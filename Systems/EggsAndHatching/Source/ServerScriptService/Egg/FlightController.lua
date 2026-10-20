--!strict
--!native
--[[
	Egg.FlightController
	===========================
	Drives an Egg from its current position to a
	destination CFrame over a distance-derived duration
	(distance / EggTravelSpeed, clamped), with a deterministic,
	time-based interpolation along a pathfinder polyline.

	The controller knows nothing about slots. It is handed a
	`destination` and an `onArrive` callback, and its whole job
	is to be at `destination.cframe` when the clock says the
	flight is over. For lucky eggs the destination is the
	base's Collector and `onArrive` is
	`Base/CollectorArrival.OnArrival`, which resolves the
	landing slot and teleports the egg into it. That split is
	deliberate: the slot an egg lands in is decided ON ARRIVAL
	(the base may have changed during a 7-second flight), so
	baking a slot into the controller at launch would be wrong.

	Movement pattern (Phase 5):
	  * Path computed once via PathfindingService between the
	    FLOOR positions of start and destination, with ONE retry
	    on failure. The accepted polyline is sanitized once at
	    launch (non-finite points and consecutive duplicates
	    dropped — zero-length segments would make the arc-length
	    cursor 0/0 = NaN and teleport the egg). Only a double
	    pathfinder failure falls back to a two-point floor
	    polyline. Either way the polyline is a FLOOR polyline —
	    its Ys are surface Ys, never hover Ys. The path is never
	    recomputed mid-flight, so no generation token is needed:
	    the closure owns the one authoritative polyline.
  * Per Heartbeat:
      - t = (os.clock() - startedAt) / duration
      - Find the polyline segment the t cursor is on
        (cumulative arc length).
      - xz = lerp(waypoints[i], waypoints[i+1], segT)
      - floorY = lerp of the same two waypoints' Ys
      - y = HoverMath.HoverY(floorY, model) + walk lift
      - Yaw smoothly faces the segment direction
        (1 - exp(-8 * dt) critical damping, with
        FacingOffset for model convention).
      - Walk presentation (SHARED EggWalkAnimator — the exact
        same hop/lean/squash ambient eggs use): speed EMA from
        the arc-length cursor, composed into the single
        PivotTo. Last ~7% of flight settles the blend so the
        egg lands at rest; _onComplete restores exact scale.
      - PivotTo(model, CFrame at (xz.X, y, xz.Z) with
        smoothed yaw + walk lean).
	  * At t >= 1: stop, PivotTo(destination.cframe), and call
	    `onArrive(egg, controller)`.

  Why the Y is mostly flat:
  * The egg holds a CONSTANT clearance between its bottom
    face and the surface below it (ramps and multi-floor
    routes come from the waypoint Ys — see `HoverMath` and
    `EggConfig.HoverClearance`). The shared walk-cycle lift
    rides on top of that clearance; it never feeds steering
    and never accumulates.

	Why an unanchored egg doesn't drift:
	  * The egg is `Anchored = true` at all times. PivotTo
	    moves the cluster directly; no BodyMovers, no Humanoid,
	    no physics. The `model:Destroy()` is the only time the
	    cluster becomes physics-driven (and then it's gone).
]]

local PathfindingService = game:GetService('PathfindingService')
local RunService = game:GetService('RunService')

local Constants = require(script.Parent.Constants)
local HoverMath = require(script.Parent.HoverMath)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local EggWalkAnimator = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local PathfindingUtil = require(script.Parent.Parent.Utility.PathfindingUtil)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)

local FlightController = {}

-- --- Tunables --------------------------------------------------

-- Smoothing factor for yaw rotation. 1 - exp(-k * dt) gives
-- a critically-damped feel that converges in ~0.4 seconds
-- without oscillating. Canonical: MovementConfig.YawSmoothing
-- (shared with animal walks + pathfinding). Public for tests.
FlightController.YawSmoothing = MovementConfig.YawSmoothing

-- Safety rail: navmesh spikes can never lift the egg more
-- than this above its launch ground (the old collector-top
-- pull is the reason this exists). Legitimate terrain
-- following below the rail is untouched; arrival delivery
-- owns final placement regardless.
-- Canonical: MovementConfig.EggFlight.MaxClimbAboveStart.
local MAX_CLIMB_ABOVE_START = MovementConfig.EggFlight.MaxClimbAboveStart

-- Facing offset (radians) added to the atan2 yaw. The lucky
-- egg model is authored with the visual front on local +Z
-- (same convention as the animal models), so we add math.pi
-- to flip it 180° so the egg's visual front faces the
-- travel direction. If a future template is authored with
-- -Z as the front, set this back to 0.
FlightController.FacingOffset = math.pi

-- --- Path sanitization -------------------------------------------

-- Minimum steering segment length (studs). Consecutive
-- waypoints closer than this are duplicates for steering:
-- keeping them creates zero-length segments, and
-- (targetDist - acc) / 0 is 0/0 = NaN on exact boundary hits
-- (near-guaranteed at t ~= 0 when the pathfinder duplicates
-- the snapped start). NaN then poisons the interpolated
-- position and the egg teleports. The pathfinder emits
-- near-duplicates intermittently (snapped start, navmesh
-- seams), so every accepted polyline is cleaned ONCE at
-- launch — never per tick, never with randomness.
local SEG_EPSILON = 0.01

local function _isFiniteVec(v: any): boolean
	if typeof(v) ~= 'Vector3' then
		return false
	end
	if v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z then
		return false
	end
	if math.abs(v.X) == math.huge or math.abs(v.Y) == math.huge or math.abs(v.Z) == math.huge then
		return false
	end
	return true
end

-- Pure: clean a raw waypoint position list into a
-- steering-safe polyline. Drops non-finite points and
-- consecutive duplicates, guarantees >= 2 points (falls back
-- to {a, b} = the straight floor line). Deterministic: same
-- input, same output, no ambient input, no RNG.
function FlightController.SanitizePath(points: { Vector3 }, a: Vector3, b: Vector3): { Vector3 }
	local clean: { Vector3 } = {}
	for _, pt in ipairs(points) do
		if _isFiniteVec(pt) then
			local prev = clean[#clean]
			if prev == nil or (pt - prev).Magnitude >= SEG_EPSILON then
				clean[#clean + 1] = pt
			end
		end
	end
	if #clean < 2 then
		return { a, b }
	end
	return clean
end

-- --- Internal types --------------------------------------------

-- Where a flight ends.
--
-- `cframe` is the egg's HOVER CFrame at the destination (the
-- caller derives it through `HoverMath.HoverY`), while
-- `floorStart` / `floorEnd` are SURFACE Ys. Both are needed
-- because the traversal polyline lives at floor level and the
-- egg flies a fixed clearance above it.
export type FlightDestination = {
	cframe: CFrame,
	floorStart: number,
	floorEnd: number,
}

export type FlightController = {
	egg: any,
	startCFrame: CFrame,
	targetCFrame: CFrame,
	startPos: Vector3,
	endPos: Vector3,
	distance: number,
	duration: number,
	floorStart: number,
	floorEnd: number,
	stopped: boolean,
	aborted: boolean,
	connection: RBXScriptConnection?,
	onArrive: ((egg: any, controller: any) -> ())?,
	-- Shared walk-cycle presentation (EggWalkAnimator — the same
	-- animator ambient eggs use; nil on the degenerate path,
	-- which never poses). walkBaseScale is the model's own
	-- authored scale (exact-restore target); walkLastScale is
	-- the quantized-apply cursor; nominal/EMA/dist drive the
	-- speed-scaled rhythm; sizeFactor caches hop-to-height.
	walk: any,
	walkBaseScale: number,
	walkLastScale: number?,
	walkNominalSpeed: number,
	walkSpeedEma: number,
	walkLastDist: number,
	walkSizeFactor: number,
	-- Ambient-style ground offset (pivot-to-bottom, SAME helper
	-- roaming eggs use): travel Y = floorY + this + walk lift,
	-- i.e. bottom face ON the ground like a roaming egg — never
	-- the +3 hover clearance and never the Collector's Y.
	walkGroundOffset: number,
	-- Next t-fraction for the bounded travel debug sample
	-- (§11: at most ~3 lines per flight, then silent).
	walkNextSample: number,
}

-- --- Public API -------------------------------------------------

-- Start a flight for `egg` to `destination`. Returns a
-- controller record the caller stores on the egg. The caller
-- MUST hold the egg's `_mutex` for the duration of the
-- controller swap and the lifetime of the flight; a second
-- flight for the same egg is rejected by the mutex check in
-- Purchase.
--
-- Args:
--   destination — a FlightDestination (see the type above):
--                 the hover CFrame to end at, plus the surface
--                 Ys under the start and the end.
--   onArrive    — invoked as `onArrive(egg, controller)` at
--                 t >= 1, after the final PivotTo, and only if
--                 the arrival guards pass. It owns EVERYTHING
--                 that happens after arrival: for lucky eggs
--                 that is `CollectorArrival.OnArrival`, which
--                 resolves a slot, teleports the egg into it,
--                 occupies it and fires `egg._onArrived`.
--
-- Required external state:
--   * egg.model — visible Model, PrimaryPart set, Anchored=true
--   * egg.state — must be 'Traveling' (set by the caller)
--   * egg.ownerUserId — set by the caller
--   * egg.slotId — the launch-time reservation, read on
--     arrival by CollectorArrival (not by this controller)
--   * egg.centerCFrame — the spawn CFrame (used for the start)
--
-- Required external services (resolved by the caller; the
-- arrival callback looks them up off the egg record's _refs
-- field so the controller itself needs no service knowledge).
function FlightController.Start(
	egg: any,
	destination: FlightDestination,
	onArrive: ((egg: any, controller: any) -> ())?
): FlightController
	if not egg.model or not egg.model.Parent then
		error('FlightController.Start: egg has no model', 2)
	end
	local primary = egg.model.PrimaryPart
	if not primary then
		error('FlightController.Start: egg has no PrimaryPart', 2)
	end
	if not destination or not destination.cframe then
		error('FlightController.Start: destination.cframe is required', 2)
	end

	local startCFrame = primary.CFrame
	local targetCFrame = destination.cframe
	local floorStart = destination.floorStart or HoverMath.FloorY(startCFrame.Y, egg.model)
	local floorEnd = destination.floorEnd or HoverMath.FloorY(targetCFrame.Y, egg.model)

	local startPos = startCFrame.Position
	local endPos = targetCFrame.Position
	local distance = (endPos - startPos).Magnitude
	-- Distance-derived duration (NOT a fixed clock): a cross-map
	-- delivery cruises at EggTravelSpeed instead of sprinting.
	-- Clamped so degenerate trips can't divide by ~zero and far
	-- trips stay bounded. Walk rhythm follows automatically —
	-- nominal speed below is distance / THIS duration.
	local duration = math.clamp(
		distance / math.max(0.001, Constants.EggTravelSpeed),
		Constants.EggTravelMinDuration,
		Constants.EggTravelMaxDuration
	)

	Debug.Log('EG', 'FlightController: starting', {
		uniqueId = egg.uniqueId,
		distance = tostring(distance),
		duration = tostring(duration),
	})

	-- Compute the wall-aware path. The egg is small and
	-- floats, but the pathfinder still routes around walls.
	--
	-- Both the query and the fallback are expressed at FLOOR
	-- level, because the per-tick Y reads the waypoint Y as
	-- "the surface under the egg right now" and adds the
	-- clearance itself. Pathfinder waypoints are already at
	-- navmesh floor level; the fallback has to be built that
	-- way explicitly, or it would fly a full clearance too
	-- high (the hover Y would be treated as a floor Y).
	local floorStartPos = Vector3.new(startPos.X, floorStart, startPos.Z)
	local floorEndPos = Vector3.new(endPos.X, floorEnd, endPos.Z)
	-- One retry: ComputeAsync fails transiently (navmesh
	-- streaming, throttling). The straight floor fallback below
	-- is the LAST resort, not the first answer — a purchased
	-- egg keeps its wall-aware polyline whenever one exists.
	local rawPoints: { Vector3 } = {}
	local computed = false
	for attempt = 1, 2 do
		local path: Path? = nil
		local ok = pcall(function()
			local built = PathfindingService:CreatePath(Constants.FlightAgentParams)
			path = built
			built:ComputeAsync(floorStartPos, floorEndPos)
		end)
		if ok and path ~= nil and (path :: Path).Status == Enum.PathStatus.Success then
			local pts: { Vector3 } = {}
			for _, wp in ipairs((path :: Path):GetWaypoints()) do
				pts[#pts + 1] = (wp :: any).Position
			end
			rawPoints = pts
			computed = true
		elseif attempt == 1 then
			Debug.Warn('EG', 'FlightController: pathfinder attempt 1 failed, retrying once', {})
		end
		if path ~= nil then
			pcall(function()
				(path :: Path):Destroy()
			end)
		end
		if computed then
			break
		end
	end
	local waypoints: { any } = {}
	if computed then
		local clean = FlightController.SanitizePath(rawPoints, floorStartPos, floorEndPos)
		for _, pt in ipairs(clean) do
			waypoints[#waypoints + 1] = { Position = pt }
		end
		-- Draw the path for the dev (no-op unless Debug.DrawPaths is on).
		if Debug.DrawPaths then
			Debug.DrawPath(waypoints, VfxConfig.Hygiene.DebugPathColor, 0)
			for i = 1, #waypoints - 1 do
				Debug.DrawLine(waypoints[i].Position, waypoints[i + 1].Position, VfxConfig.Hygiene.DebugPathColorAlt, 0)
			end
		end
	else
		Debug.Warn('EG', 'FlightController: pathfinder failed twice, falling back to straight line', {})
		waypoints = { { Position = floorStartPos }, { Position = floorEndPos } }
	end

	-- Pre-compute segment lengths for arc-length-based t cursor.
	local segLengths: { number } = {}
	local totalLength = 0
	for i = 1, #waypoints - 1 do
		local seg = (waypoints[i + 1].Position :: Vector3 - waypoints[i].Position :: Vector3).Magnitude
		segLengths[i] = seg
		totalLength = totalLength + seg
	end
	if totalLength < 0.001 then
		-- Degenerate (start == end). Just complete immediately.
		-- `_onComplete` is called from inside the controller so
		-- the arrival contract is identical whether the flight
		-- ran for 7 seconds or zero.
		local controller: FlightController = {
			egg = egg,
			startCFrame = startCFrame,
			targetCFrame = targetCFrame,
			startPos = startPos,
			endPos = endPos,
			distance = distance,
			duration = duration,
			floorStart = floorStart,
			floorEnd = floorEnd,
			stopped = true,
			aborted = false,
			connection = nil,
			onArrive = onArrive,
			walk = nil,
			walkBaseScale = 1,
			walkLastScale = nil,
			walkNominalSpeed = 0,
			walkSpeedEma = 0,
			walkLastDist = 0,
			walkSizeFactor = 1,
			walkGroundOffset = 0,
			walkNextSample = 2,
		}
		FlightController._onComplete(controller)
		return controller
	end

	-- Walk-presentation baseline (captured once — never per
	-- frame): the model's own authored scale (exact-restore
	-- target) and a hop scaler from egg height (same shape as
	-- the ambient registration).
	local walkBaseScale = 1
	do
		local okScale, s = pcall(function()
			return egg.model:GetScale()
		end)
		if okScale and type(s) == 'number' and s == s and s > 0 then
			walkBaseScale = s
		end
	end
	local walkSizeFactor = 1
	do
		local okH, h = pcall(HoverMath.BlockHeight, egg.model)
		if okH and type(h) == 'number' and h == h and h > 0 then
			local EF = MovementConfig.EggFlight
			walkSizeFactor = math.clamp(h / EF.WalkSizeDivisor, EF.WalkSizeMin, EF.WalkSizeMax)
		end
	end
	local walkNominalSpeed = totalLength / math.max(0.001, duration)
	-- Ambient-style ground offset (pivot-to-bottom): the SAME
	-- FloorGeometry helper roaming eggs use, so travel height =
	-- roam height. Falls back to half primary height (same
	-- fallback the ambient registration uses).
	local walkGroundOffset = primary.Size.Y / 2
	do
		local off = FloorGeometry.GetPivotGroundOffset(egg.model)
		if type(off) == 'number' and off == off then
			walkGroundOffset = off
		end
	end
	-- Lock the model's CFrame to startCFrame so the visual
	-- doesn't drift between now and the first Heartbeat tick.
	egg.model:PivotTo(startCFrame)

	local controller: FlightController = {
		egg = egg,
		startCFrame = startCFrame,
		targetCFrame = targetCFrame,
		startPos = startPos,
		endPos = endPos,
		distance = distance,
		duration = duration,
		floorStart = floorStart,
		floorEnd = floorEnd,
		stopped = false,
		aborted = false,
		connection = nil,
		onArrive = onArrive,
		walk = EggWalkAnimator.New(),
		walkBaseScale = walkBaseScale,
		walkLastScale = nil,
		walkNominalSpeed = walkNominalSpeed,
		walkSpeedEma = walkNominalSpeed,
		walkLastDist = 0,
		walkSizeFactor = walkSizeFactor,
		walkGroundOffset = walkGroundOffset,
		walkNextSample = MovementConfig.EggFlight.SampleInterval,
	}

	-- Track yaw per-tick. The egg smoothly turns to face
	-- the segment direction (same pattern as WalkController)
	-- so the visual front of the egg points in the
	-- direction of travel. initialized from startCFrame so
	-- the first frame has no snap.
	local _, initialYaw, _ = startCFrame:ToEulerAnglesYXZ()
	local currentYaw = initialYaw
	local lastTickTime = os.clock()
	-- Fail-safe latch: a skipped bad-pose tick warns once per
	-- flight (never per frame).
	local warnedBadPose = false

	local startedAt = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		if controller.aborted or controller.stopped then
			connection:Disconnect()
			controller.connection = nil
			return
		end
		if not egg.model or not egg.model.Parent then
			controller.aborted = true
			connection:Disconnect()
			controller.connection = nil
			return
		end

		local t = (os.clock() - startedAt) / duration
		if t >= 1 then
			connection:Disconnect()
			controller.connection = nil
			controller.stopped = true
			FlightController._onComplete(controller)
			return
		end

		-- Find segment by arc length. Sub-epsilon segments can
		-- never be selected (their cursor math is 0/0 = NaN);
		-- sanitize removed them at launch, this is belt-and-
		-- braces against float drift. segT is clamped: the
		-- cursor never extrapolates past a segment end.
		local targetDist = totalLength * t
		local acc = 0
		local segT = 0
		local p0: Vector3? = nil
		local p1: Vector3? = nil
		for i = 1, #segLengths do
			local segLen = segLengths[i]
			if segLen >= SEG_EPSILON and acc + segLen >= targetDist then
				p0 = waypoints[i].Position :: Vector3
				p1 = waypoints[i + 1].Position :: Vector3
				segT = math.clamp((targetDist - acc) / segLen, 0, 1)
				break
			end
			acc = acc + segLen
		end
		if not p0 then
			p0 = waypoints[#waypoints - 1].Position :: Vector3
			p1 = waypoints[#waypoints].Position :: Vector3
			segT = 1
		end

		local xz = (p0 :: Vector3):Lerp(p1 :: Vector3, segT)

		-- Y is roam-style ground contact, NOT hover clearance:
		-- floorY (path surface under the egg right now, capped
		-- against navmesh spikes) + the SAME pivot-to-bottom
		-- offset roaming eggs use. The Collector's Y never enters
		-- this computation — only its X/Z steered the path.
		-- Absolute recompute every tick (never previousY + hop),
		-- so the hop cannot accumulate into flight (§8).
		local floorY = (p0 :: Vector3).Y + ((p1 :: Vector3).Y - (p0 :: Vector3).Y) * segT
		floorY = math.min(floorY, controller.floorStart + MAX_CLIMB_ABOVE_START)
		local y = floorY + controller.walkGroundOffset

		-- Yaw: smoothly face the segment direction. The
		-- atan2 result is the yaw whose local -Z faces
		-- segDir's XZ (standard Roblox convention).
		-- FacingOffset lets models authored with +Z as
		-- the front flip 180° (set to math.pi).
		local now = os.clock()
		local dt = now - lastTickTime
		if dt <= 0 then
			dt = 0.016
		end
		lastTickTime = now
		local segDir = (p1 :: Vector3) - (p0 :: Vector3)
		if segDir.Magnitude > 0.001 then
			local targetYaw = math.atan2(segDir.X, segDir.Z) + FlightController.FacingOffset
			local delta = PathfindingUtil.ShortestAngleDelta(currentYaw, targetYaw)
			local alpha = 1 - math.exp(-FlightController.YawSmoothing * dt)
			currentYaw = currentYaw + delta * alpha
		end

		-- Shared walk-cycle presentation (EggWalkAnimator — the
		-- EXACT code ambient eggs run). Speed comes from the
		-- arc-length cursor (EMA-smoothed) over the flight's
		-- nominal cruise speed, so the rhythm follows real
		-- travel speed. The last ~7% of flight settles the
		-- blend (fast rate) so arrival lands at rest instead of
		-- mid-hop; _onComplete snaps the exact rest transform.
		-- Lean is applied yaw-local; with FacingOffset = π the
		-- pitch sign reads mirrored vs travel — cosmetic on a
		-- near-symmetric egg at 3°, accepted.
		local instSpeed = 0
		if dt > 0 then
			instSpeed = math.max(0, (targetDist - controller.walkLastDist) / dt)
		end
		controller.walkLastDist = targetDist
		local EF = MovementConfig.EggFlight
		controller.walkSpeedEma = controller.walkSpeedEma * EF.SpeedEmaKeep + instSpeed * EF.SpeedEmaGain
		local speedFactor = math.clamp(controller.walkSpeedEma / math.max(0.001, controller.walkNominalSpeed), 0, 1)
		if t < EF.SettleThreshold then
			EggWalkAnimator.Advance(controller.walk, dt, speedFactor)
		else
			EggWalkAnimator.Rest(controller.walk, dt, EF.SettleRate)
		end
		local lift, leanSide, leanFwd, stretch =
			EggWalkAnimator.Pose(controller.walk, speedFactor, controller.walkSizeFactor)
		controller.walkLastScale =
			EggWalkAnimator.ApplyScale(egg.model, controller.walkBaseScale * stretch, controller.walkLastScale)

		-- Bounded travel debug (§11): Y provenance a few times
		-- per flight — proves TargetY isn't the Collector and
		-- ground isn't drifting. ~3 lines max, then silent.
		if t >= controller.walkNextSample and controller.walkNextSample <= 1 then
			Debug.Log('EG', 'travel sample', {
				uniqueId = egg.uniqueId,
				y = ('%.2f'):format(y),
				floorY = ('%.2f'):format(floorY),
				speed = ('%.2f'):format(controller.walkSpeedEma),
			})
			controller.walkNextSample += MovementConfig.EggFlight.SampleInterval
		end

		local cf = CFrame.new(xz.X, y + lift, xz.Z)
			* CFrame.fromEulerAnglesYXZ(0, currentYaw, 0)
			* CFrame.Angles(leanFwd, 0, leanSide)
		-- Fail-safe: never steer to garbage. If the pose went
		-- NaN/inf (defensive — sanitize + clamps above should
		-- make this unreachable), HOLD the last pose this tick:
		-- no random fallback, no direct-line fallback. Pose is
		-- an absolute function of t, so the next tick
		-- self-heals. Warns once per flight, never per frame.
		local badPose = xz.X ~= xz.X or xz.Z ~= xz.Z or y ~= y
		if not badPose then
			badPose = math.abs(xz.X) == math.huge or math.abs(xz.Z) == math.huge or math.abs(y) == math.huge
		end
		if badPose then
			if not warnedBadPose then
				warnedBadPose = true
				Debug.Warn('EG', 'FlightController: non-finite pose skipped (holding last pose)', {
					uniqueId = egg.uniqueId,
				})
			end
			return
		end
		egg.model:PivotTo(cf)
	end)
	controller.connection = connection
	return controller
end

-- --- Stop -------------------------------------------------------

-- Idempotent. Marks the controller as stopped + aborted so the
-- Heartbeat callback bails on its next tick. If the egg is
-- in a state where it should be left Placed (e.g. force
-- release), the caller is responsible for setting that state
-- after Stop.
function FlightController.Stop(controller: FlightController)
	controller.stopped = true
	controller.aborted = true
	if controller.connection then
		controller.connection:Disconnect()
		controller.connection = nil
	end
	-- Best-effort scale restore: a mid-hop abort must not leave
	-- a squashed egg behind. Nil-guarded (degenerate/test
	-- controllers carry no walk baseline); the caller still owns
	-- the post-Stop PivotTo.
	if controller.walkBaseScale ~= nil and controller.egg and controller.egg.model then
		controller.walkLastScale =
			EggWalkAnimator.RestoreScale(controller.egg.model, controller.walkBaseScale, controller.walkLastScale)
	end
end

function FlightController.IsRunning(controller: FlightController): boolean
	return not controller.stopped
end

-- --- On complete -----------------------------------------------

-- Called when the flight finishes naturally (t >= 1). Snaps the
-- egg onto `controller.targetCFrame` — the destination it was
-- launched at — and hands the egg to `controller.onArrive`.
--
-- Everything that used to happen here (resolve the slot, occupy
-- it, commit `Placed`, fire `egg._onArrived`) now lives behind
-- `onArrive`. That is what makes the arrival RE-VALIDATABLE: a
-- 7-second flight can outlive its own slot reservation, so the
-- decision about where the egg actually lands has to be made
-- at this moment, with the base's current state — not at launch.
-- `Base/CollectorArrival.OnArrival` is that decision for lucky
-- eggs.
--
-- The controller stays consumer-agnostic: it doesn't know
-- whether the egg is a lucky egg or an animal, doesn't
-- know what a slot is, and doesn't touch `egg.state`.
--
-- The guards are deliberately here rather than in the callback,
-- because they are about the FLIGHT being still valid:
--   * `egg._aborted`      — the player left; ForceReleaseBase
--                             owns this egg now.
--   * model gone            — destroyed mid-flight.
--   * `state ~= Traveling`  — something already moved this egg
--                             on (lucky eggs only; animals
--                             carry no `state` field).
-- A callback that runs anyway would double-place the egg.
function FlightController._onComplete(controller: FlightController)
	local egg = controller.egg
	if egg._aborted then
		return
	end
	if not egg.model or not egg.model.Parent then
		return
	end
	-- State check only when the egg carries a state field
	-- (lucky eggs do; animals don't).
	if egg.state ~= nil and egg.state ~= Constants.State.Traveling then
		return
	end

	-- Land exactly on the destination. For lucky eggs this is
	-- the Collector's hover CFrame; the arrival callback then
	-- teleports the egg from here into its slot.
	--
	-- Walk-settle first: exact scale restore (nil-guarded — the
	-- degenerate path and test-built controllers carry no walk
	-- baseline, and RestoreScale itself is an exact-or-no-op).
	-- Combined with the t >= 0.93 blend-out, arrival lands at
	-- the precise resting transform: no lean, no squash, no
	-- residual scale.
	if controller.walkBaseScale ~= nil then
		controller.walkLastScale =
			EggWalkAnimator.RestoreScale(controller.egg.model, controller.walkBaseScale, controller.walkLastScale)
	end
	egg.model:PivotTo(controller.targetCFrame)
	if egg.centerCFrame ~= nil then
		egg.centerCFrame = controller.targetCFrame
	end
	egg._localFloor = controller.floorEnd

	if controller.onArrive then
		local ok, err = pcall(controller.onArrive, egg, controller)
		if not ok then
			Debug.Warn('EG', 'FlightController._onComplete: onArrive errored', {
				uniqueId = egg.uniqueId,
				err = tostring(err),
			})
		end
	end
end

return table.freeze(FlightController)
