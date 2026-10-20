--!strict
--!native
--[[
	UpgradeCost.spec
	================
	Phase 2.10 unit tests for the ONE authoritative upgrade-cost
	calculation (UpgradeService.GetUpgradeCost). Pure function:
	(base price, level) -> exact BigNumber decimal string. No
	services, no fakes, no Instances.

	Locked in (§41 + precision rules):
	  * base x 1.12^(L-1), EXACT decimals ('1254.4', never
	    float dust like '1254.4000000001')
	  * invalid input (bad def, L<1, L>Max, L=Max) yields nil —
	    no 100 -> 101 price exists
	  * deterministic: same inputs, same string, every time
	  * monotonic: higher level costs strictly more
	  * string-only comparisons (never tonumber on currency)
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local UpgradeService = require(ServerScriptService.UpgradeService)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)

	describe('UpgradeService.GetUpgradeCost', function()
		it('prices L1 as exactly the base (x 1.12^0)', function()
			expect(UpgradeService.GetUpgradeCost('Chicken', 1)).to.equal('100')
			expect(UpgradeService.GetUpgradeCost('Chimpanzee', 1)).to.equal('1000')
		end)

		it('spec examples: 1000 base L2/L3/L4 are exact', function()
			expect(UpgradeService.GetUpgradeCost('Chimpanzee', 2)).to.equal('1120')
			expect(UpgradeService.GetUpgradeCost('Chimpanzee', 3)).to.equal('1254.4')
			expect(UpgradeService.GetUpgradeCost('Chimpanzee', 4)).to.equal('1404.928')
		end)

		it('higher rarity bases scale by the same 1.12 curve', function()
			-- Divine Dragon base is 100000: L2 = x1.12,
			-- L3 = x1.2544, exact.
			expect(UpgradeService.GetUpgradeCost('Dragon', 2)).to.equal('112000')
			expect(UpgradeService.GetUpgradeCost('Dragon', 3)).to.equal('125440')
		end)

		it('rejects bad definitions and out-of-range levels with nil', function()
			expect(UpgradeService.GetUpgradeCost('NopeDef', 1)).to.equal(nil)
			expect(UpgradeService.GetUpgradeCost('', 1)).to.equal(nil)
			expect(UpgradeService.GetUpgradeCost('Chicken', 0)).to.equal(nil)
			expect(UpgradeService.GetUpgradeCost('Chicken', -3)).to.equal(nil)
			expect(UpgradeService.GetUpgradeCost('Chicken', 1.5)).to.equal(nil)
			expect(UpgradeService.GetUpgradeCost('Chicken', LevelConfig.MaxLevel + 1)).to.equal(nil)
		end)

		it('has no price at MaxLevel (100 -> 101 is forbidden)', function()
			expect(UpgradeService.GetUpgradeCost('Chicken', LevelConfig.MaxLevel)).to.equal(nil)
		end)

		it('is deterministic across repeated calls', function()
			local a = UpgradeService.GetUpgradeCost('Chimpanzee', 37)
			local b = UpgradeService.GetUpgradeCost('Chimpanzee', 37)
			expect(a ~= nil).to.equal(true)
			expect(a).to.equal(b)
			expect(BigNumber.isValid(a :: string)).to.equal(true)
		end)

		it('is strictly monotonic from L1 to L99 (never cheaper higher)', function()
			local prev = '0'
			for level = 1, LevelConfig.MaxLevel - 1 do
				local cost = UpgradeService.GetUpgradeCost('Chicken', level)
				expect(cost ~= nil).to.equal(true)
				expect(BigNumber.Compare(cost :: string, prev) > 0).to.equal(true)
				prev = cost :: string
			end
		end)

		it('stays BigNumber-exact at high levels (no float dust)', function()
			-- Closed form at L50 (k=49): cost == 100 x 28^49 /
			-- 25^49 exactly. Cross-multiply with integer ops
			-- only: cost x 25^49 must string-equal 100 x 28^49.
			-- A float path would smear the tail and fail the
			-- equality.
			local cost = UpgradeService.GetUpgradeCost('Chicken', 50)
			expect(cost ~= nil).to.equal(true)
			expect(BigNumber.isValid(cost :: string)).to.equal(true)
			local lhs = cost :: string
			for _ = 1, 49 do
				lhs = BigNumber.Multiply(lhs, 25)
			end
			local rhs = '100'
			for _ = 1, 49 do
				rhs = BigNumber.Multiply(rhs, 28)
			end
			expect(lhs).to.equal(rhs)
		end)
	end)
end
