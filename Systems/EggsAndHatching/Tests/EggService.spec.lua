--!strict
--!native
--[[
	EggService.spec
	======================
	Covers: RegisterCenter, GetEgg, Purchase failure paths, the
	HatchRollWeights diagonal guarantee, WeightedDraw determinism.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local Animals = require(ReplicatedStorage.Config.Creatures.Animals)
	local Traits = require(ReplicatedStorage.Config.Creatures.Traits)
	local Rarity = require(ReplicatedStorage.Types.RarityType)
	local WeightedDraw = require(ReplicatedStorage.Utility.WeightedDraw)

	describe('EggService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('RegisterCenter creates the folder structure', function()
			local services = Helpers.WireServices()
			services.EggService.RegisterCenter(game:GetService('Workspace'))
			local area = game:GetService('Workspace'):FindFirstChild('EggArea')
			expect(area).to.be.ok()
			expect(area:FindFirstChild('Floor')).to.be.ok()
			expect(area:FindFirstChild('ActiveEggs')).to.be.ok()
		end)

		it('GetEgg returns nil for unknown id', function()
			local services = Helpers.WireServices()
			expect(services.EggService.GetEgg('nope')).to.equal(nil)
		end)

		it('Purchase on a non-existent egg returns egg-not-found', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.EggService.RegisterCenter(game:GetService('Workspace'))
			local fake = Helpers.FakePlayer(1001)
			local r = services.EggService.Purchase(fake, 'LB_noSuchBlock')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('egg-not-found')
		end)

		it(
			'HatchRollWeights has a non-zero entry for every (blockRarity, brainrotRarity) pair on the diagonal',
			function()
				-- The diagonal of HatchRollWeights (egg rarity X rolled
				-- into rarity X) must always be > 0 so the player has a
				-- chance of getting a same-tier animal even from a
				-- low-rarity egg. Off-diagonal zero entries are fine
				-- (e.g. Secret never rolls Common).
				for blockRarity, weights in pairs(EggConfig.HatchRollWeights) do
					expect(weights[blockRarity] > 0).to.equal(true)
				end
			end
		)

		it('every egg recovers 70-85% on immediate hatch-and-sell (no money printer)', function()
			-- Expected immediate-sale value of a hatch, as a
			-- fraction of egg price, using live config only:
			-- renormalized hatch weights (empty Uncommon/Secret
			-- buckets re-roll per EggService) x uniform 0.75
			-- liquidation x trait-sell EV from live chances.
			-- Float math is fine here: probabilities, never
			-- currency.
			local nonEmpty: { [string]: boolean } = {
				Common = true,
				Rare = true,
				Epic = true,
				Mythic = true,
				Legendary = true,
				Divine = true,
			}
			local traitEV = 0.85 * 1
				+ 0.10 * (tonumber(Traits.Catalog.Gold.SellMultiplier) or 0)
				+ 0.04 * (tonumber(Traits.Catalog.Diamond.SellMultiplier) or 0)
				+ 0.01 * (tonumber(Traits.Catalog.Rainbow.SellMultiplier) or 0)
			for eggRarity, price in pairs(EggConfig.Price) do
				local weights = EggConfig.HatchRollWeights[eggRarity]
				expect(weights).to.be.ok()
				local factor = tonumber((Animals.SellMultiplier :: any)[eggRarity]) or 0
				expect(factor > 0).to.equal(true)
				local mass = 0
				local raw = 0
				for rolled, w in pairs(weights) do
					if nonEmpty[rolled] and type(w) == 'number' then
						mass += w
						raw += w * ((Animals.SellBaseValue :: any)[rolled] or 0)
					end
				end
				expect(mass > 0).to.equal(true)
				-- Mutation sell folds excluded (event-gated
				-- upside, conservatively ignored here).
				local expected = (raw / mass) * factor * traitEV
				local recovery = expected / (price :: number)
				expect(recovery >= 0.7 and recovery <= 0.85).to.equal(true)
			end
		end)

		it('WeightedDraw picks deterministically with a seeded rng', function()
			local weights = {
				[Rarity.Common] = 10,
				[Rarity.Rare] = 5,
			}
			local rng = Helpers.MakeRng(1234)
			local a = WeightedDraw.Choose(weights, rng)
			local rng2 = Helpers.MakeRng(1234)
			local b = WeightedDraw.Choose(weights, rng2)
			expect(a).to.equal(b)
		end)
	end)
end
