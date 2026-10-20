--!strict
--!native
--[[
	Leaderboard.spec
	================
	Pure-function coverage for the GLOBAL (physical, money-only)
	leaderboard: score encoding monotonicity (money only —
	rebirths NEVER affect this board), BigNumber-compatible
	display formatting (never scientific), rank colors, and
	the single-constant configuration. The 1Qa-vs-400M case is
	locked here. DataStore/Workspace paths need live servers +
	the authored Display part and are Studio-playtest items —
	see the service header. The TAB list (rebirths-first) is
	covered in TabList.spec.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local LeaderboardService = require(ServerScriptService.Leaderboard.LeaderboardService)

	describe('Leaderboard config', function()
		it('keeps ranking/display constants in one place', function()
			expect(LeaderboardService.MAX_ENTRIES).to.equal(10)
			expect(type(LeaderboardService.ORDERED_STORE_NAME)).to.equal('string')
			expect(type(LeaderboardService.META_STORE_NAME)).to.equal('string')
			expect(LeaderboardService.ORDERED_STORE_NAME ~= LeaderboardService.META_STORE_NAME).to.equal(true)
			expect(LeaderboardService.REFRESH_SECONDS >= 30).to.equal(true)
			expect(LeaderboardService.REFRESH_SECONDS <= 60).to.equal(true)
			-- Money-only store: the rebirth-mixed store name
			-- must never be reused (stale rebirth-dominated
			-- scores would resurface above real fortunes).
			expect(string.find(LeaderboardService.ORDERED_STORE_NAME, 'Money', 1, true) ~= nil).to.equal(true)
		end)
	end)

	describe('Leaderboard.EncodeScore ranking (money only)', function()
		it('ranks 1Qa above 400M regardless of rebirths (the 1Qa case)', function()
			-- Player A: 1Qa, 0 rebirths. Player B: 400M, 100
			-- rebirths. Global is money-only: A wins even
			-- though B dwarfs A on rebirths.
			local qa = '1000000000000000'
			local m400 = '400000000'
			expect(LeaderboardService.EncodeScore(qa) > LeaderboardService.EncodeScore(m400)).to.equal(true)
			expect(LeaderboardService.FormatMoney(qa)).to.equal('1.0Qa')
			expect(LeaderboardService.FormatMoney(m400)).to.equal('400.0M')
		end)

		it('orders money ascending, no rebirth input accepted', function()
			local values = { '0', '1', '999', '1000', '1500000', '9000000000' }
			local prev = -1
			for _, money in ipairs(values) do
				local score = LeaderboardService.EncodeScore(money)
				expect(score > prev).to.equal(true)
				prev = score
			end
		end)

		it('stays strictly increasing across every game magnitude tier', function()
			local ladder = {
				'1000', -- K
				'1000000', -- M
				'1000000000', -- B
				'1000000000000', -- T
				'1000000000000000', -- Qa
				'1000000000000000000', -- Qi
				'1000000000000000000000', -- Sx
				'1000000000000000000000000', -- Sp
				'1000000000000000000000000000', -- Oc
				'1000000000000000000000000000000', -- No
				'1000000000000000000000000000000000', -- Dc
				'1000000000000000000000000000000000000', -- past Dc
			}
			local prev = -1
			for _, money in ipairs(ladder) do
				local score = LeaderboardService.EncodeScore(money)
				expect(score > prev).to.equal(true)
				prev = score
			end
		end)

		it('never exceeds the OrderedDataStore/double-exact integer range', function()
			local maxScore = LeaderboardService.EncodeScore(string.rep('9', 200))
			expect(maxScore < 10000000000).to.equal(true)
			expect(maxScore < 2 ^ 53).to.equal(true)
			expect(maxScore == math.floor(maxScore)).to.equal(true)
			expect(maxScore > 0).to.equal(true)
		end)

		it('degrades nonsense inputs instead of erroring', function()
			expect(LeaderboardService.EncodeScore('abc')).to.equal(LeaderboardService.EncodeScore('0'))
			expect(LeaderboardService.EncodeScore('')).to.equal(LeaderboardService.EncodeScore('0'))
			expect(LeaderboardService.EncodeScore(nil) >= 0).to.equal(true)
		end)
	end)

	describe('Leaderboard.MoneyRank', function()
		it('prefers digit length over leading digits', function()
			expect(LeaderboardService.MoneyRank('999999') < LeaderboardService.MoneyRank('1000000')).to.equal(true)
		end)

		it('compares equal-length fortunes by leading digits', function()
			expect(LeaderboardService.MoneyRank('123456788') < LeaderboardService.MoneyRank('123456789')).to.equal(true)
		end)

		it('ranks zero below one', function()
			expect(LeaderboardService.MoneyRank('0') < LeaderboardService.MoneyRank('1')).to.equal(true)
		end)
	end)

	describe('Leaderboard.FormatMoney', function()
		it('matches the game formatter on ordinary fortunes', function()
			expect(LeaderboardService.FormatMoney('0')).to.equal('0')
			expect(LeaderboardService.FormatMoney('1')).to.equal('1')
			expect(LeaderboardService.FormatMoney('1000')).to.equal('1.0K')
			expect(LeaderboardService.FormatMoney('1500000')).to.equal('1.5M')
			expect(LeaderboardService.FormatMoney('9000000000')).to.equal('9.0B')
		end)

		it('never emits scientific notation, even past Dc', function()
			local huge = { string.rep('9', 34), string.rep('9', 37), string.rep('9', 40), string.rep('9', 61) }
			for _, money in ipairs(huge) do
				local text = LeaderboardService.FormatMoney(money)
				expect(string.find(text, 'e', 1, true)).to.equal(nil)
				expect(#text < #money).to.equal(true)
			end
		end)

		it('extends suffix tiers deterministically past Dc', function()
			-- 37 digits: 1e36 -> tier 12 -> 'UDc'.
			expect(LeaderboardService.FormatMoney('1' .. string.rep('0', 36))).to.equal('1.0UDc')
			-- 40 digits: 1e39 -> tier 13 -> 'DDc'.
			expect(LeaderboardService.FormatMoney('1' .. string.rep('0', 39))).to.equal('1.0DDc')
		end)

		it('falls back to zero on garbage', function()
			expect(LeaderboardService.FormatMoney('abc')).to.equal('0')
			expect(LeaderboardService.FormatMoney('')).to.equal('0')
			expect(LeaderboardService.FormatMoney(nil)).to.equal('0')
		end)
	end)

	describe('Leaderboard.RankColor', function()
		it('paints gold/silver/bronze/rest with the specced RGBs', function()
			expect(LeaderboardService.RankColor(1)).to.equal(Color3.fromRGB(255, 215, 80))
			expect(LeaderboardService.RankColor(2)).to.equal(Color3.fromRGB(210, 215, 220))
			expect(LeaderboardService.RankColor(3)).to.equal(Color3.fromRGB(205, 135, 75))
			expect(LeaderboardService.RankColor(4)).to.equal(Color3.fromRGB(225, 225, 225))
			expect(LeaderboardService.RankColor(10)).to.equal(Color3.fromRGB(225, 225, 225))
		end)
	end)
end
