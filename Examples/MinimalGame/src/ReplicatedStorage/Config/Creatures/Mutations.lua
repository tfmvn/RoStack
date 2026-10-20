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
	Mutations
	==============
	Phase 2.11 — the ONE centralized Egg / Animal
	Mutation catalog.

	Only event mutations exist (all others removed per design —
	catalog lookups, admin validation, persistence audit, and
	overhead sanitizers accept exactly these two):
	  Galactic   x3   gen   x2.5  sell  (Galaxy event)
	  Frost      x2.5 gen   x2    sell  (Snowfall event)

	An Egg carries N UNIQUE mutations (possibly zero). On
	open, ALL of them transfer to the Animal (defensive copy).
	Animals never gain/lose/reroll mutations after creation
	(no reroll/remove/upgrade UI exists in this phase).

	Placeholder values (tunable — designers edit here only):
	  Galactic   x3   gen   x2.5  sell  (Galaxy event)
	  Frost      x2.5 gen   x2    sell  (Snowfall event)

	Eligibility/RNG is owned by EventConfig + EventService —
	the catalog only prices the two event mutations (same
	folds as every other mutation system consumer).

	Multiplier representation: DECIMAL STRINGS (same rationale
	as TraitConfig — exact BigNumber sell math, float-safe
	generation path). Validated at require time.

	There is NO fixed maximum count and NO ordering significance:
	multipliers commute, and every fold sorts IDs first so
	insertion order can never change a result. Duplicates are
	invalid everywhere (rejected at the boundary, never stored).
]]

local Mutations = {}

-- --- Catalog ----------------------------------------------------------

Mutations.Catalog = {
	-- The only two mutations in the game (see header):
	-- priced like normal catalog entries so income/sell
	-- folds, admin validation, persistence audit, and
	-- overhead sanitizers accept them with zero special-casing.
	Galactic = {
		GenerationMultiplier = '3',
		SellMultiplier = '2.5',
	},
	Frost = {
		GenerationMultiplier = '2.5',
		SellMultiplier = '2',
	},
}

-- --- Validation ---------------------------------------------------------

local function _isValidMultiplier(v: any): boolean
	if type(v) ~= 'string' or #v == 0 or #v > 12 then
		return false
	end
	if not string.match(v, '^%d+%.?%d*$') then
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
	if type(Mutations.Catalog) ~= 'table' then
		error('[Mutations] Catalog table missing', 0)
	end
	local count = 0
	for id, entry in pairs(Mutations.Catalog) do
		count += 1
		if type(id) ~= 'string' or id == '' then
			error('[Mutations] mutation ids must be non-empty strings', 0)
		end
		if type(entry) ~= 'table' then
			error(('[Mutations] %s entry must be a table'):format(id), 0)
		end
		if not _isValidMultiplier(entry.GenerationMultiplier) then
			error(('[Mutations] %s.GenerationMultiplier must be a positive decimal string'):format(id), 0)
		end
		if not _isValidMultiplier(entry.SellMultiplier) then
			error(('[Mutations] %s.SellMultiplier must be a positive decimal string'):format(id), 0)
		end
	end
	if count == 0 then
		error('[Mutations] Catalog must not be empty', 0)
	end
end

-- --- Reads ---------------------------------------------------------------

-- Canonical definition or nil (unknown id is data, not a crash).
function Mutations.Get(mutationId: string): any?
	if type(mutationId) ~= 'string' then
		return nil
	end
	return Mutations.Catalog[mutationId]
end

-- --- Pure list + multiplier folds (shared) ----------------------------------
--
-- THE single definition of mutation list/multiplier resolution.
-- Server MutationService, persistence audit, and shared
-- consumers (AnimalStats income) all call these — the formula
-- (multiplicative over sorted unique ids, empty = identity)
-- exists exactly once.
local BigNumber = require(script.Parent.Parent.Parent.Utility.BigNumber)
local Debug = require(script.Parent.Parent.Parent.Utility.Debug)

local _warnedUnknown: { [string]: boolean } = {}

local function _warnUnknown(id: string, path: string)
	if not _warnedUnknown[id] then
		_warnedUnknown[id] = true
		Debug.Warn('MU', 'unknown mutation in ' .. path .. ' fold; skipping', { mutation = id })
	end
end

-- Canonicalize any mutation-list-shaped value: FRESH sorted array
-- of unique valid ids. Non-tables -> {} (a missing field on a
-- legacy record is normal, not an error).
function Mutations.SanitizeIds(list: any): { string }
	local out: { string } = {}
	if type(list) ~= 'table' then
		return out
	end
	local seen: { [string]: boolean } = {}
	for _, id in ipairs(list) do
		if type(id) == 'string' and id ~= '' and not seen[id] and Mutations.Get(id) ~= nil then
			seen[id] = true
			out[#out + 1] = id
		end
	end
	table.sort(out)
	return out
end

-- Multiplicative generation fold (float; empty = 1).
function Mutations.GenerationFold(list: any): number
	local ids = Mutations.SanitizeIds(list)
	local result = 1
	for _, id in ipairs(ids) do
		local entry = Mutations.Get(id)
		local n = entry and tonumber(entry.GenerationMultiplier)
		if not n or n ~= n or n == math.huge or n <= 0 then
			_warnUnknown(id, 'generation')
		else
			result *= n
		end
	end
	if result ~= result or result == math.huge or result <= 0 then
		return 1
	end
	return result
end

-- Multiplicative sell fold (EXACT BigNumber decimals; empty =
-- '1'). Chained MultiplyDecimal calls stay exact: every config
-- multiplier is a validated terminating decimal.
function Mutations.SellFold(list: any): string
	local ids = Mutations.SanitizeIds(list)
	local result = '1'
	for _, id in ipairs(ids) do
		local entry = Mutations.Get(id)
		local mult = entry and entry.SellMultiplier
		if type(mult) ~= 'string' then
			_warnUnknown(id, 'sell')
		else
			local ok, folded = pcall(BigNumber.MultiplyDecimal, result, mult)
			if not ok or type(folded) ~= 'string' then
				_warnUnknown(id, 'sell')
			else
				result = folded
			end
		end
	end
	return result
end

validate()
table.freeze(Mutations.Catalog)

return table.freeze(Mutations)
