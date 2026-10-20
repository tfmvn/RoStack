--!strict
--[[
	AnimalType
	============
	Server-authoritative record for a single, owned animal.

	Static *definitions* (the catalog) live in AnimalConfig.lua —
	AnimalType only describes the runtime instance.
]]

-- Carry state (Phase 1.5). Slotted is the resting state on a
-- animal slot. Carried is between Grab and Place — the animal
-- follows the player via CarryController. Recovering is transient:
-- the animal has no slot to return to (e.g. base was released
-- mid-carry) and is parked under Workspace.Animals.Recovering
-- until an empty slot becomes available.
export type CarryState = 'Slotted' | 'Carried' | 'Recovering'

export type Animal = {
	uniqueId: string, -- server-issued UUID
	definitionId: string,
	displayName: string,
	rarity: string, -- Rarity enum
	ownerUserId: number,
	-- Current resting slot. Phase 2: the unified slot id (e.g.
	-- `p7:<userId>:slot:3`). nil when Carried.
	slotId: string?,
	-- Phase 2: kept for back-compat. The unified slot id of the
	-- slot the animal originated from (was an Egg's slot
	-- at the time of the roll). May be nil for animals that
	-- didn't come from an Egg.
	spawnSlotId: string?,
	level: number,
	health: number,
	damage: number,
	-- Visual: server-side Model. Created on walk completion.
	model: Model?,
	-- Internal: walking transient state, set between creation and arrival.
	walkingFrom: Vector3?,
	walkingTo: Vector3?,
	-- Carry state (Phase 1.5). Defaults to 'Slotted' on existing records.
	state: CarryState,
	-- The userId of the player currently carrying this animal.
	-- Only set when state = 'Carried'.
	carriedBy: number?,
	-- The unified slot the animal was occupying when grabbed.
	-- Used as the fallback target on disconnect/death recovery
	-- (the persisted record is unchanged during carry, so on
	-- rejoin the animal respawns at originalSlotId via
	-- SpawnFromPersistence). Phase 2: the slot will be in state
	-- Reserved (not Empty) thanks to the Demote transition on
	-- grab, so the recovery path calls OccupySlot directly.
	originalSlotId: string?,
	_mutex: boolean,
	createdAt: number,
}
