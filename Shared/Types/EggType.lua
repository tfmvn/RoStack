--!strict
--[[
	EggType
	=============
	States for an Egg from the moment it spawns in the center
	until the moment it is consumed (an animal is created from it).

	Spec §19-§27.
]]

local EggState = {
	Available = 'Available', -- alive in the center, no owner
	Traveling = 'Traveling', -- purchased, on its way to a slot
	Placed = 'Placed', -- arrived at a slot, waiting to be opened
	Opening = 'Opening', -- the open action is being processed
	Consumed = 'Consumed', -- an animal was created, egg is gone
}

export type EggState = 'Available' | 'Traveling' | 'Placed' | 'Opening' | 'Consumed'

export type Egg = {
	uniqueId: string, -- server-issued UUID, used as the public handle
	rarity: string, -- Rarity enum value
	price: number, -- in-game cash
	state: EggState,
	ownerUserId: number?, -- nil until purchased
	slotId: string?, -- set when placed
	-- visual: server-side Model. Created by EggService.
	model: Model?,
	-- Cached center-area CFrame (set on spawn).
	centerCFrame: CFrame?,
	_mutex: boolean,
	spawnedAt: number, -- os.clock() at spawn
}

return {
	State = table.freeze(EggState),
}
