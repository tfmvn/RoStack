--!strict
--[[
	RarityType
	==========
	The 8 rarity tiers for both Eggs and Animals.

	These strings are the canonical wire format. Server and client
	both use this module; never inline a tier name.
]]

local Rarity = {
	Common = 'Common',
	Uncommon = 'Uncommon',
	Rare = 'Rare',
	Epic = 'Epic',
	Mythic = 'Mythic',
	Legendary = 'Legendary',
	Divine = 'Divine',
	Secret = 'Secret',
}

export type RarityEnum = string

return table.freeze(Rarity)
