--!strict
--!native
--[[
	ResetProtectionService
	======================
	Server-authoritative reset gate for transient Animal (and Egg)
	carry transactions.

	Why: resetting (Character destruction) in the middle of a
	carry — owned pickup, steal carry, or the grab/place commit
	itself — can strand slot reservations, the CarryController
	weld, and the carried record mid-mutation. Normal reset must
	keep working everywhere else, so the gate is lifecycle-bound:
	protected while a carry exists, allowed the moment it
	resolves.

	Authority model (no second boolean, nothing to go stale):
	  CarryRegistry (single source of truth for "what is this
	  player carrying")
	        |
	        +-- OnChanged(userId)          (committed Set/Clear only)
	        v
	  ResetProtectionService.Refresh(userId)
	        |
	        +-- recompute from CarryRegistry.Get(userId) live
	        +-- push S->C `ResetProtection` RemoteEvent on CHANGE only
	        v
	  client ResetProtectionController toggles the reset button
	  (StarterGui:SetCore("ResetButtonCallback", false/true))

	Protected states (all are "CarryRegistry has an entry"):
	  * CarryingAnimal — owned pickup committed, placement pending
	  * CarryingEgg    — Egg grab/place is the same transient
	    carried-object transaction shape (Reserved slot + weld);
	    resetting mid-carry corrupts it identically
	  * Stealing       — steal-carry (item.steal ~= nil), covering
	    steal delivery, cancellation, and recovery

	NOT protected (deliberately): slot menus open, upgrades,
	cash collection, level-up VFX, prompt proximity, hold
	started-but-uncommitted (the server only sees the completed
	hold via Triggered — a released hold never reaches the
	server, so there is nothing to corrupt).

	Stale-transaction safety (§10): protection is RECOMPUTED from
	live registry state on every change — no per-transaction flag
	exists for a late callback to flip. A T100 callback arriving
	during T101 cannot enable/disable anything; only the current
	registry content decides.

	Rapid pickup/place (§11): Set->Clear->Set pushes
	true->false->true in order (RemoteEvents preserve per-client
	order); single carry per player is enforced by
	CarryRegistry itself.

	Death/disconnect (§8/§18/§19): this service is NOT recovery.
	The existing Died / CharacterRemoving / PlayerRemoving
	recovery (StealService.RollbackIfStealing, then
	RecoverCarriedAnimal/RecoverCarriedEgg) still runs and still
	owns the Animal — its CarryRegistry.Clear re-triggers Refresh
	so the gate opens after recovery. Fail-safe (§25): unknown or
	absent carry state resolves to ALLOWED.

	No timers, no polling: every push originates from a
	CarryRegistry commit or an explicit lifecycle Refresh
	(join / CharacterAdded / leave cleanup).
]]

local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local CarryRegistry = require(script.Parent.CarryRegistry)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)

local ResetProtectionService = {}

-- Reasons surfaced to the client (display) and the log.
ResetProtectionService.Reason = table.freeze({
	CarryingAnimal = 'CarryingAnimal',
	CarryingEgg = 'CarryingEgg',
	Stealing = 'Stealing',
})

-- Last PUSHED protected state per userId. Change-only pushes:
-- a refresh that recomputes the same value sends nothing (no
-- spam, no redundant SetCore traffic).
local pushedProtected: { [number]: boolean } = {}
-- Registry hook handle. Init always (re)subscribes after
-- dropping the previous hook, so the wiring survives any
-- CarryRegistry.Init order (production boot, spec beforeEach).
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

local function transactionIdFor(item: any): string
	local tx, started = '?', '?'
	if type(item) == 'table' then
		if type(item.record) == 'table' and type(item.record.uniqueId) == 'string' then
			tx = item.record.uniqueId
		end
		if item.startedAt ~= nil then
			started = tostring(item.startedAt)
		end
	end
	return tx .. '@' .. started
end

-- Recompute the gate from LIVE registry state. Returns
-- (protected, reason?). Absent/unknown carry -> (false, nil).
local function compute(userId: number): (boolean, string?)
	local item = CarryRegistry.Get(userId)
	if type(item) ~= 'table' then
		return false, nil
	end
	if item.steal ~= nil then
		return true, ResetProtectionService.Reason.Stealing
	end
	if item.kind == SlotType.OccupantKind.Animal then
		return true, ResetProtectionService.Reason.CarryingAnimal
	end
	if item.kind == SlotType.OccupantKind.Egg then
		return true, ResetProtectionService.Reason.CarryingEgg
	end
	-- Unknown kind: a registry entry still means an active
	-- carried-object transaction — stay protected, never strand
	-- the gate open on a shape we don't recognise.
	return true, 'Carrying'
end

-- Push the current gate to one player when it CHANGED since the
-- last push. Never throws. No player object (Studio specs,
-- already-removed players) -> cache only, no remote traffic.
function ResetProtectionService.Refresh(playerOrUserId: any)
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return
	end
	local protected, reason = compute(userId)
	if pushedProtected[userId] == protected then
		return
	end
	pushedProtected[userId] = protected
	local player: Player? = Players:GetPlayerByUserId(userId)
	if player == nil then
		return
	end
	local item = CarryRegistry.Get(userId)
	local name = player.Name
	if protected then
				Debug.Warn('ResetProtection', ('ENABLE player=%s reason=%s tx=%s'):format(
				name,
				tostring(reason),
				transactionIdFor(item)
			))
	else
				Debug.Warn('ResetProtection', ('DISABLE player=%s reason=%s'):format(name, tostring(reason or 'NoActiveCarry')))
	end
	local ok, err = pcall(Remotes.FireClient, player, Remotes.Names.ResetProtection, {
		Protected = protected,
		Reason = reason,
	})
	if not ok then
		Debug.Warn('RP', 'Refresh: push failed (client syncs on next change)', {
			userId = tostring(userId),
			error = tostring(err),
		})
	end
end

-- Server-side query (reset-request guards, debug invariants).
-- Always recomputed live — never the push cache.
function ResetProtectionService.IsProtected(playerOrUserId: any): boolean
	local userId = resolveUserId(playerOrUserId)
	if not userId then
		return false
	end
	local protected, _ = compute(userId)
	return protected
end

-- Drop per-player push cache. Called on PlayerRemoving (the
-- client is gone; there is nothing to push) and by specs.
-- Never touches CarryRegistry — transaction cleanup owns that.
function ResetProtectionService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	pushedProtected[userId] = nil
	Debug.Log('RP', 'ForgetPlayer: cache cleared', { userId = tostring(userId) })
end

function ResetProtectionService.Init()
	if unsubscribeHook then
		pcall(unsubscribeHook)
		unsubscribeHook = nil
	end
	unsubscribeHook = CarryRegistry.OnChanged(function(userId: number)
		ResetProtectionService.Refresh(userId)
	end)
	Debug.Log('RP', 'Init: subscribed to CarryRegistry')
end

-- TEST-ONLY seam: drop the push cache (specs assert exact push
-- behaviour per transition). Does NOT unsubscribe the
-- registry hook.
function ResetProtectionService._TestReset()
	for key in pairs(pushedProtected) do
		pushedProtected[key] = nil
	end
end

return table.freeze(ResetProtectionService)
