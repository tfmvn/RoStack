--!strict
--!native
--[[
	Egg.RollController
	=========================
	The 3D roulette / reveal animation that runs at the lucky
	egg's location between `HatchEgg` entering `Opening` and
	`AnimalService.CreateFromEgg` spawning the animal.

	What it does
	------------
	* Cycles through `RollPreviewCount` animal previews
	  (3D world-space, ONE model visible at a time). The
	  LAST preview is the actual winner; the prior (N-1) are
	  decoys drawn from the ROLLED RARITY's bucket only. See
	  `PickOrder` for the pool rule.
	* Each preview's interval follows an ARITHMETIC progression
	  (linear deceleration): the first decoy uses
	  `RollFirstDecoyIntervalSeconds` (a sub-frame fast
	  flash), and each subsequent decoy is a constant STEP
	  longer. The step is solved from the total duration
	  so the sum of decoy intervals equals exactly
	  (totalDuration - winnerDwell), making the WHOLE ROLL
	  take exactly `RollTotalDurationSeconds` regardless
	  of preview count. The perception: a true constant
	  deceleration -- fast at start, slow at end, no curve.
	* Within each interval, the preview scales
	  `RollEntryScale -> 1.0 -> RollExitScale` (a quick pop-in
	  then a long dissolve), then is destroyed. Only the
	  winner is exempt from the dissolve; it stops at 1.0 and
	  STAYS visible at `winnerCFrame` (the same CFrame
	  `CreateFromEgg` uses for its animal spawn -- no
	  visible teleport at the handoff).
	* The controller fires `_onComplete` once the winner is
	  fully revealed. `HatchEgg` then calls `CreateFromEgg`
	  with the winner's defId, and consumes the roulette's
	  winner model after the handoff.

	Patterns mirrored
	-----------------
	* FlightController's per-tick Heartbeat shape.
	* `HoverMath` -- the pure-function export pattern for
	  tests. Mirrored by `RollController.PickOrder`.
	* FlightController._onComplete -- the callback-driven
	  handoff shape.
	* The `_aborted` / `stopped` dual-flag cleanup pattern
	  used by every other controller.

 	Why no `TweenService`
 	---------------------
 	The codebase convention is `RunService.Heartbeat` +
 	`model:PivotTo()` / `model:ScaleTo()`. `ScaleTo` is a
 	synchronous engine API (one call per tick); `TweenService`
 	never appears anywhere in the project.

  	Roll audio (Pop per transition + Reward on reveal)
  	--------------------------------------------------
  	Presentation-only, inside this same update loop — no new
  	Heartbeat, no timers, no per-frame audio logic. At Start,
  	a bounded Pop pool is prepared on an invisible anchor part
  	at the roll location (3D positional, per-roll isolated,
  	destroyed with the pool folder), and the Reward SOURCE is
  	cached. Each preview SHOW plays exactly one Pop in the
  	same tick as its first pose. The canonical
  	RevealFinalAnimal event (called by HatchEgg right after
  	the authoritative commit) plays Reward into the hatching
  	player's PlayerGui exactly once — so Reward, rarity VFX,
  	and the already-visible real animal land together.
  	Missing assets degrade to mute (session-once warn); audio
  	never blocks or breaks the hatch.
  ]]

local RunService = game:GetService('RunService')
local ContentProvider = game:GetService('ContentProvider')
local ServerStorage = game:GetService('ServerStorage')
local Players = game:GetService('Players')
local Debris = game:GetService('Debris')
local Constants = require(script.Parent.Constants)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local SlotMath = require(script.Parent.Parent.Animal.SlotMath)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)
local DebugConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local HoverMath = require(script.Parent.HoverMath)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local AudioGroups = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)

local RollController = {}

-- --- State ------------------------------------------------------

export type RollController = {
	egg: any,
	rarity: string,
	winnerDefId: string,
	winnerRarity: string,
	defIds: { string },
	finalIndex: number,
	startedAt: number,
	duration: number,
	currentStep: number,
	candidateEnteredAt: number?,
	currentCandidate: Model?,
	winnerModel: Model?,
	rouletteCFrame: CFrame,
	winnerCFrame: CFrame,
	templates: { [string]: Model }?,
	pool: { [string]: Model }?,
	poolOrder: { string }?,
	candidatesFolder: Folder?,
	stopped: boolean,
	aborted: boolean,
	_onComplete: ((RollController) -> ())?,
	-- PERF cursors (quantized scale + cached feet offset;
	-- per-controller so concurrent rolls never cross-talk).
	_lastScale: number?,
	_lastScaleModel: Model?,
	_feetOffset: number?,
	_feetOffsetModel: Model?,
	-- ROLL AUDIO cursors (per-controller so concurrent rolls
	-- never share pool state; Pop instances live under the
	-- roll's pool folder and die with it; Reward source is
	-- cached for the commit-time player-targeted clone).
	_audioAnchor: BasePart?,
	_popPool: { Sound }?,
	_popPoolIdx: number?,
	_rewardSource: Sound?,
	-- Reveal once-flag (RevealFinalAnimal; state identity, not
	-- timing — duplicate handoff callbacks can never refire).
	_revealPlayed: boolean?,
}

-- --- Pure helper: spin order ------------------------------------

-- Builds the spin order. Pure function (no engine state) so
-- tests can drive it with a fixed RNG and assert the result.
-- The decoy pool is cross-rarity (every defId in the catalog
-- except the winner), so the rolled rarity is intentionally
-- NOT a parameter here -- the winner's rarity is looked up
-- from the catalog.
--
-- * `winnerDefId` -- the defId HatchEgg committed to. The
--   last element of the returned list is always this.
-- * `rng` -- optional `() -> number` returning [0, 1). When
--   nil, falls back to `Random.new():NextNumber()` per the
--   existing pattern in `AnimalConfig.GetRandom`.
--
-- Returns `{ defIds = {...}, finalIndex = N }` where N is
-- the index of the last element (= #defIds).
function RollController.PickOrder(winnerDefId: string, rng: (() -> number)?): { defIds: { string }, finalIndex: number }
	-- Resolve the rolled rarity from the winner's defId. The
	-- rolled rarity IS the winner's rarity in the current
	-- flow (EggService rolls a defId from the rolled
	-- rarity's bucket and passes that defId as winnerDefId).
	-- We use the rolled rarity to look up the HatchRollWeights
	-- column that drives the decoy draw.
	local rolledRarity: string? = nil
	for r, bucket in pairs(AnimalConfig.Catalog) do
		if bucket and bucket[winnerDefId] then
			rolledRarity = r
			break
		end
	end
	assert(rolledRarity, ('RollController.PickOrder: winnerDefId "%s" not in catalog'):format(tostring(winnerDefId)))

	-- Build a per-rarity defId index. The weighted draw picks
	-- a rarity, then a defId from that rarity's bucket. The
	-- winner can appear in decoy slots (slot-machine feel) --
	-- the FINAL slot is always the actual reveal.
	local bucketIds: { [string]: { string } } = {}
	for rarity, bucket in pairs(AnimalConfig.Catalog) do
		if bucket then
			bucketIds[rarity] = {}
			for defId in pairs(bucket) do
				bucketIds[rarity][#bucketIds[rarity] + 1] = defId
			end
		end
	end
	-- Sort each bucket so the rng-driven picks are
	-- deterministic for tests (otherwise the hash order of
	-- pairs() leaks into the play sequence).
	for _rarity, ids in pairs(bucketIds) do
		table.sort(ids)
	end

	-- rng setup. Used by the weighted rarity pick and the
	-- within-bucket defId pick. The fallback (no rng passed)
	-- is a per-call Random seeded from os.clock -- distinct
	-- from the reference RouletteService's pattern but
	-- equally valid for a per-roll sequence.
	local fallbackRng = Random.new(os.clock() * 1e6)
	local effectiveRng = rng or function()
		return fallbackRng:NextNumber()
	end

	-- Find a non-empty fallback bucket for the case where the
	-- rolled rarity's bucket is empty (1-defId rarity) or the
	-- weighted pick lands on a 0-weight / empty bucket. We
	-- prefer the rolled rarity, then any non-empty bucket.
	local function _pickFallbackBucket(): { string }?
		if bucketIds[rolledRarity] and #bucketIds[rolledRarity] > 0 then
			return bucketIds[rolledRarity]
		end
		for _, ids in pairs(bucketIds) do
			if #ids > 0 then
				return ids
			end
		end
		return nil
	end

	-- Pick a rarity from the HatchRollWeights column for the
	-- rolled rarity. Cumulative distribution: sum all weights,
	-- roll once in [0, sum), find which bucket it falls in.
	local weights = EggConfig.HatchRollWeights[rolledRarity] or {}
	local weightTotal = 0
	for _, w in pairs(weights) do
		weightTotal = weightTotal + w
	end
	local function _pickRarity(): string
		if weightTotal <= 0 then
			return rolledRarity
		end
		local roll = effectiveRng() * weightTotal
		local cum = 0
		for rarity, w in pairs(weights) do
			cum = cum + w
			if roll < cum then
				return rarity
			end
		end
		return rolledRarity -- floating-point safety
	end

	-- Pick a defId from a rarity's bucket. With replacement:
	-- a 1-defId bucket (e.g. Common) will keep drawing the
	-- same defId across many decoy slots, which is the
	-- 'real slot machine can repeat outputs' behavior the
	-- user asked for.
	local function _pickDefId(rarity: string): string
		local bucket = bucketIds[rarity]
		if not bucket or #bucket == 0 then
			bucket = _pickFallbackBucket()
		end
		if not bucket or #bucket == 0 then
			-- Last-resort: catalog is empty. The winner is the
			-- only defId; the loop below will collapse the
			-- sequence to { winner }.
			return winnerDefId
		end
		local idx = math.floor(effectiveRng() * #bucket) + 1
		if idx < 1 then
			idx = 1
		end
		if idx > #bucket then
			idx = #bucket
		end
		return bucket[idx]
	end

	-- The draw: pick `RollPreviewCount - 1` decoys. Each
	-- decoy is a WEIGHTED rarity roll then a random defId
	-- from that rarity's bucket. Per the user: a Common
	-- egg produces ~70% Common decoys, ~22% Uncommon,
	-- ~6% Rare, etc. The same defId CAN appear in multiple
	-- decoy slots (with-replacement draw). The final slot
	-- is always the actual winner reveal (winnerDefId).
	local decoyCount = math.max(0, EggConfig.RollPreviewCount - 1)
	local chosen: { string } = {}
	for _ = 1, decoyCount do
		local r = _pickRarity()
		chosen[#chosen + 1] = _pickDefId(r)
	end

	-- Append the winner last. The winner CAN appear in
	-- decoy slots above (slot-machine 'preview of the
	-- reveal' is a valid feel), but the final slot is the
	-- actual reveal handoff to CreateFromEgg.
	chosen[#chosen + 1] = winnerDefId

	return {
		defIds = chosen,
		finalIndex = #chosen,
	}
end

-- --- Internal helpers -------------------------------------------

-- Resolve the animal's human-readable display name from the
-- catalog (e.g. "BurrowingOwl" → "Burrowing Owl"). Falls
-- back to the defId if the catalog doesn't have a displayName
-- entry. Used to name roulette clone Models in Studio's
-- Explorer so the player can see WHICH animal is on screen
-- instead of internal "RouletteWinner_<id>" / "RouletteDecoy_<defId>"
-- debug labels. The uniqueId and defId remain the runtime
-- identifiers; the name is just the visible label.
local function _displayNameFor(defId: string): string
	for _r, bucket in pairs(AnimalConfig.Catalog) do
		if bucket and bucket[defId] and bucket[defId].displayName then
			return bucket[defId].displayName
		end
	end
	return defId
end

-- Build a procedural Part fallback (single anchored cube in the
-- animal's rarity color) when no template is found in
-- ServerStorage. Mirrors the procedural-fallback approach used
-- by Egg.ModelBuilder. The model is named with the
-- animal's catalog displayName (e.g. "Burrowing Owl") so
-- the player can read the name in the roulette, NOT the
-- random defId like "BurrowingOwl".
local function _buildProceduralCandidate(rarity: string, defId: string): Model
	-- Look up the display name from the catalog. This is the
	-- name the player will see in the roulette. Falls back to
	-- the defId if the catalog doesn't have the entry.
	local displayName = _displayNameFor(defId)

	local model = Instance.new('Model')
	model.Name = displayName

	-- A BillboardGui label on the HRP shows the animal's name
	-- in big text floating over the cube. With no template
	-- loaded, this is the only way the player can tell which
	-- animal they're looking at during the roulette.
	local hrp = Instance.new('Part')
	hrp.Name = 'HumanoidRootPart'
	hrp.Size = Vector3.new(1, 1, 1)
	hrp.Anchored = true
	hrp.CanCollide = false
	hrp.Transparency = 1
	hrp.Parent = model
	model.PrimaryPart = hrp

	local part = Instance.new('Part')
	part.Name = 'Primary'
	part.Size = VfxConfig.EggRoll.RevealSize
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Plastic
	part.Color = (RarityConfig.RarityColor and RarityConfig.RarityColor[rarity]) or VfxConfig.EggRoll.FallbackColor
	part.Parent = model

	-- Floating name tag (so the player can read which animal
	-- they're seeing even when no real mesh is loaded).
	local head = Instance.new('Part')
	head.Name = 'Head'
	head.Size = Vector3.new(1, 1, 1)
	head.Anchored = true
	head.CanCollide = false
	head.Transparency = 1
	head.Parent = model

	local bb = Instance.new('BillboardGui')
	bb.Name = 'NameTag'
	bb.Size = UDim2.fromOffset(200, 50)
	bb.StudsOffset = Vector3.new(0, 2, 0)
	bb.AlwaysOnTop = true
	bb.Parent = head

	local tl = Instance.new('TextLabel')
	tl.Name = 'Label'
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = displayName
	tl.TextColor3 = (RarityConfig.RarityColor and RarityConfig.RarityColor[rarity]) or VfxConfig.EggRoll.FallbackText
	tl.TextStrokeColor3 = VfxConfig.EggRoll.FallbackStroke
	tl.TextStrokeTransparency = 0
	tl.TextScaled = true
	tl.Font = Enum.Font.GothamBold
	tl.Parent = bb

	return model
end

-- Resolve a defId to a Model instance (template or fallback).
-- The Model is NOT cloned; the caller clones. `trait` selects
-- the trait-specific visual (nil -> Normal); previews use the
-- egg's pending trait — a trait rolled at hatch may differ, and
-- CreateFromEgg resolves the final trait for the live animal.
local function _resolveTemplate(rarity: string, defId: string, trait: string?): Model
	local tpl = nil
	-- Lazy-require to avoid a circular reference; AnimalService
	-- doesn't require this module but tests do.
	local ok, AnimalService = pcall(function()
		return require(script.Parent.Parent.AnimalService)
	end)
	if ok and AnimalService and AnimalService.GetTemplate then
		tpl = AnimalService.GetTemplate(rarity, defId, trait)
	end
	if tpl then
		return tpl
	end
	-- Procedural fallback: cube in the rarity color, named with
	-- the animal's displayName + a billboard label so the
	-- player can read which animal is rolling past.
	return _buildProceduralCandidate(rarity, defId)
end

-- Anchor + disable collisions on every BasePart. Mirrors
-- AnimalService._anchorAll + _disableAllCollisions patterns
-- (`AnimalService.lua:252-298`).
local function _prepareCandidateModel(model: Model)
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA('BasePart') then
			d.Anchored = true
			d.CanCollide = false
		end
	end
	-- Also walk direct children in case the model is shallow.
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA('BasePart') then
			child.Anchored = true
			child.CanCollide = false
		end
	end
end

-- Mystery-silhouette blackout for roll previews. Turns a
-- preview CLONE into a pitch-black NEON silhouette with a
-- white glowing outline (geometry kept, identity hidden) in
-- ONE descendant pass, called once per shown entry — never
-- per frame. Rules:
--   * BaseParts (except fully-transparent ones, which are
--     invisible hitboxes/HRPs by design): Color black,
--     Material NEON (the intended glowing-silhouette read),
--     Transparency 0 (solid read).
--   * One Highlight on the entry (Adornee = the entry
--     itself): black fill + WHITE outline, Occluded depth.
--     Generic white always — never rarity/mutation colored.
--     Parented to the entry, so it dies with it: zero
--     bookkeeping, zero accumulation across hatches.
--   * Decals, Textures, SurfaceAppearances, Beams, Trails,
--     ParticleEmitters, Highlights (originals), lights, Guis:
--     destroyed. (MeshId geometry is kept; only TextureId-style
--     identity is cleared.) These live on a throwaway clone,
--     so destroy is cheaper than disable+restore bookkeeping.
--   * Humanoid/Animator/Attachments/welds/Model.Name: left
--     alone (rig + pool integrity; names never reach players).
-- Idempotent via the SilhouetteApplied marker: a pool-hit
-- entry that was already blacked out skips the walk entirely.
-- NO restore path exists on purpose: every shown entry is
-- destroyed at preview end (decoys) or consumed at handoff
-- (winner) — silhouette state can never leak into a real
-- Animal, and source templates are never touched (we only
-- ever mutate per-preview clones).
-- Returns the number of overridden parts (diagnostics/tests).
local SILHOUETTE_COLOR = VfxConfig.EggRoll.SilhouetteText
local SILHOUETTE_OUTLINE = VfxConfig.EggRoll.SilhouetteStroke
local function _applySilhouette(entry: Model): number
	if not entry or typeof(entry) ~= 'Instance' or not entry:IsA('Model') then
		return 0
	end
	local okMarker, marked = pcall(function()
		return entry:GetAttribute('SilhouetteApplied')
	end)
	if okMarker and marked == true then
		return 0
	end
	local blacked = 0
	local okWalk, errWalk = pcall(function()
		for _, descendant in ipairs(entry:GetDescendants()) do
			if descendant:IsA('BasePart') then
				local part = descendant :: BasePart
				-- Fully-transparent parts are invisible
				-- hitboxes/HRPs by design — materializing
				-- them would ADD false geometry.
				if part.Transparency < 1 then
					part.Color = SILHOUETTE_COLOR
					part.Material = Enum.Material.Neon
					part.Transparency = 0
					blacked += 1
				end
			elseif
				descendant:IsA('Decal')
				or descendant:IsA('Texture')
				or descendant:IsA('SurfaceAppearance')
				or descendant:IsA('Beam')
				or descendant:IsA('Trail')
				or descendant:IsA('ParticleEmitter')
				or descendant:IsA('Fire')
				or descendant:IsA('Smoke')
				or descendant:IsA('Sparkles')
				or descendant:IsA('Highlight')
				or descendant:IsA('PointLight')
				or descendant:IsA('SpotLight')
				or descendant:IsA('SurfaceLight')
				or descendant:IsA('BillboardGui')
				or descendant:IsA('SurfaceGui')
			then
				descendant:Destroy()
			elseif descendant:IsA('SpecialMesh') then
				(descendant :: SpecialMesh).TextureId = ''
			elseif descendant:IsA('MeshPart') then
				(descendant :: MeshPart).TextureID = ''
			end
		end
		-- White aura: ONE Highlight per entry, Adornee'd to
		-- the entry itself (dies with it — no cleanup code,
		-- no accumulation). Created once here, never touched
		-- per frame.
		local aura = Instance.new('Highlight')
		aura.Name = 'SilhouetteAura'
		aura.FillColor = SILHOUETTE_COLOR
		aura.FillTransparency = 0
		aura.OutlineColor = SILHOUETTE_OUTLINE
		aura.OutlineTransparency = 0
		aura.DepthMode = Enum.HighlightDepthMode.Occluded
		aura.Adornee = entry
		aura.Parent = entry
	end)
	if not okWalk then
		Debug.Warn('Roll', '_applySilhouette walk failed gracefully (preview shows unmodified)', {
			error = tostring(errWalk),
		})
		return 0
	end
	pcall(function()
		entry:SetAttribute('SilhouetteApplied', true)
	end)
	return blacked
end

-- Apply a scale to a model. For the procedural Part fallback
-- the scale animates Size. For real models we use ScaleTo.
-- Roblox's ScaleTo rejects values <= 0 with the error
-- "Only positive non-zero scale values are allowed." We use
-- scale 0 to mean "hide the model" in the pool-decoy paths,
-- so we clamp to a tiny positive epsilon (0.001) when the
-- caller asks for 0. The model is effectively invisible at
-- 0.001 (parts are 1/1000 their normal size) but ScaleTo
-- accepts it. Better than transparency toggling because
-- the per-tick loop doesn't have to walk descendants.
--
-- PERF: ScaleTo re-rigs the whole model (the most expensive
-- call in the roll). The quantized path below applies the
-- target only when it moved by SCALE_EPSILON since the last
-- applied scale for THIS controller+entry — the winner's
-- 1.0 dwell and settle holds then cost zero ScaleTo calls
-- instead of one per frame. Cursor lives on the controller
-- (rolls are concurrent; module state would cross-talk).
local SCALE_EPSILON = 0.004
local function _applyScale(controller: any, model: Model, scale: number)
	if not model.PrimaryPart then
		return
	end
	local s = scale
	if s <= 0 then
		s = 0.001
	end
	if controller ~= nil and controller._lastScaleModel == model and controller._lastScale ~= nil then
		if math.abs(s - (controller._lastScale :: number)) < SCALE_EPSILON then
			return
		end
	end
	model:ScaleTo(s)
	if controller ~= nil then
		controller._lastScaleModel = model
		controller._lastScale = s
	end
end

-- --- Reveal VFX (rarity explosion) ----------------------------------
--
-- Focused mirror of the LevelUp VFX conventions (clone →
-- mount on PrimaryPart → re-home attachments → burst
-- positioned by model extents → one Heartbeat replication
-- catch-up → Emit by authored Rate → Debris cleanup; never
-- mutates the template). LevelUp's handler stays generic for
-- unknown shapes; this one targets the known
-- Explosions.<Rarity> shape (Folder → Attachment → emitters)
-- with the same semantics, and zero risk to the working
-- level-up path.

local REVEAL_VFX_LIFETIME = VfxConfig.EggRoll.Lifetime
local REVEAL_CLEANUP_CAP = VfxConfig.EggRoll.CleanupCap

-- Static template refs only (never runtime clones):
-- rarity -> ServerStorage.Assets.Vfx.Explosions.<rarity>.
-- Misses are NOT cached (a later-added asset resolves on the
-- next hatch); dead refs re-resolve.
local _explosionTemplates: { [string]: Instance? } = {}

-- Resolve the explosion template for the AUTHORITATIVE final
-- rarity (animal.rarity post-commit — never UI text, model
-- name, or color). Never throws; nil when missing.
local function _resolveExplosion(rarity: string): Instance?
	if type(rarity) ~= 'string' or rarity == '' then
		return nil
	end
	local cached = _explosionTemplates[rarity]
	if cached ~= nil and cached.Parent ~= nil then
		return cached
	end
	local template: Instance? = nil
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local vfxRoot = assets and assets:FindFirstChild('Vfx') or nil
		local explosions = vfxRoot and vfxRoot:FindFirstChild('Explosions') or nil
		template = explosions and explosions:FindFirstChild(rarity) or nil
	end)
	_explosionTemplates[rarity] = template
	return template
end

-- One-shot rarity explosion around the REAL animal. Same
-- event-driven contract as the rest of the reveal: mount +
-- emit synchronously, then return (the one Heartbeat below
-- is the LevelUp-proven replication catch-up, not a timer).
-- Never throws; missing model/template degrades silently.
local function _playRarityExplosion(animal: any)
	local ok = pcall(function()
		if type(animal) ~= 'table' then
			return
		end
		local model = animal.model
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') or (model :: Model).Parent == nil then
			return
		end
		local template = _resolveExplosion(animal.rarity)
		if not template then
			return
		end
		local m = model :: Model
		local primary = m.PrimaryPart
		if not (primary and primary:IsA('BasePart')) then
			return
		end
		local clone = template:Clone()
		clone.Parent = m
		-- Single descendant scan: collect playables first
		-- (refs survive the re-home below).
		local playables: { Instance } = {}
		local descendants: { Instance } = {}
		if not (clone:IsA('ParticleEmitter') or clone:IsA('Sound')) then
			descendants = clone:GetDescendants()
		else
			playables[#playables + 1] = clone
		end
		for _, descendant in ipairs(descendants) do
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
		-- Re-home loose attachments/emitters onto the
		-- PrimaryPart (attachments only resolve under a
		-- BasePart); nodes moved out get their own Debris
		-- entry so nothing accumulates on the animal.
		local movedOut: { Instance } = {}
		local burstAttachments: { Attachment } = {}
		if clone:IsA('Attachment') then
			burstAttachments[#burstAttachments + 1] = clone
		end
		local host = primary :: BasePart
		for _, descendant in ipairs(descendants) do
			if descendant:IsA('Attachment') then
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
		-- Burst at visible center-top from the model's OWN
		-- extents (bounded): authored asset scale preserved,
		-- only the world position is re-anchored per animal
		-- size. Falls back to PrimaryPart center.
		if #burstAttachments > 0 then
			local upOffset = VfxConfig.EggRoll.BurstDefault
			local okExt, extents = pcall(function()
				return m:GetExtentsSize()
			end)
			if okExt and typeof(extents) == 'Vector3' then
				upOffset = math.clamp(extents.Y * 0.5 + 0.5, VfxConfig.EggRoll.BurstMin, VfxConfig.EggRoll.BurstMax)
			end
			local burstPos = host.Position + Vector3.new(0, upOffset, 0)
			for _, attachment in ipairs(burstAttachments) do
				pcall(function()
					local wc = attachment.WorldCFrame
					attachment.WorldCFrame = CFrame.new(burstPos) * (wc - wc.Position)
				end)
			end
		end
		-- Replication catch-up (same race LevelUp closes):
		-- brand-new instances emitting in the same tick can
		-- be missed by not-yet-replicated clients.
		RunService.Heartbeat:Wait()
		local longestLifetime = 0
		local emitterCount = 0
		for _, inst in ipairs(playables) do
			if inst:IsA('ParticleEmitter') then
				emitterCount += 1
				local emitter = inst :: ParticleEmitter
				local count = 1
				local okRate, rate = pcall(function()
					return emitter.Rate
				end)
				if okRate and type(rate) == 'number' and rate == rate then
					count = math.max(1, math.floor(rate + 0.5))
				end
				pcall(function()
					emitter:Emit(count)
				end)
				local okLife, lifetime = pcall(function()
					return emitter.Lifetime
				end)
				if okLife and typeof(lifetime) == 'NumberRange' then
					if lifetime.Max > longestLifetime then
						longestLifetime = lifetime.Max
					end
				end
			elseif inst:IsA('Sound') then
				-- Reveal VFX Sounds are NEVER played: this clone
				-- lives in Workspace, so a sting here is audible
				-- to every nearby player. The reveal visuals stay
				-- global; the hatching player's personal reveal
				-- sting is _playReward (PlayerGui-targeted).
				-- Destroying the unplayed Sound keeps the clone
				-- from ever sounding later (e.g. PlayOnRemove).
				pcall(function()
					(inst :: Sound):Destroy()
				end)
			elseif inst:IsA('PointLight') or inst:IsA('SpotLight') or inst:IsA('SurfaceLight') then
				local light = inst :: PointLight
				local wasEnabled = light.Enabled
				light.Enabled = true
				task.delay(math.min(REVEAL_VFX_LIFETIME, REVEAL_CLEANUP_CAP), function()
					if light and light.Parent then
						light.Enabled = wasEnabled
					end
				end)
			elseif inst:IsA('Beam') then
				local beam = inst :: Beam
				local wasEnabled = beam.Enabled
				beam.Enabled = true
				task.delay(math.min(REVEAL_VFX_LIFETIME, REVEAL_CLEANUP_CAP), function()
					if beam and beam.Parent then
						beam.Enabled = wasEnabled
					end
				end)
			end
		end
		local lifetime = math.clamp(longestLifetime + 0.75, 1.0, REVEAL_VFX_LIFETIME + 1.0)
		Debris:AddItem(clone, lifetime)
		for _, moved in ipairs(movedOut) do
			Debris:AddItem(moved, lifetime)
		end
		if emitterCount == 0 then
			Debug.Warn('Roll', 'reveal VFX: no emitter found — investigate asset reference/path', {
				rarity = tostring(animal.rarity),
			})
		else
			Debug.Log('Roll', 'reveal VFX emitted', {
				rarity = tostring(animal.rarity),
				emitters = tostring(emitterCount),
			})
		end
	end)
	if not ok then
		Debug.Warn('Roll', 'reveal VFX failed gracefully (hatch unaffected)')
	end
end

-- ROLL AUDIO: Pop per shown silhouette + Reward on commit.
-- Presentation-only, zero new loops: preparation runs ONCE
-- in Start (bounded pool, no per-tick allocation), triggers
-- are synchronous calls inside the existing transitions.
--
-- Layout per roll (all parented under the roll's pool
-- folder, so teardown destroys everything with zero extra
-- cleanup code and simultaneous rolls stay isolated):
--   candidatesFolder
--   └── RollAudioAnchor (invisible part at the slot)
--       ├── Pop1..PopN (round-robin; overlap-safe)
--       └── Reward (played once)
-- Positional 3D at the slot: the hatching player hears it;
-- distant players do not (no globals, no remotes per Pop).
-- Missing assets, load failures, or a destroyed anchor all
-- degrade to silent no-ops — audio never blocks the hatch.

-- Pop pool size: the fastest tick is
-- RollFirstDecoyIntervalSeconds (0.025s); a 4-deep pool
-- absorbs overlap for any pop shorter than ~0.1s without
-- ever cloning mid-roll. Bounded, documented, fixed.
local POP_POOL_SIZE = 4

-- Resolve ServerStorage.Assets.Sfx.<name> to its playable
-- Sound (the asset itself or its first descendant Sound).
-- Never throws; nil when missing/unusable.
local function _resolveRollSfx(name: string): Sound?
	local found: Sound? = nil
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local sfxRoot = assets and assets:FindFirstChild('Sfx') or nil
		local template = sfxRoot and sfxRoot:FindFirstChild(name) or nil
		if not template then
			return
		end
		if template:IsA('Sound') then
			found = template
		else
			local inner = template:FindFirstChildWhichIsA('Sound', true)
			if inner then
				found = inner
			end
		end
	end)
	return found
end

-- Copy audible authoring onto a pool instance (guarded per
-- property so engine skew can't break preparation).
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
	-- Global SoundGroup architecture: every Pop/Reward voice is
	-- SFX (prop refreshes re-stamp so nothing slips through).
	AudioGroups.AssignSfx(target)
end

-- Build the per-roll Pop rig under `hostFolder` at `cframe`.
-- Production hosts it in the hatching player's PlayerGui
-- (personal 2D ticks — never Workspace, where nearby players
-- would hear them); the test seam passes its own folder.
-- Returns the live rig, or nil when the Pop asset is missing
-- (silent path — pops stay mute). Synchronous and
-- allocation-bounded (one part + POP_POOL_SIZE sounds); the
-- only async work is a fire-and-forget PreloadAsync that
-- never blocks the roll. Reward is NOT built here (see
-- _playReward: it must survive pool teardown, so it clones
-- player-targeted at commit time instead).
type AudioRig = {
	anchor: BasePart?,
	pool: { Sound },
	pops: number,
}
local _warnedMissingAudio = false
local function _buildAudioRig(hostFolder: Instance, cframe: CFrame): AudioRig?
	local built: AudioRig? = nil
	pcall(function()
		local popSource = _resolveRollSfx('Pop')
		local rewardSource = _resolveRollSfx('Reward')
		if not popSource and not rewardSource then
			-- Session-once loud warn (not per roll): missing
			-- SFX assets are a content bug, and silence is
			-- otherwise indistinguishable from "working".
			if not _warnedMissingAudio then
				_warnedMissingAudio = true
				warn('[Roll] Pop/Reward SFX assets missing under ServerStorage.Assets.Sfx — rolls run mute')
			end
			return
		end
		if not popSource then
			-- Reward-only rolls skip the anchor entirely;
			-- the source ref is still cached below.
			built = {
				anchor = nil,
				pool = {},
				pops = 0,
			}
			return
		end
		local anchor = Instance.new('Part')
		anchor.Name = 'RollAudioAnchor'
		anchor.Size = Vector3.new(1, 1, 1)
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanTouch = false
		anchor.CanQuery = false
		anchor.CFrame = cframe
		anchor.Parent = hostFolder
		local pops: { Sound } = {}
		for _ = 1, POP_POOL_SIZE do
			local s = Instance.new('Sound')
			s.Name = 'RollPop'
			_copySfxProps(s, popSource)
			s.Parent = anchor
			pops[#pops + 1] = s
		end
		-- Best-effort cache warm: loads in the background
		-- while the 5s roll runs; never awaited, never
		-- blocks. First-tick audio stays synchronous
		-- fire-and-forget regardless.
		task.spawn(function()
			pcall(function()
				local items: { Instance } = {}
				items[#items + 1] = popSource
				if rewardSource then
					items[#items + 1] = rewardSource
				end
				ContentProvider:PreloadAsync(items)
			end)
		end)
		built = {
			anchor = anchor,
			pool = pops,
			pops = #pops,
		}
	end)
	return built
end

-- Prepare roll audio once at Start and stash the live rig on
-- the controller. The Reward SOURCE is cached (no instance —
-- the commit-time clone is player-targeted; see _playReward).
--
-- The Pop pool anchor lives in the HATCHING player's
-- PlayerGui (server-parented PlayerGui children replicate to
-- that client alone and play 2D), NEVER in the Workspace
-- roll folder where every nearby player would hear other
-- players' hatch ticks. No live hatcher (left mid-roll) =
-- mute ticks, never a global leak.
local function _prepareRollAudio(controller: any, groundCFrame: CFrame, _hostFolder: Instance)
	local audioHost: Instance? = nil
	pcall(function()
		local egg = controller and controller.egg or nil
		local ownerId = type(egg) == 'table' and (egg :: any).ownerUserId or nil
		if type(ownerId) == 'number' then
			local hatcher = Players:GetPlayerByUserId(ownerId)
			local gui = hatcher and hatcher:FindFirstChildOfClass('PlayerGui') or nil
			if gui ~= nil then
				audioHost = gui
			end
		end
	end)
	local rig = nil
	if audioHost ~= nil then
		rig = _buildAudioRig(audioHost, groundCFrame)
	end
	if rig then
		controller._audioAnchor = rig.anchor
		controller._popPool = rig.pool
		controller._popPoolIdx = 0
	end
	controller._rewardSource = _resolveRollSfx('Reward')
	controller._revealPlayed = false
	if not rig and not controller._rewardSource then
		Debug.Log('Roll', 'audio disabled (Pop/Reward assets missing) — roll runs mute')
	end
end

-- Play one Pop for a newly SHOWN silhouette. Round-robin over
-- the prepared pool (overlap-safe, zero allocation, zero
-- clone). Called synchronously inside the show transition —
-- same tick as the first pose — never from a timer or loop.
local function _playPop(controller: any)
	local pool = controller and controller._popPool or nil
	if type(pool) ~= 'table' or #pool == 0 then
		return
	end
	local idx = ((controller._popPoolIdx or 0) % #pool) + 1
	controller._popPoolIdx = idx
	local sound = pool[idx]
	if typeof(sound) == 'Instance' and sound:IsA('Sound') and sound.Parent ~= nil then
		if DebugConfig.Audio.Enabled == true then
						Debug.Log('Audio', ('roll resolve=Pop soundId=%s volume=%s parent=anchor play=called'):format(
					tostring((sound :: Sound).SoundId),
					tostring((sound :: Sound).Volume)
				))
		end
		pcall(function()
			(sound :: Sound):Play()
		end)
	end
end

-- Play the Reward for the committed final result, targeted
-- at the hatching player (authoritative post-commit record).
-- Called ONLY from RevealFinalAnimal below — never from the
-- roll finish (the pool it would play through is destroyed
-- at handoff, cutting the sound at ~0ms) and never twice
-- (the reveal flag guards re-entry).
--
-- WHY player-targeted (not the pool): the pool lives under
-- the roll folder, which the handoff destroys in the same
-- synchronous chain — a pool Reward would be cut instantly.
-- Instead the source (cached at Start) is cloned into the
-- hatching player's PlayerGui: server-parented PlayerGui
-- children replicate to that client alone, so only the
-- hatcher hears it; the clone survives pool teardown and
-- needs no remote per tick. One clone per hatch, Debris
-- cleaned. Missing player/asset/Gui = silent skip; the hatch
-- never blocks on audio.
local function _playReward(controller: any, animal: any)
	if not controller then
		return
	end
	local source = controller._rewardSource
	if typeof(source) ~= 'Instance' or not (source :: Instance):IsA('Sound') then
		return
	end
	local ownerId = type(animal) == 'table' and animal.ownerUserId or nil
	if type(ownerId) ~= 'number' then
		return
	end
	pcall(function()
		local player = Players:GetPlayerByUserId(ownerId)
		if not player then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if not playerGui then
			return
		end
		local clone = (source :: Sound):Clone()
		clone.Name = 'HatchReward'
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = playerGui
		if DebugConfig.Audio.Enabled == true then
						Debug.Log('Audio', ('roll resolve=Reward soundId=%s volume=%s parent=PlayerGui play=called'):format(
					tostring((source :: Sound).SoundId),
					tostring((source :: Sound).Volume)
				))
		end
		pcall(function()
			(clone :: Sound):Play()
		end)
		local length = 3
		local okLen, timeLength = pcall(function()
			return (clone :: Sound).TimeLength
		end)
		if okLen and type(timeLength) == 'number' and timeLength == timeLength and timeLength > 0 then
			length = timeLength + 0.5
		end
		Debris:AddItem(clone, length)
		Debug.Log('Roll', 'reward played', { ownerId = tostring(ownerId) })
	end)
end

-- THE canonical final reveal event. Call exactly once, with
-- the AUTHORITATIVE post-commit animal record, immediately
-- after CreateFromEgg succeeds: Reward audio + rarity VFX +
-- already-visible real animal all originate here, in one
-- synchronous block — no drift between them, ever.
-- Idempotent by controller state (not timing): a second call
-- with the same controller is a no-op, so duplicate handoff
-- callbacks can never double-fire sound/VFX.
function RollController.RevealFinalAnimal(controller: any, animal: any): boolean
	if type(controller) ~= 'table' or type(animal) ~= 'table' then
		return false
	end
	if controller._revealPlayed == true then
		return false
	end
	controller._revealPlayed = true
	local t0 = os.clock()
	_playReward(controller, animal)
	_playRarityExplosion(animal)
	Debug.Log('Roll', 'reveal', {
		animalId = tostring(animal.uniqueId),
		rarity = tostring(animal.rarity),
		msTotal = ('%.1f'):format((os.clock() - t0) * 1000),
	})
	return true
end

-- --- Preview CFrame (feet on slot, scaled, rotated) -------------

-- Compute the CFrame where a model should be PivotTo'd so its
-- FEET sit on `groundCFrame` at the given `scale`. We use
-- SlotMath.FeetOffsetBelowPrimary to find how far below the
-- model's PrimaryPart the lowest bottom face is, then lift
-- the PrimaryPart by that amount times (1 - scale) so the
-- feet stay planted as the model scales.
--
-- Args:
--   model        -- the pool entry Model (PrimaryPart set)
--   groundCFrame -- the BASE position CFrame (scale 1, default
--                    facing). The XZ + rotation come from
--                    here; the Y is the slot top.
--   scale        -- the current scale (0.001 - 1.0)
--
-- Returns: CFrame, or groundCFrame if the model has no
-- PrimaryPart (no-op fallback).
--
-- PERF: feetOffset is scale-independent but costs a full
-- GetDescendants scan via SlotMath.FeetOffsetBelowPrimary.
-- The per-frame loop passes the controller-cached value
-- (`feetOffsetOverride`); one-shot placements omit it and pay
-- the single scan. Never scan per frame.
local function _previewCFrame(model: Model, groundCFrame: CFrame, scale: number, feetOffsetOverride: number?): CFrame
	if not model or not model.PrimaryPart then
		return groundCFrame
	end
	-- feetOffset is negative (e.g. -3 means the lowest bottom
	-- face is 3 studs BELOW the PrimaryPart). We want the
	-- bottom face at groundCFrame.Y. The PrimaryPart's Y
	-- should be groundCFrame.Y - feetOffset * scale, so at
	-- scale 1 the PrimaryPart is `|feetOffset|` above ground
	-- (full standing height), and at scale 0.1 it's 0.1 *
	-- |feetOffset| above ground (feet still on the ground).
	local feetOffset = feetOffsetOverride
	if feetOffset == nil then
		feetOffset = SlotMath.FeetOffsetBelowPrimary(model)
	end
	local primaryY = groundCFrame.Y - (feetOffset :: number) * scale
	-- Preserve the ground's XZ and rotation, override only Y.
	return CFrame.new(groundCFrame.X, primaryY, groundCFrame.Z) * (groundCFrame - groundCFrame.Position)
end

-- Cached feet offset for the controller's CURRENT preview
-- entry (see _previewCFrame: one scan per entry, never per
-- frame). Keyed by entry identity; a new entry re-measures.
-- Normalized to the UNSCALED model (divided by the live
-- scale at measure time): the placement math multiplies by
-- the CURRENT frame's scale, so a scaled measurement would
-- double-scale and float the winner. Measuring unscaled keeps
-- feet exactly planted at every scale.
local function _feetOffsetFor(controller: any, entry: Model): number
	if controller._feetOffsetModel == entry and type(controller._feetOffset) == 'number' then
		return controller._feetOffset
	end
	local off = SlotMath.FeetOffsetBelowPrimary(entry)
	local okScale, liveScale = pcall(function()
		return entry:GetScale()
	end)
	if okScale and type(liveScale) == 'number' and liveScale > 0.001 then
		off /= liveScale
	end
	controller._feetOffsetModel = entry
	controller._feetOffset = off
	return off
end

-- Compute the "ground CFrame" for the roulette, used by
-- HatchEgg to position the RollController and the
-- CreateFromEgg animal spawn. Same formula as the
-- groundCFrame computed inside Start (below). Exposed as a
-- static so callers can derive the same CFrame without
-- knowing the internal _previewCFrame logic.
--
-- Args:
--   slotCFrame -- the slot part's CFrame. Its rotation is the
--                 fallback facing (the Collector-facing Yaw set
--                 by BaseService.RegisterBases).
--   egg      -- the egg record (read for _localFloor,
--                 the slot top Y). When it is missing, the
--                 slot top is recovered from the egg's
--                 hover centre via HoverMath.FloorY — the
--                 exact inverse of the arithmetic that put
--                 the egg there.
--   facingPos -- optional world position the previews should
--                 face (the stand's `Button.Base`). When nil,
--                 the slot's own rotation is kept.
--
-- Returns: CFrame at (slotCFrame.X, slotTopY, slotCFrame.Z)
-- with button-base facing when `facingPos` is given, else
-- the slot's rotation. No 180° flip.
function RollController.ComputeGroundCFrame(slotCFrame: CFrame, egg: any, facingPos: Vector3?): CFrame
	local slotTopY = (egg and egg._localFloor) or HoverMath.FloorY(slotCFrame.Y, egg and egg.model)
	local rotation = slotCFrame - slotCFrame.Position
	if facingPos ~= nil then
		local facing = StandResolver.YawFacingCFrame(slotCFrame.Position, facingPos)
		if facing ~= nil then
			rotation = facing - facing.Position
		end
	end
	return CFrame.new(slotCFrame.X, slotTopY, slotCFrame.Z) * rotation
end

-- --- Start / Stop / IsRunning -----------------------------------

-- Easing functions used by the per-preview motion curve.
-- (The birth-time timeline uses a LINEAR ramp -- see
-- _birthTime below -- not these curves.)
-- Cubic ease-out powers the pop-in phase (rapid growth
-- slowing as it approaches the peak). Cubic ease-in
-- powers settle and pop-out (slow start, accelerating --
-- the preview 'snaps' rather than drifts).
local function _easeOutCubic(x: number): number
	if x <= 0 then
		return 0
	end
	if x >= 1 then
		return 1
	end
	local inv = 1 - x
	return 1 - inv * inv * inv
end

local function _easeInCubic(x: number): number
	if x <= 0 then
		return 0
	end
	if x >= 1 then
		return 1
	end
	return x * x * x
end

-- Compute the wall-clock birth time of the i-th preview (1-indexed)
-- in a fixed-duration timeline. The schedule is a LINEAR
-- DECELERATION: an arithmetic progression of per-preview
-- intervals, each one a constant STEP longer than the last.
--
--   interval[1] = a                  (a = first decoy interval)
--   interval[k] = a + (k-1) * step   (k = 1..nDecoys)
--
-- `step` is solved from the arithmetic series so the sum of
-- decoy intervals equals exactly (total - winnerDwell), making
-- the WHOLE ROLL take exactly `total` seconds regardless of
-- how many decoys there are. The perception: the first decoy
-- is a sub-frame fast flash; the last decoy is a slow
-- distinct step; deceleration is constant, not curve-shaped.
--
-- Per user feedback: any ease curve (cubic, quartic, exponential)
-- concentrates time at one end of the roll -- the player
-- perceives a sudden slowdown near the winner. The user wants
-- a TRUE LINEAR deceleration: the active preview's visible
-- time grows by a constant step on every transition.
--
-- Special case: the N-th preview is the WINNER. Its birth time
-- is `total - winnerDwell` so it has dedicated dwell time at
-- scale 1.0. The (N-1)-th decoy is the LAST decoy and its
-- interval extends up to the winner's birth. The winner's own
-- interval is `winnerDwell`. Total time is unchanged.
local function _birthTime(
	i: number,
	n: number,
	totalDuration: number,
	winnerDwell: number,
	isWinner: boolean,
	firstDecoyInterval: number
): number
	if n <= 1 then
		return 0
	end
	if isWinner then
		-- Winner is born `winnerDwell` seconds before total so it
		-- has a dedicated dwell window at scale 1.0.
		return math.max(0, totalDuration - winnerDwell)
	end
	-- Decoy: arithmetic progression of intervals.
	-- nDecoys = n - 1 (one slot reserved for the winner).
	local nDecoys = n - 1
	if nDecoys <= 0 then
		return 0
	end
	local a = math.max(0.001, firstDecoyInterval)
	local decoyWindow = math.max(0, totalDuration - winnerDwell)
	-- Solve for step. Sum of arithmetic series:
	--   nDecoys/2 * (2a + (nDecoys - 1) * step) = decoyWindow
	--   step = (2 * decoyWindow / nDecoys - 2a) / (nDecoys - 1)
	-- For nDecoys == 1 there is no slope (single decoy), step = 0.
	local step: number
	if nDecoys == 1 then
		step = 0
	else
		step = (2 * decoyWindow / nDecoys - 2 * a) / (nDecoys - 1)
	end
	-- Clamp step so it never goes negative (a degenerate config
	-- with a tiny decoyWindow and large a would otherwise
	-- produce a negative step -> inverted acceleration).
	if step < 0 then
		step = 0
	end
	-- Clamp i to [1, n] defensively. For i == n (winner)
	-- we return total - winnerDwell above; for i == 1 we
	-- return 0 here.
	if i <= 1 then
		return 0
	end
	-- i in [2, nDecoys]: decoy index. Birth time is the
	-- cumulative sum of intervals 1..i-1.
	local k = i - 1 -- decoy index 0..nDecoys-1
	if k >= nDecoys then
		return decoyWindow
	end
	-- cumulative = k*a + step * k * (k - 1) / 2
	return k * a + step * k * (k - 1) / 2
end

-- Per-preview 'feel alive' scale curve. localT in [0, 1] across
-- the preview's lifetime. Four phases:
--
--   [0.00, 0.35]  Pop-in:   entryScale -> peakScale  (cubic ease-out)
--   [0.35, 0.45]  Settle:   peakScale -> holdScale   (cubic ease-in)
--   [0.45, 0.75]  Hold:     holdScale                (constant)
--   [0.75, 1.00]  Pop-out:  holdScale -> exitScale   (cubic ease-in)
--
-- Phase fractions (0.35 / 0.10 / 0.30 / 0.25) are hardcoded visual
-- taste. Peak scale (1.15) gives a 'punchy' overshoot before the
-- settle. For very short previews (< 0.4s) the phases compress --
-- that's correct, it reads as a fast flash at the start of the
-- roll. For the winner, exitScale is 1.0 so the pop-out phase
-- is a no-op and the winner holds at holdScale until CreateFromEgg.
local POP_IN_FRAC = 0.35
local SETTLE_FRAC = 0.10
local HOLD_FRAC = 0.30
local POP_OUT_FRAC = 0.25
local PEAK_SCALE = 1.15

local function _aliveScale(localT: number, entryScale: number, holdScale: number, exitScale: number): number
	if localT < 0 then
		localT = 0
	end
	if localT > 1 then
		localT = 1
	end

	local popInEnd = POP_IN_FRAC
	local settleEnd = popInEnd + SETTLE_FRAC
	local holdEnd = settleEnd + HOLD_FRAC

	if localT < popInEnd then
		-- Pop-in: entryScale -> peakScale, cubic ease-out.
		local t = _easeOutCubic(localT / popInEnd)
		return entryScale + (PEAK_SCALE - entryScale) * t
	end
	if localT < settleEnd then
		-- Settle: peakScale -> holdScale, cubic ease-in.
		local t = _easeInCubic((localT - popInEnd) / SETTLE_FRAC)
		return PEAK_SCALE + (holdScale - PEAK_SCALE) * t
	end
	if localT < holdEnd then
		-- Hold: constant at holdScale.
		return holdScale
	end
	-- Pop-out: holdScale -> exitScale, cubic ease-in.
	local t = _easeInCubic((localT - holdEnd) / POP_OUT_FRAC)
	return holdScale + (exitScale - holdScale) * t
end

-- Y-axis bob offset (studs). Continuous wall-clock-time based
-- sine wave at 1.5 Hz with 0.15 stud amplitude. The frequency is
-- in WALL-CLOCK time, not localT, so even sub-frame previews
-- show a visible arc instead of invisible high-frequency noise.
-- 1.5 Hz is gentle -- it reads as 'breathing' rather than
-- 'vibrating'. Applied on top of the feet-flush PivotTo.
local BOB_HZ = 1.5
local BOB_AMPLITUDE_STUDS = 0.15

local function _yBob(wallClockTime: number): number
	return BOB_AMPLITUDE_STUDS * math.sin(wallClockTime * 2 * math.pi * BOB_HZ)
end

function RollController.Start(
	egg: any,
	primaryCFrame: CFrame,
	slotCFrame: CFrame,
	rolledRarity: string,
	winnerDefId: string,
	options: { rng: (() -> number)?, facingPos: Vector3? }?
): RollController
	assert(egg, 'RollController.Start: egg is required')
	assert(primaryCFrame ~= nil, 'RollController.Start: primaryCFrame is required')
	assert(slotCFrame ~= nil, 'RollController.Start: slotCFrame is required')
	assert(type(rolledRarity) == 'string', 'RollController.Start: rolledRarity is required')
	assert(type(winnerDefId) == 'string', 'RollController.Start: winnerDefId is required')

	local options2 = options or {}
	local rng = options2.rng

	-- Resolve the winner's rarity (for procedural fallback).
	local winnerRarity = rolledRarity
	for r, bucket in pairs(AnimalConfig.Catalog) do
		if bucket and bucket[winnerDefId] then
			winnerRarity = r
			break
		end
	end

	-- Build the sequence (list of defIds, winner last). PickOrder
	-- is pure; it draws pre-winner decoys cross-rarity. The
	-- sequence is { ..., winner } and the loop runs N previews.
	local order = RollController.PickOrder(winnerDefId, rng)

	-- Ground reference: the slot top Y where the animal
	-- should "stand." _localFloor is the slot's top surface,
	-- stamped by `HoverMath.Settle` on every path that parks a
	-- egg on a slot (and by `SpawnService._spawnCenter` with
	-- the center floor for Available eggs). ComputeGroundCFrame
	-- recovers it via `HoverMath.FloorY` if it is somehow unset.
	-- The XZ comes from the slot's position (slotCFrame),
	-- the Y from _localFloor (the slot top).
	-- The rotation faces the stand's button base (via
	-- options.facingPos) when given, else the slot's own
	-- rotation — matching the direction a directly-placed
	-- animal lands in (StandingCFrameOnSlot uses the same
	-- button-base rule).
	-- Use the same helper exposed to HatchEgg so both
	-- sites agree on the exact CFrame (no formula drift).
	local groundCFrame = RollController.ComputeGroundCFrame(slotCFrame, egg, options2.facingPos)
	-- The groundCFrame is the BASE position (scale 1, feet on
	-- slot). _previewCFrame adjusts it for scale and the
	-- model's local feet offset. rouletteCFrame and
	-- winnerCFrame are the SAME now: both are "feet on slot
	-- at the winner moment." CreateFromEgg's
	-- spawnCFrameOverride gets the same CFrame so the
	-- animal walks out of the exact spot the winner was
	-- revealed at.
	local rouletteCFrame = groundCFrame
	local winnerCFrame = groundCFrame

	-- Build a defId -> rarity map from the catalog. With the
	-- weighted cross-rarity decoy draw, each decoy's rarity
	-- may differ from the winner's (a Common egg's roll
	-- can flash Uncommon / Rare / etc. decoys). The template
	-- resolver needs the correct rarity per defId, not the
	-- winner's rarity, so we look it up once here.
	local defIdToRarity: { [string]: string } = {}
	for rarity, bucket in pairs(AnimalConfig.Catalog) do
		if bucket then
			for defId in pairs(bucket) do
				defIdToRarity[defId] = rarity
			end
		end
	end

	-- TEMPLATE CACHE: resolve every UNIQUE defId in the
	-- sequence ONCE with its correct rarity. The template
	-- is the SOURCE -- we Clone from it per preview, but the
	-- resolveTemplate walk (ServerStorage.Animals lookup)
	-- only happens once per unique defId.
	--
	-- POOL: lazy. pool[defId] is a live Model IF that defId
	-- is currently being shown; nil otherwise. Decoys are
	-- destroyed at the end of their preview. When the same
	-- defId appears in a later slot, we re-clone from the
	-- cached template. Total clones per roll = preview count,
	-- but the expensive lookup is amortized. The pool folder
	-- is parented to workspace, NOT to egg.model.Parent,
	-- because egg.model is destroyed at click time.
	local templates: { [string]: Model } = {}
	for _, defId in ipairs(order.defIds) do
		if not templates[defId] then
			local r = defIdToRarity[defId] or winnerRarity
			templates[defId] = _resolveTemplate(r, defId, egg.Trait)
		end
	end
	local pool: { [string]: Model } = {}
	local poolOrder: { string } = {}
	for _, defId in ipairs(order.defIds) do
		poolOrder[#poolOrder + 1] = defId
	end

	-- Pool folder (kept name "candidatesFolder" for code symmetry
	-- with cleanup paths; semantically it's a pool).
	local candidatesFolder = Instance.new('Folder')
	candidatesFolder.Name = 'RoulettePool_' .. tostring(egg.uniqueId or os.clock())
	candidatesFolder.Parent = workspace

	local controller: RollController = {
		egg = egg,
		rarity = rolledRarity,
		winnerDefId = winnerDefId,
		winnerRarity = winnerRarity,
		defIds = order.defIds,
		finalIndex = order.finalIndex,
		startedAt = 0,
		duration = 0,
		currentStep = 0,
		candidateEnteredAt = nil,
		currentCandidate = nil,
		winnerModel = nil,
		rouletteCFrame = rouletteCFrame,
		winnerCFrame = winnerCFrame,
		templates = templates,
		pool = pool,
		poolOrder = poolOrder,
		candidatesFolder = candidatesFolder,
		stopped = false,
		aborted = false,
		_onComplete = nil,
	}

	-- Roll audio, prepared ONCE before the first preview (not
	-- per tick, not per preview): bounded Pop pool in the
	-- hatching player's PlayerGui (personal ticks) + cached
	-- Reward source for the commit-time targeted sting. Missing
	-- assets (or no live hatcher) degrade to a mute roll with
	-- a single log line — never Workspace audio.
	_prepareRollAudio(controller, groundCFrame, candidatesFolder)

	-- The driver is a single task.spawn thread, NOT a Heartbeat
	-- loop. Each iteration of the loop is one PREVIEW (a pool
	-- entry flashing 0.1 -> 1.0 -> 0.1, then the next). The
	-- loop waits the ramped interval between previews. Only
	-- one pool entry is visible (non-zero scale) at any moment.
	task.spawn(function()
		local total = #order.defIds
		local entryScale = EggConfig.RollEntryScale or 0.1
		local exitScale = EggConfig.RollExitScale or 0.1
		local holdScale = 1.0
		-- NEW: fixed-duration timeline. Wall-clock time from
		-- the start of the roll to its end is exactly
		-- totalDuration, independent of the catalog size
		-- or preview count.
		local totalDuration = EggConfig.RollTotalDurationSeconds or 5.0
		local winnerDwell = EggConfig.RollWinnerDwellSeconds or 1.0
		-- First decoy's interval. The whole ramp (first -> last)
		-- is derived from this single knob plus the total
		-- duration, winner dwell, and preview count. See
		-- _birthTime for the arithmetic-progression math.
		local firstDecoyInterval = EggConfig.RollFirstDecoyIntervalSeconds or 0.025
		local rollStartTime = os.clock()

		for i = 1, total do
			-- Guard: aborted or stopped by the cleanup path
			-- (e.g. ForceReleaseBase).
			if controller.aborted or controller.stopped then
				return
			end
			-- egg.state is the source of truth now --
			-- egg.model may be nil (destroyed at click time).
			if egg.state ~= Constants.State.Opening then
				controller.stopped = true
				return
			end

			local isWinner = (i == controller.finalIndex)
			local defId = order.defIds[i]

			-- Wait until this preview's birth time on the
			-- fixed-duration timeline. The first preview is
			-- born at t=0 (no wait). Later previews yield
			-- via Heartbeat until the wall-clock matches.
			local birthTime = _birthTime(i, total, totalDuration, winnerDwell, isWinner, firstDecoyInterval)
			while os.clock() - rollStartTime < birthTime do
				if controller.aborted or controller.stopped then
					return
				end
				if egg.state ~= Constants.State.Opening then
					controller.stopped = true
					return
				end
				RunService.Heartbeat:Wait()
			end

			-- This preview's interval: the time until the
			-- NEXT preview's birth (decoys) or the end of the
			-- timeline (winner). For decoys, the next preview
			-- is the (i+1)-th decoy (or, for the last decoy,
			-- the winner -- both cases are handled by
			-- _birthTime). For the winner, the interval is
			-- winnerDwell by construction (_birthTime(n) =
			-- total - winnerDwell for the winner, and the
			-- winner dwells until total).
			local nextBirthTime: number
			if isWinner then
				nextBirthTime = totalDuration
			else
				local nextI = i + 1
				local nextIsWinner = (nextI == controller.finalIndex)
				nextBirthTime = _birthTime(nextI, total, totalDuration, winnerDwell, nextIsWinner, firstDecoyInterval)
			end
			local interval = nextBirthTime - birthTime

			-- Lazy: clone from the cached template if the
			-- pool entry for this defId is missing (was
			-- destroyed at the end of a previous preview, or
			-- never created). The decoy path destroys entries
			-- on preview end; the winner path keeps the entry
			-- alive (it is the handoff model).
			local entry = pool[defId]
			if (not entry or not entry.Parent) and templates[defId] then
				local tpl = templates[defId]
				local cloned = tpl:Clone()
				-- Name the clone with the animal's display
				-- name so the player can read which animal
				-- is rolling past in Studio's Explorer, instead
				-- of seeing internal "RouletteWinner_<id>" /
				-- "RouletteDecoy_<defId>" debug labels.
				cloned.Name = _displayNameFor(defId)
				_prepareCandidateModel(cloned)
				if cloned.PrimaryPart then
					local hrp = cloned:FindFirstChild('HumanoidRootPart')
					if hrp and hrp:IsA('BasePart') then
						cloned.PrimaryPart = hrp
					end
				end
				cloned.Parent = candidatesFolder
				pool[defId] = cloned
				entry = cloned
			end

			controller.currentCandidate = entry
			controller.candidateEnteredAt = os.clock()
			controller.currentStep = i
			-- Mystery silhouette: black out this preview ONCE,
			-- before it is ever shown (idempotent; pool-hit
			-- entries skip the walk via the marker).
			if entry and entry.Parent then
				_applySilhouette(entry)
			end
			-- Cache this entry's UNSCALED feet offset BEFORE
			-- the show block scales it (scale-free
			-- measurement); the show pose and the per-frame
			-- loop below both reuse it instead of scanning
			-- descendants every tick.
			local entryFeetOffset: number? = nil
			if entry and entry.Parent and entry.PrimaryPart then
				entryFeetOffset = _feetOffsetFor(controller, entry)
			end

			-- Show this preview: position it at scale
			-- entryScale at t=0, then drive the per-preview
			-- motion in the sub-loop below.
			if entry and entry.Parent then
				if entry.PrimaryPart then
					local cf = isWinner and winnerCFrame or rouletteCFrame
					entry:PivotTo(_previewCFrame(entry, cf, entryScale, entryFeetOffset))
				end
				_applyScale(controller, entry, entryScale)
				-- Roll tick: exactly one Pop per SHOWN
				-- silhouette, same tick as its first pose.
				-- Never in the per-frame loop below, never
				-- for unshown pool prep.
				_playPop(controller)
			end

			-- Drive the per-preview 'feel alive' motion
			-- across `interval` seconds. The curve is
			-- pop-in -> settle -> hold -> pop-out via
			-- _aliveScale. The Y-axis bob is a continuous
			-- sine wave in WALL-CLOCK time, not localT, so
			-- even sub-frame previews show visible motion.
			local previewStart = controller.candidateEnteredAt
			while true do
				if controller.aborted or controller.stopped then
					if entry and entry.Parent then
						entry:Destroy()
					end
					if defId then
						pool[defId] = nil
					end
					controller.currentCandidate = nil
					return
				end
				if egg.state ~= Constants.State.Opening then
					controller.stopped = true
					if entry and entry.Parent then
						entry:Destroy()
					end
					if defId then
						pool[defId] = nil
					end
					controller.currentCandidate = nil
					return
				end

				local now = os.clock()
				local elapsed = now - previewStart
				local localT = interval > 0 and (elapsed / interval) or 1.0

				if isWinner then
					-- Winner: scale entryScale -> 1.0 across the
					-- pop-in + settle phases, then HOLD at 1.0
					-- for the rest of the dwell. The pop-out
					-- phase is a no-op (exitScale == 1.0 for
					-- the winner). The Y-bob continues to
					-- breathe during the dwell.
					if entry and entry.Parent then
						local s = _aliveScale(localT, entryScale, holdScale, holdScale)
						_applyScale(controller, entry, s)
						if entry.PrimaryPart then
							local bob = _yBob(now - rollStartTime)
							local cf = _previewCFrame(entry, winnerCFrame, s, entryFeetOffset)
							entry:PivotTo(cf + Vector3.new(0, bob, 0))
						end
					end
					if localT >= 1.0 then
						-- Winner fully revealed at 1.0 and the
						-- dwell time has elapsed. Mark
						-- winnerModel and exit the preview loop.
						controller.winnerModel = entry
						controller.currentCandidate = nil
						break
					end
				else
					-- Decoy: full pop-in -> settle -> hold ->
					-- pop-out across the interval, then destroy.
					-- The Y-bob breathes the animal while it's
					-- visible.
					if entry and entry.Parent then
						local s = _aliveScale(localT, entryScale, holdScale, exitScale)
						_applyScale(controller, entry, s)
						if entry.PrimaryPart then
							local bob = _yBob(now - rollStartTime)
							local cf = _previewCFrame(entry, rouletteCFrame, s, entryFeetOffset)
							entry:PivotTo(cf + Vector3.new(0, bob, 0))
						end
					end
					if localT >= 1.0 then
						-- Decoy end: destroy the entry. Per user
						-- feedback, scaling to 0.001 left a visible
						-- residue. Destroying removes it cleanly;
						-- if the same defId is needed in a later
						-- slot, the lazy clone path above recreates
						-- it from the cached template.
						if entry and entry.Parent then
							entry:Destroy()
						end
						pool[defId] = nil
						controller.currentCandidate = nil
						break
					end
				end

				-- Yield the rest of this frame. We use
				-- Heartbeat:Wait for the SAME reason
				-- HatchEgg's spin-wait does: deterministic
				-- per-frame yields, no busy loop, no
				-- task.wait scheduler hop.
				RunService.Heartbeat:Wait()
			end

			-- The winner has its own dedicated dwell time
			-- baked into its interval. No additional wait
			-- here -- we exit the for-loop after the
			-- winner's interval elapses.
			if isWinner then
				break
			end
		end

		-- If we exited the loop without ever revealing the
		-- winner (shouldn't happen, but defensive), make
		-- sure we have a winnerModel.
		if not controller.winnerModel and not controller.aborted and not controller.stopped then
			-- Last-chance: scale the winner pool entry to 1.0.
			local winnerDef = order.defIds[controller.finalIndex]
			local w = pool[winnerDef]
			if w and w.Parent then
				-- Never shown before (skipped the loop above):
				-- silhouette it so the fallback reveal is also
				-- anonymous until the real animal spawns.
				_applySilhouette(w)
				if w.PrimaryPart then
					w:PivotTo(_previewCFrame(w, winnerCFrame, 1.0))
				end
				_applyScale(controller, w, 1.0)
				-- A silhouette becomes visible here, so it
				-- gets its one Pop like any other show.
				_playPop(controller)
				controller.winnerModel = w
			end
		end

		-- Fire _onComplete. Winner stays visible at the reveal
		-- CFrame. Caller (HatchEgg) consumes it via
		-- RollController._consumeWinnerModel after
		-- CreateFromEgg has placed the real animal, then fires
		-- the canonical RevealFinalAnimal event (Reward +
		-- rarity VFX on the real animal, same tick).
		-- NOTE: Reward/VFX deliberately do NOT fire here:
		-- the real animal doesn't exist yet, and anything
		-- parented under the pool would die at handoff.
		controller.stopped = true
		if controller._onComplete then
			local cb = controller._onComplete
			cb(controller)
		end
	end)

	Debug.Log('Roll', 'Start', {
		uniqueId = egg.uniqueId,
		rolledRarity = rolledRarity,
		winnerDefId = winnerDefId,
		previewCount = #order.defIds,
		uniqueDefIds = #poolOrder,
	})
	return controller
end

-- Internal: tear down any live candidates and the candidates folder.
-- Called from the Heartbeat guards and from `Stop`.
function RollController._teardownCandidates(controller: RollController)
	-- Decoy entries are destroyed at the end of their
	-- preview (per user feedback: no residual 0.001-scale
	-- models). The winner stays until consumed by
	-- _consumeWinnerModel. Any remaining pool entries are
	-- stragglers -- the folder's Destroy cascades to every
	-- child Model. Templates are cached source references;
	-- they live in ServerStorage.Animals regardless of the
	-- controller's lifetime, so we just nil the table.
	if controller.pool then
		for _, defId in ipairs(controller.poolOrder or {}) do
			local entry = controller.pool[defId]
			if entry then
				controller.pool[defId] = nil
			end
		end
		controller.pool = nil
		controller.poolOrder = nil
	end
	if controller.templates then
		controller.templates = nil
	end
	if controller.currentCandidate then
		controller.currentCandidate = nil
	end
	if controller.winnerModel then
		controller.winnerModel = nil
	end
	if controller.candidatesFolder then
		-- Destroy any stragglers (defensive -- pool entries
		-- should already be nil'd, but Destroy is idempotent
		-- on already-destroyed Instances).
		for _, child in ipairs(controller.candidatesFolder:GetChildren()) do
			child:Destroy()
		end
		controller.candidatesFolder:Destroy()
		controller.candidatesFolder = nil
	end
	-- Pop pool anchor lives in the hatching player's PlayerGui
	-- (personal ticks), NOT under the pool folder above — so
	-- it needs its own teardown. Destroying the anchor takes
	-- the pooled Sounds with it; missing/alien anchors are a
	-- silent no-op.
	if controller._audioAnchor then
		local anchor = controller._audioAnchor
		controller._audioAnchor = nil
		controller._popPool = nil
		controller._popPoolIdx = nil
		pcall(function()
			(anchor :: Instance):Destroy()
		end)
	end
end

function RollController.Stop(controller: RollController)
	if not controller then
		return
	end
	controller.stopped = true
	controller.aborted = true
	RollController._teardownCandidates(controller)
end

function RollController.IsRunning(controller: RollController): boolean
	if not controller then
		return false
	end
	return not controller.stopped
end

-- Consume the revealed winner model. Called by HatchEgg after
-- CreateFromEgg has placed the real animal at the same CFrame
-- (so the animal's first frame is the only one with a model at
-- that position). Idempotent. Returns true if a model was destroyed.
function RollController._consumeWinnerModel(controller: RollController): boolean
	if not controller then
		return false
	end
	local hadWinner = controller.winnerModel ~= nil
	-- Tear down the WHOLE pool, not just the winner -- the
	-- decoy pool entries are no longer needed and would
	-- linger in workspace as invisible (scale 0) Models
	-- otherwise. This is a one-shot cleanup.
	RollController._teardownCandidates(controller)
	return hadWinner
end

-- TEST-ONLY seam: apply the mystery-silhouette blackout to an
-- arbitrary model and return the overridden part count. Specs
-- assert the blackout rules (black parts, hidden decals, dead
-- Guis, idempotent re-apply) without running a roll.
function RollController._TestSilhouette(model: Model): number
	return _applySilhouette(model)
end

-- TEST-ONLY seam: build a roll audio rig under a caller-owned
-- folder and return { pops, hasReward, anchor }. Specs assert
-- pool construction, SoundId inheritance, round-robin reuse,
-- and Reward source resolution without running a roll. The
-- caller owns the folder (destroy it afterwards — no global
-- state).
function RollController._TestPrepareRollAudio(hostFolder: Instance, position: Vector3): { [string]: any }
	local rig = _buildAudioRig(hostFolder, CFrame.new(position))
	local source = _resolveRollSfx('Reward')
	if not rig then
		return { pops = 0, hasReward = source ~= nil, anchor = nil }
	end
	return { pops = rig.pops, hasReward = source ~= nil, anchor = rig.anchor }
end

-- TEST-ONLY seam: resolve the exact Reward asset path
-- (ServerStorage.Assets.Sfx.Reward) and return its SoundId, or
-- nil when missing. Proves the reveal trigger reads the real
-- asset (not an assumed path) without needing a player.
function RollController._TestRewardSoundId(): string?
	local source = _resolveRollSfx('Reward')
	if not source then
		return nil
	end
	return source.SoundId
end

-- TEST-ONLY seam: drive one Pop against a controller-shaped
-- table carrying a prepared pool (asserts round-robin
-- advancement), or run the canonical reveal against a fake
-- controller + fake animal record (asserts single-fire
-- reveal semantics) — all without running a roll.
function RollController._TestPlayAudio(controller: any, which: string, animal: any?): boolean
	if which == 'pop' then
		_playPop(controller)
		return true
	elseif which == 'reveal' then
		return RollController.RevealFinalAnimal(controller, animal)
	end
	return false
end

return table.freeze(RollController)
