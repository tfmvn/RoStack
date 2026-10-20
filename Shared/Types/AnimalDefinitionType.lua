--!strict
--[[
 	AnimalDefinitionType
 	======================
 	The static catalog entry. The catalog itself lives in
	AnimalConfig.lua; this file is the *shape* of a single entry.

	Spec §33-§37.
]]

export type AnimalDefinition = {
	definitionId: string, -- e.g. "Common_Skibbidi1"
	displayName: string, -- shown in HUD
	rarity: string, -- Rarity enum
	baseHealth: number, -- legacy pre-2.5 stat input; the documented derivation source of AnimalConfig.Stats Base values (Level-derived stats since Phase 2.5)
	baseDamage: number, -- legacy pre-2.5 stat input; the documented derivation source of AnimalConfig.Stats Base values (Level-derived stats since Phase 2.5)
}
