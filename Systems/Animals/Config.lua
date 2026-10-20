--!strict
--[[
	Animals — consolidated tunables
	================================

	A documentation-and-consolidation module. It is NOT required by the
	implementation: the live game reads the domain config modules
	directly:
	  * ReplicatedStorage/Config/Creatures/Animals.lua       (this system's own)
	  * ReplicatedStorage/Config/Creatures/Progression.lua   (owned by Upgrades)
	  * ReplicatedStorage/Config/World/Prompts.lua           (owned by Carry)

	Copy this file into your project as a single place to read and tune
	every value this system owns, or ignore it and edit the domain
	modules in place. If you copy it, keep it in sync — there is no
	loader that keeps the two in step.

	Read-only reference. Nothing here is read at runtime by
	ReusableSystems' own code.
]]

--!native

local Config = {}

-- ============================================================================
-- 1. MOVEMENT
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals
-- Read by:  Animal.WalkController (Speed), AnimalService (the walk)
-- Safe to change: YES, but it is a feel value.
-- Placeholder:  no.

Config.MovementSpeed = 10 -- studs/second. The animal's walk speed.

-- ============================================================================
-- 2. THE CATALOG
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals
-- Read by:  AnimalService.GetRandom / Get, AnimalStats, AnimalWeight,
--           AnimalOverhead, AnimalService.GetTemplate
-- Safe to change: YES — but every species needs a matching Studio
--            model or the hatch fails and the egg is REFUNDED.
-- Placeholder:  the roster is Brainrot Arena content.
--
-- `Catalog[rarity][definitionId] = { displayName, baseHealth, baseDamage }`.
-- `baseHealth` / `baseDamage` are LEGACY flavour values only — the live
-- numbers are Level-derived from the `Stats` tables below. Every entry
-- in a tier shares the same Level-1 stat (the tier's Base); the
-- per-entry legacy values vary ~±15% around the tier anchor so the
-- entries are not clones of each other.
--
-- DERIVATION OF THE STATS Base: the retired create-time formula was
-- `floor(def.baseHealth * RarityMultipliers[rarity])`. Each rarity used
-- to have exactly one definition, so the Health Base was exactly that
-- legacy value; the anchors are preserved unchanged for the
-- multi-entry catalog (Common Duckling/Frog 5, Divine Dragon 792).
-- Legacy baseDamage anchors are NOT preserved — live Damage is
-- Health / 10 at every level, so the old per-tier Damage anchors are
-- retired history.
--
-- THE EMPTY BUCKETS ARE INTENTIONAL:
--   * Uncommon is empty — no Uncommon species has been authored.
--   * Secret is empty — no Secret species has been authored.
-- The `Stats`, `WeightByRarity`, `SellBaseValue` and `BaseLevel` tables
-- DO have rows for both tiers; the data is ready for content that has
-- not been written yet. `GetRandom` returns `nil, nil` for an empty
-- bucket, and the hatch re-rolls (up to 8 times) rather than failing.
--
-- The studio tree must mirror this exactly:
--   ServerStorage.Animals.<Trait>.<Rarity>.<DefId>  -> a Model
-- The <DefId> node IS the species Model (not a folder holding one).

Config.Catalog = {
	Common = {
		Chicken = { displayName = 'Chicken', baseHealth = 4, baseDamage = 1 },
		Duckling = { displayName = 'Duckling', baseHealth = 5, baseDamage = 2 },
		Frog = { displayName = 'Frog', baseHealth = 5, baseDamage = 2 },
		Dog = { displayName = 'Dog', baseHealth = 6, baseDamage = 2 },
		Penguin = { displayName = 'Penguin', baseHealth = 6, baseDamage = 3 },
	},
	-- INTENTIONALLY EMPTY. See the note above.
	Uncommon = {},
	Rare = {
		Chimpanzee = { displayName = 'Chimpanzee', baseHealth = 20, baseDamage = 12 },
		Raccoon = { displayName = 'Raccoon', baseHealth = 23, baseDamage = 14 },
		BurrowingOwl = { displayName = 'Burrowing Owl', baseHealth = 26, baseDamage = 16 },
		Fox = { displayName = 'Fox', baseHealth = 28, baseDamage = 18 },
	},
	Epic = {
		Spider = { displayName = 'Spider', baseHealth = 65, baseDamage = 27 },
		Turtle = { displayName = 'Turtle', baseHealth = 71, baseDamage = 30 },
		Axolotl = { displayName = 'Axolotl', baseHealth = 77, baseDamage = 32 },
		Walrus = { displayName = 'Walrus', baseHealth = 84, baseDamage = 35 },
		Jerboa = { displayName = 'Jerboa', baseHealth = 90, baseDamage = 38 },
	},
	Mythic = {
		Triceratops = { displayName = 'Triceratops', baseHealth = 280, baseDamage = 210 },
		Crocodile = { displayName = 'Crocodile', baseHealth = 300, baseDamage = 228 },
		SabertoothTiger = { displayName = 'Sabertooth Tiger', baseHealth = 315, baseDamage = 240 },
		Scorpion = { displayName = 'Scorpion', baseHealth = 332, baseDamage = 255 },
		Crane = { displayName = 'Crane', baseHealth = 350, baseDamage = 270 },
	},
	Legendary = {
		SandSpider = { displayName = 'Sand Spider', baseHealth = 120, baseDamage = 85 },
		Bear = { displayName = 'Bear', baseHealth = 133, baseDamage = 93 },
		Tiger = { displayName = 'Tiger', baseHealth = 147, baseDamage = 101 },
		Gorilla = { displayName = 'Gorilla', baseHealth = 165, baseDamage = 110 },
	},
	Divine = {
		TyrannosaurusRex = { displayName = 'Tyrannosaurus Rex', baseHealth = 700, baseDamage = 460 },
		Dragon = { displayName = 'Dragon', baseHealth = 792, baseDamage = 512 },
		Yeti = { displayName = 'Yeti', baseHealth = 880, baseDamage = 570 },
	},
	-- INTENTIONALLY EMPTY. See the note above.
	Secret = {},
}

-- ============================================================================
-- 3. DERIVED STATS
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals
-- Read by:  ReplicatedStorage.Utility.AnimalStats (the ONLY reader)
-- Safe to change: YES, but see the two hard rules below.
-- Placeholder:  the balance is Brainrot Arena's.
--
-- `Stats.<stat>[rarity] = { Base, Maximum, Curve }`.
--
-- HARD RULE 1 — THE 10:1 COMBAT INVARIANT:
--   `Stats.Damage[r]` MUST be exactly `Stats.Health[r] / 10` in ALL
--   THREE fields (Base, Maximum, Curve). `Animals.validateStats()`
--   errors at REQUIRE TIME if any Damage row drifts from Health / 10.
--   `AnimalStats` enforces it at runtime too (Damage short-circuits to
--   Health / 10), so a mismatch can never reach a player — but the
--   config will refuse to load.
--   Two independent Damage curves CANNOT hold a ratio across a
--   nonlinear curve. That drift is what produced the old "~400 HP with
--   ~312 Damage" observations.
--
-- HARD RULE 2 — THE CURVE:
--   Health and Damage use Curve = 100. Income uses Curve = 80. They
--   are NOT the same. Any note that says "all stat rows share
--   Curve = 100" is wrong.
--
-- The curve is logarithmic (StatCalculator). Level 1 returns `Base`
-- exactly and MaxLevel returns `Maximum` exactly (both are fast
-- paths, immune to float dust). Intermediate levels stay strictly
-- inside (Base, Maximum) and are monotonically non-decreasing.
--
-- Every rarity needs a row, including the empty Uncommon and Secret
-- buckets — the table is validated for all 8 tiers.
--
-- RANGE: Base > 0, Maximum >= Base, Curve > 0.
--
-- `Income` is the PER-SECOND rate. It is derived, never persisted;
-- the accumulation math is external (IncomeService).
-- The trait and mutation GENERATION folds multiply Income (and only
-- Income) on top of this value.

Config.Stats = {
	Health = {
		Common = { Base = 5, Maximum = 50, Curve = 100 },
		Uncommon = { Base = 12, Maximum = 120, Curve = 100 },
		Rare = { Base = 24, Maximum = 240, Curve = 100 },
		Epic = { Base = 77, Maximum = 770, Curve = 100 },
		Mythic = { Base = 140, Maximum = 1400, Curve = 100 },
		Legendary = { Base = 315, Maximum = 3150, Curve = 100 },
		Divine = { Base = 792, Maximum = 7920, Curve = 100 },
		Secret = { Base = 1152, Maximum = 11520, Curve = 100 },
	},
	Damage = {
		Common = { Base = 0.5, Maximum = 5, Curve = 100 },
		Uncommon = { Base = 1.2, Maximum = 12, Curve = 100 },
		Rare = { Base = 2.4, Maximum = 24, Curve = 100 },
		Epic = { Base = 7.7, Maximum = 77, Curve = 100 },
		Mythic = { Base = 14, Maximum = 140, Curve = 100 },
		Legendary = { Base = 31.5, Maximum = 315, Curve = 100 },
		Divine = { Base = 79.2, Maximum = 792, Curve = 100 },
		Secret = { Base = 115.2, Maximum = 1152, Curve = 100 },
	},
	Income = {
		Common = { Base = 8, Maximum = 450, Curve = 80 },
		Uncommon = { Base = 40, Maximum = 2250, Curve = 80 },
		Rare = { Base = 80, Maximum = 4500, Curve = 80 },
		Epic = { Base = 400, Maximum = 22500, Curve = 80 },
		Mythic = { Base = 2040, Maximum = 114750, Curve = 80 },
		Legendary = { Base = 4000, Maximum = 225000, Curve = 80 },
		Divine = { Base = 8000, Maximum = 450000, Curve = 80 },
		Secret = { Base = 4000, Maximum = 225000, Curve = 80 },
	},
}

-- ============================================================================
-- 4. WEIGHT / GROWTH
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals
-- Read by:  ReplicatedStorage.Utility.AnimalWeight
-- Safe to change: YES, but it changes every animal's visible size.
-- Placeholder:  Brainrot Arena's tuning.
--
-- The weight range drives the visual growth:
--   weight = StatCalculator(weight range, level points)
--   alpha  = (weight - Base) / (Maximum - Base)  in [0, 1]
--   scale  = animal.baseScale * (1 + (MaxGrowthScale - 1) * alpha)
-- `animal.baseScale` is the template's OWN authored scale, captured at
-- spawn — a tiny Mouse and a huge Dragon both grow +30%, never to one
-- universal size. The scale is never compounded.
--
-- RANGE: Base > 0, Maximum >= Base.
-- Every rarity needs a row, including the empty tiers.

Config.WeightByRarity = {
	Common = { Base = 10, Maximum = 40 },
	Uncommon = { Base = 15, Maximum = 60 },
	Rare = { Base = 25, Maximum = 100 },
	Epic = { Base = 60, Maximum = 250 },
	Mythic = { Base = 150, Maximum = 600 },
	Legendary = { Base = 350, Maximum = 1400 },
	Divine = { Base = 700, Maximum = 2800 },
	Secret = { Base = 1200, Maximum = 5000 },
}

-- Per-species weight overrides. An entry here BEATS the rarity row.
-- *** EMPTY IN PRACTICE. *** The source file has only commented-out
-- examples, so the override branch of `AnimalWeight.GetRange` is
-- never exercised at runtime. The shape is:
--   WeightByDefinition = {
--       Mouse = { Base = 1, Maximum = 2 },
--       Dragon = { Base = 500, Maximum = 2000 },
--   }
Config.WeightByDefinition = {}

-- The maximum visual growth, as a multiple of the animal's own
-- baseline scale. 1.30 = "+30% at max weight".
-- Lives in: ReplicatedStorage.Utility.AnimalWeight (a module constant,
-- not a config value).
Config.MaxGrowthScale = 1.30

-- The log-growth curve constant for weight. Same shape family as the
-- Health/Damage rows (100), but the Income rows use 80.
-- Lives in: ReplicatedStorage.Utility.AnimalWeight.
Config.WeightCurve = 100

-- ============================================================================
-- 5. SELL VALUES
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals
-- Read by:  the Sell service (not this system), via the config
-- Safe to change: YES, but it is a balance decision.
-- Placeholder:  Brainrot Arena's economy.
--
-- `SellBaseValue` is the per-rarity liquidation base, in whole
-- currency units. `SellMultiplier` is the liquidation factor applied
-- on top (0.75 = you get 75% of base).
--
-- RANGE: SellBaseValue must be a POSITIVE INTEGER.
--         SellMultiplier must be a decimal STRING in (0, 1] that
--         terminates (no '1.2345678'). A non-terminating decimal is a
--         require-time error, because the money layer is BigNumber
--         decimal-string arithmetic.
--         The legacy 5x / 10x trait multipliers are IGNORED by the
--         trait/mutation sell path.

Config.SellBaseValue = {
	Common = 100,
	Uncommon = 500,
	Rare = 1000,
	Epic = 5000,
	Mythic = 25500,
	Legendary = 50000,
	Divine = 100000,
	Secret = 50000,
}

Config.SellMultiplier = {
	Common = '0.75',
	Uncommon = '0.75',
	Rare = '0.75',
	Epic = '0.75',
	Mythic = '0.75',
	Legendary = '0.75',
	Divine = '0.75',
	Secret = '0.75',
}

-- ============================================================================
-- 6. CARRY
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Animals (as a RE-EXPORT)
-- Canonical source: ReplicatedStorage.Config.World.Prompts
-- Read by:  AnimalService.CanGrabAnimal / CanPlaceAnimal (MaxDistance),
--           CarryPrompts (the text), CarryController (HeadClearanceStuds)
-- Safe to change: NO — not here. Edit World/Prompts.
-- Placeholder:  no.
--
-- *** THIS IS A MIRROR, NOT AN INPUT. *** `Animals.Carry.MaxDistance`
-- is a copy of `Prompts.CarryMaxDistance`. Mutating `Animals.Carry` at
-- runtime does nothing — `CarryPrompts` and the validators read
-- `Prompts` directly. Change the canonical value.

Config.Carry = {
	-- The server-side interaction distance, in studs. The
	-- ProximityPrompt's MaxActivationDistance is a CLIENT HINT; this
	-- is the security boundary.
	-- Canonical: Prompts.CarryMaxDistance (8).
	MaxDistance = 8,

	-- How long the Pickup prompt must be held, in seconds. 0 means
	-- instant activation. An early release cancels the pickup.
	-- Canonical: Prompts.CarryHoldDuration (1).
	HoldDuration = 1,

	-- The four prompt text strings. Canonical:
	-- Prompts.Carry.PerKind[SlotType.OccupantKind.Animal].
	GrabActionText = 'Grab',
	PlaceActionText = 'Place',
	GrabObjectText = 'Animal',
	PlaceObjectText = 'Empty Slot',

	-- Vertical clearance (studs) between the top of the player's Head
	-- part and the carried animal's pivot. The Motor6D's C0 places the
	-- model this far above the crown, in head-local up.
	-- Canonical: Prompts.CarryVisual.HeadClearanceStuds (2.5).
	HeadClearanceStuds = 2.5,
}

-- ============================================================================
-- 7. LEGACY VALUES (retired or inert)
-- ============================================================================
-- Documented so a new game knows what to reproduce — and what NOT to.

Config.Retired = {
	-- Animals.RarityMultipliers (RETIRED as of Phase 2.5).
	-- LEGACY, NO LONGER USED BY RUNTIME STATS. Phase 2.5 replaced the
	-- create-time `floor(base * multiplier)` formula with Level-derived
	-- stats. Nothing in the runtime calls GetHealth/GetDamage any more;
	-- the table and its helpers are kept only as the documented
	-- derivation source for the `Stats` Base values.
	-- Do not build new systems on this.
	--
	-- Health: Common 1.0, Uncommon 1.5, Rare 2.2, Epic 3.5,
	--         Mythic 5.0, Legendary 7.5, Divine 11.0, Secret 16.0
	-- Damage: Common 1.0, Uncommon 1.6, Rare 2.5, Epic 4.0,
	--         Mythic 6.5, Legendary 10.0, Divine 16.0, Secret 25.0
	RarityMultipliers = {
		Health = {
			Common = 1.0,
			Uncommon = 1.5,
			Rare = 2.2,
			Epic = 3.5,
			Mythic = 5.0,
			Legendary = 7.5,
			Divine = 11.0,
			Secret = 16.0,
		},
		Damage = {
			Common = 1.0,
			Uncommon = 1.6,
			Rare = 2.5,
			Epic = 4.0,
			Mythic = 6.5,
			Legendary = 10.0,
			Divine = 16.0,
			Secret = 25.0,
		},
	},

	-- Creation-time defaults. Still present in the config, but the live
	-- Health/Damage come from `Stats` (Level-derived), not from these.
	BaseHealth = 5,
	BaseDamage = 2,
	DefaultLevel = 1,
}

-- ============================================================================
-- 8. PROGRESSION (owned by the Upgrades system)
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Progression
-- Read by:  AnimalService.AddXP, AnimalStats, AnimalWeight
-- Safe to change: GrowthRate NO (UpgradeService asserts 1.12 at load);
--            BaseRequired YES with care; MaxLevel and PointsPerLevel
--            YES with care.
-- Placeholder:  no.
--
-- XP SEMANTICS: XP is CURRENT PROGRESS toward the next level, not
-- lifetime XP. Crossing a threshold consumes it and carries the
-- overflow into the next level:
--     Level 1, XP 90, required 100, AddXP(50)  ->  Level 2, XP 40
--
-- ROUNDING: `round-half-up` (math.floor(raw + 0.5)) applied EXACTLY
-- ONCE, inside GetXPRequired, at the configuration boundary. No
-- service, command or test performs its own rounding.
--
-- MAX LEVEL: at MaxLevel the level never increases. XP is retained as a
-- "bank" for a future level-cap raise, capped at GetXPRequired(MaxLevel)
-- — the first threshold a cap raise would consume. Grants beyond the
-- bank ceiling are deterministically discarded.
--
-- POINTS: P(L) = PointsPerLevel * (L - 1). P_max = 3 * 99 = 297.

Config.Progression = {
	MaxLevel = 100,
	XP = {
		-- XP needed to go Level 1 -> Level 2.
		BaseRequired = 200,
		-- XPRequired(L) = BaseRequired * GrowthRate^(L-1).
		-- PINNED at 1.12: UpgradeService implements the identical 1.12
		-- curve with exact 28/25 integer math and ASSERTS this value
		-- at load. Do NOT retune without updating UpgradeService and
		-- re-verifying the whole economy curve.
		-- (The Arena player-XP track keeps its own separate 1.25 curve
		-- by design — arena gates are tuned to arena XP supply.)
		GrowthRate = 1.12,
	},
	-- Points awarded per level. P(L) = 3 * (L - 1), so Level 1 = 0.
	PointsPerLevel = 3,
}

-- ============================================================================
-- 9. HARDCODED CONSTANTS (documented, not configurable)
-- ============================================================================
-- These live in the code, not in config. Listed so a new game knows
-- what to reproduce.

Config.InternalConstants = {
	-- AnimalService
	MaxHatchRarityRerolls = 8, -- how many times an empty animal rarity is re-rolled
	-- Animal.WalkController
	WalkFacingOffset = 0, -- the animals face the way they walk (the EGG flight uses math.pi)
	WalkYawSmoothingRate = 8, -- yaw easing: 1 - exp(-8 * dt)
	-- Animal.CarryController
	CarryJointName = 'CarryJoint',
	-- Animal.LevelUpPresentation
	BopTotalSeconds = 0.68, -- Anticipation .10 + Launch .16 + Apex .06 + Fall .18 + Landing .08 + Settle .10
	-- Animal.AnimalOverhead
	OverheadGuiName = 'OverheadGui',
	OverheadAnchorName = 'CENTER',
	-- OwnedObjectIdentity
	IdPrefix = 'AN_',
	IdTokenLength = 10,
	IdMaxCollisionRetries = 8,
	-- Animal.AnimalStats
	DamageToHealthRatio = 10, -- Damage == Health / 10, bit-exact
}

return table.freeze(Config)
