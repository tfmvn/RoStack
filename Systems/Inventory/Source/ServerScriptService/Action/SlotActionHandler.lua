--!strict
--!native
--[[
	SlotActionHandler
	=================
	Server-side dispatch for the slot action menu. With
	native ProximityPrompt (post Phase 2.1 revert), the
	Triggered server callback in CarryPrompts calls into
	this handler with { Action, SlotId, OccupantId? } for
	each prompt fire. The handler validates the request
	and routes to the right service:

   Pickup   -> _egg().GrabEgg | _animal().GrabAnimal
   Hatch    -> _egg().HatchEgg  (Egg only)
   Place    -> _egg().PlaceEgg | _animal().PlaceAnimal
   SellAnimal (Animal only, from the animal's Sell prompt)
     -> _sell(). Eggs are NOT sellable: any 'SellEgg'
     action is rejected (no branch, no path).
   Sell     -> legacy placeholder; returns
              { success = false, error = 'not-implemented' }

	Validation (server-authoritative):
	  * Action is in the per-kind Actions table.
	  * SlotId is a real slot on a base the player owns.
	  * OccupantId (when required) matches the slot's occupant.
	  * Carry-gate: Pickup is rejected while carrying;
	    Open is rejected while carrying; Place requires
	    carrying.

	Rejection reasons (stable wire shape):
	  'InvalidAction' | 'InvalidSlot' | 'NotOwner' | 'NotOccupant'
	  | 'WrongKind' | 'AlreadyCarrying' | 'NotCarrying'
	  | 'NotImplemented' | 'ServiceError'
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Prompts = require(ReplicatedStorage.Config.World.Prompts)
local Debug = require(ReplicatedStorage.Utility.Debug)
local Validation = require(ReplicatedStorage.Utility.Validation)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local BaseService = require(ServerScriptService.BaseService)
local SlotService = require(ServerScriptService.Base.SlotService)
local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
-- Canonical player feedback (warnings). Leaf module — cycle-free.
local NotificationService = require(ServerScriptService.Base.NotificationService)

-- Lazy requires for the carry services. Resolved on first
-- dispatch to avoid a require cycle: bootstrap requires
-- EggService, which requires SlotActionHandler for
-- the Open prompt callback, which used to require
-- EggService back at module-load time. Resolving
-- on first call breaks the cycle.
local _eggService: any = nil
local _animalService: any = nil
local _sellService: any = nil
local function _egg(): any
	if not _eggService then
		_eggService = require(ServerScriptService.EggService)
	end
	return _eggService
end
local function _animal(): any
	if not _animalService then
		_animalService = require(ServerScriptService.AnimalService)
	end
	return _animalService
end

-- Phase 2.8 sell dispatch. Lazy for the same cycle reason as
-- above (SellService requires this handler at load for its
-- prompt callback; the require back happens here at call time).
local function _sell(): any
	if not _sellService then
		_sellService = require(ServerScriptService.SellService)
	end
	return _sellService
end

local SlotActionHandler = {}

-- Pick/Place single-flight guard: at most ONE in-flight Pick/Place
-- commit per player. The 2-second ProximityPrompt hold already
-- collapses press-spam client-side (early release never reaches
-- the server), but two completed holds racing in the same instant
-- — or a stale prompt closure firing after a fresh commit — must
-- not double-commit. The flag lives only for the synchronous
-- dispatch below and is always released in finish(), so death,
-- leave, or respawn can never leak it; those cases are rejected
-- by the services' own liveness/distance/ownership checks at
-- commit time.
local activePickPlaceByUserId: { [number]: boolean } = {}

-- Stable error codes clients can switch on.
SlotActionHandler.Error = table.freeze({
	InvalidAction = 'InvalidAction',
	InvalidSlot = 'InvalidSlot',
	NotOwner = 'NotOwner',
	NotOccupant = 'NotOccupant',
	WrongKind = 'WrongKind',
	AlreadyCarrying = 'AlreadyCarrying',
	NotCarrying = 'NotCarrying',
	NotImplemented = 'NotImplemented',
	ServiceError = 'ServiceError',
})

-- Normalise the heterogeneous return shapes of the underlying
-- services into a single `{ success, error?, detail? }` wire
-- table. EggService returns `{ success, error }`; the
-- animal service returns `Error.X | nil` (nil = success,
-- a string reason = failure). Anything else is treated as a
-- success (services that have nothing to return).
local function normalise(result: any): { [string]: any }?
	if result == nil then
		return { success = true }
	end
	if type(result) == 'table' then
		if result.success == false then
			return {
				success = false,
				error = SlotActionHandler.Error.ServiceError,
				detail = result.error,
			}
		end
		return { success = true }
	end
	if type(result) == 'string' then
		return {
			success = false,
			error = SlotActionHandler.Error.ServiceError,
			detail = result,
		}
	end
	return { success = true }
end

-- Look up the action list for a given (kind, state). Returns
-- a list of action names, or nil if no actions are valid for
-- this combination (e.g. an empty slot when the player is
-- not carrying).
local function actionsFor(kind: string?, state: string?): { string }?
	if state == SlotType.State.Occupied and kind == SlotType.OccupantKind.Egg then
		return Prompts.Carry.Actions[SlotType.OccupantKind.Egg]
	elseif state == SlotType.State.Occupied and kind == SlotType.OccupantKind.Animal then
		return Prompts.Carry.Actions[SlotType.OccupantKind.Animal]
	elseif state == SlotType.State.Empty then
		return Prompts.Carry.Actions.Empty
	elseif state == SlotType.State.Reserved then
		return Prompts.Carry.Actions.Reserved
	end
	return nil
end

-- Handle a slot action request from the client. Returns a
-- `{ success, error?, payload? }` table the client can switch
-- on. Never throws — all validation is internal.
function SlotActionHandler.Handle(player: Player, request: any): { [string]: any }
	Debug.Log('SAH', '> Handle', {
		name = player.Name,
		action = tostring(request and request.Action),
		slotId = tostring(request and request.SlotId),
	})
	-- Pre-finish notifier: the structural rejections below
	-- return before finish() exists. Malformed requests always
	-- get the generic fallback (never internals).
	local function notifyEarly(error: string)
		pcall(NotificationService.NotifyWarning, player, 'General_Generic')
		Debug.Log('SAH', '< Handle', {
			result = 'false',
			error = tostring(error),
		})
	end
	if type(request) ~= 'table' then
		local _r = { success = false, error = SlotActionHandler.Error.InvalidAction }
		notifyEarly(_r.error)
		return _r
	end
	local action = request.Action
	local slotId = request.SlotId
	local occupantId = request.OccupantId

	-- Action-aware structural warning: the same structural
	-- failure reads differently per prompt (Pickup vs Place vs
	-- Hatch vs Sell). Defined here so the early returns below
	-- can use it.
	local function _slotWarningFor(actionName: any, kind: string): string
		if actionName == 'Pickup' then
			if kind == 'NotOwner' then
				return 'Pickup_NotOwner'
			end
			return 'Pickup_InvalidSlot'
		elseif actionName == 'Place' then
			if kind == 'NotOwner' then
				return 'Place_NotOwner'
			end
			return 'Place_InvalidSlot'
		elseif actionName == 'Hatch' then
			return 'Hatch_InvalidTarget'
		elseif actionName == 'SellAnimal' then
			if kind == 'NotOwner' then
				return 'Sale_NotOwner'
			end
			return 'Sale_StaleTarget'
		end
		return 'General_Generic'
	end

	if type(action) ~= 'string' or type(slotId) ~= 'string' then
		local _r = { success = false, error = SlotActionHandler.Error.InvalidAction }
		notifyEarly(_r.error)
		return _r
	end
	Validation.SlotId(slotId)

	-- 1. Slot must exist.
	local slot = SlotService._findSlotById(slotId)
	if not slot then
		local _r = { success = false, error = SlotActionHandler.Error.InvalidSlot }
		pcall(NotificationService.NotifyWarning, player, _slotWarningFor(action, 'InvalidSlot'))
		Debug.Log('SAH', '< Handle', {
			result = tostring(_r.success),
			error = tostring(_r.error),
		})
		return _r
	end

	-- 2. Slot must be on a base the player owns.
	local base = BaseService.GetBaseById(slot.baseId)
	if not base or base.ownerUserId ~= player.UserId then
		local _r = { success = false, error = SlotActionHandler.Error.NotOwner }
		pcall(NotificationService.NotifyWarning, player, _slotWarningFor(action, 'NotOwner'))
		Debug.Log('SAH', '< Handle', {
			result = tostring(_r.success),
			error = tostring(_r.error),
		})
		return _r
	end

	-- 3. Action must be in the per-kind list for this slot's
	--    (kind, state) tuple. This is the same check the
	--    client UI uses to decide which buttons to render, so
	--    a request that passes here was visible to the player.
	local allowed = actionsFor(slot.occupantKind, slot.state)
	if not allowed then
		local _r = { success = false, error = SlotActionHandler.Error.WrongKind }
		notifyEarly(_r.error)
		return _r
	end
	local actionAllowed = false
	for _, a in ipairs(allowed) do
		if a == action then
			actionAllowed = true
			break
		end
	end
	if not actionAllowed then
		local _r = { success = false, error = SlotActionHandler.Error.InvalidAction }
		notifyEarly(_r.error)
		return _r
	end

	-- Single-flight gate for Pick/Place: a second Pick/Place that
	-- arrives while one is still committing is rejected with the
	-- existing 'in-progress' detail, which rejectionReason() maps
	-- to the 'General_Cooldown' ("Please wait...") warning.
	-- Hatch/Sell/upgrade paths are untouched.
	local isPickOrPlace = action == 'Pickup' or action == 'Place'
	if isPickOrPlace then
		local uid = player.UserId
		if activePickPlaceByUserId[uid] then
			local _r = {
				success = false,
				error = SlotActionHandler.Error.ServiceError,
				detail = 'in-progress',
			}
			pcall(NotificationService.NotifyWarning, player, 'General_Cooldown')
			Debug.Log('SAH', '< Handle', {
				result = tostring(_r.success),
				error = 'in-progress (single-flight)',
			})
			return _r
		end
		activePickPlaceByUserId[uid] = true
	end

	-- Map a rejection (handler code + service detail) to one
	-- canonical WarningMessages catalog id. Returns nil for the
	-- paths that stay silent (dead-character lockouts — death
	-- needs no explanation — and pure player shims).
	local function rejectionReason(actionName: string?, error: string?, detail: any): string?
		if error == SlotActionHandler.Error.AlreadyCarrying then
			if actionName == 'Hatch' then
				return 'Hatch_AlreadyCarrying'
			elseif actionName == 'Pickup' then
				return 'Pickup_AlreadyCarrying'
			end
			return 'General_Generic'
		elseif error == SlotActionHandler.Error.NotCarrying then
			return 'Place_NotCarrying'
		elseif error == SlotActionHandler.Error.InvalidSlot then
			return _slotWarningFor(actionName, 'InvalidSlot')
		elseif error == SlotActionHandler.Error.NotOwner then
			return _slotWarningFor(actionName, 'NotOwner')
		elseif error == SlotActionHandler.Error.NotOccupant then
			-- Pressed a prompt that moved on (stale slot).
			if actionName == 'Hatch' then
				return 'Hatch_InvalidTarget'
			elseif actionName == 'SellAnimal' then
				return 'Sale_StaleTarget'
			end
			return 'Pickup_TargetGone'
		elseif error == SlotActionHandler.Error.ServiceError then
			local d = detail
			if d == 'already-carrying' or d == 'PlayerAlreadyCarrying' or d == 'carrying' then
				if actionName == 'Hatch' then
					return 'Hatch_AlreadyCarrying'
				elseif actionName == 'Pickup' then
					return 'Pickup_AlreadyCarrying'
				end
				return 'General_Generic'
			elseif d == 'player-not-live' or d == 'PlayerNotLive' or d == 'InvalidPlayer' or d == 'invalid-player' then
				return nil
			elseif d == 'not-carrying' or d == 'NotCarried' then
				return 'Place_NotCarrying'
			elseif d == 'too-far' or d == 'TooFar' then
				if actionName == 'Place' then
					return 'Place_TooFar'
				end
				return 'Pickup_TooFar'
			elseif d == 'SlotOccupied' then
				return 'Place_SlotOccupied'
			elseif d == 'SlotReserved' or d == 'slot-race' then
				-- A lost race for a PLACE destination reads as
				-- occupied; anywhere else the target is gone.
				if actionName == 'Place' then
					return 'Place_SlotOccupied'
				elseif actionName == 'Hatch' then
					return 'Hatch_InvalidTarget'
				elseif actionName == 'SellAnimal' then
					return 'Sale_StaleTarget'
				end
				return 'Pickup_TargetGone'
			elseif d == 'in-progress' then
				return 'General_Cooldown'
			elseif
				d == 'egg-not-found'
				or d == 'AnimalNotFound'
				or d == 'not-found'
				or d == 'not-placed'
				or d == 'not-slotted'
				or d == 'NotSlotted'
				or d == 'no-slot'
				or d == 'InvalidSlot'
			then
				if actionName == 'Hatch' then
					return 'Hatch_InvalidTarget'
				elseif actionName == 'SellAnimal' then
					return 'Sale_StaleTarget'
				end
				return 'Pickup_TargetGone'
			elseif d == 'not-owner' or d == 'NotOwner' then
				if actionName == 'Place' then
					return 'Place_NotOwner'
				elseif actionName == 'SellAnimal' then
					return 'Sale_NotOwner'
				elseif actionName == 'Hatch' then
					return 'Hatch_InvalidTarget'
				end
				return 'Pickup_NotOwner'
			elseif d == 'steal-in-progress' or d == 'StealInProgress' then
				return 'Place_StealLocked'
			elseif d == 'carry-mismatch' then
				return 'Place_CarryMismatch'
			elseif d == 'carried' or d == 'invalid-state' then
				return 'Sale_InvalidState'
			elseif d == 'busy' or d == 'RaidLocked' then
				-- 'busy' covers racing transactions; 'RaidLocked'
				-- covers Arena-raid fighters (grab/sell/upgrade
				-- all reject while the raid runs).
				return 'General_Cooldown'
			elseif d == 'pool-busy' then
				return 'Sale_PoolBusy'
			elseif d == 'grant-failed' or d == 'no-sell-value' then
				return 'Sale_Failed'
			elseif d == 'template-missing' or d == 'no-definition' or d == 'roll-aborted' or d == 'create-failed' then
				-- HatchEgg already reported Hatch_Failed at the
				-- failure site — stay silent here so one hatch
				-- failure = one toast.
				return nil
			elseif actionName == 'SellAnimal' then
				return 'Sale_Failed'
			end
			return 'General_Generic'
		end
		-- WrongKind / InvalidAction / NotImplemented and any
		-- other malformed request: a clean generic rejection.
		return 'General_Generic'
	end

	-- Helper: log the return and yield. Every exit path goes
	-- through this so the [SAH] < Handle log always fires.
	-- Failures ALSO notify the acting player once through the
	-- canonical NotificationService (throttled, with Error SFX)
	-- — the returned table is unchanged (specs assert on it).
	local function finish(r: { [string]: any }): { [string]: any }
		-- Always release the single-flight flag (every post-gate
		-- exit funnels through here).
		if isPickOrPlace then
			activePickPlaceByUserId[player.UserId] = nil
		end
		Debug.Log('SAH', '< Handle', {
			result = tostring(r.success),
			error = tostring(r.error),
		})
		if type(r) == 'table' and r.success == false then
			local reason = rejectionReason(action, r.error, r.detail)
			if reason ~= nil then
				pcall(NotificationService.NotifyWarning, player, reason)
			end
		end
		return r
	end

	-- 4. Action-specific validation + dispatch.
	if action == 'Pickup' then
		-- Carry-gate: cannot pickup while already carrying.
		if CarryRegistry.IsCarrying(player) then
			return finish({ success = false, error = SlotActionHandler.Error.AlreadyCarrying })
		end
		-- OccupantId must match the slot's current occupant.
		if occupantId ~= slot.occupantId then
			return finish({ success = false, error = SlotActionHandler.Error.NotOccupant })
		end
		if slot.occupantKind == SlotType.OccupantKind.Egg then
			local r = _egg().GrabEgg(player, occupantId)
			return finish(normalise(r) or { success = true })
		elseif slot.occupantKind == SlotType.OccupantKind.Animal then
			local r = _animal().GrabAnimal(player, occupantId)
			return finish(normalise(r) or { success = true })
		end
		return finish({ success = false, error = SlotActionHandler.Error.WrongKind })
	elseif action == 'Hatch' then
		-- Egg only.
		if slot.occupantKind ~= SlotType.OccupantKind.Egg then
			return finish({ success = false, error = SlotActionHandler.Error.WrongKind })
		end
		if CarryRegistry.IsCarrying(player) then
			return finish({ success = false, error = SlotActionHandler.Error.AlreadyCarrying })
		end
		if occupantId ~= slot.occupantId then
			return finish({ success = false, error = SlotActionHandler.Error.NotOccupant })
		end
		local r = _egg().HatchEgg(player, occupantId)
		return finish(normalise(r) or { success = true })
	elseif action == 'Place' then
		-- Place requires carrying.
		if not CarryRegistry.IsCarrying(player) then
			return finish({ success = false, error = SlotActionHandler.Error.NotCarrying })
		end
		local item = CarryRegistry.Get(player)
		if not item then
			return finish({ success = false, error = SlotActionHandler.Error.NotCarrying })
		end
		if item.kind == SlotType.OccupantKind.Egg then
			local r = _egg().PlaceEgg(player, item.record.uniqueId, slotId)
			return finish(normalise(r) or { success = true })
		elseif item.kind == SlotType.OccupantKind.Animal then
			local r = _animal().PlaceAnimal(player, item.record.uniqueId, slotId)
			return finish(normalise(r) or { success = true })
		end
		return finish({ success = false, error = SlotActionHandler.Error.WrongKind })
	elseif action == 'Sell' then
		-- Legacy placeholder (locked test behavior). The live
		-- sell action is 'SellAnimal' below. Return a stable
		-- rejection so the client can disable the button.
		return finish({ success = false, error = SlotActionHandler.Error.NotImplemented })
	elseif action == 'SellAnimal' then
		-- Animal sell (Sell prompt on the animal). No
		-- player-level carry gate (unlike Pickup / Hatch):
		-- selling a placed object while carrying another
		-- is harmless, and the carried object itself is rejected
		-- object-side by SellService ('carried'). OccupantId must
		-- match the slot's live occupant; kind must be Animal
		-- (a stale prompt closure fails safe here). Eggs have
		-- NO sell action: any 'SellEgg' falls through to the
		-- InvalidAction rejection below.
		if occupantId ~= slot.occupantId then
			return finish({ success = false, error = SlotActionHandler.Error.NotOccupant })
		end
		if slot.occupantKind ~= SlotType.OccupantKind.Animal then
			return finish({ success = false, error = SlotActionHandler.Error.WrongKind })
		end
		local r = _sell().SellAnimal(player, occupantId)
		return finish(normalise(r) or { success = true })
	end

	return finish({ success = false, error = SlotActionHandler.Error.InvalidAction })
end

return table.freeze(SlotActionHandler)
