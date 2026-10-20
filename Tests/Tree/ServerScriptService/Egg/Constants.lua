--!strict
--!native
--[[
	Egg.Constants
	===================
	Shared constants for the Egg module. Anything that more
	than one of the new sub-modules needs (state names, default
	values, magic numbers) lives here so we don't end up with
	duplicated literals across the file tree.

	The five egg states (Available, Traveling, Placed, Opening,
	Consumed) are the EggType.State values — this module
	re-exports them for convenience and adds a couple of
	controller-typed values used by the new movement controllers.

	Phase 5. The hover clearance and movement math use these
	directly so a designer changing one value updates everywhere.
	`HoverClearance` is a BOTTOM-FACE clearance; `HoverMath` is the
	only module that turns it into a centre Y.
]]

local EggType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.EggType)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local CenterSpawn = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)

local Constants = {}

-- --- Block states (re-exported for convenience) -----------------

Constants.State = EggType.State

-- --- Controller types -------------------------------------------

-- The movement controllers the architecture uses. The egg record
-- stores the active controller so cleanup paths can detect a stuck
-- controller and stop it deterministically.
--
-- There is deliberately no `Bob` type: an egg that is not moving
-- holds a constant hover height with NO controller at all
-- (`controller = nil`), parked there by `HoverMath.Settle`.
Constants.ControllerType = table.freeze({
	Flight = 'Flight', -- pathfind to the base's Collector (lucky egg)
	AnimalFlight = 'AnimalFlight', -- pathfind + last-15% approach (animal)
	Roll = 'Roll', -- 3D roulette / reveal animation (pre-CreateFromEgg)
})

-- --- Movement parameters (shortcuts) ----------------------------

-- Studs between the surface below the egg and the egg's
-- BOTTOM FACE. `HoverMath` turns this into a centre Y; never
-- add it to a Y directly.
Constants.HoverClearance = EggConfig.HoverClearance

Constants.EggSize = EggConfig.EggSize
Constants.Price = EggConfig.Price
Constants.HatchRollWeights = EggConfig.HatchRollWeights
Constants.CenterSpawnRarityWeights = EggConfig.CenterSpawnRarityWeights
Constants.RarityMaterial = EggConfig.RarityMaterial

Constants.EggTravelDuration = CenterSpawn.TravelDuration

-- Purchased-egg cruise speed (studs/s) + duration guards.
-- FlightController derives duration as distance / speed so a
-- cross-map delivery walks at a cute pace instead of sprinting
-- on a fixed 7s clock. EggTravelDuration is kept as legacy
-- tuning (unused by the flight path since the speed fix).
Constants.EggTravelSpeed = EggConfig.PurchasedTravelSpeed
Constants.EggTravelMinDuration = EggConfig.PurchasedTravelMinDuration
Constants.EggTravelMaxDuration = EggConfig.PurchasedTravelMaxDuration
Constants.EggCenterMax = CenterSpawn.CenterMax
Constants.EggMinSpawnSpacing = CenterSpawn.MinSpawnSpacing
Constants.CenterSpawnRadius = CenterSpawn.Radius
Constants.CenterSpawnInterval = CenterSpawn.Interval

-- --- Flight parameters -----------------------------------------
-- Canonical: MovementConfig.EggFlight (re-exported here so egg
-- subsystems keep a single `Constants` import; shape unchanged).

-- PathfindingService agent parameters. Same as the previous
-- EggService used; the new FlightController keeps the
-- same values so the obstacle-aware behavior is preserved.
local _EF = MovementConfig.EggFlight
Constants.FlightAgentParams = table.freeze({
	AgentRadius = _EF.AgentRadius,
	AgentHeight = _EF.AgentHeight,
	AgentCanJump = _EF.AgentCanJump,
	AgentCanClimb = _EF.AgentCanClimb,
	WaypointSpacing = _EF.WaypointSpacing,
})

-- Heartbeat tick cap. A single flight can't run more than this
-- many ticks before the model is considered stuck and the
-- controller is force-stopped. At 60Hz, 30s is 1800 ticks.
-- Generous enough to never fire on a normal flight but tight
-- enough to fail fast if the model gets stuck.
Constants.FlightMaxTicks = _EF.FlightMaxTicks

return table.freeze(Constants)
