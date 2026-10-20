--!strict
--!native
--[[
	Egg.SpawnService
	=======================
 	The single authoritative entry point for spawning an Egg.
 	Every caller — the auto-spawn loop, the admin
	`spawnegg` command, the persistence rejoin path —
	goes through `Request`.

	Behavior by origin:
	  * Automatic / Admin / Test: cap = `EggCenterMax`
	    active Available eggs. Bail with `error = 'cap-reached'`
	    if at cap. Pick a non-overlapping XZ on the ring
	    (Placement.PickXZ), build the model, park it at its
	    hover height above the center floor, attach a Buy
	    prompt.
	  * Persistence: NO cap. Build the model directly at the
	    given slot's seated CFrame, attach an Open prompt. The
	    slot is already Reserved by
	    BaseService.RestorePlayerBase.

	A spawned egg has NO movement controller. It holds a
	constant `HoverClearance` above the surface below it (see
	`HoverMath`) and only gains a controller when something
	actually animates it — a flight, or the Roll reveal.

	The egg record is the same shape regardless of origin.
	The fields used by the controllers (model, centerCFrame,
	state, _refs, _mutex) are documented on Request.

	The `Request` shape is the contract. Adding a new spawn
	origin = adding a new caller. The implementation doesn't
	change.
]]

local Constants = require(script.Parent.Constants)
local Catalog = require(script.Parent.Catalog)
local OwnedObjectIdentity = require(game:GetService('ReplicatedStorage').Utility.OwnedObjectIdentity)
local Placement = require(script.Parent.Placement)
local ModelBuilder = require(script.Parent.ModelBuilder)
local HoverMath = require(script.Parent.HoverMath)
local AmbientService = require(script.Parent.AmbientService)
local EggOverhead = require(script.Parent.EggOverhead)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local CarryPrompts = require(script.Parent.Parent.Animal.CarryPrompts)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local PromptConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Validation = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.Parent.EconomyService)

local SpawnService = {}

-- --- Internal state --------------------------------------------

local eggs: { [string]: any } = {} -- uniqueId -> Egg
local centerFolder: Folder? = nil
local activeContainer: Folder? = nil
local centerAreaCFrame: CFrame = CFrame.new(0, 0, 0) -- overwritten on RegisterCenter
local centerFloorY: number = 0 -- overwritten on RegisterCenter

-- External service refs. Set via SetX methods from bootstrap.
local playerServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
local slotServiceRef: any = nil
-- Callback the flight controller installs an Open prompt with.
-- Phase 2: the canonical open-prompt callback lives in
-- CarryPrompts; this façade just forwards. Kept for back-compat
-- with consumers (tests, FlightController handoff) that still
-- call SetHatchPromptCallback / GetHatchPromptCallback on this
-- module.
local onBuyPromptCallback: ((Player, string) -> any)? = nil

-- --- Init / setters --------------------------------------------

function SpawnService.Init() end

function SpawnService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function SpawnService.SetBaseService(svc: any)
	baseServiceRef = svc
end

function SpawnService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function SpawnService.SetSlotService(svc: any)
	slotServiceRef = svc
end

function SpawnService.SetHatchPromptCallback(fn: (Player, string) -> any)
	CarryPrompts.SetHatchPromptCallback(fn)
end

-- Façade setter for the Egg Pickup prompt callback.
-- The Pickup prompt on an Egg model routes to a
-- separate registry from the animal Pickup prompt, so
-- an Egg ID (EG_...) doesn't get fed to
-- AnimalService.Get — which silently no-ops. SpawnService
-- is the natural façade to expose the CarryPrompts setter.
function SpawnService.SetEggGrabPromptCallback(fn: (Player, string) -> any)
	CarryPrompts.SetEggGrabPromptCallback(fn)
end

function SpawnService.SetBuyPromptCallback(fn: (Player, string) -> any)
	onBuyPromptCallback = fn
end

-- Getter for the registered Open prompt callback. The flight
-- controller handoff needs this to install the Open prompt on
-- arrival; it can't require this module at the top level
-- (EggService requires both SpawnService and
-- FlightController, so a top-level SpawnService require in
-- FlightController would deadlock the chain). Callers that
-- hold a reference to SpawnService can use this getter; the
-- flight controller uses the lazy-require pattern documented
-- in its own file.
function SpawnService.GetHatchPromptCallback(): ((Player, string) -> any)?
	return CarryPrompts.GetHatchPromptCallback()
end

-- Install the full prompt set on a lucky egg model
-- (Open F + Pickup E). A single call site for every spawn
-- / re-place / handoff path so the prompt set is always
-- in sync with the egg's current state. CarryPrompts
-- is the single source of truth for prompt install.
--
-- Required egg fields:
--   * model — visible Model with PrimaryPart set
--   * uniqueId — the egg's id (passed to the callback)
--   * slotId — the egg's current slot id (so the
--     Pickup prompt's server callback can find the
--     slot to grab from)
--
-- Idempotent: CarryPrompts destroys any existing prompt
-- on the PrimaryPart before installing a fresh one.
--
-- `slot` is the slot record the egg sits on. The slot
-- is used to register the prompts in the per-base prompt
-- registry so they can be hidden while the player is
-- carrying.
--
-- `ownerUserId` is the player whose base the egg sits
-- on. Passed through to the underlying prompt installers
-- so they can stamp the `ownerUserId` attribute for the
-- client-side `PromptOwnerFilter` LocalScript.
function SpawnService.InstallHatchPrompt(egg: any, slot: any?, ownerUserId: number?)
	-- Install Pickup FIRST (it wipes all existing prompts,
	-- leaving a clean slate), then Open (which only wipes
	-- a pre-existing HatchPrompt, so the Pickup just
	-- installed stays). Order matters — swapping these
	-- causes InstallPickupPrompt to wipe the Open prompt
	-- we just made.
	CarryPrompts.InstallPickupPrompt(egg.model, egg.uniqueId, 'egg', slot, ownerUserId)
	CarryPrompts.InstallHatchPrompt(egg, slot, ownerUserId)
end

-- --- RegisterCenter --------------------------------------------

-- Idempotent. Creates Workspace.EggArea (Floor +
-- ActiveEggs folder) if missing. Called by bootstrap
-- before the spawn loop starts.
function SpawnService.RegisterCenter(workspace: Instance)
	Debug.Log('EG', '> SpawnService.RegisterCenter')
	Validation.t.instanceOf('Workspace')(workspace)
	centerFolder = workspace:FindFirstChild('EggArea')
	if not centerFolder then
		centerFolder = Instance.new('Folder')
		centerFolder.Name = 'EggArea'
		centerFolder.Parent = workspace
	end
	local floor = centerFolder:FindFirstChild('Floor')
	if not floor then
		floor = Instance.new('Part')
		floor.Name = 'Floor'
		floor.Size = Vector3.new(40, 1, 40)
		floor.Anchored = true
		floor.Material = Enum.Material.SmoothPlastic
		floor.BrickColor = BrickColor.new('Medium stone grey')
		floor.CFrame = CFrame.new(0, 0, 0)
		floor.Parent = centerFolder
		centerAreaCFrame = floor.CFrame
		-- Rotation-aware surface height (FloorGeometry): the
		-- production Floor is a 90°-rotated Cylinder, so
		-- `Size.Y / 2` is NOT the world half-height (that
		-- misread parked spawns ~80 studs in the air).
		centerFloorY = FloorGeometry.GetWorldTopY(floor :: BasePart)
	else
		centerAreaCFrame = floor.CFrame
		if floor:IsA('BasePart') then
			centerFloorY = FloorGeometry.GetWorldTopY(floor)
		else
			Debug.Warn('EG', 'RegisterCenter: EggArea.Floor is not a BasePart; floor height unavailable', {
				className = floor.ClassName,
			})
		end
	end
	activeContainer = centerFolder:FindFirstChild('ActiveEggs')
	if not activeContainer then
		activeContainer = Instance.new('Folder')
		activeContainer.Name = 'ActiveEggs'
		activeContainer.Parent = centerFolder
	end
	Debug.Log('EG', '< SpawnService.RegisterCenter done', { floorY = tostring(centerFloorY) })
end

function SpawnService.GetCenterFloorY(): number
	return centerFloorY
end

-- Public accessor for the ActiveEggs container (the canonical
-- parent for ALL egg models: center, slot-placed, and
-- recovered). StealService uses it to re-home a carried egg's
-- model after the carry controller reparents it to a
-- per-player carried folder. Never throws; nil before
-- RegisterCenter.
function SpawnService.GetActiveContainer(): Instance?
	return activeContainer
end

function SpawnService.GetCenterAreaCFrame(): CFrame
	return centerAreaCFrame
end

-- --- Registry queries ------------------------------------------

function SpawnService.GetEgg(uniqueId: string): any?
	if not uniqueId then
		return nil
	end
	return eggs[uniqueId]
end

-- Drop an egg from the registry. Used by the facade's
-- HatchEgg consume path (after the animal is created and
-- the model is destroyed). Idempotent: dropping a missing
-- id is a no-op.
function SpawnService.DropEgg(uniqueId: string)
	if not uniqueId then
		return
	end
	eggs[uniqueId] = nil
end

-- Rebuild an egg's Model at its egg.centerCFrame. Used by
-- EggService.RefundHatch after the early-destroy flow:
-- HatchEgg now destroys egg.model at click time, so when
-- CreateFromEgg fails, RefundHatch must put a fresh model
-- back before re-parking it at its slot's seated CFrame.
--
-- Idempotent: if egg.model is already set and parented,
-- this is a no-op. Returns true if a model was created.
function SpawnService.RebuildEggModel(egg: any): boolean
	if not egg then
		return false
	end
	if egg.model and egg.model.Parent then
		return false
	end
	if not egg.centerCFrame then
		return false
	end
	if not activeContainer then
		return false
	end
	local model = ModelBuilder.Build(egg.rarity, activeContainer)
	model.Name = RarityConfig.RarityDisplayName[egg.rarity] or ('Egg_' .. tostring(egg.uniqueId))
	model:PivotTo(egg.centerCFrame)
	egg.model = model
	-- Rebuilt models need their overhead back (the old GUI
	-- died with the old model); Refresh reuses-or-creates.
	pcall(EggOverhead.Refresh, egg)
	return true
end

function SpawnService.ListAvailable(): { any }
	local out = {}
	for _, b in pairs(eggs) do
		if b.state == Constants.State.Available then
			out[#out + 1] = {
				UniqueId = b.uniqueId,
				Rarity = b.rarity,
				Price = b.price,
			}
		end
	end
	return out
end

function SpawnService.AllEggs(): { any }
	local out = {}
	for _, b in pairs(eggs) do
		out[#out + 1] = b
	end
	return out
end

function SpawnService.CountByState(state: string): number
	local n = 0
	for _, b in pairs(eggs) do
		if b.state == state then
			n += 1
		end
	end
	return n
end

-- Normal-pool Available count: the population the normal
-- spawner maintains at EggCenterMax. Pool 'Extra' eggs
-- (guaranteed/admin/special overflows) never consume normal
-- capacity. Records without a pool stamp predate the flag
-- and count as Normal.
function SpawnService.CountNormalAvailable(): number
	local n = 0
	for _, b in pairs(eggs) do
		if b.state == Constants.State.Available and b.pool ~= 'Extra' then
			n += 1
		end
	end
	return n
end

-- Canonical current-price resolver: the single source for
-- what a center egg of a rarity costs at spawn time. Normal,
-- guaranteed, and admin spawns all resolve through here —
-- never a hardcoded or zero price.
function SpawnService.ResolvePrice(rarity: string): number
	local price: number? = nil
	pcall(function()
		price = EggConfig.Price[rarity]
	end)
	if type(price) == 'number' then
		return price
	end
	return 100
end

-- Lifetime for an ambient egg of this rarity, seconds.
-- Falls back to Common's lifetime for unknown rarities.
-- Never throws.
function SpawnService.LifetimeFor(rarity: string): number
	local seconds: number? = nil
	pcall(function()
		local map = EggConfig.EggLifetimeSeconds
		if type(map) == 'table' then
			seconds = map[rarity]
		end
	end)
	if type(seconds) == 'number' and seconds == seconds and seconds > 0 then
		return seconds
	end
	return 300
end

-- --- Request ---------------------------------------------------

-- Spawn an Egg per the request. Returns
-- { success, egg?, error? }.
--
-- Pre-conditions (validated here):
--   * req.definition is a valid Definition
--   * req.origin is a valid Origin
--   * For Persistence: req.targetSlot is required
--   * For non-Persistence: the NORMAL cap applies, except
--     Admin origin and pool 'Extra' requests, which bypass
--     it (guaranteed/admin eggs overflow the normal
--     population instead of evicting it).
function SpawnService.Request(req: any): any
	local defOk, defErr = Catalog.ValidateDefinition(req.definition)
	if not defOk then
		return { success = false, error = defErr }
	end
	local originOk, originErr = Catalog.ValidateOrigin(req.origin)
	if not originOk then
		return { success = false, error = originErr }
	end

	if req.origin == Catalog.Origin.Persistence then
		if not req.targetSlot then
			return { success = false, error = 'persistence-requires-target-slot' }
		end
		return SpawnService._spawnPersistence(req)
	end

	-- Normal cap: Admin origin and pool 'Extra' bypass it.
	local pool = if type(req.pool) == 'string' then req.pool else 'Normal'
	if req.origin ~= Catalog.Origin.Admin and pool ~= 'Extra' then
		if SpawnService.CountNormalAvailable() >= Constants.EggCenterMax then
			return { success = false, error = 'cap-reached' }
		end
	end

	return SpawnService._spawnCenter(req)
end

-- --- Center spawn (Automatic / Admin / Test) -------------------

function SpawnService._spawnCenter(req: any): any
	local rarity = req.definition.rarity
	local price = req.definition.price
	-- Phase 2.2: mint the Id once, here, through the centralized
	-- generator. The old inline `'LB_' .. os.clock() .. '_' .. math.random(...)`
	-- formula was duplicated across _spawnCenter and
	-- _spawnPersistence and produced a fresh id on every
	-- rejoin, so a lucky egg's identity never survived a
	-- leave. The Id is the persistence key: it is written to
	-- PlayerData and read back on rejoin. Collision-checked
	-- against the live registry so two eggs can never share
	-- an id (spec §8-§9).
	local uniqueId = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Egg, eggs)

	if not activeContainer then
		return { success = false, error = 'center-not-registered' }
	end

	local model = ModelBuilder.Build(rarity, activeContainer)
	model.Name = RarityConfig.RarityDisplayName[rarity] or ('Egg_' .. uniqueId)

	local primary = model.PrimaryPart :: BasePart

	-- Pick a non-overlapping XZ on the ring. If req.xz is
	-- provided, try it first; fall back to PickXZ.
	local xz =
		Placement.PickXZAt(SpawnService.AllEggs(), req.xz, Constants.CenterSpawnRadius, Constants.EggMinSpawnSpacing)

	-- Y puts the egg's bottom face `HoverClearance` studs above
	-- the center floor. The egg is static here: no controller,
	-- no oscillation, until a purchase starts its flight.
	local spawnPos =
		Vector3.new(centerAreaCFrame.X + xz.X, HoverMath.HoverY(centerFloorY, model), centerAreaCFrame.Z + xz.Y)
	local spawnCFrame = centerAreaCFrame + (spawnPos - centerAreaCFrame.Position)
	model:PivotTo(spawnCFrame)

	-- Buy prompt. Named 'BuyPrompt' so the client-side
	-- PromptOwnerFilter can hide it while the local player is
	-- carrying (server-side Purchase validation stays
	-- authoritative regardless of visibility).
	local prompt = Instance.new('ProximityPrompt')
	prompt.Name = 'BuyPrompt'
	prompt.ObjectText = PromptConfig.CenterEggBuy.ObjectText
	-- Canonical money rendering (the same '$' + BigNumber.Format
	-- the HUD uses): 'Buy $10.0M', never raw digits. The price
	-- itself is the authoritative egg price resolved by the
	-- caller (normal/guaranteed/admin all resolve through
	-- SpawnService.ResolvePrice), so admin eggs show their real
	-- price here too. Display-only: a formatter failure falls
	-- back to raw digits rather than breaking the spawn.
	local priceText = tostring(price)
	pcall(function()
		priceText = '$' .. BigNumber.Format(tostring(price))
	end)
	prompt.ActionText = PromptConfig.CenterEggBuy.ActionTextPrefix .. ' ' .. priceText
	prompt.HoldDuration = PromptConfig.CenterEggBuy.HoldDuration
	prompt.MaxActivationDistance = PromptConfig.CenterEggBuy.MaxActivationDistance
	prompt.RequiresLineOfSight = PromptConfig.CenterEggBuy.RequiresLineOfSight
	prompt.Parent = primary
	prompt.Triggered:Connect(function(player: Player)
		if onBuyPromptCallback then
			onBuyPromptCallback(player, uniqueId)
		end
	end)

	-- Build the egg record.
	-- Phase 2.11: admin/test payloads may preassign mutations +
	-- a hidden trait (req.mutations / req.pendingTrait, validated
	-- by the caller). Automatic spawns pass nothing: {} / nil.
	local spawnMutations: { string } = {}
	if type(req.mutations) == 'table' then
		for _, id in ipairs(req.mutations) do
			if type(id) == 'string' then
				spawnMutations[#spawnMutations + 1] = id
			end
		end
	end
	local spawnTrait: string? = nil
	if type(req.pendingTrait) == 'string' and req.pendingTrait ~= '' then
		spawnTrait = req.pendingTrait
	end
	local egg: any = {
		uniqueId = uniqueId,
		rarity = rarity,
		price = price,
		state = Constants.State.Available,
		ownerUserId = nil,
		slotId = nil,
		Mutations = spawnMutations,
		Trait = spawnTrait,
		-- Pool membership for cap accounting ONLY (never
		-- changes lifecycle rules): 'Normal' consumes normal
		-- capacity, 'Extra' overflows it (guaranteed/admin).
		-- Admin origin is always Extra.
		pool = if req.origin == Catalog.Origin.Admin
			then 'Extra'
			elseif type(req.pool) == 'string' then req.pool
			else 'Normal',
		model = model,
		centerCFrame = primary.CFrame,
		_mutex = false,
		spawnedAt = os.clock(),
		-- Universal ambient lifetime: expires this many
		-- seconds after successful creation (per final
		-- rarity). Owned eggs never carry this field into
		-- expiry — purchase flips state under mutex first.
		_expireAt = os.clock() + SpawnService.LifetimeFor(rarity),
		controller = nil,
		controllerType = nil,
		_aborted = false,
		_refs = {
			playerService = playerServiceRef,
			baseService = baseServiceRef,
			animalService = animalServiceRef,
			slotService = slotServiceRef,
		},
	}
	-- The egg rests at a constant clearance above the center
	-- floor, so record that floor for the paths that read it
	-- (the Roll controller's ground CFrame, the flight launch).
	-- No controller: there is nothing to animate.
	egg._localFloor = centerFloorY
	eggs[uniqueId] = egg

	-- Overhead lives under the model, so attach once here at
	-- creation: ambient wander, carry, place, and recover all
	-- move the same model (and its GUI) for free.
	pcall(EggOverhead.Refresh, egg)

	-- Ambient wandering: this is a center (Available, unowned)
	-- egg, so hand its model to the ambient movement service.
	-- The persistence path never calls this (player-owned eggs
	-- are never registered). Nil-safe when the area is down.
	AmbientService.RegisterModel(model)

	-- Canonical successful-spawn event (the ONLY spawn
	-- notification source for rarity guarantees, server
	-- celebrations, and future systems): fires now that the
	-- model is parented, the record is live, and ambient owns
	-- it. Persistence restores and model rebuilds never fire —
	-- a rejoin is not a spawn. Listener-safe: never yields,
	-- never throws out of here.
	pcall(function()
		require(script.Parent.EggSpawned).Fire({
			uniqueId = uniqueId,
			rarity = rarity,
			origin = req.origin,
		})
	end)

	Debug.Log('EG', '_spawnCenter: spawned', { uniqueId = uniqueId, rarity = rarity, xz = tostring(xz) })
	return { success = true, egg = egg }
end

-- --- Persistence spawn ----------------------------------------

function SpawnService._spawnPersistence(req: any): any
	local rarity = req.definition.rarity
	local price = req.definition.price
	local slot = req.targetSlot
	-- Phase 2.2: read the Id from the persisted record instead of
	-- minting a new one. A rejoin that minted a fresh id made the
	-- lucky egg's identity unstable: the same owned object would
	-- be a different id on every leave/rejoin, so nothing could
	-- key off it. The Id is the persistence key (spec §6).
	-- If the record has no Id (pre-2.2 save or a corrupted row),
	-- PlayerService already repaired one at load time; if it's
	-- still missing here, mint one and write it back so the next
	-- rejoin sees it.
	local uniqueId = req.record and req.record.Id
	if not OwnedObjectIdentity.IsValid(uniqueId, OwnedObjectIdentity.Kind.Egg) then
		uniqueId = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Egg, eggs)
		if req.record then
			req.record.Id = uniqueId
		end
	end

	if not activeContainer then
		return { success = false, error = 'center-not-registered' }
	end

	local model = ModelBuilder.Build(rarity, activeContainer)
	model.Name = RarityConfig.RarityDisplayName[rarity] or ('Egg_' .. uniqueId)

	-- Place directly at the slot's seated CFrame.
	local targetCFrame = ModelBuilder.SlotTargetCFrame(slot, model)
	model:PivotTo(targetCFrame)

	-- Open prompt is installed AFTER the egg record is
	-- constructed, via SpawnService.InstallHatchPrompt — the
	-- same single source of truth the post-flight handoff uses.

	local slotTopY = HoverMath.SlotFloorY(slot)
	-- Phase 2.11: restore audited mutations + hidden trait from
	-- the record (PersistenceAudit cleaned both at load).
	-- Defensive copies: the runtime must never alias profile rows.
	local restoreMutations: { string } = {}
	if req.record and type(req.record.Mutations) == 'table' then
		for _, id in ipairs(req.record.Mutations) do
			if type(id) == 'string' then
				restoreMutations[#restoreMutations + 1] = id
			end
		end
	end
	local restoreTrait: string? = nil
	if req.record and type(req.record.Trait) == 'string' and req.record.Trait ~= '' then
		restoreTrait = req.record.Trait
	end
	local egg: any = {
		uniqueId = uniqueId,
		rarity = rarity,
		price = price,
		state = Constants.State.Placed,
		ownerUserId = nil, -- set by the consumer after spawn
		slotId = slot.id,
		Mutations = restoreMutations,
		Trait = restoreTrait,
		model = model,
		centerCFrame = targetCFrame,
		_mutex = false,
		spawnedAt = os.clock(),
		controller = nil,
		controllerType = nil,
		_aborted = false,
		_refs = {
			playerService = playerServiceRef,
			baseService = baseServiceRef,
			animalService = animalServiceRef,
			slotService = slotServiceRef,
		},
	}
	-- The local floor is the slot's top surface: the egg's
	-- clearance is measured from there. No controller — the
	-- egg is parked at `targetCFrame` and stays there.
	egg._localFloor = slotTopY
	eggs[uniqueId] = egg

	-- Install the Open prompt. Single source of truth — same
	-- helper the post-flight handoff in FlightController uses.
	-- Pass the slot so the prompts register against it.
	SpawnService.InstallHatchPrompt(egg, slot, slot.ownerUserId)

	-- Overhead for the rejoin-respawned model (same once-per-
	-- model rule as every other creation path).
	pcall(EggOverhead.Refresh, egg)

	Debug.Log('EG', '_spawnPersistence: placed at slot', { uniqueId = uniqueId, slotId = slot.id })
	return { success = true, egg = egg }
end

-- --- Ambient expiry (universal rotation) -----------------------

-- Internal sweep thread (ONE loop total — never per-egg
-- timers, never per-egg Heartbeats).
local _sweepThread: thread? = nil
local _sweepRunning = false

-- Expire ONE past-deadline ambient egg, fully: unregister
-- ambient movement, destroy the model (overhead + prompts die
-- with it), drop the registry record (frees pool capacity).
-- Available-only, mutex-safe, identity-checked: purchased
-- (Traveling), Placed, Opening, and in-flight eggs can never
-- be reaped, so a stale expiry can never destroy a bought
-- egg. A past-deadline Available record whose model is
-- already gone is dropped without a destroy (frees the slot
-- the record was holding). Returns true when a record was
-- actually reaped. Never throws.
function SpawnService.ExpireEgg(egg: any): boolean
	if type(egg) ~= 'table' then
		return false
	end
	if egg.state ~= Constants.State.Available then
		return false
	end
	if egg._mutex == true then
		return false
	end
	if type(egg._expireAt) ~= 'number' then
		return false
	end
	local uniqueId = egg.uniqueId
	if type(uniqueId) ~= 'string' or SpawnService.GetEgg(uniqueId) ~= egg then
		return false
	end
	if os.clock() < egg._expireAt then
		return false
	end
	local model = egg.model
	if typeof(model) == 'Instance' and (model :: Instance).Parent ~= nil then
		pcall(AmbientService.UnregisterModel, model)
		pcall(function()
			(model :: Model):Destroy()
		end)
		Debug.Log('EG', 'expired ambient egg', {
			uniqueId = tostring(uniqueId),
			rarity = tostring(egg.rarity),
			pool = tostring(egg.pool),
		})
	else
		Debug.Warn('EG', 'expired ambient record had no live model; record dropped', {
			uniqueId = tostring(uniqueId),
			rarity = tostring(egg.rarity),
		})
	end
	SpawnService.DropEgg(uniqueId)
	return true
end

-- Sweep all Available eggs against their _expireAt deadlines.
-- `nowOverride` is the TEST seam (production passes nil =
-- os.clock()). Returns the expired count. Never throws;
-- per-egg failures are skipped, never abort the sweep.
function SpawnService.SweepExpired(nowOverride: number?): number
	local now = if type(nowOverride) == 'number' then nowOverride :: number else os.clock()
	-- Collect first, expire after: never mutate the registry
	-- while traversing it.
	local due: { any } = {}
	pcall(function()
		for _, egg in pairs(eggs) do
			pcall(function()
				if
					type(egg) == 'table'
					and egg.state == Constants.State.Available
					and egg._mutex ~= true
					and type(egg._expireAt) == 'number'
					and now >= egg._expireAt
				then
					due[#due + 1] = egg
				end
			end)
		end
	end)
	local count = 0
	for _, egg in ipairs(due) do
		local ok, expired = pcall(SpawnService.ExpireEgg, egg)
		if ok and expired then
			count += 1
		end
	end
	return count
end

-- Start the single shared expiry sweep loop. Idempotent.
-- Cadence is EggConfig.ExpirySweepSeconds. Wired from
-- EggService.Start/Stop (facade owns thread lifecycle).
function SpawnService.StartExpirySweep()
	if _sweepRunning then
		return
	end
	_sweepRunning = true
	_sweepThread = task.spawn(function()
		while _sweepRunning do
			pcall(SpawnService.SweepExpired, nil)
			local cadence = 5
			pcall(function()
				local configured = EggConfig.ExpirySweepSeconds
				if type(configured) == 'number' and configured == configured and configured >= 1 then
					cadence = configured
				end
			end)
			task.wait(cadence)
		end
	end)
end

function SpawnService.StopExpirySweep()
	_sweepRunning = false
	if _sweepThread then
		pcall(task.cancel, _sweepThread)
		_sweepThread = nil
	end
end

-- --- Cleanup (used by ForceReleaseBase / CleanupPlayer) -------

-- Aborts the controllers for the given userId's eggs, then
-- tears down the in-flight records. Placed (persisted) eggs
-- are NOT destroyed — they belong to the player's data and
-- will reappear on rejoin.
function SpawnService.ForceReleaseBase(baseId: string)
	if not baseServiceRef then
		return
	end
	for _, egg in pairs(eggs) do
		if egg.state == Constants.State.Available then
			continue
		end
		-- Steal (multiplayer): a steal-carried egg belongs to
		-- the thief's carry flow now, not to this base's
		-- teardown. Destroying it here would delete another
		-- player's live carry. StealService.RollbackCarried
		-- owns it (thief death/leave) or completes it.
		if egg.stolenBy ~= nil then
			continue
		end
		if not egg.slotId then
			continue
		end
		-- Parse the slot id to find the owner.
		local slotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
		local parsed = slotType.ParseId(egg.slotId)
		if not parsed then
			continue
		end
		local base = baseServiceRef.GetBaseByOwner(parsed.userId)
		if not (base and base.id == baseId) then
			continue
		end
		-- Persisted eggs (Placed) are NOT destroyed here.
		-- Only in-flight (Traveling/Opening) eggs are torn down.
		if egg.state == Constants.State.Traveling or egg.state == Constants.State.Opening then
			-- Phase 2.5.1: remove the persistence record FIRST —
			-- before the refund and before the runtime teardown.
			-- This egg is being destroyed and refunded, so
			-- leaving its record in profile.Data.LuckyBlocks
			-- would hand the player a free phantom egg on the
			-- next rejoin (the pre-2.5.1 bug: refund + destroy
			-- with the record surviving = money AND egg
			-- duplication). By-Id primary, by-slot fallback,
			-- same policy as every other teardown.
			if playerServiceRef and parsed.userId then
				local removed = false
				if playerServiceRef.RemoveEgg then
					removed = playerServiceRef.RemoveEgg(parsed.userId, egg.uniqueId)
				end
				if not removed and playerServiceRef.RemoveEggAtSlot then
					removed = playerServiceRef.RemoveEggAtSlot(parsed.userId, egg.slotId)
				end
				if not removed then
					Debug.Warn('EG', 'ForceReleaseBase: no persisted record removed for torn-down egg', {
						uniqueId = tostring(egg.uniqueId),
						userId = tostring(parsed.userId),
						slotId = tostring(egg.slotId),
					})
				end
			end
			-- Phase 2.1: refund through EconomyService.AddMoney
			-- with the EggRefund reason. The amount is
			-- sanitized at the boundary (same string the
			-- purchase path produced). If the price is
			-- malformed for any reason, skip the refund rather
			-- than corrupt the balance.
			if playerServiceRef and parsed.userId then
				local refundStr = BigNumber.sanitize(tostring(egg.price))
				if refundStr then
					EconomyService.AddMoney(parsed.userId, refundStr, TransactionReason.EggRefund)
				else
					Debug.Warn('EG', 'ForceReleaseBase: refund skipped (invalid price)', {
						uniqueId = tostring(egg.uniqueId),
						price = tostring(egg.price),
					})
				end
			end
			egg._aborted = true
			if egg.controller then
				if egg.controllerType == Constants.ControllerType.Flight then
					require(script.Parent.FlightController).Stop(egg.controller)
				elseif egg.controllerType == Constants.ControllerType.Roll then
					require(script.Parent.RollController).Stop(egg.controller)
				end
				egg.controller = nil
			end
			if egg.slotId then
				slotServiceRef.ReleaseSlot(egg.slotId)
			end
			if egg.model then
				egg.model:Destroy()
			end
			eggs[egg.uniqueId] = nil
		end
	end
end

-- Used by the consumer (M3) to hand the Flying egg back to
-- Placed state on cleanup (e.g. cleanupPlayer) when the slot
-- has been re-stamped.
function SpawnService.SetEggAborted(uniqueId: string)
	local egg = eggs[uniqueId]
	if not egg then
		return
	end
	egg._aborted = true
	if egg.controller then
		if egg.controllerType == Constants.ControllerType.Flight then
			require(script.Parent.FlightController).Stop(egg.controller)
		elseif egg.controllerType == Constants.ControllerType.Roll then
			require(script.Parent.RollController).Stop(egg.controller)
		end
		egg.controller = nil
	end
end

return table.freeze(SpawnService)
