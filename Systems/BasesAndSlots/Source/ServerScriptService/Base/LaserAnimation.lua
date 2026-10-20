--!strict
--!native
--[[
	LaserAnimation
	==============
	Instant state application for the physical Base Lock laser
	barriers (Parts named "Part" under
	Workspace.Map.Bases.<Base>.LazerDoor.Lazers).

	Locked   -> every laser takes its AUTHORED original
	            Size/CFrame immediately.
	Unlocked -> every laser takes the retracted pose (toward the
	            ground, bottom anchored) immediately.
	No TweenService, no waits, no stagger: transitions assign the
	final Size/CFrame synchronously using the same pose math.

	Design constraints (see BaseLockService header for the
	authoritative side):
	  * Server-authoritative state lives in BaseLockService; this
	    module only animates. It never decides locked/unlocked,
	    never touches CollisionGroup/CanCollide/Transparency, and
	    never invents a final size.
	  * Original Size + CFrame are captured ONCE per Part. Every
	    animation derives from the captured original — never from
	    the live animated Size — so repeated lock/unlock cycles
	    cannot drift, shrink, or grow the barrier.
	  * Bottom-anchored scaling: the laser's ground point is
	    computed from the original CFrame + Size along the Part's
	    OWN local Y axis (rotation-preserving via fromMatrix),
	    and the bottom never moves during a transition.
	  * Transitions assign final state synchronously; rapid
	    lock/unlock cycles simply re-assign, so mid-transition
	    reversal is exact by construction.
	  * No Heartbeat/RenderStepped loops, no Workspace polling,
	    no repeated GetDescendants: BaseLockService calls in only
	    on real transitions (Lock/Unlock) and once at
	    registration. Each Base's lasers are independent (state
	    keyed by baseId; parts never shared across bases).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local BaseLockConfig = require(ReplicatedStorage.Config.World.Bases).Lock
local Debug = require(ReplicatedStorage.Utility.Debug)

local LaserAnimation = {}

export type LaserOriginal = {
	size: Vector3,
	cf: CFrame,
}

-- --- Internal state ----------------------------------------------

-- Authored state, captured once per Part. Never rewritten.
local _original: { [BasePart]: LaserOriginal } = {}
-- Per-base generation: bumped on every transition (kept so rapid
-- lock/unlock cycles stay ordered in logs).
local _generation: { [string]: number } = {}

function LaserAnimation._TestReset()
	table.clear(_original)
	table.clear(_generation)
end

-- --- Ground-anchor math ------------------------------------------

-- The laser's ground point: original center minus half the
-- authored height along the Part's OWN local Y axis. Works for
-- rotated Parts (no world-Y assumption).
local function _groundPoint(orig: LaserOriginal): Vector3
	local yAxis = orig.cf.YVector
	return orig.cf.Position - yAxis * (orig.size.Y * 0.5)
end

-- Size + CFrame for a given height, bottom pinned to the
-- captured ground point, rotation preserved exactly.
local function _poseFor(orig: LaserOriginal, height: number): (Vector3, CFrame)
	local h = math.max(height, BaseLockConfig.LaserRetractedHeight)
	local size = Vector3.new(orig.size.X, h, orig.size.Z)
	local yAxis = orig.cf.YVector
	local center = _groundPoint(orig) + yAxis * (h * 0.5)
	local cf = CFrame.fromMatrix(center, orig.cf.XVector, yAxis, orig.cf.ZVector)
	return size, cf
end

-- Full-height pose: EXACT authored Size, transform matching the
-- authored position/rotation.
local function _fullPose(orig: LaserOriginal): (Vector3, CFrame)
	local cf = CFrame.fromMatrix(orig.cf.Position, orig.cf.XVector, orig.cf.YVector, orig.cf.ZVector)
	return orig.size, cf
end

-- --- Capture -----------------------------------------------------

local function _capture(part: BasePart)
	if _original[part] == nil then
		_original[part] = { size = part.Size, cf = part.CFrame }
	end
end

-- --- Instant application -------------------------------------------
-- (No tweens anywhere in this module: every transition assigns
-- the final Size/CFrame synchronously.)

local function _cancelTween(_part: BasePart)
	-- Retained as a no-op seam: historical call sites in Register
	-- and Snap run unchanged, and any in-flight tween object from
	-- before this change has no live references to act on.
	return
end

-- --- Public API --------------------------------------------------

-- Register a base's lasers: capture authored state once, snap to
-- the retracted pose instantly (locks are runtime-only, so a
-- freshly registered base starts unlocked).
function LaserAnimation.Register(baseId: string, laserParts: { BasePart })
	if type(baseId) ~= 'string' then
		return
	end
	_generation[baseId] = (_generation[baseId] or 0) + 1
	for _, part in ipairs(laserParts) do
		if typeof(part) == 'Instance' and part:IsA('BasePart') and part.Parent ~= nil then
			_capture(part)
			_cancelTween(part)
			local orig = _original[part]
			if orig then
				local size, cf = _poseFor(orig, BaseLockConfig.LaserRetractedHeight)
				pcall(function()
					part.Size = size
					part.CFrame = cf
				end)
			end
		end
	end
	Debug.Log('LZ', 'lasers registered (retracted)', { baseId = baseId, count = tostring(#laserParts) })
end

-- Snap to a state instantly (init sync / recovery). No tween.
function LaserAnimation.Snap(baseId: string, laserParts: { BasePart }, locked: boolean)
	if type(baseId) ~= 'string' then
		return
	end
	_generation[baseId] = (_generation[baseId] or 0) + 1
	for _, part in ipairs(laserParts) do
		if typeof(part) == 'Instance' and part:IsA('BasePart') and part.Parent ~= nil then
			_capture(part)
			_cancelTween(part)
			local orig = _original[part]
			if orig then
				local size: Vector3 = orig.size
				local cf: CFrame = orig.cf
				if locked then
					size, cf = _fullPose(orig)
				else
					size, cf = _poseFor(orig, BaseLockConfig.LaserRetractedHeight)
				end
				pcall(function()
					part.Size = size
					part.CFrame = cf
				end)
			end
		end
	end
end

-- Set the door state INSTANTLY (no tween, no stagger, no
-- waits): open = full authored pose, closed = retracted pose.
-- Same API and same final Size/CFrame math as Snap — the state
-- machine, collision, prompts, and lock logic are untouched.
function LaserAnimation.SetLocked(baseId: string, laserParts: { BasePart }, locked: boolean)
	if type(baseId) ~= 'string' then
		return
	end
	_generation[baseId] = (_generation[baseId] or 0) + 1
	for _, part in ipairs(laserParts) do
		if typeof(part) == 'Instance' and part:IsA('BasePart') and part.Parent ~= nil then
			_capture(part)
			_cancelTween(part)
			local orig = _original[part]
			if orig then
				local goalSize: Vector3 = orig.size
				local goalCf: CFrame = orig.cf
				if locked then
					goalSize, goalCf = _fullPose(orig)
				else
					goalSize, goalCf = _poseFor(orig, BaseLockConfig.LaserRetractedHeight)
				end
				pcall(function()
					part.Size = goalSize
					part.CFrame = goalCf
				end)
			end
		end
	end
	Debug.Log('LZ', 'laser transition (instant)', { baseId = baseId, locked = tostring(locked) })
end

return table.freeze(LaserAnimation)
