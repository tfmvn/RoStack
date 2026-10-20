--!strict
--!native
--[[
	LevelUpPresentation
	===================
	Server-authoritative level-up celebration for Animals.

	ADD-ON to the Weight/Growth system: whenever an Animal actually
	levels up (XP threshold crossed in AddXP, or a paid upgrade in
	ApplyLevelUpgrade), the Animal plays a small happy "bop" hop and
	bursts the `ServerStorage.Assets.Vfx.Upgrade` effect around
	itself. If the Weight/Growth system reports a new target size,
	the model smoothly grows toward it first; when the Animal is
	already at MaxWeight, only the celebration plays.

	Sequence (server-driven):

	    Animal gains XP
	        ↓
	    Level increases (AnimalService, authoritative)
	        ↓
	    New Weight calculated (Weight provider, if present)
	        ↓
	    Model grows toward weight-derived size (smooth, only if
	    the calculated weight actually increased)
	        ↓
	    Procedural BOP: anticipation squash → spring/stretch
	    launch → airborne tilt → fall → landing squash → settle
	    (100% code-driven, no AnimationId/Animator/AnimationTrack)
	        ↓
    Upgrade VFX bursts around the apex (cloned, cleaned up;
    visual only — embedded Sounds are never played)
        ↓
    Owner-only AnimalLeveledUp remote fires; the owning
    client's LocalScript plays the personal LevelUp sting
    (server never plays upgrade audio — see the note above
    the celebration loop)

	ENGINE NOTE (squash & stretch honesty): Roblox's
	Model:ScaleTo() accepts a single UNIFORM number — per-axis
	model scale (X=1.04/Y=0.92/Z=1.04) is not supported by the
	API, and faking it per-part would fight the Motor6D rig
	(detached limbs on an animated rig). The squash & stretch
	read is therefore built from uniform scale pulses combined
	with vertical motion and a micro-tilt: anticipation shrink,
	launch stretch-grow, airborne tilt, landing squash, settle.
	Same cartoon language, zero rig risk.

	Trigger contract:
	  * AnimalService is the ONLY caller of NotifyLevelUp, and it
	    calls it only when a level change really happened (never on
	    a bare value change). The client never decides.
	  * Every entry point is pcall-wrapped by the caller AND
	    nil-safe internally: presentation must never break the
	    level-up or weight mutation, even when the model, the slot,
	    or the VFX asset is missing/malformed.

	Slot safety:
	  * The rest pivot is captured once per celebration and the
	    model is restored to EXACTLY that pivot at the end.
	  * Slot occupancy / SlotId / stand positioning are never
	    touched — presentation only moves the model's pivot and
	    scale, then puts them back.
	  * If the Animal is mid-walk / carried / recovering (an active
	    `animal.controller` or a non-Slotted state), positional work
	    is skipped and only the VFX plays, so we never fight the
	    WalkController or tear a carry weld.

	Concurrency:
	  * Per-animal generation counter. A new NotifyLevelUp while a
	    celebration is in flight bumps the generation: the old loop
	    exits WITHOUT restoring, and the new loop owns the restore
	    to the ORIGINAL rest pivot (kept in _rest until a loop
	    completes). Rapid multi-level grants therefore merge into
	    one controlled celebration — the Animal can never fly up
	    permanently, stack CFrame tweens, or end up offset.
	  * The ground/feet baseline (_restGround: feet world Y +
	    feet offset + ref scale) shares _rest's burst lifetime:
	    measured once by the burst starter, reused by every
	    superseding loop. Re-measuring mid-hop baked in-flight
	    lift into the restore (the Y-drift ratchet); kept values
	    keep every restore on the original ground.

	Weight hook (integration with the Weight/Growth system):
	  * SetWeightProvider(fn) registers `(animal) -> number?`.
	    The provider returns the model's new target scale (the
	    Model:GetScale()/ScaleTo space). Nil / invalid = "no growth
	    this level-up" (e.g. capped at MaxWeight) — the celebration
	    still plays.
  * Wiring: AnimalService.Init registers AnimalWeight's
    GetTargetScale as the provider — the same authoritative
    target the spawn/arrival path applies. SetWeightProvider
    remains for tests/overrides; nil provider = "no growth",
    celebration still plays.
	  * Growth is a smooth Heartbeat lerp (~0.45s) with feet planted
	    (pivot Y re-derived from the ground plane each step), never
	    an instant ScaleTo pop.

	VFX contract (`ServerStorage.Assets.Vfx.Upgrade`):
  * The asset is inspected at runtime — never assumed to be a
    ParticleEmitter. Folders/Models/Attachments/Parts are all
    accepted; every descendant ParticleEmitter is Emit()ted,
    transient lights/beams are toggled. Descendant Sounds are
    NEVER Play()ed (a Workspace sting would be audible to
    every nearby player) — they are destroyed with the clone.
	  * The original is never modified (always Clone()), the clone
	    is positioned on/around the celebrating Animal, and it is
	    removed via Debris once finished. Missing/malformed asset =
	    warn + skip, level-up still succeeds.
]]

local ServerStorage = game:GetService('ServerStorage')
local RunService = game:GetService('RunService')
local Debris = game:GetService('Debris')
local Players = game:GetService('Players')

local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local Remotes = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)
local SlotMath = require(script.Parent.SlotMath)
local StandPresentation = require(script.Parent.Parent.StandPresentation)

local LevelUpPresentation = {}

-- --- Tunables (presentation only, never authority) -------------------
-- Canonical source: VfxConfig.LevelUp. Values preserved exactly.

local _LV = VfxConfig.LevelUp

-- Growth overlaps the bop instead of preceding it (no 0.45s
-- "thinking pause"): the baseline scale eases start→target over
-- the first GROW_OVERLAP seconds of the celebration while the
-- squash/stretch multiplies around it.
local GROW_OVERLAP = _LV.Bop.GrowOverlap

-- BOP phases (total ~0.68s: quick + punchy + satisfying).
local ANTICIPATION_DURATION = _LV.Bop.AnticipationDuration -- squash down, shrink slightly
local ANTICIPATION_SQUASH = _LV.Bop.AnticipationSquash -- uniform squash multiplier
local ANTICIPATION_DIP = _LV.Bop.AnticipationDip -- dip depth (studs)
local LAUNCH_DURATION = _LV.Bop.LaunchDuration -- spring upward, stretch slightly
local LAUNCH_STRETCH = _LV.Bop.LaunchStretch -- uniform stretch multiplier
local APEX_DURATION = _LV.Bop.ApexDuration -- airborne hold + tilt sway
local FALL_DURATION = _LV.Bop.FallDuration -- fall back, scale easing to normal
local LANDING_DURATION = _LV.Bop.LandingDuration -- landing squash kiss
local LANDING_SQUASH = _LV.Bop.LandingSquash -- uniform landing multiplier
local SETTLE_DURATION = _LV.Bop.SettleDuration -- spring back to exact rest

-- Micro-tilt personality (degrees, Z-axis, relative to rest).
local TILT_TAKEOFF = _LV.Tilt.Takeoff
local TILT_APEX = _LV.Tilt.Apex
local TILT_LANDING = _LV.Tilt.Landing

-- PERF: Model:ScaleTo() re-rigs the whole model (sizes, joints,
-- bounds, replication) — the most expensive call in the
-- celebration. Frames only re-scale on meaningful change
-- (epsilon) AND at most 30/s (interval): at 170fps render-linked
-- Heartbeats, per-frame scale deltas hover right at the epsilon
-- and defeat it alone (observed 73-81 rigs/celebration pre-
-- throttle). PivotTo (cheap CFrame write) still runs every frame
-- for smooth motion. Final restores are always exact.
local SCALE_EPSILON = _LV.ScaleEpsilon
local SCALE_MIN_INTERVAL = _LV.ScaleMinInterval

local VFX_LIFETIME = _LV.Lifetime -- fallback VFX cleanup delay (s)
local VFX_CLEANUP_CAP = _LV.CleanupCap

-- --- Internal state ---------------------------------------------------

-- animalId -> generation. Bumped on every Notify/Cancel; a loop
-- whose local generation no longer matches exits immediately.
local _generation: { [string]: number } = {}
-- animalId -> rest pivot captured by the FIRST loop of a burst.
-- Kept until a loop completes its restore, so a superseding loop
-- restores to the ORIGINAL position, not a mid-air snapshot.
local _rest: { [string]: CFrame } = {}
-- animalId -> ground/feet baseline captured by the FIRST loop
-- of a burst, kept with the same lifetime as _rest.
-- DRIFT FIX: the rest pivot above was always burst-stable, but
-- the ground reference (feet world Y) and feet normalization
-- scale used to be re-captured by EVERY celebration from the
-- live pose. A celebration superseding mid-hop therefore baked
-- the in-flight lift into its "exact restore" and ratcheted
-- the animal upward on rapid upgrades. Now the whole baseline
-- (pivot + ground + feet + ref scale) is captured once per
-- burst and every frame derives visible = baseline + offset.
local _restGround: { [string]: { y: number, feet: number, sRef: number } } = {}
-- animalId -> rest SCALE captured by the FIRST loop of a burst
-- (post-growth). Every animation frame computes
-- restScale * temporaryMultiplier — multipliers are NEVER
-- accumulated, so repeated level-ups cannot inflate the animal.
-- Cleared together with _rest on completion/cancel.
local _restScale: { [string]: number } = {}
-- Explicit weight provider (SetWeightProvider). Nil = no growth.
local _weightProvider: ((any) -> number?)? = nil

-- Cached Upgrade VFX source (§6): resolved once, re-resolved
-- only if the cached ref dies (asset replaced at runtime).
-- Only the REFERENCE is cached — every level-up still Clones a
-- fresh copy; mutable instances are never reused.
local _vfxTemplate: Instance? = nil

local function _resolveUpgradeTemplate(): Instance?
	local cached = _vfxTemplate
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local assets = ServerStorage:FindFirstChild('Assets')
	local vfxRoot = assets and assets:FindFirstChild('Vfx') or nil
	local template = vfxRoot and vfxRoot:FindFirstChild(_LV.VfxAssetName) or nil
	_vfxTemplate = template
	return template
end

-- --- Weight provider ---------------------------------------------------

-- Register the Weight/Growth system's target-scale resolver.
-- `fn(animal) -> targetScale:number?`. Nil return (or any invalid
-- value) means "no growth for this level-up" — e.g. MaxWeight
-- capped — and the celebration still plays. Never throws.
function LevelUpPresentation.SetWeightProvider(fn: ((any) -> number?)?)
	if fn ~= nil and type(fn) ~= 'function' then
		return
	end
	_weightProvider = fn
end

-- Resolve the model's new target scale for this level-up. Returns
-- nil when growth must be skipped (no provider, capped weight,
-- invalid value). Never throws.
local function _resolveTargetScale(animal: any): number?
	local provider = _weightProvider
	if provider == nil then
		-- No provider wired (AnimalService.Init wires the real
		-- AnimalWeight pipeline). That is a normal "no growth"
		-- case — the celebration still plays.
		return nil
	end
	local ok, scale = pcall(provider, animal)
	if not ok or type(scale) ~= 'number' or scale ~= scale or scale == math.huge or scale <= 0 then
		return nil
	end
	return scale
end

-- --- Small helpers ---------------------------------------------------

local function _validModel(model: any): boolean
	-- NOTE: Instances are NOT Lua tables (type() returns
	-- "Instance"), so this must use typeof()/IsA().
	return typeof(model) == 'Instance' and (model :: Instance):IsA('Model') and (model :: any).Parent ~= nil
end

local function _easeOutCubic(t: number): number
	return 1 - (1 - t) ^ 3
end

local function _easeInQuad(t: number): number
	return t * t
end

local function _easeOutSine(t: number): number
	return math.sin(t * math.pi * 0.5)
end

local function _easeInOutQuad(t: number): number
	if t < 0.5 then
		return 2 * t * t
	end
	return 1 - (-2 * t + 2) ^ 2 / 2
end

-- Yield one Heartbeat. Returns false when the loop was superseded
-- (generation bumped) or the model died — the caller must exit.
local function _step(animalId: string, generation: number, model: any): boolean
	if _generation[animalId] ~= generation then
		return false
	end
	if not _validModel(model) then
		return false
	end
	RunService.Heartbeat:Wait()
	if _generation[animalId] ~= generation then
		return false
	end
	if not _validModel(model) then
		return false
	end
	return true
end

-- True when positional presentation is safe: the animal record
-- still points at this model, nothing is driving it (no walk /
-- carry controller), and it is resting on its slot.
--
-- Liveness-aware (not just non-nil): a FINISHED controller must
-- not block. WalkController marks stopped=true on completion and
-- CarryController marks running=false on Stop; either flag means
-- "parked handle, nobody is driving". An unknown handle shape
-- stays blocking (safe default). This keeps the guard correct
-- even if a future path forgets to clear the fields on arrival.
local function _controllerIsDriving(animal: any): boolean
	local c = animal.controller
	if c == nil then
		return false
	end
	if type(c) ~= 'table' then
		return true
	end
	if c.stopped == true then
		return false
	end
	if c.running == false then
		return false
	end
	return true
end

local function _canMovePivot(animal: any, model: any): boolean
	if type(animal) ~= 'table' then
		return false
	end
	if animal.model ~= model then
		return false
	end
	if _controllerIsDriving(animal) then
		return false
	end
	local state = animal.state
	if state ~= 'Slotted' and state ~= 'Placed' then
		return false
	end
	return true
end

-- --- Upgrade VFX -------------------------------------------------------

-- Play the Upgrade VFX around `model`. Inspects the actual asset
-- structure (Folder / Model / Attachment / Emitter / Part ...),
-- clones it, positions the clone on the animal, fires one-shot
-- playback, and schedules cleanup. Missing/malformed asset (or any
-- runtime failure) warns and returns — never throws.
function LevelUpPresentation.PlayUpgradeVfx(model: any)
	local ok = pcall(function()
		if not _validModel(model) then
			return
		end
		local assets = ServerStorage:FindFirstChild('Assets')
		local vfxRoot = assets and assets:FindFirstChild('Vfx') or nil
		local template = _resolveUpgradeTemplate()
		if not template then
			-- Loud miss diagnostic: inventory what DOES exist so
			-- a moved/renamed Studio asset is obvious from logs
			-- (the #1 suspect when "VFX never plays").
			local assetNames = {}
			if assets then
				for _, child in ipairs(assets:GetChildren()) do
					assetNames[#assetNames + 1] = child.Name .. ':' .. child.ClassName
				end
			end
			local vfxNames = {}
			if vfxRoot then
				for _, child in ipairs(vfxRoot:GetChildren()) do
					vfxNames[#vfxNames + 1] = child.Name .. ':' .. child.ClassName
				end
			end
			Debug.Warn('LV', 'PlayUpgradeVfx: ServerStorage.Assets.Vfx.Upgrade missing — skipping VFX', {
				hasAssets = tostring(assets ~= nil),
				assetsChildren = table.concat(assetNames, ', '),
				hasVfx = tostring(vfxRoot ~= nil),
				vfxChildren = table.concat(vfxNames, ', '),
			})
			return
		end
		local clone = template:Clone()
		-- Asset discovery proof (§1/§10): measured on the SOURCE
		-- template (never on the clone — re-homing below moves
		-- nodes OUT of the clone, so clone counts would lie).
		local templateDescendants = #template:GetDescendants()
		Debug.Log('LV', 'Upgrade VFX asset', {
			class = template.ClassName,
			descendants = tostring(templateDescendants),
		})

		-- Anchor point: PrimaryPart center, else model pivot.
		local anchorCFrame: CFrame = model:GetPivot()
		local okPivot, pivot = pcall(function()
			return model:GetPivot()
		end)
		if okPivot and typeof(pivot) == 'CFrame' then
			anchorCFrame = pivot
		end
		local primary = model.PrimaryPart
		if primary and primary:IsA('BasePart') then
			anchorCFrame = primary.CFrame
		end

		-- Mount the clone on the ANIMAL so the effect rides it.
		-- Attachments only resolve to a world position under a
		-- BasePart (or another attachment under one) — an
		-- Attachment sitting in a bare Folder/Model container
		-- would emit at the wrong place. So: parent the container
		-- to the model, then RE-HOME every Attachment and every
		-- container-direct emitter/sound onto the PrimaryPart,
		-- preserving authored local offsets. The production shape
		-- (Upgrade Folder → Attachment → 15 ParticleEmitters)
		-- ends up as PrimaryPart → Attachment → emitters, with
		-- the Attachment's authored Position/Orientation intact
		-- (never reset, never replaced — §7/§8).
		--
		-- ORDER MATTERS (the actual VFX bug, fixed): playable
		-- refs are collected BEFORE re-homing. Reparenting does
		-- not invalidate Instance refs, but scanning the clone
		-- AFTER the move finds an empty husk (the Attachment
		-- took the emitters with it) — which is exactly how the
		-- "descendants=0" misdiagnosis happened.
		clone.Parent = model
		if clone:IsA('Model') then
			local okPlace = pcall(function()
				(clone :: Model):PivotTo(anchorCFrame)
			end)
			if not okPlace then
				Debug.Warn('LV', 'PlayUpgradeVfx: could not PivotTo Model clone — leaving at authored offset')
			end
		elseif clone:IsA('BasePart') then
			pcall(function()
				(clone :: BasePart).Anchored = true
				(clone :: BasePart).CanCollide = false
				(clone :: BasePart).CFrame = anchorCFrame
			end)
		elseif clone:IsA('Attachment') then
			if primary and primary:IsA('BasePart') then
				clone.Parent = primary
			end
		end
		-- Collect ALL playables first (refs survive the move).
		-- SINGLE descendants scan: playables and re-home
		-- candidates are classified in one pass (the old code
		-- scanned the clone twice per level-up).
		local playables: { Instance } = {}
		-- One engine query: the descendant array is captured
		-- once and reused for both classification passes below
		-- (GetDescendants walks the hierarchy; calling it twice
		-- per level-up doubled that cost).
		local cloneDescendants: { Instance } = {}
		if not (clone:IsA('ParticleEmitter') or clone:IsA('Sound')) then
			cloneDescendants = clone:GetDescendants()
		end
		if clone:IsA('ParticleEmitter') or clone:IsA('Sound') then
			playables[#playables + 1] = clone
		else
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
		end
		-- Nodes moved OUT of the clone need their own Debris
		-- entry (Debris on the clone cannot reach them anymore).
		-- Without this, every level-up permanently accumulates
		-- an Attachment + emitters on the animal.
		local movedOut: { Instance } = {}
		-- Attachments that define the burst origin (for visible
		-- placement below): the re-homed ones, plus the clone
		-- itself when the asset IS an attachment.
		local burstAttachments: { Attachment } = {}
		if clone:IsA('Attachment') then
			burstAttachments[#burstAttachments + 1] = clone
		end
		if primary and primary:IsA('BasePart') then
			local host = primary
			for _, descendant in ipairs(cloneDescendants) do
				if descendant:IsA('Attachment') then
					-- Only re-home attachments that are NOT already
					-- under a BasePart (those resolve correctly).
					-- The EXISTING cloned attachment is reused as-is
					-- (§2: never create a replacement).
					local p = descendant.Parent
					if not (p and p:IsA('BasePart')) then
						descendant.Parent = host
						movedOut[#movedOut + 1] = descendant
						burstAttachments[#burstAttachments + 1] = descendant
					end
				elseif descendant:IsA('ParticleEmitter') or descendant:IsA('Sound') then
					local p = descendant.Parent
					if not (p and (p:IsA('BasePart') or p:IsA('Attachment'))) then
						descendant.Parent = host
						movedOut[#movedOut + 1] = descendant
					end
				end
			end
		end
		-- Place the burst ON the animal: visible center-top, as a
		-- child of the animal at the animal's position (per the
		-- reporter's requirement). The authored Studio offset was
		-- relative to a standalone preview — kept as-is it buries
		-- the emitters INSIDE the animal mesh, where opaque parts
		-- occlude every particle. Orientation is preserved; only
		-- the world position is re-anchored. Falls back to the
		-- PrimaryPart center when the size query fails.
		local burstPos: Vector3? = nil
		if primary and primary:IsA('BasePart') and #burstAttachments > 0 then
			local upOffset = _LV.BurstDefault
			local okExt, extents = pcall(function()
				return (model :: Model):GetExtentsSize()
			end)
			if okExt and typeof(extents) == 'Vector3' then
				upOffset = math.clamp(extents.Y * 0.5 + 0.5, _LV.BurstMin, _LV.BurstMax)
			end
			burstPos = primary.Position + Vector3.new(0, upOffset, 0)
			for _, attachment in ipairs(burstAttachments) do
				pcall(function()
					local wc = attachment.WorldCFrame
					attachment.WorldCFrame = CFrame.new(burstPos :: Vector3) * (wc - wc.Position)
				end)
			end
		end
		-- Replication catch-up: the attachment + emitters are brand
		-- new instances. Emitting in the SAME tick as parenting
		-- lets clients miss a same-tick burst for not-yet-known
		-- instances. One Heartbeat closes that race; the delay is
		-- imperceptible inside the ~1.1s celebration.
		RunService.Heartbeat:Wait()

		-- One-shot playback of the COLLECTED playables (valid
		-- wherever they now live). Every emitter fires — never
		-- just the first (§3). Rate == 0 is fine: one-shot
		-- effects still Emit (§5). Counts stay small: each
		-- emitter emits clamp(rate, 8, 48), default 24 (§6).
		-- Nothing authored is modified — only triggered (§4).
		local longestLifetime = 0
		local emitterCount = 0
		local emittedTotal = 0
		local function fireDescendant(inst: Instance)
			if inst:IsA('ParticleEmitter') then
				emitterCount += 1
				local emitter = inst :: ParticleEmitter
				-- Burst count = the emitter's OWN authored Rate,
				-- fired exactly once. No invented constants, no
				-- clamps: the Studio authoring is the source of
				-- truth for density. The floor of 1 is structural,
				-- not aesthetic — Emit(0) is a no-op, so a Rate-0
				-- one-shot emitter still puffs once.
				local count = 1
				local okRate, rate = pcall(function()
					return emitter.Rate
				end)
				if okRate and type(rate) == 'number' and rate == rate then
					count = math.max(1, math.floor(rate + 0.5))
				end
				local okEmit = pcall(function()
					emitter:Emit(count)
				end)
				if okEmit then
					emittedTotal += count
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
				-- Upgrade VFX Sounds are NEVER played: this clone
				-- lives in Workspace, so a sting here is audible to
				-- every nearby player. The burst visuals stay
				-- global; the upgrading player's personal sting
				-- plays on their client (AnimalLeveledUp remote).
				-- Destroyed (not merely skipped) so an authored
				-- PlayOnRemove can never sound it at cleanup.
				pcall(function()
				(inst :: Sound):Destroy()
			end)
			elseif inst:IsA('PointLight') or inst:IsA('SpotLight') or inst:IsA('SurfaceLight') then
			local light = inst :: PointLight
			local wasEnabled = light.Enabled
			light.Enabled = true
			task.delay(math.min(VFX_LIFETIME, VFX_CLEANUP_CAP), function()
				if light and light.Parent then
					light.Enabled = wasEnabled
				end
			end)
			elseif inst:IsA('Beam') then
				local beam = inst :: Beam
				local wasEnabled = beam.Enabled
				beam.Enabled = true
				task.delay(math.min(VFX_LIFETIME, VFX_CLEANUP_CAP), function()
					if beam and beam.Parent then
						beam.Enabled = wasEnabled
					end
				end)
			end
		end
		if clone:IsA('ParticleEmitter') or clone:IsA('Sound') then
			fireDescendant(clone)
		else
			for _, playable in ipairs(playables) do
				fireDescendant(playable)
			end
		end

		local lifetime = math.clamp(
			longestLifetime + _LV.CloneCleanupPadding,
			_LV.CloneCleanupMin,
			VFX_LIFETIME + _LV.CloneCleanupMaxPad
		)
		Debris:AddItem(clone, lifetime)
		for _, moved in ipairs(movedOut) do
			Debris:AddItem(moved, lifetime)
		end
		if emitterCount == 0 then
			Debug.Warn('LV', 'PlayUpgradeVfx: no playable emitter found — investigate asset reference/path', {
				templateClass = template.ClassName,
				templateDescendants = tostring(templateDescendants),
				collected = tostring(#playables),
			})
		else
			Debug.Log('LV', 'vfx played', {
				templateClass = template.ClassName,
				templateDescendants = tostring(templateDescendants),
				emitters = tostring(emitterCount),
				emitted = tostring(emittedTotal),
				lifetimeMax = ('%.2f'):format(longestLifetime),
				burstPos = burstPos ~= nil and ('%.1f, %.1f, %.1f'):format(burstPos.X, burstPos.Y, burstPos.Z)
					or 'authored',
			})
		end
	end)
	if not ok then
		Debug.Warn('LV', 'PlayUpgradeVfx failed gracefully (level-up unaffected)')
	end
end

-- --- Level-up audio: PERSONAL (client-side) -------------------------------
--
-- The upgrade sting is PERSONAL: only the upgrading player may
-- hear it. An earlier design played it here on the server —
-- first as a per-upgrade Workspace clone, later as a
-- persistent `LevelUpSfx` Sound on the animal model. Both
-- variants lived in Workspace, so EVERY nearby player heard
-- EVERY other player's upgrades. That whole server-side audio
-- path is deleted (no Ensure/Play helpers remain in this
-- module; AnimalService no longer provisions model Sounds).
--
-- Current flow (no RollOff hacks, no FireAllClients):
--   server: NotifyLevelUp validates + celebrates (BOP/VFX stay
--     global visuals) and FireClients ONLY the owner via the
--     existing AnimalLeveledUp remote (already owner-only).
--   client: SlotMenuController plays the LevelUp template
--     locally (PlayerGui clone) on that remote — one listener
--     per player, real-level-increase gating from the
--     OldLevel/NewLevel payload.
-- The server NEVER calls :Play() on upgrade audio.

-- NOTE: the server-side upgrade-audio helpers
-- (EnsureLevelUpSfx / PlayLevelUpSfx) were removed here. The
-- sting is personal and now plays on the owning client (see
-- the note above + SlotMenuController).

-- --- Celebration loop ---------------------------------------------------

-- Internal: run growth + bop + VFX for one level-up burst.
-- Owns the restore to the exact rest pivot AND rest scale when
-- its generation survives. A superseded loop exits without
-- touching the model. Visuals only — upgrade audio is personal
-- and plays on the owning client (see the note above).
local function _runCelebration(animal: any, animalId: string, generation: number)
	local tCeleb = os.clock()
	local scaleToCalls = 0
	-- Start latency (§1 proof): Notify → first visible pose.
	local firstPoseMs: number? = nil
	local model = animal.model
	if not _validModel(model) then
		_rest[animalId] = nil
		_restScale[animalId] = nil
		_restGround[animalId] = nil
		return
	end

	-- Defensive: StandPresentation is the EGG-ONLY slot-idle
	-- wobble and animals are never bound to it, so this Hold is
	-- a no-op for animals. Kept so the celebration never fights
	-- a presentation loop even if binding rules change.
	StandPresentation.Hold(model, 1.4)

	-- Quantized scaler: skips redundant ScaleTo calls (see
	-- SCALE_EPSILON / SCALE_MIN_INTERVAL). Shared by growth + bop
	-- so the whole burst pays for distinct scales only.
	local lastAppliedScale: number? = nil
	local lastScaleTime = 0
	local function _applyScale(s: number): boolean
		if lastAppliedScale ~= nil then
			if math.abs(s - lastAppliedScale) < SCALE_EPSILON then
				return true
			end
			if os.clock() - lastScaleTime < SCALE_MIN_INTERVAL then
				return true
			end
		end
		local ok = pcall(function()
			(model :: Model):ScaleTo(s)
		end)
		if ok then
			lastAppliedScale = s
			lastScaleTime = os.clock()
			scaleToCalls += 1
		end
		return ok
	end

	-- Rest pivot: the ORIGINAL captured position for this burst
	-- (kept across superseding loops), else the current pivot.
	local restPivot: CFrame = _rest[animalId] or model:GetPivot()
	_rest[animalId] = restPivot

	local movable = _canMovePivot(animal, model)

	-- Weight target, resolved ONCE up front (cheap pure math —
	-- no model queries, no waits). Growth does NOT run as a
	-- blocking pre-phase (that was a 0.45s "thinking pause"
	-- before any visible motion); the baseline eases
	-- start→target DURING the bop via _currentBase() below, so
	-- the first visible pose lands within frames of Notify.
	local startScale: number = 1
	do
		local okS, s = pcall(function()
			return (model :: Model):GetScale()
		end)
		if okS and type(s) == 'number' and s > 0 then
			startScale = s
		end
	end
	local restScale: number = _restScale[animalId] or startScale
	local growthActive = false
	if movable then
		local targetScale = _resolveTargetScale(animal)
		if targetScale ~= nil and targetScale > startScale + 1e-4 then
			restScale = targetScale
			growthActive = true
		end
	end
	_restScale[animalId] = restScale

	-- Time-varying baseline: start → rest over the first
	-- GROW_OVERLAP seconds of the celebration. Poses use
	-- base × multiplier, so growth and squash/stretch compose
	-- instead of fighting. Final restore uses restScale exactly.
	local function _currentBase(): number
		if not growthActive then
			return restScale
		end
		local t = math.clamp((os.clock() - tCeleb) / GROW_OVERLAP, 0, 1)
		return startScale + (restScale - startScale) * _easeInOutQuad(t)
	end

	-- Refresh movability: resolution above never moved the model.
	movable = _validModel(model) and _canMovePivot(animal, model)

	-- Feet-plane reference: the BURST baseline (first loop
	-- measures, superseding loops reuse). Measuring per
	-- celebration reads the live mid-hop pose AND mid-squash
	-- scale, which is exactly the Y-drift ratchet: kept values
	-- keep every restore on the original ground.
	local feetOffset = 0
	local sRef = startScale
	local groundBottomY = 0
	do
		local kept = _restGround[animalId]
		if kept ~= nil then
			feetOffset = kept.feet
			sRef = kept.sRef
			groundBottomY = kept.y
		else
			local okFeet, off = pcall(SlotMath.FeetOffsetBelowPrimary, model)
			if okFeet and type(off) == 'number' then
				feetOffset = off
			end
			local pivotNow: CFrame = model:GetPivot()
			groundBottomY = pivotNow.Y + feetOffset
			_restGround[animalId] = { y = groundBottomY, feet = feetOffset, sRef = sRef }
		end
	end
	local restRot: CFrame = restPivot - restPivot.Position

	-- Hop height scales gently with model size so tiny and huge
	-- animals both read as a "small celebratory hop".
	local hopHeight = 1.0
	do
		local okExt, extents = pcall(function()
			return (model :: Model):GetExtentsSize()
		end)
		if okExt and typeof(extents) == 'Vector3' then
			hopHeight = math.clamp(extents.Y * 0.35, 0.6, 1.6)
		end
	end

	-- One BOP pose: uniform scale pulse + vertical lift + micro
	-- tilt, all relative to the captured rest transform. Returns
	-- false when the pose could not be applied.
	local function _applyBopPose(mult: number, lift: number, tiltDeg: number): boolean
		if not _validModel(model) then
			return false
		end
		local s = _currentBase() * mult
		if firstPoseMs == nil then
			firstPoseMs = (os.clock() - tCeleb) * 1000
		end
		if not _applyScale(s) then
			return false
		end
		local ok = pcall(function()
			(model :: Model):PivotTo(
				CFrame.new(restPivot.X, groundBottomY - feetOffset * (s / sRef) + lift, restPivot.Z)
					* restRot
					* CFrame.Angles(0, 0, math.rad(tiltDeg))
			)
		end)
		return ok
	end

	-- One timed phase. fn(t) poses each Heartbeat with t in
	-- [0, 1]. Returns 'done' | 'superseded' | 'blocked' (blocked =
	-- the animal started walking / was grabbed mid-phase).
	local function _runPhase(duration: number, fn: (number) -> ()): string
		local start = os.clock()
		while true do
			if not _step(animalId, generation, model) then
				return 'superseded'
			end
			if not _canMovePivot(animal, model) then
				return 'blocked'
			end
			local t = math.clamp((os.clock() - start) / duration, 0, 1)
			local okPhase = pcall(fn, t)
			if not okPhase then
				return 'blocked'
			end
			if t >= 1 then
				return 'done'
			end
		end
	end

	-- BOP + VFX launch TOGETHER at t=0: the VFX burst fires
	-- first so its one-frame replication catch-up overlaps the
	-- anticipation dip, and the apex lands inside the
	-- particles. VFX ALWAYS plays (global visual) — even when
	-- positional work is unsafe, it is model-mounted and
	-- follows the animal. Audio NEVER plays here (personal —
	-- owning client only, via the AnimalLeveledUp remote).
	local tVfx = os.clock()
	LevelUpPresentation.PlayUpgradeVfx(model)
	local msVfx = (os.clock() - tVfx) * 1000

	local status = 'done'
	if movable then
		-- PHASE 1 — ANTICIPATION (~0.10s): squash + dip.
		status = _runPhase(ANTICIPATION_DURATION, function(t: number)
			local e = _easeInQuad(t)
			_applyBopPose(1 + (ANTICIPATION_SQUASH - 1) * e, -ANTICIPATION_DIP * e, 0)
		end)
	else
		status = 'blocked'
	end

	if status == 'done' then
		-- PHASE 2 — LAUNCH (~0.16s): stretch + spring up + takeoff
		-- tilt, ease-out for a snappy rise.
		status = _runPhase(LAUNCH_DURATION, function(t: number)
			local e = _easeOutCubic(t)
			_applyBopPose(
				ANTICIPATION_SQUASH + (LAUNCH_STRETCH - ANTICIPATION_SQUASH) * e,
				-ANTICIPATION_DIP + (hopHeight + ANTICIPATION_DIP) * e,
				TILT_TAKEOFF * e
			)
		end)
	end
	if status == 'done' then
		-- PHASE 3 — APEX (~0.06s): airborne hold, tilt sways to
		-- the other side, tiny bob.
		status = _runPhase(APEX_DURATION, function(t: number)
			_applyBopPose(
				LAUNCH_STRETCH + (1.03 - LAUNCH_STRETCH) * t,
				hopHeight + 0.05 * math.sin(t * math.pi),
				TILT_TAKEOFF + (TILT_APEX - TILT_TAKEOFF) * t
			)
		end)
	end
	if status == 'done' then
		-- PHASE 4 — FALL (~0.18s): ease back to resting scale
		-- while descending, tilt drifts toward landing.
		status = _runPhase(FALL_DURATION, function(t: number)
			local e = _easeInQuad(t)
			_applyBopPose(1.03 + (1 - 1.03) * e, hopHeight * (1 - e), TILT_APEX + (TILT_LANDING - TILT_APEX) * e)
		end)
	end
	if status == 'done' then
		-- PHASE 5 — LANDING (~0.08s): squash kiss on touchdown.
		status = _runPhase(LANDING_DURATION, function(t: number)
			local kiss = math.sin(t * math.pi)
			_applyBopPose(1 + (LANDING_SQUASH - 1) * kiss, -ANTICIPATION_DIP * 0.75 * kiss, TILT_LANDING * (1 - t))
		end)
	end
	if status == 'done' then
		-- PHASE 6 — SETTLE (~0.10s): one breath back to exact
		-- rest (mult ends at exactly 1).
		status = _runPhase(SETTLE_DURATION, function(t: number)
			_applyBopPose(1 + 0.02 * math.sin(t * math.pi), 0, 0)
		end)
	end

	if status == 'superseded' then
		-- A newer celebration owns the restore. Exit WITHOUT
		-- touching the model — never leave competing writers.
		return
	end

	-- Restore the EXACT resting state. Scale is always safe to
	-- restore (it never moves the animal); the pivot is restored
	-- only when nothing else is driving the model (a mid-bop grab
	-- or walk owns positioning from here — its own settle flow
	-- re-places the animal). The pivot Y is re-derived from the
	-- ground plane at the REST scale (overlap growth means the
	-- captured restPivot.Y predates the grown stance).
	if _generation[animalId] == generation and _validModel(model) then
		if status == 'done' and _canMovePivot(animal, model) then
			pcall(function()
				(model :: Model):ScaleTo(restScale);
				(model :: Model):PivotTo(
					CFrame.new(restPivot.X, groundBottomY - feetOffset * (restScale / sRef), restPivot.Z) * restRot
				)
			end)
		elseif animal.model == model then
			pcall(function()
				(model :: Model):ScaleTo(restScale)
			end)
		end
	end
	if _generation[animalId] == generation then
		_rest[animalId] = nil
		_restScale[animalId] = nil
		_restGround[animalId] = nil
		-- Defensive Rebase: animals are never bound to the
		-- egg-only StandPresentation, so this is a no-op.
		-- Kept so a post-growth baseline re-sync happens even
		-- if binding rules change.
		if status == 'done' then
			StandPresentation.Rebase(model)
		end
		-- Lightweight profiling (one line per celebration, same
		-- verbosity as the per-upgrade UP/EC lines): total burst
		-- time, VFX setup time, ScaleTo call count, and START
		-- LATENCY (Notify → first visible pose — the §1 number).
		Debug.Log('LV', 'celebration done', {
			animalId = animalId,
			msTotal = ('%.1f'):format((os.clock() - tCeleb) * 1000),
			msVfx = ('%.1f'):format(msVfx),
			msToFirstPose = firstPoseMs ~= nil and ('%.1f'):format(firstPoseMs) or 'n/a',
			scaleToCalls = tostring(scaleToCalls),
		})
	end
end

-- --- Public API ----------------------------------------------------------

-- Server-authoritative level-up trigger. Call ONLY from the real
-- level-up mutation (AddXP threshold cross / ApplyLevelUpgrade).
-- `info` = { oldLevel: number, newLevel: number, levelsGained: number }.
-- Merges rapid grants: a celebration already in flight is superseded
-- and the new burst restores to the original rest pivot. Never
-- throws, never yields the caller (spawns its own thread).
function LevelUpPresentation.NotifyLevelUp(animal: any, info: any)
	local ok = pcall(function()
		if type(animal) ~= 'table' or type(animal.uniqueId) ~= 'string' then
			return
		end
		local animalId: string = animal.uniqueId
		local oldLevel = info and info.oldLevel or nil
		local newLevel = info and info.newLevel or animal.Level
		local levelsGained = info and info.levelsGained or 1
		if type(newLevel) ~= 'number' or type(oldLevel) ~= 'number' then
			-- Level unknown (should not happen from the
			-- authoritative call sites) — still celebrate the
			-- event rather than dropping feedback, but keep the
			-- remote payload honest.
			oldLevel = nil
		end

		_generation[animalId] = (_generation[animalId] or 0) + 1
		local generation = _generation[animalId]
		Debug.Log('LV', 'notify', {
			animalId = animalId,
			oldLevel = tostring(oldLevel),
			newLevel = tostring(newLevel),
			hasModel = tostring(typeof(animal.model) == 'Instance'),
		})

		-- Fire the client event (HUD/toast hook). Best-effort:
		-- a missing Remotes folder must never break the server
		-- celebration.
		pcall(function()
			local ownerId = animal.ownerUserId
			if type(ownerId) == 'number' then
				local player = Players:GetPlayerByUserId(ownerId)
				if player then
					Remotes.FireClient(player, Remotes.Names.AnimalLeveledUp, {
						AnimalId = animalId,
						SlotId = animal.slotId,
						OldLevel = oldLevel,
						NewLevel = newLevel,
						LevelsGained = levelsGained,
					})
				end
			end
		end)

		task.spawn(function()
			-- The celebration is visuals-only. The personal
			-- sting plays on the owning client (AnimalLeveledUp
			-- remote, gated on real level increase there from
			-- this same OldLevel/NewLevel state).
			local okRun, err = pcall(_runCelebration, animal, animalId, generation)
			if not okRun then
				Debug.Warn('LV', 'celebration failed gracefully (level-up unaffected)', {
					animalId = animalId,
					error = tostring(err),
				})
				if _generation[animalId] == generation then
					_rest[animalId] = nil
					_restScale[animalId] = nil
					_restGround[animalId] = nil
				end
			end
		end)
	end)
	if not ok then
		Debug.Warn('LV', 'NotifyLevelUp failed gracefully (level-up unaffected)')
	end
end

-- Cancel any in-flight celebration for `animalId` (destroy /
-- cleanup / rejoin paths). The superseded loop exits without
-- touching the model. Never throws.
function LevelUpPresentation.Cancel(animalId: string)
	pcall(function()
		if type(animalId) == 'string' then
			_generation[animalId] = (_generation[animalId] or 0) + 1
			_rest[animalId] = nil
			_restScale[animalId] = nil
			_restGround[animalId] = nil
		end
	end)
end

-- TEST-ONLY seam: read the current generation (specs assert merge
-- behavior without spawning models). Returns 0 when untouched.
function LevelUpPresentation._TestGeneration(animalId: string): number
	if type(animalId) ~= 'string' then
		return 0
	end
	return _generation[animalId] or 0
end

-- TEST-ONLY seam: expose the controller-liveness check so specs
-- lock the Bug-1 contract (a FINISHED walk handle must not block
-- the bop; an ACTIVE carry handle must).
function LevelUpPresentation._TestIsDriving(animal: any): boolean
	if type(animal) ~= 'table' then
		return false
	end
	return _controllerIsDriving(animal)
end

return table.freeze(LevelUpPresentation)
