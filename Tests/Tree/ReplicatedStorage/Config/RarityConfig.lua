--!strict
--[[
	RarityConfig
	============
	Defines the rarity tiers used by both Eggs (which spawn
	weighted toward the common end) and Animals (which inherit
	their rarity from the Egg they came from).

	Spec §22-§24, §33-§37.

	The `Rarity` enum is re-exported here so callers do not need to
	require the Types module just to compare two rarity strings.
]]

local Rarity = require(script.Parent.Parent.Types.RarityType)

local RarityConfig = {}

-- Display order, common -> rarest. Used by UIs that list animals
-- and by catalog sort.
RarityConfig.Order = {
	Rarity.Common,
	Rarity.Uncommon,
	Rarity.Rare,
	Rarity.Epic,
	Rarity.Mythic,
	Rarity.Legendary,
	Rarity.Divine,
	Rarity.Secret,
}

-- Display colors. Picked to be readable against Roblox's standard
-- white-grey UI. (Color3.new takes values 0..1.)
RarityConfig.RarityColor = {
	[Rarity.Common] = Color3.fromRGB(255, 255, 255),
	[Rarity.Uncommon] = Color3.fromRGB(80, 200, 120),
	[Rarity.Rare] = Color3.fromRGB(0, 166, 255),
	[Rarity.Epic] = Color3.fromRGB(191, 0, 255),
	[Rarity.Mythic] = Color3.fromRGB(255, 0, 4),
	[Rarity.Legendary] = Color3.fromRGB(255, 247, 0),
	[Rarity.Divine] = Color3.fromRGB(105, 255, 140),
	[Rarity.Secret] = Color3.fromRGB(1, 1, 1),
}

-- Human-readable Egg display name per rarity. Set on
-- the lucky egg Model.Name at spawn time so the Explorer
-- shows a friendly name (e.g. "Epic Egg") instead of
-- the internal uniqueId. The animal equivalent is
-- `def.displayName` from AnimalConfig.
RarityConfig.RarityDisplayName = {
	[Rarity.Common] = 'Common Egg',
	[Rarity.Uncommon] = 'Uncommon Egg',
	[Rarity.Rare] = 'Rare Egg',
	[Rarity.Epic] = 'Epic Egg',
	[Rarity.Mythic] = 'Mythic Egg',
	[Rarity.Legendary] = 'Legendary Egg',
	[Rarity.Divine] = 'Divine Egg',
	[Rarity.Secret] = 'Secret Egg',
}

-- Spawn weight per rarity, used by EggConfig.HatchRollWeights
-- and EggConfig.CenterSpawnRarityWeights. These are the
-- weights for which rarity a *Egg* spawns with — the animal
-- roll uses a separate, more granular table inside EggConfig.
--
-- Tuned so that the bottom 4 tiers dominate and Divine/Secret are
-- very rare. Spec §22: "rarity drops weighted toward common".
RarityConfig.SpawnWeight = {
	[Rarity.Common] = 35,
	[Rarity.Uncommon] = 25,
	[Rarity.Rare] = 18,
	[Rarity.Epic] = 12,
	[Rarity.Mythic] = 6,
	[Rarity.Legendary] = 3,
	[Rarity.Divine] = 0.8,
	[Rarity.Secret] = 0.2,
}

-- Animal level tier per rarity. Spec §37: each rarity tier sets
-- a base level (1..8) before any in-game growth mechanic. Phase 1
-- doesn't add growth, so level is purely cosmetic for now.
RarityConfig.BaseLevel = {
	[Rarity.Common] = 1,
	[Rarity.Uncommon] = 2,
	[Rarity.Rare] = 3,
	[Rarity.Epic] = 4,
	[Rarity.Mythic] = 5,
	[Rarity.Legendary] = 6,
	[Rarity.Divine] = 7,
	[Rarity.Secret] = 8,
}

return table.freeze(RarityConfig)
