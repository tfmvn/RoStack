--!strict
--!native
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Traits
	===========
	Phase 2.11 — the ONE centralized Animal Trait catalog.

	An Animal has EXACTLY zero or one Trait (nil = none). Traits
	are rolled at Egg open time (or forced 100% by a
	hidden preassigned egg Trait) and NEVER change after.

	Placeholder values (tunable — designers edit here only):
	  Gold     10%   x3 gen   x3 sell
	  Diamond   4%   x5 gen   x5 sell
	  Rainbow   1%  x10 gen  x10 sell
	  None     rest   x1       x1 (implicit, never persisted)

	Multiplier representation: DECIMAL STRINGS ('2', '1.5'), not
	Lua numbers. Currency math (sell) must be exact — float dust
	('1.1000000000000001') would corrupt BigNumber strings. The
	generation path converts with tonumber (rates are floats
	already); the sell path folds exact decimal strings. Every
	value is validated at require time: positive, finite,
	terminating decimal, sane magnitude.

	Chance representation: percent NUMBERS (0-100). Floats are
	fine here — chances only partition a roll, never touch
	currency. Total must not exceed 100; the remainder is None.

	No-trait is ALWAYS nil, never the string 'None'. No code may
	persist, display (player-facing), or roll a 'None' trait.
]]

local Traits = {}

-- --- Catalog ----------------------------------------------------------

-- SellMultiplier is deliberately MODEST next to the income
-- (Generation) multiplier: traits are keeper value (income),
-- not flip value. A 10x Rainbow still doubles the sale, but
-- flip EV math (hatch-and-sell recovery) assumes trait sell
-- EV ≈ 1.05 — see the economy balance report. Do NOT raise
-- these without re-verifying every egg's hatch-and-sell EV.
Traits.Catalog = {
	Gold = {
		Chance = 10,
		GenerationMultiplier = '3',
		SellMultiplier = '1.2',
	},
	Diamond = {
		Chance = 4,
		GenerationMultiplier = '5',
		SellMultiplier = '1.5',
	},
	Rainbow = {
		Chance = 1,
		GenerationMultiplier = '10',
		SellMultiplier = '2',
	},
}

-- Deterministic roll order. NEVER iterate the catalog with pairs
-- for the roll — table order must not affect probabilities.
Traits.RollOrder = { 'Gold', 'Diamond', 'Rainbow' }

-- --- Validation ---------------------------------------------------------

-- A multiplier string must be a positive terminating decimal the
-- exact-math path can fold: digits with at most one dot, value
-- in (0, 1e6], at most 6 significant digits (keeps BigNumber
-- integer multis in range).
local function _isValidMultiplier(v: any): boolean
	if type(v) ~= 'string' or #v == 0 or #v > 12 then
		return false
	end
	if not string.match(v, '^%d+%.?%d*$') then
		return false
	end
	if string.match(v, '%.%.') then
		return false
	end
	local n = tonumber(v)
	if not n or n ~= n or n == math.huge or n == -math.huge or n <= 0 or n > 1_000_000 then
		return false
	end
	local digits = string.gsub(v, '%.', '')
	digits = string.gsub(digits, '^0+', '')
	if #digits == 0 then
		return false
	end
	if #digits > 6 then
		return false
	end
	return true
end

local function validate()
	if type(Traits.Catalog) ~= 'table' then
		error('[Traits] Catalog table missing', 0)
	end
	if type(Traits.RollOrder) ~= 'table' or #Traits.RollOrder == 0 then
		error('[Traits] RollOrder must be a non-empty array', 0)
	end
	local seen: { [string]: boolean } = {}
	local totalChance = 0
	for _, id in ipairs(Traits.RollOrder) do
		if type(id) ~= 'string' or id == '' then
			error('[Traits] RollOrder entries must be non-empty strings', 0)
		end
		if seen[id] then
			error(('[Traits] RollOrder duplicates trait %s'):format(id), 0)
		end
		seen[id] = true
		local entry = Traits.Catalog[id]
		if type(entry) ~= 'table' then
			error(('[Traits] RollOrder references unknown trait %s'):format(id), 0)
		end
		if type(entry.Chance) ~= 'number' or entry.Chance ~= entry.Chance or entry.Chance < 0 or entry.Chance > 100 then
			error(('[Traits] %s.Chance must be a number in 0..100'):format(id), 0)
		end
		totalChance += entry.Chance
		if not _isValidMultiplier(entry.GenerationMultiplier) then
			error(('[Traits] %s.GenerationMultiplier must be a positive decimal string'):format(id), 0)
		end
		if not _isValidMultiplier(entry.SellMultiplier) then
			error(('[Traits] %s.SellMultiplier must be a positive decimal string'):format(id), 0)
		end
	end
	-- Every catalog entry must be reachable from the roll order —
	-- unreachable entries are dead config (typo bait).
	for id in pairs(Traits.Catalog) do
		if not seen[id] then
			error(('[Traits] catalog entry %s missing from RollOrder'):format(tostring(id)), 0)
		end
	end
	if totalChance > 100 then
		error(('[Traits] total Chance %s exceeds 100'):format(tostring(totalChance)), 0)
	end
end

-- --- Reads ---------------------------------------------------------------

-- Canonical definition or nil (unknown id is data, not a crash).
function Traits.Get(traitId: string): any?
	if type(traitId) ~= 'string' then
		return nil
	end
	return Traits.Catalog[traitId]
end

-- --- Pure multiplier folds (shared) ---------------------------------------
--
-- THE single definition of trait multiplier resolution. Both the
-- server TraitService and shared consumers (AnimalStats income)
-- call these — never reimplement the nil/unknown policy
-- elsewhere. Nil (no trait) -> identity; unknown id -> identity
-- with a loud warn-once (records are audit-cleaned, so unknown
-- means a bug worth hearing about, not a crash).
local Debug = require(script.Parent.Parent.Parent.Utility.Debug)

local _warnedUnknown: { [string]: boolean } = {}

-- Float multiplier for generation math (rates are floats; the
-- income accumulator owns the single flooring boundary).
function Traits.GenerationMultiplierFor(traitId: string?): number
	if traitId == nil then
		return 1
	end
	local entry = Traits.Get(traitId)
	local n = entry and tonumber(entry.GenerationMultiplier)
	if not n or n ~= n or n == math.huge or n <= 0 then
		if type(traitId) == 'string' and not _warnedUnknown[traitId] then
			_warnedUnknown[traitId] = true
			Debug.Warn('TR', 'unknown trait in generation fold; degrading to 1x', { trait = tostring(traitId) })
		end
		return 1
	end
	return n
end

-- Exact decimal-string multiplier for BigNumber sell math.
function Traits.SellMultiplierFor(traitId: string?): string
	if traitId == nil then
		return '1'
	end
	local entry = Traits.Get(traitId)
	if not entry or type(entry.SellMultiplier) ~= 'string' then
		if type(traitId) == 'string' and not _warnedUnknown[traitId] then
			_warnedUnknown[traitId] = true
			Debug.Warn('TR', 'unknown trait in sell fold; degrading to 1x', { trait = tostring(traitId) })
		end
		return '1'
	end
	return entry.SellMultiplier
end

validate()
table.freeze(Traits.Catalog)

return table.freeze(Traits)
