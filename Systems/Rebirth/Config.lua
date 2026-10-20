--!strict
--[[
	Rebirth — consolidated tunables
	================================

		A documented view of every value the Rebirth system reads.

		The authoritative copy lives in ONE module:
		  ReplicatedStorage.Config.Economy.Rebirth

		This file is a CONSOLIDATION, not a replacement. To change a
		value in the live game, edit that module (or uncomment the
		require block at the bottom to make this file the source of
		truth).

		Not owned here:
		  * GearConfig.RequiredRebirth -- which gear each Rebirth
		    unlocks (owned by the Combat system)
		  * AnimalConfig -- the DefIds referenced by the requirements
		    and their base sell values (owned by the Animals system)
		  * ArenaProgressionService -- the arena level the
		    requirements are measured against
		  * ModifierService -- where the multiplier actually lives
		    at runtime
	]]

local RebirthConfig = {}

-- =========================================================================
-- Stand counts for players who never rebirthed
-- =========================================================================

-- Normal (animal) stands a player owns at Rebirth 0.
-- Default: 6
-- Meaning: Rebirth 0 has no completable entry, so it cannot carry its
--   own Stands block. Every never-rebirthed player uses this count.
-- Valid range: integer >= 0.
-- Safe to change: YES -- but it changes EVERY new player's base
--   immediately, and a lower value removes stands from existing
--   players who have never rebirthed. The Rebuild path re-assigns the
--   same base id, so existing stands are rebuilt with the new count.
-- Read by: ReplicatedStorage.Config.Economy.Rebirth (authoritative),
--   Rebirth.StandsFor; consumed by DynamicSlotService.
-- Placeholder: NO -- a real, tuned value.
RebirthConfig.InitialStandsAnimal = 6

-- Arena stands a player owns at Rebirth 0.
-- Default: 1
-- Meaning: as above, for the arena-stand flavour.
-- Valid range: integer >= 0.
-- Safe to change: YES -- same caveats as InitialStandsAnimal.
-- Read by: ReplicatedStorage.Config.Economy.Rebirth (authoritative),
--   Rebirth.StandsFor.
-- Placeholder: NO.
RebirthConfig.InitialStandsArena = 1

-- =========================================================================
-- The requirement / reward ladder
-- =========================================================================
--
-- One table per rebirth, indexed 1..Max. The server walks
-- current + 1, so the entries MUST be gapless (Validate() enforces
-- this). Every Rebirth may carry any number of Animal requirements,
-- including zero.
--
-- Per entry:
--   Requirements = {
--     Money = <BigNumber decimal STRING>,
--     ArenaLevel = <integer >= 0>,
--     Animals = { { DefId = <string>, Trait = <string|nil>,
--                   MinimumLevel = <integer >= 1> } },
--   }
--   Rewards = {
--     StartingCash = <BigNumber decimal STRING>,
--     MoneyMultiplier = <number > 0>,
--   }
--   Reset = {
--     Money = <bool>, Base = <bool>, Animals = <bool>,
--     ArenaLevel = <bool>,
--   }
--   Stands = { Animal = <int >= 0>, Arena = <int >= 0> }
--
-- Money and StartingCash are STRINGS, never numbers -- the money
-- system is BigNumber-backed. A number here fails Validate() and
-- BigNumber.Compare will reject it at runtime.

-- --- Rebirth 1 ------------------------------------------------------------
-- Money: wallet required, as a decimal string.
--   Default: '500000'
--   Meaning: the price of the first rebirth. 100x the starting
--     wallet ('5000'), so it is a real grind.
--   Valid range: any BigNumber decimal string >= '0'.
--   Safe to change: YES -- but it is the first wall; lowering it
--     removes the first progression beat entirely.
--   Read by: RebirthService.RequestRebirth (BigNumber.Compare) and
--     BuildState.
--   Placeholder: NO.
RebirthConfig.Rebirth1Money = '500000'

-- Arena level required.
--   Default: 5
--   Meaning: the arena progression gate. 0 disables the gate.
--   Valid range: integer >= 0.
--   Safe to change: YES -- the single most common knob to retune.
--   Read by: RebirthService.RequestRebirth
--     (ArenaProgressionService.GetArenaLevel).
--   Placeholder: NO.
RebirthConfig.Rebirth1ArenaLevel = 5

-- Animal requirements. Each rule needs a DISTINCT owned animal of the
-- given DefId and Trait at or above MinimumLevel. One animal can
-- never satisfy two rules.
--   Default: { { DefId = 'Dog', Trait = 'Normal', MinimumLevel = 5 } }
--   Meaning: the animal hand-in for the first rebirth.
--   Valid range: an array (may be empty) of
--     { DefId = <non-empty string>, Trait = <string|nil>,
--       MinimumLevel = <integer >= 1> }.
--   Safe to change: YES -- the DefIds must exist in the animal
--     catalogue, or the requirement can never be met (silently).
--   Read by: RebirthService.matchAnimals.
--   Placeholder: NO.
RebirthConfig.Rebirth1Animals = {
	{ DefId = 'Dog', Trait = 'Normal', MinimumLevel = 5 },
}

-- Cash granted after the reset.
--   Default: '25000'
--   Meaning: the post-rebirth wallet. Always a fraction of the
--     requirement, so a rebirth never leaves you richer than when
--     you started.
--   Valid range: any BigNumber decimal string >= '0'.
--   Safe to change: YES.
--   Read by: RebirthService.RequestRebirth
--     (data.Money = BigNumber.sanitize(StartingCash)).
--   Placeholder: NO.
RebirthConfig.Rebirth1StartingCash = '25000'

-- Permanent money multiplier.
--   Default: 1.5
--   Meaning: the multiplier on every future money gain. Applied via
--     ModifierService under the source id 'Rebirth' and re-applied
--     on every join (ModifierService is session-only).
--   Valid range: number > 0, not NaN.
--   Safe to change: YES -- but it compounds with the whole ladder,
--     so raise the later requirements at the same time.
--   Read by: RebirthService (AddModifier + ApplySessionModifiers).
--   Placeholder: NO.
RebirthConfig.Rebirth1MoneyMultiplier = 1.5

-- Stands unlocked BY completing Rebirth 1.
--   Default: { Animal = 6, Arena = 2 }
--   Meaning: the counts a player AT Rebirth 1 owns. The delta from
--     the previous counts is what the GUI shows.
--   Valid range: integers >= 0.
--   Safe to change: YES.
--   Read by: RebirthConfig.StandsFor, RebirthUnlocks.BuildForPreview,
--     DynamicSlotService.
--   Placeholder: NO.
RebirthConfig.Rebirth1Stands = { Animal = 6, Arena = 2 }

-- --- Rebirth 2 ------------------------------------------------------------
RebirthConfig.Rebirth2Money = '1500000'
RebirthConfig.Rebirth2ArenaLevel = 15
RebirthConfig.Rebirth2Animals = {
	{ DefId = 'Fox', Trait = 'Normal', MinimumLevel = 1 },
	{ DefId = 'Spider', Trait = 'Normal', MinimumLevel = 3 },
}
RebirthConfig.Rebirth2StartingCash = '50000'
RebirthConfig.Rebirth2MoneyMultiplier = 2.0
RebirthConfig.Rebirth2Stands = { Animal = 7, Arena = 2 }

-- --- Rebirth 3 ------------------------------------------------------------
RebirthConfig.Rebirth3Money = '3000000'
RebirthConfig.Rebirth3ArenaLevel = 25
RebirthConfig.Rebirth3Animals = {
	{ DefId = 'Turtle', Trait = 'Normal', MinimumLevel = 8 },
	{ DefId = 'Walrus', Trait = 'Normal', MinimumLevel = 3 },
}
RebirthConfig.Rebirth3StartingCash = '150000'
RebirthConfig.Rebirth3MoneyMultiplier = 2.5
RebirthConfig.Rebirth3Stands = { Animal = 8, Arena = 3 }

-- --- Rebirth 4 ------------------------------------------------------------
RebirthConfig.Rebirth4Money = '4000000'
RebirthConfig.Rebirth4ArenaLevel = 40
RebirthConfig.Rebirth4Animals = {
	{ DefId = 'Crocodile', Trait = 'Normal', MinimumLevel = 6 },
	{ DefId = 'Scorpion', Trait = 'Normal', MinimumLevel = 4 },
}
RebirthConfig.Rebirth4StartingCash = '200000'
RebirthConfig.Rebirth4MoneyMultiplier = 3.0
RebirthConfig.Rebirth4Stands = { Animal = 8, Arena = 3 }

-- --- Rebirth 5 ------------------------------------------------------------
RebirthConfig.Rebirth5Money = '5000000'
RebirthConfig.Rebirth5ArenaLevel = 45
RebirthConfig.Rebirth5Animals = {
	{ DefId = 'Gorilla', Trait = 'Normal', MinimumLevel = 10 },
	{ DefId = 'Tiger', Trait = 'Normal', MinimumLevel = 10 },
}
RebirthConfig.Rebirth5StartingCash = '250000'
RebirthConfig.Rebirth5MoneyMultiplier = 3.5
RebirthConfig.Rebirth5Stands = { Animal = 8, Arena = 3 }

-- =========================================================================
-- Behavioural constants
-- =========================================================================

-- The ModifierService source id that owns the rebirth multiplier.
-- Default: 'Rebirth'
-- Meaning: the identity of the multiplier source. Re-adding the same
--   (userId, type, sourceId) REPLACES the previous value, so this
--   id is what makes the multiplier idempotent and non-stacking.
-- Valid range: any non-empty string. Must be stable.
-- Safe to change: NO -- changing it orphans the existing source and
--   the player ends up with two multipliers until the old one is
--   removed.
-- Read by: RebirthService (REBIRTH_MODIFIER_SOURCE).
-- Placeholder: NO.
RebirthConfig.ModifierSourceId = 'Rebirth'

-- How long Init() waits for the RebirthAction remote.
-- Default: 10 (seconds)
-- Meaning: the WaitForChild timeout in RebirthService.Init. If the
--   remotes folder is missing, the wait burns 10 seconds of boot and
--   then logs 'RebirthAction remote missing; rebirths disabled'.
-- Valid range: > 0 (seconds).
-- Safe to change: YES -- but keep it small; the remotes folder is
--   created first in the bootstrap, so this wait should never elapse.
-- Read by: RebirthService.Init.
-- Placeholder: NO.
RebirthConfig.RemoteWaitSeconds = 10

-- =========================================================================
-- Derived (not configurable -- documented so the numbers make sense)
-- =========================================================================
--
-- The requirement check is AND-ed: money >= Requirements.Money AND
-- arenaLevel >= Requirements.ArenaLevel AND every animal rule
-- matched. A rule matches when the player owns a DISTINCT animal of
-- the given DefId and Trait whose level is >= MinimumLevel.
--
-- The commit order is fixed and not configurable:
--   steal/carry rollback -> base -> animals -> arena -> money ->
--   rebirth count -> multiplier -> label -> egg reconcile.
-- The base step is a hard gate: if it fails, nothing else runs.
--
-- INVARIANT: the requirement ladder should stay monotonic in Money,
-- StartingCash, and MoneyMultiplier. A non-monotonic ladder lets a
-- player farm a later rebirth's StartingCash by doing an earlier one
-- first.

-- =========================================================================
-- Optional: wire this file to the authoritative module
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.

-- local Rebirth = require(game:GetService('ReplicatedStorage').Config.Economy.Rebirth)
-- RebirthConfig.InitialStandsAnimal = 6
-- RebirthConfig.InitialStandsArena = 1
-- local e1 = Rebirth.Get(1)
-- if e1 ~= nil then
-- 	RebirthConfig.Rebirth1Money = e1.Requirements.Money
-- 	RebirthConfig.Rebirth1ArenaLevel = e1.Requirements.ArenaLevel
-- 	RebirthConfig.Rebirth1Animals = e1.Requirements.Animals
-- 	RebirthConfig.Rebirth1StartingCash = e1.Rewards.StartingCash
-- 	RebirthConfig.Rebirth1MoneyMultiplier = e1.Rewards.MoneyMultiplier
-- 	RebirthConfig.Rebirth1Stands = e1.Stands
-- end
-- -- ... same for Rebirth2..Rebirth5

return table.freeze(RebirthConfig)
