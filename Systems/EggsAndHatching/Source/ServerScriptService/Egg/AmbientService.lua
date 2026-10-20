--!strict
--!native
--[[
	Egg.AmbientService
	====================
	Server-side ambient NPC wandering for AVAILABLE (center,
	unowned) eggs inside `Workspace.EggArea.ActiveEggs`.

	Each registered egg loops: pick a random floor destination
	-> walk (smooth turn, gentle procedural hop) -> idle ->
	repeat. Movement is custom and physics-free: every part of
	an ambient model is Anchored + non-collidable, and the whole
	model moves via `Model:PivotTo` from ONE centralized
	Heartbeat loop. No Humanoids, no HumanoidRootParts, no
	Animators, no PathfindingService, no per-egg connections.

	Walk animation is a deterministic sine walk-cycle (vertical
	hop + hop-synced alternating side lean + speed-scaled forward
	lean + velocity-driven uniform squash/stretch) composed into
	that same single PivotTo — zero extra replication while
	walking. A walkBlend crossfades walk↔idle (no Tweens);
	idling eggs breathe at 10Hz behind an epsilon deadband so
	resting eggs cost ~nothing. Per-egg personality
	(phase/frequency/bob/sway multipliers) is rolled ONCE at
	registration — never math.random() per frame.

	Separation (no piling): a spatial hash grid (cell =
	SeparationRadius) rebuilt each tick — O(n) build, bounded
	3x3-cell neighbor checks per egg — steers too-close eggs
	apart through velocity, never physics or teleports.

	Scope boundary: ONLY models explicitly registered via
	`RegisterModel` wander, and the ONLY caller is
	`SpawnService._spawnCenter` (ambient Available eggs).
	Player-owned egg models (persistence spawns, placed eggs,
	flights) live in the same container but are never
	registered and never touched. `ChildRemoved` on the
	container is a safety net that drops movement state for any
	destroyed model. Unregister restores the model's touch/query
	flags so a purchased egg behaves exactly as before.
]]

local RunService = game:GetService('RunService')
local Workspace = game:GetService('Workspace')

-- Localized hot-path helpers (walk-cycle math itself lives in
-- the shared EggWalkAnimator; these cover the loop's own needs).
local _abs = math.abs
local _clamp = math.clamp

local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local EggWalkAnimator = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local AmbientService = {}

export type AmbientState = {
	model: Model,
	primary: BasePart,
	yaw: number,
	dest: Vector3?,
	speed: number,
	idleUntil: number,
	halfExtent: number,
	groundOffset: number,
	-- Walk-cycle presentation: EggWalkAnimator owns the phase /
	-- blend / personality fields (phase, blend, idlePhase,
	-- freqMult, bobMult, swayMult) — this service only adds
	-- grounding + loop bookkeeping below. Field names match the
	-- animator's WalkState shape so the state passes straight
	-- through with zero translation.
	phase: number,
	blend: number,
	idlePhase: number,
	freqMult: number,
	bobMult: number,
	swayMult: number,
	idleTick: number, -- accumulator for the quantized idle write
	baseY: number, -- grounded rest Y (walk frames refresh it)
	sizeFactor: number, -- cached hop scaler from egg height
	baseScale: number, -- THIS egg's own authored scale (captured at register; squash is baseScale * multiplier, never normalized)
	lastScale: number?, -- last applied squash/stretch (quantized)
}

-- --- Internal state ----------------------------------------------

local _states: { [Model]: AmbientState } = {}
local _heartbeatConn: RBXScriptConnection? = nil
local _childRemovedConn: RBXScriptConnection? = nil
local _container: Instance? = nil
local _floor: BasePart? = nil
local _started = false
-- Proof diagnostics (lifecycle tracing): last area-warn time,
-- last 1/sec count-log time, and per-egg first-destination /
-- first-move flags. All print-based and throttled/one-shot —
-- never per-frame spam.
local _lastAreaWarn = 0
local _loggedDest: { [Model]: boolean } = {}
local _loggedMove: { [Model]: boolean } = {}

-- --- Area resolution -----------------------------------------------

local function _resolveArea(): (Instance?, BasePart?)
	local eggArea = Workspace:FindFirstChild('EggArea')
	-- The container is accepted as ANY Instance (Folder or
	-- Model): Studio builders commonly group spawn containers
	-- as Models, and requiring exactly Folder here silently
	-- disabled the whole system (frozen eggs) when it wasn't
	-- one. Only the Floor must be a BasePart (we read
	-- CFrame/Size off it).
	local container = eggArea and eggArea:FindFirstChild('ActiveEggs') or nil
	local floor = eggArea and eggArea:FindFirstChild('Floor') or nil
	if container and floor and floor:IsA('BasePart') then
		return container, floor
	end
	return nil, nil
end

local function _ensureArea(): boolean
	if _container and _container.Parent and _floor and _floor.Parent then
		return true
	end
	local container, floor = _resolveArea()
	if not container or not floor then
		return false
	end
	_container = container
	_floor = floor
	return true
end

-- --- Floor math (FloorGeometry owns ALL of it) ---------------------
--
-- The production Floor is a Cylinder rotated 90° about Z, so
-- local dimensions are NOT world dimensions. Sampling,
-- clamping, and surface height all go through the shared
-- FloorGeometry helper (cap-ellipse aware); nothing here
-- touches Size directly.

local function _marginFor(state: AmbientState): number
	return EggConfig.Ambient.EdgeMargin + state.halfExtent
end

-- --- Sampling (bounded attempts, never infinite-loop) ----------------

local function _horizontalDist(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

-- Is `point` (world XZ) clear of other ambient eggs by
-- SeparationRadius? Linear scan here is fine: sampling runs a
-- bounded few attempts a few times per egg lifetime, never per
-- frame (per-frame separation uses the spatial grid instead).
local function _pointIsClear(point: Vector3, ignore: Model?): boolean
	local radius = EggConfig.Ambient.SeparationRadius
	for other, _ in pairs(_states) do
		if other ~= ignore then
			local primary = other.PrimaryPart
			if primary and _horizontalDist(point, primary.Position) < radius then
				return false
			end
		end
	end
	return true
end

-- Sample a world-space destination for `state`: on the cap
-- ellipse, far enough from the current position, clear of
-- other eggs. Falls back to the best (farthest) candidate
-- after SampleAttempts tries; a clamped-in-place fallback
-- (arrive -> idle -> repick) when sampling degenerates.
local function _pickDestination(state: AmbientState): Vector3?
	local floor = _floor :: BasePart
	local cfg = EggConfig.Ambient
	local margin = _marginFor(state)
	local current = state.primary.Position
	local best: Vector3? = nil
	local bestDist = -1
	for _ = 1, cfg.SampleAttempts do
		local world = FloorGeometry.SampleSurfacePoint(floor, margin)
		if not world then
			break
		end
		local dist = _horizontalDist(world, current)
		if dist > bestDist then
			bestDist = dist
			best = world
		end
		if dist >= cfg.MinDestinationDistance and _pointIsClear(world, state.model) then
			return world
		end
	end
	if best then
		return best
	end
	return FloorGeometry.ClampToSurface(floor, current, margin)
end

-- --- Angle helpers -----------------------------------------------------

local function _wrapAngle(a: number): number
	while a > math.pi do
		a -= math.pi * 2
	end
	while a < -math.pi do
		a += math.pi * 2
	end
	return a
end

-- --- Per-egg update ------------------------------------------------------

local function _updateEgg(state: AmbientState, dt: number, pushX: number, pushZ: number, now: number)
	local cfg = EggConfig.Ambient
	local primary = state.primary
	if not primary.Parent then
		return
	end
	-- Idle: breathing only, quantized. The walk blend decays so a
	-- stopping egg settles (slight sink while blend remains, then
	-- pure micro-breath). Writes go out at IdleTickRate Hz behind
	-- an epsilon deadband — a resting egg costs ~nothing and
	-- replicates ~nothing. No drift: X/Z/yaw are untouched.
	if now < state.idleUntil then
		-- Settle (blend decay + breathing clock) via the shared
		-- animator; idleOffset = settle dip + micro-breath.
		local _, idleOffset = EggWalkAnimator.Rest(state, dt)
		-- An egg that stopped mid-squash restores its OWN resting
		-- scale once (then the lastScale == baseScale guard makes
		-- this free every tick after). NEVER a hardcoded 1:
		-- each template keeps its authored size.
		state.lastScale = EggWalkAnimator.RestoreScale(state.model, state.baseScale, state.lastScale)
		state.idleTick += dt
		if state.idleTick >= 1 / cfg.IdleTickRate then
			state.idleTick = 0
			local y = state.baseY + idleOffset
			-- Deadband against the live pose: skip the write
			-- (and its replication) when nothing visible changed.
			if _abs(y - state.model:GetPivot().Y) >= cfg.IdleEpsilon then
				local p = primary.Position
				state.model:PivotTo(CFrame.new(p.X, y, p.Z) * CFrame.Angles(0, state.yaw, 0))
			end
		end
		return
	end
	local pos = primary.Position
	if not state.dest then
		state.dest = _pickDestination(state)
		if not state.dest then
			state.idleUntil = now + cfg.MinIdleTime
			return
		end
		if not _loggedDest[state.model] then
			_loggedDest[state.model] = true
			local d = state.dest :: Vector3
						Debug.Log('EggAmbient', ('Egg=%s destination selected=<%0.1f, %0.1f, %0.1f> speed=%0.1f'):format(
					state.model:GetFullName(),
					d.X,
					d.Y,
					d.Z,
					state.speed
				))
		end
	end
	local dest = state.dest :: Vector3
	local toX = dest.X - pos.X
	local toZ = dest.Z - pos.Z
	local dist = math.sqrt(toX * toX + toZ * toZ)
	if dist < cfg.ArriveRadius then
		state.dest = nil
		state.idleUntil = now + cfg.MinIdleTime + math.random() * (cfg.MaxIdleTime - cfg.MinIdleTime)
		return
	end
	-- Desired walk velocity + separation steering, clamped.
	local dirX, dirZ = toX / dist, toZ / dist
	local velX = dirX * state.speed + pushX
	local velZ = dirZ * state.speed + pushZ
	local maxSpeed = state.speed * cfg.MaxSpeedFactor
	local velLen = math.sqrt(velX * velX + velZ * velZ)
	if velLen > maxSpeed then
		velX = velX / velLen * maxSpeed
		velZ = velZ / velLen * maxSpeed
		velLen = maxSpeed
	end
	-- Deadzone: tiny vectors cause rotation jitter, not motion.
	if velLen < cfg.SteerDeadzone then
		return
	end
	-- Smooth turn toward the velocity direction.
	local targetYaw = math.atan2(velX, velZ)
	local turn = math.clamp(_wrapAngle(targetYaw - state.yaw), -cfg.TurnRate * dt, cfg.TurnRate * dt)
	state.yaw += turn
	-- Advance, clamped onto the cap ellipse (safety net under
	-- the destination sampler). The clamped point's Y IS the
	-- surface height — grounding can never drift.
	local floor = _floor :: BasePart
	local nextWorld = Vector3.new(pos.X + velX * dt, pos.Y, pos.Z + velZ * dt)
	local grounded = FloorGeometry.ClampToSurface(floor, nextWorld, _marginFor(state))
	-- Walk-cycle presentation via the SHARED EggWalkAnimator
	-- (same code the purchased-egg flight uses — one source of
	-- truth). Movement and visuals stay separate: these terms
	-- never feed steering. Feet-planted Y compensation included
	-- (squash never sinks the egg).
	local speedFactor = _clamp(velLen / state.speed, 0, 1)
	EggWalkAnimator.Advance(state, dt, speedFactor)
	local lift, leanSide, leanFwd, stretch = EggWalkAnimator.Pose(state, speedFactor, state.sizeFactor)
	state.lastScale = EggWalkAnimator.ApplyScale(state.model, state.baseScale * stretch, state.lastScale)
	local y = grounded.Y + state.groundOffset + lift - (1 - stretch) * state.groundOffset
	state.baseY = grounded.Y + state.groundOffset
	state.model:PivotTo(
		CFrame.new(grounded.X, y, grounded.Z) * CFrame.Angles(0, state.yaw, 0) * CFrame.Angles(leanFwd, 0, leanSide)
	)
	if not _loggedMove[state.model] then
		_loggedMove[state.model] = true
				Debug.Log('EggAmbient', ('Movement started Egg=%s'):format(state.model:GetFullName()))
	end
end

-- --- Central update loop (ONE Heartbeat for all eggs) --------------------

local function _update(_dt: number)
	if not _ensureArea() then
		-- Area not resolvable yet (or Floor lost): say so at
		-- most every 5s instead of silently idling forever.
		local now = os.clock()
		if now - _lastAreaWarn >= 5 then
			_lastAreaWarn = now
			Debug.Log('EggAmbient', 'waiting for area: Workspace.EggArea/ActiveEggs/Floor not resolved')
		end
		return
	end
	-- Lazy ChildRemoved net: connected once the container is
	-- known (covers models destroyed outside the service).
	if _childRemovedConn == nil and _container ~= nil then
		_childRemovedConn = (_container :: Instance).ChildRemoved:Connect(function(child)
			AmbientService.UnregisterModel(child)
		end)
	end
	-- Proof log removed (was a per-second string.format + full
	-- registry scan on the hot path). Lifecycle tracing stays in
	-- Register/Unregister (one-shot Debug.Log lines).
	local dt = math.clamp(_dt, 0, 1 / 20)
	local now = os.clock()
	local cfg = EggConfig.Ambient
	-- Spatial hash grid (cell = SeparationRadius): O(n) build.
	-- Numeric two-level grid (grid[gx][gz]) — zero string
	-- allocation on the hot path (the old tostring(gx)..','..
	-- tostring(gz) built ~10 strings per egg per tick).
	local cell = math.max(0.5, cfg.SeparationRadius)
	local grid: { [number]: { [number]: { AmbientState } } } = {}
	for model, state in pairs(_states) do
		if model.Parent == nil or state.primary.Parent == nil then
			_states[model] = nil
		else
			local p = state.primary.Position
			local gx = math.floor(p.X / cell)
			local gz = math.floor(p.Z / cell)
			local col = grid[gx]
			if not col then
				col = {}
				grid[gx] = col
			end
			local bucket = col[gz]
			if not bucket then
				bucket = {}
				col[gz] = bucket
			end
			bucket[#bucket + 1] = state
		end
	end
	-- Per egg: separation push from the 3x3 neighborhood, then
	-- the movement update. Neighbor checks are bounded by cell
	-- density, never O(n^2). Push accumulates in x/z scalars —
	-- no Vector3 allocation per egg per tick.
	local sepRadius = cfg.SeparationRadius
	local sepStrength = cfg.SeparationStrength
	for _, state in pairs(_states) do
		local p = state.primary.Position
		local cx = math.floor(p.X / cell)
		local cz = math.floor(p.Z / cell)
		local pushX = 0
		local pushZ = 0
		for gx = cx - 1, cx + 1 do
			local col = grid[gx]
			if col then
				for gz = cz - 1, cz + 1 do
					local bucket = col[gz]
					if bucket then
						for _, other in ipairs(bucket) do
							if other ~= state then
								local op = other.primary.Position
								local dx = p.X - op.X
								local dz = p.Z - op.Z
								local d = math.sqrt(dx * dx + dz * dz)
								if d > 0.001 and d < sepRadius then
									local w = (sepRadius - d) / sepRadius * sepStrength
									pushX += dx / d * w
									pushZ += dz / d * w
								end
							end
						end
					end
				end
			end
		end
		_updateEgg(state, dt, pushX, pushZ, now)
	end
end

-- --- Public API ------------------------------------------------------------

function AmbientService.Init() end

function AmbientService.Start(_workspace: Instance?)
	if _started then
		return true
	end
	-- The single centralized Heartbeat is connected up front;
	-- the area (and the ChildRemoved net below) resolves
	-- lazily inside _update, so a late-replicating EggArea
	-- self-heals instead of permanently disabling wandering.
	_heartbeatConn = RunService.Heartbeat:Connect(_update)
	_started = true
	if _ensureArea() then
				Debug.Log('EggAmbient', ('ActiveEggs found = %s'):format((_container :: Instance):GetFullName()))
		-- One-shot numerical verification of the floor
		-- geometry (expect top ≈ 21.32, NOT ≈ 101.32).
				Debug.Log('EggAmbient', ('%s'):format(FloorGeometry.Describe(_floor :: BasePart)))
	else
		Debug.Log('EggAmbient', 'ActiveEggs not resolved yet; will retry each tick')
	end
	Debug.Log('EA', 'AmbientService started', {})
	return true
end

function AmbientService.Stop()
	_started = false
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	if _childRemovedConn then
		_childRemovedConn:Disconnect()
		_childRemovedConn = nil
	end
	table.clear(_states)
end

-- Register an AMBIENT (Available, center) egg model for
-- wandering. Idempotent. Validates the PrimaryPart and
-- normalizes the model's parts (anchored, non-collidable,
-- non-touchable, non-queryable — scoped to this model only).
-- Returns false when the area is unavailable or the model is
-- unsuitable; never errors.
function AmbientService.RegisterModel(model: Instance?): boolean
	if not _ensureArea() then
		return false
	end
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		return false
	end
	local typed = model :: Model
	if _states[typed] then
		return true
	end
	local primary = typed.PrimaryPart
	if not primary or not primary:IsA('BasePart') then
		Debug.Log('EggAmbient', typed:GetFullName())
		return false
	end
	for _, descendant in ipairs(typed:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
		end
	end
	local cfg = EggConfig.Ambient
	local yaw = math.random() * math.pi * 2
	-- Per-model pivot-to-bottom offset from actual geometry
	-- (never a global egg height).
	local groundOffset = FloorGeometry.GetPivotGroundOffset(typed) or (primary.Size.Y / 2)
	-- Walk-cycle personality comes from the SHARED EggWalkAnimator
	-- (same rolls the purchased-egg flight uses). sizeFactor
	-- scales the hop to egg height (cached — no per-frame
	-- measuring): a 4-stud egg gets full amplitude, smaller eggs
	-- proportionally less.
	local walk = EggWalkAnimator.New()
	-- Baseline scale: THIS model's own authored scale, captured
	-- once (never a global 1, never re-queried per frame). All
	-- squash/stretch multiplies around it, so small/medium/large
	-- templates keep their natural sizes forever.
	local baseScale = 1
	do
		local okScale, s = pcall(function()
			return typed:GetScale()
		end)
		if okScale and type(s) == 'number' and s == s and s > 0 then
			baseScale = s
		end
	end
	local state: AmbientState = {
		model = typed,
		primary = primary,
		yaw = yaw,
		dest = nil,
		speed = cfg.MinWalkSpeed + math.random() * (cfg.MaxWalkSpeed - cfg.MinWalkSpeed),
		idleUntil = os.clock() + math.random() * cfg.MaxIdleTime,
		halfExtent = math.max(primary.Size.X, primary.Size.Z) / 2,
		groundOffset = groundOffset,
		phase = walk.phase,
		blend = walk.blend, -- 0: spawn-settle, no pop
		idlePhase = walk.idlePhase,
		freqMult = walk.freqMult,
		bobMult = walk.bobMult,
		swayMult = walk.swayMult,
		idleTick = 0,
		baseY = primary.Position.Y,
		sizeFactor = _clamp(groundOffset / cfg.HopSizeDivisor, cfg.HopSizeMin, cfg.HopSizeMax),
		baseScale = baseScale,
		lastScale = baseScale, -- already at rest: first RestoreScale is a free no-op
	}
	_states[typed] = state
	-- Initial placement: a valid GROUNDED separated point
	-- before wandering begins (spawn-time settle, never a
	-- leftover hover height).
	local floor = _floor :: BasePart
	local margin = _marginFor(state)
	local placed = false
	for _ = 1, cfg.SampleAttempts do
		local world = FloorGeometry.SampleSurfacePoint(floor, margin)
		if world and _pointIsClear(world, typed) then
			typed:PivotTo(CFrame.new(world.X, world.Y + groundOffset, world.Z) * CFrame.Angles(0, yaw, 0))
			placed = true
			break
		end
	end
	if not placed then
		-- Safe fallback: floor center clamped onto the surface
		-- (never stuck outside, never an infinite search).
		local world = FloorGeometry.ClampToSurface(floor, floor.Position, margin)
		typed:PivotTo(CFrame.new(world.X, world.Y + groundOffset, world.Z) * CFrame.Angles(0, yaw, 0))
	end
	-- Seed the idle-breathing rest height from the actual placed
	-- pose (walking frames refresh it every tick after).
	state.baseY = typed:GetPivot().Y
	Debug.Log('EA', 'registered ambient egg', { model = typed:GetFullName() })
		Debug.Log('EggAmbient', ('Registered Egg=%s PrimaryPart=%s'):format(typed:GetFullName(), primary.Name))
	return true
end

-- Drop an egg from wandering and restore its touch/query flags
-- (so a purchased egg behaves exactly as before). Safe on
-- destroyed models and unknown models (no-op). Never errors.
function AmbientService.UnregisterModel(model: Instance?)
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		return
	end
	local typed = model :: Model
	if _states[typed] == nil then
		return
	end
	_states[typed] = nil
	_loggedDest[typed] = nil
	_loggedMove[typed] = nil
	if typed.Parent ~= nil then
		for _, descendant in ipairs(typed:GetDescendants()) do
			if descendant:IsA('BasePart') then
				descendant.CanTouch = true
				descendant.CanQuery = true
			end
		end
	end
	Debug.Log('EA', 'unregistered ambient egg', { model = typed:GetFullName() })
end

return table.freeze(AmbientService)
