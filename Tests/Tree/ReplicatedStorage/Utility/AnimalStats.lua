--!strict
--[[
	AnimalStats
	=============
	Phase 2.5 — the ONE authoritative Animal stat layer. Resolves

	    Animal
	      -> definition (AnimalConfig catalog, via DefId)
	      -> rarity (the catalog bucket the def lives in)
	      -> stat configuration (AnimalConfig.Stats[rarity])
	      -> Level points (LevelConfig.GetPointsForLevel, P(L) = q(L-1))
	      -> StatCalculator (universal logarithmic formula)
	      -> final Health / Income (per second), Damage = Health / 10

	StatCalculator stays generic: it knows nothing about animals,
	rarity or definitions, and this module adds no math of its own —
	it only resolves inputs and delegates. Nothing else may apply
	AnimalConfig.Stats parameters.

	DERIVED, NOT PERSISTED (spec: Level is the source of truth):
	Health/Damage are recomputed from Level + definition + config on
	every call — after server startup, rejoin, load, slot
	rearrangement, creation and level-up alike. No cached stat field
	exists on the runtime record, so a level change can never leave
	a stale stat behind and there is no cache to invalidate. A call
	is two table lookups plus two math.log calls — safe to run on
	every push.

	FAIL-SAFE CONTRACT (missing/invalid data):
	  * Unknown/missing DefId            -> warn once, return 0.
	  * Rarity with no config row        -> warn once, return 0.
	  * Malformed Level (nil/"10"/0/NaN/ -> repaired through
	    inf/fractional/> MaxLevel)          LevelConfig.Normalize —
	                                        no second normalization.
	  * Unknown statName / non-table     -> throws (programming
	    animal                            error, fail loudly).
	Never returns NaN/Infinity/negative for data problems and never
	crashes the server on malformed persistence state.
]]

local AnimalConfig = require(script.Parent.Parent.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.Config.Creatures.Progression)
local StatCalculator = require(script.Parent.StatCalculator)
local Debug = require(script.Parent.Debug)
-- Phase 2.11: intrinsic trait/mutation generation multipliers
-- (Income ONLY — Health/Damage are pure level scaling). The
-- folds live in the shared configs (same functions the server
-- services call), so this shared module stays free of
-- server-only requires.
local TraitConfig = require(script.Parent.Parent.Config.Creatures.Traits)
local MutationConfig = require(script.Parent.Parent.Config.Creatures.Mutations)

local AnimalStats = {}

-- The stats this layer supports. Phase 2.5 added Health + Damage;
-- Phase 2.6 adds Income (per-second, consumed by IncomeService —
-- the rate itself is derived, never persisted).
local SUPPORTED_STATS = { Health = true, Damage = true, Income = true }

-- Human-readable stat list for error messages.
local SUPPORTED_LIST = '"Health", "Damage" or "Income"'

-- Warn-once set: a broken def/config warns on the first encounter,
-- not on every push that reads it.
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string, data: { [string]: any }?)
	if warned[key] then
		return
	end
	warned[key] = true
	Debug.Warn('AN', message, data)
end

-- Direct config access for tools/tests. Throws on an unsupported
-- statName (programming error); returns nil for a rarity without a
-- config row (data problem — callers fail safe).
function AnimalStats.GetStatConfig(rarity: any, statName: string): any?
	if type(statName) ~= 'string' or not SUPPORTED_STATS[statName] then
		error('[AnimalStats] statName must be ' .. SUPPORTED_LIST, 0)
	end
	local perRarity = AnimalConfig.Stats[statName]
	return perRarity and perRarity[rarity] or nil
end

-- Calculate one derived stat for an animal-like table.
--
-- `animal` accepts either representation of the canonical state:
-- a runtime record (`definitionId`, AnimalService) or a persisted
-- row (`DefId`, PlayerService profile data). Both carry `Level`.
--
-- 10:1 COMBAT INVARIANT: Damage is ALWAYS exactly Health / 10,
-- derived from the same scaled Health result — never from
-- independent Damage parameters. Independent per-stat rows
-- cannot hold a ratio across a nonlinear curve (that drift is
-- what produced observations like ~400 HP with ~312 Damage),
-- so Damage short-circuits to the Health computation. The
-- logarithmic curve, boundaries, fail-safes, and precision
-- behavior below therefore apply to Damage identically.
--
-- Returns the value with full precision. BOUNDARY POLICY: Level 1
-- returns Base exactly (StatCalculator's G(0) fast path) and
-- MaxLevel returns Maximum exactly (fast path here) — the spec's
-- hard "never exceeds Maximum / never negative" guarantees are
-- enforced at this boundary rather than left to float dust
-- ((M-B)*ln/ln differs from M-B by up to one ulp at P = P_max).
-- Intermediate levels keep full precision and stay strictly inside
-- (Base, Maximum) — verified across every rarity row. No rounding
-- is applied anywhere; a consumer that needs an integer game-facing
-- value rounds once at its own display boundary.
function AnimalStats.Calculate(animal: any, statName: string): number
	if type(animal) ~= 'table' then
		error('[AnimalStats] animal must be a table with DefId/definitionId + Level', 0)
	end
	if type(statName) ~= 'string' or not SUPPORTED_STATS[statName] then
		error('[AnimalStats] statName must be ' .. SUPPORTED_LIST, 0)
	end

	-- 10:1 invariant enforcement point (single place in the
	-- codebase where the ratio is established): Damage IS
	-- Health / 10, bit-exact by construction. Recursion depth
	-- is exactly 1 (the Health path below has no branch).
	-- Fail-safes are preserved: unknown DefId warns once and
	-- yields 0/10 = 0 through the Health path.
	if statName == 'Damage' then
		return AnimalStats.Calculate(animal, 'Health') / 10
	end

	-- Resolve definition + rarity from the canonical catalog.
	local defId = animal.DefId or animal.definitionId
	local rarity, def = AnimalConfig.Get(defId)
	if not rarity or not def then
		warnOnce('def:' .. tostring(defId), 'AnimalStats: defId not in catalog; stat fails safe to 0', {
			defId = tostring(defId),
			statName = statName,
		})
		return 0
	end

	local cfg = AnimalStats.GetStatConfig(rarity, statName)
	if not cfg then
		warnOnce(('cfg:%s:%s'):format(tostring(rarity), statName), 'AnimalStats: no stat config for rarity', {
			rarity = tostring(rarity),
			statName = statName,
		})
		return 0
	end

	-- Canonical Level repair/normalization (no second system):
	-- Normalize(level, 0) clamps into 1..MaxLevel and never drains
	-- (0 is below every requirement), so GetPointsForLevel cannot
	-- throw and a malformed Level can never produce a bad stat.
	local level = LevelConfig.Normalize(animal.Level, 0)
	local points = LevelConfig.GetPointsForLevel(level)

	-- Boundary fast path: at (or beyond) MaxLevel the stat IS the
	-- Maximum — exact, deterministic, immune to float dust. Level 1
	-- (points == 0) falls through to StatCalculator, which returns
	-- Base exactly on its own G(0) fast path.
	local maxPoints = LevelConfig.GetMaxPoints()
	local value: number
	if points >= maxPoints then
		value = cfg.Maximum
	else
		value = StatCalculator.Calculate({
			Points = points,
			Base = cfg.Base,
			Maximum = cfg.Maximum,
			Curve = cfg.Curve,
			MaxPoints = LevelConfig.GetMaxPoints(),
		})

		-- Belt-and-braces (spec: never negative / never beyond Maximum
		-- for data problems). Unreachable with validated config and
		-- points < maxPoints, kept as explicit insurance.
		if value < 0 then
			return 0
		end
		if value > cfg.Maximum then
			return cfg.Maximum
		end
	end
	-- Phase 2.11: intrinsic trait/mutation generation, Income
	-- ONLY. The record carries Trait (string|nil) + Mutations
	-- (array, either case convention); both fold to 1x when
	-- absent, so legacy/untraited rows are byte-identical to
	-- before. Health/Damage never see these multipliers. The
	-- player MoneyMultiplier stays OUTSIDE (applied by
	-- IncomeService at the tick, never stored here).
	if statName == 'Income' then
		local trait = animal.Trait
		if trait == nil then
			trait = animal.trait
		end
		local mutations = animal.Mutations
		if mutations == nil then
			mutations = animal.mutations
		end
		local shaped = value * TraitConfig.GenerationMultiplierFor(trait) * MutationConfig.GenerationFold(mutations)
		if shaped ~= shaped or shaped == math.huge or shaped < 0 then
			return value
		end
		return shaped
	end
	return value
end

-- Both derived stats in one call — the shape the wire pushes and
-- future consumers read.
function AnimalStats.Snapshot(animal: any): { Health: number, Damage: number }
	return {
		Health = AnimalStats.Calculate(animal, 'Health'),
		Damage = AnimalStats.Calculate(animal, 'Damage'),
	}
end

return table.freeze(AnimalStats)
