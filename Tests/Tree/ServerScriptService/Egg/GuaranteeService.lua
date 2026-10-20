--!strict
--!native
--[[
	Egg.GuaranteeService
	====================
	Server-side spawn-rarity guarantee state, layered ON TOP of
	the restored 7235158 Egg system. This module never spawns,
	moves, destroys, or otherwise touches eggs: it only answers
	"is a rarity due?" and remembers "when did each rarity last
	appear?". The existing automatic spawn loop consults it when
	choosing a rarity and reports back what actually spawned.

	Flow:
	  automatic spawn tick
	    ↓
	  PickDue() → rarity? (first due entry in EggConfig order)
	    ↓
	  YES → request that rarity | NO → normal weighted roll
	    ↓
	  SpawnService.Request (unchanged 7235158 creation, one egg)
	    ↓
	  success → NoteSpawned(rarity) → clock resets + UI pushes

	Rules:
	  * Natural and forced appearances both reset (any
	    successful automatic center spawn of the rarity).
	  * A due guarantee persists until its rarity spawns (the
	    clock never auto-resets; the UI clamps at 00:00).
	  * Overdue ties resolve in EggConfig.Guarantees array
	    order (Legendary before Mythic).
	  * Clocks are server-session scoped (os.clock); no
	    DataStores. Global to the server, never per-player.
	  * Client replication is timestamp attributes on the
	    existing EggTimer node (NextAt/Interval/Revision per
	    rarity + one shared revision). No remotes, no
	    per-second pushes: the client counts down locally from
	    the authoritative timestamp. Attributes persist, so
	    late joiners read current state automatically.
]]

local Workspace = game:GetService('Workspace')

local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local CenterPartBillboards = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.CenterPartBillboards)

local GuaranteeService = {}

-- --- Internal state --------------------------------------------

-- Last os.clock() timestamp per guaranteed rarity. Missing
-- entry = never appeared => measured from session boot.
local _last: { [string]: number } = {}
local _bootAt: number? = nil
-- Monotonic revision bumped on every state change (reset).
-- Replicated alongside the timestamps so clients can drop
-- out-of-order snapshots.
local _revision = 0
-- Warn-once flag for the Studio-authored EggTimer lookup.
local _timerWarned = false

local function _now(): number
	return os.clock()
end

local function _ensureBoot(): number
	if _bootAt == nil then
		_bootAt = _now()
		-- Publish initial timers so joiners and the UI see
		-- full intervals from boot (no reset has happened yet,
		-- so this is not a state change worth a revision bump
		-- by itself — but pushing once is what makes the
		-- attributes exist at all).
		pcall(GuaranteeService._pushAttributes)
	end
	return _bootAt :: number
end

-- Defensive parse of EggConfig.Guarantees into an ordered
-- array of { rarity, interval }. Malformed entries are
-- skipped (logged once); a malformed config degrades to "no
-- guarantees" instead of erroring the spawn loop. Never throws.
local function _entries(): { { rarity: string, interval: number } }
	local out: { { rarity: string, interval: number } } = {}
	pcall(function()
		local cfg = EggConfig.Guarantees
		if type(cfg) ~= 'table' then
			return
		end
		for _, g in ipairs(cfg) do
			if type(g) == 'table' and g.Enabled == true then
				local rarity = g.Rarity
				local interval = tonumber(g.IntervalSeconds)
				if type(rarity) == 'string' and rarity ~= '' and type(interval) == 'number' and interval >= 1 then
					out[#out + 1] = { rarity = rarity, interval = interval }
				end
			end
		end
	end)
	return out
end

local function _lastAt(rarity: string): number
	local t = _last[rarity]
	if type(t) == 'number' then
		return t
	end
	return _ensureBoot()
end

-- --- Workspace timer node ----------------------------------------

-- Resolve the Studio-authored timer node via the shared
-- CenterPartBillboards resolver (the Egg BillboardGui sibling
-- is found by its `Egg` child marker — never positionally,
-- since both CenterPart BillboardGuis share one Name).
-- Resolves to Map.CenterPart.BillboardGui.Egg (labels
-- Mythic/Legendary) with a legacy Map.EggTimer fallback.
-- Pure lookup, no creation (Studio owns the asset). Returns
-- nil when absent. Never throws.
local function _resolveTimerNode(): Instance?
	local node: Instance? = nil
	pcall(function()
		node = CenterPartBillboards.FindEggTimerNode(Workspace:FindFirstChild('Map'))
	end)
	return node
end

local function _serverNow(): number
	local t: number? = nil
	pcall(function()
		t = Workspace:GetServerTimeNow()
	end)
	if type(t) == 'number' then
		return t
	end
	return os.time()
end

-- Push NextAt/Interval/Revision attributes per guarantee entry
-- so clients count down locally from an authoritative
-- timestamp. Called on boot and on every reset (the reset is
-- visible immediately). Missing Studio asset degrades to a
-- one-shot warn, never an error. Never throws.
function GuaranteeService._pushAttributes()
	pcall(function()
		local node = _resolveTimerNode()
		if node == nil then
			if not _timerWarned then
				_timerWarned = true
				Debug.Warn(
					'EG',
					'Guarantee timer UI missing (expected Map.CenterPart.BillboardGui.Egg or legacy Map.EggTimer); timer attributes skipped',
					{}
				)
			end
			return
		end
		local target: Instance = node :: Instance
		for _, row in ipairs(GuaranteeService.GetState()) do
			target:SetAttribute('Guarantee_' .. tostring(row.Rarity) .. '_NextAt', row.NextAt)
			target:SetAttribute('Guarantee_' .. tostring(row.Rarity) .. '_Interval', row.Interval)
			target:SetAttribute('Guarantee_' .. tostring(row.Rarity) .. '_Revision', row.Revision)
		end
	end)
end

-- --- Public API --------------------------------------------------

-- First due guarantee rarity in config order, or nil when
-- nothing is due. `nowOverride` is the test seam (production
-- passes nil = os.clock()). Never throws.
function GuaranteeService.PickDue(nowOverride: number?): string?
	local now = if type(nowOverride) == 'number' then nowOverride :: number else _now()
	local picked: string? = nil
	pcall(function()
		for _, entry in ipairs(_entries()) do
			if now - _lastAt(entry.rarity) >= entry.interval then
				picked = entry.rarity
				break
			end
		end
	end)
	return picked
end

-- Record that `rarity` appeared in the automatic center pool
-- (natural roll OR forced guarantee — both satisfy the
-- timer). Resets that rarity's clock, bumps the revision, and
-- pushes the timer UI immediately. Unknown/untracked rarities
-- are ignored. Never throws.
function GuaranteeService.NoteSpawned(rarity: string)
	if type(rarity) ~= 'string' or rarity == '' then
		return
	end
	pcall(function()
		local tracked = false
		for _, entry in ipairs(_entries()) do
			if entry.rarity == rarity then
				tracked = true
				break
			end
		end
		if not tracked then
			return
		end
		_last[rarity] = _now()
		_revision += 1
		GuaranteeService._pushAttributes()
	end)
end

-- Authoritative snapshot, one row per configured guarantee in
-- config order: { Rarity, Interval, Remaining (clamped >= 0),
-- NextAt (server-time timestamp the client counts down from),
-- Due, Revision }. `nowOverride` is the test seam. Never throws.
function GuaranteeService.GetState(nowOverride: number?): { any }
	local now = if type(nowOverride) == 'number' then nowOverride :: number else _now()
	local serverNow = _serverNow()
	local out: { any } = {}
	pcall(function()
		for _, entry in ipairs(_entries()) do
			local elapsed = now - _lastAt(entry.rarity)
			local remaining = math.max(0, entry.interval - elapsed)
			out[#out + 1] = {
				Rarity = entry.rarity,
				Interval = entry.interval,
				Remaining = math.floor(remaining),
				NextAt = serverNow + math.floor(remaining),
				Due = remaining <= 0,
				Revision = _revision,
			}
		end
	end)
	return out
end

-- TEST-ONLY seams: reset clocks/revision (specs drive time
-- deterministically through the nowOverride params instead).
function GuaranteeService._TestReset()
	table.clear(_last)
	_bootAt = nil
	_revision = 0
	_timerWarned = false
end

function GuaranteeService._TestSetLastSpawn(rarity: string, at: number)
	if type(rarity) == 'string' and type(at) == 'number' then
		_last[rarity] = at
	end
end

return table.freeze(GuaranteeService)
