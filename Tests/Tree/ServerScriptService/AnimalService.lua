--!strict
--!native
--[[
	AnimalService
	===============
	Owns:
	  * The catalog of animal definitions (read-through to
	    AnimalConfig)
	  * The runtime `Animal` records (created on Egg open)
	  * The visible Model (cloned from ServerStorage.Animals) +
	    its Humanoid + walk/idle animations
	  * Server-side pathfinding from spawn point to slot

	Does NOT own:
	  * Egg state (EggService)
	  * Slot reservation (BaseService)
	  * Player data (PlayerService)

	Movement model:
	  * Animals WALK to their slot via `Animal.WalkController`.
	    The controller drives `model:PivotTo` per `RunService.Heartbeat`
	    along a `PathfindingService` polyline. The model stays
	    ANCHORED for the entire walk; the Animator drives the walk
	    animation track on the anchored cluster, so the animal
	    visibly walks while smoothly translating. The Humanoid is
	    kept for future combat; it's idle throughout the walk.
	  * The walk uses per-waypoint Y from the pathfinder polyline
	    (not a linear Y lerp from start to end). This makes the
	    animal actually walk up/down stairs and ramps between
	    floors, instead of "floating in a straight line" through
	    floor transitions. The arc-length t-cursor advances
	    continuously on Heartbeat — no per-waypoint yield, no
	    deceleration/idle transition.
	  * Yaw smoothly faces the segment direction (1 - exp(-8 * dt)),
	    so the animal visibly turns as the path turns.
	  * If the pathfinder returns no path, the animal teleports
	    to the slot (deterministic, no hang). Same fallback for
	    degenerate paths.
	  * At the slot, the animal stands flush: the model's lowest
	    BasePart sits on the slot top surface (not floating above,
	    not half-sunk). This is computed via `SlotMath.StandingCFrameOnSlot`
	    which accounts for the model's local geometry (HRP may be
	    center, top, or bottom depending on the authored model).
	  * On rejoin, the animal is spawned DIRECTLY at the slot —
	    no walk on every rejoin. `SlotMath.StandingCFrameOnSlot`
	    places it flush with the slot top.
	  * If the animal's template is missing from
	    ServerStorage, CreateFromEgg fails and the lucky
	    egg is refunded (the player can retry). On rejoin,
	    the persisted record is dropped, the slot is
	    released, and the owner is notified.
]]

local Players = game:GetService('Players')
local ServerStorage = game:GetService('ServerStorage')
local Workspace = game:GetService('Workspace')

local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local AnimalStats = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local EggType = require(script.Parent.Parent.ReplicatedStorage.Types.EggType)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local SlotMath = require(script.Parent.Animal.SlotMath)
local LevelUpPresentation = require(script.Parent.Animal.LevelUpPresentation)
local AnimalOverhead = require(script.Parent.Animal.AnimalOverhead)
-- NOTE: AnimalService NEVER requires StandPresentation. That module
-- is the EGG-ONLY slot-idle wobble; animals use Animator idle tracks.
local AnimalWeight = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalWeight)
local OwnedObjectIdentity = require(script.Parent.Parent.ReplicatedStorage.Utility.OwnedObjectIdentity)
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
local CarryController = require(script.Parent.Animal.CarryController)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
-- Raid lock: grabbing an animal out of an active Arena raid
-- is rejected (frozen raid snapshot vs live record must
-- never diverge). Require-safe: ArenaService depends only
-- on ReplicatedStorage modules.
local ArenaService = require(script.Parent.Arena.ArenaService)
local TraitService = require(script.Parent.TraitService)
local SlotActionHandler = require(script.Parent.Action.SlotActionHandler)
local NotificationService = require(script.Parent.Base.NotificationService)
local TutorialSignals = require(script.Parent.Tutorial.TutorialSignals)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.FunnelService)
local AnimalService = {}

-- --- Internal state ---------------------------------------------

local animals: { [string]: any } = {} -- uniqueId -> Animal
-- Phase 2: the per-player carry index moved to
-- CarryRegistry (Carry/CarryRegistry.lua). The animal
-- record's own `carriedBy` field is kept as a hint (used
-- by ForceReleaseBase to know which player to clear
-- from the registry), but the authoritative state is the
-- registry.
local animalsFolder: Folder? = nil
local _templatesValidated = false

local playerServiceRef: any = nil
local baseServiceRef: any = nil
local eggServiceRef: any = nil
local slotServiceRef: any = nil
-- Phase 2.7: the ONE reader of the XP modifier. Read exactly once
-- per AddXP grant; LevelConfig never knows about player modifiers.
local modifierServiceRef: any = nil

-- --- Arena deployment (presentation-only parking) -----------------
--
-- While an animal fights in an active Arena raid, its stand
-- model is parked (Parent = nil) so its ArenaAnimalStand
-- reads visually empty. Slot ownership, persisted data,
-- Level/XP/Mutations/Trait/cash — ALL untouched. The stashed
-- parent restores the model to its exact prior container on
-- raid end (same stand slot: slotId never changes, and the
-- model re-settles onto its slot).
--
-- State lives HERE (module-local, keyed by uniqueId) — never
-- on the animal record (records serialize to the profile)
-- and never inferred from hierarchy (no Workspace scans).
-- ArenaService drives this from the authoritative session
-- team at raid start/end; the battle-spawn site separately
-- flags transient combat overhead records so Generation
-- hides on arena overheads. One authority (the raid
-- session), two projections, no drift.
local arenaParked: { [string]: { parent: Instance? } } = {}

-- True while the animal's stand model is parked for an active
-- raid. Unknown ids read false (fail-closed for UI gating).
function AnimalService.IsArenaDeployed(uniqueId: string): boolean
	if type(uniqueId) ~= 'string' then
		return false
	end
	return arenaParked[uniqueId] ~= nil
end

-- Park (deployed=true) or restore (deployed=false) one animal's
-- stand model. Idempotent both ways: repeat deploys no-op,
-- restores of non-parked animals no-op. Never throws, never
-- yields. Returns true when the animal is in the requested
-- state afterward, false for unknown ids / dead models.
-- Dot-semantics (no self): callers use
--   animalServiceRef.SetArenaDeployed(uid, bool)
-- inside pcall, matching the AnimalService.Get convention.
function AnimalService.SetArenaDeployed(uniqueId: string, deployed: boolean): boolean
	if type(uniqueId) ~= 'string' then
		return false
	end
	if deployed == true then
		if arenaParked[uniqueId] ~= nil then
			return true
		end
		local animal = animals[uniqueId]
		if type(animal) ~= 'table' then
			return false
		end
		local model = animal.model
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return false
		end
		local stashParent: Instance? = nil
		pcall(function()
			stashParent = (model :: Model).Parent
		end)
		arenaParked[uniqueId] = { parent = stashParent }
		pcall(function()
			(model :: Model).Parent = nil
		end)
				Debug.Warn('ArenaPresentation', ('deploy animal=%s stand=%s'):format(uniqueId, tostring(animal.slotId)))
		return true
	end
	-- Restore path.
	local entry = arenaParked[uniqueId]
	if entry == nil then
		return true
	end
	arenaParked[uniqueId] = nil
	local animal = animals[uniqueId]
	if type(animal) ~= 'table' then
		Debug.Warn('ArenaPresentation', ('restore skipped animal=%s reason=record-gone'):format(uniqueId))
		return false
	end
	local model = animal.model
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		Debug.Warn('ArenaPresentation', ('restore skipped animal=%s reason=model-gone'):format(uniqueId))
		return false
	end
	local target = entry.parent
	if typeof(target) ~= 'Instance' or (target :: Instance).Parent == nil then
		if animalsFolder ~= nil and (animalsFolder :: Folder).Parent ~= nil then
			target = animalsFolder
		else
			target = nil
		end
	end
	if target ~= nil then
		pcall(function()
			(model :: Model).Parent = target
		end)
	end
	local restored = target ~= nil
	pcall(function()
		if (model :: Model).Parent ~= target then
			restored = false
		end
	end)
	if not restored then
		warn(('[ArenaPresentation] restore FAILED animal=%s stand=%s'):format(uniqueId, tostring(animal.slotId)))
		return false
	end
		Debug.Warn('ArenaPresentation', ('restore animal=%s stand=%s'):format(uniqueId, tostring(animal.slotId)))
	-- Repaint the stand overhead now that the model is live
	-- again (Generation re-shows: the stand record never
	-- carried the arena flag).
	pcall(AnimalOverhead.Refresh, animal)
	return true
end

-- Drop a parked entry without touching models (record/model
-- already destroyed by the caller). Keeps the map leak-free
-- on destroy paths.
local function _dropArenaParked(uniqueId: string)
	if type(uniqueId) == 'string' then
		arenaParked[uniqueId] = nil
	end
end

-- --- Error reason constants (Phase 1.5) -------------------------

-- Stable wire-shape strings returned from the carry/place
-- transactions. Tests assert on these directly, so they are
-- intentionally spelled out rather than being string-built
-- dynamically.
AnimalService.Error = {
	InvalidPlayer = 'InvalidPlayer',
	AnimalNotFound = 'AnimalNotFound',
	NotOwner = 'NotOwner',
	NotSlotted = 'NotSlotted',
	AlreadyCarried = 'AlreadyCarried',
	PlayerAlreadyCarrying = 'PlayerAlreadyCarrying',
	InvalidSlot = 'InvalidSlot',
	InvalidDestination = 'InvalidDestination',
	SlotOccupied = 'SlotOccupied',
	SlotReserved = 'SlotReserved',
	TooFar = 'TooFar',
	NotCarried = 'NotCarried',
	-- Arena raid lock: the animal is fighting in an active
	-- raid (frozen snapshot). Grabbing it mid-run is
	-- rejected so the persistent record and the raid can
	-- never diverge.
	RaidLocked = 'RaidLocked',
	-- Steal (multiplayer): the carried animal is a steal in
	-- progress and must be delivered to the thief's collector
	-- (StealService) — normal Place is rejected.
	StealInProgress = 'StealInProgress',
	-- Death/reset lockout: the player's character is not live
	-- (dead/dying/respawning). All physical interactions reject
	-- with this while internal server recovery still runs.
	PlayerNotLive = 'PlayerNotLive',
}

-- --- API --------------------------------------------------------

function AnimalService.Init()
	-- Create a Workspace folder for animals so the Explorer
	-- stays sane when 40 models are alive.
	if not animalsFolder or not animalsFolder.Parent then
		animalsFolder = Instance.new('Folder')
		animalsFolder.Name = 'Animals'
		animalsFolder.Parent = Workspace
	end
	-- One-shot asset-tree validation (first Init only): missing
	-- Normal variants break every spawn of that species, so say
	-- so once at boot instead of once per failed hatch. Runs
	-- both directions (config-without-model AND model-without-
	-- config) so catalog/Studio drift is caught at startup.
	if not _templatesValidated then
		_templatesValidated = true
		pcall(function()
			for _, issue in ipairs(AnimalService.ValidateTemplates()) do
				Debug.Warn('AN', issue, {})
			end
			for _, issue in ipairs(AnimalService.ValidateStudioCoverage()) do
				Debug.Warn('AN', issue, {})
			end
		end)
	end
	-- Weight/Growth: connect the level-up celebration to the
	-- real weight pipeline. GetTargetScale resolves
	-- baseScale * level multiplier per animal (nil when
	-- unresolvable — celebration still plays). Idempotent.
	LevelUpPresentation.SetWeightProvider(AnimalWeight.GetTargetScale)
	-- Register the carry prompt callbacks. The animal service
	-- is the only authority on the grab/place transactions, so
	-- the callbacks route through here. CarryPrompts lives in a
	-- separate module to keep this service focused on state
	-- (the prompt install/remove pattern is a self-contained
	-- concern that's tested in isolation).
	CarryPrompts.SetGrabPromptCallback(function(player: Player, animalId: string)
		-- Native ProximityPrompt.Triggered source. Look up
		-- the slot id from the animal record and dispatch
		-- through the unified SlotActionHandler so all
		-- validation lives in one place.
		local animal = AnimalService.Get(animalId)
		if not animal or not animal.slotId then
			Debug.Log('AN', 'Pickup prompt fired but animal is not on a slot', {
				animalId = tostring(animalId),
			})
			return nil
		end
		return SlotActionHandler.Handle(player, {
			Action = 'Pickup',
			SlotId = animal.slotId,
			OccupantId = animalId,
		})
	end)
	CarryPrompts.SetPlacePromptCallback(function(player: Player, slotId: string, _baseId: string)
		-- The Place prompt is on a slot part. The slot is the
		-- destination: the player walked up to the slot they
		-- want to drop the carried object into and pressed E.
		-- We dispatch directly to SlotActionHandler with the
		-- slot id captured by the prompt's Triggered closure.
		local item = CarryRegistry.Get(player)
		if not item then
			Debug.Log('AN', 'Place prompt fired but player is not carrying anything', {
				userId = tostring(player.UserId),
			})
			return nil
		end
		return SlotActionHandler.Handle(player, {
			Action = 'Place',
			SlotId = slotId,
		})
	end)
end

function AnimalService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function AnimalService.SetBaseService(svc: any)
	baseServiceRef = svc
end

function AnimalService.SetEggService(svc: any)
	eggServiceRef = svc
end

-- Phase 3: SlotService is the single source of truth for
-- slot state transitions. AnimalService routes every
-- slot primitive through this ref.
function AnimalService.SetSlotService(svc: any)
	slotServiceRef = svc
end

-- Phase 2.7: inject the centralized modifier authority. Nil-safe:
-- an unwired ref resolves every grant to 1x (pre-2.7 behavior).
function AnimalService.SetModifierService(svc: any)
	modifierServiceRef = svc
end

-- --- Catalog read-throughs --------------------------------------

function AnimalService.GetPoolForRarity(rarity: string): { [string]: any }?
	Validation.t.string(rarity)
	return AnimalConfig.Catalog[rarity]
end

-- --- Template lookup --------------------------------------------

-- Canonical trait-folder resolution (THE single place that maps
-- a gameplay trait value to a Studio folder name). nil/''/unknown
-- -> 'Normal' (nil means "no trait", never the string 'None').
-- Trait validity comes from TraitService (the catalog), so no id
-- list is duplicated here. Pure apart from the catalog read.
function AnimalService.ResolveTraitFolder(trait: string?): string
	if type(trait) == 'string' and trait ~= '' then
		local okValid, valid = pcall(TraitService.IsValidTrait, trait)
		if okValid and valid then
			return trait
		end
	end
	return 'Normal'
end

-- Canonical Studio path string for a trait+rarity+species
-- triple, for logs and diagnostics (no engine access; pure
-- string fold). Uses the same ResolveTraitFolder rule as
-- GetTemplate so validator, hatch, spawn, and UI logs can
-- never disagree on the path. The leaf is the SPECIES MODEL
-- itself (Animals/<Trait>/<Rarity>/<DefId>); there is no
-- intermediate `Animal` node. `defId` is optional only so
-- folder-level diagnostics can omit it.
function AnimalService.GetTemplatePath(trait: string?, rarity: string, defId: string?): string
	return ('ServerStorage.Animals.%s.%s.%s'):format(
		AnimalService.ResolveTraitFolder(trait),
		tostring(rarity),
		if type(defId) == 'string' then defId else '<defId>'
	)
end

-- Startup validation for the trait/rarity/species asset tree.
-- For every catalog species, the Normal variant
-- (Animals/Normal/<Rarity>/<DefId>) must exist as a Model — it
-- is the guaranteed fallback for every trait. Missing Normal
-- variants break ALL spawns of that species; missing
-- Gold/Diamond/Rainbow variants only degrade to Normal
-- (logged at spawn, not issues). Silent when
-- ServerStorage/Animals is absent entirely (headless test
-- place / unconfigured Studio — per-spawn warns still fire).
-- Uses the SAME ResolveTraitFolder/GetTemplatePath rule as the
-- runtime resolver so validator and spawner can never disagree.
-- Returns the issue list (empty = clean); never throws, never
-- yields, never creates anything.
function AnimalService.ValidateTemplates(): { string }
	local issues: { string } = {}
	pcall(function()
		local templatesRoot = ServerStorage:FindFirstChild('Animals')
		if not templatesRoot then
			return
		end
		-- Diagnose a missing trait root explicitly: without
		-- Animals/Normal every species below reports missing, so
		-- say the root cause once instead of N species lines.
		local normalRoot = templatesRoot:FindFirstChild('Normal')
		if not normalRoot then
			issues[#issues + 1] = 'missing trait root: Animals/Normal (no Normal variant can resolve)'
			return
		end
		for rarity, bucket in pairs(AnimalConfig.Catalog) do
			if type(bucket) == 'table' and next(bucket) ~= nil then
				local rarityNode = normalRoot:FindFirstChild(rarity)
				for defId in pairs(bucket) do
					local model = rarityNode and rarityNode:FindFirstChild(defId) or nil
					if not model or not model:IsA('Model') then
						issues[#issues + 1] = ('missing Normal variant: Animals/Normal/%s/%s'):format(
							tostring(rarity),
							tostring(defId)
						)
					end
				end
			end
		end
	end)
	return issues
end

-- Studio -> Config drift check (the reverse direction of
-- ValidateTemplates). For every authored species Model under
-- Animals/Normal/<Rarity>, the catalog bucket for that rarity
-- must contain the same DefId. Only DIRECT Model children
-- count as species — nested Models inside a species model
-- (e.g. BurrowingOwl/Model) are internal rig/content, never
-- separate animals (GetChildren, never GetDescendants).
-- Reports `[AnimalConfigValidator] MODEL WITHOUT CONFIG:
-- <rarity>/<name>` per drifted model. Silent when the tree is
-- absent (headless test place). Never throws, never yields,
-- never creates anything.
function AnimalService.ValidateStudioCoverage(): { string }
	local issues: { string } = {}
	pcall(function()
		local templatesRoot = ServerStorage:FindFirstChild('Animals')
		if not templatesRoot then
			return
		end
		local normalRoot = templatesRoot:FindFirstChild('Normal')
		if not normalRoot then
			return
		end
		for _, rarityNode in ipairs(normalRoot:GetChildren()) do
			if rarityNode:IsA('Folder') then
				local bucket = AnimalConfig.Catalog[rarityNode.Name]
				for _, child in ipairs(rarityNode:GetChildren()) do
					if child:IsA('Model') then
						if type(bucket) ~= 'table' or bucket[child.Name] == nil then
							issues[#issues + 1] = ('[AnimalConfigValidator] MODEL WITHOUT CONFIG: %s/%s'):format(
								tostring(rarityNode.Name),
								tostring(child.Name)
							)
						end
					end
				end
			end
		end
	end)
	return issues
end

-- Returns the Model the animal should be cloned from, or nil
-- if the human has not placed one in Studio yet. Module-level
-- (exported as AnimalService.GetTemplate) so the lucky-egg
-- roulette can resolve candidate templates too without
-- duplicating the lookup. THE central animal visual resolver:
-- every spawn/display path goes through here, never around it.
--
-- REAL STUDIO SHAPE (authored assets, never restructured by
-- code): Animals/<Trait>/<Rarity>/<DefId>, where the <DefId>
-- node IS the complete species Model (e.g.
-- Animals.Normal.Rare.BurrowingOwl). Nested Models inside the
-- species model are internal rig/content — the resolver returns
-- the species node itself and never descends into it.
--
-- Resolution (trait + rarity + species; gameplay data stays
-- authoritative elsewhere — DefId/Trait/Rarity on the record
-- are untouched):
--   1. Animals/<Trait>/<Rarity>/<DefId> — the authored
--      trait-specific species model.
--   2. Animals/Normal/<Rarity>/<DefId> — safe fallback when
--      the trait variant is missing (warns loudly; never a
--      broken animal).
--   3. Legacy Animals/<Rarity>/<DefId> (old Studio shape
--      without trait folders; defId-preferred, then any model)
--      — kept so old layouts keep working during migration.
--
-- `trait` nil/invalid -> 'Normal' folder (nil means "no trait",
-- never the string 'None'). Trait validity comes from
-- TraitService (the catalog), so no id list is duplicated here.
-- Returns the template itself (callers clone the WHOLE model);
-- never mutates, never returns an inner child.
function AnimalService.GetTemplate(rarity: string, defId: string, trait: string?): Model?
	local templatesRoot = ServerStorage:FindFirstChild('Animals')
	if not templatesRoot then
		Debug.Warn('AN', 'GetTemplate: no Animals root', {
			path = 'ServerStorage.Animals',
			trait = tostring(trait),
			rarity = tostring(rarity),
			defId = tostring(defId),
		})
		return nil
	end
	local traitFolder = AnimalService.ResolveTraitFolder(trait)
	local function speciesUnder(traitName: string): Model?
		local traitRoot = templatesRoot:FindFirstChild(traitName)
		if not traitRoot then
			return nil
		end
		local rarityNode = traitRoot:FindFirstChild(rarity)
		if not rarityNode then
			return nil
		end
		local species = rarityNode:FindFirstChild(defId)
		if species and species:IsA('Model') then
			return species
		end
		return nil
	end
	local exact = speciesUnder(traitFolder)
	if exact then
		Debug.Log('AN', 'GetTemplate', {
			trait = traitFolder,
			rarity = tostring(rarity),
			defId = tostring(defId),
			path = AnimalService.GetTemplatePath(trait, rarity, defId),
			found = 'true',
		})
		return exact
	end
	if traitFolder ~= 'Normal' then
		local fallback = speciesUnder('Normal')
		if fallback then
			Debug.Warn('AN', 'GetTemplate: trait model missing, Normal fallback', {
				trait = traitFolder,
				rarity = tostring(rarity),
				defId = tostring(defId),
				path = AnimalService.GetTemplatePath(trait, rarity, defId),
			})
			return fallback
		end
	end
	-- Legacy shape without trait folders: Animals/<Rarity>/<DefId>.
	local rarityFolder = templatesRoot:FindFirstChild(rarity)
	if not rarityFolder then
		Debug.Warn('AN', 'GetTemplate: total miss (checked all shapes)', {
			checked = 'Animals/'
				.. traitFolder
				.. '/'
				.. tostring(rarity)
				.. '/'
				.. tostring(defId)
				.. ', Animals/Normal/'
				.. tostring(rarity)
				.. '/'
				.. tostring(defId)
				.. ', Animals/'
				.. tostring(rarity)
				.. '/'
				.. tostring(defId),
			path = AnimalService.GetTemplatePath(trait, rarity, defId),
			found = 'false',
			trait = tostring(trait),
			rarity = tostring(rarity),
			defId = tostring(defId),
		})
		return nil
	end
	-- Try by definitionId first.
	local byDefId = rarityFolder:FindFirstChild(defId)
	if byDefId and byDefId:IsA('Model') then
		return byDefId
	end
	-- Fall back to "any model" so a misnamed model still works.
	for _, child in ipairs(rarityFolder:GetChildren()) do
		if child:IsA('Model') then
			return child
		end
	end
	Debug.Warn('AN', 'GetTemplate: rarity folder has no Model children', {
		rarity = tostring(rarity),
		defId = tostring(defId),
		trait = tostring(trait),
		path = AnimalService.GetTemplatePath(trait, rarity, defId),
	})
	return nil
end

-- --- Animator hookup --------------------------------------------

-- Walks the cloned model looking for walk + idle Animation
-- objects, then loads them as server-side AnimationTracks
-- via Animator:LoadAnimation. Returns nil tracks if the
-- model has no animation rig — the animal walks rigid
-- (graceful degradation, no error).
--
-- Two template structures are accepted (checked in order):
--
--   Preferred (Anims folder):
--     <AnimalTemplate> (Model)
--       HumanoidRootPart
--       Humanoid
--       Animator
--       Anims (Folder)
--         walk (Animation)   -- AnimationId = rbxassetid://...
--         idle (Animation)   -- AnimationId = rbxassetid://...
--
--   Fallback (animations as direct children of the model):
--     <AnimalTemplate> (Model)
--       HumanoidRootPart
--       Humanoid
--       Animator
--       walk (Animation)   -- AnimationId = rbxassetid://...
--       idle (Animation)   -- AnimationId = rbxassetid://...
--
-- Animations are loaded SERVER-SIDE because animals are NPCs
-- with no client of their own — there is no local Player to
-- run a stock Animate LocalScript. The server's Animator
-- replicates the playing animation to all clients for free.
-- (No Animate LocalScript is needed in the template.)
local function _loadAnimations(model: Model): { walk: any?, idle: any? }?
	local humanoid = model:FindFirstChildOfClass('Humanoid')
	if not humanoid then
		Debug.Log('AN', '_loadAnimations: no Humanoid')
		return nil
	end
	local animator = humanoid:FindFirstChildOfClass('Animator')
	if not animator then
		Debug.Log('AN', '_loadAnimations: no Animator')
		return nil
	end

	-- Look in two places, in order:
	--   1. model.Anims.walk / model.Anims.idle (preferred — keeps
	--      animations organized in a single folder)
	--   2. model.walk / model.idle (fallback — animations as
	--      direct children of the model)
	-- The second case covers the common authoring shortcut of
	-- dropping the Animation objects straight into the model.
	local function _find(name: string): Animation?
		local anims = model:FindFirstChild('Anims')
		if anims then
			local child = anims:FindFirstChild(name)
			if child and child:IsA('Animation') then
				return child
			end
		end
		local direct = model:FindFirstChild(name)
		if direct and direct:IsA('Animation') then
			return direct
		end
		return nil
	end

	local walkAnim = _find('walk')
	local idleAnim = _find('idle')
	Debug.Log('AN', '_loadAnimations: scanned', {
		modelName = model.Name,
		hasAnimsFolder = tostring(model:FindFirstChild('Anims') ~= nil),
		walkFound = walkAnim ~= nil,
		idleFound = idleAnim ~= nil,
		walkAnimId = walkAnim and walkAnim.AnimationId or 'nil',
		idleAnimId = idleAnim and idleAnim.AnimationId or 'nil',
	})
	return {
		walk = walkAnim and animator:LoadAnimation(walkAnim) or nil,
		idle = idleAnim and animator:LoadAnimation(idleAnim) or nil,
	}
end

-- Settle an animal onto a slot using a pose-independent
-- sequence. All three placement paths (CreateFromEgg
-- walk-settle, SpawnFromPersistence, and PlaceAnimal)
-- call this so the visual result is identical regardless
-- of which path placed the animal.
--
-- Why this helper exists: FeetOffsetBelowPrimary iterates
-- the model's CURRENT descendants and reads their CURRENT
-- world CFrames. The computed "feet offset" depends on
-- which pose the rig is in at the moment of the call. The
-- idle animation shifts the feet to a different height
-- than the default/template pose, and the walk animation
-- shifts the feet to yet another height. If we compute
-- the target CFrame from a pose that doesn't match the
-- pose the animal will end up in (idle), the feet
-- don't land on the slot — the animal floats or sinks
-- by the pose difference.
--
-- The fix is to put the rig into a KNOWN pose (idle
-- playing) before computing the target CFrame, and to
-- wait one Heartbeat so the Animator has actually
-- applied the idle pose to the Motor6D joints. The
-- one-frame yield adds ~16ms latency, which is
-- imperceptible.
--
-- Sequence:
--   1. Stop ALL playing tracks on the Animator (kills
--      orphaned tracks from prior _loadAnimations calls
--      AND the current walk/idle tracks). Without this,
--      the rig is driven by the old tracks and the new
--      tracks simultaneously, producing visually
--      incorrect poses.
--   2. Reload the animation tracks via _loadAnimations,
--      so animal.animations points to fresh track objects
--      and the Animator has a clean track set.
--   3. Play the idle track (Looped = true so the
--      animal stays alive visually).
--   4. Wait one Heartbeat so the Animator applies the
--      idle pose to the Motor6D joints. Without this
--      yield, the joints are still in the pre-idle pose
--      when we read the world CFrames.
--   5. Compute StandingCFrameOnSlot (reads the now-
--      idle-pose limbs, so the feetOffset matches the
--      pose the animal will live in).
--   6. PivotTo the target CFrame.
--   7. Stop the walk track (in case it was loaded but
--      not played) so it can't fight idle on the next
--      Heartbeat.
--
-- Edge case: if the model has no Humanoid/Animator,
-- no tracks can play, the default pose is the only
-- pose, and this helper degenerates to "load nil
-- tracks, compute from default pose, PivotTo" — which
-- matches the previous behaviour. No regression.
local RunService = game:GetService('RunService')

local function _settleOnSlot(animal: any, slot: any, model: Model): CFrame
	-- Step 1: stop ALL playing tracks on the Animator.
	local humanoid = model and model:FindFirstChildOfClass('Humanoid')
	local animator = humanoid and humanoid:FindFirstChildOfClass('Animator')
	if animator then
		for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
			-- instant stop (no fade) so the rig returns
			-- to the default C0/C1 immediately. A fade
			-- would leave the Motor6D Transforms in a
			-- transient state when we read them.
			track:Stop(0)
		end
	end

	-- Step 2: reload the animation tracks.
	animal.animations = _loadAnimations(model) or animal.animations

	-- Step 3: play the idle track so the rig is in a
	-- known pose for the math below.
	if animal.animations and animal.animations.idle then
		animal.animations.idle.Looped = true
		animal.animations.idle:Play()
	end

	-- Step 4: wait one Heartbeat so the Animator
	-- applies the idle pose to the Motor6D joints.
	-- The Animator runs in the render/physics step,
	-- not synchronously when Play() is called. Reading
	-- the world CFrames before the next Heartbeat
	-- would read the pre-idle pose.
	if RunService.Heartbeat then
		RunService.Heartbeat:Wait()
	end

	-- Step 5: compute the target CFrame from the now-
	-- idle-pose rig.
	local targetCFrame = SlotMath.StandingCFrameOnSlot(model, slot)

	-- Step 6: snap to the slot.
	model:PivotTo(targetCFrame)

	-- Step 7: stop the walk track so it can't fight
	-- idle on the next Heartbeat. The walk track
	-- was never played, but stopping it explicitly
	-- is defensive and free.
	if animal.animations and animal.animations.walk then
		animal.animations.walk:Stop()
	end

	return targetCFrame
end

-- --- Slot landing math -------------------------------------------

-- Animals stand on top of their slot part. The CFrame is
-- computed by `_standingCFrameOnSlot` (defined later) so the
-- model's feet sit flush with the slot top. The old
-- `slot.part.CFrame + halfSize.Y` approach placed the model's
-- PrimaryPart (the HumanoidRootPart) at the slot top, which
-- for a typical model with HRP at the center means feet
-- half-sunk into the slot. The new helper accounts for the
-- model's local geometry.

-- --- Model preparation ------------------------------------------

-- Anchor pattern: the PrimaryPart (HumanoidRootPart) stays
-- anchored, every other BasePart is UNANCHORED. This is the
-- standard R15 NPC pattern: anchored root = the cluster
-- doesn't drift (no gravity, no fall-through), unanchored
-- limbs = Motor6D joints can rotate freely so the Animator
-- can drive walk + idle animation tracks visibly.
--
-- The `WalkController` unanchors the PrimaryPart during the
-- walk (so the root joint can move too), and re-anchors it
-- at the slot. Limbs are always unanchored — that's what
-- makes the idle anim visible when the animal is standing
-- in its slot.
--
-- The Humanoid is NOT destroyed — combat / raid / animation
-- systems coming later rely on it. The Humanoid is idle
-- while the animal is at the slot; the cluster doesn't
-- move on its own (anchored root, no collisions).
-- Anchor only the PrimaryPart (the HumanoidRootPart). Anchored
-- root = the cluster doesn't drift (no gravity, no fall-through).
-- Unanchored limbs = Motor6D joints can rotate freely, so the
-- Animator can drive the walk + idle animation tracks. This is
-- the standard R15 NPC pattern: anchored HRP, free limbs.
local function _anchorAll(model: Model)
	local primary = model.PrimaryPart
	if not primary then
		return
	end
	primary.Anchored = true
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') and descendant ~= primary then
			descendant.Anchored = false
		end
	end
end

-- The inverse of _anchorAll. Used by the WalkController during
-- the walk so the Animator can actually rotate the Motor6D
-- joints (anchored parts don't move their Motor6D children, so
-- the walk animation plays but the legs don't visibly cycle).
-- WalkController re-anchors at the slot via _anchorAll.
-- Unanchor every part, INCLUDING the PrimaryPart. Used by
-- WalkController at the start of a walk so the Animator can
-- drive the full Motor6D chain (including the root joint).
-- The controller re-anchors the PrimaryPart only at the slot
-- via _reanchorRoot, so the cluster is stable at rest but
-- every limb can rotate freely during the walk.
local function _unanchorAll(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Anchored = false
		end
	end
end

-- Disable collisions on every BasePart. Animals standing on
-- the same base must not bump into each other; the pathfinder
-- handles the routing (its grid is geometry-based, not
-- collision-based). Without this, two animals in adjacent
-- slots can wedge against each other and never reach their
-- destination. We keep this even though parts are anchored
-- because a future system might re-enable collision
-- selectively.
local function _disableAllCollisions(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.CanCollide = false
		end
	end
end

-- --- Stand parenting (placed-animal hierarchy) --------------------
--
-- A live PLACED animal is a direct child of its Stand
-- (`slot.stand`), keeping its existing Model.Name (species label,
-- NOT globally unique — duplicates across stands are valid).
-- Identity stays record-based (AnimalId/DefId); the stand is only
-- the physical owner. Reparenting preserves world transforms, and
-- every seat site re-settles the world CFrame right after, so
-- placement visuals are unchanged.
--
-- Temporary states keep their existing containers (Carried_<uid>
-- folders, Recovering, arena-parked Parent=nil): only Slotted
-- placement seats under the stand.

-- Seat a placed model under its slot's Stand. Falls back to the
-- shared animals folder (warned) when the slot/stand is unusable —
-- never destroys, never nil-parents. Returns true when the model
-- ended up directly under the stand.
local function _seatModelAtStand(model: Model?, slot: any): boolean
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		return false
	end
	local stand: Instance? = nil
	if type(slot) == 'table' then
		local candidate = slot.stand
		if typeof(candidate) == 'Instance' and (candidate :: Instance).Parent ~= nil then
			stand = candidate
		end
	end
	if stand ~= nil then
		pcall(function()
			(model :: Model).Parent = stand
		end)
		if (model :: Model).Parent == stand then
			return true
		end
	end
	Debug.Warn('AN', 'SeatModelAtStand: stand unusable, falling back to animals folder', {
		slotId = tostring(type(slot) == 'table' and slot.id or nil),
		model = (model :: Model).Name,
	})
	AnimalService.Init() -- ensure folder exists
	if animalsFolder then
		pcall(function()
			(model :: Model).Parent = animalsFolder
		end)
	end
	return false
end

-- Warn-only placement validator: an occupied slot's live model
-- must be a direct child of that slot's Stand. Never destroys,
-- never reparents — callers seat first, then verify.
local function _warnUnlessSeated(animal: any, slot: any, context: string)
	pcall(function()
		if type(animal) ~= 'table' or type(slot) ~= 'table' then
			return
		end
		local model = animal.model
		local stand = slot.stand
		if typeof(model) ~= 'Instance' or typeof(stand) ~= 'Instance' then
			return
		end
		if (model :: Model).Parent ~= stand then
			Debug.Warn('AN', 'StandPlacement: live model not under its stand', {
				context = context,
				animalId = tostring(animal.uniqueId),
				slotId = tostring(slot.id),
				modelParent = tostring((model :: Model).Parent),
			})
		end
	end)
end

-- --- Creation ---------------------------------------------------

-- Read the model's authored scale for the weight-growth
-- baseline (AnimalWeight.baseScale). Captured BEFORE any growth
-- is applied so the animal's own natural size stays the
-- reference forever. Nil when unreadable — the apply below
-- captures lazily on first touch instead. Never throws.
local function _captureBaseScale(model: Model): number?
	local ok, s = pcall(function()
		return model:GetScale()
	end)
	if ok and type(s) == 'number' and s == s and s ~= math.huge and s > 0 then
		return s
	end
	return nil
end

-- Apply the weight-derived scale to the animal's LIVE model,
-- grounded (feet stay planted via the SlotMath ground plane).
-- SERVER-SIDE: lives here (not in AnimalWeight) because only
-- server modules may require the ServerScriptService/Animal
-- SlotMath sibling. Captures animal.baseScale on first touch.
-- Returns 'applied' | 'unchanged' | 'skipped'. Never throws.
-- Logs one WT line per real apply (def, level, weight, alpha,
-- scale) so the pipeline is provable from Output.
function AnimalService.ApplyGrowthScale(animal: any): string
	local ok, result = pcall(function(): string
		if type(animal) ~= 'table' then
			return 'skipped'
		end
		local model = animal.model
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return 'skipped'
		end
		if (model :: Model).Parent == nil then
			return 'skipped'
		end
		local defId = animal.definitionId or animal.DefId
		-- Baseline: the model's own authored scale, captured
		-- once. Never derived from a possibly-grown live scale
		-- (that would compound on every call).
		local base = animal.baseScale
		if type(base) ~= 'number' or base ~= base or base == math.huge or base <= 0 then
			base = _captureBaseScale(model)
			if base == nil then
				return 'skipped'
			end
			animal.baseScale = base
		end
		local target = AnimalWeight.GetTargetScale(animal)
		if type(target) ~= 'number' or target ~= target or target == math.huge or target <= 0 then
			return 'skipped'
		end
		local okCur, current = pcall(function()
			return (model :: Model):GetScale()
		end)
		if not okCur or type(current) ~= 'number' then
			return 'skipped'
		end
		if math.abs(target - current) < 1e-4 then
			return 'unchanged'
		end
		local feetOffset = 0
		local okFeet, off = pcall(SlotMath.FeetOffsetBelowPrimary, model)
		if okFeet and type(off) == 'number' then
			feetOffset = off
		end
		local pivot: CFrame = (model :: Model):GetPivot()
		local groundBottomY = pivot.Y + feetOffset;
		(model :: Model):ScaleTo(target);
		(model :: Model):PivotTo(
			CFrame.new(pivot.X, groundBottomY - feetOffset * (target / current), pivot.Z) * (pivot - pivot.Position)
		)
		local w = AnimalWeight.CalculateWeight(defId, animal.Level)
		local alpha = AnimalWeight.GrowthAlpha(defId, animal.Level)
		Debug.Log('WT', 'growth applied', {
			defId = tostring(defId),
			level = tostring(animal.Level),
			weight = w ~= nil and ('%.2f'):format(w) or 'n/a',
			alpha = alpha ~= nil and ('%.3f'):format(alpha) or 'n/a',
			scale = ('%.3f -> %.3f'):format(current, target),
		})
		return 'applied'
	end)
	if not ok or (result ~= 'applied' and result ~= 'unchanged' and result ~= 'skipped') then
		return 'skipped'
	end
	return result :: string
end

-- Phase 2: CreateFromEgg derives the destination slot from
-- `egg.slotId` (the unified slot the egg was on). The
-- open is in-place, so the destination IS the source slot
-- (now Reserved after the Demote transition on open). The
-- animal walks a (possibly zero-distance) path and lands
-- on the same slot. If anything goes wrong here we refund
-- the open via eggServiceRef:RefundHatch.
function AnimalService.CreateFromEgg(
	egg: any,
	rarity: string,
	predefId: string?,
	options: {
		spawnCFrameOverride: CFrame?,
		Trait: string?,
		Mutations: { string }?,
		TraitResolved: boolean?,
		ResolvedTrait: string?,
		ResolvedMutations: { string }?,
	}?
): any
	Debug.Log('AN', '> CreateFromEgg', { rarity = rarity, blockSlotId = tostring(egg and egg.slotId) })
	Validation.AnyTable(egg)
	Validation.t.string(rarity)
	if options ~= nil then
		Validation.AnyTable(options)
	end
	if not egg.slotId then
		Debug.Warn('AN', 'CreateFromEgg: egg has no slotId; refusing')
		return { success = false, error = 'no-slot' }
	end
	local targetSlot = slotServiceRef._findSlotById and slotServiceRef._findSlotById(egg.slotId)
	if not targetSlot then
		Debug.Warn('AN', 'CreateFromEgg: target slot not found', { slotId = egg.slotId })
		return { success = false, error = 'slot-not-found' }
	end

	local defId, def = nil, nil
	if predefId ~= nil then
		local rarityCatalog = AnimalConfig.Catalog[rarity]
		if rarityCatalog and rarityCatalog[predefId] then
			defId = predefId
			def = rarityCatalog[predefId]
		end
	end
	if not defId or not def then
		defId, def = AnimalConfig.GetRandom(rarity)
	end
	if not defId or not def then
		Debug.Log('AN', 'CreateFromEgg: no definition for rarity')
		-- Refund: release the animal slot the caller reserved
		-- and roll the lucky egg back to Placed.
		if eggServiceRef and eggServiceRef.RefundHatch then
			eggServiceRef.RefundHatch(egg)
		else
			slotServiceRef.ReleaseSlot(targetSlot.id)
			egg.state = EggType.State.Placed
			egg._mutex = false
		end
		return { success = false, error = 'no-definition' }
	end
	Debug.Log('AN', 'CreateFromEgg: definition chosen', { defId = defId, displayName = def.displayName })

	-- Phase 2.11 inheritance via the ONE shared rule
	-- (TraitService.ResolveInheritance): hidden egg Trait
	-- transfers 100%, else server-side roll. Resolved HERE —
	-- before model selection — because the visual template is
	-- trait-specific: the model must match the FINAL trait, not
	-- the pending egg trait. Runs inside the caller's mutex
	-- with no yields (consumed-once egg, created-once animal,
	-- rolled-once trait). Reused below for the animal record.
	-- HatchEgg pre-resolves the SAME inheritance before the
	-- roulette (so the pre-roulette template check validates
	-- the FINAL trait, not the pending egg trait) and passes it
	-- through options.TraitResolved + ResolvedTrait /
	-- ResolvedMutations. When present, reuse it verbatim: a
	-- second roll here would pick a DIFFERENT trait than the one
	-- the roulette just validated, breaking the hatch after a
	-- 5-second roll for no reason.
	local inheritance
	if type(options) == 'table' and (options :: any).TraitResolved == true then
		local rt = (options :: any).ResolvedTrait
		if rt ~= nil and type(rt) ~= 'string' then
			rt = nil
		end
		if type(rt) == 'string' and not TraitService.IsValidTrait(rt) then
			rt = nil
		end
		local rm: { string } = {}
		if type((options :: any).ResolvedMutations) == 'table' then
			for _, id in ipairs((options :: any).ResolvedMutations) do
				if type(id) == 'string' and id ~= '' then
					rm[#rm + 1] = id
				end
			end
		end
		inheritance = { Trait = rt, Mutations = rm }
		Debug.Log('AN', 'CreateFromEgg: using caller-resolved inheritance', {
			trait = tostring(inheritance.Trait),
			mutations = table.concat(inheritance.Mutations, ','),
		})
	else
		inheritance = TraitService.ResolveInheritance(egg.Trait, egg.Mutations, nil)
	end

	local template = AnimalService.GetTemplate(rarity, defId, inheritance.Trait)
	if not template then
		Debug.Warn('AN', 'CreateFromEgg: template missing', {
			rarity = rarity,
			defId = defId,
			trait = tostring(inheritance.Trait),
			path = AnimalService.GetTemplatePath(inheritance.Trait, rarity, defId),
		})
		-- Refund: same as above.
		if eggServiceRef and eggServiceRef.RefundHatch then
			eggServiceRef.RefundHatch(egg)
		else
			slotServiceRef.ReleaseSlot(targetSlot.id)
			egg.state = EggType.State.Placed
			egg._mutex = false
		end
		return { success = false, error = 'template-missing' }
	end

	-- Phase 2.2: mint the Id once, here, through the centralized
	-- generator. The old inline `'BR_' .. os.clock() .. '_' .. math.random(...)`
	-- formula was duplicated across CreateFromEgg and
	-- SpawnFromPersistence and produced a fresh id on every
	-- rejoin, so an animal's identity never survived a leave.
	-- The Id is the persistence key: it is written to
	-- PlayerData and read back on rejoin. Collision-checked
	-- against the live registry so two animals can never
	-- share an id (spec §8-§9).
	local uniqueId = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, animals)

	-- Clone the authored model. We set the spawn CFrame below
	-- after the clone is parented (so PrimaryPart + descendants
	-- exist).
	local model = template:Clone()
	-- Name the model with the animal's displayName (e.g.
	-- "Sabertooth Tiger") so the player can read which
	-- animal they're looking at, instead of seeing the
	-- internal `BR_<clock>_<random>` uniqueId in
	-- Studio's Explorer. The uniqueId is still the runtime
	-- identifier (used by animals[uniqueId] lookups,
	-- client remotes, persistence); the name is just the
	-- visible label.
	model.Name = def.displayName or ('Animal_' .. uniqueId)
	AnimalService.Init() -- ensure folder exists
	model.Parent = animalsFolder

	-- Anchor only the PrimaryPart (HumanoidRootPart), leave
	-- every other part unanchored. This is the R15 NPC
	-- pattern: anchored root = no drift / fall-through,
	-- unanchored limbs = Animator can drive walk + idle
	-- tracks visibly. The WalkController unanchors the
	-- root during the walk (so the root joint can move)
	-- and re-anchors it at the slot.
	-- Disable collisions so animals in adjacent slots
	-- don't wedge each other (collision-free parts don't
	-- bump; the pathfinder handles routing).
	_anchorAll(model)
	_disableAllCollisions(model)

	-- PrimaryPart MUST be a HumanoidRootPart so the model can
	-- be pathfound. If the human placed a wrong model, fail
	-- loudly so the asset doc is followed.
	local hrp = model:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		Debug.Warn('AN', 'CreateFromEgg: model has no HumanoidRootPart', {
			defId = defId,
			rarity = tostring(rarity),
			trait = tostring(inheritance.Trait),
			template = template:GetFullName(),
		})
		model:Destroy()
		-- Refund the open: caller can retry.
		if eggServiceRef and eggServiceRef.RefundHatch then
			eggServiceRef.RefundHatch(egg)
		end
		return { success = false, error = 'template-no-humanoidrootpart' }
	end
	model.PrimaryPart = hrp
	-- NOTE: no model Sounds are provisioned here. Upgrade
	-- audio is personal and plays on the owning client
	-- (AnimalLeveledUp remote); a Workspace Sound would be
	-- audible to every nearby player.
	-- Spawn position. The CFrame is exactly the position
	-- the animal appears at; the WalkController then drives
	-- it to the target slot. Resolution order (precedence):
	--   1. options.spawnCFrameOverride -- set by HatchEgg so
	--      the animal spawns at the SAME CFrame the winner
	--      was revealed at, with the SAME facing. The caller
	--      owns the exact position; we do NOT add a +2 offset
	--      (the override already accounts for the model
	--      orientation via RollController._previewCFrame).
	--   2. egg.model.PrimaryPart.CFrame + (0, 2, 0) -- the
	--      legacy path used when the egg model is still alive
	--      and the caller did not pass an override. The +2
	--      lifts the animal just above the egg so the
	--      walk-out animation is visible.
	--   3. targetSlot.part.CFrame + (0, 5, 0) -- last-resort
	--      fallback when neither the override nor the model is
	--      available.
	local spawnCFrame
	if options and options.spawnCFrameOverride then
		spawnCFrame = options.spawnCFrameOverride
	elseif egg.model and egg.model.PrimaryPart then
		spawnCFrame = egg.model.PrimaryPart.CFrame + Vector3.new(0, 2, 0)
	else
		spawnCFrame = targetSlot.part.CFrame + Vector3.new(0, 5, 0)
	end
	-- Set the spawn CFrame via PivotTo (anchors-free).
	model:PivotTo(spawnCFrame)

	local anims = _loadAnimations(model)

	-- _refs is read by Animal.WalkController._onComplete to
	-- call baseService.OccupySlot. Without it, every walk logs
	-- "no _refs.baseService, cannot OccupySlot" and the animal
	-- never actually arrives. Same refs as the module-level
	-- locals used by _walkTo's _onArrived callback.
	local refs = {
		baseService = baseServiceRef,
		playerService = playerServiceRef,
		eggService = eggServiceRef,
		slotService = slotServiceRef,
	}

	local animal: any = {
		uniqueId = uniqueId,
		definitionId = defId,
		displayName = def.displayName,
		rarity = rarity,
		ownerUserId = egg.ownerUserId,
		slotId = targetSlot.id,
		spawnSlotId = egg.slotId,
		-- Phase 2.4: canonical progression level. Every new animal
		-- starts at Level 1 / XP 0 (spec §4) regardless of rarity.
		Level = 1,
		-- Phase 2.5: Health/Damage are DERIVED stats — computed from
		-- Level + definition + AnimalConfig.Stats on demand via
		-- AnimalStats (see GetStats). No cached field lives here, so
		-- a level-up can never leave a stale stat behind.
		-- Phase 2.11: Trait (singular string|nil) + Mutations
		-- (unique array, defensive copy — never the caller's
		-- table). Generation/sell multipliers derive from these
		-- on demand; nothing calculated is stored.
		Trait = nil,
		Mutations = {},
		model = model,
		animations = anims,
		_refs = refs,
		-- Weight-growth baseline: the template's authored scale,
		-- captured pre-growth (Level 1 applies no growth, so this
		-- is exactly the resting scale the multiplier builds on).
		baseScale = _captureBaseScale(model),
		-- Phase 1.5: carry state. Defaults to Slotted on
		-- creation; the slot is Reserved (held by the
		-- WalkController until it lands) but the animal
		-- itself is conceptually Slotted the moment it has a
		-- target. Recovering is reserved for the rare
		-- "no slot to return to" case in
		-- RecoverCarriedAnimal.
		state = 'Slotted',
		carriedBy = nil,
		originalSlotId = nil,
		_mutex = true,
		createdAt = os.clock(),
		XP = 0,
	}
	-- Trait + mutations were resolved above (before model
	-- selection, so the trait-specific template matches the
	-- final trait). Reused here for the animal record.
	animal.Trait = inheritance.Trait
	animal.Mutations = inheritance.Mutations
	Debug.Log('AN', 'inheritance resolved', {
		animal = uniqueId,
		trait = tostring(inheritance.Trait),
		mutations = table.concat(inheritance.Mutations, ','),
	})
	animals[uniqueId] = animal

	-- Live overhead GUI (presentation only, pcall-guarded): the
	-- BillboardGui rides the model through its walk to the slot.
	pcall(AnimalOverhead.EnsureForAnimal, animal)

	-- Persist: a new animal in the player's data, AND consume
	-- the Egg record in the SAME synchronous mutation
	-- (Phase 2.5.1 §10). The old split — HatchEgg removed the LB
	-- record, this line added the BR record — is the window that
	-- let a phantom LB record survive its own open and come back
	-- as a "converted" Egg on rejoin.
	if playerServiceRef then
		if playerServiceRef.ConsumeEggIntoAnimal then
			playerServiceRef.ConsumeEggIntoAnimal(
				egg.ownerUserId,
				egg.uniqueId,
				targetSlot.id,
				defId,
				uniqueId,
				{ Trait = inheritance.Trait, Mutations = inheritance.Mutations }
			)
		else
			Debug.Warn('AN', 'CreateFromEgg: playerService lacks ConsumeEggIntoAnimal — LB record NOT consumed', {
				userId = tostring(egg.ownerUserId),
				eggId = tostring(egg.uniqueId),
				slotId = targetSlot.id,
			})
		end
	end

	-- NOTE: we do NOT call OccupySlot here. The slot stays
	-- Reserved during the walk; WalkController._onComplete
	-- calls OccupySlot on arrival. This is the same pattern
	-- as EggService (ReserveSlot before the flight,
	-- OccupySlot in FlightController._onComplete). Calling
	-- OccupySlot here would double-call it on arrival and
	-- the second call would fail with "state = Occupied".

	Debug.Log('AN', 'CreateFromEgg: ok, spawning flyTo', { uniqueId = uniqueId })
	Debug.Log('AN', 'CreateFromEgg', {
		defId = tostring(defId),
		trait = tostring(inheritance.Trait),
		rarity = tostring(rarity),
		template = template:GetFullName(),
		created = 'true',
	})

	task.spawn(function()
		AnimalService._walkTo(animal, targetSlot)
	end)

	return { success = true, animalId = uniqueId }
end

-- --- Flight ------------------------------------------------------

-- Slot lookup by id. Local to this file because the animal
-- service only ever needs to resolve its OWN spawn slot (a
-- lucky-egg slot) — never other animals' slots.
local function _findSlotById(slotId: string): any?
	if not baseServiceRef or not slotServiceRef._findSlotById then
		return nil
	end
	return slotServiceRef._findSlotById(slotId)
end

-- Slot landing math lives in `Animal/SlotMath.lua`. We share
-- it with Animal.WalkController (which also needs to compute
-- the standing CFrame on the slot so it can target the walk).
-- See `SlotMath.FeetOffsetBelowPrimary` and
-- `SlotMath.StandingCFrameOnSlot` for the implementation.
-- Drive the animal from its current position (its spawn
-- point, which is the lucky egg's CFrame) to the animal
-- slot via a pathfinder + Heartbeat-driven PivotTo walk.
-- The model stays ANCHORED for the entire walk; the
-- PathfindingUtil walker drives model:PivotTo each Heartbeat
-- tick along the path polyline. Same architecture as the
-- lucky egg FlightController, with no physics interference
-- and no jitter.
--
-- The walk anim plays on the moving model (the Animator
-- drives Motor6D joints regardless of anchor state), so the
-- animal visibly walks while smoothly translating to the
-- slot. At the slot, the walk anim stops and the idle anim
-- plays.
--
-- The Humanoid is kept for future combat / raid systems;
-- it's idle throughout the walk.
-- Start a walk for `animal` to `targetSlot`. Hands off to
-- `Animal.WalkController`, which drives the model along the
-- pathfinder polyline per Heartbeat. The controller fires
-- `animal._onArrived` on completion; we install that
-- callback here to do the per-arrival work (stop walk anim,
-- play idle anim, push state, fire AnimalArrived, notify).
--
-- The animal service owns the arrival behavior; the
-- controller is consumer-agnostic. Same pattern as the
-- lucky egg FlightController: the controller's only job
-- is to drive the model + OccupySlot + call _onArrived. The
-- consumer decides what "arrived" means.
function AnimalService._walkTo(animal: any, targetSlot: any)
	Debug.Log('AN', '> _walkTo', { uniqueId = animal.uniqueId })
	local model = animal.model
	if not model or not model.Parent then
		Debug.Log('AN', '_walkTo: no model, bailing')
		animal._mutex = false
		return
	end

	-- Install the per-arrival callback. The WalkController
	-- fires this after OccupySlot succeeds, passing
	-- (animal, slot, slotId). The slotId is a captured
	-- string, not a live slot reference, so a
	-- BaseService.CleanupPlayer re-stamp of slot.id to
	-- userId=0 doesn't corrupt our in-flight reference.
	animal._onArrived = function(arrived, slot, slotId)
		if arrived._aborted or not arrived.model or not arrived.model.Parent then
			Debug.Log('AN', '_onArrived: aborted, bailing')
			-- The walk is over (dead): release the finished
			-- controller handle so later systems (level-up
			-- presentation, destroy paths) don't mistake a dead
			-- walk table for an active driver.
			arrived.controller = nil
			arrived.controllerType = nil
			arrived._mutex = false
			return
		end
		-- Final safety snap. Match the place flow's
		-- canonical settle exactly:
		--   1. _anchorAll (primary anchored, limbs
		--      unanchored) — re-establishes the
		--      standard R15 NPC anchor state after
		--      the walk controller's
		--      _reanchorAll (which only sets the HRP
		--      and leaves the limbs in whatever state
		--      _unanchorAll put them in at walk
		--      start; in practice this matches
		--      what _anchorAll does, but doing it
		--      here explicitly removes any drift if
		--      a future code path leaves the limbs
		--      anchored).
		--   2. Re-load the animation tracks so the
		--      rig is bound to fresh AnimationTrack
		--      objects on a clean Animator. The walk
		--      track's TimePosition can be stale and
		--      its weight can be 0 mid-stride; a
		--      fresh Animator:LoadAnimation gives
		--      clean tracks.
		--   3. Compute StandingCFrameOnSlot. Now
		--      that the rig is in the canonical
		--      state (anchored HRP, free limbs,
		--      no track playing), the math is the
		--      same as the place flow.
		--   4. PivotTo snaps the model exactly to
		--      the slot top + HipHeight.
		--   5. Stop the (now stale) walk track and
		--      play the fresh idle track.
		_anchorAll(arrived.model)
		_disableAllCollisions(arrived.model)
		-- Seat under the arrival Stand (the walked model keeps
		-- whatever parent it had; placement owns the hierarchy).
		_seatModelAtStand(arrived.model, slot)
		_warnUnlessSeated(arrived, slot, 'WalkArrival')
		-- Canonical settle: pose-independent, kills the
		-- orphaned walk track, plays idle before reading
		-- the rig pose. See _settleOnSlot for the full
		-- rationale.
		_settleOnSlot(arrived, slot, arrived.model)
		-- Weight-growth: land at the record Level's physical size
		-- (no-op at Level 1 — target equals baseline). Grounded,
		-- never throws, celebration-safe.
		AnimalService.ApplyGrowthScale(arrived)
		-- Overhead rides the model through the walk; refresh
		-- post-arrival so the seated animal is guaranteed
		-- populated even if creation raced model parenting.
		pcall(AnimalOverhead.Refresh, arrived)
		-- NOTE (egg-only idle): Animals NEVER bind to
		-- StandPresentation. That loop is the egg slot-idle
		-- wobble; animal presentation is Animator idle tracks.

		-- Phase 1.5: install the Grab prompt on the slot so
		-- the player can pick the animal up to rearrange.
		if slot.part and slot.part.Parent then
			CarryPrompts.InstallPickupPrompt(arrived.model, arrived.uniqueId, 'arrived', slot, slot.ownerUserId)
		end

		-- Push state to the owner and fire AnimalArrived.
		-- Skip if the owner left during the walk; the
		-- persistence record is the source of truth and the
		-- next rejoin will re-spawn the animal at the
		-- slot.
		local owner = playerServiceRef and Players:GetPlayerByUserId(arrived.ownerUserId :: number)
		if owner and baseServiceRef and playerServiceRef then
			playerServiceRef.PushState(owner, baseServiceRef.Snapshot(arrived.ownerUserId :: number))
			-- Arrival success: OccupySlot done above, model
			-- settled on the slot, prompts installed. One
			-- arrival = one notification (restore paths place
			-- directly and never run this callback).
			pcall(
				NotificationService.NotifySuccess,
				owner,
				'Arrival_Success',
				{ AnimalName = arrived.displayName, Rarity = arrived.rarity }
			)
			-- Phase 2.5: derived stats, recomputed from the canonical
			-- Level at push time (server-authoritative; the client can
			-- only display these values, never submit them).
			local stats = AnimalStats.Snapshot(arrived)
			Remotes.FireClient(owner, Remotes.Names.AnimalArrived, {
				BaseId = slot.baseId,
				SlotId = slotId,
				Type = arrived.definitionId,
				DisplayName = arrived.displayName,
				Rarity = arrived.rarity,
				Level = arrived.Level or 1,
				Health = stats.Health,
				Damage = stats.Damage,
			})
		end

		arrived._mutex = false
		-- Walk completed: release the finished controller handle.
		-- The walk's Heartbeat connection is already disconnected
		-- (or never existed on the teleport path) and
		-- controller.stopped == true. Without this, animal.controller
		-- stays a truthy dead table forever and any consumer that
		-- checks "is this animal being driven" (level-up
		-- presentation, carry guards) misreads a quietly slotted
		-- animal as mid-walk. Mirrors the egg lifecycle
		-- (CollectorArrival/HoverMath nil the controller on
		-- completion); pickup→place only worked around this
		-- because PlaceAnimal clears the same fields.
		arrived.controller = nil
		arrived.controllerType = nil
		Debug.Log('AN', '< _onArrived done')
	end

	-- Play walk animation. The track was loaded by
	-- _loadAnimations, which reads from the `Anims` folder
	-- on the model and loads via Animator:LoadAnimation
	-- (server-side; animals are NPCs, no client).
	if animal.animations and animal.animations.walk then
		animal.animations.walk.Looped = true
		animal.animations.walk:Play()
	end

	-- Hand off to the WalkController. It eggs the calling
	-- coroutine until the walk completes (or aborts). The
	-- model stays anchored throughout; the controller drives
	-- model:PivotTo per Heartbeat.
	local WalkController = require(script.Parent.Animal.WalkController)
	animal.controllerType = 'Walk'
	animal.controller = WalkController.Start(animal, targetSlot)
	Debug.Log('AN', '< _walkTo done')
end

-- --- Persistence rejoin ----------------------------------------

-- Called by BaseService.RestorePlayerBase for each persisted
-- animal record. Re-creates the animal AT its slot (no
-- walk). BaseService.RestorePlayerBase has already called
-- ReserveSlot on the slot; we OccupySlot it here, fixing a
-- latent bug where slots were left Reserved forever because
-- no one ever called OccupySlot on the rejoin path.
--
-- Missing-template handling: if the template isn't in
-- ServerStorage, we drop the persisted record, release the
-- slot, and notify the owner. The slot then becomes Empty
-- and is reusable on the next rejoin.
function AnimalService.SpawnFromPersistence(userId: number, record: any, slot: any): any
	Debug.Log('AN', '> SpawnFromPersistence', { userId = tostring(userId), defId = record.DefId })
	Validation.PositiveInteger(userId)
	Validation.AnyTable(record)
	Validation.AnyTable(slot)

	local defId = record.DefId
	-- Look up the rarity from the defId.
	local rarity, def = AnimalConfig.Get(defId)
	if not rarity or not def then
		Debug.Warn('AN', 'SpawnFromPersistence: defId not in catalog', { defId = defId })
		AnimalService._dropPersistedAndNotify(userId, slot, defId, '(unknown definition)', record)
		return { success = false, error = 'defId-not-in-catalog' }
	end

	local template = AnimalService.GetTemplate(rarity, defId, record.Trait)
	if not template then
		Debug.Warn('AN', 'SpawnFromPersistence: template missing', {
			rarity = rarity,
			defId = defId,
			trait = tostring(record.Trait),
		})
		AnimalService._dropPersistedAndNotify(userId, slot, defId, def.displayName, record)
		return { success = false, error = 'template-missing' }
	end

	-- Phase 2.2: read the Id from the persisted record instead of
	-- minting a new one. A rejoin that minted a fresh id made
	-- the animal's identity unstable: the same owned object
	-- would be a different id on every leave/rejoin, so
	-- nothing could key off it. The Id is the persistence key
	-- (spec §6). If the record has no Id (pre-2.2 save or a
	-- corrupted row), PlayerService already repaired one at
	-- load time; if it's still missing here, mint one and
	-- write it back so the next rejoin sees it.
	local uniqueId = record.Id
	if not OwnedObjectIdentity.IsValid(uniqueId, OwnedObjectIdentity.Kind.Animal) then
		uniqueId = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, animals)
		record.Id = uniqueId
	end

	local model = template:Clone()
	-- Name the model with the animal's displayName (e.g.
	-- "Boneca Ambalabu"). See CreateFromEgg for the
	-- displayName-vs-uniqueId rationale.
	model.Name = def.displayName or ('Animal_' .. uniqueId)
	AnimalService.Init()
	-- Placed on rejoin directly at its slot: seat under the Stand
	-- (falls back to the shared folder, warned, if unusable).
	_seatModelAtStand(model, slot)

	-- Anchor every part (the cluster is moved via PivotTo;
	-- physics-engine interference would cause the same
	-- jitter the lucky egg path used to have). Disable
	-- collisions so animals in adjacent slots don't wedge.
	_anchorAll(model)
	_disableAllCollisions(model)

	local hrp = model:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		Debug.Warn('AN', 'SpawnFromPersistence: model has no HumanoidRootPart', {
			defId = defId,
			rarity = tostring(rarity),
			trait = tostring(record.Trait),
			template = template:GetFullName(),
		})
		model:Destroy()
		AnimalService._dropPersistedAndNotify(userId, slot, defId, def.displayName, record)
		return { success = false, error = 'template-no-humanoidrootpart' }
	end
	model.PrimaryPart = hrp
	-- NOTE: no model Sounds provisioned (personal upgrade
	-- audio plays on the owning client — see above).

	-- Place the model directly at the slot top CFrame. No
	-- walk — the player sees the animal in place on
	-- rejoin. The "approach" landing from a flight is
	-- irrelevant here; we just place. _settleOnSlot
	-- plays the idle animation before reading the rig
	-- pose, so the feetOffset matches the pose the
	-- animal will live in. Without this, the animal
	-- floats by the difference between the default-
	-- pose foot height and the idle-pose foot height.
	local placeholder = { model = model, animations = _loadAnimations(model) }
	_settleOnSlot(placeholder, slot, model)

	-- _refs matches the CreateFromEgg record. SpawnFromPersistence
	-- doesn't walk (it places directly at the slot) so _refs is
	-- mostly defensive, but keeping the shape consistent means a
	-- walk later (e.g. server-initiated re-place) can still use
	-- it.
	local refs = {
		baseService = baseServiceRef,
		playerService = playerServiceRef,
		eggService = eggServiceRef,
		slotService = slotServiceRef,
	}

	local animal: any = {
		uniqueId = uniqueId,
		definitionId = defId,
		displayName = def.displayName,
		rarity = rarity,
		ownerUserId = userId,
		slotId = slot.id,
		spawnSlotId = nil,
		-- Phase 2.4: canonical progression level, restored from the
		-- persisted record (repair/normalization already ran in
		-- PlayerService on load). Stats are re-derived from this Level
		-- on demand (AnimalStats) — no stale persisted stat survives
		-- a rejoin because none is ever stored.
		Level = record.Level or 1,
		-- Phase 2.11: Trait/Mutations restored from the audited
		-- record (PersistenceAudit cleaned them at load: nil/{}
		-- defaults, unknown ids dropped). Defensive array copy.
		Trait = (type(record.Trait) == 'string' and record.Trait or nil),
		Mutations = {},
		model = model,
		animations = placeholder.animations,
		_refs = refs,
		-- Weight-growth baseline (rejoin path): the template's
		-- authored scale. ApplyGrowthScale below then jumps
		-- straight to the persisted Level's size — no re-leveling
		-- needed.
		baseScale = _captureBaseScale(model),
		-- Phase 1.5: carry state. Rejoin-spawned animals
		-- are Slotted at their original slot (the persisted
		-- record is unchanged during carry, so a rejoin
		-- mid-carry is just "the animal is back at its
		-- original slot" — which is what Slotted means).
		state = 'Slotted',
		carriedBy = nil,
		originalSlotId = nil,
		_mutex = false,
		createdAt = os.clock(),
		XP = record.XP or 0,
	}
	if type(record.Mutations) == 'table' then
		for _, id in ipairs(record.Mutations) do
			if type(id) == 'string' then
				animal.Mutations[#animal.Mutations + 1] = id
			end
		end
	end
	animals[uniqueId] = animal

	-- OccupySlot fixes the latent bug: without this, the
	-- slot stays Reserved forever and eggs future reuse.
	-- BaseService.RestorePlayerBase already called
	-- ReserveSlot on this slot.
	if baseServiceRef and not slotServiceRef.OccupySlot(slot.id, uniqueId, SlotType.OccupantKind.Animal) then
		-- Slot wasn't Reserved (maybe an admin force-released
		-- mid-rejoin). The animal model is already placed,
		-- so we still consider this a success — the slot
		-- just won't be marked Occupied. The next cleanup
		-- pass will reset it.
		Debug.Warn('AN', 'SpawnFromPersistence: OccupySlot failed (slot not Reserved?)', {
			slotId = slot.id,
		})
	end

	-- The idle animation is already playing (set by
	-- _settleOnSlot above, which waits one Heartbeat
	-- so the Animator has applied the idle pose to
	-- the Motor6D joints before the animal's slot
	-- snapshot is taken). Replaying it here would
	-- restart the track from TimePosition 0, producing
	-- a one-frame "snap to default pose" visual
	-- artifact.
	--
	-- Weight-growth (rejoin path): jump straight to the
	-- persisted Level's physical size — no re-leveling needed
	-- for the correct size to appear. Grounded, never throws.
	AnimalService.ApplyGrowthScale(animal)
	-- NOTE (egg-only idle): Animals NEVER bind to
	-- StandPresentation (egg slot-idle wobble only).

	-- Phase 2.1: install the Pickup prompt on the animal
	-- model so the player can pick it up. Pass the slot so
	-- the prompt registers against it (used to hide other
	-- Pickup/Open prompts while the player is carrying).
	if model and model.Parent then
		CarryPrompts.InstallPickupPrompt(model, uniqueId, 'animal', slot, slot.ownerUserId)
	end

	-- Clear the controller fields. There's no in-flight
	-- controller on a rejoin-spawned animal — the model
	-- is placed, the slot is occupied, the animal is
	-- effectively Placed.
	animal.controller = nil
	animal.controllerType = nil

	-- Live overhead GUI with rejoin-restored values (Level /
	-- Trait / Mutations / stats all read from the record).
	-- Immediate: no upgrade/pick/place needed to populate.
	pcall(AnimalOverhead.EnsureForAnimal, animal)

	Debug.Log('AN', '< SpawnFromPersistence done', { uniqueId = uniqueId })
	return { success = true, animalId = uniqueId }
end

-- Drop a persisted record and release the slot it was bound
-- to. Used by SpawnFromPersistence when the template is
-- missing or the defId is unknown. Notifies the owner if
-- they are currently connected.
--
-- Safe to call before PlayerService is wired (the Notify
-- becomes a no-op in that case).
function AnimalService._dropPersistedAndNotify(
	userId: number,
	slot: any,
	defId: string,
	displayName: string,
	record: any?
)
	-- Drop the persisted record so the slot is empty on the next
	-- rejoin. Phase 2.5.1: remove by the record's own Id (the
	-- persistence key). The pre-2.5.1 call passed the SlotId into
	-- the Id-keyed RemoveAnimal — a silent no-op — so a record
	-- whose definition/template vanished survived in the profile
	-- forever and re-logged this same drop on every rejoin. The
	-- by-slot fallback covers a record whose Id can't be trusted.
	if playerServiceRef then
		local removed = false
		if record and type(record.Id) == 'string' and playerServiceRef.RemoveAnimal then
			removed = playerServiceRef.RemoveAnimal(userId, record.Id)
		end
		if not removed and playerServiceRef.RemoveAnimalAtSlot then
			removed = playerServiceRef.RemoveAnimalAtSlot(userId, slot.id)
		end
		if not removed then
			Debug.Warn('AN', '_dropPersistedAndNotify: no persisted record removed', {
				userId = tostring(userId),
				defId = tostring(defId),
				slotId = tostring(slot and slot.id),
				recordId = tostring(record and record.Id),
			})
		end
	end
	-- Release the slot. The slot was Reserved by
	-- RestorePlayerBase; we flip it back to Empty.
	if baseServiceRef and slotServiceRef.ReleaseSlot then
		slotServiceRef.ReleaseSlot(slot.id)
	end
	-- Notify the owner if they're connected. The displayName
	-- may be "(unknown definition)" if the defId was never
	-- in the catalog.
	local owner = Players:GetPlayerByUserId(userId)
	if owner and playerServiceRef and playerServiceRef.Notify then
		playerServiceRef.Notify(owner, 'Warning', displayName .. ' was removed because its model is missing.')
	end
	Debug.Warn('AN', '_dropPersistedAndNotify: dropped', { userId = tostring(userId), defId = defId, slotId = slot.id })
end

-- --- Reads -----------------------------------------------------

function AnimalService.Get(uniqueId: string): any?
	Validation.ShortString(uniqueId)
	return animals[uniqueId]
end

-- Canonical stand -> live animal resolution. Matches direct Model
-- children of the stand against the live registry by Instance
-- identity (never by Model.Name — duplicates share names across
-- stands). Returns the animal record or nil for empty stands.
-- Never throws; never creates anything.
function AnimalService.GetStandAnimal(stand: Instance?): any?
	if typeof(stand) ~= 'Instance' then
		return nil
	end
	local found: any? = nil
	pcall(function()
		for _, child in ipairs((stand :: Instance):GetChildren()) do
			if child:IsA('Model') then
				for _, animal in pairs(animals) do
					if type(animal) == 'table' and animal.model == child then
						found = animal
						return
					end
				end
			end
		end
	end)
	return found
end

-- Warn-only placement audit for one slot: the occupant's live
-- model must sit directly under slot.stand. Used by development
-- validation; never destroys or reparents.
function AnimalService.ValidateStandPlacement(slot: any): boolean
	if type(slot) ~= 'table' then
		return false
	end
	local ok = false
	pcall(function()
		local stand = slot.stand
		if typeof(stand) ~= 'Instance' then
			return
		end
		local occupant: any? = nil
		if slot.occupantId ~= nil and slotServiceRef and slotServiceRef.FindSlotByOccupant then
			local check: any = nil
			pcall(function()
				check = slotServiceRef.FindSlotByOccupant(slot.occupantId)
			end)
			if type(check) == 'table' and check.id == slot.id then
				pcall(function()
					occupant = AnimalService.Get(slot.occupantId)
				end)
			end
		end
		if type(occupant) ~= 'table' then
			return
		end
		local model = occupant.model
		if typeof(model) ~= 'Instance' then
			return
		end
		if (model :: Model).Parent == stand then
			ok = true
			return
		end
		Debug.Warn('AN', 'StandPlacement: occupant model not under its stand', {
			slotId = tostring(slot.id),
			animalId = tostring(slot.occupantId),
		})
	end)
	return ok
end

function AnimalService.ListForPlayer(userId: number): { any }
	Validation.PositiveInteger(userId)
	local out = {}
	for _, animal in pairs(animals) do
		if animal.ownerUserId == userId then
			-- Phase 2.5: derived stats, recomputed from the canonical
			-- Level (same authoritative path as every other reader).
			local stats = AnimalStats.Snapshot(animal)
			out[#out + 1] = {
				UniqueId = animal.uniqueId,
				DefinitionId = animal.definitionId,
				DisplayName = animal.displayName,
				Rarity = animal.rarity,
				SlotId = animal.slotId,
				State = animal.state,
				Level = animal.Level or 1,
				Health = stats.Health,
				Damage = stats.Damage,
			}
		end
	end
	return out
end

-- --- Carry (Phase 1.5) -----------------------------------------

-- Pure checks. Return nil on success, or a string error reason
-- otherwise. Used by the prompt callback to pre-validate before
-- committing (and by tests to assert the rejection paths).
function AnimalService.CanGrabAnimal(player: Player, animalId: string): string?
	-- The same validation is inlined in GrabAnimal. Keeping
	-- a separate entry point lets tests + admin commands probe
	-- the validation without committing.
	if not Validation.LivePlayer(player) then
		return AnimalService.Error.InvalidPlayer
	end
	local animal = animals[animalId]
	if not animal then
		return AnimalService.Error.AnimalNotFound
	end
	if animal.ownerUserId ~= player.UserId then
		return AnimalService.Error.NotOwner
	end
	if ArenaService.IsAnimalRaidLocked(animalId) then
		return AnimalService.Error.RaidLocked
	end
	if animal.state == 'Carried' then
		return AnimalService.Error.AlreadyCarried
	end
	if CarryRegistry.IsCarrying(player) then
		return AnimalService.Error.PlayerAlreadyCarrying
	end
	if not animal.slotId then
		return AnimalService.Error.NotSlotted
	end
	local slot = _findSlotById(animal.slotId)
	if not slot then
		return AnimalService.Error.InvalidSlot
	end
	if slot.state ~= SlotType.State.Occupied or slot.occupantId ~= animalId then
		return AnimalService.Error.NotSlotted
	end
	if slot.ownerUserId ~= player.UserId then
		-- Cross-base defense: the slot's userId prefix must
		-- match the requesting player. _findSlotById already
		-- checks the prefix, but this is defensive.
		return AnimalService.Error.NotOwner
	end
	-- Distance check (server-side; ProximityPrompt's
	-- MaxActivationDistance is the client hint, not the
	-- security boundary).
	local character = player.Character
	if not character then
		return AnimalService.Error.TooFar
	end
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		return AnimalService.Error.TooFar
	end
	if (hrp.Position - slot.part.Position).Magnitude > AnimalConfig.Carry.MaxDistance then
		return AnimalService.Error.TooFar
	end
	return nil
end

function AnimalService.CanPlaceAnimal(player: Player, animalId: string, destSlotId: string): string?
	if not Validation.LivePlayer(player) then
		return AnimalService.Error.InvalidPlayer
	end
	local animal = animals[animalId]
	if not animal then
		return AnimalService.Error.AnimalNotFound
	end
	if animal.ownerUserId ~= player.UserId then
		return AnimalService.Error.NotOwner
	end
	if animal.state ~= 'Carried' or animal.carriedBy ~= player.UserId then
		return AnimalService.Error.NotCarried
	end
	local dest = _findSlotById(destSlotId)
	if not dest then
		return AnimalService.Error.InvalidSlot
	end
	if dest.ownerUserId ~= player.UserId then
		return AnimalService.Error.NotOwner
	end
	-- Phase 2: Destination can be:
	--   * Empty (any other slot) — place-elsewhere.
	--   * Reserved — only if it's the carried animal's
	--     own originalSlotId (the carry-reservation
	--     placed there by Demote on grab). This is the
	--     same-slot return path. ReserveSlot is
	--     idempotent on already-Reserved so the place
	--     just occupies directly.
	if dest.state == SlotType.State.Occupied then
		return AnimalService.Error.SlotOccupied
	end
	if dest.state == SlotType.State.Reserved and dest.id ~= animal.originalSlotId then
		return AnimalService.Error.SlotReserved
	end
	if dest.state ~= SlotType.State.Empty and dest.state ~= SlotType.State.Reserved then
		return AnimalService.Error.InvalidSlot
	end
	-- Distance check.
	local character = player.Character
	if not character then
		return AnimalService.Error.TooFar
	end
	local hrp = character:FindFirstChild('HumanoidRootPart')
	if not hrp or not hrp:IsA('BasePart') then
		return AnimalService.Error.TooFar
	end
	if (hrp.Position - dest.part.Position).Magnitude > AnimalConfig.Carry.MaxDistance then
		return AnimalService.Error.TooFar
	end
	return nil
end

-- Atomic grab. Validates, mutates, fires remote, returns
-- error reason on failure. The validation phase (steps 1-10
-- in the plan) runs BEFORE any state mutation, so on rejection
-- there is nothing to roll back.
function AnimalService.GrabAnimal(player: Player, animalId: string): string?
	Debug.Log('AN', '> GrabAnimal', { userId = tostring(player.UserId), uniqueId = animalId })
	-- Step 1-10: validation. All checks BEFORE any mutation.
	local reason = AnimalService.CanGrabAnimal(player, animalId)
	if reason then
		Debug.Log('AN', 'GrabAnimal: validation failed', { reason = reason })
		return reason
	end
	-- Death/reset lockout: dead/dying/respawning players have
	-- ZERO grab authority. Checked here (not in CanGrabAnimal)
	-- so the pure validator stays probeable in tests.
	if not Validation.CanPlayerInteract(player) then
		Debug.Log('AN', 'GrabAnimal: player not live')
		return AnimalService.Error.PlayerNotLive
	end
	local animal = animals[animalId] :: any
	local slot = _findSlotById(animal.slotId) :: any

	-- Step 11: acquire the transaction lock.
	animal._mutex = true

	-- Step 12: Phase 2 — demote the source slot
	-- (Occupied → Reserved). The slot is held for the
	-- player's return; the carry-reservation invariant
	-- (source slot stays Reserved on grab) means a
	-- same-slot return is just Reserved → Occupied, and a
	-- different-slot return is Reserved → Empty + a fresh
	-- Empty → Reserved → Occupied on the destination.
	if baseServiceRef and not slotServiceRef.DemoteSlotToReserved(slot.id) then
		-- Demote failed: the slot is not currently Occupied
		-- (e.g. another flow started a transition). Race.
		animal._mutex = false
		Debug.Warn('AN', 'GrabAnimal: DemoteSlotToReserved failed', { slotId = slot.id })
		return AnimalService.Error.InvalidSlot
	end

	-- Step 13: update the record. Capture the source slot
	-- as originalSlotId for recovery.
	animal.state = 'Carried'
	animal.carriedBy = player.UserId
	animal.originalSlotId = animal.slotId
	animal.slotId = nil
	-- Phase 2: register the carry in CarryRegistry (the
	-- shared state across both lucky-egg and animal
	-- carry). The kind discriminator is what
	-- EggService uses to refuse animal-while-
	-- carrying (and vice versa).
	local ok, carryErr = CarryRegistry.Set(player.UserId, {
		kind = SlotType.OccupantKind.Animal,
		record = animal,
		originalSlotId = animal.originalSlotId,
		startedAt = os.clock(),
	})
	if not ok then
		-- Rollback: undo the demote, restore the slot
		-- occupancy, return the error.
		slotServiceRef.OccupySlot(slot.id, animal.uniqueId, SlotType.OccupantKind.Animal)
		animal.state = 'Slotted'
		animal.carriedBy = nil
		animal.slotId = animal.originalSlotId
		animal.originalSlotId = nil
		animal._mutex = false
		Debug.Warn('AN', 'GrabAnimal: CarryRegistry.Set failed', { err = tostring(carryErr) })
		return AnimalService.Error.AlreadyCarrying
	end

	-- Step 14: remove the Pickup prompt from the carried
	-- model (the carried model has no prompt — the Place
	-- prompt lives on the player's base slot parts instead).
	-- Then install Place prompts on every eligible slot of
	-- the player's base (all Empty slots + the source slot
	-- they just demoted, which is now Reserved for them).
	-- Finally, hide every other Pickup/Open prompt on the
	-- player's base so the carrying player isn't shown
	-- affordances that will just be rejected.
	if animal.model then
		CarryPrompts.RemovePromptsFromModel(animal.model)
	end
	local playerBase = baseServiceRef and baseServiceRef.GetBaseByOwner and baseServiceRef.GetBaseByOwner(player.UserId)
	if playerBase then
		CarryPrompts.InstallPlacePromptsForBase(playerBase, player.UserId, SlotType.OccupantKind.Animal)
		CarryPrompts.DisablePickupHatchPromptsForBase(playerBase)
	end

	-- Step 15: the original slot is now Reserved (per the
	-- Demote transition) and is included in the Place-prompt
	-- set above (eligible because ownerUserId == playerId).
	-- Same-slot return is therefore always available to the
	-- carrying player: they can always place back into the
	-- slot they just grabbed from, even if their mood changes.

	-- Step 16: spawn the carry controller. The model is
	-- reparented to Workspace.Animals.Carried_<userId> and
	-- drives per Heartbeat.
	local character = player.Character
	if character and animal.model and animal.model.Parent then
		-- Idempotent: if there's already a controller (e.g.
		-- the animal was Carried and we're somehow re-
		-- grabbing), stop the old one first.
		if animal.controller and CarryController.IsRunning(animal.controller) then
			CarryController.Stop(animal.controller)
		end
		animal.controllerType = 'Carry'
		animal.controller = CarryController.Start(animal, player.UserId, character, player)
		-- NOTE (egg-only idle): animals are never bound to
		-- StandPresentation, so there is nothing to unbind here.
	end

	-- Step 17: push state + fire AnimalCarried so the
	-- HUD can update (the slot is now Empty, the animal
	-- is in the player's hand).
	if playerServiceRef and baseServiceRef then
		playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
		Remotes.FireClient(player, Remotes.Names.AnimalCarried, {
			UniqueId = animal.uniqueId,
			DefinitionId = animal.definitionId,
			DisplayName = animal.displayName,
			Rarity = animal.rarity,
		})
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Pickup_Success',
			{ Name = animal.displayName, Rarity = animal.rarity }
		)
	end

	animal._mutex = false
	Debug.Log('AN', '< GrabAnimal ok', { uniqueId = animalId })
	-- Tutorial guide layer observes the committed grab (bus
	-- never throws; the grab itself is unaffected).
	pcall(TutorialSignals.Fire, 'AnimalPickedUp', { UserId = player.UserId, AnimalId = animalId })
	return nil
end

-- Atomic place. Mirrors GrabAnimal's structure: validate,
-- commit, fire remote.
function AnimalService.PlaceAnimal(player: Player, animalId: string, destSlotId: string): string?
	Debug.Log('AN', '> PlaceAnimal', {
		userId = tostring(player.UserId),
		uniqueId = animalId,
		destSlotId = destSlotId,
	})
	local reason = AnimalService.CanPlaceAnimal(player, animalId, destSlotId)
	if reason then
		Debug.Log('AN', 'PlaceAnimal: validation failed', { reason = reason })
		return reason
	end
	-- Death/reset lockout (see GrabAnimal).
	if not Validation.CanPlayerInteract(player) then
		Debug.Log('AN', 'PlaceAnimal: player not live')
		return AnimalService.Error.PlayerNotLive
	end
	-- Steal (multiplayer): a steal-carried animal must be
	-- delivered to the thief's collector (StealService
	-- completion) — normal Place is rejected so a stolen
	-- object can never be laundered into a base via place.
	local carryItem = CarryRegistry.Get(player)
	if carryItem and carryItem.steal ~= nil then
		Debug.Log('AN', 'PlaceAnimal: steal in progress, use collector delivery')
		return AnimalService.Error.StealInProgress
	end
	local animal = animals[animalId] :: any
	local dest = _findSlotById(destSlotId) :: any

	-- Step 10: acquire the transaction lock.
	animal._mutex = true

	-- Step 11: Phase 2. Same-slot return: the destination
	-- is the carried animal's own originalSlotId (which
	-- is currently Reserved thanks to Demote on grab).
	-- ReserveSlot is idempotent on already-Reserved so
	-- it's a no-op success here. We just OccupySlot
	-- directly to flip Reserved → Occupied.
	--
	-- Different-slot place: release the source (Reserved →
	-- Empty) and reserve + occupy the destination.
	local isSameSlot = destSlotId == animal.originalSlotId
	if isSameSlot then
		-- Idempotent on already-Reserved: returns true
		-- without changing state.
		if not slotServiceRef.ReserveSlot(destSlotId) then
			animal._mutex = false
			Debug.Warn('AN', 'PlaceAnimal: same-slot reserve race')
			return AnimalService.Error.SlotReserved
		end
	else
		-- Different-slot path. Release the source first
		-- (Reserved → Empty), then reserve + occupy the
		-- destination.
		if animal.originalSlotId then
			slotServiceRef.ReleaseSlot(animal.originalSlotId)
		end
		if not slotServiceRef.ReserveSlot(destSlotId) then
			animal._mutex = false
			Debug.Warn('AN', 'PlaceAnimal: ReserveSlot race')
			return AnimalService.Error.SlotReserved
		end
	end

	-- Step 12: update PlayerData. Re-point the SAME record to
	-- the destination slot (Phase 2.5.1 §12: a rearrangement
	-- moves the record; it must never re-create it — the old
	-- Remove+Add pair reset Level/XP to 1/0 on every cross-slot
	-- place, wiping progression). SetAnimalSlot mutates the
	-- record in place; the Add fallback (carrying the runtime's
	-- current Level/XP) covers a record that is genuinely
	-- missing, loudly. Same-slot places skip this (the slot id
	-- didn't change).
	if playerServiceRef and not isSameSlot then
		local rePointed = playerServiceRef.SetAnimalSlot
			and playerServiceRef.SetAnimalSlot(player.UserId, animal.uniqueId, destSlotId)
		if not rePointed and playerServiceRef.AddAnimal then
			playerServiceRef.AddAnimal(player.UserId, destSlotId, animal.definitionId, animal.uniqueId, {
				Level = animal.Level,
				XP = animal.XP,
				Trait = animal.Trait,
				Mutations = animal.Mutations,
			})
			Debug.Warn('AN', 'PlaceAnimal: persisted record was missing, re-added at the destination', {
				userId = tostring(player.UserId),
				uniqueId = animal.uniqueId,
				slotId = destSlotId,
			})
		end
	end

	-- Step 13: occupy the destination slot. The 3rd arg
	-- is the occupant kind (Phase 2: stamps slot.occupantKind
	-- so the wire snapshot knows what's on the slot).
	if not slotServiceRef.OccupySlot(destSlotId, animal.uniqueId, SlotType.OccupantKind.Animal) then
		-- Should not happen; we just reserved it. Bail
		-- without rolling back PlayerData (the SetAnimalSlot
		-- above is harmless on its own; a re-try can re-
		-- OccupySlot).
		animal._mutex = false
		Debug.Warn('AN', 'PlaceAnimal: OccupySlot failed', { slotId = destSlotId })
		return AnimalService.Error.InvalidSlot
	end

	-- Step 14: stop the carry controller and update the
	-- record. Clear the CarryRegistry entry. Seat the
	-- model under the destination Stand.
	if animal.controller and CarryController.IsRunning(animal.controller) then
		CarryController.Stop(animal.controller)
	end
	animal.controller = nil
	animal.controllerType = nil
	animal.state = 'Slotted'
	animal.slotId = destSlotId
	animal.originalSlotId = nil
	animal.carriedBy = nil
	CarryRegistry.Clear(player.UserId)

	-- Reparent the model under the destination Stand (so it is not
	-- parented to a stale Carried_<uid> folder if the player
	-- carries again later). Falls back to the shared folder,
	-- warned, if the stand is unusable.
	if animal.model and animal.model.Parent then
		AnimalService.Init() -- ensure folder exists
		_seatModelAtStand(animal.model, dest)
		_warnUnlessSeated(animal, dest, 'PlaceAnimal')
		-- Re-anchor the model at the slot using the
		-- canonical anchored-HRP + free-limbs pattern.
		-- CarryController.Stop set every part Anchored
		-- = true (including the limbs), which freezes
		-- the rig: anchored limbs don't move their
		-- Motor6D children, so the Animator's idle
		-- track plays but the limbs don't visibly
		-- cycle. Result: the animal is "stuck in the
		-- animation pose" — frozen at whatever pose
		-- the joint solver last computed. _anchorAll
		-- sets primary.Anchored = true and unanchors
		-- all other parts, so the Motor6D joints can
		-- rotate freely and the idle animation
		-- animates visibly. This is the same pattern
		-- SpawnFromPersistence uses (line 743) and the
		-- same pattern the walk-settle path inherits
		-- from the WalkController.
		_anchorAll(animal.model)
		-- Step 15: place flush with the slot top. The animal
		-- faces the stand's button base (StandingCFrameOnSlot
		-- applies the button-base yaw) — not the player's
		-- look direction. The carried pose is the one that
		-- follows the player; the slotted pose is the one
		-- that faces the button. _settleOnSlot kills
		-- the carry/idle tracks, plays idle, waits one
		-- Heartbeat so the Animator applies the idle pose,
		-- then computes the target CFrame from the idle-pose
		-- rig. The Place path was correct by accident
		-- (AnimationTrack:Stop's 0.1s fade-out left the rig
		-- in the carry/idle pose when the math ran); making
		-- it pose-independent removes that fragile
		-- coincidence.
		_disableAllCollisions(animal.model)
		_settleOnSlot(animal, dest, animal.model)
		-- NOTE (egg-only idle): animals are never bound to
		-- StandPresentation (egg slot-idle wobble only).
	end

	-- Step 16: the carry is over; the carried model is now
	-- the placed model on dest. Remove every Place prompt
	-- from the player's base slot parts (the carry is done,
	-- the slot grid is no longer the affordance) and install
	-- the Pickup prompt on the placed model (its
	-- PrimaryPart). Pickup on the placed model is the
	-- player's only affordance now until they pick it up
	-- again.
	if animal.model and animal.model.Parent then
		CarryPrompts.InstallPickupPrompt(animal.model, animal.uniqueId, 'animal', dest, dest.ownerUserId)
	end
	local playerBase = baseServiceRef and baseServiceRef.GetBaseByOwner and baseServiceRef.GetBaseByOwner(player.UserId)
	if playerBase then
		CarryPrompts.RemovePlacePromptsForBase(playerBase)
		CarryPrompts.EnablePickupHatchPromptsForBase(playerBase)
	end

	-- Step 17: push state + fire AnimalPlaced.
	if playerServiceRef and baseServiceRef then
		playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
		Remotes.FireClient(player, Remotes.Names.AnimalPlaced, {
			UniqueId = animal.uniqueId,
			SlotId = destSlotId,
		})
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Place_Success',
			{ Name = animal.displayName, Rarity = animal.rarity }
		)
	end

	animal._mutex = false
	Debug.Log('AN', '< PlaceAnimal ok', { uniqueId = animalId, destSlotId = destSlotId })
	-- Tutorial guide layer observes the committed placement
	-- (bus never throws; the placement itself is unaffected).
	pcall(TutorialSignals.Fire, 'AnimalPlaced', { UserId = player.UserId, AnimalId = animalId, SlotId = destSlotId })
	-- Funnel: first placement (slot occupied + persisted above).
	pcall(function()
		FunnelService:LogStep(player, 'Onboarding', 'FirstAnimalPlaced', nil)
	end)
	return nil
end

-- Read: returns the animal the given player is currently
-- carrying, or nil. Phase 2: thin wrapper over
-- CarryRegistry. Asserts the carried kind is an animal —
-- a player carrying a lucky egg returns nil here so
-- the animal-specific call sites stay correct.
function AnimalService.GetCarriedAnimal(player: Player): any?
	if not player or not Validation.LivePlayer(player) then
		return nil
	end
	local item = CarryRegistry.Get(player)
	if not item or item.kind ~= SlotType.OccupantKind.Animal then
		return nil
	end
	return item.record
end

-- Read: returns true if the given player is currently
-- carrying an animal. O(1) via the CarryRegistry.
-- This is the authoritative global interaction check —
-- any server-side action that should be blocked while
-- carrying (Egg purchase/open, secondary grab
-- attempts, etc.) calls this. Centralizing the check
-- here means a single source of truth for the carry
-- state; systems don't need to know about the internal
-- carry state.
function AnimalService.IsCarryingAnimal(player: Player): boolean
	if not player then
		return false
	end
	return AnimalService.GetCarriedAnimal(player) ~= nil
end

-- Read: same as above but takes a userId directly. Used by
-- tests + the disconnect / death recovery paths.
function AnimalService.GetCarriedAnimalByUserId(userId: number): any?
	Validation.PositiveInteger(userId)
	local item = CarryRegistry.Get(userId)
	if not item or item.kind ~= SlotType.OccupantKind.Animal then
		return nil
	end
	return item.record
end

-- Ownership helpers (spec §28 API). Centralized so the prompt
-- callback doesn't have to know the internal slot data shape.
function AnimalService.IsAnimalOwnedByPlayer(animalId: string, player: Player): boolean
	if not player then
		return false
	end
	local animal = animals[animalId]
	return animal ~= nil and animal.ownerUserId == player.UserId
end

function AnimalService.IsSlotOwnedByPlayer(slotId: string, player: Player): boolean
	if not player then
		return false
	end
	local slot = _findSlotById(slotId)
	return slot ~= nil and slot.ownerUserId == player.UserId
end

-- Recovery. Called on disconnect, death, or admin force-
-- release. Behavior:
--   1. Find the carried animal for this userId.
--   2. Stop the carry controller.
--   3. Decide where the animal goes:
--        a. originalSlotId is still a valid slot in the
--           player's CURRENT base → return to that slot
--           (OccupySlot it, clear carry state).
--        b. originalSlotId is invalid (base was released,
--           slot destroyed) → fall back to the first
--           empty animal slot in the player's CURRENT
--           base.
--        c. No empty slot anywhere → set state to
--           'Recovering', leave the model parked under
--           Workspace.Animals.Recovering. The animal
--           is NOT destroyed; it waits for an empty slot.
--   4. Remove any lingering place prompts.
--
-- The `player` argument may be nil on disconnect (the player
-- is no longer in-game). All fallbacks in (3) work without
-- a player reference.
-- Carry-end replication for animal recovery. Clearing the
-- registry is NOT enough: the client's PromptOwnerFilter
-- hides Pickup/Hatch/Buy prompts while its last PlayerState
-- still says carrying, so every recovery path must push —
-- exactly like the egg recovery path already does. Missing
-- this push strands the player with invisible prompts and
-- zero errors until rejoin.
local function pushCarryCleared(userId: number)
	pcall(function()
		local player = Players:GetPlayerByUserId(userId)
		if player == nil then
			return
		end
		if playerServiceRef and playerServiceRef.PushState and baseServiceRef and baseServiceRef.Snapshot then
			playerServiceRef.PushState(player, baseServiceRef.Snapshot(userId))
		end
	end)
end

function AnimalService.RecoverCarriedAnimal(playerOrUserId: any, reason: string)
	Debug.Log('AN', '> RecoverCarriedAnimal', { reason = reason })
	local userId: number
	if typeof(playerOrUserId) == 'Instance' and playerOrUserId:IsA('Player') then
		local _player = playerOrUserId
		userId = _player.UserId
	elseif type(playerOrUserId) == 'number' then
		userId = playerOrUserId
	else
		Debug.Warn('AN', 'RecoverCarriedAnimal: invalid argument', { arg = type(playerOrUserId) })
		return
	end
	local item = CarryRegistry.Get(userId)
	if not item or item.kind ~= SlotType.OccupantKind.Animal then
		-- Nothing to recover (player wasn't carrying a
		-- animal, or wasn't carrying anything). The
		-- CleanupPlayer / death hook calls this
		-- defensively on every leave/respawn, so a no-op
		-- is expected for the common case.
		Debug.Log('AN', 'RecoverCarriedAnimal: no carried animal, no-op')
		return
	end
	local animal = item.record

	-- Stop the carry controller first so the model stops
	-- following the (potentially destroyed) character.
	if animal.controller and CarryController.IsRunning(animal.controller) then
		CarryController.Stop(animal.controller)
	end
	animal.controller = nil
	animal.controllerType = nil

	-- Try the original slot first. Phase 2: the original
	-- slot is in Reserved state (the carry-reservation
	-- placed there by Demote on grab), so we just
	-- OccupySlot it directly (Reserved → Occupied).
	local originalSlot = animal.originalSlotId and _findSlotById(animal.originalSlotId) or nil
	if originalSlot and originalSlot.state == SlotType.State.Reserved and originalSlot.ownerUserId == userId then
		-- Best case: original slot is still ours and is
		-- Reserved. Occupy it (Reserved → Occupied) and
		-- clear the carry state.
		if
			baseServiceRef and slotServiceRef.OccupySlot(originalSlot.id, animal.uniqueId, SlotType.OccupantKind.Animal)
		then
			animal.state = 'Slotted'
			animal.slotId = originalSlot.id
			animal.originalSlotId = nil
			animal.carriedBy = nil
			CarryRegistry.Clear(userId)
			-- Snap the model to the slot's standing CFrame
			-- using the canonical settle (stop all tracks,
			-- play idle, wait one Heartbeat, then compute
			-- from the idle-pose rig). Without this, the
			-- recovered animal would float by the same
			-- pose difference that affects the Walk and
			-- Rejoin paths.
			if animal.model and animal.model.Parent then
				AnimalService.Init()
				_seatModelAtStand(animal.model, originalSlot)
				_warnUnlessSeated(animal, originalSlot, 'RecoverCarriedAnimal/original')
				_anchorAll(animal.model)
				_settleOnSlot(animal, originalSlot, animal.model)
				-- NOTE (egg-only idle): animals never bind here.
			end
			-- Refresh prompts: install Pickup on the now-
			-- placed model. Pass the slot so the prompt
			-- registers against it (used to hide other
			-- Pickup/Open prompts while carrying).
			if animal.model and animal.model.Parent then
				CarryPrompts.InstallPickupPrompt(
					animal.model,
					animal.uniqueId,
					'animal',
					originalSlot,
					originalSlot.ownerUserId
				)
			end
			-- Remove every Place prompt from the player's
			-- base slot parts (the carry is over). Re-enable
			-- Pickup/Open prompts on the player's base now
			-- that the carry is over.
			local playerBase = baseServiceRef
				and baseServiceRef.GetBaseByOwner
				and baseServiceRef.GetBaseByOwner(userId)
			if playerBase then
				CarryPrompts.RemovePlacePromptsForBase(playerBase)
				CarryPrompts.EnablePickupHatchPromptsForBase(playerBase)
			end
			Debug.Log('AN', '< RecoverCarriedAnimal: returned to original slot', {
				uniqueId = animal.uniqueId,
				slotId = originalSlot.id,
			})
			pushCarryCleared(userId)
			return
		end
	end

	-- Fallback: find the first empty slot in the player's
	-- CURRENT base. Phase 2: the unified pool, no
	-- `animalSlots` sub-iter.
	local base = baseServiceRef and baseServiceRef.GetBaseByOwner(userId)
	if base then
		for _, slot in pairs(base.slots) do
			if slot.state == SlotType.State.Empty then
				-- ReserveSlot first (slot must transition
				-- Empty → Reserved → Occupied per the
				-- state machine; ReserveSlot is the only
				-- way to flip Empty to Reserved and then
				-- we OccupySlot to land it Occupied).
				if
					slotServiceRef.ReserveSlot(slot.id)
					and slotServiceRef.OccupySlot(slot.id, animal.uniqueId, SlotType.OccupantKind.Animal)
				then
					-- Persistence update: re-point the SAME record
					-- (Phase 2.5.1: never Remove+Add — that reset
					-- Level/XP). The Add fallback preserves the
					-- runtime Level/XP if the record is missing.
					if playerServiceRef then
						local rePointed = playerServiceRef.SetAnimalSlot
							and playerServiceRef.SetAnimalSlot(userId, animal.uniqueId, slot.id)
						if not rePointed and playerServiceRef.AddAnimal then
							playerServiceRef.AddAnimal(userId, slot.id, animal.definitionId, animal.uniqueId, {
								Level = animal.Level,
								XP = animal.XP,
								Trait = animal.Trait,
								Mutations = animal.Mutations,
							})
							Debug.Warn('AN', 'RecoverCarriedAnimal: persisted record was missing, re-added', {
								userId = tostring(userId),
								uniqueId = animal.uniqueId,
								slotId = slot.id,
							})
						end
					end
					animal.state = 'Slotted'
					animal.slotId = slot.id
					animal.originalSlotId = nil
					animal.carriedBy = nil
					CarryRegistry.Clear(userId)
					if animal.model and animal.model.Parent then
						AnimalService.Init()
						_seatModelAtStand(animal.model, slot)
						_warnUnlessSeated(animal, slot, 'RecoverCarriedAnimal/fallback')
						_anchorAll(animal.model)
						_settleOnSlot(animal, slot, animal.model)
						-- NOTE (egg-only idle): animals never bind here.
					end
					-- Refresh prompts on the now-placed model.
					if animal.model and animal.model.Parent then
						CarryPrompts.InstallPickupPrompt(
							animal.model,
							animal.uniqueId,
							'animal',
							slot,
							slot.ownerUserId
						)
					end
					-- Remove every Place prompt from the
					-- player's base slot parts (the carry is
					-- over). Re-enable Pickup/Open prompts
					-- now that the carry is over.
					local playerBase = baseServiceRef
						and baseServiceRef.GetBaseByOwner
						and baseServiceRef.GetBaseByOwner(userId)
					if playerBase then
						CarryPrompts.RemovePlacePromptsForBase(playerBase)
						CarryPrompts.EnablePickupHatchPromptsForBase(playerBase)
					end
					Debug.Log('AN', '< RecoverCarriedAnimal: fell back to empty slot', {
						uniqueId = animal.uniqueId,
						slotId = slot.id,
					})
					pushCarryCleared(userId)
					return
				end
			end
		end
	end

	-- Last resort: no slot available. Park the animal in
	-- `Recovering` state under a dedicated folder. The model
	-- is not visible on the map. The animal will be re-
	-- placed when a slot opens (Phase 2 work).
	Debug.Warn('AN', 'RecoverCarriedAnimal: no slot available, entering Recovering', {
		uniqueId = animal.uniqueId,
	})
	animal.state = 'Recovering'
	animal.slotId = nil
	-- Keep originalSlotId and carriedBy as recovery hints.
	CarryRegistry.Clear(userId)
	-- Move the model to a Recovering folder.
	if animal.model and animal.model.Parent then
		local recovering = Workspace:FindFirstChild('Animals') and Workspace.Animals:FindFirstChild('Recovering')
		if not recovering then
			local Animals = Workspace:FindFirstChild('Animals') or Instance.new('Folder')
			if not Animals.Parent then
				Animals.Name = 'Animals'
				Animals.Parent = Workspace
			end
			recovering = Instance.new('Folder')
			recovering.Name = 'Recovering'
			recovering.Parent = Animals
		end
		animal.model.Parent = recovering
	end
	-- Cleanup the carried model's prompt (if the model
	-- still exists — it's parked in the Recovering folder
	-- above). Wipe any Place prompt that was on it.
	if animal.model and animal.model.Parent then
		CarryPrompts.RemovePromptsFromModel(animal.model)
	end
	-- Remove every Place prompt from the player's base
	-- slot parts (the carry is over, the model is in
	-- Recovering — there is no affordance for the player
	-- until a slot opens). Re-enable Pickup/Open prompts
	-- since the carry is over even though the animal
	-- itself is parked in Recovering.
	local playerBase = baseServiceRef and baseServiceRef.GetBaseByOwner and baseServiceRef.GetBaseByOwner(userId)
	if playerBase then
		CarryPrompts.RemovePlacePromptsForBase(playerBase)
		CarryPrompts.EnablePickupHatchPromptsForBase(playerBase)
	end
	pushCarryCleared(userId)
end

-- Public settle seam for server-authoritative flows that move
-- an animal model onto a slot WITHOUT going through
-- PlaceAnimal (StealService completion/rollback). Seats under the
-- slot's Stand, anchors, snaps to the slot's
-- standing CFrame via the canonical settle, and refreshes the
-- Pickup prompt. No occupancy changes (caller owns slot
-- transitions), no carry checks. Never throws; no-op when the
-- model is gone (caller still owns record/slot repair).
function AnimalService.SettleModelAtSlot(animal: any, slot: any)
	pcall(function()
		if type(animal) ~= 'table' or type(slot) ~= 'table' then
			return
		end
		local model = animal.model
		if model == nil or (typeof(model) == 'Instance' and (model :: Instance).Parent == nil) then
			return
		end
		AnimalService.Init()
		_seatModelAtStand(model, slot)
		_warnUnlessSeated(animal, slot, 'SettleModelAtSlot')
		_anchorAll(model)
		_disableAllCollisions(model)
		_settleOnSlot(animal, slot, model)
		if typeof(model) == 'Instance' and (model :: Instance).Parent ~= nil then
			CarryPrompts.InstallPickupPrompt(model, animal.uniqueId, 'animal', slot, slot.ownerUserId)
		end
	end)
end

-- --- Cleanup ---------------------------------------------------

function AnimalService.ForceReleaseBase(baseId: string)
	Validation.ShortString(baseId)
	-- Phase 1.5: handle BOTH slotted and carried animals. The
	-- original implementation only iterated `animal.slotId`, which
	-- misses carried animals (slotId is nil while Carried).
	-- Without this fix, a wipe-while-carrying leaves an orphan
	-- record in `animals` and an orphan model in
	-- Workspace.Animals.Carried_<userId>.
	for _, animal in pairs(animals) do
		-- Steal (multiplayer): a steal-carried animal is a live
		-- transaction with the thief. An admin base wipe must
		-- not destroy it out from under the carry flow.
		if animal.stolenBy ~= nil then
			continue
		end
		local belongsToBase = false
		if animal.slotId then
			local parsed = SlotType.ParseId(animal.slotId)
			if parsed then
				local base = baseServiceRef and baseServiceRef.GetBaseByOwner(parsed.userId)
				if base and base.id == baseId then
					belongsToBase = true
				end
			end
		elseif animal.state == 'Carried' and animal.carriedBy then
			-- Carried animal: resolve the owner's base
			-- directly. The carried animal has no slotId
			-- to parse.
			local base = baseServiceRef and baseServiceRef.GetBaseByOwner(animal.carriedBy)
			if base and base.id == baseId then
				belongsToBase = true
			end
		end
		if not belongsToBase then
			continue
		end

		-- Flag the in-flight walk so the
		-- WalkController's _onComplete early-returns.
		-- The WalkController itself self-guards against
		-- `not model.Parent` (the Heartbeat callback
		-- disconnects) and returns cleanly if the model
		-- is destroyed out from under it, so the abort
		-- path is robust even without this flag.
		animal._aborted = true
		-- Stop the carry controller if running. Idempotent.
		if animal.controller and CarryController.IsRunning(animal.controller) then
			CarryController.Stop(animal.controller)
		end
		animal.controller = nil
		animal.controllerType = nil
		-- Remove from the carry registry if this animal
		-- was being carried.
		if animal.carriedBy then
			CarryRegistry.Clear(animal.carriedBy)
		end
		-- Remove from persisted data. The record Id (animal.uniqueId)
		-- is the persistence key; the persisted SlotId is
		-- animal.slotId or animal.originalSlotId (persistence was never
		-- mutated during carry). This is a genuine destroy — the
		-- record is meant to go.
		local persistedSlot = animal.slotId or animal.originalSlotId
		if persistedSlot and playerServiceRef and playerServiceRef.RemoveAnimal then
			playerServiceRef.RemoveAnimal(animal.ownerUserId, animal.uniqueId)
		end
		-- Defensive: wipe any prompt on the model (it'll be
		-- destroyed below). Native prompts live on the model,
		-- not on a base-wide collection, so there's no shared
		-- prompt registry to drain. (Animals are never bound to
		-- the egg-only StandPresentation, so no unbind needed.)
		if animal.model then
			CarryPrompts.RemovePromptsFromModel(animal.model)
			animal.model:Destroy()
		end
		animals[animal.uniqueId] = nil
		-- Arena deployment entries die with the record: a
		-- wiped base can never strand a parked entry.
		_dropArenaParked(animal.uniqueId)
	end
end

function AnimalService.CleanupPlayer(userId: number)
	-- Phase 1: leaving the server is NOT destructive for slotted
	-- animals. They are persisted in PlayerService; on rejoin,
	-- RestorePlayerBase re-spawns them.
	--
	-- Phase 1.5: a player who disconnects WHILE CARRYING a
	-- animal must have the carry cleared so the rejoin path
	-- sees the animal at its original slot (the persisted
	-- record was never mutated during carry, so the rejoin
	-- `SpawnFromPersistence` will land it at originalSlotId).
	-- Without this, the in-memory carry state survives the
	-- disconnect and the next rejoin's PushState is wrong
	-- (the animal's slot is Empty but the animal is
	-- "Carried" by a userId that no longer exists).
	Validation.PositiveInteger(userId)
	-- Steal (multiplayer): a steal-carry is owned by
	-- StealService, not by the generic owner-assuming recover
	-- below (which would place A's animal into B's base and
	-- corrupt B's profile). Roll back to the original owner.
	-- Lazy require: StealService top-requires this module.
	local stealHandled = false
	do
		local ok, stealSvc = pcall(require, script.Parent.Steal.StealService)
		if ok and stealSvc then
			stealHandled = stealSvc.RollbackIfStealing(userId, 'disconnect')
		end
	end
	-- Phase 2: ask the carry registry. A player can only be
	-- carrying an animal here (the lucky egg carry has
	-- its own recover path in EggService.CleanupPlayer).
	local item = CarryRegistry.Get(userId)
	if item and item.kind == SlotType.OccupantKind.Animal and not stealHandled then
		AnimalService.RecoverCarriedAnimal(userId :: any, 'disconnect')
	end
	-- Multi-player cleanup: sweep every animal owned by
	-- the leaving user. This destroys the Workspace models
	-- but PRESERVES the persisted record in
	-- playerServiceRef (we never call RemoveAnimal
	-- here). On rejoin, RestorePlayerBase re-spawns from
	-- the profile. Without this sweep, a leaving player's
	-- animal models linger in Workspace.Animals, and
	-- the next player assigned to that base sees the
	-- ghost models with stale Pickup prompts.
	--
	-- The recover step above already moved any Carried
	-- animal back to its original slot (state='Placed'),
	-- so the sweep catches it as Placed and destroys the
	-- model. The persisted record is still there; rejoin
	-- re-spawns it.
	for uniqueId, animal in pairs(animals) do
		if animal.ownerUserId == userId then
			-- Steal (multiplayer): a steal-carried animal is a
			-- live transaction with the thief. Recover it to
			-- the owner FIRST (its slot still exists this
			-- early in leave cleanup), then fall through to
			-- the normal non-destructive sweep below — never
			-- strand the thief carrying against a wiped base,
			-- never destroy the model out from under the
			-- carry flow. Lazy require: StealService
			-- top-requires this module.
			if animal.stolenBy ~= nil then
				do
					local ok, stealSvc = pcall(require, script.Parent.Steal.StealService)
					if ok and stealSvc then
						stealSvc.RollbackStolenTarget('animal', uniqueId, 'owner-leaving')
					end
				end
			end
			-- Cancel any in-flight level-up celebration so no
			-- bop/VFX thread outlives the rejoin sweep.
			pcall(LevelUpPresentation.Cancel, uniqueId)
			-- NOTE: animals are never bound to the egg-only
			-- StandPresentation, so no unbind is needed here.
			if animal.model then
				CarryPrompts.RemovePromptsFromModel(animal.model)
				animal.model:Destroy()
			end
			animals[uniqueId] = nil
			-- Leave sweep destroys models: drop any parked
			-- entry so rejoin starts clean (re-spawned
			-- animals are never parked).
			_dropArenaParked(uniqueId)
		end
	end
	-- Also clear the carried folder if it exists, as a
	-- defensive measure (the recover path above should
	-- have already destroyed the carried model via the
	-- settle-or-destroy flow).
	if animalsFolder then
		local carriedFolder = animalsFolder:FindFirstChild('Carried_' .. tostring(userId))
		if carriedFolder then
			carriedFolder:Destroy()
		end
	end
end

-- Phase 2.4: Animal Level/XP progression. Server-authoritative.
-- XP is CURRENT PROGRESS toward the next level (not lifetime XP) and
-- Level is the canonical progression level; both live on the owned
-- Animal (not definition, not slot). Representation: normal Lua
-- numbers with integer semantics enforced. All threshold math — the
-- XP curve, the level-up drain loop, the MaxLevel bank — is owned by
-- LevelConfig (spec §7: no service computes thresholds itself).
-- Zero is a no-op. Negative / NaN / inf / fractional / wrong-type
-- rejected.
function AnimalService:GetXP(animalId: string): number?
	Validation.ShortString(animalId)
	local animal = animals[animalId]
	if not animal then
		return nil
	end
	return animal.XP or 0
end

-- Canonical progression level of a registered Animal (spec §3).
function AnimalService:GetLevel(animalId: string): number?
	Validation.ShortString(animalId)
	local animal = animals[animalId]
	if not animal then
		return nil
	end
	return animal.Level or 1
end

-- Phase 2.5: the ONE authoritative way for callers to obtain a
-- registered animal's derived stats. Health/Damage are computed
-- from Level + definition + AnimalConfig.Stats through
-- AnimalStats (-> StatCalculator) — never stored, never accepted
-- from the client, never persisted. Returns nil for an unknown id.
function AnimalService.GetStats(animalId: string): any?
	Validation.ShortString(animalId)
	local animal = animals[animalId]
	if not animal then
		return nil
	end
	return AnimalStats.Snapshot(animal)
end

function AnimalService:AddXP(animalId: string, amount: number): any
	Validation.ShortString(animalId)
	if type(amount) ~= 'number' then
		return { success = false, error = 'invalid-amount' }
	end
	if amount ~= math.floor(amount) then
		return { success = false, error = 'fractional-amount' }
	end
	if amount < 0 then
		return { success = false, error = 'negative-amount' }
	end
	if amount ~= amount or amount == math.huge or amount == -math.huge then
		return { success = false, error = 'invalid-amount' }
	end
	local animal = animals[animalId]
	if not animal then
		return { success = false, error = 'no-animal' }
	end
	-- Ownership / lifecycle guard: must be a registered, non-consumed animal.
	if animal.state == 'Consumed' or animal.state == 'Destroyed' then
		return { success = false, error = 'invalid-state' }
	end
	-- Phase 2.7: apply the player's XP modifier EXACTLY ONCE, here,
	-- at the single entry point of the canonical XP pipeline:
	--   Requested XP -> x XPModifier -> AddXP -> LevelConfig.Normalize.
	-- The modifier is resolved once per grant from ModifierService
	-- (1x when unwired or when no sources are active). appliedXP is
	-- floored to an integer; with a 1x modifier requested == applied
	-- exactly. LevelConfig never sees the modifier — it only drains
	-- thresholds. Admin commands (/givexp) route through this same
	-- function, so they observe identical modifier behavior.
	local requestedXP = amount
	local xpModifier = 1
	if modifierServiceRef and modifierServiceRef.GetXPModifier and type(animal.ownerUserId) == 'number' then
		local ok, resolved = pcall(modifierServiceRef.GetXPModifier, animal.ownerUserId)
		if ok and type(resolved) == 'number' and resolved == resolved and resolved > 0 and resolved ~= math.huge then
			xpModifier = resolved
		end
	end
	local appliedXP = math.floor(requestedXP * xpModifier)
	if appliedXP ~= appliedXP or appliedXP == math.huge or appliedXP < 0 then
		-- Overflow guard: a grant so large the shaped value is no
		-- longer a finite integer fails loudly instead of silently
		-- granting nothing (Normalize would repair inf to 0).
		return { success = false, error = 'invalid-amount' }
	end
	-- Zero is deterministic no-op.
	if appliedXP == 0 then
		local level0 = animal.Level or 1
		return {
			success = true,
			newXP = animal.XP or 0,
			level = level0,
			levelsGained = 0,
			leveledUp = false,
			atMaxLevel = level0 >= LevelConfig.MaxLevel,
			requestedXP = requestedXP,
			xpModifier = xpModifier,
			appliedXP = appliedXP,
		}
	end
	local current = (type(animal.XP) == 'number' and animal.XP == math.floor(animal.XP) and animal.XP >= 0)
			and animal.XP
		or 0
	-- LevelConfig.Normalize drains every crossed threshold (spec §12
	-- step 7 / §13: iterative loop, hard `level < MaxLevel` safety
	-- condition), preserves overflow (spec §5), repairs a malformed
	-- runtime pair defensively, and applies the MaxLevel bank cap
	-- (spec §11). One call — the loop is not duplicated here.
	local newLevel, newXP, levelsGained = LevelConfig.Normalize(animal.Level or 1, current + appliedXP)
	animal.Level = newLevel
	animal.XP = newXP
	-- Authoritative owned state updated; sync back to profile
	-- so ProfileService's existing lifecycle saves both fields.
	if playerServiceRef and playerServiceRef.GetPlayerData then
		local profileData = playerServiceRef.GetPlayerData(animal.ownerUserId)
		if profileData and profileData.Brainrots then
			for _, rec in pairs(profileData.Brainrots) do
				if rec and rec.Id == animalId then
					rec.Level = newLevel
					rec.XP = newXP
					break
				end
			end
		end
	end
	-- Server-authoritative level-up presentation (happy bop +
	-- Upgrade VFX + smooth weight-growth). Fires ONLY on a real
	-- level change — never on a bare XP change. Non-blocking and
	-- fully pcall-guarded inside: presentation can never break or
	-- delay the XP mutation above.
	if levelsGained > 0 then
		local leveledAnimal = animal
		local info = {
			oldLevel = newLevel - levelsGained,
			newLevel = newLevel,
			levelsGained = levelsGained,
		}
		local okPresent, errPresent = pcall(LevelUpPresentation.NotifyLevelUp, leveledAnimal, info)
		if not okPresent then
			Debug.Warn('AN', 'AddXP: level-up presentation failed gracefully (XP unaffected)', {
				animalId = tostring(animalId),
				error = tostring(errPresent),
			})
		end
		-- Overhead follows the SAME authoritative mutation:
		-- Name/Level/Health/Damage/Generation refresh with the
		-- new Level (never waits for the bop to finish).
		pcall(AnimalOverhead.Refresh, leveledAnimal)
		-- Stand upgrade readout follows too: the open
		-- UpgradesFrame preview + the direct-upgrade
		-- Level/UpgradeAmount labels derive from Level, so a
		-- silent XP level-up (arena rewards, /givexp) would
		-- otherwise leave stale cost text behind. Re-derive
		-- through the canonical slot display pipeline (the
		-- same call the transition sites use). Guarded:
		-- display can never break the XP mutation above.
		pcall(function()
			if slotServiceRef and slotServiceRef.FindSlotByOccupant and slotServiceRef.RefreshDisplays then
				local slot = slotServiceRef.FindSlotByOccupant(animalId)
				if type(slot) == 'table' and type(slot.id) == 'string' then
					slotServiceRef.RefreshDisplays(slot.id)
				end
			end
		end)
	end
	return {
		success = true,
		newXP = newXP,
		level = newLevel,
		levelsGained = levelsGained,
		leveledUp = levelsGained > 0,
		atMaxLevel = newLevel >= LevelConfig.MaxLevel,
		requestedXP = requestedXP,
		xpModifier = xpModifier,
		appliedXP = appliedXP,
	}
end

-- All live runtime records. DebugService iterates THIS (never a
-- Workspace scan) for the centralized overhead refresh. Returns a
-- fresh array of the live record references.
function AnimalService.GetAll(): { any }
	local out: { any } = {}
	for _, animal in pairs(animals) do
		out[#out + 1] = animal
	end
	return out
end

-- Destroy ONE runtime animal record (Phase 2.8 sale path).
-- Stops any controller, wipes prompts, destroys the model, and
-- drops the registry entry. Slot release + profile removal are
-- the CALLER's job (SellService owns the sale transaction order).
-- Returns true iff a live record was destroyed. Never throws.
function AnimalService.DestroyRuntimeAnimal(uniqueId: string): boolean
	if type(uniqueId) ~= 'string' then
		return false
	end
	local animal = animals[uniqueId]
	if not animal then
		return false
	end
	-- Stop any in-flight level-up celebration first so a
	-- superseded bop loop exits without touching the dying model
	-- (no leftover tweens, no pivot writes after destroy).
	pcall(LevelUpPresentation.Cancel, uniqueId)
	if animal.controller and CarryController.IsRunning(animal.controller) then
		CarryController.Stop(animal.controller)
	end
	animal.controller = nil
	animal.controllerType = nil
	-- NOTE: animals are never bound to the egg-only
	-- StandPresentation, so no unbind is needed here.
	if animal.model then
		CarryPrompts.RemovePromptsFromModel(animal.model)
		animal.model:Destroy()
	end
	animals[uniqueId] = nil
	_dropArenaParked(uniqueId)
	return true
end

-- Apply ONE paid level upgrade (Phase 2.10 upgrade path).
-- Level += 1, XP untouched. The paid path is separate from XP
-- progression by design, and the bump can never be undone by
-- LevelConfig.Normalize: thresholds strictly increase with level
-- (GrowthRate > 1), so the unchanged XP stays below the new
-- requirement forever. Stats/income/sale derive from Level on
-- demand, so they follow automatically with no extra writes.
-- Syncs the profile record (same write AddXP performs), so the
-- upgrade persists and survives rejoin with identical Id, slot,
-- XP, CashPool, and definition. Returns { success, oldLevel,
-- newLevel } or { success = false, error }.
function AnimalService.ApplyLevelUpgrade(uniqueId: string): any
	Validation.ShortString(uniqueId)
	local animal = animals[uniqueId]
	if not animal then
		return { success = false, error = 'no-animal' }
	end
	if animal.state == 'Consumed' or animal.state == 'Destroyed' then
		return { success = false, error = 'invalid-state' }
	end
	local level = animal.Level
	if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 or level >= LevelConfig.MaxLevel then
		return { success = false, error = 'invalid-level' }
	end
	local oldLevel = level
	local newLevel = level + 1
	animal.Level = newLevel
	if playerServiceRef and playerServiceRef.GetPlayerData then
		local profileData = playerServiceRef.GetPlayerData(animal.ownerUserId)
		if profileData and profileData.Brainrots then
			for _, rec in pairs(profileData.Brainrots) do
				if rec and rec.Id == uniqueId then
					rec.Level = newLevel
					break
				end
			end
		end
	end
	-- Server-authoritative level-up presentation (happy bop +
	-- Upgrade VFX + smooth weight-growth). The paid path is a real
	-- level change, so it celebrates exactly like an XP level-up.
	-- Non-blocking and pcall-guarded: presentation can never break
	-- the upgrade mutation above.
	local okPresent, errPresent = pcall(LevelUpPresentation.NotifyLevelUp, animal, {
		oldLevel = oldLevel,
		newLevel = newLevel,
		levelsGained = 1,
	})
	if not okPresent then
		Debug.Warn('AN', 'ApplyLevelUpgrade: level-up presentation failed gracefully (upgrade unaffected)', {
			animalId = tostring(uniqueId),
			error = tostring(errPresent),
		})
	end
	-- Overhead follows the SAME authoritative mutation (paid
	-- path celebrates exactly like XP: refresh immediately).
	pcall(AnimalOverhead.Refresh, animal)
	-- Stand upgrade readout follows too (next level + next
	-- cost): the menu confirm path repaints explicitly, but
	-- non-menu upgrade callers (admin, future flows) must not
	-- leave stale cost text behind. Same guarded pipeline as
	-- AddXP above; display never breaks the mutation.
	pcall(function()
		if slotServiceRef and slotServiceRef.FindSlotByOccupant and slotServiceRef.RefreshDisplays then
			local slot = slotServiceRef.FindSlotByOccupant(uniqueId)
			if type(slot) == 'table' and type(slot.id) == 'string' then
				slotServiceRef.RefreshDisplays(slot.id)
			end
		end
	end)
	return { success = true, oldLevel = oldLevel, newLevel = newLevel }
end

-- TEST-ONLY seam (Phase 2.7): register / unregister a minimal
-- runtime record so specs can exercise AddXP without spawning
-- models. Production paths (CreateFromEgg / SpawnFromPersistence)
-- never call these. Records must carry uniqueId + ownerUserId.
function AnimalService._TestRegister(record: any): boolean
	if type(record) ~= 'table' or type(record.uniqueId) ~= 'string' then
		return false
	end
	animals[record.uniqueId] = record
	return true
end

function AnimalService._TestUnregister(uniqueId: string)
	if type(uniqueId) == 'string' then
		animals[uniqueId] = nil
	end
end

-- TEST-ONLY seams for Arena deployment: parked-entry count
-- plus map reset (models are untouched; specs own them).
function AnimalService._TestArenaParkedCount(): number
	local n = 0
	for _ in pairs(arenaParked) do
		n += 1
	end
	return n
end

function AnimalService._TestResetArenaDeployment()
	for key in pairs(arenaParked) do
		arenaParked[key] = nil
	end
end

return table.freeze(AnimalService)
