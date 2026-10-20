--!strict
--[[
	Inventory — consolidated tunables
	==================================

	A single, documented view of every value the Inventory system
	reads. The authoritative copies live in the config modules below;
	this file is a CONSOLIDATION, not a replacement. Copy any value you
	change back into the module that owns it, or replace the `require`
	calls at the bottom with your own modules and delete the local
	copies.

	Owning modules (the authoritative source of truth):
	  * ReplicatedStorage.Config.World.Bases          -- slot pool, labels
	  * ReplicatedStorage.Config.World.Prompts         -- carry actions
	  * ReplicatedStorage.Config.Creatures.Progression -- level cap
	  * ReplicatedStorage.Config.Creatures.Animals     -- animal defs
	  * ReplicatedStorage.Config.Systems.Security      -- request throttle

	Not owned here (owned elsewhere, referenced only):
	  * Economy.Money.*        -- what a sale pays
	  * Animals.SellBaseValue  -- the price ladder
	  * Types.SlotType         -- slot id format and occupant kinds

	Every value below carries: default, meaning, valid range,
	whether it is safe to change, which module reads it, and
	whether it is a placeholder.
]]

local InventoryConfig = {}

-- =========================================================================
-- The slot pool
-- =========================================================================

-- How many slots each base has.
-- Default: 8
-- Meaning: the size of the UNIFIED slot pool. Eggs and animals share
--   the same pool — a slot holds either an egg or an animal, never
--   both. A base with 8 slots can therefore hold 8 occupants of mixed
--   kind.
-- Valid range: integer >= 1. Changing it changes the shape of every
--   base's stand ring.
-- Safe to change: YES for a new game. NO for a game with existing
--   players — an existing profile may hold occupants in slots that no
--   longer exist, and `PersistenceAudit` will quarantine them.
-- Read by: Bases.Slots.Count (authoritative); `SlotService` allocates
--   slot ids against it, and the stand ring is generated from it.
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.SlotsPerBase = 8

-- The world size of a slot, in studs.
-- Default: Vector3.new(3.5, 0.6, 3.5)
-- Meaning: the footprint of a stand's display area. The Y component is
--   the platform's thickness, not a height above the ground.
-- Valid range: any Vector3 with positive X and Z.
-- Safe to change: YES -- presentation only, unless the stand models
--   are authored to a specific size, in which case the authored model
--   wins.
-- Read by: Bases.Slots.Size (authoritative).
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.SlotSize = Vector3.new(3.5, 0.6, 3.5)

-- The radius of the stand ring, in studs.
-- Default: 12
-- Meaning: the slots are arranged in a ring of this radius around the
--   base's centre. The stand ring is generated from `Slots.Count` and
--   this radius — the individual offsets are computed, not authored.
-- Valid range: number > 0.
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Slots.Offsets (computed from Count and this radius).
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.StandRingRadius = 12

-- The height of the stand ring above the base floor, in studs.
-- Default: 2
-- Meaning: the Y coordinate every slot offset sits at.
-- Valid range: any number.
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Slots.Offsets (the Y component).
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.StandRingHeight = 2

-- =========================================================================
-- Levels
-- =========================================================================

-- The hard level ceiling.
-- Default: 100
-- Meaning: the maximum level an animal can reach. At the cap the level
--   never increases and the XP is retained. `Progression.Normalize`
--   clamps a level above this back down to it.
-- Valid range: integer >= 1.
-- Safe to change: NO for a live game — an existing animal above the new
--   cap is silently clamped, and its XP is stranded. Changing the cap
--   is a progression-balance decision, not a tuning decision.
-- Read by: Progression.MaxLevel (authoritative); `UpgradeService`
--   enforces it; `SlotMenuService` reads it to render the level cap.
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.MaxLevel = 100

-- =========================================================================
-- Request throttling
-- =========================================================================

-- The minimum gap between slot-menu and snapshot requests, in seconds.
-- Default: 0.5
-- Meaning: the shared throttle for the slot menu and the player
--   snapshot. A client that spams gets its requests dropped rather
--   than queued.
-- Valid range: number >= 0. 0 disables the throttle.
-- Safe to change: YES -- technical setting, not balance. Raise it if
--   you see menu lag under load; lower it for a more responsive menu.
-- Read by: Security.RequestThrottleSeconds (authoritative).
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.RequestThrottleSeconds = 0.5

-- =========================================================================
-- Stand labels
-- =========================================================================
--
-- These are the strings the slot menu renders on each stand. They are
-- the shared piece of the stand UI; the per-stand formatting is done
-- by the callers.

-- The direct-upgrade button's text.
-- Default: 'Upgrade'
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.UpgradeButton.
InventoryConfig.LabelUpgradeButton = 'Upgrade'

-- Shown when the upgrade endpoint is unavailable.
-- Default: 'Unavailable'
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.Unavailable.
InventoryConfig.LabelUnavailable = 'Unavailable'

-- Shown at the level cap.
-- Default: 'Max Level'
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.MaxLevel.
InventoryConfig.LabelMaxLevel = 'Max Level'

-- The short form of the level-cap label.
-- Default: 'Max'
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.MaxLevelShort.
InventoryConfig.LabelMaxLevelShort = 'Max'

-- The income-rate suffix.
-- Default: '/sec'
-- Meaning: appended after the rate, e.g. '1.25/sec'. The '$' and the
--   number are added by the caller.
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.RateSuffix.
InventoryConfig.LabelRateSuffix = '/sec'

-- The placeholder for a stand whose rate cannot be computed.
-- Default: 'N/A'
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.RateMissing.
InventoryConfig.LabelRateMissing = 'N/A'

-- The name shown for an egg standing in a slot.
-- Default: 'Egg'
-- Meaning: the occupant's display name when the slot holds an egg
--   rather than an animal.
-- Valid range: any string. Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.Labels.EggName.
InventoryConfig.LabelEggName = 'Egg'

-- Decimal places for the income rate.
-- Default: 2
-- Meaning: the precision of the $/sec readout, with trailing zeros
--   trimmed.
-- Valid range: integer >= 0.
-- Safe to change: YES -- presentation only.
-- Read by: Bases.Stands.UpgradeReadout.RateDecimals.
InventoryConfig.RateDecimals = 2

-- =========================================================================
-- Carry actions
-- =========================================================================

-- Which prompt actions each occupant kind offers.
-- Default: Egg -> { 'Pickup', 'Hatch' },
--          Animal -> { 'Pickup', 'SellAnimal' },
--          Empty -> { 'Place' },
--          Reserved -> { 'Place' }
-- Meaning: the set of actions a player may take on a slot, chosen by
--   what occupies it. The STRUCTURE (which actions exist, what each
--   one does) is owned by `SlotActionHandler`; only the choice of
--   action names is data.
-- Valid range: the four keys above, each a non-empty array of action
--   names. An unknown action name is a no-op at runtime.
-- Safe to change: NO -- not freely. Removing an action removes a
--   player capability. Note that eggs are deliberately NOT sellable:
--   there is no SellEgg action, prompt, button, or remote path
--   anywhere in the codebase.
-- Read by: Prompts.Carry.Actions (authoritative).
-- Placeholder: NO -- a real, tuned value.
InventoryConfig.CarryActions = {
	Egg = { 'Pickup', 'Hatch' },
	Animal = { 'Pickup', 'SellAnimal' },
	Empty = { 'Place' },
	Reserved = { 'Place' },
}

-- =========================================================================
-- INVARIANTS
-- =========================================================================
--
-- * The slot pool is UNIFIED. A slot holds an egg OR an animal. A
--   slot id encodes its owner and its index, in the form
--   `p7:<userId>:slot:<index>`, and the index is what `SlotService`
--   allocates against. Changing the slot-id prefix orphans every
--   existing slot id.
--
-- * `Bases.Slots.Offsets` is COMPUTED, not authored. The `Bases`
--   config builds it from `Count` and the ring radius at load time.
--   Do not try to hand-edit the offsets; change the count or the
--   radius and let the config rebuild them.
--
-- * `Progression.Normalize(level, xp)` is the only safe way to read a
--   stored level. It clamps to [1, MaxLevel] and rejects NaN, ±inf,
--   and non-integers, returning the sanitised level and XP. Reading
--   `data.Level` directly and trusting it is how a corrupted profile
--   turns into a NaN in the UI.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.

-- local Bases = require(game:GetService('ReplicatedStorage').Config.World.Bases)
-- local Prompts = require(game:GetService('ReplicatedStorage').Config.World.Prompts)
-- local Progression = require(game:GetService('ReplicatedStorage').Config.Creatures.Progression)
-- local Security = require(game:GetService('ReplicatedStorage').Config.Systems.Security)
-- InventoryConfig.SlotsPerBase = Bases.Slots.Count
-- InventoryConfig.SlotSize = Bases.Slots.Size
-- InventoryConfig.MaxLevel = Progression.MaxLevel
-- InventoryConfig.RequestThrottleSeconds = Security.RequestThrottleSeconds

return table.freeze(InventoryConfig)
