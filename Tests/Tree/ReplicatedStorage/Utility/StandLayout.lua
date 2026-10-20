--!strict
--[[
	StandLayout
	===========
	Pure Base-LOCAL stand layout math (no services, no remotes,
	headless-testable). Given a stand count, produces base-local
	CFrames; callers transform through the Base's Center part
	(worldCFrame = Center.CFrame * localCFrame) so rotated bases
	rotate their whole layout. Ground Y always comes from
	Center.Position.Y (passed through by callers).

	Animal ring: count splits into a right arc and a mirrored
	left arc on the same ellipse. Right arc index order first
	(1..R), then left (R+1..N); odd counts put the extra stand on
	the right. Single-point arcs use the arc midpoint.
	Arena row: centered on X at the configured local Z.
	All stands face the layout center, yaw-only (eye and target
	share Y, so no tilt).
]]

local StandLayout = {}

-- Base-local CFrames for `count` animal stands around a circle
-- center (cx, cz) — normally (0, ForwardOffset): the whole ring
-- shifts as one unit. Never errors; count <= 0 yields {}.
function StandLayout.AnimalLocals(
	count: number,
	radiusX: number,
	radiusZ: number,
	startDeg: number,
	endDeg: number,
	circleX: number?,
	circleZ: number?
): { CFrame }
	local out: { CFrame } = {}
	local n = math.floor(tonumber(count) or 0)
	if n <= 0 then
		return out
	end
	local rx = tonumber(radiusX) or 0
	local rz = tonumber(radiusZ) or 0
	local a0 = math.rad(tonumber(startDeg) or 0)
	local a1 = math.rad(tonumber(endDeg) or 0)
	local rightCount = math.ceil(n / 2)
	local leftCount = n - rightCount
	local function arcAngles(k: number): { number }
		if k <= 0 then
			return {}
		end
		if k == 1 then
			return { (a0 + a1) * 0.5 }
		end
		local angles: { number } = {}
		for i = 1, k do
			angles[#angles + 1] = a0 + (a1 - a0) * ((i - 1) / (k - 1))
		end
		return angles
	end
	local ordered: { number } = {}
	for _, a in ipairs(arcAngles(rightCount)) do
		ordered[#ordered + 1] = a
	end
	for _, a in ipairs(arcAngles(leftCount)) do
		ordered[#ordered + 1] = math.pi - a
	end
	local ccx = tonumber(circleX) or 0
	local ccz = tonumber(circleZ) or 0
	for _, a in ipairs(ordered) do
		local pos = Vector3.new(ccx + rx * math.cos(a), 0, ccz + rz * math.sin(a))
		out[#out + 1] = CFrame.lookAt(pos, Vector3.new(ccx, pos.Y, ccz))
	end
	return out
end

-- Base-local CFrames for `count` arena stands: centered row.
function StandLayout.ArenaLocals(count: number, z: number, spacing: number): { CFrame }
	local out: { CFrame } = {}
	local n = math.floor(tonumber(count) or 0)
	if n <= 0 then
		return out
	end
	local zz = tonumber(z) or 0
	local sp = tonumber(spacing) or 0
	for i = 1, n do
		local x = (i - (n + 1) / 2) * sp
		local pos = Vector3.new(x, 0, zz)
		out[#out + 1] = CFrame.lookAt(pos, Vector3.new(0, pos.Y, 0))
	end
	return out
end

return table.freeze(StandLayout)
