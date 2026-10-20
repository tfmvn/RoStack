--!strict
--!native
--[[
	LevelProgression.spec
	=====================
	Phase 2.4 tests for the canonical Level/XP progression module
	(ReplicatedStorage/Config/LevelConfig.lua).

	What this spec locks in (spec §34/§35):
	  * XPRequired(L) = BaseRequired * GrowthRate^(L-1), rounded
	    half-up ONCE at the config boundary (200 / 1.12 curve).
	  * Level -> points formula P(L) = q(L-1) with q = 3:
	    L1 = 0, L2 = 3, L3 = 6, L4 = 9, L100 = 297; P_max = 297.
	  * Normalize: XP is current progress (not lifetime); exact
	    threshold -> level+1 with XP 0; overflow preserved; one
	    grant crossing multiple levels; hard MaxLevel stop with
	    the bank cap; malformed (level, xp) pairs repaired.
	  * The consistency invariant: after Normalize, XP < R(level)
	    for level < MaxLevel; XP <= R(MaxLevel) at MaxLevel.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)

	local MAX = LevelConfig.MaxLevel
	local function required(level: number): number
		return LevelConfig.GetXPRequired(level)
	end

	describe('GetXPRequired', function()
		it('returns the exact dev-curve thresholds', function()
			expect(required(1)).to.equal(200) -- 200 * 1.12^0
			expect(required(2)).to.equal(224) -- 200 * 1.12^1
			expect(required(3)).to.equal(251) -- 250.88 rounds half-up once
			expect(required(4)).to.equal(281) -- 280.9856 -> 281
			expect(required(5)).to.equal(315) -- 314.703872 -> 315
		end)

		it('returns integers across the whole curve (single rounding boundary)', function()
			for level = 1, MAX do
				local r = required(level)
				expect(r).to.be.a('number')
				expect(r).to.equal(math.floor(r))
				expect(r >= 1).to.equal(true)
			end
		end)

		it('is strictly increasing (GrowthRate > 1)', function()
			for level = 1, MAX - 1 do
				expect(required(level) < required(level + 1)).to.equal(true)
			end
		end)

		it('throws on out-of-domain levels', function()
			expect(function()
				required(0)
			end).to.throw()
			expect(function()
				required(MAX + 1)
			end).to.throw()
			expect(function()
				required(1.5)
			end).to.throw()
		end)
	end)

	describe('GetPointsForLevel (P(L) = q(L-1), q = 3)', function()
		it('matches the canonical progression', function()
			expect(LevelConfig.GetPointsForLevel(1)).to.equal(0)
			expect(LevelConfig.GetPointsForLevel(2)).to.equal(3)
			expect(LevelConfig.GetPointsForLevel(3)).to.equal(6)
			expect(LevelConfig.GetPointsForLevel(4)).to.equal(9)
			expect(LevelConfig.GetPointsForLevel(100)).to.equal(297)
		end)

		it('exposes P_max = q * (L_max - 1) = 297', function()
			expect(LevelConfig.GetMaxPoints()).to.equal(297)
			expect(LevelConfig.GetMaxPoints()).to.equal(LevelConfig.GetPointsForLevel(MAX))
		end)

		it('throws on out-of-domain levels', function()
			expect(function()
				LevelConfig.GetPointsForLevel(0)
			end).to.throw()
			expect(function()
				LevelConfig.GetPointsForLevel(MAX + 1)
			end).to.throw()
		end)
	end)

	describe('Normalize — XP semantics (current progress, overflow preserved)', function()
		it('keeps partial progress at the same level', function()
			local level, xp, gained = LevelConfig.Normalize(1, 50)
			expect(level).to.equal(1)
			expect(xp).to.equal(50)
			expect(gained).to.equal(0)
		end)

		it('levels up exactly at the threshold with XP 0', function()
			local level, xp, gained = LevelConfig.Normalize(1, 200)
			expect(level).to.equal(2)
			expect(xp).to.equal(0)
			expect(gained).to.equal(1)
		end)

		it('preserves overflow across one threshold (spec §5 example)', function()
			-- 200 + 140 grant -> Level 2 with 140 left.
			local level, xp, gained = LevelConfig.Normalize(1, 340)
			expect(level).to.equal(2)
			expect(xp).to.equal(140)
			expect(gained).to.equal(1)
		end)

		it('crosses multiple levels in one call (spec §13)', function()
			-- 200 + 224 + 251 consumed, 10 carried into level 4.
			local level, xp, gained = LevelConfig.Normalize(1, 685)
			expect(level).to.equal(4)
			expect(xp).to.equal(10)
			expect(gained).to.equal(3)
		end)

		it('stops exactly at MaxLevel with 99 levels gained, no infinite loop', function()
			local level, xp, gained = LevelConfig.Normalize(1, 10 ^ 15)
			expect(level).to.equal(MAX)
			expect(gained).to.equal(MAX - 1)
			expect(xp <= required(MAX)).to.equal(true)
		end)
	end)

	describe('Normalize — MaxLevel bank (spec §11)', function()
		it('never exceeds MaxLevel', function()
			local level = LevelConfig.Normalize(MAX, 10 ^ 18)
			expect(level).to.equal(MAX --[[@as number]])
		end)

		it('caps XP at the bank ceiling R(MaxLevel)', function()
			local level, xp, gained = LevelConfig.Normalize(MAX, 10 ^ 18)
			expect(level).to.equal(MAX)
			expect(xp).to.equal(required(MAX))
			expect(gained).to.equal(0)
		end)

		it('keeps in-range XP untouched at MaxLevel', function()
			local level, xp, gained = LevelConfig.Normalize(MAX, 12345)
			expect(level).to.equal(MAX)
			expect(xp).to.equal(12345)
			expect(gained).to.equal(0)
		end)
	end)

	describe('Normalize — malformed data repair (spec §27)', function()
		it('repairs missing Level/XP to 1/0', function()
			local level, xp, gained = LevelConfig.Normalize(nil, nil)
			expect(level).to.equal(1)
			expect(xp).to.equal(0)
			expect(gained).to.equal(0)
		end)

		it('repairs negative / fractional / NaN / inf values', function()
			local level, xp = LevelConfig.Normalize(-5, -3)
			expect(level).to.equal(1)
			expect(xp).to.equal(0)

			level, xp = LevelConfig.Normalize(2.5, 3.7)
			expect(level).to.equal(1)
			expect(xp).to.equal(0)

			level, xp = LevelConfig.Normalize(0 / 0, 0 / 0)
			expect(level).to.equal(1)
			expect(xp).to.equal(0)

			level, xp = LevelConfig.Normalize(math.huge, math.huge)
			expect(level).to.equal(1)
			expect(xp).to.equal(0)
		end)

		it('clamps Level > MaxLevel instead of resetting it', function()
			local level, xp = LevelConfig.Normalize(500, 0)
			expect(level).to.equal(MAX)
			expect(xp).to.equal(0)
		end)

		it('drains an impossible XP pile instead of keeping it (spec §28)', function()
			-- Level 3 with 1e12 XP is not a valid state: normalize it.
			local level, xp, gained = LevelConfig.Normalize(3, 10 ^ 12)
			expect(level).to.equal(MAX)
			expect(gained).to.equal(MAX - 3)
			expect(xp <= required(MAX)).to.equal(true)
		end)
	end)

	describe('consistency invariant sweep (spec §28)', function()
		it('every produced state satisfies XP < R(level) below MaxLevel', function()
			local samples = {
				{ 1, 0 },
				{ 1, 50 },
				{ 1, 99 },
				{ 1, 100 },
				{ 1, 140 },
				{ 1, 391 },
				{ 7, 43 },
				{ 99, required(99) - 1 },
				{ 99, required(99) },
				{ 99, required(99) + 500 },
				{ MAX, 0 },
				{ MAX, 12345 },
				{ MAX, 10 ^ 15 },
				{ 500, 10 ^ 12 },
				{ -3, -1 },
				{ nil, nil },
			}
			for _, pair in ipairs(samples) do
				local level, xp = LevelConfig.Normalize(pair[1], pair[2])
				expect(level >= 1).to.equal(true)
				expect(level <= MAX).to.equal(true)
				expect(xp >= 0).to.equal(true)
				expect(xp).to.equal(math.floor(xp))
				if level < MAX then
					expect(xp < required(level)).to.equal(true)
				else
					expect(xp <= required(MAX)).to.equal(true)
				end
			end
		end)
	end)
end
