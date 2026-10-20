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
	Rarity
	============
	Defines the rarity tiers used by both Eggs (which spawn
	weighted toward the common end) and Animals (which inherit
	their rarity from the Egg they came from).

	Spec §22-§24, §33-§37.

	The `Rarity` enum is re-exported here so callers do not need to
	require the Types module just to compare two rarity strings.
]]

local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)

local RarityDefs = {}

-- Display order, common -> rarest. Used by UIs that list animals
-- and by catalog sort.
RarityDefs.Order = {
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
RarityDefs.RarityColor = {
	[Rarity.Common] = Color3.fromRGB(255, 255, 255),
	[Rarity.Uncommon] = Color3.fromRGB(80, 200, 120),
	[Rarity.Rare] = Color3.fromRGB(0, 166, 255),
	[Rarity.Epic] = Color3.fromRGB(191, 0, 255),
	[Rarity.Mythic] = Color3.fromRGB(255, 0, 4),
	[Rarity.Legendary] = Color3.fromRGB(255, 247, 0),
	[Rarity.Divine] = Color3.fromRGB(105, 255, 140),
	[Rarity.Secret] = Color3.fromRGB(255, 255, 255),
}

-- Human-readable Egg display name per rarity. Set on
-- the lucky egg Model.Name at spawn time so the Explorer
-- shows a friendly name (e.g. "Epic Egg") instead of
-- the internal uniqueId. The animal equivalent is
-- `def.displayName` from AnimalConfig.
RarityDefs.RarityDisplayName = {
	[Rarity.Common] = 'Common Egg',
	[Rarity.Uncommon] = 'Uncommon Egg',
	[Rarity.Rare] = 'Rare Egg',
	[Rarity.Epic] = 'Epic Egg',
	[Rarity.Mythic] = 'Mythic Egg',
	[Rarity.Legendary] = 'Legendary Egg',
	[Rarity.Divine] = 'Divine Egg',
	[Rarity.Secret] = 'Secret Egg',
}

-- Spawn weight per rarity for the NORMAL automatic center
-- roll (EggConfig.CenterSpawnRarityWeights aliases this
-- table). These are the weights for which rarity a *center
-- Egg* spawns with — the hatch roll uses the separate,
-- more granular EggConfig.HatchRollWeights table.
--
-- Tuned so Common dominates, Legendary is rare (~2%), and
-- Mythic is extremely rare (~0.2%: hours of play without a
-- natural sighting). Divine and Secret are 0 — they NEVER
-- appear in the normal roll (admin/special systems spawn them
-- explicitly). Spec §22: "rarity drops weighted toward common".
RarityDefs.SpawnWeight = {
	[Rarity.Common] = 38,
	[Rarity.Uncommon] = 27,
	[Rarity.Rare] = 19,
	[Rarity.Epic] = 13.8,
	[Rarity.Legendary] = 2,
	[Rarity.Mythic] = 0.2,
	[Rarity.Divine] = 0,
	[Rarity.Secret] = 0,
}

-- Server Luck curve: normal-roll weight multiplier per pool
-- tier is luck^(tierIndex / LuckExponentDivisor), where the
-- tier index follows the design pool order
-- Common(0) … Mythic(5). luck=1x is the identity (baseline
-- above). Higher luck progressively favors rarer tiers while
-- keeping Mythic a chase even at 4x (~1%); Divine/Secret
-- weights stay exactly 0 at any luck. Designers rebalance via
-- SpawnWeight; this divisor shapes the luck curve itself.
RarityDefs.LuckExponentDivisor = 3

-- Animal level tier per rarity. Spec §37: each rarity tier sets
-- a base level (1..8) before any in-game growth mechanic. Phase 1
-- doesn't add growth, so level is purely cosmetic for now.
RarityDefs.BaseLevel = {
	[Rarity.Common] = 1,
	[Rarity.Uncommon] = 2,
	[Rarity.Rare] = 3,
	[Rarity.Epic] = 4,
	[Rarity.Mythic] = 5,
	[Rarity.Legendary] = 6,
	[Rarity.Divine] = 7,
	[Rarity.Secret] = 8,
}

return table.freeze(RarityDefs)
