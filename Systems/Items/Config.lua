--!strict
--[[
	Items — consolidated tunables
	==============================

	A single, documented view of every value the Items system reads.
	The authoritative copies live in the two config modules below; this
	file is a CONSOLIDATION, not a replacement. Copy any value you
	change back into the module that owns it, or replace the two
	`require` calls at the bottom with your own modules and delete the
	local copies.

	Owning modules (the authoritative source of truth):
	  * ReplicatedStorage.Config.Economy.Gear   -- the gear catalogue
	  * ReplicatedStorage.Config.World.Prompts  -- the shop prompt

	Not owned here (owned elsewhere, referenced only):
	  * Combat tuning for each bat -- Gear.Combat (per-bat blocks)
	  * Economy.Money.* -- what the wallet can pay
	  * Rebirth.Rebirth.* -- the rebirth ladder the lock checks read

	Every value below carries: default, meaning, valid range,
	whether it is safe to change, which module reads it, and
	whether it is a placeholder.
]]

local ItemsConfig = {}

-- =========================================================================
-- The gear catalogue
-- =========================================================================
--
-- Ten entries, a strict price-and-rebirth ladder. The catalogue is
-- CONTENT: the shape is portable, the specific gear is this game's.
-- Every `Description` in the source catalogue is a PLACEHOLDER string
-- ("PLACEHOLDER: run faster while held."), because the gear's real
-- behaviour is not implemented — the bats carry their tuning in
-- `Gear.Combat`, and the coils have no effect yet.
--
-- `Price` is a BigNumber decimal STRING, never a Lua number.
-- `RequiredRebirth` is the rebirth count at which the gear unlocks.
-- `ToolName` is the name of the Studio-authored Tool that must exist
-- in `ServerStorage` for the gear to be grantable. If the tool is
-- missing, the gear is still sold but cannot be equipped.

ItemsConfig.Catalogue = {
	{ Id = 'SpeedCoil', Name = 'Speed Coil', Price = '500', RequiredRebirth = 0, ToolName = 'Speed Coil' },
	{ Id = 'SilverBat', Name = 'Silver Bat', Price = '1000', RequiredRebirth = 0, ToolName = 'Silver Bat' },
	{ Id = 'GravityCoil', Name = 'Gravity Coil', Price = '5000', RequiredRebirth = 1, ToolName = 'Gravity Coil' },
	{ Id = 'GoldBat', Name = 'Gold Bat', Price = '7500', RequiredRebirth = 1, ToolName = 'Gold Bat' },
	{ Id = 'CoilCombo', Name = 'Coil Combo', Price = '20000', RequiredRebirth = 2, ToolName = 'Coil Combo' },
	{ Id = 'DiamondBat', Name = 'Diamond Bat', Price = '25000', RequiredRebirth = 2, ToolName = 'Diamond Bat' },
	{ Id = 'ObsidianBat', Name = 'Obsidian Bat', Price = '30000', RequiredRebirth = 3, ToolName = 'Obsidian Bat' },
	{ Id = 'CrystalBat', Name = 'Crystal Bat', Price = '50000', RequiredRebirth = 4, ToolName = 'Crystal Bat' },
	{
		Id = 'InvisibleCloak',
		Name = 'Invisible Cloak',
		Price = '55000',
		RequiredRebirth = 4,
		ToolName = 'Invisible Cloak',
	},
	{ Id = 'HackerBat', Name = 'Hacker Bat', Price = '70000', RequiredRebirth = 5, ToolName = 'Hacker Bat' },
}

-- =========================================================================
-- Catalogue invariants
-- =========================================================================

-- The catalogue must be sorted by ascending price.
-- Default: true
-- Meaning: `GearShopService` presents the catalogue in list order, and
--   the client does not re-sort. An unsorted catalogue shows gear out
--   of price order, which reads as a bug to the player.
-- Valid range: boolean.
-- Safe to change: NO -- not a live toggle. If you reorder the
--   catalogue, re-sort it yourself. This flag is documentation, not
--   a mechanism.
-- Read by: nobody at runtime; enforced by `Gear.ValidateLive`.
-- Placeholder: NO -- describes a real, enforced invariant.
ItemsConfig.RequirePriceOrder = true

-- =========================================================================
-- The gear shop prompt
-- =========================================================================

-- The text on the shop's ProximityPrompt.
-- Default: 'Open Gear Shop'
-- Meaning: the prompt label a player sees when they walk up to the
--   gear shop.
-- Valid range: any string.
-- Safe to change: YES -- presentation only.
-- Read by: Prompts.GearShop.ActionText.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ShopPromptText = 'Open Gear Shop'

-- How long the prompt must be held, in seconds.
-- Default: 0
-- Meaning: 0 means a TAP opens the shop. A positive value requires a
--   deliberate hold, which stops accidental opens when the player is
--   running past.
-- Valid range: number >= 0.
-- Safe to change: YES -- presentation only.
-- Read by: Prompts.GearShop.HoldDuration.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ShopPromptHoldSeconds = 0

-- How close the player must be, in studs, for the prompt to work.
-- Default: 12
-- Meaning: the prompt's activation range.
-- Valid range: number > 0.
-- Safe to change: YES -- presentation only.
-- Read by: Prompts.GearShop.MaxActivationDistance.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ShopPromptMaxDistance = 12

-- Whether the prompt requires line of sight to the shop.
-- Default: false
-- Meaning: when true, the player must actually be looking at the shop
--   to trigger it. `false` means standing near it is enough.
-- Valid range: boolean.
-- Safe to change: YES -- presentation only.
-- Read by: Prompts.GearShop.RequiresLineOfSight.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ShopPromptRequiresLineOfSight = false

-- =========================================================================
-- Shop preview framing
-- =========================================================================

-- The preview camera distance as a multiple of the model's bounding box.
-- Default: 1.4
-- Meaning: the shop's 3-D preview frames each gear model at
--   `max(boundingBoxSize * DistanceFactor, MinDistance)` studs.
-- Valid range: number > 0.
-- Safe to change: YES -- presentation only.
-- Read by: Gear.Viewport.DistanceFactor.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ViewportDistanceFactor = 1.4

-- The minimum preview camera distance, in studs.
-- Default: 2
-- Meaning: the floor on the preview distance, so a very small model
--   is not clipped by the near plane.
-- Valid range: number >= 0.
-- Safe to change: YES -- presentation only.
-- Read by: Gear.Viewport.MinDistance.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ViewportMinDistance = 2

-- The direction the preview camera looks from.
-- Default: Vector3.new(1, 0.6, 1.6)
-- Meaning: the offset direction, from the model centre, that the
--   preview camera sits along. A three-quarter view.
-- Valid range: any Vector3 (ideally normalised, but the preview
--   normalises it itself).
-- Safe to change: YES -- presentation only.
-- Read by: Gear.Viewport.Direction.
-- Placeholder: NO -- a real, tuned value.
ItemsConfig.ViewportDirection = Vector3.new(1, 0.6, 1.6)

-- =========================================================================
-- INVARIANTS
-- =========================================================================
--
-- * `Gear.ValidateLive()` is the real check. It verifies that every
--   entry's `Id` is unique, that every `Price` parses as a BigNumber
--   decimal string, that `RequiredRebirth` is a non-negative integer,
--   and that each `ToolName` resolves to a Tool in `ServerStorage`.
--   `ConfigValidator` calls it at boot. Do not hand-roll a second
--   validation path.
--
-- * `Gear.IsLocked(playerRebirth, required)` returns true when the
--   player's rebirth count is BELOW `RequiredRebirth`. A gear with
--   `RequiredRebirth = 0` is never locked.
--
-- * `Gear.FindGear(id)` is the only lookup. `Gear.GetAll()` returns
--   the live catalogue table; do not mutate it.

-- =========================================================================
-- Optional: wire this file to the authoritative modules
-- =========================================================================
--
-- Uncomment to make this consolidation the live source of truth. The
-- defaults above are the current live values, so switching over is a
-- no-op until you edit something.

-- local Gear = require(game:GetService('ReplicatedStorage').Config.Economy.Gear)
-- local Prompts = require(game:GetService('ReplicatedStorage').Config.World.Prompts)
-- ItemsConfig.Catalogue = Gear.GetAll()
-- ItemsConfig.ShopPromptText = Prompts.GearShop.ActionText
-- ItemsConfig.ShopPromptHoldSeconds = Prompts.GearShop.HoldDuration
-- ItemsConfig.ShopPromptMaxDistance = Prompts.GearShop.MaxActivationDistance
-- ItemsConfig.ShopPromptRequiresLineOfSight = Prompts.GearShop.RequiresLineOfSight
-- ItemsConfig.ViewportDistanceFactor = Gear.Viewport.DistanceFactor
-- ItemsConfig.ViewportMinDistance = Gear.Viewport.MinDistance
-- ItemsConfig.ViewportDirection = Gear.Viewport.Direction

return table.freeze(ItemsConfig)
