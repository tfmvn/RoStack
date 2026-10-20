--!strict
--!native
--[[
	CollectFeedback
	===============
	Instant cash-collection feedback, server-side, fired ONLY on
	a successful authoritative claim commit (IncomeService.
	TryCollect, after AddMoney succeeds and the pool zeroes).

	One call — CollectFeedback.Play(player, slot) — triggers all
	three effects synchronously, with zero waits between commit
	and feedback:

  * CashClaim SFX (`ServerStorage.Assets.Sfx.CashClaim`):
    ONE persistent Sound per player (`CashClaimSfx` under
    their PlayerGui, LevelUp-persistent-instance pattern),
    props copied from the template (RollController
    _copySfxProps convention). Play() restarts it, so rapid
    claims never stack, leak, or allocate. Private to the
    collecting player (StealService robbery-alert scoping).
    RELIABILITY (pool): a single restarting instance drops
    overlapping claims and mutes the first collect while the
    asset replicates, so the SFX is a BOUNDED pool of 4
    pre-created Sounds per player (`CashClaimPool` Folder in
    their PlayerGui, warmed at join via Warm() and topped up
    on every play). Each success round-robins to the next
    member, so rapid claims overlap instead of truncating.
    Every play revalidates SoundId against the template (a
    stale/empty instance is refreshed, never replayed mute),
    and the legacy `CashClaimSfx` singleton is removed when
    the pool is ensured. Private to the collecting player
    (StealService robbery-alert scoping).
  * CashClaim VFX (`ServerStorage.Assets.Vfx.CashClaim`
    Attachment): per-claim clone mounted to
    `Stand.Button.PressPart` (template never mutated),
    burst origin re-anchored just above the button's live
    top surface so particles escape the opaque mesh, every
    descendant emitter fired with its own authored EmitCount
    attribute (exact value, fallback 0), Debris-cleaned by
    emitter lifetime. Step-for-step LevelUpPresentation
    parity: same mount, same re-anchor, same one-Heartbeat
    replication catch-up, same Debris rule. A small random
    yaw on the CLONED attachment varies burst orientation
    per claim (asset values untouched).
  * Button press (`Stand.Button.PressPart` toward
    `Stand.Button.Base`): the press distance is derived
    from the LIVE Base/PressPart geometry along the
    button's own local Y (a fraction of the projected
    gap — never a hardcoded world offset). ONE TweenService
    tween per button at a time: a new claim cancels the
    previous tween, bumps the press generation, snaps to
    the canonical rest CFrame, and tweens down; the
    down-Completed callback (generation-checked) tweens
    back to rest. Stale callbacks can never fight a newer
    press. No Heartbeat/RenderStepped loops, no polling.

	Empty / failed / rejected claims never reach here — the
	caller only invokes Play on the success branch — so there
	is no silent-feedback path by construction. Every effect
	is independently nil-safe: a missing asset or part skips
	that effect only, never the claim, never the others.

	Performance: template refs cached (re-resolved if
	destroyed); per claim the work is one pooled Sound.Play
	(round-robin, zero allocation after warm), one Attachment
	clone + N Emits (async, off the commit path), and one short
	TweenService tween. No Workspace scans (the slot record
	already carries its parts), no per-button loops; VFX clones
	are Debris-bounded by emitter lifetime.
]]

local ServerStorage = game:GetService('ServerStorage')
local TweenService = game:GetService('TweenService')
local RunService = game:GetService('RunService')
local Debris = game:GetService('Debris')

local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local DebugConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local AudioConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Audio)
local Bases = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local AudioGroups = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)

local CollectFeedback = {}

-- --- Tuning (feel only — no placement authority) ------------------
-- Canonical sources: Bases.Collector.Feel (press/VFX feel) + Audio.Collect (SFX pool).

local _FEEL = Bases.Collector.Feel

-- Fraction of the live Base↔PressPart gap the button travels.
-- Geometry-relative: adapts to the authored button, never
-- overshoots into Base (fraction < 1), never a world offset.
local PRESS_FRACTION = _FEEL.PressFraction
-- Minimum projected gap worth pressing; below this the button
-- is degenerate and the press is skipped (SFX/VFX still play).
local MIN_PRESS_TRAVEL = _FEEL.MinPressTravel
-- Animation feel: fast press, short hold, smooth return.
local PRESS_SECONDS = _FEEL.PressSeconds
local HOLD_SECONDS = _FEEL.HoldSeconds
local RELEASE_SECONDS = _FEEL.ReleaseSeconds
-- Visual nudge lifting the VFX burst origin above the
-- button's top surface so particles escape the opaque mesh
-- (LevelUp re-anchor convention). Presentation only.
local VFX_SURFACE_LIFT = _FEEL.VfxSurfaceLift

local SFX_CHILD_NAME = 'CashClaimSfx' -- legacy singleton: removed when the pool is ensured
local POOL_FOLDER_NAME = 'CashClaimPool'
-- Pool size: a short sting with collections at most ~1/s apart
-- (income tick) means 4 overlapping voices can never exhaust;
-- rapid legitimate claims overlap instead of truncating. Fixed
-- bound: never grows, never Debris-churned, replicates once.
local POOL_SIZE = AudioConfig.Collect.PoolSize

-- --- Cached template refs -----------------------------------------

local _sfxSource: Sound? = nil
local _sfxSourceValid = false
local _vfxTemplate: Instance? = nil
local _vfxTemplateValid = false
local _warnedMissingSfx = false
local _warnedMissingVfx = false

local function _resolveSfxSource(): Sound?
	if _sfxSourceValid and _sfxSource ~= nil and _sfxSource.Parent ~= nil then
		return _sfxSource
	end
	_sfxSource = nil
	_sfxSourceValid = true
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local sfxRoot = assets and assets:FindFirstChild('Sfx') or nil
		local template = sfxRoot and sfxRoot:FindFirstChild('CashClaim') or nil
		if not template then
			return
		end
		if template:IsA('Sound') then
			_sfxSource = template
		else
			local inner = template:FindFirstChildWhichIsA('Sound', true)
			if inner then
				_sfxSource = inner
			end
		end
	end)
	if _sfxSource == nil and not _warnedMissingSfx then
		_warnedMissingSfx = true
		Debug.Warn('CF', 'ServerStorage.Assets.Sfx.CashClaim missing — claims run mute', {})
	end
	return _sfxSource
end

local function _resolveVfxTemplate(): Instance?
	if _vfxTemplateValid and _vfxTemplate ~= nil and _vfxTemplate.Parent ~= nil then
		return _vfxTemplate
	end
	_vfxTemplate = nil
	_vfxTemplateValid = true
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local vfxRoot = assets and assets:FindFirstChild('Vfx') or nil
		local cashClaim = vfxRoot and vfxRoot:FindFirstChild('CashClaim') or nil
		if not cashClaim then
			return
		end
		-- The asset IS an Attachment, or carries one.
		if cashClaim:IsA('Attachment') then
			_vfxTemplate = cashClaim
		else
			local inner = cashClaim:FindFirstChildWhichIsA('Attachment', true)
			if inner then
				_vfxTemplate = inner
			end
		end
	end)
	if _vfxTemplate == nil and not _warnedMissingVfx then
		_warnedMissingVfx = true
		Debug.Warn('CF', 'ServerStorage.Assets.Vfx.CashClaim Attachment missing — claims run without VFX', {})
	end
	return _vfxTemplate
end

-- --- SFX (bounded pre-warmed pool per player) -------------------------

-- Round-robin cursor per player (userId -> next pool index).
-- Cleared by ForgetPlayer; missing entries start at 1.
local _nextIndex: { [number]: number } = {}

local function _copySfxProps(target: Sound, source: Sound)
	pcall(function()
		target.SoundId = source.SoundId
	end)
	pcall(function()
		target.Volume = source.Volume
	end)
	pcall(function()
		target.PlaybackSpeed = source.PlaybackSpeed
	end)
	pcall(function()
		target.RollOffMinDistance = source.RollOffMinDistance
	end)
	pcall(function()
		target.RollOffMaxDistance = source.RollOffMaxDistance
	end)
	pcall(function()
		target.EmitterSize = source.EmitterSize
	end)
	target.Looped = false
	target.PlayOnRemove = false
	-- Global SoundGroup architecture: every CashClaim voice is
	-- SFX (prop refreshes re-stamp so nothing slips through).
	AudioGroups.AssignSfx(target)
end

-- Ensure the player's bounded SFX pool exists under guiRoot
-- (their PlayerGui in production, any container in specs) and
-- return its Sound members. Self-healing: missing members are
-- recreated on every call, so PlayerGui recreation/respawn can
-- never permanently lose audio — the next success rebuilds.
-- Stale members (empty/retargeted SoundId) are refreshed from
-- the template; the legacy singleton is destroyed. Never throws.
local function _ensurePool(guiRoot: Instance): { Sound }
	local pool: { Sound } = {}
	pcall(function()
		local source = _resolveSfxSource()
		local folder = guiRoot:FindFirstChild(POOL_FOLDER_NAME)
		if not (folder and folder:IsA('Folder')) then
			local fresh = Instance.new('Folder')
			fresh.Name = POOL_FOLDER_NAME
			fresh.Parent = guiRoot
			folder = fresh
		end
		local typed = folder :: Folder
		-- Legacy singleton replaced by the pool (also purges a
		-- broken instance cached by the old path).
		local legacy = guiRoot:FindFirstChild(SFX_CHILD_NAME)
		if legacy then
			pcall(function()
				(legacy :: Instance):Destroy()
			end)
		end
		for i = 1, POOL_SIZE do
			local name = 'CashClaim' .. tostring(i)
			local child = typed:FindFirstChild(name)
			local sound: Sound? = nil
			if child and child:IsA('Sound') then
				sound = child
			else
				local made = Instance.new('Sound')
				made.Name = name
				made.Looped = false
				made.PlayOnRemove = false
				AudioGroups.AssignSfx(made)
				made.Parent = typed
				sound = made
			end
			if sound then
				-- Refresh stale members: never replay a muted /
				-- retargeted instance. Same-value sets are
				-- no-ops (no reload); only real drift recopies.
				if source and source.SoundId ~= '' and sound.SoundId ~= source.SoundId then
					_copySfxProps(sound, source)
				end
				pool[#pool + 1] = sound
			end
		end
	end)
	return pool
end

-- Play one pool member round-robin for userId. Returns played +
-- the member name (test seam asserts rotation). Never throws.
local function _playFromPool(guiRoot: Instance, userId: number): (boolean, string?)
	local played = false
	local used: string? = nil
	pcall(function()
		local pool = _ensurePool(guiRoot)
		if #pool == 0 then
			return
		end
		local idx = (_nextIndex[userId] or 0) % #pool + 1
		_nextIndex[userId] = idx
		local sound = pool[idx]
		if sound.SoundId == '' then
			-- No valid asset (source missing): stay mute rather
			-- than fake a play.
			return
		end
		if DebugConfig.Audio.Enabled == true then
						Debug.Log('Audio', ('collect resolve=CashClaim soundId=%s volume=%s parent=PlayerGui member=%s play=called'):format(
					tostring(sound.SoundId),
					tostring(sound.Volume),
					tostring(sound.Name)
				))
		end
		sound:Play()
		played = true
		used = sound.Name
	end)
	return played, used
end

-- Play for the collecting player on their pool. Returns true
-- when audible.
local function _playSfx(player: Player): boolean
	local played = false
	pcall(function()
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if not playerGui then
			return
		end
		played = _playFromPool(playerGui, player.UserId)
	end)
	return played
end

-- --- VFX (LevelUp-parity burst on the cash trigger) -------------------
--
-- Per successful claim: clone the CashClaim template (template
-- NEVER mutated), mount to PressPart, fire, Debris-clean.
-- This mirrors LevelUpPresentation.PlayUpgradeVfx step for
-- step, because the previous persistent-rig variant proved
-- invisible in production for two reasons this fixes:
--   1. OCCLUSION: a template-attachment kept at its authored
--      local offset sits INSIDE the opaque PressPart mesh,
--      where every particle is occluded (the exact failure
--      LevelUp's re-anchor step exists for). The burst
--      origin is therefore re-anchored to just above the
--      button's live top surface (rotation preserved), so
--      particles escape the mesh. The lift derives from the
--      part's own Size — no world hardcode.
--   2. REPLICATION RACE: Emit on a brand-new instance in the
--      same tick as parenting can be missed by clients it
--      has not replicated to yet. One Heartbeat closes the
--      race (LevelUp-proven; ~16ms, imperceptible, and the
--      sound + button press still fire with zero wait).
-- Spam safety comes from Debris-bounded short lives (the
-- same contract as rapid level-ups): overlapping bursts
-- coexist briefly, nothing permanent accumulates, no
-- connections are created.
local function _playVfx(pressPart: BasePart): boolean
	local fired = false
	pcall(function()
		local template = _resolveVfxTemplate()
		if not template then
			return
		end
		local clone = template:Clone()
		local cloneDescendants = clone:GetDescendants()
		-- Collect what can play (LevelUp convention: every
		-- descendant emitter fires — never just the first;
		-- template-contained Sounds play too; Lights/Beams
		-- are switched on for the burst lifetime). No
		-- authored property is altered to decide this —
		-- the asset's own hierarchy is the playlist.
		local playables: { Instance } = {}
		for _, descendant in ipairs(cloneDescendants) do
			if
				descendant:IsA('ParticleEmitter')
				or descendant:IsA('Sound')
				or descendant:IsA('PointLight')
				or descendant:IsA('SpotLight')
				or descendant:IsA('SurfaceLight')
				or descendant:IsA('Beam')
			then
				playables[#playables + 1] = descendant
			end
		end
		-- Burst attachments: the clone itself when the asset
		-- IS an attachment, plus re-homed ones below.
		local burstAttachments: { Attachment } = {}
		if clone:IsA('Attachment') then
			burstAttachments[#burstAttachments + 1] = clone
		end
		-- Mount: attachments already under a BasePart resolve
		-- correctly; everything else re-homes onto PressPart
		-- (the cloned attachment is reused as-is — never a
		-- replacement). Nodes moved OUT of the clone get
		-- their own Debris entry since Debris on the clone
		-- cannot reach them anymore.
		local movedOut: { Instance } = {}
		clone.Parent = pressPart
		for _, descendant in ipairs(cloneDescendants) do
			if descendant:IsA('Attachment') then
				local p = descendant.Parent
				if not (p and p:IsA('BasePart')) then
					descendant.Parent = pressPart
					movedOut[#movedOut + 1] = descendant
					burstAttachments[#burstAttachments + 1] = descendant
				end
			elseif
				descendant:IsA('ParticleEmitter')
				or descendant:IsA('Sound')
				or descendant:IsA('PointLight')
				or descendant:IsA('SpotLight')
				or descendant:IsA('SurfaceLight')
				or descendant:IsA('Beam')
			then
				local p = descendant.Parent
				if not (p and (p:IsA('BasePart') or p:IsA('Attachment'))) then
					descendant.Parent = pressPart
					movedOut[#movedOut + 1] = descendant
				end
			end
		end
		-- Re-anchor the burst origin just above the button's
		-- live top surface so particles are never buried in
		-- the opaque mesh. Orientation preserved; only the
		-- world position is re-anchored.
		do
			local up = pressPart.CFrame.UpVector
			local burstPos = pressPart.Position + up * (pressPart.Size.Y / 2 + VFX_SURFACE_LIFT)
			-- Per-burst orientation variation lives ONLY in the
			-- CLONE's transform (never in authored emitter
			-- props): a random yaw so repeated claims don't
			-- stack into an identical cone.
			local yaw = 0
			pcall(function()
				yaw = math.random() * math.pi * 2
			end)
			local yawCf = CFrame.Angles(0, yaw, 0)
			for _, attachment in ipairs(burstAttachments) do
				pcall(function()
					local wc = attachment.WorldCFrame
					attachment.WorldCFrame = CFrame.new(burstPos) * (yawCf * (wc - wc.Position))
				end)
			end
		end
		-- Replication catch-up: brand-new instances need one
		-- Heartbeat before Emit, or clients miss the burst.
		RunService.Heartbeat:Wait()
		if pressPart.Parent == nil then
			clone:Destroy()
			for _, moved in ipairs(movedOut) do
				pcall(function()
					moved:Destroy()
				end)
			end
			return
		end
		-- One-shot playback. Burst count = each emitter's OWN
		-- authored EmitCount ATTRIBUTE (the Studio authoring
		-- is the source of truth for density; each emitter
		-- keeps its distinct value — never normalized, never
		-- scaled). Missing/invalid attribute -> safe
		-- fallback 0 (Emit(0) is a no-op). The source
		-- template is never mutated; only the clone emits.
		-- Enabled is left as-authored on the clone; nothing
		-- authored is modified, only triggered.
		local longestLifetime = 0
		local emitterCount = 0
		for _, inst in ipairs(playables) do
			if inst:IsA('ParticleEmitter') then
				emitterCount += 1
				local emitter = inst :: ParticleEmitter
				local count = 0
				local okAttr, raw = pcall(function()
					return emitter:GetAttribute('EmitCount')
				end)
				if okAttr and type(raw) == 'number' and raw == raw and raw ~= math.huge and raw ~= -math.huge then
					count = math.max(0, math.floor(raw + 0.5))
				else
					count = 0
				end
				if pcall(function()
					emitter:Emit(count)
				end) then
					fired = true
				end
				local okLife, lifetime = pcall(function()
					return emitter.Lifetime
				end)
				if okLife and typeof(lifetime) == 'NumberRange' then
					if lifetime.Max > longestLifetime then
						longestLifetime = lifetime.Max
					end
				end
			elseif inst:IsA('Sound') then
				pcall(function()
					local sfx = inst :: Sound
					AudioGroups.AssignSfx(sfx)
					sfx:Play()
				end)
			elseif inst:IsA('PointLight') or inst:IsA('SpotLight') or inst:IsA('SurfaceLight') then
				-- Clone-only write (Debris below owns
				-- cleanup): flash the authored light for the
				-- burst lifetime. The template is untouched.
				pcall(function()
					(inst :: PointLight).Enabled = true
				end)
			elseif inst:IsA('Beam') then
				pcall(function()
					(inst :: Beam).Enabled = true
				end)
			end
		end
		local lifetime = math.clamp(longestLifetime + _FEEL.VfxCleanupPadding, _FEEL.VfxCleanupMin, _FEEL.VfxCleanupMax)
		Debris:AddItem(clone, lifetime)
		for _, moved in ipairs(movedOut) do
			Debris:AddItem(moved, lifetime)
		end
		if emitterCount == 0 then
			Debug.Warn('CF', 'CashClaim VFX has no ParticleEmitter — investigate asset reference/path', {
				templateClass = template.ClassName,
			})
		end
	end)
	return fired
end

-- --- Button press (ONE TweenService tween per button) ---------------------

-- Per-PressPart presentation state (weak keys so a destroyed
-- stand never pins memory): the canonical rest transform
-- (cached on first sight — nothing else in the game moves the
-- button), the live tween + its connection, and the press
-- generation. A new claim cancels the previous tween,
-- disconnects its callback, bumps the generation, snaps to
-- rest, and tweens down. Completed callbacks re-check the
-- generation AND the tween's PlaybackState, so a stale
-- callback (cancelled tween, superseded press) can never
-- move the button after a newer press started.
type ButtonState = {
	rest: CFrame,
	generation: number,
	tween: Tween?,
	conn: RBXScriptConnection?,
}
local _buttons: { [BasePart]: ButtonState } = setmetatable({}, { __mode = 'k' })

local DOWN_INFO = TweenInfo.new(PRESS_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local UP_INFO = TweenInfo.new(RELEASE_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

-- Pure pressed-transform math (test seam below asserts it):
-- travel is the live Base↔PressPart gap projected onto the
-- button's own local Y, times PRESS_FRACTION. Degenerate gaps
-- return the rest transform (press skipped by the caller).
function CollectFeedback.ComputePressedCFrame(rest: CFrame, basePos: Vector3, fraction: number?): CFrame
	local f = fraction or PRESS_FRACTION
	local up = rest.UpVector
	local gapVec = basePos - rest.Position
	local travel = -gapVec:Dot(up)
	if not (travel == travel) or travel < MIN_PRESS_TRAVEL then
		return rest
	end
	return rest - up * (travel * f)
end

-- Cancel the live tween + callback without touching the
-- part (the caller owns what happens next). Generation is
-- NOT bumped here — only a new press bumps it.
local function _cancelLocked(state: ButtonState)
	if state.conn then
		pcall(function()
			(state.conn :: RBXScriptConnection):Disconnect()
		end)
		state.conn = nil
	end
	if state.tween then
		pcall(function()
			(state.tween :: Tween):Cancel()
		end)
		pcall(function()
			(state.tween :: Tween):Destroy()
		end)
		state.tween = nil
	end
end

local function _pressButton(pressPart: BasePart, base: BasePart)
	local state = _buttons[pressPart]
	if not state then
		local okRest, restCf = pcall(function()
			return pressPart.CFrame
		end)
		if not okRest or typeof(restCf) ~= 'CFrame' then
			return
		end
		state = { rest = restCf, generation = 0, tween = nil, conn = nil }
		_buttons[pressPart] = state
	end
	-- A dead/destroyed part ends the presentation permanently.
	if pressPart.Parent == nil then
		_cancelLocked(state)
		_buttons[pressPart] = nil
		return
	end
	local okBase, basePos = pcall(function()
		return base.Position
	end)
	if not okBase or typeof(basePos) ~= 'Vector3' then
		return
	end
	local rest: CFrame = state.rest
	local pressed = CollectFeedback.ComputePressedCFrame(rest, basePos)
	if pressed == rest then
		return
	end
	-- Supersede: kill the previous tween + callback FIRST so
	-- no old Completed handler can ever fire into the new
	-- press, then bump the generation the new callbacks own.
	_cancelLocked(state)
	state.generation += 1
	local mine = state.generation
	-- Restart FROM rest: travel always derives from the
	-- canonical transform, never from a mid-animation pose,
	-- so spam can never accumulate offsets or strand the
	-- button below/above rest.
	pcall(function()
		pressPart.CFrame = rest
	end)
	local downTween: Tween? = nil
	pcall(function()
		downTween = TweenService:Create(pressPart, DOWN_INFO, { CFrame = pressed })
	end)
	if downTween == nil then
		return
	end
	state.tween = downTween
	-- Short hold at the bottom is folded into the release
	-- chain: the down-Completed callback waits HOLD_SECONDS
	-- (generation-checked) before tweening back, so the
	-- press reads as a physical click, not a vibration.
	state.conn = (downTween :: Tween).Completed:Connect(function(playState: Enum.PlaybackState)
		if playState ~= Enum.PlaybackState.Completed then
			return
		end
		if state.generation ~= mine or pressPart.Parent == nil then
			return
		end
		task.delay(HOLD_SECONDS, function()
			if state.generation ~= mine or pressPart.Parent == nil then
				return
			end
			local upTween: Tween? = nil
			pcall(function()
				upTween = TweenService:Create(pressPart, UP_INFO, { CFrame = rest })
			end)
			if upTween == nil then
				return
			end
			state.tween = upTween
			state.conn = (upTween :: Tween).Completed:Connect(function(upState: Enum.PlaybackState)
				if upState ~= Enum.PlaybackState.Completed then
					return
				end
				if state.generation ~= mine or pressPart.Parent == nil then
					return
				end
				-- Exact rest restore: tweens interpolate in
				-- floats, so snap to the canonical CFrame.
				pcall(function()
					pressPart.CFrame = rest
				end)
				state.tween = nil
				state.conn = nil
			end)
			pcall(function()
				(upTween :: Tween):Play()
			end)
		end)
	end)
	pcall(function()
		(downTween :: Tween):Play()
	end)
end

-- TEST-ONLY seam: run one press cycle against explicit parts
-- (returns the press generation). Specs use it for spam
-- determinism without a player/slot.
function CollectFeedback._TestPress(pressPart: BasePart, base: BasePart): number
	_pressButton(pressPart, base)
	local state = _buttons[pressPart]
	return state and state.generation or 0
end

-- TEST-ONLY seam: fire the VFX rig against an explicit part
-- (returns true when at least one emitter fired). Lets specs
-- assert mount point, reuse, and emission with a staged
-- ServerStorage asset and no player.
function CollectFeedback._TestFireVfx(pressPart: BasePart): boolean
	if typeof(pressPart) ~= 'Instance' or not (pressPart :: Instance):IsA('BasePart') then
		return false
	end
	return _playVfx(pressPart)
end

-- --- Public API -----------------------------------------------------

function CollectFeedback.Init() end

-- Fire all three effects for a SUCCESSFUL claim. Ordering is
-- deliberate: SFX plays FIRST and synchronously (never blocked
-- by presentation), then the button press, then the VFX
-- asynchronously — the VFX replication Heartbeat wait must never
-- delay the press or extend the caller's claim path. Each effect
-- is independently guarded: a VFX/button failure can never mute
-- the SFX, and vice versa. Returns which effects fired
-- (vfx = dispatched; the async burst reports via the sync
-- _TestFireVfx seam in specs).
function CollectFeedback.Play(player: Player?, slot: any): { [string]: boolean }
	local result = { sfx = false, vfx = false, press = false }
	if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
		return result
	end
	if type(slot) ~= 'table' then
		return result
	end
	local typedPlayer = player :: Player
	-- 1. SFX: synchronous, first, never gated on VFX/button.
	pcall(function()
		result.sfx = _playSfx(typedPlayer)
	end)
	-- 2. Button press: synchronous, independent of SFX/VFX.
	local pressPart: BasePart? = nil
	pcall(function()
		local raw = slot.cashCollector
		if typeof(raw) == 'Instance' and (raw :: Instance):IsA('BasePart') then
			local typed = raw :: BasePart
			if typed.Parent ~= nil then
				pressPart = typed
			end
		end
		if pressPart == nil then
			return
		end
		local stand = slot.stand
		if typeof(stand) ~= 'Instance' then
			return
		end
		local buttons = StandResolver.GetButtonParts(stand)
		if buttons.base ~= nil and buttons.pressPart ~= nil then
			_pressButton(buttons.pressPart, buttons.base)
			result.press = true
		end
	end)
	-- 3. VFX: async dispatch (its internal replication catch-up
	-- must not hold the commit path). Dispatch is marked fired
	-- when the template resolves; the burst itself is guarded.
	if pressPart ~= nil then
		local target = pressPart :: BasePart
		local template = _resolveVfxTemplate()
		if template ~= nil then
			result.vfx = true
			task.spawn(function()
				_playVfx(target)
			end)
		end
	end
	return result
end

-- Warm the player's SFX pool ahead of the first collect
-- (join-time; bootstrap calls this per player). Creating the
-- pool early gives replication + asset download a head start so
-- the first success doesn't create-and-play in the same tick.
-- Idempotent; safe when PlayerGui isn't ready yet (Play
-- self-heals via _ensurePool). Never throws.
function CollectFeedback.Warm(player: Player?)
	pcall(function()
		if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
			return
		end
		local gui = (player :: Player):FindFirstChildOfClass('PlayerGui')
		if not gui then
			return
		end
		_ensurePool(gui)
	end)
end

-- Drop per-player pool rotation state (leave lifecycle).
function CollectFeedback.ForgetPlayer(userId: number)
	_nextIndex[userId] = nil
end

-- TEST-ONLY seam: ensure the SFX pool under an explicit
-- container (any Instance; production passes PlayerGui) and
-- return the member count. Lets specs assert pool size,
-- warm-idempotence, and self-healing without a player.
function CollectFeedback._TestEnsurePool(root: Instance): number
	if typeof(root) ~= 'Instance' then
		return 0
	end
	return #_ensurePool(root)
end

-- TEST-ONLY seam: play one pool member under an explicit
-- container for userId (default 0). Returns played + the member
-- name so specs assert round-robin rotation and SoundId
-- revalidation without a player.
function CollectFeedback._TestPlayPool(root: Instance, userId: number?): (boolean, string?)
	if typeof(root) ~= 'Instance' then
		return false, nil
	end
	return _playFromPool(root, userId or 0)
end

-- TEST-ONLY seam: cancel every live tween and drop cached
-- state + template refs so specs observe resolution fresh.
function CollectFeedback._TestReset()
	for _, state in pairs(_buttons) do
		_cancelLocked(state)
	end
	table.clear(_buttons)
	table.clear(_nextIndex)
	_sfxSource = nil
	_sfxSourceValid = false
	_vfxTemplate = nil
	_vfxTemplateValid = false
end

return table.freeze(CollectFeedback)
