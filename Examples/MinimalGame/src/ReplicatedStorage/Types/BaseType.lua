--!strict
--[[
	BaseType
	========
	Defines the lifecycle states of a Base and the public record
	shape used across services.

	Phase 2: the base has a single `slots[1..SlotCount]` pool
	that can hold either an Egg or an Animal. There is
	no per-kind sub-pool.

	Spec §9-§13, §28 (Phase 1); Phase 2 §3-§5.
]]

local BaseState = {
	Available = 'Available', -- no owner, all slots free
	Reserved = 'Reserved', -- an owner is assigned but no eggs are present
	Occupied = 'Occupied', -- an owner is assigned and at least one slot is used
}

export type BaseState = 'Available' | 'Reserved' | 'Occupied'

-- Public record. `id` is "Base_<n>" with n in [1, BaseCount].
export type Base = {
	id: string,
	index: number,
	state: BaseState,
	ownerUserId: number?,
	spawnCFrame: CFrame,
	-- Unified slot pool. A base has exactly Bases.Slots.Count
	-- entries (1..SlotCount). Each slot can hold an Egg,
	-- an Animal, or be Empty. There is no separate lucky/animal
	-- sub-pool.
	slots: { [number]: any },
	_mutex: boolean,
	-- Single counter: number of slots currently in Occupied state
	-- (regardless of occupant kind). Replaces the prior per-kind
	-- counter pair.
	_occupiedCount: number,
}

-- Build the canonical id for a base by 1-based index.
local function BuildId(index: number): string
	assert(index >= 1 and index <= 99, 'Base index out of range')
	return string.format('Base_%d', index)
end

return {
	State = table.freeze(BaseState),
	BuildId = BuildId,
}
