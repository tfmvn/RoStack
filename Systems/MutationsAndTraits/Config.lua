--!strict
--[[
	MutationsAndTraits — consolidated tunables
	===========================================

	A documentation-and-consolidation module. It is NOT required by the
	implementation: the live game reads the domain config modules
	directly (see the "Lives in" column on every entry below).

	Copy this file into your project as a single place to read and tune
	every value this system owns, or ignore it and edit the domain
	configs in place. If you copy it, keep it in sync — there is no
	loader that keeps the two in step.

	Read-only reference. Nothing here is read at runtime by
	ReusableSystems' own code.
]]

--!native

local Config = {}

-- ============================================================================
-- 1. TRAIT CATALOG
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Traits
--           (Source/ReplicatedStorage/Config/Creatures/Traits.lua)
-- Read by:  TraitService.RollTrait / GetGenerationMultiplier /
--           GetSellMultiplier; Traits.GenerationMultiplierFor /
--           SellMultiplierFor; shared consumers such as AnimalStats
--           (income), the economy sell path, PersistenceAudit, and the
--           overhead sanitizers.
-- Safe to change: YES for Chance and the multipliers, but see the notes
--                 on sell multipliers before touching them.
-- Placeholder:  The catalog itself is placeholder content (Gold /
--               Diamond / Rainbow are Brainrot Arena's trait names).

Config.Traits = {
	-- The trait catalog. One entry per trait. `Chance` is a percent
	-- number in 0..100; the multipliers are DECIMAL STRINGS.
	--
	-- NOTE: the source file's own header comment claims
	-- "Gold x3 sell / Diamond x5 sell / Rainbow x10 sell". That comment
	-- is STALE. The values below are what the code actually reads.
	--
	-- Valid multiplier string: 1..12 chars, matches ^%d+%.?%d*$,
	-- value in (0, 1e6], at most 6 significant digits.
	-- Valid Chance: a number in 0..100. Total Chance must be <= 100;
	-- the remainder is the implicit "no trait" bucket (100 - 15 = 85%).
	Catalog = {
		-- 10% chance. x3 income, x1.2 sell.
		Gold = {
			Chance = 10,
			GenerationMultiplier = '3',
			SellMultiplier = '1.2',
		},
		-- 4% chance. x5 income, x1.5 sell.
		Diamond = {
			Chance = 4,
			GenerationMultiplier = '5',
			SellMultiplier = '1.5',
		},
		-- 1% chance. x10 income, x2 sell.
		Rainbow = {
			Chance = 1,
			GenerationMultiplier = '10',
			SellMultiplier = '2',
		},
	},

	-- The deterministic roll order. NEVER replace this with a pairs()
	-- iteration — table order must not be able to skew probabilities.
	-- Every id here must exist in Catalog, every Catalog entry must
	-- appear here (unreachable entries are rejected at require time),
	-- and no duplicates.
	--
	-- Changing the ORDER changes which probability band each trait
	-- gets, so it is a balance change, not a cosmetic one.
	RollOrder = { 'Gold', 'Diamond', 'Rainbow' },
}

-- ============================================================================
-- 2. MUTATION CATALOG
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Mutations
--           (Source/ReplicatedStorage/Config/Creatures/Mutations.lua)
-- Read by:  MutationService.SanitizeList / GetGenerationMultiplier /
--           GetSellMultiplier; Mutations.SanitizeIds / GenerationFold /
--           SellFold; AnimalStats (income), the sell path,
--           PersistenceAudit, and the overhead sanitizers.
-- Safe to change: YES, but the eligibility/RNG for these mutations is
--                 owned by the event system, NOT here. This module only
--                 PRICES them.
-- Placeholder:  The catalog is placeholder content (Galactic / Frost).

Config.Mutations = {
	-- Multipliers are DECIMAL STRINGS, same rules as traits:
	-- 1..12 chars, ^%d+%.?%d*$, value in (0, 1e6], <= 6 significant
	-- digits. There is NO `Chance` here — mutation eligibility is
	-- event-driven.
	Catalog = {
		-- x3 income, x2.5 sell. (Galaxy event.)
		Galactic = {
			GenerationMultiplier = '3',
			SellMultiplier = '2.5',
		},
		-- x2.5 income, x2 sell. (Snowfall event.)
		Frost = {
			GenerationMultiplier = '2.5',
			SellMultiplier = '2',
		},
	},

	-- There is no maximum mutation count, no ordering significance, and
	-- no duplicate tolerance. Multipliers commute and every fold sorts
	-- and de-duplicates before multiplying, so insertion order can
	-- never change a result.
	--
	-- An Egg carries N unique mutations (possibly zero). On open, ALL
	-- of them transfer to the Animal as a defensive copy.
	MaxCount = nil, -- nil = uncapped
}

-- ============================================================================
-- 3. RARITY TABLE (canonical)
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Rarity
--           (Source/ReplicatedStorage/Config/Creatures/Rarity.lua)
-- Read by:  the egg center spawn roll, the hatch roll, the animal
--           catalog, all rarity-coloured UI, and the luck curve.
-- Safe to change: colours and display names YES; SpawnWeight changes
--                 rarity rates and should be a balance decision;
--                 Order changes the UI sort (and Mythic/ Legendary are
--                 deliberately out of power order).
-- Placeholder:  The tier list and its weights are Brainrot Arena's.

Config.Rarity = {
	-- Display order, common -> rarest. NOTE: Mythic is BELOW Legendary
	-- in this list, and this is intentional in the source game. Do not
	-- use an index into this table to compare rarity strength.
	Order = { 'Common', 'Uncommon', 'Rare', 'Epic', 'Mythic', 'Legendary', 'Divine', 'Secret' },

	-- Display colors, as 0..255 RGB triples.
	-- Common and Secret are both pure white.
	RarityColor = {
		Common = { 255, 255, 255 },
		Uncommon = { 80, 200, 120 },
		Rare = { 0, 166, 255 },
		Epic = { 191, 0, 255 },
		Mythic = { 255, 0, 4 },
		Legendary = { 255, 247, 0 },
		Divine = { 105, 255, 140 },
		Secret = { 255, 255, 255 },
	},

	-- The egg Model.Name shown in Explorer and in the overhead GUI.
	RarityDisplayName = {
		Common = 'Common Egg',
		Uncommon = 'Uncommon Egg',
		Rare = 'Rare Egg',
		Epic = 'Epic Egg',
		Mythic = 'Mythic Egg',
		Legendary = 'Legendary Egg',
		Divine = 'Divine Egg',
		Secret = 'Secret Egg',
	},

	-- Weights for WHICH RARITY a centre egg spawns as. The hatch roll
	-- uses a separate, far more granular table (EggConfig.HatchRollWeights).
	-- Divine and Secret are 0: they NEVER appear in the normal roll and
	-- are spawned explicitly by admin/special systems.
	SpawnWeight = {
		Common = 38,
		Uncommon = 27,
		Rare = 19,
		Epic = 13.8,
		Legendary = 2,
		Mythic = 0.2,
		Divine = 0,
		Secret = 0,
	},

	-- The server luck curve: the normal-roll weight multiplier for a
	-- pool tier is luck^(tierIndex / LuckExponentDivisor), where the
	-- tier index follows the design pool order Common(0) .. Mythic(5).
	-- luck = 1x is the identity. Divine/Secret stay at 0 at any luck.
	-- Designers rebalance via SpawnWeight; this divisor shapes the
	-- curve itself.
	LuckExponentDivisor = 3,

	-- The base level an animal of each rarity starts at. Purely
	-- cosmetic in this phase (no growth mechanic).
	BaseLevel = {
		Common = 1,
		Uncommon = 2,
		Rare = 3,
		Epic = 4,
		Mythic = 5,
		Legendary = 6,
		Divine = 7,
		Secret = 8,
	},
}

-- ============================================================================
-- 4. RARITY GUARANTEES (owned by another system, consumed here)
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
--           (Systems/EggsAndHatching/Source/ReplicatedStorage/Config/Creatures/Eggs.lua)
-- Read by:  Egg.GuaranteeService (in the EggsAndHatching system).
-- WHY HERE:  the guarantee timers are keyed by rarity, so they are the
--           boundary between this system and the egg system.
-- Safe to change: YES. These are the "a Legendary is guaranteed every
--                 N seconds" timers.
-- Placeholder:  no.

Config.RarityGuarantees = {
	-- Seconds between forced spawns of each rarity.
	Guarantees = {
		{ Rarity = 'Legendary', Enabled = true, IntervalSeconds = 600 },
		{ Rarity = 'Mythic', Enabled = true, IntervalSeconds = 1200 },
	},
}

-- ============================================================================
-- 5. RARITY-GATED NOTIFICATIONS (owned by another system)
-- ============================================================================
-- Lives in: ServerScriptService.Egg.RareEggNotifier (EggsAndHatching)
-- Read by:  that module.
-- WHY HERE:  "which rarities deserve a server-wide toast" is a rarity
--           policy, and it must use an EXPLICIT set — NOT an index into
--           Rarity.Order, because Order puts Mythic below Legendary.
-- Safe to change: YES.
-- Placeholder:  no.

Config.RareNotifyRarities = { 'Legendary', 'Mythic', 'Divine', 'Secret' }

-- ============================================================================
-- 6. INHERITANCE RULES (hard-coded in TraitService, documented here)
-- ============================================================================
-- There is no config knob for these — they are the contract every
-- consumer depends on. Listed so a new game does not accidentally
-- break them.

Config.InheritanceRules = {
	-- A valid forced egg trait is used 100% and NO roll is performed.
	ForcedTraitIsCertain = true,
	-- An invalid-but-present forced egg trait is warned about and the
	-- roll takes over; the egg is NOT destroyed.
	InvalidForcedTraitFallsBackToRoll = true,
	-- A nil egg trait always rolls.
	NilTraitAlwaysRolls = true,
	-- The returned mutation list is a fresh, sorted, de-duplicated copy.
	-- The egg's live table is never aliased or reordered in place.
	MutationsAreDefensivelyCopied = true,
	-- "No trait" is nil, never the string 'None'.
	NoTraitIsNil = true,
}

return table.freeze(Config)
