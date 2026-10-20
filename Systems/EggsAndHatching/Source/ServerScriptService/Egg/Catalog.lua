--!strict
--!native
--[[
	Egg.Catalog
	==================
	The shape of a "EggDefinition" — what the SpawnService
	receives from any caller (auto-spawn, admin spawn, persistence
	rejoin) and what it uses to populate an egg record.

	Phase 2. The egg record itself is just a plain table; the
	SpawnService is the single authority that creates one. The
	fields here are documented for the benefit of every caller
	and the tests.

	The `origin` field tells the spawn service which caller is
	asking. The behavior is:

	  * 'Automatic' — center-spawn loop, applies the cap.
	  * 'Admin'     — admin command, applies the cap.
	  * 'Persistence' — rejoin restoration, NO cap, jumps
	                    straight to Placed state at a given slot.
	  * 'Test'      — test-only path, applies the cap.

	No `bypassCap` field. If a future feature needs to bypass the
	cap, add the field then (YAGNI now).
]]

local Catalog = {}

-- --- Origin enum ------------------------------------------------

Catalog.Origin = table.freeze({
	Automatic = 'Automatic',
	Admin = 'Admin',
	Persistence = 'Persistence',
	Test = 'Test',
})

-- --- Definition shape ------------------------------------------

export type Origin = 'Automatic' | 'Admin' | 'Persistence' | 'Test'

export type Definition = {
	rarity: string, -- Rarity enum value
	price: number, -- in-game cash; 0 for admin-spawned
}

export type Request = {
	definition: Definition,
	origin: Origin,
	-- Persistence-only: skip center, jump straight to Placed at
	-- this slot. The SpawnService is the single source of truth
	-- for what "Placed at slot X" means.
	targetSlot: any?,
	-- Test/admin-only: a fixed XZ on the ring (else random).
	xz: Vector2?,
	-- Admin only: which admin triggered this (for the audit log).
	adminUserId: number?,
}

-- --- Helpers ----------------------------------------------------

-- Validate that a value is a well-formed Definition. Returns
-- (true, nil) on success or (false, errMessage) on failure.
-- Used by SpawnService.Request as the first gate.
function Catalog.ValidateDefinition(value: any): (boolean, string?)
	if typeof(value) ~= 'table' then
		return false, 'definition must be a table'
	end
	if typeof(value.rarity) ~= 'string' then
		return false, 'definition.rarity must be a string'
	end
	if typeof(value.price) ~= 'number' then
		return false, 'definition.price must be a number'
	end
	if value.price < 0 then
		return false, 'definition.price must be non-negative'
	end
	return true, nil
end

-- Validate that an origin is one of the four known values.
function Catalog.ValidateOrigin(value: any): (boolean, string?)
	if typeof(value) ~= 'string' then
		return false, 'origin must be a string'
	end
	if value ~= 'Automatic' and value ~= 'Admin' and value ~= 'Persistence' and value ~= 'Test' then
		return false, 'origin must be Automatic, Admin, Persistence, or Test'
	end
	return true, nil
end

return table.freeze(Catalog)
