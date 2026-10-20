--!strict
--!native
--[[
	StatCalculator.spec
	===================
	Phase 2.4 tests for the universal logarithmic stat-scaling
	utility (ReplicatedStorage/Utility/StatCalculator.lua) — the
	ONE implementation of the canonical formula (spec §17-§21/§35):

	    G(P) = B + (M - B) * ln(1 + P/C) / ln(1 + P_max/C)

	What this spec locks in:
	  * G(0) = B and G(P_max) = M exactly, for the canonical
	    document's verification examples (B=100/M=600 and
	    B=10/M=60 with C=100, P_max=297).
	  * Monotonic increase with points; diminishing returns
	    (equal point steps shrink in value).
	  * Points > P_max clamp to P_max (deterministic, G = M).
	  * Full float precision — no internal rounding.
	  * Invalid parameters throw (Curve <= 0, MaxPoints <= 0,
	    non-finite Base/Maximum, negative Points).
]]

local EPSILON = 1e-9

local function near(a: number, b: number): boolean
	return math.abs(a - b) <= EPSILON * math.max(1, math.abs(a), math.abs(b))
end

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local StatCalculator = require(ReplicatedStorage.Utility.StatCalculator)

	local function calc(points: number, base: number, maximum: number, curve: number, maxPoints: number): number
		return StatCalculator.Calculate({
			Points = points,
			Base = base,
			Maximum = maximum,
			Curve = curve,
			MaxPoints = maxPoints,
		})
	end

	describe('canonical boundaries (spec §35)', function()
		it('G(0) = B and G(P_max) = M for B=100, M=600, C=100, P_max=297', function()
			expect(near(calc(0, 100, 600, 100, 297), 100)).to.equal(true)
			expect(near(calc(297, 100, 600, 100, 297), 600)).to.equal(true)
		end)

		it('G(0) = B and G(P_max) = M for B=10, M=60, C=100, P_max=297', function()
			expect(near(calc(0, 10, 60, 100, 297), 10)).to.equal(true)
			expect(near(calc(297, 10, 60, 100, 297), 60)).to.equal(true)
		end)

		it('returns B exactly at zero points (no float dust)', function()
			expect(calc(0, 100, 600, 100, 297)).to.equal(100)
			expect(calc(0, 10, 60, 100, 297)).to.equal(10)
		end)
	end)

	describe('curve shape', function()
		local B, M, C, PMAX = 100, 600, 100, 297

		it('increases with points', function()
			local previous = calc(0, B, M, C, PMAX)
			for _, p in ipairs({ 1, 10, 50, 100, 150, 200, 250, 297 }) do
				local value = calc(p, B, M, C, PMAX)
				expect(value > previous).to.equal(true)
				previous = value
			end
		end)

		it('shows diminishing returns (equal steps shrink)', function()
			local step1 = calc(50, B, M, C, PMAX) - calc(0, B, M, C, PMAX)
			local step2 = calc(100, B, M, C, PMAX) - calc(50, B, M, C, PMAX)
			local step3 = calc(150, B, M, C, PMAX) - calc(100, B, M, C, PMAX)
			local step4 = calc(200, B, M, C, PMAX) - calc(150, B, M, C, PMAX)
			expect(step1 > step2).to.equal(true)
			expect(step2 > step3).to.equal(true)
			expect(step3 > step4).to.equal(true)
		end)

		it('never exceeds M below P_max and never goes below B', function()
			for _, p in ipairs({ 1, 29, 73, 148, 296 }) do
				local value = calc(p, B, M, C, PMAX)
				expect(value > B).to.equal(true)
				expect(value < M).to.equal(true)
			end
		end)

		it('keeps full float precision (no internal rounding)', function()
			local value = calc(137, B, M, C, PMAX)
			local raw = B + (M - B) * math.log(1 + 137 / C) / math.log(1 + PMAX / C)
			expect(near(value, raw)).to.equal(true)
			expect(value == raw).to.equal(true) -- bit-exact with the inline formula
		end)
	end)

	describe('point clamp policy (spec §21)', function()
		it('clamps Points > P_max to P_max, yielding exactly M', function()
			expect(near(calc(400, 100, 600, 100, 297), 600)).to.equal(true)
			expect(calc(10 ^ 12, 100, 600, 100, 297)).to.equal(600)
		end)
	end)

	describe('validation (spec §21)', function()
		it('throws on Curve <= 0', function()
			expect(function()
				calc(10, 100, 600, 0, 297)
			end).to.throw()
			expect(function()
				calc(10, 100, 600, -1, 297)
			end).to.throw()
		end)

		it('throws on MaxPoints <= 0', function()
			expect(function()
				calc(10, 100, 600, 100, 0)
			end).to.throw()
			expect(function()
				calc(10, 100, 600, 100, -5)
			end).to.throw()
		end)

		it('throws on non-finite Base / Maximum / Curve', function()
			expect(function()
				calc(10, 0 / 0, 600, 100, 297)
			end).to.throw()
			expect(function()
				calc(10, 100, math.huge, 100, 297)
			end).to.throw()
			expect(function()
				calc(10, 100, 600, 0 / 0, 297)
			end).to.throw()
		end)

		it('throws on negative or NaN points', function()
			expect(function()
				calc(-1, 100, 600, 100, 297)
			end).to.throw()
			expect(function()
				calc(0 / 0, 100, 600, 100, 297)
			end).to.throw()
		end)
	end)
end
