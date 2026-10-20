--!strict
--!native
--[[
	EggFlightPath.spec
	==================
	Tests for the purchased-egg path sanitizer
	(ServerScriptService/Egg/FlightController.SanitizePath).

	What this spec locks in:
	  A. Consecutive duplicate waypoints are dropped (they
	     create zero-length segments, and the arc-length cursor
	     (targetDist - acc) / 0 is 0/0 = NaN — NaN poisons the
	     interpolated position and the egg teleports).
	  B. Non-finite points (NaN/inf) are dropped, never steered to.
	  C. Fewer than 2 surviving points falls back to the
	     straight {a, b} floor line (never nil, never 1 point).
	  D. Sanitizing is deterministic: same input, same output,
	     no RNG, order preserved.
	  E. A healthy polyline passes through untouched.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local FlightController = require(ServerScriptService.Egg.FlightController)

	local A = Vector3.new(0, 0, 0)
	local B = Vector3.new(100, 0, 0)

	describe('FlightController.SanitizePath', function()
		it('keeps a healthy polyline untouched', function()
			local pts = {
				Vector3.new(0, 0, 0),
				Vector3.new(10, 0, 5),
				Vector3.new(20, 1, 10),
				Vector3.new(100, 0, 0),
			}
			local clean = FlightController.SanitizePath(pts, A, B)
			expect(#clean).to.equal(4)
			for i, pt in ipairs(pts) do
				expect(clean[i] == pt).to.equal(true)
			end
		end)

		it('drops consecutive duplicates that would make 0/0 segments', function()
			local pts = {
				Vector3.new(0, 0, 0),
				Vector3.new(0, 0, 0), -- pathfinder-duplicated start
				Vector3.new(0, 0, 0),
				Vector3.new(50, 0, 0),
				Vector3.new(100, 0, 0),
				Vector3.new(100, 0, 0), -- duplicated end
			}
			local clean = FlightController.SanitizePath(pts, A, B)
			expect(#clean).to.equal(3)
			expect(clean[1] == pts[1]).to.equal(true)
			expect(clean[2] == pts[4]).to.equal(true)
			expect(clean[3] == pts[5]).to.equal(true)
			-- Every surviving segment is steerable (no 0/0).
			for i = 1, #clean - 1 do
				expect((clean[i + 1] - clean[i]).Magnitude >= 0.01).to.equal(true)
			end
		end)

		it('drops NaN/inf points, never steers to them', function()
			local nan = 0 / 0
			local pts = {
				Vector3.new(0, 0, 0),
				Vector3.new(nan, 0, 10),
				Vector3.new(50, math.huge, 0),
				Vector3.new(100, 0, 0),
			}
			local clean = FlightController.SanitizePath(pts, A, B)
			expect(#clean).to.equal(2)
			expect(clean[1] == pts[1]).to.equal(true)
			expect(clean[2] == pts[4]).to.equal(true)
		end)

		it('falls back to the straight line when fewer than 2 points survive', function()
			expect(#FlightController.SanitizePath({}, A, B)).to.equal(2)
			local onlyJunk = { Vector3.new(0 / 0, 0, 0) }
			local clean = FlightController.SanitizePath(onlyJunk, A, B)
			expect(#clean).to.equal(2)
			expect(clean[1] == A).to.equal(true)
			expect(clean[2] == B).to.equal(true)
			-- All-duplicates collapse to one point -> fallback.
			local dupes = { Vector3.new(5, 0, 5), Vector3.new(5, 0, 5) }
			local cleanDupes = FlightController.SanitizePath(dupes, A, B)
			expect(#cleanDupes).to.equal(2)
			expect(cleanDupes[1] == A).to.equal(true)
		end)

		it('is deterministic across repeated calls', function()
			local pts = {
				Vector3.new(0, 0, 0),
				Vector3.new(0, 0, 0),
				Vector3.new(30, 2, -10),
				Vector3.new(100, 0, 0),
			}
			local first = FlightController.SanitizePath(pts, A, B)
			local second = FlightController.SanitizePath(pts, A, B)
			expect(#first).to.equal(#second)
			for i, pt in ipairs(first) do
				expect(pt == second[i]).to.equal(true)
			end
		end)
	end)
end
