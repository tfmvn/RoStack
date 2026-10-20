--!strict
--!native
-- # NEED TO REMOVE THIS FILE IN FUTURE
--[[
	WalkController
	==============
	Drives an animal from its current position to an animal slot
	on a PathfindingService polyline. Plain pathfinding — no
	LOS simplification, no body bob, no per-frame coroutine
	wait loop. Just compute the path once, then drive
	model:PivotTo each RunService.Heartbeat tick. The model
	uses the R15 NPC anchor pattern (root anchored, limbs
	unanchored) so the walk + idle anims play visibly.

	Why a dedicated controller (not PathfindingUtil.WalkTo):
	  * PathfindingUtil.WalkTo used a linear Y lerp from startY
	    to endY across the whole flight. That's wrong for a thing
	    that's supposed to walk on the ground — the pathfinder
	    returns waypoints with stepped Y (around obstacles,
	    between floors, over ramps), and we want the animal to
	    follow those Y steps so it visibly walks up stairs / down
	    ramps instead of floating in a straight line.
	  * The lucky egg's FlightController has the same Y-lerp
	    shape, but lucky eggs float (sin-bob, localFloor clamp)
	    so the bug is invisible. Animals are on the ground —
	    the path's Y IS where the feet should be.
	  * The WalkController uses the per-waypoint Y at the same
	    segT as the XZ. XZ is the arc-length-segment lerp; Y is
	    the same per-segment lerp. The pathfinder's polyline is
	    the path; we follow it exactly.



	Why anchored + PivotTo + Animator plays walk (not
	Humanoid:MoveTo):
	  * Humanoid:MoveTo + MoveToFinished:Wait() makes the
	    Humanoid stop at every waypoint (decelerate, idle-anim
	    transition, re-accelerate). Visible stutter.
	  * PivotTo is instantaneous. No coroutine wait per
	    waypoint (which is what Humanoid:MoveTo would force).
	    The Animator drives Motor6D joints (limbs unanchored
	    during the walk), so the walk animation track plays on
	    the moving cluster and the animal visibly walks
	    while smoothly translating.
	  * The Humanoid is preserved (combat / raid systems coming
	    later). It's idle throughout the walk.

	Algorithm:
	  1. Compute the path once via PathfindingService. On
	     ComputeAsync error or non-Success, TELEPORT to the slot
	     (snap PivotTo, OccupySlot, fire _onArrived). The user
	     chose teleport over hold-and-notify because teleport is
	     the only deterministic outcome.
	  2. Pre-compute segment lengths for the arc-length t cursor.
	  3. duration = totalLength / Speed.
	  4. Per Heartbeat:
	       - real dt = now - lastTickTime
	       - t = (os.clock() - startedAt) / duration
	       - Find the polyline segment at arc length totalLength * t
	       - xz = lerp(waypoints[i], waypoints[i+1], segT)
	       - y  = lerp(waypoints[i].Y, waypoints[i+1].Y, segT)  ← per-waypoint Y
	         (the path is computed from the animal's FEET
	         positions, not HRP, so the path's Y is where the
	         FEET should be; the per-tick `y` is the HRP's
	         world Y, lifted by |feetOffset| above the feet Y)
       - targetYaw = targetCFrame:ToEulerAnglesYXZ()  ← button-base facing yaw
         (the target CFrame faces the stand's button base,
         so the walk eases into the same direction the
         animal will hold once placed)
	       - smoothYaw = currentYaw + delta * (1 - exp(-YawSmoothing * dt))
	       - model:PivotTo(CFrame at (xz.X, y, xz.Z) with smoothYaw)
	  5. At t >= 1: snap to targetCFrame, call _onComplete,
	     disconnect.

	Multi-floor handling: the pathfinder returns Y-stepped
	waypoints (stairs, ramps, floor transitions). The per-waypoint
	Y lerp at the same segT as the XZ makes the animal's feet
	track those Y steps, so walking from floor 1 to floor 2
	visibly goes up the stairs.

	No per-waypoint stopping: the Heartbeat cursor advances
	continuously, never yielding per waypoint. The path's Y is
	followed per tick; the animal never decelerates or idles
	because we're not calling Humanoid:MoveTo. No external
	coroutine wait either — Start returns synchronously and
	cleanup is driven by the connection itself.

	Requirements on the model:
	  * Has a PrimaryPart (the HumanoidRootPart, used as
	    the position reference and the only part the walker
	    toggles between anchored and unanchored)
	  * Every other BasePart is unanchored (the standard
	    R15 NPC pattern) so the Animator can drive the
	    walk + idle animation tracks. CanCollide is false
	    on every part to keep the model non-interactive.
	  * Optional Humanoid — kept for animation playback and
	    future combat, but not required for the walk to work

	Edge cases:
	  * Model destroyed mid-walk: the Heartbeat callback checks
	    `not model.Parent` and disconnects cleanly. The
	    while-yield in Start exits on the next tick.
	  * Pathfinder returns non-Success: teleport to slot, fire
	    _onArrived, return a stopped controller. No Heartbeat
	    loop runs.
	  * Total path length < 0.001: same teleport path.
	  * Wall-clock cap: duration + WallClockPadding (2s). The
	    walk is deterministic (no per-waypoint yield), so this
	    only fires if the Heartbeat connection itself is somehow
	    lost.
]]

local PathfindingService = game:GetService('PathfindingService')
local RunService = game:GetService('RunService')

local PathfindingUtil = require(script.Parent.Parent.Utility.PathfindingUtil)
local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local SlotMath = require(script.Parent.SlotMath)

local WalkController = {}

-- --- Tunables ----------------------------------------------------

-- Walk speed in studs per second. Mirrors the default
-- Humanoid.WalkSpeed (16) so the visual pace matches what
-- players expect from Roblox characters. Re-exported from
-- AnimalConfig so tests can override via mock or stub.
WalkController.Speed = AnimalConfig.MovementSpeed

-- The walk animation was authored assuming this base movement
-- speed. When actual speed differs, the walk track's playback
-- speed is scaled by `actualSpeed / WalkController.AnimationBaseSpeed`
-- so the leg cadence visually matches the model's travel rate.
-- Canonical: MovementConfig.AnimalWalk.AnimationBaseSpeed (kept
-- in step with AnimalConfig.MovementSpeed; 10/10 = 1.0x at cruise).
-- Public + writable so tests can override per-case.
WalkController.AnimationBaseSpeed = MovementConfig.AnimalWalk.AnimationBaseSpeed

-- Smoothing factor for yaw rotation. Higher = the model snaps
-- to the segment direction faster; lower = it lags more behind
-- the path. 1 - exp(-8 * dt) gives a critically-damped feel
-- that converges in ~0.4 seconds without oscillating.
-- Canonical: MovementConfig.YawSmoothing (shared with egg
-- flight + pathfinding). Public + writable for tests.
WalkController.YawSmoothing = MovementConfig.YawSmoothing

-- Wall-clock cap is duration + this padding. The walk is
-- deterministic (no per-waypoint yield), so this only fires
-- if the Heartbeat connection itself is somehow lost. The
-- 2-second padding accounts for slow frames near the end.
WalkController.WallClockPadding = MovementConfig.AnimalWalk.WallClockPadding

-- Facing offset (radians) added to the target yaw. The
-- WalkController targets the slot's yaw (which is the
-- Collector-facing direction after BaseService applies the
-- Collector-facing rotation at register time), and the
-- animal's authored front is local +Z, which aligns with
-- the slot's +Z directly. The 180° flip that was needed for
-- the old segDir-based yaw is no longer needed; leave
-- FacingOffset at 0. If a future template is authored with
-- -Z as the front, set this to math.pi.
WalkController.FacingOffset = 0

-- --- Helpers -----------------------------------------------------

-- Unanchor every BasePart on the model, including the
-- PrimaryPart. Required during the walk so the Animator can
-- actually rotate the Motor6D joints — anchored parts don't
-- move their Motor6D children even when the Animator plays
-- a track, so the walk cycle loads and plays but the legs
-- don't visibly cycle. We re-anchor only the PrimaryPart in
-- the final-snap tick of the Heartbeat (and in
-- _teleportAndArrive) so the cluster's reference frame is
-- fixed at the slot, but limbs stay unanchored so the idle
-- anim at the slot actually plays.
local function _unanchorAll(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Anchored = false
		end
	end
end

-- Re-anchor only the PrimaryPart on the model. Called when
-- the walk ends so the cluster's reference frame is fixed
-- at the slot — no drift, no fall-through. Every other part
-- stays unanchored so the Animator can drive the walk + idle
-- tracks. Combined with CanCollide=false (set at clone time
-- by AnimalService), the model is stable at rest: anchored
-- root pins the cluster, unanchored limbs let the joints
-- rotate.
local function _reanchorAll(model: Model)
	local primary = model.PrimaryPart
	if not primary then
		return
	end
	primary.Anchored = true
end

-- Compute a path from `from` to `to`. Returns the path object
-- on success; nil on failure. Caller must call path:Destroy()
-- when done.
local function _computePath(from: Vector3, to: Vector3, agentParams: any)
	local path = PathfindingService:CreatePath(agentParams)
	local ok, err = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if not ok then
		Debug.Warn('WC', '_computePath: ComputeAsync error: ' .. tostring(err))
		path:Destroy()
		return nil
	end
	if path.Status ~= Enum.PathStatus.Success then
		Debug.Warn('WC', '_computePath: non-Success status: ' .. tostring(path.Status))
		path:Destroy()
		return nil
	end
	return path
end

-- --- Public API --------------------------------------------------

-- Start a walk for `animal` to `slot`. Returns a controller
-- record the caller stores on the animal. The caller MUST
-- have called `baseServiceRef.ReserveSlot(slot.id)` before
-- starting the walk (the existing EggService.HatchEgg
-- flow does this).
--
-- Required external state:
--   * animal.model — visible Model, PrimaryPart set, Anchored=true
--   * animal.uniqueId — for OccupySlot
--   * animal.slotId — captured as string for OccupySlot
--   * animal.ownerUserId — kept for the arrival notify
--   * animal._refs.baseService — for OccupySlot
--   * animal._onArrived (optional) — fires after OccupySlot
--
-- Failure semantics:
--   * On pathfinder failure: teleport to slot, fire _onArrived,
--     return a stopped controller.
--   * On model destroyed mid-walk: the Heartbeat callback
--     disconnects; the while-yield in Start exits; the caller
--     observes animal.model.Parent == nil.
function WalkController.Start(animal: any, slot: any): any
	if not animal.model or not animal.model.Parent then
		error('WalkController.Start: animal has no model', 2)
	end
	if not animal.slotId then
		error('WalkController.Start: animal has no slotId', 2)
	end
	local primary = animal.model.PrimaryPart
	if not primary then
		error('WalkController.Start: animal has no PrimaryPart', 2)
	end

	-- Capture slotId as a string. The slot table is a live
	-- reference; slot.id may have been re-stamped to userId=0
	-- by BaseService.CleanupPlayer if the player left in the
	-- final frame. Same pattern as the lucky egg flight.
	local slotId = animal.slotId :: string
	-- Compute the feet offset FIRST so we can use the
	-- animal's FEET position (not its HRP position) for
	-- the path. PathfindingService returns waypoints at
	-- the agent's HRP Y; if we use the HRP Y for both
	-- the path start and the per-tick floorY, the
	-- animal's FEET (which are |feetOffset| below the
	-- HRP) end up |feetOffset| above the path's reported
	-- Y, floating above the actual ground by that amount.
	-- Using the FEET position for the path makes the
	-- path's Y align with where the FEET should be, and
	-- the per-tick `y = floorY - feetOffset` (subtracting
	-- a negative feetOffset) lifts the HRP by the right
	-- amount.
	local feetOffset = SlotMath.FeetOffsetBelowPrimary(animal.model)
	local startCFrame = primary.CFrame
	local targetCFrame = SlotMath.StandingCFrameOnSlot(animal.model, slot)
	-- Path start/end: use the FEET position, not the HRP
	-- position. `feetOffset` is negative (e.g. -2.99), so
	-- adding (0, feetOffset, 0) LOWERS the position by
	-- |feetOffset| — from the HRP down to the feet. For
	-- the target, the standing CFrame is already computed
	-- with the HRP at slotTopY + |feetOffset|, so the
	-- FEET are at slotTopY. We just add the offset to
	-- convert from HRP-Y to feet-Y.
	local startPos = startCFrame.Position + Vector3.new(0, feetOffset, 0)
	local endPos = targetCFrame.Position + Vector3.new(0, feetOffset, 0)
	local totalDistance = (endPos - startPos).Magnitude

	-- Compute the path. On non-Success, teleport to slot.
	local waypoints: { Vector3 }
	local path: Path? = nil
	do
		path = _computePath(startPos, endPos, PathfindingUtil.AgentParams)
		if path then
			local waypointObjects = path:GetWaypoints()
			waypoints = {}
			for i, w in ipairs(waypointObjects) do
				waypoints[i] = w.Position
			end
			path:Destroy()
			path = nil
		else
			Debug.Warn('WC', 'WalkController: pathfinder failed, teleporting to slot')
			waypoints = {}
		end
	end

	Debug.Log('WC', 'WalkController: starting', {
		slotId = slotId,
		uniqueId = animal.uniqueId,
		start = tostring(startPos),
		end_ = tostring(endPos),
		distance = tostring(totalDistance),
		waypointCount = #waypoints,
		speed = WalkController.Speed,
	})

	if #waypoints < 2 then
		-- Pathfinder failed or degenerate path. Just
		-- complete via teleport.
		Debug.Log('WC', 'WalkController: empty/degenerate path, teleporting')
		if not WalkController._teleportAndArrive(animal, slot, slotId, targetCFrame) then
			return {
				animal = animal,
				slot = slot,
				slotId = slotId,
				startCFrame = startCFrame,
				targetCFrame = targetCFrame,
				waypoints = waypoints,
				segLengths = {},
				totalLength = 0,
				duration = 0,
				currentYaw = 0,
				stopped = true,
				aborted = true,
				connection = nil,
			}
		end
		return {
			animal = animal,
			slot = slot,
			slotId = slotId,
			startCFrame = startCFrame,
			targetCFrame = targetCFrame,
			waypoints = waypoints,
			segLengths = {},
			totalLength = 0,
			duration = 0,
			currentYaw = 0,
			stopped = true,
			aborted = false,
			connection = nil,
		}
	end

	-- Pre-compute segment lengths for arc-length-based t cursor.
	local segLengths: { number } = {}
	local totalLength = 0
	for i = 1, #waypoints - 1 do
		local seg = (waypoints[i + 1] - waypoints[i]).Magnitude
		segLengths[i] = seg
		totalLength = totalLength + seg
	end
	if totalLength < 0.001 then
		-- Degenerate (start == end, or single waypoint).
		-- Just complete immediately.
		Debug.Log('WC', 'WalkController: degenerate path, teleporting')
		if not WalkController._teleportAndArrive(animal, slot, slotId, targetCFrame) then
			return {
				animal = animal,
				slot = slot,
				slotId = slotId,
				startCFrame = startCFrame,
				targetCFrame = targetCFrame,
				waypoints = waypoints,
				segLengths = segLengths,
				totalLength = totalLength,
				duration = 0,
				currentYaw = 0,
				stopped = true,
				aborted = true,
				connection = nil,
			}
		end
		return {
			animal = animal,
			slot = slot,
			slotId = slotId,
			startCFrame = startCFrame,
			targetCFrame = targetCFrame,
			waypoints = waypoints,
			segLengths = segLengths,
			totalLength = totalLength,
			duration = 0,
			currentYaw = 0,
			stopped = true,
			aborted = false,
			connection = nil,
		}
	end

	-- Walk duration: distance / speed.
	local duration = totalLength / WalkController.Speed
	local startedAt = os.clock()
	local _, initialYaw, _ = startCFrame:ToEulerAnglesYXZ()
	local currentYaw = initialYaw

	-- The pathfinder returns the FLOOR Y the animal's
	-- FEET should walk on. The path is computed from
	-- the animal's FEET position (see the startPos /
	-- endPos construction above — we add feetOffset to
	-- convert the HRP positions to feet positions before
	-- calling the pathfinder). The path's Y IS the
	-- height the feet should be at. We then offset the
	-- PrimaryPart UP by |feetOffset| so the BOTTOM of
	-- the model sits on the path Y, not the PrimaryPart
	-- itself. For a model with feet 2.99 studs below
	-- the HRP, the HRP rides 2.99 studs above the path
	-- Y and the feet touch the path Y exactly.
	--
	-- `feetOffset` is captured at the top of Start (before
	-- the path is computed) and used both for the path
	-- start/end and for the per-tick HRP lift. The earlier
	-- capture means the diagnostic below sees the same
	-- value the per-tick code uses.

	-- Unanchor every part (root + limbs) so the Animator
	-- can drive the full Motor6D chain during the walk.
	-- The PivotTo each Heartbeat keeps the model moving
	-- along the path; the unanchor only affects joint
	-- rotation, not the model's translation. We re-anchor
	-- only the PrimaryPart in the t >= 1 final snap (and
	-- in _teleportAndArrive) so the cluster's reference
	-- frame is fixed at the slot, but limbs stay
	-- unanchored so the idle anim at the slot actually
	-- plays.
	_unanchorAll(animal.model)

	-- Lock the model's CFrame to startCFrame so the visual
	-- doesn't drift between now and the first Heartbeat tick.
	animal.model:PivotTo(startCFrame)

	-- Adjust the walk animation playback speed so the leg
	-- cadence matches the actual travel rate. If the animal
	-- has no walk animation (template missing Anims), skip.
	if animal.animations and animal.animations.walk then
		local speedRatio = WalkController.Speed / WalkController.AnimationBaseSpeed
		-- Clamp to a sane range so a misconfigured
		-- AnimationBaseSpeed doesn't make the legs
		-- sprint-blur or crawl.
		speedRatio = math.clamp(speedRatio, 0.25, 4.0)
		animal.animations.walk:AdjustSpeed(speedRatio)
	end

	local controller: any = {
		animal = animal,
		slot = slot,
		slotId = slotId,
		startCFrame = startCFrame,
		targetCFrame = targetCFrame,
		waypoints = waypoints,
		segLengths = segLengths,
		totalLength = totalLength,
		duration = duration,
		feetOffset = feetOffset,
		currentYaw = currentYaw,
		stopped = false,
		aborted = false,
		connection = nil,
	}

	-- The Heartbeat loop. Per tick: real-frame-dt, find
	-- segment by arc length, lerp XZ, lerp Y at the same
	-- segT, smooth yaw using real dt, PivotTo.
	local connection
	local lastTickTime = startedAt
	connection = RunService.Heartbeat:Connect(function()
		if controller.aborted or controller.stopped then
			connection:Disconnect()
			controller.connection = nil
			return
		end
		if not animal.model or not animal.model.Parent or not animal.model.PrimaryPart then
			controller.aborted = true
			connection:Disconnect()
			controller.connection = nil
			return
		end

		-- Wall-clock cap.
		local now = os.clock()
		if now - startedAt > duration + WalkController.WallClockPadding then
			Debug.Warn('WC', 'WalkController: hit wall-clock cap', {
				elapsed = tostring(now - startedAt),
			})
			controller.aborted = true
			connection:Disconnect()
			controller.connection = nil
			return
		end

		-- Real-frame dt for yaw smoothing. First tick
		-- uses 0 so the first yaw delta isn't a giant
		-- snap.
		local dt = now - lastTickTime
		if dt <= 0 then
			dt = 0.016
		end
		lastTickTime = now

		local t = (now - startedAt) / duration
		if t >= 1 then
			-- Final snap to the exact target CFrame. The
			-- smooth interpolation has landed near but
			-- not exactly on the target due to frame
			-- quantisation; the snap removes any drift.
			animal.model:PivotTo(targetCFrame)
			-- Re-anchor only the PrimaryPart so the
			-- cluster's reference frame is fixed at the
			-- slot (no drift). Limbs stay unanchored so
			-- the Animator can drive the idle animation
			-- track at the slot. PivotTo is the LAST
			-- physics write before anchoring; the model
			-- is now at the exact target CFrame and
			-- won't drift.
			_reanchorAll(animal.model)
			connection:Disconnect()
			controller.connection = nil
			controller.stopped = true
			WalkController._onComplete(controller)
			return
		end

		-- Find the polyline segment at arc length
		-- totalLength * t.
		local targetDist = totalLength * t
		local acc = 0
		local segT = 0
		local p0: Vector3? = nil
		local p1: Vector3? = nil
		for i = 1, #segLengths do
			if acc + segLengths[i] >= targetDist then
				p0 = waypoints[i]
				p1 = waypoints[i + 1]
				segT = (targetDist - acc) / segLengths[i]
				break
			end
			acc = acc + segLengths[i]
		end
		if not p0 then
			-- Edge case: targetDist just past the end. Snap
			-- to the last segment.
			p0 = waypoints[#waypoints - 1]
			p1 = waypoints[#waypoints]
			segT = 1
		end
		local p0v = p0 :: Vector3
		local p1v = p1 :: Vector3

		-- XZ is the per-segment lerp at segT.
		local xz = p0v:Lerp(p1v, segT)

		-- Y is also the per-segment lerp at the SAME segT.
		-- This is the fix: the pathfinder's Y IS the path
		-- Y (with floor steps, ramps, obstacle avoidance).
		-- We follow it exactly so the animal visibly
		-- walks up/down stairs instead of floating in a
		-- straight line.
		--
		-- The path was computed using the animal's FEET
		-- positions as start/end (see startPos / endPos
		-- at the top of Start — we add feetOffset to the
		-- HRP positions to convert them to feet positions
		-- before calling the pathfinder). So the path's
		-- Y is the height the FEET should be at, not the
		-- HRP. The per-tick `y` below is the HRP's world
		-- Y (what model:PivotTo expects), so we lift the
		-- HRP by |feetOffset| above the path's feet Y.
		-- Subtracting a negative feetOffset = adding the
		-- absolute offset.
		local floorY = p0v.Y + (p1v.Y - p0v.Y) * segT
		local y = floorY - feetOffset

		-- Yaw: face the slot's rotation (the Collector-
		-- facing Yaw set by BaseService.RegisterBases),
		-- not the segment direction. The animal lands
		-- facing the same direction the slot faces, which
		-- is the Collector's direction. Previously we used
		-- `segDir` to face the path of motion, which made
		-- the animal visibly spin as the path curved;
		-- the final snap at t >= 1 still landed it at the
		-- correct CFrame but the in-flight visual was
		-- wrong.
		--
		-- `targetCFrame` is the slot's standing CFrame,
		-- whose yaw is the slot's rotation (= Collector's
		-- direction). The animal's authored front is
		-- local +Z, which aligns with the slot's +Z
		-- directly, so FacingOffset is 0.
		local _, targetYawRaw, _ = targetCFrame:ToEulerAnglesYXZ()
		local targetYaw = targetYawRaw + WalkController.FacingOffset
		local delta = PathfindingUtil.ShortestAngleDelta(currentYaw, targetYaw)
		local alpha = 1 - math.exp(-WalkController.YawSmoothing * dt)
		currentYaw = currentYaw + delta * alpha

		local cf = CFrame.new(xz.X, y, xz.Z) * CFrame.fromEulerAnglesYXZ(0, currentYaw, 0)
		animal.model:PivotTo(cf)
	end)
	controller.connection = connection
	-- No poll loop. The Heartbeat callback handles its own
	-- bail-out (model destroyed, t >= 1, wall-clock cap)
	-- and disconnects the connection. The calling coroutine
	-- doesn't need to wait — the controller record is
	-- returned synchronously. Cleanup paths (Stop,
	-- ForceReleaseBase) read controller.stopped/aborted.
	return controller
end

-- --- Stop --------------------------------------------------------

-- Idempotent. Marks the controller as stopped + aborted so the
-- Heartbeat callback bails on its next tick.
function WalkController.Stop(controller: any)
	controller.stopped = true
	controller.aborted = true
	if controller.connection then
		controller.connection:Disconnect()
		controller.connection = nil
	end
end

function WalkController.IsRunning(controller: any): boolean
	return not controller.stopped
end

-- --- Internal: teleport + arrive ---------------------------------

-- Used when the pathfinder can't compute a route, or the path
-- is degenerate. Snaps the model to the slot, calls OccupySlot,
-- fires _onArrived. Returns true on success; false if the
-- animal was already torn down.
function WalkController._teleportAndArrive(animal: any, slot: any, slotId: string, targetCFrame: CFrame): boolean
	if not animal.model or not animal.model.Parent then
		return false
	end
	animal.model:PivotTo(targetCFrame)
	-- Re-anchor only the PrimaryPart for the symmetric
	-- end-state: cluster root fixed, limbs free for the
	-- idle anim. The model was unanchored at clone time
	-- (limbs) and may or may not have been unanchored for
	-- the walk (root) — _reanchorAll is idempotent.
	_reanchorAll(animal.model)
	local controller: any = {
		animal = animal,
		slot = slot,
		slotId = slotId,
		startCFrame = targetCFrame,
		targetCFrame = targetCFrame,
		stopped = true,
		aborted = false,
	}
	WalkController._onComplete(controller)
	return true
end

-- --- Internal: on complete ---------------------------------------

-- Called when the walk finishes naturally (t >= 1) or when the
-- teleport path lands. The model is already at the slot CFrame;
-- we OccupySlot the slot and fire the consumer's _onArrived.
--
-- The controller is intentionally consumer-agnostic: it doesn't
-- know whether the animal is a "boneca ambalabu" or a "tren
-- turco". The consumer installs the per-animal behavior by
-- setting `animal._onArrived(animal, slot, slotId)` before
-- starting the walk. AnimalService._walkTo installs the
-- per-animal arrival work: stop walk anim, play idle anim,
-- push state, fire AnimalArrived, notify the owner.
--
-- If OccupySlot returns false, the slot wasn't Reserved (maybe
-- an admin force-released mid-walk). We log warn and return
-- without firing _onArrived — the animal is at the slot
-- visually, and the next cleanup pass will reconcile.
function WalkController._onComplete(controller: any)
	local animal = controller.animal
	local slot = controller.slot
	local slotId = controller.slotId
	if animal._aborted then
		return
	end
	if not animal.model or not animal.model.Parent then
		return
	end
	local refs = animal._refs
	if not refs or not refs.baseService then
		Debug.Warn('WC', '_onComplete: no _refs.baseService, cannot OccupySlot')
		return
	end

	local result = (refs.slotService or refs.baseService).OccupySlot(
		slotId,
		animal.uniqueId,
		SlotType.OccupantKind.Animal
	)
	if not result then
		Debug.Warn('WC', '_onComplete: OccupySlot returned false', {
			slotId = slotId,
			uniqueId = animal.uniqueId,
		})
		return
	end

	if animal._onArrived then
		local ok, err = pcall(animal._onArrived, animal, slot, slotId)
		if not ok then
			Debug.Warn('WC', '_onComplete: _onArrived errored', {
				uniqueId = animal.uniqueId,
				err = tostring(err),
			})
		end
	end
end

return table.freeze(WalkController)
