--!strict
--!native
--[[
	Base.CollectorArrival
	=====================
	Owns the question "an Egg just reached its owner's
	Collector — where does it actually go?"

	This is deliberately a separate module from the flight that
	brought the egg here. A flight lasts
	`EggTravelDuration` seconds (7 at the time of
	writing), and a base can change a lot in 7 seconds: the
	owner can grab an egg off a slot, place an animal, fill
	the base, or have their reservation released by an admin
	command. So the landing slot CANNOT be decided at launch.
	`FlightController` targets the Collector and hands the egg
	here; this module re-validates against the base's state at
	the moment of arrival.

	Entry point: `OnArrival(egg, refs) -> boolean`. It is
	installed as the `onArrive` callback in
	`EggService.Purchase`, and is invoked by
	`FlightController._onComplete` at `t >= 1` — after the
	guards there and after the final `PivotTo(Collector)`.
	Arrival is therefore FLIGHT COMPLETION, not a `.Touched`
	signal: because the flight's destination IS the Collector,
	finishing the flight means being at it, with no chance of
	the Touched race (an egg that clips a corner of the
	Collector part on the way past, or a Touched that never
	fires because both parts are CanCollide = false).

	The sequence (REQ-013 .. REQ-016):
	  1. Guards — `_aborted`, model destroyed, state moved on.
	  2. Resolve the owner (egg.ownerUserId, else parse the
	     slot id).
	  3. Resolve the landing slot, three tiers (REQ-015):
	       Tier 1 — the launch-time reservation, if it is still
	                Reserved.
	       Tier 2 — any free slot, with the persistence record
	                re-pointed to it.
	       Tier 3 — nothing free: refund and destroy. NEVER
	                leave the egg orphaned over the Collector.
	  4. Teleport into the slot: ONE `PivotTo`, no tween, so
	     there is no visible bounce or overshoot (REQ-014).
	  5. `HoverMath.Settle` — refresh `centerCFrame` /
	     `_localFloor` and leave no controller.
	  6. `OccupySlot`.
	  7. Commit `Placed` and fire `egg._onArrived`.

	Does NOT own:
	  * Slot state transitions (SlotService)
	  * Cash / persistence (PlayerService)
	  * Prompt install / client pushes — that is
	    `egg._onArrived`, i.e. `EggService._onEggArrived`
	  * Any knowledge of how the egg got here (no flight
	    controller reference; the controller record is not read)
]]

local HoverMath = require(script.Parent.Parent.Egg.HoverMath)
local StandPresentation = require(script.Parent.Parent.StandPresentation)
local Constants = require(script.Parent.Parent.Egg.Constants)
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Validation = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.Parent.EconomyService)
-- Canonical player-facing rejections. Leaf module (no
-- ServerScriptService requires) — safe to load here even though
-- EggService requires this module.
local NotificationService = require(script.Parent.NotificationService)
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals)

local CollectorArrival = {}

-- --- Owner resolution ------------------------------------------

-- The userId whose base this egg belongs to.
--
-- `egg.ownerUserId` is stamped by `Purchase` before the flight
-- starts, so it is the primary source. The slot id is parsed as
-- a fallback for records that predate the stamp (and for the
-- persistence path, where the consumer sets the owner after the
-- spawn returns).
local function _resolveOwner(egg: any): number?
	if type(egg.ownerUserId) == 'number' and Validation.IsValidPlayerUserId(egg.ownerUserId) then
		return egg.ownerUserId
	end
	if type(egg.slotId) == 'string' then
		local parsed = SlotType.ParseId(egg.slotId)
		if parsed and Validation.IsValidPlayerUserId(parsed.userId) then
			return parsed.userId
		end
	end
	return nil
end

-- --- Tier 3: refund and drop -----------------------------------

-- Nothing in the base can hold the egg. Give the player their
-- cash back, release whatever stale reservation is left, destroy
-- the model, and drop the record.
--
-- The order matters: the persistence record is removed BEFORE
-- the registry drop, so a player who rejoins immediately does
-- not get an egg restored onto a slot that was never occupied.
local function _refundAndDrop(egg: any, refs: any, userId: number?, reason: string)
	Debug.Warn('EG', 'CollectorArrival: no slot available, refunding', {
		uniqueId = egg.uniqueId,
		userId = tostring(userId),
		reason = reason,
	})

	local playerService = refs and refs.playerService
	local slotService = refs and refs.slotService

	if userId and playerService then
		-- Phase 2.1: refund through EconomyService.AddMoney
		-- with the EggRefund reason. The amount is
		-- sanitized at the boundary (the same
		-- `egg.price` was the TrySpendMoney cost on the
		-- purchase path). If the price is malformed for any
		-- reason, skip the refund rather than corrupt the
		-- balance — the player will have lost the money, but
		-- the loss is at most one egg's price, not the
		-- entire economy.
		local refundStr = BigNumber.sanitize(tostring(egg.price))
		if refundStr then
			EconomyService.AddMoney(userId, refundStr, TransactionReason.EggRefund)
		else
			Debug.Warn('EG', 'CollectorArrival: refund skipped (invalid price)', {
				uniqueId = tostring(egg.uniqueId),
				price = tostring(egg.price),
			})
		end
		if playerService.RemoveEgg then
			-- Phase 2.5.1: remove by the record's own Id (the
			-- persistence key), not the slot id. The pre-2.5.1
			-- call passed the SlotId here, which never matched a
			-- record Id — the refunded egg's record silently
			-- survived and respawned as a free phantom egg on
			-- the next rejoin. The by-slot fallback covers the
			-- (load-time re-keyed) case where the runtime Id no
			-- longer matches any record.
			if not playerService.RemoveEgg(userId, egg.uniqueId) and egg.slotId then
				if not playerService.RemoveEggAtSlot(userId, egg.slotId) then
					Debug.Warn('EG', 'CollectorArrival: refunded egg had no persistence record to remove', {
						uniqueId = tostring(egg.uniqueId),
						slotId = tostring(egg.slotId),
					})
				end
			end
		end
	end

	-- Release the stale reservation so the slot is not left
	-- Reserved forever. Only safe because we are on the failure
	-- path: the egg never occupied it.
	if egg.slotId and slotService and slotService.ReleaseSlot then
		slotService.ReleaseSlot(egg.slotId)
	end
	egg.slotId = nil

	egg._aborted = true
	egg.controller = nil
	egg.controllerType = nil
	if egg.model then
		egg.model:Destroy()
		egg.model = nil
	end

	-- Drop from the spawn registry. Required lazily: SpawnService
	-- is required by EggService, which requires this
	-- module, so a top-level require here would close the cycle.
	local SpawnService = require(script.Parent.Parent.Egg.SpawnService)
	SpawnService.DropEgg(egg.uniqueId)

	if userId then
		local Players = game:GetService('Players')
		local player = Players:GetPlayerByUserId(userId)
		if player then
			-- Canonical rejection path (reason-owned text,
			-- throttle, Error SFX).
			pcall(NotificationService.NotifyWarning, player, 'Buy_ArrivalBaseFull')
		end
	end
end

-- --- Slot resolution -------------------------------------------

-- Returns the slot the egg should land on, or nil when the
-- base cannot hold it (caller then refunds).
--
-- Tier 1 — the slot named by `egg.slotId`, if it still exists
--   and is still `Reserved`. A Reserved slot records no
--   reserver (`slot.occupantId` is set only by `OccupySlot`),
--   so `state == Reserved` on the SPECIFICALLY NAMED slot is
--   the strongest check available. That is sufficient here
--   because `Purchase` reserves exactly one distinct slot per
--   flight (`GetFreeSlot` -> `ReserveSlot`) and stamps its id
--   on the egg, so no two in-flight eggs can name the same
--   slot.
--
-- Tier 2 — any free slot, reserved on the spot. The persistence
--   record is re-pointed from the old slot id to the new one, so
--   a rejoin restores the egg where it actually landed rather
--   than where it was heading.
local function _resolveLandingSlot(egg: any, refs: any, userId: number): any?
	local slotService = refs and refs.slotService
	if not slotService then
		return nil
	end

	-- Tier 1.
	if egg.slotId then
		local reserved = slotService._findSlotById(egg.slotId)
		if reserved and reserved.part and reserved.state == SlotType.State.Reserved then
			Debug.Log('EG', 'CollectorArrival: tier 1 — reservation intact', { slotId = egg.slotId })
			return reserved
		end
	end

	-- Tier 2.
	local fresh = slotService.GetFreeSlot(userId)
	if not fresh then
		return nil
	end
	if not slotService.ReserveSlot(fresh.id) then
		return nil
	end

	local oldSlotId = egg.slotId
	local playerService = refs and refs.playerService
	if playerService then
		-- Phase 2.5.1: re-point the SAME record to the new slot
		-- (identity preserved). The pre-2.5.1 code did
		-- RemoveEgg(oldSlotId) — a silent no-op, it
		-- matched records by Id — then AddEgg(fresh.id),
		-- which minted a SECOND record with a new Id. The stale
		-- record survived the open that followed and came back
		-- as a phantom Egg on rejoin: the reported
		-- Animal→Egg "conversion". SetEggSlot
		-- mutates the record in place; the Add fallback (with
		-- the runtime's own Id passed explicitly) covers a
		-- record that is genuinely missing, and can never mint
		-- a duplicate identity.
		local rePointed = playerService.SetEggSlot and playerService.SetEggSlot(userId, egg.uniqueId, fresh.id)
		if not rePointed and playerService.AddEgg then
			playerService.AddEgg(userId, fresh.id, egg.rarity, egg.uniqueId, {
				Mutations = egg.Mutations,
				Trait = egg.Trait,
			})
			Debug.Warn('EG', 'CollectorArrival: tier 2 record was missing, re-added at the new slot', {
				uniqueId = tostring(egg.uniqueId),
				slotId = fresh.id,
			})
		end
	end
	egg.slotId = fresh.id

	Debug.Log('EG', 'CollectorArrival: tier 2 — re-pointed to a new slot', {
		uniqueId = egg.uniqueId,
		oldSlotId = tostring(oldSlotId),
		newSlotId = fresh.id,
	})
	return fresh
end

-- --- OnArrival -------------------------------------------------

-- The egg is at the Collector. Land it.
--
-- Returns true when the egg ended up Placed on a slot, false
-- on every bail-out (guard tripped, no slot, occupy race).
--
-- `refs` is the egg's `_refs` table (playerService,
-- baseService, animalService, slotService), wired by
-- `SpawnService` at spawn time. Passing it in rather than
-- requiring the services keeps this module testable with fakes
-- and free of the service require cycle.
function CollectorArrival.OnArrival(egg: any, refs: any): boolean
	if not egg then
		return false
	end
	Debug.Log('EG', '> CollectorArrival.OnArrival', {
		uniqueId = tostring(egg.uniqueId),
		slotId = tostring(egg.slotId),
	})

	-- Step 1: guards. `FlightController._onComplete` checks the
	-- same three, but this module is a public entry point and a
	-- caller could reach it another way.
	if egg._aborted then
		return false
	end
	if not egg.model or not egg.model.Parent then
		return false
	end
	if egg.state ~= nil and egg.state ~= Constants.State.Traveling then
		Debug.Warn('EG', 'CollectorArrival: egg is not Traveling, bailing', {
			uniqueId = egg.uniqueId,
			state = tostring(egg.state),
		})
		return false
	end

	-- Step 2: owner.
	local userId = _resolveOwner(egg)
	if not userId then
		Debug.Warn('EG', 'CollectorArrival: cannot resolve owner, refunding is impossible', {
			uniqueId = egg.uniqueId,
		})
		_refundAndDrop(egg, refs, nil, 'no-owner')
		return false
	end

	-- Step 3: landing slot.
	local slot = _resolveLandingSlot(egg, refs, userId)
	if not slot then
		_refundAndDrop(egg, refs, userId, 'no-free-slot')
		return false
	end

	-- Steps 4 + 5: teleport into the slot and record where the
	-- egg now is. `Settle` is a single `PivotTo` to the slot's
	-- seated CFrame — no tween, no easing — so the egg appears
	-- in the slot on one frame with no bounce or overshoot. It
	-- also refreshes `centerCFrame` / `_localFloor` and leaves
	-- `controller = nil`: a resting egg is static.
	HoverMath.Settle(egg, slot)
	-- Stand wobble: bind the arrived model (rest = the settled
	-- pose, so the egg sits alive on its slot immediately).
	StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)

	-- Step 6: occupy.
	local slotService = refs and refs.slotService
	if not slotService.OccupySlot(slot.id, egg.uniqueId, SlotType.OccupantKind.Egg) then
		-- The slot changed under us between the resolve and the
		-- occupy. Leave the egg in `Traveling` and do NOT fire
		-- `_onArrived`: `Traveling` is what makes
		-- `SpawnService.ForceReleaseBase` willing to clean this
		-- egg up later. Committing `Placed` here would strand
		-- it forever, since the cleanup path only tears down
		-- Traveling / Opening eggs.
		Debug.Warn('EG', 'CollectorArrival: OccupySlot failed, leaving egg Traveling', {
			uniqueId = egg.uniqueId,
			slotId = slot.id,
		})
		return false
	end

	-- Step 7: commit and hand off to the consumer.
	egg.slotId = slot.id
	egg.state = Constants.State.Placed
	-- Tutorial guide layer observes the committed arrival
	-- (bus never throws; arrival itself is unaffected).
	pcall(TutorialSignals.Fire, 'EggPlaced', { EggId = egg.uniqueId, OwnerUserId = userId, SlotId = slot.id })
	if egg._onArrived then
		local ok, err = pcall(egg._onArrived, egg, slot, slot.id)
		if not ok then
			Debug.Warn('EG', 'CollectorArrival: _onArrived errored', {
				uniqueId = egg.uniqueId,
				err = tostring(err),
			})
		end
	end

	Debug.Log('EG', '< CollectorArrival.OnArrival: placed', {
		uniqueId = egg.uniqueId,
		slotId = slot.id,
	})
	return true
end

return table.freeze(CollectorArrival)
