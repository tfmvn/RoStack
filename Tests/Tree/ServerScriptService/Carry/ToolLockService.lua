--!strict
--!native
--[[
	ToolLockService
	===============
	Server-authoritative gameplay-Tool lock derived from the single
	carry source of truth. While CarryRegistry holds an entry for a
	player (stealing an Animal/Egg, carrying their own Animal/Egg —
	kind and ownership are irrelevant), that player may not equip
	or activate gameplay Tools (Bat, future weapons, any Tool).

	Authority model (no second boolean, nothing to go stale):
	  CarryRegistry (single source of truth)
	        |
	        +-- OnChanged(userId)          (committed Set/Clear only)
	        v
	  ToolLockService.Refresh(userId)
	        |
	        +-- recompute from CarryRegistry.IsCarrying live
	        +-- push S->C `CarryLock` RemoteEvent on CHANGE only
	        v
	  client ToolLockController locks the Backpack/hotbar and
	  force-unequips (StarterGui Backpack off + UnequipTools +
	  equip-guard); the server ALSO unequips at Set time
	  (CarryRegistry) and every server-activated Tool gates on
	  IsCarrying — forged requests and mid-carry re-equips fail.

	Unlock is automatic: any Clear (place, cancel, recover,
	Bat-hit interrupt, death/leave hooks) recomputes to false and
	pushes. Nothing here destroys, moves, or reassigns Tools —
	lock is purely equip/activate prevention, fully temporary.
	No timers, no polling: every push originates from a
	CarryRegistry commit.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local CarryRegistry = require(script.Parent.CarryRegistry)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)

local ToolLockService = {}

-- Last PUSHED locked state per userId. Change-only pushes.
local pushedLocked: { [number]: boolean } = {}
local unsubscribeHook: (() -> ())? = nil

local function resolveUserId(playerOrUserId: any): number?
	if typeof(playerOrUserId) == 'number' then
		return playerOrUserId :: number
	end
	if typeof(playerOrUserId) == 'Instance' and (playerOrUserId :: Instance):IsA('Player') then
		return (playerOrUserId :: Player).UserId
	end
	return nil
end

-- Server-side query (Tool activation guards, debug invariants).
-- Always recomputed live — never the push cache.
function ToolLockService.IsLocked(playerOrUserId: any): boolean
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false
	end
	return CarryRegistry.IsCarrying(userId)
end

-- Push the current lock to one player when it CHANGED since the
-- last push. Never throws. No player object -> cache only.
function ToolLockService.Refresh(playerOrUserId: any)
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return
	end
	local locked = CarryRegistry.IsCarrying(userId)
	if pushedLocked[userId] == locked then
		return
	end
	pushedLocked[userId] = locked
	local player: Player? = Players:GetPlayerByUserId(userId)
	if player == nil then
		return
	end
	if locked then
				Debug.Warn('ToolLock', ('ENABLE player=%s reason=CarryActive'):format(player.Name))
	else
				Debug.Warn('ToolLock', ('DISABLE player=%s reason=NoActiveCarry'):format(player.Name))
	end
	local ok, err = pcall(Remotes.FireClient, player, Remotes.Names.CarryLock, {
		Locked = locked,
	})
	if not ok then
		Debug.Warn('ToolLock', 'Refresh: push failed (client syncs on next change)', {
			userId = tostring(userId),
			error = tostring(err),
		})
	end
end

-- Drop per-player push cache. Called on PlayerRemoving (the
-- client is gone; there is nothing to push) and by specs.
-- Never touches CarryRegistry — transaction cleanup owns that.
function ToolLockService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	pushedLocked[userId] = nil
	Debug.Log('ToolLock', 'ForgetPlayer: cache cleared', { userId = tostring(userId) })
end

function ToolLockService.Init()
	if unsubscribeHook then
		pcall(unsubscribeHook)
		unsubscribeHook = nil
	end
	unsubscribeHook = CarryRegistry.OnChanged(function(userId: number)
		ToolLockService.Refresh(userId)
	end)
	Debug.Log('ToolLock', 'Init: subscribed to CarryRegistry')
end

-- TEST-ONLY seam: drop the push cache (specs assert exact push
-- behaviour per transition). Does NOT unsubscribe the hook.
function ToolLockService._TestReset()
	for key in pairs(pushedLocked) do
		pushedLocked[key] = nil
	end
end

return table.freeze(ToolLockService)
