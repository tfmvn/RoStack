--!strict
--!native
--[[
	EggService
	=================
	Thin facade. The heavy lifting lives in the modules under
	`./Egg/` (SpawnService, FlightController, HoverMath,
	ModelBuilder, Placement, Catalog, Constants). This file
	preserves the public surface so the consumer services
	(BaseService, AnimalService) and the existing TestEZ tests
	keep working without modification.

	Owns (via delegation):
	  * Center-area lucky egg spawning (SpawnService.Request)
	  * Purchase -> travel -> arrive -> open state machine
	    (Purchase here, Base/CollectorArrival.OnArrival on
	    arrival, HatchEgg here, RefundHatch here)
	  * Per-egg mutex for race protection
	  * The visible Workspace Model for each egg (ModelBuilder)
	  * The deterministic, time-based flight from the center to
	    the owner's Collector (FlightController)

	Does NOT own:
	  * Player data / cash (PlayerService)
	  * Slot reservation (BaseService)
	  * Animal creation / walk (AnimalService)
	  * Where an arriving egg actually lands
	    (Base/CollectorArrival)

	Phase 2 changes:
	  * BodyMovers are GONE. The egg is anchored at all times
	    and is moved via model:PivotTo() each Heartbeat by the
	    FlightController.

	Phase 5 changes:
	  * Bobbing is GONE. A egg at rest has NO controller: it
	    is parked at a constant `HoverClearance` above the
	    surface below it via `HoverMath.Settle`. Every hover /
	    floor calculation goes through `HoverMath` so the spawn
	    path and the landing path cannot disagree.
	  * A purchase flies the egg to the owner's `Collector`,
	    not to a slot. The landing slot is resolved ON ARRIVAL
	    by `Base/CollectorArrival.OnArrival` — a 7-second
	    flight can outlive its own slot reservation.
	  * HatchEgg reverses the consume order: CreateFromEgg
	    runs FIRST, the egg is destroyed only on success. On
	    failure, the egg stays in Placed state and the animal
	    slot reservation is released.
	  * CleanupPlayer is now defined (was previously a phantom
	    call from BaseService). It tears down in-flight eggs
	    for the leaving user; Placed (persisted) eggs stay
	    alive so the persistence record remains the source of
	    truth on rejoin.
]]

local Players = game:GetService('Players')

local SpawnService = require(script.Parent.Egg.SpawnService)
local AmbientService = require(script.Parent.Egg.AmbientService)
local FlightController = require(script.Parent.Egg.FlightController)
local GuaranteeService = require(script.Parent.Egg.GuaranteeService)
local RareEggNotifier = require(script.Parent.Egg.RareEggNotifier)
local ServerLuckService = require(script.Parent.ServerLuckService)
local HoverMath = require(script.Parent.Egg.HoverMath)
local StandPresentation = require(script.Parent.StandPresentation)
local CollectorArrival = require(script.Parent.Base.CollectorArrival)
local Constants = require(script.Parent.Egg.Constants)
local Catalog = require(script.Parent.Egg.Catalog)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
local CarryController = require(script.Parent.Animal.CarryController)
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
local SlotActionHandler = require(script.Parent.Action.SlotActionHandler)

local EggConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local PromptConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local WeightedDraw = require(script.Parent.Parent.ReplicatedStorage.Utility.WeightedDraw)
local FloorGeometry = require(script.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local RollController = require(script.Parent.Egg.RollController)
local TraitService = require(script.Parent.TraitService)
local StandResolver = require(script.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local RunService = game:GetService('RunService')
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.EconomyService)
local TutorialSignals = require(script.Parent.Tutorial.TutorialSignals)
-- Funnel analytics (leaf module — never gameplay-critical; every
-- LogStep is pcall-guarded inside, calls below add one more).
local FunnelService = require(script.Parent.FunnelService)
-- Canonical player-facing rejections (reason IDs + catalog +
-- throttle + Error SFX). Leaf module — cycle-free.
local NotificationService = require(script.Parent.Base.NotificationService)

local EggService = {}

-- --- Internal state ---------------------------------------------

-- The auto-spawn loop's thread + flag. Kept here (not in
-- SpawnService) because it's a long-lived background task
-- driven by the facade's lifecycle (Start / Stop).
local spawnThread: thread? = nil
local spawnThreadRunning = false

-- External service refs. Set via SetX from bootstrap.
local playerServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
local slotServiceRef: any = nil
-- Phase 2.1: EconomyService is the single authoritative
-- mutator for player Money. The facade goes through it for
-- purchases and refunds; it never touches profile.Data.Money
-- directly.
local economyServiceRef: any = EconomyService

-- --- API ---------------------------------------------------------

function EggService.Init()
	SpawnService.Init()
	-- Server-wide egg rarity Luck (default 1x; future purchase
	-- flows raise it via ServerLuckService.SetLuck). Publishes
	-- the replicated attribute; the Start loop below reads it.
	ServerLuckService.Init()
	-- Server-wide rare-egg celebration: exactly one subscriber
	-- turns canonical EggSpawned events into a global toast.
	RareEggNotifier.Start()
	-- Wire prompt callbacks so SpawnService can install Buy /
	-- Open prompts that route back through the facade's
	-- Purchase / HatchEgg methods.
	SpawnService.SetBuyPromptCallback(function(player, uniqueId)
		EggService.Purchase(player, uniqueId)
	end)
	SpawnService.SetHatchPromptCallback(function(player, uniqueId)
		-- Native ProximityPrompt.Triggered source. Look up
		-- the slot id from the egg record and dispatch
		-- through the unified SlotActionHandler.
		local egg = SpawnService.GetEgg(uniqueId)
		if not egg or not egg.slotId then
			Debug.Log('EG', 'Open prompt fired but egg is not on a slot', {
				uniqueId = tostring(uniqueId),
			})
			return nil
		end
		return SlotActionHandler.Handle(player, {
			Action = 'Hatch',
			SlotId = egg.slotId,
			OccupantId = uniqueId,
		})
	end)
	-- Egg Pickup prompt: routes by kind= 'egg' in
	-- CarryPrompts. Without a separate registry here, every
	-- Pickup (including EG_... ids) would go to the animal
	-- service's grab callback, which silently no-ops because
	-- the animal registry doesn't have EG_... ids.
	SpawnService.SetEggGrabPromptCallback(function(player: Player, uniqueId: string)
		local egg = SpawnService.GetEgg(uniqueId)
		if not egg or not egg.slotId then
			Debug.Log('EG', 'Pickup prompt fired but egg is not on a slot', {
				uniqueId = tostring(uniqueId),
			})
			return nil
		end
		return SlotActionHandler.Handle(player, {
			Action = 'Pickup',
			SlotId = egg.slotId,
			OccupantId = uniqueId,
		})
	end)
end

function EggService.SetPlayerService(svc: any)
	playerServiceRef = svc
	SpawnService.SetPlayerService(svc)
end

function EggService.SetBaseService(svc: any)
	baseServiceRef = svc
	SpawnService.SetBaseService(svc)
end

function EggService.SetAnimalService(svc: any)
	animalServiceRef = svc
	SpawnService.SetAnimalService(svc)
end

-- Phase 3: SlotService is the single source of truth for
-- slot state transitions. EggService routes every
-- slot primitive through this ref.
function EggService.SetSlotService(svc: any)
	slotServiceRef = svc
	SpawnService.SetSlotService(svc)
end

-- EconomyService override (specs inject a fake ledger;
-- production always uses the real module default above).
function EggService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

-- --- Registration -----------------------------------------------

-- Idempotent. Creates Workspace.EggArea + Floor +
-- ActiveEggs folder if missing. Delegates to SpawnService.
-- Also starts ambient wandering for Available eggs.
function EggService.RegisterCenter(workspace: Instance)
	SpawnService.RegisterCenter(workspace)
	AmbientService.Start(workspace)
end

-- --- Spawn loop ------------------------------------------------

-- Background thread: every CenterSpawnInterval, top up the
-- NORMAL ambient population toward the cap. Bails if already
-- running. Each top-up calls SpawnService.Request with
-- origin = 'Automatic'.
--
-- Rarity selection per spawn slot: a due guarantee overrides
-- the roll (pool 'Extra': bypasses the normal cap, so a
-- 20/20 pool still yields its guaranteed egg as 21st);
-- otherwise the luck-shaped normal roll fills normal capacity
-- (pool 'Normal'). Every successful spawn reports to the
-- guarantee layer (natural and forced appearances both reset).
function EggService.Start()
	Debug.Log('EG', '> Start: launching auto-spawn loop')
	if spawnThreadRunning then
		return
	end
	spawnThreadRunning = true
	SpawnService.StartExpirySweep()
	spawnThread = task.spawn(function()
		-- Spawn one egg (normal or guaranteed) into the pool.
		-- Returns false when the loop should rest until the
		-- next interval (pool full, cap reached, spawn failed).
		local function spawnOnce(rarity: string, pool: string): boolean
			local r = SpawnService.Request({
				definition = { rarity = rarity, price = SpawnService.ResolvePrice(rarity) },
				origin = Catalog.Origin.Automatic,
				pool = pool,
			})
			if not r or not r.success then
				return false
			end
			-- Report what actually spawned: natural and forced
			-- appearances both satisfy the timer.
			-- Success-only: a failed spawn resets nothing.
			GuaranteeService.NoteSpawned(rarity)
			return true
		end
		while spawnThreadRunning do
			while true do
				-- Guarantee hook: a due guarantee takes this
				-- spawn slot as pool 'Extra' — even at 20/20
				-- normal. The guarantee persists until its egg
				-- successfully spawns, so a failure here simply
				-- retries next interval.
				local due = GuaranteeService.PickDue()
				if due ~= nil then
					if not spawnOnce(due, 'Extra') then
						break
					end
				elseif SpawnService.CountNormalAvailable() < Constants.EggCenterMax then
					-- Server Luck shapes ONLY the normal roll
					-- (guaranteed rarities bypass luck entirely).
					local luckedWeights =
						ServerLuckService.ApplyLuck(EggConfig.CenterSpawnRarityWeights, ServerLuckService.GetLuck())
					local rarity = WeightedDraw.Choose(luckedWeights)
					if not rarity then
						break
					end
					if not spawnOnce(rarity, 'Normal') then
						break
					end
				else
					break
				end
				-- Small breather so a bulk top-up doesn't
				-- hammer the pathfinder / engine startup.
				task.wait(0.1)
			end
			task.wait(Constants.CenterSpawnInterval)
		end
	end)
end

function EggService.Stop()
	spawnThreadRunning = false
	SpawnService.StopExpirySweep()
	AmbientService.Stop()
	if spawnThread then
		task.cancel(spawnThread :: thread)
		spawnThread = nil
	end
end

-- --- Public queries --------------------------------------------

-- Re-export from SpawnService. Preserves the wire shape (table
-- with UniqueId / Rarity / Price keys, capitalized for the
-- client snapshot consumers).
function EggService.ListCenterEggs(): { any }
	return SpawnService.ListAvailable()
end

function EggService.GetEgg(uniqueId: string): any?
	Validation.ShortString(uniqueId)
	return SpawnService.GetEgg(uniqueId)
end

-- Drop ONE runtime egg record (Phase 2.8 sale path). Model
-- destroy + slot release + profile removal are the CALLER's job
-- (SellService owns the sale transaction order). Returns true
-- iff a live record was dropped.
function EggService.DropEggRuntime(uniqueId: string): boolean
	if type(uniqueId) ~= 'string' then
		return false
	end
	if not SpawnService.GetEgg(uniqueId) then
		return false
	end
	SpawnService.DropEgg(uniqueId)
	return true
end

-- --- _onEggArrived --------------------------------------------

-- Post-arrival hook invoked by `Base/CollectorArrival.OnArrival`
-- after a successful OccupySlot. The egg has already been
-- teleported from the Collector into `slot` and parked at its
-- seated CFrame, and is in Placed state. We:
--   1. Replace the Buy prompt with an Open prompt.
--   2. Push state to the owner and fire EggArrived.
--
-- No controller handoff: a resting egg has none. The teleport
-- and the `HoverMath.Settle` that parks it are CollectorArrival's
-- job, so by the time this hook runs the egg is already at its
-- final CFrame with `controller = nil`.
--
-- This is the single source of truth for "lucky egg arrived"
-- — the persistence rejoin path installs the prompt directly in
-- SpawnService._spawnPersistence, so a first arrival and a
-- rejoin should produce identical visible state.
-- Before the callback existed, only the rejoin path ran the
-- install steps, so a first arrival looked "frozen" while a
-- rejoin looked "right".
function EggService._onEggArrived(egg: any, slot: any, slotId: string)
	Debug.Log('EG', '_onEggArrived', { uniqueId = egg.uniqueId, slotId = slotId })
	-- Replace the Buy prompt with an Open prompt. Single source
	-- of truth — SpawnService.InstallHatchPrompt — also used by
	-- the persistence path. The callback is the one registered
	-- via SpawnService.SetHatchPromptCallback (in Init).
	SpawnService.InstallHatchPrompt(egg, slot, slot.ownerUserId)

	-- Push state to the owner and fire EggArrived. Skip if
	-- the owner left during the flight; the persistence record
	-- is the source of truth and the next rejoin will re-spawn
	-- the egg via _spawnPersistence.
	local refs = egg._refs
	local owner = refs and refs.playerService and Players:GetPlayerByUserId(egg.ownerUserId :: number)
	if owner and refs.playerService then
		refs.playerService.PushState(owner, refs.baseService.Snapshot(egg.ownerUserId :: number))
		-- Egg-bought presentation lives HERE (authoritative
		-- arrival), not at purchase: the same Buy_Success
		-- toast the purchase used to send (with its Approved
		-- sting) now fires per arrival, for the current owner.
		-- No separate arrival text (the old "arrived! Press F"
		-- message is retired).
		do
			local eggName: string? = nil
			pcall(function()
				eggName = egg.model and egg.model.Name or nil
			end)
			pcall(NotificationService.NotifySuccess, owner, 'Buy_Success', { EggName = eggName, Rarity = egg.rarity })
		end
		Remotes.FireClient(owner, Remotes.Names.EggArrived, {
			BaseId = slot.baseId,
			SlotId = slotId,
			Rarity = egg.rarity,
			Price = egg.price,
		})
	end
end

-- --- Purchase ---------------------------------------------------

-- Returns { success, error?, egg? }.
function EggService.Purchase(player: Player, uniqueId: string): any
	Validation.LivePlayer(player)
	Validation.ShortString(uniqueId)
	-- While the player is carrying anything (lucky or animal),
	-- Egg interactions are blocked. The server is the
	-- authority (proxies like ProximityPrompts are global; a
	-- malicious client can fire the request manually).
	-- CarryRegistry.IsCarrying is the single source of truth
	-- for the carry state.
	if CarryRegistry.IsCarrying(player) then
		pcall(NotificationService.NotifyWarning, player, 'Buy_Carrying')
		return { success = false, error = 'carrying' }
	end
	local egg = SpawnService.GetEgg(uniqueId)
	if not egg then
		pcall(NotificationService.NotifyWarning, player, 'Buy_InvalidEgg')
		return { success = false, error = 'egg-not-found' }
	end
	if egg._mutex then
		return { success = false, error = 'in-progress' }
	end
	egg._mutex = true
	-- Contestable travel: an Available egg is a first purchase;
	-- a Traveling egg may be contested by ANOTHER player (it
	-- stays buyable until arrival commits). Any other state is
	-- unavailable. The owner re-buying their own traveling egg
	-- is rejected after userId resolves below (before debit).
	local isContest = false
	if egg.state == Constants.State.Traveling then
		isContest = true
	elseif egg.state ~= Constants.State.Available then
		egg._mutex = false
		pcall(NotificationService.NotifyWarning, player, 'Buy_InvalidEgg')
		return { success = false, error = 'not-available' }
	end
	if not playerServiceRef then
		egg._mutex = false
		return { success = false, error = 'service-not-ready' }
	end

	local userId = player.UserId
	-- Owner re-buy: contesting your own traveling egg is not a
	-- purchase (rejected before any debit, prompt visibility
	-- notwithstanding — the server stays authoritative).
	if isContest and egg.ownerUserId == userId then
		egg._mutex = false
		pcall(NotificationService.NotifyWarning, player, 'Buy_InvalidEgg')
		return { success = false, error = 'not-available' }
	end
	-- Phase 2.1: `egg.price` is a Lua number from
	-- EggConfig.Price. The economy is string-backed
	-- now, so we sanitize-once-at-the-boundary into a
	-- canonical BigNumber. EconomyService.TrySpendMoney is
	-- the atomic read-compare-write; the old
	-- `CanAfford` + `DebitCash` two-step race is gone.
	local costStr = BigNumber.sanitize(tostring(egg.price))
	if not costStr then
		egg._mutex = false
		pcall(NotificationService.NotifyWarning, player, 'Buy_InvalidPrice')
		return { success = false, error = 'invalid-price' }
	end
	local spendResult = economyServiceRef.TrySpendMoney(userId, costStr, TransactionReason.EggPurchase)
	if not spendResult.Success then
		egg._mutex = false
		if spendResult.Code == 'insufficient' then
			-- Server-calculated shortfall (never client values).
			local shortfall: string? = nil
			pcall(function()
				local data = playerServiceRef and playerServiceRef.GetPlayerData(userId)
				local money = data and BigNumber.sanitize(data.Money) or '0'
				shortfall = BigNumber.Subtract(costStr, money or '0')
			end)
			pcall(NotificationService.NotifyWarning, player, 'Buy_InsufficientCash', { Amount = shortfall })
			return { success = false, error = 'insufficient-money' }
		end
		-- Other codes (no-profile, invalid-amount,
		-- invalid-reason) are unexpected at this point;
		-- log and bail.
		Debug.Warn('EG', 'Purchase: TrySpendMoney failed', {
			code = tostring(spendResult.Code),
			error = tostring(spendResult.Reason),
		})
		return { success = false, error = 'purchase-failed' }
	end

	local base = baseServiceRef and baseServiceRef.GetPlayerBase(userId)
	if not base then
		-- Refund: we debited but the player has no base.
		-- This is an unusual pre-condition failure (the
		-- base assignment happened in bootstrap) but the
		-- only safe thing is to give the money back.
		economyServiceRef.AddMoney(userId, costStr, TransactionReason.EggRefund)
		egg._mutex = false
		pcall(NotificationService.NotifyWarning, player, 'Buy_NoBase')
		return { success = false, error = 'no-base' }
	end

	-- Phase 2: single unified slot pool. No kind argument.
	local slot = slotServiceRef.GetFreeSlot(userId)
	if not slot then
		-- Refund: we debited but there's no slot to land in.
		economyServiceRef.AddMoney(userId, costStr, TransactionReason.EggRefund)
		egg._mutex = false
		pcall(NotificationService.NotifyWarning, player, 'Buy_BaseFull')
		return { success = false, error = 'no-slot' }
	end

	-- Money is already debited (TrySpendMoney was atomic).
	-- First purchase: transition to Traveling, reserve the
	-- slot. The old slot-race rollback `AddCash` is gone — the
	-- debit only happens once and never needs reversing because
	-- `TrySpendMoney` was the single point of mutation.
	-- Contest (isContest): validated below in the transfer
	-- branch — the egg keeps Traveling while ownership, slot
	-- reservation, profile identity, and flight retarget.
	local prevOwnerId: number? = nil
	local prevSlotId: string? = nil
	if isContest then
		if type(egg.ownerUserId) ~= 'number' then
			-- Traveling with no owner is corrupt state: refund
			-- the debit and bail (never adopt it).
			economyServiceRef.AddMoney(userId, costStr, TransactionReason.EggRefund)
			egg._mutex = false
			pcall(NotificationService.NotifyWarning, player, 'Buy_InvalidEgg')
			return { success = false, error = 'not-available' }
		end
		prevOwnerId = egg.ownerUserId
		prevSlotId = egg.slotId
	else
		egg.state = Constants.State.Traveling
		egg.ownerUserId = userId
	end
	-- The egg leaves the ambient pool: stop wandering it now so
	-- the flight controller is the unambiguous driver. Touch /
	-- query flags are restored by the unregister. No-op-safe on
	-- contest (already unregistered).
	AmbientService.UnregisterModel(egg.model)
	if not slotServiceRef.ReserveSlot(slot.id) then
		-- Slot reservation lost a race against another
		-- purchase. Refund the debit and reset the egg.
		-- Contest-safe: the egg itself is untouched (previous
		-- owner keeps traveling ownership), only the new
		-- debit is refunded.
		economyServiceRef.AddMoney(userId, costStr, TransactionReason.EggRefund)
		if not isContest then
			egg.state = Constants.State.Available
			egg.ownerUserId = nil
		end
		egg._mutex = false
		return { success = false, error = 'slot-race' }
	end

	-- Persist: a new lucky egg in the player's data. Phase
	-- 2.5.1: the record's Id is passed EXPLICITLY as the runtime
	-- egg's own uniqueId — every later lifecycle event (tier-2
	-- re-point, open-consume, refund) keys off egg.uniqueId, so
	-- the persisted identity and the runtime identity must be the
	-- same string from birth.
	-- Contest: the SAME identity transfers — the previous
	-- owner's row is removed and their slot released first, so
	-- the uniqueId never exists in two profiles at once. The
	-- previous owner's spent debit is NOT refunded (a lost
	-- contest is a sunk cost, by design).
	if isContest then
		if type(prevOwnerId) == 'number' then
			pcall(function()
				playerServiceRef.RemoveEgg(prevOwnerId, egg.uniqueId)
			end)
		end
		if type(prevSlotId) == 'string' then
			pcall(function()
				slotServiceRef.ReleaseSlot(prevSlotId)
			end)
		end
	end
	egg.slotId = slot.id
	if playerServiceRef.AddEgg then
		-- Phase 2.11: persist the egg's mutations + hidden
		-- pending trait (normally {} / nil; admin-spawned eggs
		-- may carry preassigned values that open inheritance).
		playerServiceRef.AddEgg(userId, slot.id, egg.rarity, egg.uniqueId, {
			Mutations = egg.Mutations,
			Trait = egg.Trait,
		})
	end

	-- Ownership transfer (contest only): the new owner is
	-- stamped AFTER the old identity is torn down above, so no
	-- observer ever sees two owners. First purchase stamped
	-- earlier; state stays Traveling either way.
	if isContest then
		egg.ownerUserId = userId
		-- Stop the previous owner's flight: exactly ONE travel
		-- state may control the egg. The old Heartbeat bails on
		-- its next tick; its arrival can never fire afterward.
		-- (Its _onComplete additionally guards on state/abort.)
		if egg.controller then
			pcall(FlightController.Stop, egg.controller)
		end
		egg.controller = nil
		egg.controllerType = nil
	end

	-- A center-area egg is static (no controller), so there
	-- is normally nothing to stop here. Cleared defensively so
	-- the flight controller is unambiguously the only driver.
	-- (Contest already stopped + cleared above.)
	if not isContest then
		egg.controller = nil
		egg.controllerType = nil
	end

	-- The Buy prompt STAYS for the whole travel (first purchase
	-- and contest): the egg remains buyable until arrival
	-- commits, at which point InstallHatchPrompt's Pickup
	-- install wipes all prompts on the PrimaryPart. The prompt
	-- range (12 studs, live position) gates proximity; the
	-- server revalidates every trigger (state, owner, slot,
	-- debit), so stale prompts can never force a purchase.

	-- Push new cash + slot state to the new owner. On contest
	-- the previous owner also gets a fresh snapshot (their egg
	-- row + slot hold are gone) when still in game.
	playerServiceRef.PushState(player, baseServiceRef.Snapshot(userId))
	if isContest and type(prevOwnerId) == 'number' then
		pcall(function()
			local prevPlayer = Players:GetPlayerByUserId(prevOwnerId :: number)
			if prevPlayer then
				playerServiceRef.PushState(prevPlayer, baseServiceRef.Snapshot(prevOwnerId :: number))
			end
		end)
	end

	Debug.Log('EG', 'Purchase: starting flight', {
		uniqueId = egg.uniqueId,
		slotId = slot.id,
		contest = tostring(isContest),
	})

	-- Kick off the flight. The egg flies to the CURRENT owner's
	-- base COLLECTOR, not to `slot` — the reservation above exists so
	-- the slot is held (and so two buyers can't race the last
	-- one), but the slot the egg actually lands in is decided
	-- on arrival by `CollectorArrival.OnArrival`, which
	-- re-validates against the base's state at that moment.
	-- Generation-guarded swap: each launch bumps egg._flightGen
	-- and only assigns its controller when still current, so a
	-- slow first-purchase launch can never overwrite a newer
	-- contest flight (exactly one driver, no stale paths). The
	-- egg's `_mutex` is held across the synchronous transfer;
	-- in-flight launches are ordered by the generation check.
	local function _launchFlight(targetBase: any)
		egg._flightGen = (egg._flightGen or 0) + 1
		local myGen = egg._flightGen
		task.spawn(function()
			-- The flight's destination: the Collector's X/Z at BASE
			-- GROUND height with roam-style egg contact — NOT the
			-- Collector's top surface. The Collector is a destination
			-- reference, never the egg's ground plane: its Y (top of
			-- a possibly tall/elevated part) must not become travel
			-- height, or the egg visibly climbs it on approach.
			-- `base.collector` is guaranteed non-nil —
			-- BaseService.RegisterBases errors at startup on a base
			-- without a Collector — so there is no fallback branch
			-- here by design.
			local collector = targetBase.collector :: BasePart
			local collectorBottomY = collector.CFrame.Y - collector.Size.Y / 2
			local centerFloorY = SpawnService.GetCenterFloorY()
			-- SAME pivot-to-bottom helper roaming eggs use
			-- (AmbientService registration) — one ground-contact
			-- source of truth for both systems.
			local walkGroundOffset = EggConfig.EggSize.Y / 2
			do
				local primary = egg.model and egg.model.PrimaryPart
				if primary and primary:IsA('BasePart') then
					walkGroundOffset = primary.Size.Y / 2
				end
				local off = egg.model and FloorGeometry.GetPivotGroundOffset(egg.model) or nil
				if type(off) == 'number' and off == off then
					walkGroundOffset = off
				end
			end
			local destination = {
				cframe = CFrame.new(collector.Position.X, collectorBottomY + walkGroundOffset, collector.Position.Z),
				floorStart = centerFloorY,
				floorEnd = collectorBottomY,
			}
			-- Install the post-arrival callback BEFORE the flight
			-- starts. `CollectorArrival` fires it after OccupySlot
			-- succeeds. The callback closes the
			-- first-arrival-vs-rejoin parity gap: before it existed,
			-- the handoff used a dead refs.onHatchPrompt reference,
			-- so the Open prompt never fired until the next rejoin.
			-- Same callback across contests: it reads the CURRENT
			-- owner/slot live at arrival, so retargets need no
			-- reinstall. Generation-gated: a superseded launch's
			-- arrival can never commit (its controller is stopped
			-- above, but the gate makes the ordering explicit and
			-- survives any future caller that skips the stop).
			egg._onArrived = EggService._onEggArrived
			local arrivalGen = myGen
			local controller = FlightController.Start(egg, destination, function(b, _c)
				if egg._flightGen ~= arrivalGen then
					return
				end
				CollectorArrival.OnArrival(b, b._refs)
			end)
			if egg._flightGen ~= myGen then
				-- Superseded by a newer transfer while this
				-- launch was computing: kill it immediately so
				-- two paths never drive the same egg.
				pcall(FlightController.Stop, controller)
				return
			end
			egg.controller = controller
			egg.controllerType = Constants.ControllerType.Flight
		end)
	end
	_launchFlight(base)
	-- Stamp the current purchaser on the traveling Buy prompt:
	-- the purchaser's filter hides Buy, everyone else keeps
	-- seeing it until arrival commits (arrival wipes prompts).
	-- Re-stamped on every contest; server rejection is
	-- independent (owner re-buy fails pre-debit).
	pcall(function()
		local model = egg.model
		local primary = model and model.PrimaryPart
		if primary and primary:IsA('BasePart') then
			for _, child in ipairs(primary:GetChildren()) do
				if child:IsA('ProximityPrompt') and child.Name == 'BuyPrompt' then
					child:SetAttribute('purchaserUserId', userId)
				end
			end
		end
	end)

	egg._mutex = false
	Debug.Log('EG', '< Purchase success')
	-- Lifetime counter: exactly one purchase event per
	-- successful debit commit (refunded/debited-then-failed
	-- paths returned above and never reach here).
	pcall(function()
		if playerServiceRef and playerServiceRef.BumpStat then
			playerServiceRef.BumpStat(userId, 'EggsPurchased')
		end
	end)
	-- Purchase commits silently: egg-bought UI + Approved sting
	-- fire at authoritative arrival (_onEggArrived), never here,
	-- so traveling/contested eggs never celebrate early.
	-- Tutorial guide layer observes the committed purchase (the
	-- bus never throws; purchase itself is unaffected).
	pcall(TutorialSignals.Fire, 'EggPurchased', { UserId = userId, EggId = egg.uniqueId })
	-- Funnel: first purchase (server-committed only; analytics
	-- can never fail the purchase).
	pcall(function()
		FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)
		FunnelService:LogStep(player, 'Progression', 'FirstEggPurchased', nil)
	end)
	return { success = true, egg = egg }
end

-- --- RefundHatch ------------------------------------------------

-- Called by AnimalService.CreateFromEgg when the animal
-- can't be created (template missing / occupy race). The lucky
-- egg is rolled back to Placed state, the animal slot
-- reservation is released, and the egg is re-parked at its
-- slot's seated CFrame.
--
-- Invariants (Phase 2 — the bug fix from M3):
--   * The egg record is intact (CreateFromEgg did NOT
--     destroy the egg; it now bails before consume).
--   * The egg was in 'Opening' state at entry.
--   * The egg's slot is still Reserved for the animal;
--     ReleaseReservedSlotForUser frees it.
--   * After RefundHatch the egg is in 'Placed' state,
--     hovering statically on its slot with no controller.
function EggService.RefundHatch(theEgg: any)
	Debug.Log('EG', '> RefundHatch', { uniqueId = theEgg.uniqueId })
	if not theEgg then
		return
	end
	-- Phase 2: the slot is the same one the egg was on
	-- (HatchEgg called DemoteSlotToReserved on it). Flip it
	-- back to Occupied with the egg as the original
	-- occupant. The kind is 'egg' so future wire-snapshot
	-- consumers see an Egg, not an Animal.
	if theEgg.slotId and slotServiceRef then
		slotServiceRef.OccupySlot(theEgg.slotId, theEgg.uniqueId, SlotType.OccupantKind.Egg)
	end

	-- Stop any controller (should be no-op since Opening
	-- means no controller is running, but be safe).
	if theEgg.controller then
		if theEgg.controllerType == Constants.ControllerType.Flight then
			FlightController.Stop(theEgg.controller)
		elseif theEgg.controllerType == Constants.ControllerType.Roll then
			RollController.Stop(theEgg.controller)
		end
		theEgg.controller = nil
		theEgg.controllerType = nil
	end

	theEgg.state = Constants.State.Placed
	theEgg._mutex = false

	-- Re-park the egg at its slot's seated CFrame. HatchEgg
	-- destroys egg.model at click time, so on the
	-- create-failed path we must REBUILD the model from
	-- egg.centerCFrame (captured at spawn) before there is
	-- anything to place. SpawnService owns the rebuild (it has
	-- the activeContainer + the ModelBuilder plumbing).
	--
	-- `Settle` re-derives the CFrame from the slot rather than
	-- reusing centerCFrame, so an egg whose slot moved between
	-- spawn and refund still lands correctly.
	if theEgg.centerCFrame then
		if not theEgg.model or not theEgg.model.Parent then
			SpawnService.RebuildEggModel(theEgg)
		end
		local slot = theEgg.slotId and slotServiceRef and slotServiceRef._findSlotById(theEgg.slotId)
		if slot then
			HoverMath.Settle(theEgg, slot)
			-- Stand wobble: rebind after refund re-park.
			StandPresentation.Bind(theEgg.model, SlotType.OccupantKind.Egg)
		end
	end
	Debug.Log('EG', '< RefundHatch: egg back to Placed')
end

-- --- Persistence rejoin ----------------------------------------

-- Called by BaseService.RestorePlayerBase for each persisted
-- lucky egg record. Delegates to SpawnService.Request with
-- origin = 'Persistence'. The slot is already Reserved by
-- BaseService.RestorePlayerBase; we just place the model at
-- the slot in Placed state and stamp the owner.
function EggService.SpawnFromPersistence(userId: number, record: any, slot: any): any
	Debug.Log('EG', '> SpawnFromPersistence', { userId = tostring(userId), rarity = record.Rarity })
	Validation.PositiveInteger(userId)
	Validation.AnyTable(record)
	Validation.AnyTable(slot)

	local rarity = record.Rarity
	if not EggConfig.Price[rarity] then
		Debug.Warn('EG', 'SpawnFromPersistence: unknown rarity', { rarity = rarity })
		return { success = false, error = 'unknown-rarity' }
	end
	local price = EggConfig.Price[rarity]

	local r = SpawnService.Request({
		definition = { rarity = rarity, price = price },
		origin = Catalog.Origin.Persistence,
		targetSlot = slot,
		record = record,
	})
	if not r or not r.success then
		Debug.Warn('EG', 'SpawnFromPersistence: SpawnService.Request failed', { error = tostring(r and r.error) })
		return r or { success = false, error = 'spawn-failed' }
	end

	-- Stamp the owner; the persisted record is the source of
	-- truth and BaseService.RestorePlayerBase has reserved
	-- the slot. Flip Reserved -> Occupied now that the model
	-- is on the slot, mirroring the post-flight
	-- `_onEggArrived` path. Without this, the slot stays
	-- Reserved and SlotActionHandler rejects Pickup/Open as
	-- the only action valid for Reserved is Place.
	slotServiceRef.OccupySlot(slot.id, r.egg.uniqueId, SlotType.OccupantKind.Egg)
	r.egg.ownerUserId = userId
	-- Stand wobble: bind the rejoin-spawned model (rest = the
	-- placed pose, so rejoin lands already wobbling correctly).
	StandPresentation.Bind(r.egg.model, SlotType.OccupantKind.Egg)
	return r
end

-- --- Force-release (called by BaseService on owner disconnect) --

function EggService.ForceReleaseBase(baseId: string)
	Validation.ShortString(baseId)
	SpawnService.ForceReleaseBase(baseId)
end

-- --- Cleanup ---------------------------------------------------

-- Called on PlayerRemoving. Tears down in-flight (Traveling /
-- Opening) eggs for the leaving user; Placed (persisted)
-- eggs stay alive because their persistence record is the
-- source of truth on rejoin.
--
-- Phase 2 fix: this function was undefined in the old code
-- but called by BaseService.CleanupPlayer. The phantom call
-- silently errored at runtime. Now it's a real function.
function EggService.CleanupPlayer(userId: number)
	Debug.Log('EG', '> CleanupPlayer (non-destructive)', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	-- Steal (multiplayer): a steal-carry is owned by
	-- StealService — roll back to the original owner before
	-- any base teardown runs. Lazy require: StealService
	-- top-requires the egg modules.
	do
		local ok, stealSvc = pcall(require, script.Parent.Steal.StealService)
		if ok and stealSvc then
			stealSvc.RollbackIfStealing(userId, 'disconnect')
		end
	end
	-- Steal (multiplayer), owner side: any of THIS player's
	-- eggs currently steal-carried by someone else is
	-- recovered home FIRST, while its slot still exists —
	-- then the normal teardown below sees a plain Placed egg
	-- (model destroyed, runtime dropped, profile kept for a
	-- clean rejoin). Never strand a thief carrying against a
	-- wiped base.
	for _, egg in pairs(SpawnService.AllEggs()) do
		if egg.ownerUserId == userId and egg.stolenBy ~= nil then
			local ok, stealSvc = pcall(require, script.Parent.Steal.StealService)
			if ok and stealSvc then
				stealSvc.RollbackStolenTarget('egg', egg.uniqueId, 'owner-leaving')
			end
		end
	end
	if not baseServiceRef then
		return
	end
	local base = baseServiceRef.GetBaseByOwner and baseServiceRef.GetBaseByOwner(userId)
	if base and base.id then
		SpawnService.ForceReleaseBase(base.id)
	end
	-- Multi-player cleanup: sweep every Placed Egg
	-- owned by the leaving user. The persisted record
	-- (playerServiceRef.LuckyBlocks) is left intact;
	-- `RestorePlayerBase` re-spawns from the profile on
	-- rejoin. Without this sweep, a leaving player's
	-- eggs linger in
	-- Workspace.EggArea.ActiveEggs with
	-- stale Pickup/Open prompts — the next player
	-- assigned to that base sees ghost eggs.
	--
	-- The ForceReleaseBase call above already destroyed
	-- in-flight Traveling/Opening eggs; this sweep
	-- handles the Placed ones (including any Carried
	-- egg that RecoverCarriedEgg just put
	-- back on its original slot).
	for _, egg in pairs(SpawnService.AllEggs()) do
		if egg.ownerUserId == userId and egg.state == Constants.State.Placed then
			if egg.model then
				-- Unbind the stand wobble before the destroy.
				StandPresentation.Unbind(egg.model)
				egg.model:Destroy()
			end
			SpawnService.DropEgg(egg.uniqueId)
		end
	end
	Debug.Log('EG', '< CleanupPlayer done')
end

-- --- Open -------------------------------------------------------

-- The consume path. The egg was in 'Placed' state, owned by
-- `player`. Phase 2 unification: the open happens IN-PLACE.
-- The egg is on `egg.slotId`; we demote that slot to
-- Reserved (race guard), run the roulette, then on success
-- `CreateFromEgg` occupies the same slot with the rolled
-- animal. On failure, `RefundHatch` flips the slot back to
-- Occupied with the egg as the occupant.
--
-- Phase 2 sequence:
--   1. DemoteSlotToReserved(egg.slotId) — Occupied → Reserved.
--   2. Roll the animal rarity + winner defId.
--   3. Capture the egg's PrimaryPart CFrame + groundCFrame
--      (roulette + animal spawn position).
--   4. Destroy the egg model (player already saw it disappear
--      at click time in Phase 1.5).
--   5. Run the 3D roulette.
--   6. CreateFromEgg (on the SAME slot, now Reserved) either
--      succeeds → OccupySlot(egg.slotId, brId, 'animal'),
--      or fails → RefundHatch OccupySlot(egg.slotId, eggId, 'egg').
--   7. On success: release the slot (no-op; OccupySlot already
--      committed it), remove from persistence, drop the runtime.
function EggService.HatchEgg(player: Player, uniqueId: string): any
	Validation.LivePlayer(player)
	Validation.ShortString(uniqueId)
	-- Death/reset lockout (see GrabEgg).
	if not Validation.CanPlayerInteract(player) then
		return { success = false, error = 'player-not-live' }
	end
	-- While the player is carrying anything, Egg
	-- interactions are blocked. See Purchase for the rationale.
	if CarryRegistry.IsCarrying(player) then
		return { success = false, error = 'carrying' }
	end
	local egg = SpawnService.GetEgg(uniqueId)
	if not egg then
		return { success = false, error = 'egg-not-found' }
	end
	if egg._mutex then
		return { success = false, error = 'in-progress' }
	end
	egg._mutex = true
	if egg.state ~= Constants.State.Placed then
		egg._mutex = false
		return { success = false, error = 'not-placed' }
	end
	if egg.ownerUserId ~= player.UserId then
		egg._mutex = false
		return { success = false, error = 'not-owner' }
	end

	local userId = player.UserId

	-- Phase 2: validate that the egg is actually on a slot
	-- the player owns, and demote that slot to Reserved.
	-- Demote fails if the slot is not Occupied (e.g. another
	-- flow already started a transition) — in that case we
	-- treat it as a race and bail.
	if not egg.slotId then
		egg._mutex = false
		return { success = false, error = 'no-slot' }
	end
	local eggSlot = slotServiceRef._findSlotById(egg.slotId)
	if not eggSlot or eggSlot.state ~= SlotType.State.Occupied or eggSlot.occupantId ~= egg.uniqueId then
		egg._mutex = false
		return { success = false, error = 'slot-state' }
	end
	if not slotServiceRef.DemoteSlotToReserved(egg.slotId) then
		egg._mutex = false
		return { success = false, error = 'slot-race' }
	end

	local weights = EggConfig.HatchRollWeights[egg.rarity]
	if not weights then
		-- No weights → refund (the slot is currently Reserved
		-- for this player, so we have to flip it back to
		-- Occupied with the egg as occupant).
		EggService.RefundHatch(egg)
		return { success = false, error = 'no-weights' }
	end
	-- Roll the animal rarity. If the rolled rarity has no
	-- defIds in the catalog (designer hasn't placed every
	-- model yet), re-pick up to 8 times before falling back
	-- to the egg's own rarity.
	local rolledRarity = nil
	for _ = 1, 8 do
		local candidate = WeightedDraw.Choose(weights)
		if not candidate then
			break
		end
		if AnimalConfig.Catalog[candidate] and next(AnimalConfig.Catalog[candidate]) then
			rolledRarity = candidate
			break
		end
	end
	if not rolledRarity then
		rolledRarity = egg.rarity
	end

	-- Roll the winner defId up front so the roulette can show
	-- the actual candidate models. The defId is the same one
	-- CreateFromEgg will spawn, so the player sees the same
	-- model in the roulette and in the walking animal.
	local winnerDefId, winnerDef = AnimalConfig.GetRandom(rolledRarity)
	if not winnerDefId or not winnerDef then
		EggService.RefundHatch(egg)
		pcall(NotificationService.NotifyWarning, player, 'Hatch_Failed')
		return { success = false, error = 'no-definition' }
	end
	-- Inheritance is resolved ONCE here (THE single roll for
	-- this hatch) via the authoritative TraitService rule:
	-- hidden egg Trait transfers 100%, else server-side roll.
	-- The resolved trait selects the FINAL visual template, so
	-- the pre-roulette check below validates the exact template
	-- CreateFromEgg will clone — never the pending egg trait.
	-- The resolved pair is passed through to CreateFromEgg
	-- (options.TraitResolved), which reuses it verbatim instead
	-- of rolling a second, possibly different trait.
	local hatchInheritance = TraitService.ResolveInheritance(egg.Trait, egg.Mutations, nil)
	Debug.Log('EG', 'HatchEgg: inheritance resolved', {
		eggId = tostring(egg.uniqueId),
		winnerDefId = tostring(winnerDefId),
		rarity = tostring(rolledRarity),
		trait = tostring(hatchInheritance.Trait),
	})
	-- Validate the winner template exists before starting the
	-- 5-second roulette. Missing winner -> refund immediately
	-- (egg kept, slot restored) with a precise server log.
	-- Also fail fast when the template lacks the REQUIRED
	-- HumanoidRootPart: CreateFromEgg would reject it after the
	-- roulette with the same toast, so refund now with a
	-- precise log instead of playing a doomed 5-second roll.
	local winnerTemplate: Model? = nil
	if animalServiceRef and animalServiceRef.GetTemplate then
		pcall(function()
			winnerTemplate = animalServiceRef.GetTemplate(rolledRarity, winnerDefId, hatchInheritance.Trait)
		end)
	end
	if winnerTemplate == nil then
		-- Exact-path fallback for the log when the canonical
		-- GetTemplatePath helper is unavailable (same
		-- ResolveTraitFolder rule: valid trait or Normal).
		local templatePath: string
		do
			local folder = 'Normal'
			if type(hatchInheritance.Trait) == 'string' and TraitService.IsValidTrait(hatchInheritance.Trait) then
				folder = hatchInheritance.Trait
			end
			templatePath = ('ServerStorage.Animals.%s.%s.%s'):format(
				folder,
				tostring(rolledRarity),
				tostring(winnerDefId)
			)
		end
		if animalServiceRef and animalServiceRef.GetTemplatePath then
			pcall(function()
				templatePath = animalServiceRef.GetTemplatePath(hatchInheritance.Trait, rolledRarity, winnerDefId)
			end)
		end
		Debug.Warn('EG', 'HatchEgg: winner template missing (pre-roulette refund)', {
			rarity = tostring(rolledRarity),
			defId = tostring(winnerDefId),
			trait = tostring(hatchInheritance.Trait),
			path = templatePath,
			found = 'false',
			eggId = tostring(egg.uniqueId),
		})
		EggService.RefundHatch(egg)
		pcall(NotificationService.NotifyWarning, player, 'Hatch_Failed')
		return { success = false, error = 'template-missing' }
	end
	local winnerHrp = (winnerTemplate :: Model):FindFirstChild('HumanoidRootPart')
	if winnerHrp == nil or not (winnerHrp :: Instance):IsA('BasePart') then
		Debug.Warn('EG', 'HatchEgg: winner template has no HumanoidRootPart (pre-roulette refund)', {
			rarity = tostring(rolledRarity),
			defId = tostring(winnerDefId),
			trait = tostring(hatchInheritance.Trait),
			template = (winnerTemplate :: Model):GetFullName(),
			eggId = tostring(egg.uniqueId),
		})
		EggService.RefundHatch(egg)
		pcall(NotificationService.NotifyWarning, player, 'Hatch_Failed')
		return { success = false, error = 'template-missing' }
	end

	-- Move the egg to Opening state so a second HatchEgg
	-- for the same egg is rejected. A Placed egg has no
	-- controller; the fields are cleared so the Roll controller
	-- started below is unambiguously the only driver.
	egg.state = Constants.State.Opening
	egg.controller = nil
	egg.controllerType = nil

	-- Capture the egg's PrimaryPart CFrame BEFORE we
	-- destroy the model. The 3D roulette needs the XZ from
	-- this (the controller derives the slot top Y from
	-- egg._localFloor), and CreateFromEgg needs the
	-- groundCFrame for the animal spawn position (so the
	-- animal walks out of the exact spot the winner was
	-- revealed at, with the same facing).
	local primaryCF = egg.model.PrimaryPart.CFrame
	-- Ground CFrame: faces the stand's button base (yaw-only),
	-- computed via the RollController helper so both call
	-- sites agree. The roll previews and the post-roll
	-- animal all face the button — the same direction a
	-- directly-placed animal lands in.
	local facingTarget = StandResolver.GetStandFacingTarget(eggSlot.stand)
	local facingPos = facingTarget and facingTarget.Position or nil
	local groundCF = RollController.ComputeGroundCFrame(eggSlot.part.CFrame, egg, facingPos)

	-- Block disappears THE INSTANT the player clicks it.
	-- The roulette takes over at the slot top, with each
	-- preview standing on the ground (feet flush, scaled
	-- around feet). The
	-- controller's guards use egg.state, not egg.model,
	-- so the destroyed model is fine.
	if egg.model then
		-- Unbind the stand wobble before the destroy below.
		StandPresentation.Unbind(egg.model)
		egg.model:Destroy()
		egg.model = nil
	end

	-- 3D roulette / reveal animation. The egg stays in
	-- Opening state throughout. The roulette cycles animal
	-- candidate MODELS standing on the slot at the egg's
	-- XZ, slows down,
	-- and lands on the server-authoritative winner. The
	-- existing animal walk system is unchanged.
	-- `eggSlot.part.CFrame` is the slot's CFrame; the roll
	-- previews face the stand's button base (facingPos
	-- above). We pass the slot explicitly so the data flow
	-- is "position comes from the slot, facing from the
	-- button" — never from the model.
	local rollController = RollController.Start(
		egg,
		primaryCF,
		eggSlot.part.CFrame,
		rolledRarity,
		winnerDefId,
		{ rng = nil, facingPos = facingPos }
	)
	egg.controller = rollController
	egg.controllerType = Constants.ControllerType.Roll
	-- Wait for the roulette to finish (or be aborted). Use
	-- Heartbeat:Wait to yield without busy-waiting; codebase
	-- convention is no `task.wait` loops.
	local rollAborted = false
	while RollController.IsRunning(rollController) do
		RunService.Heartbeat:Wait()
		if rollController.aborted then
			rollAborted = true
			break
		end
	end
	if rollAborted then
		RollController.Stop(rollController)
		egg.controller = nil
		egg.controllerType = nil
		EggService.RefundHatch(egg)
		pcall(NotificationService.NotifyWarning, player, 'Hatch_Failed')
		return { success = false, error = 'roll-aborted' }
	end
	-- Tidy the controller reference. CreateFromEgg doesn't
	-- know about the roulette; the rollController is done.
	egg.controller = nil
	egg.controllerType = nil

	-- Consume the roulette's winner model now that the real
	-- animal is in Workspace. CreateFromEgg clones a fresh
	-- animal at the same CFrame the winner was revealed at
	-- (egg.model.PrimaryPart.CFrame + (0,2,0)), so destroying
	-- the winner right after the animal spawns means there's
	-- no overlap (winner is gone) and no gap (animal is at
	-- the same CFrame the player was just looking at).
	RollController._consumeWinnerModel(rollController)

	-- Try to create the animal FIRST. Only on success do we
	-- consume the egg. This is the Phase 2 fix. The winner
	-- defId is passed through so CreateFromEgg uses the
	-- SAME defId the roulette just revealed.
	-- options.spawnCFrameOverride pins the animal's spawn
	-- CFrame to the same spot the winner was revealed at
	-- (since egg.model is gone, CreateFromEgg's
	-- primary-CFrame lookup would otherwise fall through to
	-- the slot-top + 5 fallback, producing a 3-stud jump).
	-- groundCF is the slot top facing the stand's button
	-- base — exactly what the roulette's winner preview
	-- was at.
	--
	-- Phase 2: `egg.slotId` is the slot the egg was on.
	-- CreateFromEgg derives the destination from this
	-- (not from a separately-found freeBrSlot). The slot
	-- is currently Reserved; CreateFromEgg will call
	-- OccupySlot(egg.slotId, brId, 'animal') to flip
	-- it to Occupied.
	-- NOTE: exactly four args. A stale fifth-arg form once
	-- passed egg.slotId here, which shadowed winnerDefId into
	-- the predefId slot and dropped the options table (roulette
	-- winner + spawn pin silently ignored). Trait/mutation
	-- inheritance was resolved ONCE above (hatchInheritance) and
	-- is passed through TraitResolved so CreateFromEgg reuses
	-- the validated trait instead of rolling a second one.
	local result = animalServiceRef.CreateFromEgg(egg, rolledRarity, winnerDefId, {
		spawnCFrameOverride = groundCF,
		TraitResolved = true,
		ResolvedTrait = hatchInheritance.Trait,
		ResolvedMutations = hatchInheritance.Mutations,
	})
	if not result or not result.success then
		-- CreateFromEgg failed. RefundHatch:
		--   * flips the slot back to Occupied with the egg
		--     as occupant (Reserved → Occupied via OccupySlot)
		--   * re-parks the egg at the slot's seated CFrame
		-- The inner error is propagated (never masked as a
		-- generic failure) so server logs and the handler can
		-- distinguish template vs slot vs persistence causes.
		-- The player still gets the single safe Hatch_Failed
		-- toast; the technical reason stays server-side.
		local innerError = (type(result) == 'table' and type(result.error) == 'string') and result.error
			or 'create-failed'
		Debug.Warn('EG', 'HatchEgg: animal creation failed (refund)', {
			eggId = tostring(egg.uniqueId),
			rarity = tostring(rolledRarity),
			defId = tostring(winnerDefId),
			trait = tostring(hatchInheritance.Trait),
			error = innerError,
		})
		EggService.RefundHatch(egg)
		pcall(NotificationService.NotifyWarning, player, 'Hatch_Failed')
		return { success = false, error = innerError }
	end
	Debug.Log('EG', 'HatchEgg: success', {
		eggId = tostring(egg.uniqueId),
		animalId = tostring(result.animalId),
		winnerDefId = tostring(winnerDefId),
		rarity = tostring(rolledRarity),
		trait = tostring(hatchInheritance.Trait),
	})

	-- THE canonical final reveal event, fired exactly once for
	-- the committed result: Reward audio + rarity explosion
	-- VFX + the just-spawned real animal, all in one
	-- synchronous block (no drift between them, ever). Reads
	-- the AUTHORITATIVE post-commit record (same Id/rarity/
	-- ownership the persistence layer just wrote). Never
	-- throws, never blocks the hatch; presentation only.
	local okReveal, revealErr = pcall(function()
		local animal = animalServiceRef.Get(result.animalId)
		if animal then
			RollController.RevealFinalAnimal(rollController, animal)
		end
	end)
	if not okReveal then
		Debug.Warn('EG', 'HatchEgg: reveal event failed gracefully (hatch unaffected)', {
			error = tostring(revealErr),
		})
	end

	-- Success: consume the egg. (The egg model was
	-- already destroyed at click time -- this branch is
	-- here only to clear the runtime record.) The slot is
	-- now Occupied by the new animal, so we do NOT
	-- release it. Phase 2.5.1: the PERSISTENCE side of the
	-- consume (remove the LB record + add the BR record)
	-- already happened atomically inside CreateFromEgg via
	-- PlayerService.ConsumeEggIntoAnimal — no
	-- separate RemoveEgg here anymore (a second
	-- remove was dead at best and, when it was mis-keyed,
	-- the direct cause of phantom records).
	egg.state = Constants.State.Consumed
	-- Drop the runtime record. SpawnService.GetEgg will
	-- return nil for this id from now on.
	SpawnService.DropEgg(egg.uniqueId)
	-- Lifetime counter: exactly one hatch event per committed
	-- hatch (animal persisted + egg consumed above; the
	-- refund paths returned earlier).
	pcall(function()
		if playerServiceRef and playerServiceRef.BumpStat then
			playerServiceRef.BumpStat(userId, 'EggsHatched')
		end
	end)

	playerServiceRef.PushState(player, baseServiceRef.Snapshot(userId))

	-- Success ONLY after the authoritative hatch commit above
	-- (animal created + persisted, egg consumed). Visual-only:
	-- the roulette already played the Reward sting at reveal.
	do
		local animalName: string? = nil
		pcall(function()
			local animal = animalServiceRef and animalServiceRef.Get(result.animalId)
			animalName = animal and animal.displayName or nil
		end)
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Hatch_Success',
			{ AnimalName = animalName, Rarity = rolledRarity }
		)
	end

	egg._mutex = false
	-- Tutorial guide layer observes the committed hatch (egg id
	-- -> animal id identity chain; bus never throws).
	pcall(TutorialSignals.Fire, 'EggHatched', { UserId = userId, EggId = uniqueId, AnimalId = result.animalId })
	-- Funnel: first hatch (animal created + persisted above).
	pcall(function()
		FunnelService:LogStep(player, 'Onboarding', 'FirstEggHatched', { rarity = rolledRarity })
	end)
	return { success = true, animalId = result.animalId, rarity = rolledRarity }
end

-- --- Carry: Grab / Place / Recover / IsCarrying ---------------

-- The carry surface for Eggs mirrors AnimalService.
-- Both kinds share CarryRegistry as the authoritative state
-- (mutual exclusion: a player can only carry one object at a
-- time, regardless of kind).

-- Returns true iff the player is currently carrying an Egg.
-- Use CarryRegistry.IsCarrying for a kind-agnostic
-- check; this is a thin convenience for callers that only
-- care about eggs.
function EggService.IsCarrying(playerOrUserId: any): boolean
	if
		CarryRegistry.IsCarrying(playerOrUserId)
		and CarryRegistry.GetKind(playerOrUserId) == SlotType.OccupantKind.Egg
	then
		return true
	end
	return false
end

-- Grab an Egg from its slot. Phase 2: the slot is
-- demoted to Reserved (the carry-reservation invariant),
-- the egg is welded to the player via CarryController, and
-- the CarryRegistry is updated. Rejected if the player is
-- already carrying anything.
function EggService.GrabEgg(player: Player, uniqueId: string): any
	Validation.LivePlayer(player)
	Validation.ShortString(uniqueId)
	-- Death/reset lockout: dead/dying/respawning players have
	-- ZERO grab authority (LivePlayer alone survives death).
	if not Validation.CanPlayerInteract(player) then
		return { success = false, error = 'player-not-live' }
	end
	if CarryRegistry.IsCarrying(player) then
		return { success = false, error = 'already-carrying' }
	end
	local egg = SpawnService.GetEgg(uniqueId)
	if not egg then
		return { success = false, error = 'egg-not-found' }
	end
	if egg.state ~= Constants.State.Placed then
		return { success = false, error = 'not-placed' }
	end
	if egg.ownerUserId ~= player.UserId then
		return { success = false, error = 'not-owner' }
	end
	if not egg.slotId then
		return { success = false, error = 'no-slot' }
	end
	-- Distance check (same as animal carry).
	local base = baseServiceRef and baseServiceRef.GetPlayerBase(player.UserId)
	if not base then
		return { success = false, error = 'no-base' }
	end
	local eggSlot = slotServiceRef._findSlotById(egg.slotId)
	if not eggSlot or not eggSlot.part then
		return { success = false, error = 'no-slot' }
	end
	local slotPos = eggSlot.part.Position
	local playerPos = player.Character and player.Character.PrimaryPart and player.Character.PrimaryPart.Position
	if playerPos and (slotPos - playerPos).Magnitude > PromptConfig.CarryMaxDistance then
		return { success = false, error = 'too-far' }
	end
	-- Demote the slot (Occupied → Reserved). The egg is
	-- still in Placed state; CarryController will animate the
	-- model to follow the player.
	if not slotServiceRef.DemoteSlotToReserved(egg.slotId) then
		return { success = false, error = 'slot-race' }
	end
	egg.state = Constants.State.Opening -- treat as in-flight; HatchEgg rejects until Placed
	-- A Placed egg has no controller, but clear the fields so
	-- nothing can fight CarryController for the model's CFrame.
	egg.controller = nil
	egg.controllerType = nil
	-- Weld the egg to the player's head via the kind-agnostic
	-- CarryController. The lucky egg has no Humanoid, so
	-- CarryController's nil-safe PlatformStand branch applies.
	egg.originalSlotId = egg.slotId
	local character = player.Character
	if not character then
		-- Rollback the demote: re-occupy the slot so the
		-- egg stays placed.
		slotServiceRef.OccupySlot(egg.slotId, egg.uniqueId, SlotType.OccupantKind.Egg)
		return { success = false, error = 'no-character' }
	end
	-- Stop any pre-existing carry (idempotent re-Grab).
	if egg.controller and CarryController.IsRunning(egg.controller) then
		CarryController.Stop(egg.controller)
	end
	egg.controllerType = 'Carry'
	egg.controller = CarryController.Start(egg, player.UserId, character, player)
	-- Stand wobble off while carried (the carry controller owns
	-- the transform now). Rebound on place/recover.
	StandPresentation.Unbind(egg.model)
	-- Register the carry.
	local ok = CarryRegistry.Set(player.UserId, {
		kind = SlotType.OccupantKind.Egg,
		record = egg,
		originalSlotId = egg.slotId,
		startedAt = os.clock(),
	})
	if not ok then
		-- Rollback: drop the carry attach + re-promote slot.
		CarryController.Stop(egg.controller)
		egg.controller = nil
		egg.controllerType = nil
		egg.state = Constants.State.Placed
		slotServiceRef.OccupySlot(egg.slotId, egg.uniqueId, SlotType.OccupantKind.Egg)
		return { success = false, error = 'carry-failed' }
	end
	-- The carried model has no prompt — the Place prompt
	-- lives on the player's base slot parts instead. Strip
	-- any leftover Pickup/Open prompts from the model (it
	-- shouldn't have any — but be defensive against stale
	-- state from a re-grab race) and then install Place
	-- prompts on every eligible slot of the player's base
	-- (all Empty slots + the source slot they just demoted,
	-- which is now Reserved for them). Hide every other
	-- Pickup/Open prompt on the player's base so the
	-- carrying player isn't shown affordances that will
	-- just be rejected.
	if egg.model then
		CarryPrompts.RemovePromptsFromModel(egg.model)
	end
	local playerBase = baseServiceRef and baseServiceRef.GetBaseByOwner and baseServiceRef.GetBaseByOwner(player.UserId)
	if playerBase then
		-- Eggs can never land on arena stands: hide the
		-- arena grid from egg carriers (server rejects
		-- arena egg placement regardless).
		CarryPrompts.InstallPlacePromptsForBase(playerBase, player.UserId, SlotType.OccupantKind.Egg)
		CarryPrompts.DisablePickupHatchPromptsForBase(playerBase)
	end
	Remotes.FireClient(player, Remotes.Names.EggCarried, {
		BaseId = eggSlot.baseId,
		SlotId = egg.slotId,
		Rarity = egg.rarity,
	})
	if playerServiceRef and playerServiceRef.PushState then
		playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
	end
	-- Success ONLY after the grab commit above (slot demoted,
	-- carry attached + registered). Visual-only by policy.
	do
		local eggName: string? = nil
		pcall(function()
			eggName = egg.model and egg.model.Name or nil
		end)
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Pickup_Success',
			{ Name = eggName or 'Egg', Rarity = egg.rarity }
		)
	end
	Debug.Log('EG', 'GrabEgg: ok', { uniqueId = uniqueId, slotId = egg.slotId })
	return { success = true }
end

-- Place an Egg on a destination slot. Phase 2:
-- source slot (Reserved) flips to Empty (release) UNLESS
-- the destination is the same slot (then it's Reserved →
-- Occupied directly via OccupySlot). The destination must
-- be either Empty (reserve then occupy) or the same
-- Reserved slot (just occupy).
function EggService.PlaceEgg(player: Player, uniqueId: string, destSlotId: string): any
	Validation.LivePlayer(player)
	Validation.ShortString(uniqueId)
	Validation.SlotId(destSlotId)
	-- Death/reset lockout (see GrabEgg).
	if not Validation.CanPlayerInteract(player) then
		return { success = false, error = 'player-not-live' }
	end
	if not CarryRegistry.IsCarrying(player) then
		return { success = false, error = 'not-carrying' }
	end
	local item = CarryRegistry.Get(player)
	if not item or item.kind ~= SlotType.OccupantKind.Egg or item.record.uniqueId ~= uniqueId then
		return { success = false, error = 'carry-mismatch' }
	end
	-- Steal (multiplayer): a steal-carried egg must be
	-- delivered to the thief's collector (StealService
	-- completion) — normal Place is rejected so a stolen
	-- object can never be laundered into a base via place.
	if item.steal ~= nil then
		return { success = false, error = 'steal-in-progress' }
	end
	-- Arena stands hold ANIMALS only. An egg routed at an
	-- arena slot (forged request — carriers never see the
	-- prompt) recovers to its source instead of occupying.
	local destArena: any = nil
	pcall(function()
		destArena = slotServiceRef._findSlotById(destSlotId)
	end)
	if type(destArena) == 'table' and destArena.arena == true then
		warn(('[EggService] PlaceEgg rejected: arena slot cannot hold eggs dest=%s'):format(tostring(destSlotId)))
		return EggService.RecoverCarriedEgg(player, 'arena-no-eggs')
	end
	local egg = item.record
	local srcSlotId = egg.slotId
	if srcSlotId == destSlotId then
		-- Return to original slot (Reserved → Occupied).
		-- OccupySlot accepts the kind arg and stamps the slot.
		if egg.controller and CarryController.IsRunning(egg.controller) then
			CarryController.Stop(egg.controller)
		end
		egg.controller = nil
		egg.controllerType = nil
		CarryRegistry.Clear(player.UserId)
		if not slotServiceRef.OccupySlot(srcSlotId, egg.uniqueId, SlotType.OccupantKind.Egg) then
			-- Race: someone else changed the slot. Try to
			-- find a new empty slot; if none, fall back to
			-- recovering the egg to the original (the
			-- recover path handles both cases).
			return EggService.RecoverCarriedEgg(player, 'place-race')
		end
		egg.state = Constants.State.Placed
		egg.slotId = srcSlotId
		-- Re-anchor the model at the source slot. After
		-- CarryController.Stop the model is still at the
		-- player's head (the carry controller's last
		-- PivotTo was head-relative). Without an explicit
		-- snap here, the placed egg stays welded in the
		-- player's view, in the player's head-rotation —
		-- which is the orientation bug the user reported.
		-- `HoverMath.Settle` is the same call the place-to-
		-- different path uses: it PivotTos to the slot's hover
		-- CFrame (preserving the slot's rotation), refreshes
		-- centerCFrame / _localFloor, and leaves no controller.
		local placedSlot = slotServiceRef._findSlotById(srcSlotId)
		if placedSlot then
			HoverMath.Settle(egg, placedSlot)
			-- Stand wobble: rebind after same-slot return.
			StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)
		end
		local base = baseServiceRef and baseServiceRef.GetPlayerBase(player.UserId)
		-- Refresh prompts: re-install Pickup + Open on the
		-- placed model (its PrimaryPart). Pass the slot so
		-- the prompts register against it (used to hide
		-- other Pickup/Open prompts while the player
		-- carries).
		SpawnService.InstallHatchPrompt(egg, placedSlot, placedSlot.ownerUserId)
		-- Remove every Place prompt from the player's base
		-- slot parts (the carry is over, the slot grid is
		-- no longer the affordance).
		if base then
			CarryPrompts.RemovePlacePromptsForBase(base)
			CarryPrompts.EnablePickupHatchPromptsForBase(base)
		end
		Remotes.FireClient(player, Remotes.Names.EggPlaced, {
			BaseId = (base and base.id) or '',
			SlotId = srcSlotId,
		})
		if playerServiceRef and playerServiceRef.PushState then
			playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
		end
		-- Success ONLY after the same-slot commit above.
		-- Visual-only by policy (high-frequency movement).
		do
			local eggName: string? = nil
			pcall(function()
				eggName = egg.model and egg.model.Name or nil
			end)
			pcall(
				NotificationService.NotifySuccess,
				player,
				'Place_Success',
				{ Name = eggName or 'Egg', Rarity = egg.rarity }
			)
		end
		return { success = true }
	end
	-- Different slot. Release the source (Reserved → Empty),
	-- then reserve + occupy the destination.
	if egg.controller and CarryController.IsRunning(egg.controller) then
		CarryController.Stop(egg.controller)
	end
	egg.controller = nil
	egg.controllerType = nil
	CarryRegistry.Clear(player.UserId)
	if srcSlotId then
		slotServiceRef.ReleaseSlot(srcSlotId)
	end
	egg.slotId = nil
	if not slotServiceRef.ReserveSlot(destSlotId) then
		-- Destination not reservable. Recover back to the
		-- original slot.
		return EggService.RecoverCarriedEgg(player, 'dest-unavailable')
	end
	if not slotServiceRef.OccupySlot(destSlotId, egg.uniqueId, SlotType.OccupantKind.Egg) then
		local destIndex = tonumber(string.match(destSlotId, ':(%d+)$') or '0') :: number
		slotServiceRef.ReleaseReservedSlotForUser(player.UserId, destIndex)
		return EggService.RecoverCarriedEgg(player, 'occupy-failed')
	end
	egg.slotId = destSlotId
	egg.state = Constants.State.Placed
	-- Re-park the model on the destination slot. `Settle`
	-- measures the clearance from the slot part's TOP surface,
	-- so the egg can't sink into a thicker slot part, and it
	-- keeps the slot's Collector-facing rotation.
	local destSlot = slotServiceRef._findSlotById(destSlotId)
	if destSlot then
		HoverMath.Settle(egg, destSlot)
		-- Stand wobble: rebind at the new stand (overwrites the
		-- old rest cleanly — new position, same guarantee).
		StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)
	end
	-- Re-attach the Open prompt on the new PrimaryPart. Pass
	-- the destination slot so the prompts register against
	-- it (used to hide other Pickup/Open prompts while the
	-- player carries).
	SpawnService.InstallHatchPrompt(egg, destSlot, destSlot.ownerUserId)
	-- Persistence: update the slot id on the player's data.
	-- Phase 2.5.1: re-point the SAME record in place. The old
	-- fallback branch (RemoveEgg(srcSlotId) — a slot id
	-- passed into the Id-keyed remove, i.e. a silent no-op — then
	-- AddEgg(destSlotId) minting a second record) was
	-- dead code that, if it had ever run, would have left the
	-- old record behind as a phantom. SetEggSlot either
	-- moves the record or returns false, and a false is logged
	-- loudly instead of papered over.
	if playerServiceRef then
		if playerServiceRef.SetEggSlot then
			if not playerServiceRef.SetEggSlot(player.UserId, egg.uniqueId, destSlotId) then
				Debug.Warn('EG', 'PlaceEgg: no persisted record to re-point', {
					userId = tostring(player.UserId),
					uniqueId = tostring(egg.uniqueId),
					slotId = destSlotId,
				})
			end
		else
			Debug.Warn('EG', 'PlaceEgg: playerService lacks SetEggSlot — persistence NOT updated', {
				userId = tostring(player.UserId),
				uniqueId = tostring(egg.uniqueId),
			})
		end
	end
	local base = baseServiceRef and baseServiceRef.GetPlayerBase(player.UserId)
	-- Remove every Place prompt from the player's base
	-- slot parts (the carry is over, the slot grid is
	-- no longer the affordance).
	if base then
		CarryPrompts.RemovePlacePromptsForBase(base)
		CarryPrompts.EnablePickupHatchPromptsForBase(base)
	end
	Remotes.FireClient(player, Remotes.Names.EggPlaced, {
		BaseId = (base and base.id) or '',
		SlotId = destSlotId,
	})
	if playerServiceRef and playerServiceRef.PushState then
		playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
	end
	-- Success ONLY after the cross-slot commit above.
	-- Visual-only by policy (high-frequency movement).
	do
		local eggName: string? = nil
		pcall(function()
			eggName = egg.model and egg.model.Name or nil
		end)
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Place_Success',
			{ Name = eggName or 'Egg', Rarity = egg.rarity }
		)
	end
	return { success = true }
end

-- Recover a carried Egg. Called from the death hook
-- (player died mid-carry) and the disconnect path. The
-- original slot is Reserved thanks to the Demote transition
-- on grab; tier-1 is OccupySlot(originalSlotId) (Reserved →
-- Occupied). Tier-2 (original slot no longer Reserved) falls
-- back to the first Empty slot in the base. If there's no
-- place to put the egg, the player is notified.
function EggService.RecoverCarriedEgg(player: Player, reason: string?): any
	Validation.LivePlayer(player)
	if not CarryRegistry.IsCarrying(player) then
		return { success = false, error = 'not-carrying' }
	end
	local item = CarryRegistry.Get(player)
	if not item or item.kind ~= SlotType.OccupantKind.Egg then
		return { success = false, error = 'carry-mismatch' }
	end
	local egg = item.record
	Debug.Log('EG', '> RecoverCarriedEgg', { uniqueId = egg.uniqueId, reason = tostring(reason) })
	if egg.controller and CarryController.IsRunning(egg.controller) then
		CarryController.Stop(egg.controller)
	end
	egg.controller = nil
	egg.controllerType = nil
	CarryRegistry.Clear(player.UserId)
	local origSlotId = item.originalSlotId
	if origSlotId and slotServiceRef.OccupySlot(origSlotId, egg.uniqueId, SlotType.OccupantKind.Egg) then
		egg.slotId = origSlotId
		egg.state = Constants.State.Placed
		local slot = slotServiceRef._findSlotById(origSlotId)
		-- Same `Settle` call as every other place path, so the
		-- egg sits at its clearance above the slot's TOP
		-- surface in the slot's rotation.
		if slot then
			HoverMath.Settle(egg, slot)
			-- Stand wobble: rebind after recovery settle.
			StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)
		end
		SpawnService.InstallHatchPrompt(egg, slot, slot.ownerUserId)
	else
		-- Tier 2: find a free slot in any of the player's bases
		-- (there's only one, but the loop is defensive).
		local base = baseServiceRef.GetPlayerBase(player.UserId)
		if base then
			for _, slot in pairs(base.slots) do
				if slot.state == SlotType.State.Empty then
					if
						slotServiceRef.ReserveSlot(slot.id)
						and slotServiceRef.OccupySlot(slot.id, egg.uniqueId, SlotType.OccupantKind.Egg)
					then
						egg.slotId = slot.id
						egg.state = Constants.State.Placed
						-- Same `Settle` call as every other
						-- place path.
						HoverMath.Settle(egg, slot)
						-- Stand wobble: rebind after fallback settle.
						StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)
						SpawnService.InstallHatchPrompt(egg, slot, slot.ownerUserId)
						-- Phase 2.5.1: the persistence record still
						-- points at the ORIGINAL slot — re-point it
						-- to the slot the egg actually landed on,
						-- or the rejoin would respawn the egg
						-- somewhere it no longer is. Same policy as
						-- PlaceEgg: re-point in place, loud
						-- warn when there is no record to move.
						if playerServiceRef then
							if playerServiceRef.SetEggSlot then
								if not playerServiceRef.SetEggSlot(player.UserId, egg.uniqueId, slot.id) then
									Debug.Warn('EG', 'RecoverCarriedEgg: no persisted record to re-point', {
										userId = tostring(player.UserId),
										uniqueId = tostring(egg.uniqueId),
										slotId = slot.id,
									})
								end
							else
								Debug.Warn(
									'EG',
									'RecoverCarriedEgg: playerService lacks SetEggSlot — persistence NOT updated',
									{
										userId = tostring(player.UserId),
										uniqueId = tostring(egg.uniqueId),
									}
								)
							end
						end
						break
					end
				end
			end
		end
	end
	-- Refresh prompts: re-install Pickup + Open on the
	-- placed model (its PrimaryPart). Pass the slot so the
	-- prompts register against it. finalSlot can be nil when
	-- every tier failed (full base): InstallHatchPrompt must
	-- be skipped, but the base prompt restore + state push
	-- below MUST still run — otherwise the client's carry
	-- filter hides every prompt forever with zero errors.
	local finalSlot = egg.slotId and slotServiceRef._findSlotById(egg.slotId)
	if finalSlot then
		SpawnService.InstallHatchPrompt(egg, finalSlot, finalSlot.ownerUserId)
	else
		Debug.Warn('EG', 'RecoverCarriedEgg: no slot for prompt reinstall', {
			userId = tostring(player.UserId),
			uniqueId = tostring(egg.uniqueId),
		})
	end
	-- Remove every Place prompt from the player's base
	-- slot parts (the carry is over, the slot grid is no
	-- longer the affordance). Re-enable Pickup/Open
	-- prompts now that the carry is over.
	if baseServiceRef and baseServiceRef.GetPlayerBase then
		local playerBase = baseServiceRef.GetPlayerBase(player.UserId)
		if playerBase then
			CarryPrompts.RemovePlacePromptsForBase(playerBase)
			CarryPrompts.EnablePickupHatchPromptsForBase(playerBase)
		end
	end
	if playerServiceRef and playerServiceRef.PushState then
		playerServiceRef.PushState(player, baseServiceRef.Snapshot(player.UserId))
	end
	return { success = true }
end

-- Post-base-swap reconciliation (called by RebirthService
-- after a successful base rebuild; mirrors the join-time
-- RestorePlayerBase repair so post-rebirth state is
-- functionally identical to a fresh join).
--
-- Rebirth destroys stands but intentionally keeps egg
-- profile rows (LuckyBlocks). Without repair, those rows
-- keep slotIds that now alias FRESH Empty slots (slot ids
-- are deterministic per user+index), and runtime models
-- destroyed with the old stands never come back:
-- interactions then fail with clean-looking rejections
-- ('slot-state', dead slots) while the eggs look present.
-- Repair, per record (Placed-state runtimes only — Traveling
-- / Opening / carried eggs belong to live flows and are
-- never touched):
--   * slot gone            -> re-home record (+ runtime) to
--                             a free Reserved slot;
--   * runtime missing       -> respawn the model into the
--                             (Empty, Reserved) slot;
--   * model destroyed       -> rebuild + re-seat + Occupy +
--                             prompt reinstall (RefundHatch
--                             pattern);
--   * healthy pair          -> left alone (prompt installs are
--                             wipe-then-install idempotent, so
--                             reinstalls here are safe).
-- Returns counts; never throws (internal pcall); safe no-op
-- when nothing is stale.
function EggService.ReconcileAfterBaseSwap(userId: number): { [string]: number }
	local out = { rehomed = 0, rebuilt = 0 }
	pcall(function()
		if playerServiceRef == nil or slotServiceRef == nil or baseServiceRef == nil then
			return
		end
		local data = playerServiceRef.GetPlayerData(userId)
		if type(data) ~= 'table' then
			return
		end
		local base = baseServiceRef.GetPlayerBase and baseServiceRef.GetPlayerBase(userId) or nil
		if base == nil then
			return
		end
		if type(data.LuckyBlocks) ~= 'table' then
			return
		end
		for _, rec in ipairs(data.LuckyBlocks) do
			if type(rec) == 'table' and type(rec.Id) == 'string' then
				local slot = nil
				if type(rec.SlotId) == 'string' then
					pcall(function()
						slot = slotServiceRef._findSlotById(rec.SlotId)
					end)
				end
				local runtime: any = nil
				pcall(function()
					runtime = SpawnService.GetEgg(rec.Id)
				end)
				-- Live flows (Traveling/Opening/carried/consumed)
				-- own their runtime — never touch them.
				if runtime == nil or runtime.state == Constants.State.Placed then
					if slot == nil then
						-- Slot gone: re-home to a free slot.
						local free = slotServiceRef.GetFreeSlot(userId)
						if free ~= nil and slotServiceRef.ReserveSlot(free.id) then
							rec.SlotId = free.id
							if runtime ~= nil then
								runtime.slotId = free.id
								if runtime.model and runtime.model.Parent then
									HoverMath.Settle(runtime, free)
									StandPresentation.Bind(runtime.model, SlotType.OccupantKind.Egg)
									slotServiceRef.OccupySlot(free.id, runtime.uniqueId, SlotType.OccupantKind.Egg)
									SpawnService.InstallHatchPrompt(runtime, free, free.ownerUserId)
								else
									EggService.SpawnFromPersistence(userId, rec, free)
								end
							else
								EggService.SpawnFromPersistence(userId, rec, free)
							end
							out.rehomed = out.rehomed + 1
						else
							Debug.Warn('EG', 'ReconcileAfterBaseSwap: no free slot, record kept', {
								userId = tostring(userId),
								eggId = tostring(rec.Id),
							})
						end
					elseif runtime == nil then
						-- Record without runtime: respawn into the
						-- slot when it is Empty.
						if slot.state == SlotType.State.Empty and slotServiceRef.ReserveSlot(slot.id) then
							EggService.SpawnFromPersistence(userId, rec, slot)
							out.rebuilt = out.rebuilt + 1
						else
							Debug.Warn('EG', 'ReconcileAfterBaseSwap: slot not Empty, record kept', {
								userId = tostring(userId),
								eggId = tostring(rec.Id),
								slotId = tostring(rec.SlotId),
							})
						end
					else
						-- Runtime exists: heal a destroyed model and
						-- keep record/runtime slot agreement (the
						-- profile record is the source of truth,
						-- same as rejoin).
						if runtime.slotId ~= rec.SlotId then
							runtime.slotId = rec.SlotId
						end
						if runtime.model == nil or runtime.model.Parent == nil then
							if slot.state == SlotType.State.Empty then
								slotServiceRef.ReserveSlot(slot.id)
							end
							SpawnService.RebuildEggModel(runtime)
							if runtime.model and runtime.model.Parent then
								HoverMath.Settle(runtime, slot)
								StandPresentation.Bind(runtime.model, SlotType.OccupantKind.Egg)
								slotServiceRef.OccupySlot(slot.id, runtime.uniqueId, SlotType.OccupantKind.Egg)
								SpawnService.InstallHatchPrompt(runtime, slot, slot.ownerUserId)
								out.rebuilt = out.rebuilt + 1
							else
								Debug.Warn('EG', 'ReconcileAfterBaseSwap: model rebuild failed', {
									userId = tostring(userId),
									eggId = tostring(rec.Id),
								})
							end
						end
					end
				end
			end
		end
	end)
	Debug.Log('EG', 'ReconcileAfterBaseSwap done', {
		userId = tostring(userId),
		rehomed = tostring(out.rehomed),
		rebuilt = tostring(out.rebuilt),
	})
	return out
end

return table.freeze(EggService)
