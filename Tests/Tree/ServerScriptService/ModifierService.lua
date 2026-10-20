--!strict
--!native
--[[
	ModifierService
	===============
	Phase 2.7 — the ONE authoritative place for modifier resolution.

	Owns the calculation of, per player:
	  * MoneyMultiplier (applies ONLY to ONLINE income generation)
	  * XPModifier      (applies EXACTLY ONCE in the canonical XP flow)

	Both default to 1x when no modifier sources are active.

	Server-authoritative end to end: this module lives on the server,
	is never required by the client, and exposes no remote that sets
	values. Clients can only READ resolved values through the
	display-only debug snapshot (DebugService, admin-gated).

	Modifier sources (future: rebirth, gamepasses, upgrades, events,
	boosts, mutations, buffs — NOT implemented here, infrastructure
	only):
	  {
	      SourceId = 'ExampleSource',   -- explicit identity
	      Type = 'MoneyMultiplier',     -- one of ModifierType
	      Value = 2,                    -- finite number > 0
	      Operation = 'Multiply',       -- deterministic op (only one today)
	      Metadata = {...}?,            -- optional, opaque
	  }

	Stacking rule (deterministic, order-independent):
	  * Every source is multiplicative: final = 1 x v1 x v2 x ... x vn.
	  * SourceIds are sorted before folding, so insertion order can
	    never change the result.
	  * No sources -> exactly 1.
	  * Only 'Multiply' exists today; any other operation string is
	    rejected at the Add boundary so a future op is a deliberate,
	    tested addition — never a silent behavior change.

	Application points (the ONLY readers — never scatter more):
	  * IncomeService._tickPlayer reads GetMoneyMultiplier ONCE per
	    player per tick and folds it into newly generated income.
	    Offline earnings, collection, and settlement NEVER read it.
	  * AnimalService.AddXP reads GetXPModifier ONCE per grant and
	    applies it EXACTLY ONCE before LevelConfig.Normalize.

	Derived values are NEVER persisted. A future persistent source
	(e.g. a permanent rebirth bonus) persists the SOURCE, and this
	service re-resolves the multiplier from sources on every read.
	No current source needs persistence, so nothing here writes to
	the profile.

	Concurrency: Luau runs each call synchronously with no yields
	between read-modify-write, so Add/Remove/Resolve serialize on
	the VM. Same model as EconomyService.
]]

local ModifierService = {}

local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)

-- --- Types & operations -------------------------------------------

ModifierService.ModifierType = {
	MoneyMultiplier = 'MoneyMultiplier',
	XPModifier = 'XPModifier',
}

ModifierService.Operation = {
	Multiply = 'Multiply',
}

export type ModifierSource = {
	SourceId: string,
	Type: string,
	Value: number,
	Operation: string,
	Metadata: any?,
}

-- Defensive upper bound for a single source value. Modifiers are
-- small gameplay numbers (1.5x, 2x); anything astronomically large
-- is a bug or grief attempt, not game design. Rejected loudly at
-- the boundary rather than allowed to poison income/XP math.
local MAX_SOURCE_VALUE = 1_000_000

-- --- Internal state ------------------------------------------------

-- userId -> modifierType -> sourceId -> source.
local _sources: { [number]: { [string]: { [string]: ModifierSource } } } = {}

-- --- Validation ----------------------------------------------------

local function _isValidUserId(userId: any): boolean
	if not Validation.IsValidPlayerUserId(userId) then
		return false
	end
	return userId == userId and userId ~= math.huge and userId ~= -math.huge
end

local function _isValidSourceId(sourceId: any): boolean
	return type(sourceId) == 'string' and #sourceId > 0 and #sourceId <= 64
end

local function _isKnownType(modifierType: any): boolean
	return modifierType == ModifierService.ModifierType.MoneyMultiplier
		or modifierType == ModifierService.ModifierType.XPModifier
end

local function _isValidValue(value: any): boolean
	return type(value) == 'number'
		and value == value -- not NaN
		and value ~= math.huge
		and value ~= -math.huge
		and value > 0
		and value <= MAX_SOURCE_VALUE
end

-- --- Lifecycle -----------------------------------------------------

function ModifierService.Init()
	-- No-op: all state is per-player and created on first Add.
end

-- Drop every source for a player. Called by bootstrap on leave so
-- session-scoped sources can never leak into a future session, and
-- used by specs for isolation.
function ModifierService.ForgetPlayer(userId: number)
	if not _isValidUserId(userId) then
		return
	end
	_sources[userId] = nil
end

ModifierService.ClearModifiers = ModifierService.ForgetPlayer

-- --- Mutations (server only — no remote ever calls these) ----------

-- Add (or replace) one modifier source for a player. Re-adding the
-- same (userId, type, sourceId) REPLACES the previous source — the
-- triple is the identity, so a source can never double-count itself.
-- Returns (true) on success, (false, code) on rejection.
function ModifierService.AddModifier(
	userId: number,
	sourceId: string,
	modifierType: string,
	value: number,
	operation: string?,
	metadata: any?
): (boolean, string?)
	if not _isValidUserId(userId) then
		return false, 'invalid-player'
	end
	if not _isValidSourceId(sourceId) then
		return false, 'invalid-source'
	end
	if not _isKnownType(modifierType) then
		return false, 'invalid-type'
	end
	if not _isValidValue(value) then
		return false, 'invalid-value'
	end
	local op = operation or ModifierService.Operation.Multiply
	if op ~= ModifierService.Operation.Multiply then
		return false, 'unsupported-operation'
	end
	if metadata ~= nil and type(metadata) ~= 'table' then
		return false, 'invalid-metadata'
	end
	local byType = _sources[userId]
	if not byType then
		byType = {}
		_sources[userId] = byType
	end
	local bySource = byType[modifierType]
	if not bySource then
		bySource = {}
		byType[modifierType] = bySource
	end
	bySource[sourceId] = {
		SourceId = sourceId,
		Type = modifierType,
		Value = value,
		Operation = op,
		Metadata = metadata,
	}
	return true
end

-- Remove one source. With modifierType nil, removes sourceId from
-- ALL types. Returns true iff anything was removed.
function ModifierService.RemoveModifier(userId: number, sourceId: string, modifierType: string?): boolean
	if not _isValidUserId(userId) then
		return false
	end
	if not _isValidSourceId(sourceId) then
		return false
	end
	local byType = _sources[userId]
	if not byType then
		return false
	end
	if modifierType ~= nil then
		if not _isKnownType(modifierType) then
			return false
		end
		local bySource = byType[modifierType]
		if not bySource or bySource[sourceId] == nil then
			return false
		end
		bySource[sourceId] = nil
		return true
	end
	local removed = false
	for _, bySource in pairs(byType) do
		if bySource[sourceId] ~= nil then
			bySource[sourceId] = nil
			removed = true
		end
	end
	return removed
end

-- --- Reads ----------------------------------------------------------

-- Active sources for a player (+ optional type filter), sorted by
-- SourceId so enumeration order is deterministic. Returns COPIES —
-- callers can never mutate authoritative state through this.
function ModifierService.GetModifiers(userId: number, modifierType: string?): { ModifierSource }
	local out: { ModifierSource } = {}
	if not _isValidUserId(userId) then
		return out
	end
	local byType = _sources[userId]
	if not byType then
		return out
	end
	local function collect(list: { [string]: ModifierSource })
		for _, source in pairs(list) do
			out[#out + 1] = {
				SourceId = source.SourceId,
				Type = source.Type,
				Value = source.Value,
				Operation = source.Operation,
				Metadata = source.Metadata,
			}
		end
	end
	if modifierType ~= nil then
		if not _isKnownType(modifierType) then
			return out
		end
		local bySource = byType[modifierType]
		if bySource then
			collect(bySource)
		end
	else
		for _, bySource in pairs(byType) do
			collect(bySource)
		end
	end
	table.sort(out, function(a, b)
		if a.Type == b.Type then
			return a.SourceId < b.SourceId
		end
		return a.Type < b.Type
	end)
	return out
end

-- Resolve one modifier type to its final multiplier. Deterministic:
-- sourceIds sorted, values folded multiplicatively from base 1.
-- Never throws, never returns NaN/inf — untrusted state degrades
-- to 1x rather than poisoning income/XP math.
local function _resolve(userId: number, modifierType: string): number
	if not _isValidUserId(userId) then
		return 1
	end
	local byType = _sources[userId]
	local bySource = byType and byType[modifierType]
	if not bySource then
		return 1
	end
	local ids: { string } = {}
	for sourceId in pairs(bySource) do
		ids[#ids + 1] = sourceId
	end
	if #ids == 0 then
		return 1
	end
	table.sort(ids)
	local result = 1
	for _, sourceId in ipairs(ids) do
		local source = bySource[sourceId]
		local v = source and source.Value
		-- Defensive: state was validated at Add, but never trust
		-- stored state blindly — a poisoned entry degrades to a
		-- skip, not a NaN cascade.
		if _isValidValue(v) and source.Operation == ModifierService.Operation.Multiply then
			result *= v
			if result ~= result or result == math.huge or result <= 0 then
				return 1
			end
		end
	end
	return result
end

-- Player Money multiplier. 1x when no sources are active.
-- THE value IncomeService folds into newly generated online income.
function ModifierService.GetMoneyMultiplier(userId: number): number
	return _resolve(userId, ModifierService.ModifierType.MoneyMultiplier)
end

-- Player XP modifier. 1x when no sources are active.
-- THE value AnimalService folds into a grant exactly once.
function ModifierService.GetXPModifier(userId: number): number
	return _resolve(userId, ModifierService.ModifierType.XPModifier)
end

-- Both resolved values + their sorted sources in one call — the
-- shape the debug snapshot reads so the HUD shows the number AND
-- the sources it came from without a second resolution.
function ModifierService.GetResolvedModifiers(userId: number): {
	MoneyMultiplier: number,
	XPModifier: number,
	MoneySources: { ModifierSource },
	XPSources: { ModifierSource },
}
	return {
		MoneyMultiplier = ModifierService.GetMoneyMultiplier(userId),
		XPModifier = ModifierService.GetXPModifier(userId),
		MoneySources = ModifierService.GetModifiers(userId, ModifierService.ModifierType.MoneyMultiplier),
		XPSources = ModifierService.GetModifiers(userId, ModifierService.ModifierType.XPModifier),
	}
end

return table.freeze(ModifierService)
