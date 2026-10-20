--!strict
--!native
--[[
	PathfindingUtil
	===============
	Shared pathfinding helpers used by Animal.WalkController
	and (potentially) future walker systems.

	What lives here:
	  * AgentParams — the pathfinder agent defaults
	    (AgentRadius, AgentHeight, AgentCanJump, etc.)
	  * YawSmoothing — the yaw smoothing factor
	    (1 - exp(-YawSmoothing * dt))
	  * MaxWalkSeconds — backwards-compat constant kept for any
	    external callers
	  * ShortestAngleDelta — shortest-path angle delta for
	    smoothing yaw across ±pi

	Agent params (2026-09-05 rework):
	  * AgentRadius 4 (was 2) — matches the actual animal
	    model footprint. A 2-stud agent treats the animal as
	    a thin pillar and the pathfinder routes it through
	    gaps the model physically can't fit through, then the
	    walk visibly clips into walls.
	  * AgentHeight 5 (was 5) — fine.
	  * AgentCanJump = false (was true). With CanJump=true the
	    pathfinder takes 4-stud "jump" links to traverse small
	    Y gaps, producing sideways-then-up approaches. The
	    animal is on the ground and should route over ramps
	    and stairs, not jump links. If a gap is non-traversable
	    without a jump, the pathfinder should refuse and we
	    fall through to the teleport-arrive path.
	  * WaypointSpacing 6 (was 4). Slightly larger so the
	    polyline is shorter, and our LOS-simplification in
	    WalkController can drop more redundant interior
	    waypoints.
]]

local PathfindingUtil = {}

-- --- Tunables ----------------------------------------------------

-- Path agent parameters. Animal model footprint is
-- approximately 4×5×2 studs; we use AgentRadius=4 so the
-- pathfinder routes around the actual model rather than
-- threading it through gaps a thin agent could squeeze
-- through but the model can't.
PathfindingUtil.AgentParams = {
	AgentRadius = 4,
	AgentHeight = 5,
	AgentCanJump = false,
	AgentCanClimb = false,
	WaypointSpacing = 6,
}

-- Smoothing factor for yaw rotation. Higher = the model snaps
-- to the segment direction faster; lower = it lags more behind
-- the path. 1 - exp(-8 * dt) gives a critically-damped feel
-- that converges in ~0.4 seconds without oscillating.
-- Canonical: ReplicatedStorage.Config.MovementConfig.YawSmoothing
-- (shared with animal walks + egg flights). Assigned at load so
-- all three systems turn identically; tests may still override
-- this field per-case.
PathfindingUtil.YawSmoothing = require(game:GetService('ReplicatedStorage').Config.World.Movement).YawSmoothing

-- Backwards-compat constant. No longer used by the walker
-- itself (which uses a duration-based cap), but kept so
-- external callers don't break.
PathfindingUtil.MaxWalkSeconds = 60

-- --- Helpers -----------------------------------------------------

-- Normalize an angle to (-pi, pi]. Used to take the shortest
-- path between two yaws (avoids the "spin the long way around"
-- bug when the delta crosses ±pi).
function PathfindingUtil.ShortestAngleDelta(from: number, to: number): number
	local delta = (to - from) % (2 * math.pi)
	if delta > math.pi then
		delta = delta - 2 * math.pi
	end
	return delta
end

return table.freeze(PathfindingUtil)
