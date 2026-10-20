--!strict
--!native
--[[
	CarryRegistry
	=============
	Single source of truth for "what is this player currently
	carrying". Phase 2 unification: a player can carry either a
	Egg or an Animal (exactly one at a time), and the
	authoritative state lives here so both services can ask
	without depending on each other.

	Why a separate module (and not a field on each service):
	  * Both EggService and AnimalService need to be
	    able to ask "is this player carrying something?" without
	    pulling in the other service.
	  * The grab-side precondition ("cannot grab while carrying")
	    is cross-service — EggService.GrabEgg must
	    reject if the player is carrying an Animal and vice
	    versa. With a shared registry, the check is symmetric and
	    instant.
	  * The death hook (bootstrap.server.lua) and the disconnect
	    path (RecoverCarriedX) want one call to learn "what
	    does this player need back, and what kind is it?"

	Wire shape:
	  carriedBy: { [userId]: CarriedItem }
	  CarriedItem = { kind, record, originalSlotId, startedAt }

	Not concerned with: how the carried item is welded to the
	player (CarryController does that). This is the state
	machine only.
]]

local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local CarryRegistry = {}

-- --- Public error codes ------------------------------------------

-- String codes a caller can check against. The actual error
-- surfacing (notification, log) is the caller's job; this just
-- gives them a stable name to switch on.
local CarryError = {
	InvalidPlayer = 'InvalidPlayer',
	AlreadyCarried = 'AlreadyCarried',
	PlayerAlreadyCarrying = 'PlayerAlreadyCarrying',
	NotCarrying = 'NotCarrying',
	KindMismatch = 'KindMismatch',
}
CarryRegistry.Error = table.freeze(CarryError)

-- --- Internal state ----------------------------------------------

local carriedBy: { [number]: any } = {} -- userId -> CarriedItem

-- Change subscribers (ResetProtectionService derives the
-- per-player reset gate from this registry — never from a
-- second boolean). Fired synchronously on every committed
-- Set/Clear, pcall-guarded so a subscriber can never break
-- the atomic grab/place/steal/recover paths. Reset by Init
-- (spec isolation + server restart parity).
local _subscribers: { (userId: number) -> () } = {}

local function _notify(userId: number)
	for _, callback in ipairs(_subscribers) do
		pcall(callback, userId)
	end
end

-- --- Helpers -----------------------------------------------------

local function resolveUserId(playerOrUserId: any): number?
	if typeof(playerOrUserId) == 'number' then
		return playerOrUserId :: number
	end
	-- Treat anything with a UserId as a Player-shaped object.
	if typeof(playerOrUserId) == 'Instance' and (playerOrUserId :: Instance):IsA('Player') then
		return (playerOrUserId :: Player).UserId
	end
	return nil
end

-- --- API ----------------------------------------------------------

function CarryRegistry.Init()
	carriedBy = {}
	_subscribers = {}
	Debug.Log('CR', 'Init: registry cleared')
end

-- Subscribe to committed carry changes. `callback(userId)` fires
-- synchronously after every successful Set and every Clear that
-- actually removed an item. Never fires for rejected writes.
-- Returns an unsubscribe function. Subscribers must be fast and
-- non-yielding; errors are swallowed (see _notify).
function CarryRegistry.OnChanged(callback: (userId: number) -> ()): () -> ()
	table.insert(_subscribers, callback)
	local active = true
	return function()
		if not active then
			return
		end
		active = false
		for i, existing in ipairs(_subscribers) do
			if existing == callback then
				table.remove(_subscribers, i)
				break
			end
		end
	end
end

-- Returns the CarriedItem for the player (or nil if none).
-- Accepts either a Player or a numeric userId.
function CarryRegistry.Get(playerOrUserId: any): any?
	local uid = resolveUserId(playerOrUserId)
	if not uid then
		return nil
	end
	return carriedBy[uid]
end

-- Returns true iff the player is currently carrying anything
-- (lucky or animal).
function CarryRegistry.IsCarrying(playerOrUserId: any): boolean
	return CarryRegistry.Get(playerOrUserId) ~= nil
end

-- Returns the kind of what the player is carrying, or nil if
-- the player is not carrying. Use this to branch on the
-- carried item type without inspecting the record shape.
function CarryRegistry.GetKind(playerOrUserId: any): string?
	local item = CarryRegistry.Get(playerOrUserId)
	if not item then
		return nil
	end
	return item.kind
end

-- Reserve the player as carrying `item`. The precondition is
-- `IsCarrying(userId) == false`; otherwise PlayerAlreadyCarrying
-- is returned. `item` MUST be a table with:
--   * kind: SlotType.OccupantKind.* (string)
--   * record: the owned record (Egg or Animal)
--   * originalSlotId: string (the slot the item came from;
--     used by RecoverForPlayer to put it back)
--   * startedAt: number (tick() at grab; used for stuck-carry
--     diagnostics)
function CarryRegistry.Set(userId: number, item: any): (boolean, string?)
	if type(userId) ~= 'number' then
		return false, CarryError.InvalidPlayer
	end
	if type(item) ~= 'table' then
		return false, CarryError.InvalidPlayer
	end
	if carriedBy[userId] then
		Debug.Warn('CR', 'Set: player already carrying', { userId = tostring(userId) })
		return false, CarryError.PlayerAlreadyCarrying
	end
	if item.kind ~= SlotType.OccupantKind.Egg and item.kind ~= SlotType.OccupantKind.Animal then
		Debug.Warn('CR', 'Set: invalid kind', { kind = tostring(item.kind) })
		return false, CarryError.KindMismatch
	end
	carriedBy[userId] = item
	Debug.Log('CR', 'Set: ok', { userId = tostring(userId), kind = item.kind })
	-- Global tool lock: a carrying player cannot have a gameplay
	-- Tool equipped (steal, own animal/egg pickup alike — kind is
	-- irrelevant). Moved to the Backpack, never destroyed; usable
	-- again once the carry ends. Server-side activation gates
	-- (e.g. BatService) re-check IsCarrying, so a forged request
	-- or a mid-carry re-equip can never bypass this.
	pcall(function()
		local player = game:GetService('Players'):GetPlayerByUserId(userId)
		local character = if player ~= nil then player.Character else nil
		local humanoid = if character ~= nil then character:FindFirstChildOfClass('Humanoid') else nil
		if humanoid ~= nil then
			humanoid:UnequipTools()
		end
	end)
	_notify(userId)
	return true, nil
end

-- Drop the carried item for the player. Returns the cleared
-- item (or nil if the player wasn't carrying). NotCarrying is
-- returned only when called with a non-number argument; for
-- a player who isn't carrying, we treat it as a no-op
-- success.
function CarryRegistry.Clear(userId: number): (any?, string?)
	if type(userId) ~= 'number' then
		return nil, CarryError.InvalidPlayer
	end
	local item = carriedBy[userId]
	if not item then
		return nil, CarryError.NotCarrying
	end
	carriedBy[userId] = nil
	Debug.Log('CR', 'Clear: ok', { userId = tostring(userId), kind = item.kind })
	_notify(userId)
	return item, nil
end

-- Iterate over all currently-carried items. Used by the
-- death hook / server shutdown paths to recover everything
-- in one pass.
function CarryRegistry.ForEach(callback: (userId: number, item: any) -> ())
	for uid, item in pairs(carriedBy) do
		callback(uid, item)
	end
end

-- Snapshot a single player's carried item for the wire
-- (PlayerService.PushState). Returns { Kind, Name, Steal }
-- where Name is the animal's displayName or the lucky egg's
-- rarity (no displayName on Egg records in Phase 1.5), and
-- Steal is true while the carry is a steal in progress
-- (drives the thief's prompt suppression client-side).
function CarryRegistry.Snapshot(userId: number): { Kind: string?, Name: string?, Steal: boolean? }
	local item = carriedBy[userId]
	if not item then
		return { Kind = nil, Name = nil, Steal = nil }
	end
	local name: string? = nil
	if item.kind == SlotType.OccupantKind.Animal and type(item.record) == 'table' then
		name = item.record.displayName
	elseif item.kind == SlotType.OccupantKind.Egg and type(item.record) == 'table' then
		-- Egg has no displayName; surface the rarity as
		-- the HUD label.
		name = item.record.rarity
	end
	return { Kind = item.kind, Name = name, Steal = item.steal ~= nil }
end

return table.freeze(CarryRegistry)
