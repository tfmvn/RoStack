--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Animals
	==============
	The full Animal catalog. Every animal a player can obtain
	lives here as a static `AnimalDefinition`.

	Spec §33-§37.

	Multiple animals per rarity (26 definitions across 6 tiers).
	Since Phase 2.5, Health/Damage
	are Level-derived from the explicit per-rarity `Stats` table via
	StatCalculator — see the Stats section below. The legacy
	`RarityMultipliers` + `GetHealth`/`GetDamage` path is retired
	(kept only as the documented derivation source of Stats Base).

	Names are themed placeholder names — the design team can swap
	them in this file without touching service code. Adding a new
	animal is as simple as adding a new entry in the right
	rarity bucket; the services do not need to be touched.
]]

local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)
local RarityDefs = require(script.Parent.Rarity)
local SlotType = require(script.Parent.Parent.Parent.Types.SlotType)

local Animals = {}

-- --- Multipliers (RETIRED as of Phase 2.5) ------------------------

-- LEGACY, NO LONGER USED BY RUNTIME STATS. Phase 2.5 replaced the
-- create-time `floor(base * multiplier)` formula with Level-derived
-- stats (Animals.Stats + AnimalStats + StatCalculator).
-- Nothing in the runtime calls GetHealth/GetDamage any more; the
-- table and its helpers are kept only as the documented derivation
-- source of the Stats Base values (see the Stats section below).
-- Do not build new systems on this.
Animals.RarityMultipliers = {
	Health = {
		[Rarity.Common] = 1.0,
		[Rarity.Uncommon] = 1.5,
		[Rarity.Rare] = 2.2,
		[Rarity.Epic] = 3.5,
		[Rarity.Mythic] = 5.0,
		[Rarity.Legendary] = 7.5,
		[Rarity.Divine] = 11.0,
		[Rarity.Secret] = 16.0,
	},
	Damage = {
		[Rarity.Common] = 1.0,
		[Rarity.Uncommon] = 1.6,
		[Rarity.Rare] = 2.5,
		[Rarity.Epic] = 4.0,
		[Rarity.Mythic] = 6.5,
		[Rarity.Legendary] = 10.0,
		[Rarity.Divine] = 16.0,
		[Rarity.Secret] = 25.0,
	},
}

-- --- Movement -----------------------------------------------------

Animals.MovementSpeed = 10 -- studs per second during walk (reduced from 16; anchored PivotTo reads faster than a Humanoid walk)

-- Base health/damage that get multiplied by RarityMultipliers.
-- Keeping these small (single digits) means a 16x multiplier still
-- yields sane numbers (e.g. 5 * 16 = 80).
Animals.BaseHealth = 5
Animals.BaseDamage = 2

-- --- Default level (cosmetic) -----------------------------------

Animals.DefaultLevel = 1

-- --- Carry / Place (Phase 1.5; Phase 2 unified) --------------------

-- Back-compat re-export. Shared interaction tunables are
-- canonical in World.Prompts (distances, holds, head clearance);
-- the legacy per-kind Grab/Place TEXT stays sourced from
-- `Prompts.Carry.PerKind[Animal]` (pinned by the config spec).
-- Older code/tests reading `Animals.Carry` continue to work
-- with an identical shape. New code must read World.Prompts.
local Prompts = require(script.Parent.Parent.World.Prompts)
local _animalCarry = Prompts.Carry.PerKind[SlotType.OccupantKind.Animal]
Animals.Carry = {
	MaxDistance = Prompts.CarryMaxDistance,
	HoldDuration = Prompts.CarryHoldDuration,
	GrabActionText = _animalCarry.GrabActionText,
	PlaceActionText = _animalCarry.PlaceActionText,
	GrabObjectText = _animalCarry.GrabObjectText,
	PlaceObjectText = _animalCarry.PlaceObjectText,

	-- Vertical clearance (in studs) between the top of the
	-- player's Head part and the carried animal's pivot.
	-- The animal is welded to the Head via a Motor6D
	-- whose C0 places the model
	-- HeadClearanceStuds studs above the crown of the head
	-- (in head-local up). The animal then rides the head
	-- bone through every animation — no per-tick follow,
	-- no smoothing, no lag. 2.5 reads as "held just overhead",
	-- low enough to sit near the raised hands without
	-- intersecting the head mesh on average-sized animals.
	-- Canonical: Prompts.CarryVisual.HeadClearanceStuds.
	HeadClearanceStuds = Prompts.CarryVisual.HeadClearanceStuds,
}

-- --- Catalog ------------------------------------------------------

-- `Catalog[rarity][definitionId] = { displayName, baseHealth, baseDamage }`.
-- Base values are tier-relative (kept for legacy/docs flavor and
-- per-entry variety). The LIVE Health/Damage/Income numbers are
-- Level-derived from the per-rarity `Stats` table below, so every
-- entry in a tier shares the same Level-1 stat (the tier's Base)
-- and the same growth curve to Maximum at MaxLevel.
-- Within a tier, entries are ordered weakest -> strongest and
-- their legacy baseHealth/baseDamage vary ~±15% around the tier
-- anchor so the entries aren't clones of each other.
-- Uncommon is INTENTIONALLY EMPTY (no definitions yet) and Secret
-- has no bucket yet. Empty/missing buckets are safe: HatchEgg
-- re-rolls up to 8 times and GetRandom returns nil, nil.
Animals.Catalog = {
	[Rarity.Common] = {
		Chicken = { displayName = 'Chicken', baseHealth = 4, baseDamage = 1 },
		Duckling = { displayName = 'Duckling', baseHealth = 5, baseDamage = 2 },
		Frog = { displayName = 'Frog', baseHealth = 5, baseDamage = 2 },
		Dog = { displayName = 'Dog', baseHealth = 6, baseDamage = 2 },
		Penguin = { displayName = 'Penguin', baseHealth = 6, baseDamage = 3 },
	},

	-- Intentionally empty: no Uncommon definitions yet. The
	-- per-rarity Stats/Sell rows below are kept so the config
	-- stays complete and a future Uncommon definition cannot
	-- hit a missing-config path.
	[Rarity.Uncommon] = {},
	-- left empty as there are no animals in the ServerStorage.Animals.Normal/Gold/Diamond/Rainbow.Uncommon category

	[Rarity.Rare] = {
		Chimpanzee = { displayName = 'Chimpanzee', baseHealth = 20, baseDamage = 12 },
		Raccoon = { displayName = 'Raccoon', baseHealth = 23, baseDamage = 14 },
		BurrowingOwl = { displayName = 'Burrowing Owl', baseHealth = 26, baseDamage = 16 },
		Fox = { displayName = 'Fox', baseHealth = 28, baseDamage = 18 },
	},

	[Rarity.Epic] = {
		Spider = { displayName = 'Spider', baseHealth = 65, baseDamage = 27 },
		Turtle = { displayName = 'Turtle', baseHealth = 71, baseDamage = 30 },
		Axolotl = { displayName = 'Axolotl', baseHealth = 77, baseDamage = 32 },
		Walrus = { displayName = 'Walrus', baseHealth = 84, baseDamage = 35 },
		Jerboa = { displayName = 'Jerboa', baseHealth = 90, baseDamage = 38 },
	},

	[Rarity.Mythic] = {
		Triceratops = { displayName = 'Triceratops', baseHealth = 280, baseDamage = 210 },
		Crocodile = { displayName = 'Crocodile', baseHealth = 300, baseDamage = 228 },
		SabertoothTiger = { displayName = 'Sabertooth Tiger', baseHealth = 315, baseDamage = 240 },
		Scorpion = { displayName = 'Scorpion', baseHealth = 332, baseDamage = 255 },
		Crane = { displayName = 'Crane', baseHealth = 350, baseDamage = 270 },
	},

	[Rarity.Legendary] = {
		SandSpider = { displayName = 'Sand Spider', baseHealth = 120, baseDamage = 85 },
		Bear = { displayName = 'Bear', baseHealth = 133, baseDamage = 93 },
		Tiger = { displayName = 'Tiger', baseHealth = 147, baseDamage = 101 },
		Gorilla = { displayName = 'Gorilla', baseHealth = 165, baseDamage = 110 },
	},

	[Rarity.Divine] = {
		TyrannosaurusRex = { displayName = 'Tyrannosaurus Rex', baseHealth = 700, baseDamage = 460 },
		Dragon = { displayName = 'Dragon', baseHealth = 792, baseDamage = 512 },
		Yeti = { displayName = 'Yeti', baseHealth = 880, baseDamage = 570 },
	},

	[Rarity.Secret] = {},
}
-- --- Level-based stat scaling (Phase 2.5) --------------------------

--[[
	Per-rarity explicit stat parameters for the Level-derived
	Health / Damage stats. The authoritative formula is the universal
	logarithmic one (Phase 2.4 canonical document):

	    G(P) = B + (M - B) * ln(1 + P/C) / ln(1 + P_max/C)

	with P(L) = q(L-1) owned by LevelConfig and the scaling itself
	owned by StatCalculator. AnimalStats
	(ReplicatedStorage/Utility/AnimalStats.lua) is the ONE layer
	that resolves definition -> rarity -> this config -> Level points
	-> StatCalculator. Do not read `Stats` anywhere else and do not
	reintroduce a multiplier architecture.

	DERIVATION OF Base (balance preservation): the retired create-time
	formula was floor(def.baseHealth * RarityMultipliers[rarity]).
	Each rarity used to have exactly one definition, so the Health
	Base was exactly that legacy value. The Health Base anchors
	are PRESERVED unchanged for the multi-entry catalog: every
	entry in a tier shares the tier's Level-1 Health (e.g.
	Common Duckling/Frog 5, Divine Dragon 792). Per-entry
	legacy values are variety/flavor only — the live stat is
	per-rarity, not per-entry. Legacy baseDamage anchors are
	NOT preserved: live Damage is Health / 10 at every level
	(10:1 invariant), so old per-tier Damage anchors (Common 2,
	Divine 512, …) are retired history, kept only in the
	retired GetDamage path and its tests.

	DEVELOPMENT DEFAULTS (not final balance): Maximum = Base * 10 and
	Curve = 100 for every row. They give a smooth diminishing-returns
	curve from Base at Level 1 to 10x Base at Level 100 (P_max = 297).

	10:1 COMBAT INVARIANT (Damage = Health / 10, enforced in
	AnimalStats.Calculate — NOT by these rows): the Damage rows
	below are Health / 10 exactly (same Curve), so they stay
	truthful for any reader of GetStatConfig (debug surfaces).
	They are DOCUMENTATION of the invariant, not tuning knobs:
	changing a Damage row cannot change live Damage (the
	calculation bypasses Damage parameters entirely), and
	validateStats() below FAILS THE GAME AT STARTUP if any
	Damage row ever drifts from its Health row. Tune Health;
	Damage follows.

	Income (Phase 2.6) follows the exact same rule — Base / Maximum /
	Curve per rarity, resolved through the same StatCalculator via
	AnimalStats.Calculate(animal, 'Income'). The Base values are
	set to SellBaseValue / 12.5 per rarity, so a Level-1 animal
	earns back its egg's price in ~12 seconds and its first
	upgrade costs ~12.5x one second of income (the early pacing
	anchor; see the Income table note). They are tunable balance
	values, not derived ones — there is no legacy income formula
	to preserve.

	Uncommon and Secret have no catalog definitions yet
	(RarityDefs.Order knows the tiers; the catalog does not).
	Their rows are kept complete (Uncommon's legacy-derived values,
	Secret extrapolated as Divine's def values x Secret's legacy
	multipliers) so the configuration is complete and a future
	definition cannot hit a missing-config path. No Uncommon or
	Secret content was added.
]]

Animals.Stats = {
	Health = {
		[Rarity.Common] = { Base = 5, Maximum = 50, Curve = 100 },
		[Rarity.Uncommon] = { Base = 12, Maximum = 120, Curve = 100 },
		[Rarity.Rare] = { Base = 24, Maximum = 240, Curve = 100 },
		[Rarity.Epic] = { Base = 77, Maximum = 770, Curve = 100 },
		[Rarity.Mythic] = { Base = 140, Maximum = 1400, Curve = 100 },
		[Rarity.Legendary] = { Base = 315, Maximum = 3150, Curve = 100 },
		[Rarity.Divine] = { Base = 792, Maximum = 7920, Curve = 100 },
		[Rarity.Secret] = { Base = 1152, Maximum = 11520, Curve = 100 },
	},
	Damage = {
		[Rarity.Common] = { Base = 0.5, Maximum = 5, Curve = 100 },
		[Rarity.Uncommon] = { Base = 1.2, Maximum = 12, Curve = 100 },
		[Rarity.Rare] = { Base = 2.4, Maximum = 24, Curve = 100 },
		[Rarity.Epic] = { Base = 7.7, Maximum = 77, Curve = 100 },
		[Rarity.Mythic] = { Base = 14, Maximum = 140, Curve = 100 },
		[Rarity.Legendary] = { Base = 31.5, Maximum = 315, Curve = 100 },
		[Rarity.Divine] = { Base = 79.2, Maximum = 792, Curve = 100 },
		[Rarity.Secret] = { Base = 115.2, Maximum = 1152, Curve = 100 },
	},
	-- Phase 2.6: income per second. BALANCED (early-game curve):
	-- Base = SellBaseValue / 12.5, so a Level-1 animal's first
	-- upgrade (SellBase x growth^0 = SellBase, growth = 1.12)
	-- costs ~12.5x one second of income — the early-game pacing
	-- anchor (growth-independent: L1 cost is always the base).
	-- Maximum = Base x 56.25 and the shared Curve = 80 shape the
	-- widening: ratios stay fast through the teens, widen
	-- through the 20s-30s, and ease late (upgrade costs grow at
	-- 1.12x against flattening log income). Curve is shared so
	-- every rarity rides the SAME ratio curve — rarity shifts
	-- absolute scale
	-- only (ordering stays monotonic per the ladder invariant).
	-- The value is a RATE: AnimalStats returns it at full float
	-- precision and the income accumulator owns the single
	-- rounding boundary (whole dollars credited to the slot's
	-- CashPool).
	Income = {
		[Rarity.Common] = { Base = 8, Maximum = 450, Curve = 80 },
		[Rarity.Uncommon] = { Base = 40, Maximum = 2250, Curve = 80 },
		[Rarity.Rare] = { Base = 80, Maximum = 4500, Curve = 80 },
		[Rarity.Epic] = { Base = 400, Maximum = 22500, Curve = 80 },
		[Rarity.Mythic] = { Base = 2040, Maximum = 114750, Curve = 80 },
		[Rarity.Legendary] = { Base = 4000, Maximum = 225000, Curve = 80 },
		[Rarity.Divine] = { Base = 8000, Maximum = 450000, Curve = 80 },
		[Rarity.Secret] = { Base = 4000, Maximum = 225000, Curve = 80 },
	},
}

-- --- Base sell value (Phase 2.8) --------------------------------------
--
-- Per-rarity liquidation base for Animal selling, in whole
-- dollars (positive integers). The live sale formula is
-- `BaseSellValue x CurrentLevel` (SellService, BigNumber-safe);
-- this table is the ONLY price source for that formula — there
-- is no second price database.
--
-- DEVELOPMENT DEFAULTS (not final balance): the ladder mirrors
-- EggConfig.Price so a fresh Level-1 animal liquidates
-- for roughly its egg's acquisition cost and every level adds
-- one more base-worth of value. Designers retune here without
-- touching transaction code.
Animals.SellBaseValue = {
	[Rarity.Common] = 100,
	[Rarity.Uncommon] = 5_00,
	[Rarity.Rare] = 1_000,
	[Rarity.Epic] = 5_000,
	[Rarity.Mythic] = 25_500,
	[Rarity.Legendary] = 50_000,
	[Rarity.Divine] = 100_000,
	[Rarity.Secret] = 50_000,
}

-- --- Liquidation factor (balance pass) ---------------------------------
--
-- Per-rarity sale haircut applied by the sell formula
-- (SellService folds it in as base x level x SellMultiplier x
-- trait x mutation, BigNumber-exact). Uniform 0.75: a Level-1
-- animal liquidates for 75% of its egg cost — selling stays
-- useful for clearing bad animals, but hatch-and-sell can
-- never print money (per-egg expected recovery simulates at
-- 70-85% of price across all tiers; see the balance report).
-- Upgrade costs still anchor on SellBaseValue above (full
-- base), so this touches ONLY sale payouts, never upgrade
-- pricing or egg pricing. Do NOT raise these without
-- re-verifying every egg's hatch-and-sell EV.
Animals.SellMultiplier = {
	[Rarity.Common] = '0.75',
	[Rarity.Uncommon] = '0.75',
	[Rarity.Rare] = '0.75',
	[Rarity.Epic] = '0.75',
	[Rarity.Mythic] = '0.75',
	[Rarity.Legendary] = '0.75',
	[Rarity.Divine] = '0.75',
	[Rarity.Secret] = '0.75',
}

-- Validates the Stats table once at require time (same fail-loudly
-- philosophy as LevelConfig): every known rarity tier must have an
-- explicit row for every supported stat, and every parameter must be
-- finite and ordered (0 < Base <= Maximum, Curve > 0). A typo or a
-- missing tier fails at startup instead of producing NaN stats.
local function validateStats()
	for _, statName in ipairs({ 'Health', 'Damage', 'Income' }) do
		local perRarity = Animals.Stats[statName]
		if type(perRarity) ~= 'table' then
			error(('[Animals] Stats.%s table missing'):format(statName), 0)
		end
		for _, rarity in ipairs(RarityDefs.Order) do
			local cfg = perRarity[rarity]
			if type(cfg) ~= 'table' then
				error(('[Animals] Stats.%s missing rarity %s'):format(statName, tostring(rarity)), 0)
			end
			local base, maximum, curve = cfg.Base, cfg.Maximum, cfg.Curve
			if type(base) ~= 'number' or base ~= base or base == math.huge or base == -math.huge or base <= 0 then
				error(('[Animals] Stats.%s.%s.Base must be a finite number > 0'):format(statName, rarity), 0)
			end
			if
				type(maximum) ~= 'number'
				or maximum ~= maximum
				or maximum == math.huge
				or maximum == -math.huge
				or maximum < base
			then
				error(('[Animals] Stats.%s.%s.Maximum must be a finite number >= Base'):format(statName, rarity), 0)
			end
			if type(curve) ~= 'number' or curve ~= curve or curve == math.huge or curve == -math.huge or curve <= 0 then
				error(('[Animals] Stats.%s.%s.Curve must be a finite number > 0'):format(statName, rarity), 0)
			end
		end
	end
	-- 10:1 invariant guard: every Damage row must equal its
	-- Health row divided by 10 (Base, Maximum, and Curve).
	-- Live Damage bypasses these rows entirely
	-- (AnimalStats.Calculate), but debug/display readers use
	-- GetStatConfig — a drifted row would show a ratio the
	-- game never actually has. Fail loudly at startup.
	for _, rarity in ipairs(RarityDefs.Order) do
		local health = Animals.Stats.Health[rarity]
		local damage = Animals.Stats.Damage[rarity]
		if damage.Base ~= health.Base / 10 or damage.Maximum ~= health.Maximum / 10 or damage.Curve ~= health.Curve then
			error(
				('[Animals] Stats.Damage.%s must equal Stats.Health.%s / 10 (10:1 invariant)'):format(
					tostring(rarity),
					tostring(rarity)
				),
				0
			)
		end
	end
	-- Phase 2.8: every rarity tier needs an explicit integer sell
	-- base (see SellBaseValue above). Same fail-loudly rule.
	if type(Animals.SellBaseValue) ~= 'table' then
		error('[Animals] SellBaseValue table missing', 0)
	end
	for _, rarity in ipairs(RarityDefs.Order) do
		local sellBase = Animals.SellBaseValue[rarity]
		if
			type(sellBase) ~= 'number'
			or sellBase ~= sellBase
			or sellBase == math.huge
			or sellBase == -math.huge
			or sellBase ~= math.floor(sellBase)
			or sellBase <= 0
		then
			error(('[Animals] SellBaseValue.%s must be a positive integer'):format(tostring(rarity)), 0)
		end
	end
	-- Balance pass: every tier needs an explicit terminating-
	-- decimal liquidation factor in (0, 1] (see SellMultiplier
	-- above). Same fail-loudly rule.
	if type(Animals.SellMultiplier) ~= 'table' then
		error('[Animals] SellMultiplier table missing', 0)
	end
	for _, rarity in ipairs(RarityDefs.Order) do
		local factor = Animals.SellMultiplier[rarity]
		if type(factor) ~= 'string' then
			error(('[Animals] SellMultiplier.%s must be a decimal string'):format(tostring(rarity)), 0)
		end
		local n = tonumber(factor)
		if n == nil or n ~= n or n <= 0 or n > 1 then
			error(('[Animals] SellMultiplier.%s must be in (0, 1]'):format(tostring(rarity)), 0)
		end
		if not string.match(factor, '^%d+%.?%d*$') then
			error(('[Animals] SellMultiplier.%s must be a terminating decimal'):format(tostring(rarity)), 0)
		end
	end
end
validateStats()

-- --- Physical weight (AnimalWeight growth system) ----------------------
--
-- Per-rarity natural weight range, in kg-ish units (DEVELOPMENT
-- DEFAULTS, same ladder spirit as SellBaseValue — designers
-- retune here without touching system code). Level 1 weighs
-- Base; MaxLevel weighs Maximum; the log curve fills between.
--
-- Per-DEFINITION overrides (optional): WeightByDefinition[defId]
-- wins over the rarity row when present, so individual Animals
-- (Mouse vs Dragon) tune independently. Empty by default —
-- entries below are commented examples of the shape.
Animals.WeightByRarity = {
	[Rarity.Common] = { Base = 10, Maximum = 40 },
	[Rarity.Uncommon] = { Base = 15, Maximum = 60 },
	[Rarity.Rare] = { Base = 25, Maximum = 100 },
	[Rarity.Epic] = { Base = 60, Maximum = 250 },
	[Rarity.Mythic] = { Base = 150, Maximum = 600 },
	[Rarity.Legendary] = { Base = 350, Maximum = 1400 },
	[Rarity.Divine] = { Base = 700, Maximum = 2800 },
	[Rarity.Secret] = { Base = 1200, Maximum = 5000 },
}

Animals.WeightByDefinition = {
	-- Mouse = { Base = 0.2, Maximum = 1 },
	-- Dragon = { Base = 50, Maximum = 500 },
}

local function validateWeight()
	if type(Animals.WeightByRarity) ~= 'table' then
		error('[Animals] WeightByRarity table missing', 0)
	end
	for _, rarity in ipairs(RarityDefs.Order) do
		local row = Animals.WeightByRarity[rarity]
		if type(row) ~= 'table' then
			error(('[Animals] WeightByRarity missing rarity %s'):format(tostring(rarity)), 0)
		end
		if
			type(row.Base) ~= 'number'
			or row.Base ~= row.Base
			or row.Base == math.huge
			or row.Base == -math.huge
			or row.Base <= 0
		then
			error(('[Animals] WeightByRarity.%s.Base must be a finite number > 0'):format(rarity), 0)
		end
		if
			type(row.Maximum) ~= 'number'
			or row.Maximum ~= row.Maximum
			or row.Maximum == math.huge
			or row.Maximum == -math.huge
			or row.Maximum < row.Base
		then
			error(('[Animals] WeightByRarity.%s.Maximum must be a finite number >= Base'):format(rarity), 0)
		end
	end
	if type(Animals.WeightByDefinition) ~= 'table' then
		error('[Animals] WeightByDefinition table missing', 0)
	end
	for defId, row in pairs(Animals.WeightByDefinition) do
		if type(defId) ~= 'string' or type(row) ~= 'table' then
			error('[Animals] WeightByDefinition keys must be definitionId strings', 0)
		end
		if
			type(row.Base) ~= 'number'
			or type(row.Maximum) ~= 'number'
			or row.Base ~= row.Base
			or row.Maximum ~= row.Maximum
			or row.Base <= 0
			or row.Maximum < row.Base
		then
			error(('[Animals] WeightByDefinition.%s must have 0 < Base <= Maximum'):format(defId), 0)
		end
		local rarity = Animals.Get(defId)
		if not rarity then
			error(('[Animals] WeightByDefinition.%s is not in the catalog'):format(defId), 0)
		end
	end
end
validateWeight()

-- --- Helpers used by services -------------------------------------

-- Returns the rolled Health for a created animal.
function Animals.GetHealth(rarity: string, baseHealth: number): number
	local m = Animals.RarityMultipliers.Health[rarity] or 1
	return math.floor(baseHealth * m)
end

-- Returns the rolled Damage for a created animal.
function Animals.GetDamage(rarity: string, baseDamage: number): number
	local m = Animals.RarityMultipliers.Damage[rarity] or 1
	return math.floor(baseDamage * m)
end

-- Returns a random definition in the given rarity bucket.
function Animals.GetRandom(rarity: string, rng: (() -> number)?): (string?, any?)
	local bucket = Animals.Catalog[rarity]
	if not bucket or not next(bucket) then
		return nil, nil
	end
	local ids = {}
	for k in pairs(bucket) do
		ids[#ids + 1] = k
	end
	table.sort(ids)
	local pick = math.floor(((rng and rng() or Random.new():NextNumber()) * #ids) + 1)
	if pick < 1 then
		pick = 1
	end
	if pick > #ids then
		pick = #ids
	end
	return ids[pick], bucket[ids[pick]]
end

-- Returns the canonical definition by id (or nil if not in catalog).
function Animals.Get(definitionId: string): (string?, any?)
	for rarity, bucket in pairs(Animals.Catalog) do
		if bucket[definitionId] then
			return rarity, bucket[definitionId]
		end
	end
	return nil, nil
end

-- Re-export the level table for convenience.
Animals.BaseLevel = RarityDefs.BaseLevel

return table.freeze(Animals)
