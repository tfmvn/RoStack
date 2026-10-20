--!strict
--!native
--[[
	SlotService
	===========
	Single source of truth for slot state transitions and slot
	queries. Owns the slot-level mutex and the slot state machine
	(Empty <-> Reserved <-> Occupied).

	Phase 3 architecture: split out from BaseService so future
	features (stealing, selling, upgrades, trading) can route
	through one shared slot access surface. Both
	EggService and AnimalService call into SlotService
	for every slot transition; they do not touch BaseService's
	slot methods.

	Slot records are owned by BaseService (one record per slot
	in `base.slots[1..SlotCount]`). BaseService calls
	`SlotService.RegisterBase(base)` after building each base's
	slot table, and `SlotService.UnregisterBase(baseId)` on
	cleanup. SlotService keeps an O(1) `slotById` index for
	`_findSlotById` and the state-transition methods.

	On slot transitions that change the base's occupied count
	(`OccupySlot`, `ReleaseSlot`), SlotService calls back into
	a `BaseService` callback so the base's `_occupiedCount`
	stays in sync. This is the only cross-module hook: the slot
	record itself is mutated by SlotService in place.

	Concurrency: each slot has a per-slot mutex (`slot._mutex`).
	Transitions that touch a single slot take the slot mutex;
	multi-slot transitions (e.g. rearrange) are sequenced by
	the caller, which takes slots in id order. BaseService's
	per-base mutex (`base._mutex`) covers multi-slot
	operations like assignment; SlotService does not duplicate
	that.

	The deprecated `GetNearestValidSlotForPlayer` is kept as a
	stub that returns nil; Phase 4 removes the `_placeCallback`
	resolver that called it. `GetFreeSlot` lives here and
	resolves the user's base via the registered base-lookup
	callback. Once the Place rework lands, this lookup is
	also removed and the purchase path uses the pre-allocated
	reservation pattern from the spec.
]]

local Bases = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Validation = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)

local SlotService = {}

-- --- Internal state ----------------------------------------------

-- slotId -> slot record. Populated by RegisterBase on base
-- registration. Cleared by UnregisterBase on base cleanup.
local slotById: { [string]: any } = {}

-- baseId -> array of slot records (the same array as
-- `base.slots` in BaseService, kept here for the snapshot
-- path so SlotService can build the wire array without
-- requiring BaseService back).
local slotsByBase: { [string]: { [number]: any } } = {}
local arenaSlotsByBase: { [string]: { [number]: any } } = {}

-- baseId -> array of ARENA slot records (the same array as
-- `base.arenaSlots`). Arena records share the slotById index
-- (so _findSlotById + every state transition works on them
-- unchanged) but are deliberately EXCLUDED from slotsByBase:
-- GetFreeSlot, snapshots, and every other slotsByBase reader
-- stay normal-slot-only, which is what keeps arena animals
-- out of egg placement, steal delivery, and HUD snapshots.

-- userId -> base record. Populated by RegisterBase; cleared
-- on UnregisterBase. The lookup lets GetFreeSlot and
-- ReleaseReservedSlotForUser find the user's base without
-- requiring BaseService. BaseService.AssignBaseForPlayer +
-- BaseService.ReleaseBase + BaseService.CleanupPlayer keep
-- this in sync.
local baseByOwner: { [number]: any } = {}

-- --- Callbacks (wired by bootstrap) ----------------------------

-- On a slot transition that changes the base's occupied
-- count, SlotService calls this. The callback receives the
-- base record and the delta (+1 / -1). BaseService wires its
-- own counter update.
--
-- Stored in a local upvalue, not on `SlotService`, so the
-- `table.freeze(SlotService)` at the bottom of this file
-- doesn't make the assignment a runtime error.
local occupiedCountCallback: ((slot: any, delta: number) -> ())? = nil

function SlotService.SetOccupiedCountCallback(fn: (slot: any, delta: number) -> ())
	occupiedCountCallback = fn
end

-- Phase 2.6.2: on slot transitions that change what a slot's
-- CashCollector displays (OccupySlot, DemoteSlotToReserved,
-- ReleaseSlot — the transitions into or out of Occupied),
-- SlotService calls this after the transition completes so
-- IncomeService can republish the CashPool attribute + MoneyLabel
-- immediately (place / pickup / move / release). Transitions
-- between Empty and Reserved never change the displayed value
-- (both display '0'), so they do not call it. The callback must
-- be nil-safe on any slot shape; it receives the slot record.
local poolDisplayCallback: ((slot: any) -> ())? = nil

function SlotService.SetPoolDisplayCallback(fn: ((slot: any) -> ())?)
	poolDisplayCallback = fn
end

-- Fire the display hook if wired. Kept as one helper so each
-- transition site stays one line.
local function notifyPoolDisplay(slot: any)
	if poolDisplayCallback then
		poolDisplayCallback(slot)
	end
end

-- MAIN GAME: second display hook for the stand upgrade readout
-- (`UpgradeButton.Level` / `UpgradeButton.UpgradeAmount`,
-- owned by StandDisplayService). Fired on the same transitions
-- as the pool hook, plus RebaseSlotIds (assignment re-stamp),
-- so the readout follows place / pickup / move / release /
-- assign without any polling. Nil-safe like the pool hook.
local standDisplayCallback: ((slot: any) -> ())? = nil

function SlotService.SetStandDisplayCallback(fn: ((slot: any) -> ())?)
	standDisplayCallback = fn
end

local function notifyStandDisplay(slot: any)
	if standDisplayCallback then
		standDisplayCallback(slot)
	end
end

-- --- Init / setters --------------------------------------------

function SlotService.Init() end

-- Register a base. Idempotent: re-registering the same base
-- is a no-op. Called by BaseService.RegisterBases after each
-- base's slot table is built.
function SlotService.RegisterBase(base: any)
	if not base or not base.id or not base.slots then
		return
	end
	if slotsByBase[base.id] then
		return
	end
	slotsByBase[base.id] = base.slots
	for _, slot in pairs(base.slots) do
		slotById[slot.id] = slot
	end
	SlotService.RegisterArenaSlots(base)
end

-- Index a base's arena slot records. Separate entry point so
-- DynamicSlotService can (re)index after a mid-session arena
-- rebuild without touching the normal registration. Records
-- join slotById (transitions resolve) but never slotsByBase
-- (capacity/HUD/placement stay normal-only).
function SlotService.RegisterArenaSlots(base: any)
	if not base or not base.id then
		return
	end
	SlotService.UnregisterArenaSlots(base.id)
	if type(base.arenaSlots) ~= 'table' then
		return
	end
	arenaSlotsByBase[base.id] = base.arenaSlots
	for _, slot in pairs(base.arenaSlots) do
		if type(slot) == 'table' and type(slot.id) == 'string' then
			slotById[slot.id] = slot
		end
	end
end

-- Drop a base's arena index entries (records themselves are
-- owned by BaseService/DynamicSlotService). Drops by record
-- IDENTITY, not by current id string: assign re-stamps ids
-- before the record array is replaced, so key matching would
-- miss. Owner-namespaced ids make the value scan safe (no
-- other base's records are ever the same tables).
function SlotService.UnregisterArenaSlots(baseId: string)
	if not baseId then
		return
	end
	local slots = arenaSlotsByBase[baseId]
	if slots then
		local doomed: { [any]: boolean } = {}
		for _, slot in pairs(slots) do
			doomed[slot] = true
		end
		for id, s in pairs(slotById) do
			if doomed[s] then
				slotById[id] = nil
			end
		end
	end
	arenaSlotsByBase[baseId] = nil
end

-- Unregister a base. Called by BaseService.ReleaseBase and
-- BaseService.CleanupPlayer. Idempotent.
function SlotService.UnregisterBase(baseId: string)
	if not baseId then
		return
	end
	local slots = slotsByBase[baseId]
	if slots then
		for _, slot in pairs(slots) do
			slotById[slot.id] = nil
		end
	end
	slotsByBase[baseId] = nil
	SlotService.UnregisterArenaSlots(baseId)
	for userId, b in pairs(baseByOwner) do
		if b.id == baseId then
			baseByOwner[userId] = nil
		end
	end
	SlotService.ClearMenuWarnings()
end

-- Bind a base to an owner. Called by BaseService.AssignBaseForPlayer
-- and BaseService.AssignBaseById after the base record's
-- ownerUserId is stamped.
function SlotService.SetBaseOwner(userId: number, base: any)
	if not userId or not base then
		return
	end
	baseByOwner[userId] = base
end

-- Clear the owner binding. Called by BaseService.ReleaseBase
-- and BaseService.CleanupPlayer after the base's ownerUserId
-- is cleared.
function SlotService.ClearBaseOwner(userId: number)
	if not userId then
		return
	end
	baseByOwner[userId] = nil
end

-- Re-index slot ids after a base's slots are re-stamped (e.g.
-- on owner assignment). Called by BaseService.AssignBaseForPlayer
-- and BaseService.AssignBaseById after the per-slot re-stamp.
--
-- Stamp a slot's Studio-authored menu buttons with the slot's
-- current id (Phase 2.9). Attributes only — no instances are
-- created, renamed, or destroyed. The client menu controller
-- reads `slotId` off the pressed button to route the request;
-- the server revalidates ownership + occupancy on every request
-- regardless, so a missing/stale stamp fails safe (reject).
--
-- Placement contract, MAIN GAME shape (Studio):
-- `Stand.Slot.MenuPart.MenuGui.UpgradeButton` — the button is a
-- DIRECT child of MenuGui (no Frame intermediary). The legacy
-- shape (`MenuGui -> Frame -> UpgradeButton`) is still
-- accepted so old places keep working. Absent parts are
-- a silent no-op; a one-time Debug log per slot part names
-- the gap without spamming. Sell buttons are never stamped
-- (selling lives on the animal's Sell prompt).
--
-- NOTE: this local must stay ABOVE RebaseSlotIds (Lua resolves
-- upvalues lexically — a local declared below is invisible).
local _menuWarned: { [string]: boolean } = {}

-- Drop suppressed menu-structure warnings so the next owner
-- re-warns on real hierarchy gaps (warnings must not die with
-- the previous owner). Called from UnregisterBase.
function SlotService.ClearMenuWarnings()
	for key in pairs(_menuWarned) do
		_menuWarned[key] = nil
	end
end

local function _stampMenuSlotId(slot: any)
	if type(slot) ~= 'table' or type(slot.id) ~= 'string' then
		return
	end
	-- MAIN GAME: resolve through the stand when one is bound
	-- (exact `Stand.Slot.MenuPart.MenuGui.UpgradeButton`
	-- hierarchy via StandResolver). Otherwise fall back to the
	-- legacy recursive search under the slot part.
	local upgradeButton: Instance? = nil
	local stand = slot.stand
	if typeof(stand) == 'Instance' then
		local parts = StandResolver.GetStandParts(stand)
		upgradeButton = parts.upgradeButton
		if upgradeButton == nil then
			local key = stand:GetFullName()
			if not _menuWarned[key] then
				_menuWarned[key] = true
				warn('[SlotMenu] Missing UpgradeButton for stand ' .. key)
			end
			return
		end
	else
		local part = slot.part
		if typeof(part) ~= 'Instance' then
			return
		end
		local menuPart = part:FindFirstChild('MenuPart', true)
		if not menuPart then
			-- Phase 2.9.1 §26: never silent. Plain warn (not the
			-- gated Debug channel) so a Studio hierarchy gap is
			-- always visible in output. Once per part.
			local key = part:GetFullName()
			if not _menuWarned[key] then
				_menuWarned[key] = true
				warn('[SlotMenu] Missing SlotId for MenuPart under ' .. key)
			end
			return
		end
		local gui = menuPart:FindFirstChild('MenuGui', true)
		if not gui then
			return
		end
		-- Legacy shape nests the buttons under a Frame; the new
		-- shape parents them directly to the MenuGui. A
		-- recursive search covers both without caring.
		local foundUpgrade = gui:FindFirstChild('UpgradeButton', true)
		if foundUpgrade then
			upgradeButton = foundUpgrade
		end
		if upgradeButton == nil then
			return
		end
	end
	local stamped: { string } = {}
	if upgradeButton then
		upgradeButton:SetAttribute('slotId', slot.id)
		stamped[#stamped + 1] = 'UpgradeButton'
	end
	-- Phase 2.9.2 breadcrumb: proves which slots resolved their
	-- Studio menu (one line per slot per assignment).
	Debug.Log('SlotMenu', ('stamped slotId %s buttons %s'):format(tostring(slot.id), table.concat(stamped, ',')))
end

function SlotService.RebaseSlotIds(base: any)
	if not base or not base.slots then
		return
	end
	for _, slot in pairs(base.slots) do
		-- Drop any stale id entries that still point to
		-- this slot. New id is added by RegisterBase if
		-- the base isn't already registered; for an
		-- already-registered base, the slot.id changed
		-- and we need the index to follow.
		local stale = {}
		for id, s in pairs(slotById) do
			if s == slot and id ~= slot.id then
				stale[#stale + 1] = id
			end
		end
		for _, id in ipairs(stale) do
			slotById[id] = nil
		end
		slotById[slot.id] = slot
		-- Phase 2.9: re-stamp the slot's Studio-authored menu
		-- buttons (if any) with the new id. Assignment is the
		-- only moment slot ids change, so this keeps the
		-- client menu routing in lockstep with ownership.
		-- (_stampMenuSlotId is defined above: Lua resolves
		-- upvalues lexically.)
		_stampMenuSlotId(slot)
		notifyStandDisplay(slot)
	end
	-- Arena records re-index (same stale-drop) WITH the same
	-- menu stamping and display repaint as normal slots:
	-- arena stands are first-class slots with real menus.
	if type(base.arenaSlots) == 'table' then
		for _, slot in pairs(base.arenaSlots) do
			if type(slot) == 'table' and type(slot.id) == 'string' then
				local stale = {}
				for id, s in pairs(slotById) do
					if s == slot and id ~= slot.id then
						stale[#stale + 1] = id
					end
				end
				for _, id in ipairs(stale) do
					slotById[id] = nil
				end
				slotById[slot.id] = slot
				_stampMenuSlotId(slot)
				notifyStandDisplay(slot)
			end
		end
		arenaSlotsByBase[base.id] = base.arenaSlots
	end
end

-- --- Internal helpers ------------------------------------------

local function findSlotById(slotId: string): any?
	if not slotId then
		return nil
	end
	local slot = slotById[slotId]
	if slot and slot.id == slotId then
		return slot
	end
	-- Slow path: linear scan. Covers the case where a
	-- slot's id was re-stamped and a caller still holds
	-- the old id string. The fast path (slotById) handles
	-- every normal call. Arena stands live in a separate
	-- per-base table: scan it too so RefreshDisplays (and
	-- any future id-based caller) resolves arena slots —
	-- Arena raid deploy/restore repaints through this path.
	for _, slots in pairs(slotsByBase) do
		for _, s in pairs(slots) do
			if s.id == slotId then
				return s
			end
		end
	end
	for _, slots in pairs(arenaSlotsByBase) do
		if type(slots) == 'table' then
			for _, s in pairs(slots) do
				if type(s) == 'table' and s.id == slotId then
					return s
				end
			end
		end
	end
	Debug.Warn('SS', 'findSlotById: no slot matched', { slotId = slotId })
	return nil
end

SlotService._findSlotById = findSlotById

-- Reconcile ONE slot's presentation from canonical state, right
-- now, through the same two display hooks the transition sites
-- use (pool attribute + MoneyLabel, stand upgrade readout).
-- Slot-scoped: only this slot's GUI is touched, never a
-- sibling's. Used after multi-step transactions (steal
-- completion, rollback seats) whose intermediate transitions
-- fired while the runtime record was mid-mutation, so the final
-- paint must be re-derived AFTER the record is final. Nil-safe;
-- returns false when the slot id is unknown. (Placed here
-- because Lua resolves the findSlotById upvalue lexically.)
function SlotService.RefreshDisplays(slotId: string): boolean
	if type(slotId) ~= 'string' or slotId == '' then
		return false
	end
	local slot = findSlotById(slotId)
	if not slot then
		return false
	end
	notifyPoolDisplay(slot)
	notifyStandDisplay(slot)
	return true
end

-- --- Read API --------------------------------------------------

function SlotService.GetFreeSlot(userId: number): any?
	Debug.Log('SS', '> GetFreeSlot', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	local base = baseByOwner[userId]
	if not base then
		Debug.Log('SS', 'GetFreeSlot: no base for user, returning nil')
		return nil
	end
	local scanned = 0
	for _, slot in pairs(base.slots) do
		scanned = scanned + 1
		if slot.state == SlotType.State.Empty and not slot._mutex then
			Debug.Log('SS', 'GetFreeSlot: returning slot', { slotId = slot.id, scanned = tostring(scanned) })
			return slot
		end
	end
	Debug.Log('SS', 'GetFreeSlot: no free slot', { scanned = tostring(scanned) })
	return nil
end

function SlotService.FindSlotByOccupant(occupantId: string): (any?, any?)
	Validation.ShortString(occupantId)
	for _, slots in pairs(slotsByBase) do
		for _, slot in pairs(slots) do
			if slot.occupantId == occupantId then
				return slot, nil
			end
		end
	end
	-- Arena occupants must resolve too (recovery paths find
	-- carried-from-arena animals through this index).
	for _, slots in pairs(arenaSlotsByBase) do
		for _, slot in pairs(slots) do
			if slot.occupantId == occupantId then
				return slot, nil
			end
		end
	end
	return nil, nil
end

-- Deprecated. Kept as a stub so the existing `_placeCallback`
-- resolver still compiles; returns nil. Phase 4 removes
-- `_placeCallback` and this method.
function SlotService.GetNearestValidSlotForPlayer(_userId: number, _playerPos: Vector3): any?
	Debug.Log('SS', 'GetNearestValidSlotForPlayer: deprecated, returning nil')
	return nil
end

-- --- Write API: state transitions ------------------------------

function SlotService.ReserveSlot(slotId: string): boolean
	Debug.Log('SS', '> ReserveSlot', { slotId = slotId })
	Validation.SlotId(slotId)
	local slot = findSlotById(slotId)
	if not slot then
		Debug.Log('SS', 'ReserveSlot: slot not found')
		return false
	end
	if slot._mutex then
		Debug.Log('SS', 'ReserveSlot: slot mutex held')
		return false
	end
	if slot.state == SlotType.State.Reserved then
		-- Already reserved (e.g. by the carry Demote on the
		-- source slot, or by the place-to-original path).
		-- No-op success.
		Debug.Log('SS', 'ReserveSlot: already Reserved, no-op')
		return true
	end
	if slot.state ~= SlotType.State.Empty then
		Debug.Log('SS', 'ReserveSlot: slot not Empty', { state = tostring(slot.state) })
		return false
	end
	slot._mutex = true
	slot.state = SlotType.State.Reserved
	slot._mutex = false
	Debug.Log('SS', 'ReserveSlot: ok')
	return true
end

function SlotService.DemoteSlotToReserved(slotId: string): boolean
	Debug.Log('SS', '> DemoteSlotToReserved', { slotId = slotId })
	Validation.SlotId(slotId)
	local slot = findSlotById(slotId)
	if not slot then
		Debug.Log('SS', 'DemoteSlotToReserved: slot not found')
		return false
	end
	if slot.state ~= SlotType.State.Occupied then
		Debug.Log('SS', 'DemoteSlotToReserved: slot not Occupied', { state = tostring(slot.state) })
		return false
	end
	if slot._mutex then
		Debug.Log('SS', 'DemoteSlotToReserved: slot mutex held')
		return false
	end
	slot._mutex = true
	slot.state = SlotType.State.Reserved
	-- occupantId + occupantKind are kept on the slot during
	-- the Reserved state so recovery / inspection paths know
	-- what was on the slot before the carry.
	slot._mutex = false
	notifyPoolDisplay(slot)
	notifyStandDisplay(slot)
	Debug.Log('SS', 'DemoteSlotToReserved: ok')
	return true
end

function SlotService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean
	Debug.Log('SS', '> OccupySlot', { slotId = slotId, occupantId = occupantId, occupantKind = tostring(occupantKind) })
	Validation.SlotId(slotId)
	Validation.ShortString(occupantId)
	if occupantKind ~= nil then
		Validation.t.string(occupantKind)
	end
	local slot = findSlotById(slotId)
	if not slot then
		Debug.Log('SS', 'OccupySlot: slot not found')
		return false
	end
	if slot.state ~= SlotType.State.Reserved then
		Debug.Log('SS', 'OccupySlot: slot not Reserved', { state = tostring(slot.state) })
		return false
	end
	if slot._mutex then
		Debug.Log('SS', 'OccupySlot: slot mutex held')
		return false
	end
	slot._mutex = true
	slot.state = SlotType.State.Occupied
	slot.occupantId = occupantId
	slot.occupantKind = occupantKind
	if occupiedCountCallback then
		occupiedCountCallback(slot, 1)
	end
	slot._mutex = false
	notifyPoolDisplay(slot)
	notifyStandDisplay(slot)
	Debug.Log('SS', 'OccupySlot: ok')
	return true
end

function SlotService.ReleaseSlot(slotId: string): boolean
	Validation.SlotId(slotId)
	local slot = findSlotById(slotId)
	if not slot then
		return false
	end
	if slot._mutex then
		return false
	end
	if slot.state == SlotType.State.Empty then
		-- Already empty; idempotent no-op.
		return true
	end
	slot._mutex = true
	local wasOccupied = slot.state == SlotType.State.Occupied
	-- A Reserved slot still names its occupant (Demote keeps
	-- occupantId/occupantKind for recovery). Releasing one —
	-- e.g. the steal source on delivery — clears that name, so
	-- the slot's presentation must reconcile too, not just the
	-- Occupied -> Empty path.
	local hadOccupant = slot.occupantId ~= nil
	slot.state = SlotType.State.Empty
	slot.occupantId = nil
	slot.occupantKind = nil
	slot._mutex = false
	if wasOccupied or hadOccupant then
		notifyPoolDisplay(slot)
		notifyStandDisplay(slot)
		if occupiedCountCallback then
			occupiedCountCallback(slot, -1)
		end
	end
	return true
end

function SlotService.ReleaseReservedSlotForUser(userId: number, index: number): boolean
	Validation.PositiveInteger(userId)
	Validation.PositiveInteger(index)
	local base = baseByOwner[userId]
	if not base then
		return false
	end
	local slot = base.slots[index]
	if not slot then
		return false
	end
	if slot.state ~= SlotType.State.Reserved then
		return false
	end
	slot.state = SlotType.State.Empty
	slot.occupantId = nil
	slot.occupantKind = nil
	return true
end

-- --- Snapshot --------------------------------------------------

-- Returns the wire-shape array of slot snapshots for the
-- given base. Used by BaseService.Snapshot to build the
-- player state push. The slot array part of Snapshot moves
-- here so SlotService owns the per-slot wire shape.
-- Normal slots first (indices 1..SlotCount — every existing
-- client indexes these numerically and is unaffected), then
-- arena slots appended in arenaIndex order with Arena = true
-- (menu visibility + direct-upgrade targeting resolve them;
-- HUD row loops ignore the tail).
function SlotService.SnapshotBaseSlots(base: any): { [number]: any }?
	if not base or not base.slots then
		return nil
	end
	local out: { [number]: any } = {}
	for i = 1, Bases.Slots.Count do
		local s = base.slots[i]
		-- Dynamic bases may hold fewer slots than SlotCount
		-- (rebirth progression, marker gaps, unassigned
		-- bases): skip absent indices instead of indexing nil.
		if s == nil then
			continue
		end
		local pos = s.part and s.part.Position or nil
		out[i] = {
			Index = i,
			Id = s.id,
			State = s.state,
			OccupantId = s.occupantId,
			OccupantKind = s.occupantKind,
			Position = pos,
		}
	end
	if type(base.arenaSlots) == 'table' then
		local ordered: { any } = {}
		for _, s in pairs(base.arenaSlots) do
			if type(s) == 'table' then
				ordered[#ordered + 1] = s
			end
		end
		table.sort(ordered, function(a: any, b: any)
			local ai = (type(a.arenaIndex) == 'number' and a.arenaIndex) or (a.index or 0)
			local bi = (type(b.arenaIndex) == 'number' and b.arenaIndex) or (b.index or 0)
			return ai < bi
		end)
		for _, s in ipairs(ordered) do
			local pos = nil
			pcall(function()
				pos = s.part and s.part.Position or nil
			end)
			out[#out + 1] = {
				Index = s.index,
				Id = s.id,
				State = s.state,
				OccupantId = s.occupantId,
				OccupantKind = s.occupantKind,
				Position = pos,
				Arena = true,
			}
		end
	end
	return out
end

-- Test-only / debug helper: dump the slotById table.
function SlotService._dump(): { [string]: any }
	return slotById
end

return table.freeze(SlotService)
