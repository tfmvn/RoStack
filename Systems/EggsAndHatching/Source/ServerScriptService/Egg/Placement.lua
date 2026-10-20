--!strict
--!native
--[[
	Egg.Placement
	====================
	Overlap-free XZ sampling on the center ring. The auto-spawn
	loop and the admin spawn command both call `PickXZ` to find
	a position for a new egg. The new SpawnService is the only
	caller in production; the admin / test paths go through it
	too.

	Strategy (3 phases, in order):
	  1. Random retries on the configured ring (up to 20
	     attempts). For a 10-egg cap on a 20-stud ring with
	     7-stud min spacing, most picks resolve here.
	  2. Deterministic spiral fallback. Start at minSpacing from
	     the center, walk outward in minSpacing/2 increments
	     until a non-overlapping candidate is found. Provably
	     solvable in O(minSpacing * cap) attempts.
	  3. Last resort: accept any spot on the configured ring,
	     even if it overlaps. Better to spawn two close eggs
	     than to never fill the arena.

	`IsFarFromAll` is exposed for the tests (so the spiral
	fallback can be exercised deterministically by populating
	the existing list).
]]

local Constants = require(script.Parent.Constants)

local Placement = {}

-- --- Constants --------------------------------------------------

local Security = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Security)
local MAX_RANDOM_ATTEMPTS = Security.Placement.MaxRandomAttempts
local SPIRAL_STEP = Constants.EggMinSpawnSpacing / 2
local MAX_SPIRAL_RADIUS_MULT = Security.Placement.MaxSpiralRadiusMult -- spiral out to 2x the ring radius

-- --- IsFarFromAll -----------------------------------------------

-- True if the candidate XZ is at least `minSpacing` studs from
-- every existing egg. Used by PickXZ and by the tests.
function Placement.IsFarFromAll(candidate: Vector2, existingBlocks: { any }, minSpacing: number): boolean
	for _, b in ipairs(existingBlocks) do
		-- Each egg has a `centerCFrame` set on spawn; we read
		-- its XZ. Blocks without a centerCFrame (e.g. just-spawned
		-- persistence records that haven't been placed yet) are
		-- skipped — they don't occupy a center spot.
		if b.centerCFrame and typeof(b.centerCFrame) == 'CFrame' then
			local dx = b.centerCFrame.X - candidate.X
			local dz = b.centerCFrame.Z - candidate.Y
			local d2 = dx * dx + dz * dz
			if d2 < minSpacing * minSpacing then
				return false
			end
		end
	end
	return true
end

-- --- PickXZ -----------------------------------------------------

-- Returns a Vector2 (XZ) on the ring that satisfies the spacing
-- constraint against every existing egg. May fall back to the
-- last-resort ring spot if both random and spiral strategies
-- fail (very unlikely with the default cap=10 and radius=20).
function Placement.PickXZ(existingBlocks: { any }, radius: number, minSpacing: number): Vector2
	-- Phase 1: random retries.
	local attempts = 0
	while attempts < MAX_RANDOM_ATTEMPTS do
		local angle = Random.new():NextNumber() * math.pi * 2
		local candidate = Vector2.new(math.cos(angle) * radius, math.sin(angle) * radius)
		if Placement.IsFarFromAll(candidate, existingBlocks, minSpacing) then
			return candidate
		end
		attempts += 1
	end

	-- Phase 2: deterministic spiral outward from the center.
	-- Start at minSpacing (so we're already clear of the center)
	-- and walk outward in SPIRAL_STEP increments. The angle at
	-- each step is randomized so successive calls don't fall on
	-- the same radial line.
	local r = minSpacing
	while r < radius * MAX_SPIRAL_RADIUS_MULT do
		local angle = Random.new():NextNumber() * math.pi * 2
		local candidate = Vector2.new(math.cos(angle) * r, math.sin(angle) * r)
		if Placement.IsFarFromAll(candidate, existingBlocks, minSpacing) then
			return candidate
		end
		r += SPIRAL_STEP
	end

	-- Phase 3: last-resort ring spot. Even if this overlaps
	-- an existing egg, it's better than never filling the
	-- arena. SpawnService is responsible for warning when this
	-- branch fires.
	local angle = Random.new():NextNumber() * math.pi * 2
	return Vector2.new(math.cos(angle) * radius, math.sin(angle) * radius)
end

-- --- PickXZAt (admin override) ---------------------------------

-- Pick a specific XZ if one is provided (admin spawn), else fall
-- back to PickXZ. This is a thin wrapper so the SpawnService
-- stays symmetric across all origins.
function Placement.PickXZAt(existingBlocks: { any }, xz: Vector2?, radius: number, minSpacing: number): Vector2
	if xz and Placement.IsFarFromAll(xz, existingBlocks, minSpacing) then
		return xz
	end
	return Placement.PickXZ(existingBlocks, radius, minSpacing)
end

return table.freeze(Placement)
