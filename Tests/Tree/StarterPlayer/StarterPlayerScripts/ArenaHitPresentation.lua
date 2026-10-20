--!strict
--!native
--[[
	ArenaHitPresentation
	====================
	Client-local impact bundle for Arena hits. The server stays
	fully authoritative (attacker, target, damage, timing,
	motion); on the single authoritative HIT_CONTACT it
	broadcasts ONE ArenaHit packet over the existing
	ArenaCombatEvent remote, and this controller presents it
	INSTANTLY — same callback, zero waits before starting:

	  VFX emit + SFX play + damage-number BOP (+ camera punch,
	  owned by ArenaCameraImpacts from the same packet)

	VFX path is one deterministic one-shot (PlayArenaAttackVFX):
	clone the authored Attack1 hierarchy under a per-hit HitPoint
	in Workspace.ArenaVFX, Emit() every emitter with a positive
	count, destroy the HitPoint after the authored particle
	lifetime. No Heartbeat, no RenderStepped, no polling, no
	dependency on animations, damage numbers, or highlights.

	Assets come from the REPLICATED mirror
	(ReplicatedStorage.Assets.Vfx.HitVfx.Attack1 for the hit VFX,
	ReplicatedStorage.Assets.Arena.Sfx for sounds — mirrored at
	boot from the ServerStorage originals, which LocalScripts
	cannot read). Missing mirrors degrade gracefully
	(warn-once; the damage number needs no asset and always
	works). Sounds are preloaded at Init so the first hit
	sounds identical to the tenth.

	No HealthChanged/AttributeChanged listeners, no polling,
	no Heartbeat/RenderStepped, no Workspace scans. Per-hit
	anchor part + instances, all Debris-backed. Transient
	world-anchored effects mutate no state, so stale packets
	cannot corrupt anything (nothing to track).
]]

local ContentProvider = game:GetService('ContentProvider')
local Debris = game:GetService('Debris')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local TweenService = game:GetService('TweenService')
local Workspace = game:GetService('Workspace')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

local ArenaHitPresentation = {}

local wired = false

-- Flip to true for per-hit verification logs (off by
-- default: one line per attack would spam every fight).
-- Canonical toggle: DebugConfig.Subsystem.ArenaHitClient.
local VERBOSE = DebugConfig.Subsystem.ArenaHitClient == true

-- Focused audio-path trace (Systems.Debug Audio gate). One [Audio] line
-- per resolve/play/cleanup step; silent when off.
local AUDIO_DEBUG = DebugConfig.Audio.Enabled == true

local function audioLog(message: string)
	if AUDIO_DEBUG then
		Debug.Log('Audio', message)
	end
end

-- Canonical presentation values (ArenaPresentationConfig).
-- Every literal below preserves the previous in-code value.
local DN = ArenaPresentationConfig.DamageNumber
local VFX_CFG = ArenaPresentationConfig.Vfx
local SFX_CFG = ArenaPresentationConfig.Sfx
local ANCHOR_CFG = ArenaPresentationConfig.Anchor

local vfxTemplate: Instance? = nil
local vfxWarned = false
local arenaVfxFolder: Instance? = nil
local sfxTemplates: { Sound? } = { nil, nil, nil }
local sfxWarned: { boolean } = { false, false, false }
local hitSeq = 0

local function logClient(message: string)
	if VERBOSE then
		Debug.Log('ArenaHitClient', message)
	end
end

-- Canonical replicated hit-VFX path (mirrored at server boot
-- from ServerStorage.Assets.Vfx.HitVfx.Attack1 — LocalScripts
-- cannot read ServerStorage). Single pipeline: no second copy,
-- no Assets.Arena.Vfx.
local function resolveVfx(): Instance?
	if vfxTemplate ~= nil and vfxTemplate.Parent ~= nil then
		return vfxTemplate
	end
	vfxTemplate = nil
	pcall(function()
		local assets = ReplicatedStorage:FindFirstChild('Assets')
		local vfx = assets and assets:FindFirstChild('Vfx') or nil
		local hit = vfx and vfx:FindFirstChild('HitVfx') or nil
		local template = hit and hit:FindFirstChild(VFX_CFG.AssetName) or nil
		if template ~= nil then
			vfxTemplate = template
						Debug.Log('ArenaVFX', ('Attack1 resolved path=ReplicatedStorage.Assets.Vfx.HitVfx.%s class=%s'):format(
					VFX_CFG.AssetName,
					template.ClassName
				))
		else
			Debug.Log('ArenaVFX', ('lookup miss: ReplicatedStorage.Assets(%s).Vfx(%s).HitVfx(%s).%s(%s)'):format(
					tostring(assets ~= nil),
					tostring(vfx ~= nil),
					tostring(hit ~= nil),
					VFX_CFG.AssetName,
					'missing'
				))
		end
	end)
	return vfxTemplate
end

-- Client-local VFX container: Workspace.ArenaVFX (created once,
-- this client only — never replicated, never touches gameplay).
local function ensureArenaVfxFolder(): Instance
	if arenaVfxFolder ~= nil and (arenaVfxFolder :: Instance).Parent == Workspace then
		return arenaVfxFolder :: Instance
	end
	local found = Workspace:FindFirstChild('ArenaVFX')
	if found == nil then
		local created = Instance.new('Folder')
		created.Name = 'ArenaVFX'
		created.Parent = Workspace
		found = created
	end
	arenaVfxFolder = found
	return found :: Instance
end

-- TEST-ONLY seam: pure cleanup math (authored max + padding,
-- clamped). Mirrors PlayArenaAttackVFX so specs can pin the
-- contract without spawning instances.
function ArenaHitPresentation._TestVfxCleanup(maxLifetime: number): number
	return math.clamp(maxLifetime + VFX_CFG.CleanupPadding, VFX_CFG.MinCleanup, VFX_CFG.MaxCleanup)
end

-- SFX mirror root (unchanged pipeline):
-- ReplicatedStorage.Assets.Arena.Sfx.
local function arenaMirror(): Instance?
	local assets = ReplicatedStorage:FindFirstChild('Assets')
	local arena = assets and assets:FindFirstChild('Arena') or nil
	return arena
end

local function resolveSfx(index: number): Sound?
	local idx = math.clamp(math.floor(tonumber(index) or 1), 1, SFX_CFG.SlotCount)
	local cached = sfxTemplates[idx]
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local found: Sound? = nil
	local templateName = SFX_CFG.SlotPrefix .. tostring(idx)
	pcall(function()
		local arena = arenaMirror()
		local sfx = arena and arena:FindFirstChild('Sfx') or nil
		local template = sfx and sfx:FindFirstChild(templateName) or nil
		if template ~= nil then
			if template:IsA('Sound') then
				found = template
			else
				local inner = template:FindFirstChildWhichIsA('Sound', true)
				if inner then
					found = inner
				end
			end
		end
	end)
	if AUDIO_DEBUG then
		audioLog(
			('resolve slot=%d name=%s found=%s soundId=%s volume=%s'):format(
				idx,
				templateName,
				tostring(found ~= nil),
				found ~= nil and (found :: Sound).SoundId or 'n/a',
				found ~= nil and tostring((found :: Sound).Volume) or 'n/a'
			)
		)
	end
	sfxTemplates[idx] = found
	return found
end

-- Canonical damage text (mirrors the former server formatter:
-- integers bare, fractions one decimal).
local function formatDamage(damage: number): string
	if type(damage) ~= 'number' or damage ~= damage then
		return '0'
	end
	if damage < 0 then
		damage = 0
	end
	if damage == math.floor(damage) then
		return tostring(math.floor(damage))
	end
	local whole = math.floor(damage)
	local frac = math.floor((damage - whole) * 10 + 0.5)
	if frac >= 10 then
		return tostring(whole + 1)
	end
	return ('%d.%d'):format(whole, frac)
end

-- Preferred VFX home: the actual target Animal model's part.
-- Models replicate under Workspace.ArenaBattles, so the client
-- sees the same bodies the server sim drives. The packet carries
-- TargetId, but models are named Arena_<Team><index> with no Id
-- attribute, so the target MODEL is resolved positionally (the
-- model with a part nearest the authoritative impact — the
-- impact is already the target's hit point) and then the PART is
-- picked canonically: a child BasePart named CENTER, else the
-- model's PrimaryPart, else the model's part nearest the impact.
-- Returns nil when no battle part is close enough (caller uses
-- the HitPoint fallback). One small scan per HIT (never per
-- frame): a handful of models, buried in hit frequency.
local function findTargetPart(impact: Vector3): BasePart?
	local battles: Instance? = nil
	pcall(function()
		battles = Workspace:FindFirstChild('ArenaBattles')
	end)
	if battles == nil then
		return nil
	end
	local bestModel: Model? = nil
	local bestPart: BasePart? = nil
	local bestDist = VFX_CFG.TargetMatchMaxDistance
	pcall(function()
		for _, descendant in ipairs((battles :: Instance):GetDescendants()) do
			if descendant:IsA('BasePart') then
				local part = descendant :: BasePart
				local d = (part.Position - impact).Magnitude
				if d < bestDist then
					bestDist = d
					bestPart = part
					bestModel = part:FindFirstAncestorOfClass('Model')
				end
			end
		end
	end)
	if bestModel == nil or bestPart == nil then
		return nil
	end
	-- Canonical part preference inside the resolved target model.
	local preferred: BasePart? = nil
	pcall(function()
		local model = bestModel :: Model
		local center = model:FindFirstChild('CENTER')
		if center ~= nil and center:IsA('BasePart') then
			preferred = center :: BasePart
		elseif model.PrimaryPart ~= nil then
			preferred = model.PrimaryPart
		end
	end)
	if preferred ~= nil then
		return preferred
	end
	return bestPart
end

-- Fallback VFX home ONLY (preferred path is the target's own
-- part above): temporary invisible anchored part under the
-- client-local Workspace.ArenaVFX folder.
local function createHitPointFallback(impact: Vector3): BasePart
	local hitPoint = Instance.new('Part')
	hitPoint.Name = 'ArenaHitPoint'
	hitPoint.Size = ANCHOR_CFG.Size
	hitPoint.Transparency = 1
	hitPoint.Anchored = true
	hitPoint.CanCollide = false
	hitPoint.CanTouch = false
	hitPoint.CanQuery = false
	hitPoint.CFrame = CFrame.new(impact)
	hitPoint.Parent = ensureArenaVfxFolder()
	return hitPoint
end

-- Deterministic one-shot Arena attack VFX. impact is the
-- authoritative ImpactPosition from the ArenaHit packet (already
-- the target's hit point — never recomputed). Clones the ENTIRE
-- authored Attack1 hierarchy (expected: Attachment of
-- ParticleEmitters) and:
--   PREFERRED: parents the clone to the target's nearest
--     BasePart with Position = part:PointToObjectSpace(impact),
--     so the burst sits exactly at the hit, then destroys the
--     CLONE after longestLifetime + padding (one cleanup path;
--     target death takes it earlier, harmlessly).
--   FALLBACK (no battle part near the impact): parents the clone
--     to a temporary HitPoint at the impact (authored transform
--     preserved) and destroys the HitPoint on the same timer.
-- EVERY emitter found recursively gets a positive Emit()
-- (authored EmitCount attribute else EmitFallback); NEVER Rate
-- (continuous). No Heartbeat, no RenderStepped, no combat logic.
-- Returns the host part (target part or fallback HitPoint) so the
-- same-hit sound + damage number share the contact; nil only when
-- even the fallback cannot be built (bundle then skips safely).
local function PlayArenaAttackVFX(impact: Vector3, seq: number): BasePart?
		Debug.Log('ArenaVFX', ('HIT RECEIVED seq=%d impact=%s'):format(seq, tostring(impact)))
	local template = resolveVfx()
	if template == nil then
		Debug.Log('ArenaVFX', 'ERROR: replicated Attack1 missing (checked ReplicatedStorage.Assets.Vfx.HitVfx.Attack1)')
		if not vfxWarned then
			vfxWarned = true
			warn(
				'[ArenaHitClient] VFX mirror ReplicatedStorage.Assets.Vfx.HitVfx.Attack1 missing — hits run without VFX'
			)
		end
		return nil
	end
		Debug.Log('ArenaVFX', ('asset found class=%s name=%s'):format(template.ClassName, template.Name))
	local host: BasePart? = nil
	local ok = pcall(function()
		local clone = template:Clone()
				Debug.Log('ArenaVFX', ('Attack1 clone=%s'):format(clone.ClassName))
		-- Scan FIRST (clone still unparented): collect every
		-- emitter + its positive one-shot count + the longest
		-- authored lifetime. Emit fires AFTER placement below, so
		-- particles are born with a valid world-space home.
		local emitters: { ParticleEmitter } = {}
		local counts: { number } = {}
		local maxLifetime = 0
		for _, descendant in ipairs(clone:GetDescendants()) do
			if descendant:IsA('ParticleEmitter') then
				local emitter = descendant :: ParticleEmitter
				emitters[#emitters + 1] = emitter
				local count: number = VFX_CFG.EmitFallback
				local attr = emitter:GetAttribute('EmitCount')
				if type(attr) == 'number' and attr > 0 then
					count = math.floor(attr)
				end
				counts[#counts + 1] = math.max(1, count)
				local life = emitter.Lifetime
				if typeof(life) == 'NumberRange' and life.Max > maxLifetime then
					maxLifetime = life.Max
				end
			end
		end
		if clone:IsA('ParticleEmitter') then
			-- Attack1 authored as a bare emitter (no Attachment
			-- wrapper): it IS the effect.
			local emitter = clone :: ParticleEmitter
			emitters[#emitters + 1] = emitter
			local count: number = VFX_CFG.EmitFallback
			local attr = emitter:GetAttribute('EmitCount')
			if type(attr) == 'number' and attr > 0 then
				count = math.floor(attr)
			end
			counts[#counts + 1] = math.max(1, count)
			local life = emitter.Lifetime
			if typeof(life) == 'NumberRange' then
				maxLifetime = life.Max
			end
		end
				Debug.Log('ArenaVFX', ('total emitters=%d'):format(#emitters))
		if #emitters == 0 then
			Debug.Log('ArenaVFX', 'ERROR: Attack1 contains zero ParticleEmitters')
			Debug.Warn('ArenaVFX', ('total emitters=0 seq=%d — wrong asset or unexpected Attack1 hierarchy, VFX will be invisible'):format(
					seq
				))
			pcall(function()
				clone:Destroy()
			end)
			return
		end
		local vfxCleanup = math.clamp(maxLifetime + VFX_CFG.CleanupPadding, VFX_CFG.MinCleanup, VFX_CFG.MaxCleanup)
		-- Placement: PREFERRED = target's own part at the exact
		-- impact; FALLBACK = temporary HitPoint at the impact.
		-- pcall: a part mid-destroy falls through to the
		-- fallback, never fails the hit.
		local isFallback = false
		local targetPart = findTargetPart(impact)
		if targetPart ~= nil then
			local placed = false
			pcall(function()
				if (clone :: Instance):IsA('Attachment') then
					-- Exact hit placement: authoritative world
					-- impact in the part's local space (NOT zeroed).
					(clone :: Attachment).Position = (targetPart :: BasePart).CFrame:PointToObjectSpace(impact)
				end
				(clone :: Instance).Parent = targetPart
				placed = true
			end)
			if placed then
				host = targetPart
			else
				isFallback = true
			end
		else
			Debug.Log('ArenaVFX', 'no battle part near impact — HitPoint fallback')
			isFallback = true
		end
		if isFallback then
			local hitPoint = createHitPointFallback(impact)
			clone.Parent = hitPoint
			host = hitPoint
		end
		local part = host :: BasePart
		local model = part:FindFirstAncestorOfClass('Model')
		local localPosition = part.CFrame:PointToObjectSpace(impact)
				Debug.Log('ArenaVFX', ('PLAY seq=%d impact=%s asset=ReplicatedStorage.Assets.Vfx.HitVfx.Attack1 class=%s targetPart=%s localPosition=%s emitters=%d'):format(
				seq,
				tostring(impact),
				clone.ClassName,
				part.Name,
				tostring(localPosition),
				#emitters
			))
		if model ~= nil then
			logClient(('hit target model=%s fallback=%s'):format((model :: Model).Name, tostring(isFallback)))
		end
		-- Fire every emitter NOW that the clone has a valid
		-- world-space home, then stop continuous spray
		-- (already-emitted particles live out their Lifetime).
		for i, emitter in ipairs(emitters) do
						Debug.Log('ArenaVFX', ('EMIT seq=%d emitter=%s count=%d'):format(seq, emitter.Name, counts[i]))
			emitter:Emit(counts[i])
			emitter.Enabled = false
		end
				Debug.Log('ArenaVFX', ('PLAY COMPLETE seq=%d emitted=%d cleanupIn=%.2fs'):format(seq, #emitters, vfxCleanup))
		-- Exactly ONE cleanup path per branch: the clone (target
		-- path — target death takes it earlier, harmlessly) or
		-- the HitPoint (fallback path, plus a longer Debris
		-- backup that can never win).
		if isFallback then
			local hitPoint = part
			Debris:AddItem(hitPoint, vfxCleanup + VFX_CFG.AnchorMargin)
			task.delay(vfxCleanup, function()
				pcall(function()
					if hitPoint.Parent ~= nil then
						hitPoint:Destroy()
					end
				end)
			end)
		else
			task.delay(vfxCleanup, function()
				pcall(function()
					if (clone :: Instance).Parent ~= nil then
						(clone :: Instance):Destroy()
					end
				end)
			end)
		end
	end)
	if not ok then
		warn(('[ArenaVFX] FAILED safely seq=%d (hit continues without VFX)'):format(seq))
		return host
	end
	return host
end

-- One-shot sound AT the anchor (3D positioned by parenting):
-- clone preserves every authored property; cleanup on Ended
-- + Debris fallback. Reports invalid/missing SoundIds.
local function playSfx(anchor: BasePart, soundIndex: number)
	local idx = math.clamp(math.floor(tonumber(soundIndex) or 1), 1, SFX_CFG.SlotCount)
	local template = resolveSfx(idx)
	if template == nil then
		if not sfxWarned[idx] then
			sfxWarned[idx] = true
			warn(
				('[ArenaHitClient] SFX mirror ReplicatedStorage.Assets.Arena.Sfx.Attack%d missing — hits run mute for slot %d'):format(
					idx,
					idx
				)
			)
		end
		return
	end
	pcall(function()
		local soundId = template.SoundId
		if AUDIO_DEBUG then
			audioLog(
				('attempt slot=%d soundId=%s volume=%s parent=%s'):format(
					idx,
					tostring(soundId),
					tostring(template.Volume),
					tostring(template:GetFullName())
				)
			)
		end
		if type(soundId) ~= 'string' or soundId == '' then
			if not sfxWarned[idx] then
				sfxWarned[idx] = true
								Debug.Warn('ArenaHitClient', ('SFX Attack%d has an empty SoundId â€” slot %d silent'):format(idx, idx))
			end
			return
		end
		local clone = template:Clone()
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = anchor
		if AUDIO_DEBUG then
			audioLog(
				('play slot=%d parent=%s isPlayingBefore=%s'):format(
					idx,
					tostring(anchor:GetFullName()),
					tostring(clone.IsPlaying)
				)
			)
		end
		clone:Play()
		logClient(('SFX played slot=%d'):format(idx))
		local dur = SFX_CFG.FallbackCleanup
		local d = clone.TimeLength
		if type(d) == 'number' and d == d and d > 0 then
			dur = math.min(d + SFX_CFG.CleanupPadding, SFX_CFG.MaxCleanup)
		end
		Debris:AddItem(clone, dur)
		task.spawn(function()
			pcall(function()
				clone.Ended:Wait()
			end)
			if AUDIO_DEBUG then
				audioLog(('cleanup slot=%d after %.2fs'):format(idx, dur))
			end
			pcall(function()
				clone:Destroy()
			end)
		end)
	end)
end

-- Cartoony damage BOP on the anchor: 0.2 -> 1.35 -> 0.95 ->
-- 1.0 with tilt settle, tiny rise, micro-squash exit. Fully
-- opaque throughout (NO fade), ~0.35s, then destroy. Tween
-- chain on Completed waits — no loops, no Heartbeat.
local function popDamageNumber(anchor: BasePart, damage: number)
	pcall(function()
		local jitterX = (math.random() - 0.5) * DN.JitterX
		local tilt = (math.random() - 0.5) * DN.TiltRange
		local baseSize = DN.BaseSize
		local created = Instance.new('BillboardGui')
		created.Name = 'ArenaDamageNumber'
		created.Size = baseSize * 0.2
		created.StudsOffsetWorldSpace = Vector3.new(jitterX, DN.RiseStart, 0)
		created.AlwaysOnTop = true
		created.LightInfluence = 0
		created.MaxDistance = DN.MaxDistance
		local label = Instance.new('TextLabel')
		label.Name = 'Damage'
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = '-' .. formatDamage(damage)
		label.Font = DN.Font
		label.TextScaled = true
		label.Rotation = tilt
		label.TextColor3 = DN.TextColor
		label.TextStrokeTransparency = DN.TextStrokeTransparency
		local stroke = Instance.new('UIStroke')
		stroke.Thickness = DN.StrokeThickness
		stroke.Color = DN.StrokeColor
		stroke.Transparency = 0
		stroke.Parent = label
		label.Parent = created
		created.Adornee = anchor
		created.Parent = anchor
		Debris:AddItem(created, DN.Lifetime)
		local liveTweens: { Tween } = {}
		local function playTween(inst: Instance, info: TweenInfo, props: { [string]: any })
			local tween = TweenService:Create(inst, info, props)
			liveTweens[#liveTweens + 1] = tween
			tween:Play()
			return tween
		end
		local quadOut = TweenInfo.new(DN.PopDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local popTween = playTween(created, quadOut, { Size = baseSize * DN.PopScale })
		popTween.Completed:Wait()
		if created.Parent == nil then
			return
		end
		local overTween = playTween(created, quadOut, { Size = baseSize * DN.OvershootScale })
		overTween.Completed:Wait()
		if created.Parent == nil then
			return
		end
		playTween(label, TweenInfo.new(DN.SettleDuration), { Rotation = 0 })
		playTween(
			created,
			TweenInfo.new(DN.SettleDuration),
			{ StudsOffsetWorldSpace = Vector3.new(jitterX, DN.RiseEnd, 0) }
		)
		local settleTween = playTween(created, TweenInfo.new(DN.SettleDuration), { Size = baseSize })
		settleTween.Completed:Wait()
		if created.Parent == nil then
			return
		end
		local exitTween = playTween(created, TweenInfo.new(DN.ExitDuration), {
			Size = UDim2.fromScale(baseSize.X.Scale * DN.ExitScaleX, baseSize.Y.Scale * DN.ExitScaleY),
		})
		exitTween.Completed:Wait()
		for _, tween in ipairs(liveTweens) do
			pcall(function()
				tween:Destroy()
			end)
		end
		pcall(function()
			created:Destroy()
		end)
		logClient('damage pop done')
	end)
end

-- The SAME callback presents the whole bundle with zero
-- waits before starting: anchor, VFX, sound, number. (Camera
-- punch rides the same packet via ArenaCameraImpacts.)
local function onHit(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	if payload.Event ~= 'ArenaHit' then
		return
	end
	if typeof(payload.ImpactPosition) ~= 'Vector3' then
		return
	end
	local ok = pcall(function()
		hitSeq += 1
		local seq = hitSeq
		logClient(
			('received seq=%s anim=%s sound=%s damage=%s'):format(
				tostring(payload.AttackSequence),
				tostring(payload.AttackIndex),
				tostring(payload.SoundIndex),
				tostring(payload.Damage)
			)
		)
		-- One authoritative hit fans out to three independent
		-- presentations, all starting NOW (zero stagger, zero
		-- coupling — if VFX fails, sound/number still play):
		--   1. Attack1 burst ON the target at the exact impact
		--      (HitPoint fallback when no battle part matches).
		--   2. Positional hit sound on the same host part.
		--   3. White damage popup on the same host part.
		-- Camera punch rides the same packet via ArenaCameraImpacts.
		local impact: Vector3 = payload.ImpactPosition
		local host = PlayArenaAttackVFX(impact, seq)
		if host == nil then
			host = createHitPointFallback(impact)
			Debris:AddItem(host, ANCHOR_CFG.Lifetime)
		end
		playSfx(host, payload.SoundIndex)
		task.spawn(function()
			popDamageNumber(host, tonumber(payload.Damage) or 0)
		end)
	end)
	if not ok then
		pcall(function()
			warn('[ArenaHitClient] hit presentation failed safely (bundle skipped)')
		end)
	end
end

function ArenaHitPresentation.Init()
	if wired then
		return
	end
	wired = true
	-- Warm the replicated Attack1 early (server mirrors it at
	-- boot, possibly after this client loads): WAIT for it rather
	-- than permanently failing, so early hits still get VFX.
	-- Async, non-blocking, pcall'd.
	task.spawn(function()
		pcall(function()
			local assets = ReplicatedStorage:WaitForChild('Assets', 10)
			local vfx = assets and assets:WaitForChild('Vfx', 10) or nil
			local hit = vfx and vfx:WaitForChild('HitVfx', 10) or nil
			local attack = hit and hit:WaitForChild(VFX_CFG.AssetName, 10) or nil
			if attack ~= nil then
				vfxTemplate = attack
								Debug.Log('ArenaVFX', ('Attack1 resolved path=ReplicatedStorage.Assets.Vfx.HitVfx.%s class=%s'):format(
						VFX_CFG.AssetName,
						attack.ClassName
					))
			else
				Debug.Log('ArenaVFX', 'warmup: Attack1 not yet replicated (per-hit lookup will retry)')
			end
		end)
	end)
	-- Preload hit assets so the first impact sounds/looks
	-- identical to the tenth. Async, non-blocking, pcall'd.
	task.spawn(function()
		pcall(function()
			local items: { Instance } = {}
			pcall(function()
				local arena = arenaMirror()
				local sfx = arena and arena:FindFirstChild('Sfx') or nil
				if sfx then
					for _, child in ipairs(sfx:GetChildren()) do
						if child:IsA('Sound') then
							items[#items + 1] = child
						else
							local inner = child:FindFirstChildWhichIsA('Sound', true)
							if inner then
								items[#items + 1] = inner
							end
						end
					end
				end
				local attack = resolveVfx()
				if attack then
					items[#items + 1] = attack
				end
			end)
			if #items > 0 then
				ContentProvider:PreloadAsync(items)
			end
		end)
	end)
	local folder = Remotes.WaitForReady()
	local okEvent, combatEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaCombatEvent, 10)
	end)
	if okEvent and combatEvent ~= nil and (combatEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(combatEvent :: RemoteEvent).OnClientEvent:Connect(onHit)
		end)
	end
end

return table.freeze(ArenaHitPresentation)
