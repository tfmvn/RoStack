--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Movement: locomotion feel (root) + avatar tunables (Movement.Player).
--[[
	Movement
	==============
	Single source of truth for locomotion FEEL: yaw smoothing shared
	by all three walkers, animal walk cadence, egg-flight walk-cycle
	rhythm, and stand idle-loop cadence.

	WHAT THIS CONTROLS
	------------------
	How movement LOOKS: turn responsiveness, leg-cadence matching,
	flight rhythm, idle-loop rate. Path ROUTES (agent params,
	waypoints, steering math) stay in PathfindingUtil / controllers;
	speeds stay in AnimalConfig.MovementSpeed (animals) and
	EggConfig (flight durations); only the FEEL knobs live here.

	YAW SMOOTHING (why one value three times)
	----------------------------------------
	WalkController, FlightController, and PathfindingUtil each had
	`YawSmoothing = 8.0` with the same comment (1 - exp(-k*dt),
	converges ~0.4s). One value here; all three read it. Public
	fields (`WalkController.YawSmoothing`, …) remain writable for
	tests but initialize from this module.

	Units: smoothing factors are exponential rates (higher = snappier);
	durations seconds; distances studs.
]]

local Movement = {}

-- --- Shared yaw ------------------------------------------------------------------

-- Critically-damped turn rate used by animal walks, egg flights,
-- and pathfinding yaw helpers. CURRENT: 8.0.
Movement.YawSmoothing = 8.0

-- --- Animal walk (WalkController) -----------------------------------------------------

Movement.AnimalWalk = {
	-- The walk animation was authored assuming this base movement
	-- speed; playback scales by actualSpeed / AnimationBaseSpeed.
	-- CURRENT: 10 (= AnimalConfig.MovementSpeed, so 1.0x at cruise).
	-- If MovementSpeed is retuned, retune this together or cadence
	-- drifts from travel rate.
	AnimationBaseSpeed = 10,
	-- Wall-clock cap padding for the deterministic walk (fires only
	-- if the Heartbeat connection itself is lost). CURRENT: 2s.
	-- Safety bound, not feel.
	WallClockPadding = 2,
}

-- --- Egg flight walk-cycle (FlightController) ---------------------------------------------

Movement.EggFlight = {
	-- Safety rail: navmesh spikes can never lift the egg more than
	-- this above its launch ground. CURRENT: 2 studs.
	MaxClimbAboveStart = 2,
	-- Hop scaler from model height: clamp(h / Divisor, Min, Max).
	-- CURRENT: h/4, [0.7, 1.25].
	WalkSizeDivisor = 4,
	WalkSizeMin = 0.7,
	WalkSizeMax = 1.25,
	-- Speed EMA: keep * old + gain * instantaneous. CURRENT: 0.9/0.1.
	SpeedEmaKeep = 0.9,
	SpeedEmaGain = 0.1,
	-- Last 7% of flight settles the blend at SettleRate so arrival
	-- lands at rest. CURRENT: threshold 0.93, rate 8.
	SettleThreshold = 0.93,
	SettleRate = 8,
	-- Travel-debug sample cadence (fraction of flight). CURRENT: 0.25.
	SampleInterval = 0.25,
	-- PathfindingService agent parameters for egg flights. Same
	-- obstacle-aware behavior as the legacy EggService; differs
	-- from the animal agent (smaller body). CURRENT: 3/6/no-jump.
	AgentRadius = 3,
	AgentHeight = 6,
	AgentCanJump = false,
	AgentCanClimb = false,
	WaypointSpacing = 6,
	-- Heartbeat tick cap per flight: a flight running longer is
	-- considered stuck and force-stopped. At 60Hz, 30s = 1800
	-- ticks — generous for normal flights, tight for failures.
	-- CURRENT: 1800. Safety bound, not feel.
	FlightMaxTicks = 60 * 30,
}

-- --- Stand idle loop (StandPresentation) ------------------------------------------------------

Movement.StandIdle = {
	-- Whole-registry tick rate (Hz). Idle motion is ~0.45Hz, so
	-- 30Hz sampling is smooth while keeping replication bounded.
	-- CURRENT: 30.
	TickRate = 30,
	-- PivotTo deadband: skip the CFrame write when neither height
	-- nor lean moved enough to see (~1/3 of ticks near extrema).
	-- CURRENT: 0.004 / 0.004.
	PoseEpsilon = 0.004,
	LeanEpsilon = 0.004,
}

function Movement.Validate(): { string }
	local issues: { string } = {}
	if type(Movement.YawSmoothing) ~= 'number' or Movement.YawSmoothing <= 0 then
		issues[#issues + 1] = 'YawSmoothing must be a number > 0'
	end
	if type(Movement.AnimalWalk.AnimationBaseSpeed) ~= 'number' or Movement.AnimalWalk.AnimationBaseSpeed <= 0 then
		issues[#issues + 1] = 'AnimalWalk.AnimationBaseSpeed must be a number > 0'
	end
	if type(Movement.EggFlight.MaxClimbAboveStart) ~= 'number' or Movement.EggFlight.MaxClimbAboveStart < 0 then
		issues[#issues + 1] = 'EggFlight.MaxClimbAboveStart must be a number >= 0'
	end
	if type(Movement.StandIdle.TickRate) ~= 'number' or Movement.StandIdle.TickRate <= 0 then
		issues[#issues + 1] = 'StandIdle.TickRate must be a number > 0'
	end
	return issues
end

-- --- Avatar tunables (former PlayerConfig) ---
-- Default WalkSpeed. CURRENT: 20 (spec baseline; comment once said 16).
-- Type: number > 0.
Movement.Player = {
	WalkSpeed = 20,
	JumpPower = 50,
}

function Movement.Player.Validate(): { string }
	local issues: { string } = {}
	if type(Movement.Player.WalkSpeed) ~= 'number' or Movement.Player.WalkSpeed <= 0 then
		issues[#issues + 1] = 'WalkSpeed must be a number > 0'
	end
	if type(Movement.Player.JumpPower) ~= 'number' or Movement.Player.JumpPower < 0 then
		issues[#issues + 1] = 'JumpPower must be a number >= 0'
	end
	return issues
end

table.freeze(Movement.Player)

return table.freeze(Movement)
