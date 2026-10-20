--!strict
--[[
	FloorGeometry
	=============
	One shared, rotation-aware floor geometry helper. Every
	system that reasons about the `Workspace.EggArea.Floor`
	surface (ambient spawning, ambient wandering, flight
	bounds) MUST use this instead of inline `Size` math.

	Why it exists: the production Floor is a Cylinder rotated
	90° about Z (local +X points at world +Y), so `Size.Y / 2`
	is NOT the world vertical half-height — treating it as one
	put eggs ~80 studs in the air. All queries below derive
	from `CFrame` basis vectors, so they stay correct for any
	orientation. Nothing here is hard-coded to the current
	Floor; the measured production values
	(top ≈ 21.32059, X ∈ [-81.15, 79.75], Z ∈ [-68.10, 64.21])
	are verification targets, not inputs.

	Cylinder semantics: the Floor's flat cap is an ellipse
	spanned by the two local axes LEAST aligned with world up,
	with radii equal to those axes' half-sizes. Sampling and
	clamping stay inside that ellipse (minus margin), never the
	looser rectangular corners.
]]

local FloorGeometry = {}

-- World-space half-extent of the floor along world Y,
-- rotation-aware: sum of |basis-Y| * local half-size over the
-- three axes. No orientation special-casing.
local function _worldHalfHeight(floor: BasePart): number
	local cf = floor.CFrame
	local hx, hy, hz = floor.Size.X / 2, floor.Size.Y / 2, floor.Size.Z / 2
	local rv, uv, lv = cf.RightVector, cf.UpVector, cf.LookVector
	return math.abs(rv.Y) * hx + math.abs(uv.Y) * hy + math.abs(lv.Y) * hz
end

-- World Y of the floor's top surface.
function FloorGeometry.GetWorldTopY(floor: BasePart): number
	return floor.Position.Y + _worldHalfHeight(floor)
end

-- World Y of the floor's bottom surface.
function FloorGeometry.GetWorldBottomY(floor: BasePart): number
	return floor.Position.Y - _worldHalfHeight(floor)
end

-- Full world-space AABB of the floor (all 8 oriented corners).
-- Used for verification/diagnostics, NOT for roam sampling
-- (the roam area is the cap ellipse — see below).
function FloorGeometry.GetWorldBounds(floor: BasePart): (Vector3, Vector3)
	local cf = floor.CFrame
	local hx, hy, hz = floor.Size.X / 2, floor.Size.Y / 2, floor.Size.Z / 2
	local min = Vector3.new(math.huge, math.huge, math.huge)
	local max = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local world = cf:PointToWorldSpace(Vector3.new(sx * hx, sy * hy, sz * hz))
				min = Vector3.new(math.min(min.X, world.X), math.min(min.Y, world.Y), math.min(min.Z, world.Z))
				max = Vector3.new(math.max(max.X, world.X), math.max(max.Y, world.Y), math.max(max.Z, world.Z))
			end
		end
	end
	return min, max
end

-- Which local axis is most aligned with world up, and the
-- planar (cap) axes with their half-sizes. Returns
-- (topAxisIndex, topHalf, aHalf, bHalf) where indices are
-- 1/2/3 for local X/Y/Z.
local function _capAxes(floor: BasePart): (number, number, number, number)
	local cf = floor.CFrame
	local halves = { floor.Size.X / 2, floor.Size.Y / 2, floor.Size.Z / 2 }
	local align = {
		math.abs(cf.RightVector.Y),
		math.abs(cf.UpVector.Y),
		math.abs(cf.LookVector.Y),
	}
	local top = 1
	if align[2] > align[top] then
		top = 2
	end
	if align[3] > align[top] then
		top = 3
	end
	local planar: { number } = {}
	for i = 1, 3 do
		if i ~= top then
			planar[#planar + 1] = i
		end
	end
	return top, halves[top], halves[planar[1]], halves[planar[2]]
end

local function _setAxis(v: Vector3, index: number, value: number): Vector3
	if index == 1 then
		return Vector3.new(value, v.Y, v.Z)
	elseif index == 2 then
		return Vector3.new(v.X, value, v.Z)
	else
		return Vector3.new(v.X, v.Y, value)
	end
end

local function _getAxis(v: Vector3, index: number): number
	if index == 1 then
		return v.X
	elseif index == 2 then
		return v.Y
	else
		return v.Z
	end
end

-- Clamp a world position onto the floor's cap ellipse (shrunk
-- by `margin`), pinned to the top surface along the top axis.
-- The Y of the result IS the surface height.
function FloorGeometry.ClampToSurface(floor: BasePart, worldPos: Vector3, margin: number): Vector3
	local top, topHalf, aHalf, bHalf = _capAxes(floor)
	aHalf = math.max(0, aHalf - margin)
	bHalf = math.max(0, bHalf - margin)
	local lp = floor.CFrame:PointToObjectSpace(worldPos)
	-- Pin to the top surface.
	lp = _setAxis(lp, top, topHalf)
	-- Project the planar coords inside the ellipse.
	local planarIdx: { number } = {}
	for i = 1, 3 do
		if i ~= top then
			planarIdx[#planarIdx + 1] = i
		end
	end
	if aHalf > 0 and bHalf > 0 then
		local a = _getAxis(lp, planarIdx[1]) / aHalf
		local b = _getAxis(lp, planarIdx[2]) / bHalf
		local k = math.sqrt(a * a + b * b)
		if k > 1 then
			lp = _setAxis(lp, planarIdx[1], _getAxis(lp, planarIdx[1]) / k)
			lp = _setAxis(lp, planarIdx[2], _getAxis(lp, planarIdx[2]) / k)
		end
	else
		lp = _setAxis(lp, planarIdx[1], 0)
		lp = _setAxis(lp, planarIdx[2], 0)
	end
	return floor.CFrame:PointToWorldSpace(lp)
end

-- Uniform random point on the floor's cap ellipse (shrunk by
-- `margin`), pinned to the top surface. Returns nil when the
-- shrunk ellipse degenerates. sqrt-distribution keeps the
-- density uniform over the disk, not clustered at the center.
function FloorGeometry.SampleSurfacePoint(floor: BasePart, margin: number): Vector3?
	local top, topHalf, aHalf, bHalf = _capAxes(floor)
	aHalf -= margin
	bHalf -= margin
	if aHalf <= 0 or bHalf <= 0 then
		return nil
	end
	local r = math.sqrt(math.random())
	local theta = math.random() * math.pi * 2
	local planarIdx: { number } = {}
	for i = 1, 3 do
		if i ~= top then
			planarIdx[#planarIdx + 1] = i
		end
	end
	local lp = Vector3.new(0, 0, 0)
	lp = _setAxis(lp, top, topHalf)
	lp = _setAxis(lp, planarIdx[1], r * math.cos(theta) * aHalf)
	lp = _setAxis(lp, planarIdx[2], r * math.sin(theta) * bHalf)
	return floor.CFrame:PointToWorldSpace(lp)
end

-- Vertical offset from a model's pivot down to its lowest part
-- bottom (world Y at call time; models are rigid so this is
-- stable). Per-model — never a global egg height. Returns nil
-- when the model has no usable geometry.
function FloorGeometry.GetPivotGroundOffset(model: Model): number?
	local primary = model.PrimaryPart
	if not primary or not primary:IsA('BasePart') then
		return nil
	end
	local lowest: number? = nil
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			local bottom = descendant.Position.Y - descendant.Size.Y / 2
			if lowest == nil or bottom < (lowest :: number) then
				lowest = bottom
			end
		end
	end
	if lowest == nil then
		return nil
	end
	return math.max(0, primary.Position.Y - (lowest :: number))
end

-- One-line numerical verification dump for the current floor.
function FloorGeometry.Describe(floor: BasePart): string
	local min, max = FloorGeometry.GetWorldBounds(floor)
	return ('Floor pos=<%.3f, %.3f, %.3f> top=%.3f bottom=%.3f X=[%.2f, %.2f] Z=[%.2f, %.2f]'):format(
		floor.Position.X,
		floor.Position.Y,
		floor.Position.Z,
		FloorGeometry.GetWorldTopY(floor),
		FloorGeometry.GetWorldBottomY(floor),
		min.X,
		max.X,
		min.Z,
		max.Z
	)
end

return table.freeze(FloorGeometry)
