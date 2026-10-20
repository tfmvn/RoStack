--!strict
--[[
	Upgrades — consolidated tunables
	=================================

		A documented view of every value the Upgrades system reads.

		The authoritative copies live in two modules:
		  * ReplicatedStorage.Config.Creatures.Progression  -- the
		    level ceiling, the XP curve, the points formula
		  * ReplicatedStorage.Config.Creatures.Animals       -- the
		    base price per rarity (SellBaseValue)

		This file is a CONSOLIDATION, not a replacement. Copy any
		value you change back into the module that owns it, or
		uncomment the require block at the bottom to make this file
		the live source of truth.

		WARNING: Progression.lua validates itself at REQUIRE TIME
		and calls error() on a bad configuration -- it does not
		expose a non-throwing Validate(). Every other config in this
		library does. If you retune GrowthRate without updating
		UpgradeService's exact 28/25 integer math, the server fails
		to LOAD (UpgradeService asserts GrowthRate == 1.12).

		Not owned here:
		  * AnimalConfig.SellMultiplier / Traits / Mutations -- the
		    SALE formula, not the upgrade price
		  * AnimalConfig.Stats.Income -- the income ladder
		  * ModifierService -- the money multiplier, which is NEVER
		    consulted for an upgrade cost
	]]

local UpgradeConfig = {}

-- =========================================================================
-- Level ceiling
-- =========================================================================

-- The hard progression ceiling.
-- Default: 100
-- Meaning: the highest level an animal can reach. Level 100 is the
--   last level; there is no 101, and UpgradeService.GetUpgradeCost
--   returns nil at level >= MaxLevel (so the last PURCHASABLE
--   level is 99 -> 100).
-- Valid range: integer >= 1.
-- Safe to change: YES -- but Progression.lua re-runs its overflow
--   check at require time (the whole 100-level XP curve must stay
--   under 2^53), and every animal's persisted Level is clamped to
--   MaxLevel on the next Normalize.
-- Read by: ReplicatedStorage.Config.Creatures.Progression
--   (authoritative), Progression.GetXPRequired / GetPointsForLevel /
--   Normalize; UpgradeService.GetUpgradeCost and UpgradeAnimal.
-- Placeholder: NO -- a real, tuned value.
UpgradeConfig.MaxLevel = 100

-- The admin `/setlevel` ceiling.
-- Default: 99
-- Meaning: how high an admin command may set an animal's level. It
--   is deliberately ONE BELOW MaxLevel.
-- Valid range: integer >= 0, <= MaxLevel.
-- Safe to change: YES -- but keep it below MaxLevel; setting it
--   equal to MaxLevel would let an admin bypass the purchase cost
--   of the final level.
-- Read by: the admin tooling (not by UpgradeService).
-- Placeholder: NO.
UpgradeConfig.AdminLevelCap = 99

-- =========================================================================
-- XP curve
-- =========================================================================

-- XP needed to advance FROM Level 1 TO Level 2.
-- Default: 200
-- Meaning: the first level-up costs this much XP. XPRequired(L) =
--   BaseRequired * GrowthRate^(L-1).
-- Valid range: a finite number > 0.
-- Safe to change: YES -- this is the XP track's anchor, so raising
--   it slows every level-up in the game.
-- Read by: ReplicatedStorage.Config.Creatures.Progression
--   (authoritative), Progression.GetXPRequired.
-- Placeholder: NO.
UpgradeConfig.XPBaseRequired = 200

-- The XP growth factor per level.
-- Default: 1.12
-- Meaning: XPRequired(L) = BaseRequired * 1.12^(L-1). The value
--   rounds HALF-UP, exactly once, at the config boundary.
-- Valid range: a finite number >= 1 (1 = constant thresholds).
-- Safe to change: NO -- UpgradeService ASSERTS this is 1.12 at
--   require time and implements the same curve with exact 28/25
--   integer math. Changing it without rewriting that math breaks
--   the server at load. The two curves are deliberately coupled:
--     UpgradeCost(L -> L+1) = BasePrice * 1.12^(L-1)
--     XPRequired(L -> L+1)  = 200 * 1.12^(L-1)
--   The comment in Progression.lua says: "Do NOT retune without
--   updating UpgradeService + re-verifying the whole economy curve."
--   NOTE: the Arena player-XP track keeps its own separate 1.25
--   curve (Arena.lua) by design.
-- Read by: ReplicatedStorage.Config.Creatures.Progression
--   (authoritative); asserted by UpgradeService.
-- Placeholder: NO.
UpgradeConfig.XPGrowthRate = 1.12

-- =========================================================================
-- Progression points
-- =========================================================================

-- Points awarded per level.
-- Default: 3
-- Meaning: P(L) = q * (L - 1). Level 1 = 0 points, Level 2 = 3,
--   Level 100 = 297. P_max = q * (MaxLevel - 1) = 297.
-- Valid range: an integer >= 0.
-- Safe to change: YES -- but it is a linear rescale of every
--   player's point total; anything already spent is not refunded.
-- Read by: ReplicatedStorage.Config.Creatures.Progression
--   (authoritative), Progression.GetPointsForLevel /
--   GetMaxPoints.
-- Placeholder: NO.
UpgradeConfig.PointsPerLevel = 3

-- =========================================================================
-- Upgrade price
-- =========================================================================

-- The base price per rarity -- the anchor of the upgrade cost curve.
-- Default: Common 100, Uncommon 500, Rare 1000, Epic 5000,
--   Mythic 25500, Legendary 50000, Divine 100000, Secret 50000.
-- Meaning: the price of the FIRST level of an animal of that
--   rarity. Every later level is base * 1.12^(L-1).
--   IMPORTANT: this is the SAME table the SALE formula uses as its
--   base, so retuning it moves both curves.
-- Valid range: a finite positive integer per rarity.
-- Safe to change: YES -- but see the note above, and the balance
--   anchors in Animals.lua: the Level-1 upgrade is meant to cost
--   about 12.5x one second of income, and a Level-1 animal liquidates
--   for 75% of its egg price.
-- Read by: ReplicatedStorage.Config.Creatures.Animals (authoritative,
--   as Animals.SellBaseValue); UpgradeService.GetBasePrice reads it.
-- Placeholder: NO.
UpgradeConfig.BasePriceCommon = 100
UpgradeConfig.BasePriceUncommon = 500
UpgradeConfig.BasePriceRare = 1000
UpgradeConfig.BasePriceEpic = 5000
UpgradeConfig.BasePriceMythic = 25500
UpgradeConfig.BasePriceLegendary = 50000
UpgradeConfig.BasePriceDivine = 100000
UpgradeConfig.BasePriceSecret = 50000

-- The upgrade growth factor, as an exact fraction.
-- Default: 28 / 25 (= 1.12)
-- Meaning: UpgradeService computes the cost as
--   base * 28^k / 25^k, then scales by 10^(2k) to get the exact
--   terminating decimal. 25 = 5^2, so 25^k divides 10^(2k)
--   exactly and the division is exact -- zero floating point.
-- Valid range: num/den must be 2/5-smooth (a product of 2s and 5s)
--   for the terminating-decimal trick to work. 28 = 2^2 * 7 is fine
--   as a numerator; the DENOMINATOR is the constraint.
-- Safe to change: NO -- it must equal XPGrowthRate, and the
--   UpgradeService require-time assert enforces that indirectly.
-- Read by: ServerScriptService.UpgradeService (hardcoded in the
--   exact-math loops).
-- Placeholder: NO.
UpgradeConfig.UpgradeGrowthNumerator = 28
UpgradeConfig.UpgradeGrowthDenominator = 25

-- =========================================================================
-- Behavioural constants
-- =========================================================================

-- The TransactionReason used for the debit.
-- Default: 'AnimalUpgrade'
-- Meaning: the audit label written on the money transaction.
-- Valid range: any value in the CLOSED TransactionReason enum.
-- Safe to change: NO -- EconomyService rejects any reason outside
--   the enum's `_ALL` list with the code 'invalid-reason', and the
--   spend then fails.
-- Read by: UpgradeService.UpgradeAnimal.
-- Placeholder: NO.
UpgradeConfig.TransactionReason = 'AnimalUpgrade'

-- The transaction id.
-- Default: 'tx-<userId>-<counter>'
-- Meaning: the per-transaction identifier EconomyService assigns.
--   It is generated by EconomyService, not by UpgradeService -- this
--   entry documents the format only.
-- Valid range: n/a.
-- Safe to change: n/a.
-- Read by: ReplicatedStorage.Utility.BigNumber's consumer
--   (EconomyService).
-- Placeholder: YES -- documentation of a format owned elsewhere.

-- =========================================================================
-- Derived (not configurable -- documented so the numbers make sense)
-- =========================================================================
--
-- The upgrade cost:
--   cost(L -> L+1) = BasePrice[rarity] * 1.12^(L-1)
--
-- Exact examples (BigNumber strings, never floats):
--   Chicken   (base 100)     L1 = '100'          L2 = '112'
--                            L3 = '125.44'       L4 = '140.4928'
--                            L5 = '157.351936'   L6 = '176.23416832'
--   Chimpanzee (base 1000)    L2 = '1120'        L3 = '1254.4'
--                            L4 = '1404.928'
--   Dragon    (base 100000)   L2 = '112000'      L3 = '125440'
--
-- The XP curve:
--   XPRequired(L) = round-half-up(200 * 1.12^(L-1))
--   L1 = 200, L2 = 224, L3 = 251, L4 = 281, L5 = 315, ...
--
-- The points curve:
--   P(L) = 3 * (L - 1); P_max = 297.
--
-- INVARIANT: the upgrade cost and the XP curve MUST share the same
-- growth number. They are coupled by an assert in UpgradeService.
--
-- INVARIANT: Animals.SellBaseValue[rarity] is used BOTH as the
-- upgrade base price AND as the base of the sale formula (the sale
-- then applies SellMultiplier, trait, and mutation factors). The
-- two curves are anchored to the same number on purpose.
--
-- INVARIANT: a Level-1 upgrade costs exactly the base (1.12^0 = 1),
-- which is growth-independent. The balance anchor in Animals.lua is
-- that this equals about 12.5x one second of income.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.
--
-- NOTE: Progression.lua has no non-throwing Validate(); it errors at
-- require time. If you wire this file to it, keep the values in sync
-- or the server will not load.

-- local Progression = require(game:GetService('ReplicatedStorage').Config.Creatures.Progression)
-- local Animals = require(game:GetService('ReplicatedStorage').Config.Creatures.Animals)
-- UpgradeConfig.MaxLevel = Progression.MaxLevel
-- UpgradeConfig.AdminLevelCap = Progression.AdminLevelCap
-- UpgradeConfig.XPBaseRequired = Progression.XP.BaseRequired
-- UpgradeConfig.XPGrowthRate = Progression.XP.GrowthRate
-- UpgradeConfig.PointsPerLevel = Progression.PointsPerLevel
-- UpgradeConfig.BasePriceCommon = Animals.SellBaseValue.Common
-- UpgradeConfig.BasePriceUncommon = Animals.SellBaseValue.Uncommon
-- UpgradeConfig.BasePriceRare = Animals.SellBaseValue.Rare
-- UpgradeConfig.BasePriceEpic = Animals.SellBaseValue.Epic
-- UpgradeConfig.BasePriceMythic = Animals.SellBaseValue.Mythic
-- UpgradeConfig.BasePriceLegendary = Animals.SellBaseValue.Legendary
-- UpgradeConfig.BasePriceDivine = Animals.SellBaseValue.Divine
-- UpgradeConfig.BasePriceSecret = Animals.SellBaseValue.Secret

return table.freeze(UpgradeConfig)
