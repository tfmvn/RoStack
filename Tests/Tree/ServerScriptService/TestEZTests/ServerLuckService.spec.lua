--!strict
--!native
--[[
	ServerLuckService.spec
	======================
	Server-wide Luck multiplier for normal egg rarity rolls:

	  * default 1x, Get/Set/Reset surface
	  * invalid values rejected (luck unchanged)
	  * ApplyLuck never mutates the canonical config table
	  * 1x is the identity (baseline weights untouched)
	  * Divine/Secret stay exactly 0 at any luck
	  * higher luck strictly favors rarer tiers (seeded rolls:
	    more Legendary+Mythic at 4x than at 1x)
	  * Mythic remains a small minority even at 4x

	Distribution assertions use Helpers.MakeRng (seeded) through
	the real WeightedDraw.Choose, so they exercise the exact
	production path (lucked weights -> draw).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(ServerScriptService.TestEZTests._Helpers)
	local ServerLuckService = require(ServerScriptService.ServerLuckService)
	local WeightedDraw = require(ReplicatedStorage.Utility.WeightedDraw)
	local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)

	local function rollCounts(weights: { [string]: number }, n: number, seed: number): { [string]: number }
		local counts: { [string]: number } = {}
		local rng = Helpers.MakeRng(seed)
		for _ = 1, n do
			local rarity = WeightedDraw.Choose(weights, rng)
			assert(rarity ~= nil, 'roll must resolve with non-empty weights')
			counts[rarity] = (counts[rarity] or 0) + 1
		end
		return counts
	end

	describe('ServerLuckService luck state', function()
		beforeEach(function()
			ServerLuckService._TestReset()
		end)

		afterEach(function()
			ServerLuckService._TestReset()
		end)

		it('defaults to 1x', function()
			expect(ServerLuckService.GetLuck()).to.equal(1)
			expect(ServerLuckService.DefaultLuck()).to.equal(1)
		end)

		it('SetLuck changes luck and ResetLuck restores 1x', function()
			expect(ServerLuckService.SetLuck(2)).to.equal(true)
			expect(ServerLuckService.GetLuck()).to.equal(2)
			expect(ServerLuckService.SetLuck(4)).to.equal(true)
			expect(ServerLuckService.GetLuck()).to.equal(4)
			expect(ServerLuckService.ResetLuck()).to.equal(true)
			expect(ServerLuckService.GetLuck()).to.equal(1)
		end)

		it('rejects invalid luck without changing state', function()
			expect(ServerLuckService.SetLuck(2)).to.equal(true)
			expect(ServerLuckService.SetLuck(0)).to.equal(false)
			expect(ServerLuckService.SetLuck(-3)).to.equal(false)
			expect(ServerLuckService.SetLuck('4' :: any)).to.equal(false)
			expect(ServerLuckService.SetLuck(nil :: any)).to.equal(false)
			expect(ServerLuckService.SetLuck(0 / 0)).to.equal(false)
			expect(ServerLuckService.SetLuck(math.huge)).to.equal(false)
			expect(ServerLuckService.SetLuck(ServerLuckService.MaxLuck() + 1)).to.equal(false)
			expect(ServerLuckService.GetLuck()).to.equal(2)
		end)

		it('accepts arbitrary positive multipliers including fractionals', function()
			for _, v in ipairs({ 0.5, 1.5, 2.5, 10, 25, 100, 1000 }) do
				expect(ServerLuckService.SetLuck(v)).to.equal(true)
				expect(ServerLuckService.GetLuck()).to.equal(v)
			end
		end)
	end)

	describe('ServerLuckService.ApplyLuck', function()
		beforeEach(function()
			ServerLuckService._TestReset()
		end)

		afterEach(function()
			ServerLuckService._TestReset()
		end)

		it('1x is the identity and never mutates the input', function()
			local before: { [string]: number } = {}
			for rarity, w in pairs(RarityConfig.SpawnWeight) do
				before[rarity] = w
			end
			local lucked = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 1)
			for rarity, w in pairs(before) do
				expect(lucked[rarity]).to.equal(w)
				expect(RarityConfig.SpawnWeight[rarity]).to.equal(w)
			end
		end)

		it('Divine and Secret stay exactly 0 at any luck', function()
			for _, luck in ipairs({ 1, 2, 4 }) do
				local lucked = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, luck)
				expect(lucked['Divine']).to.equal(0)
				expect(lucked['Secret']).to.equal(0)
			end
			-- And the draw itself can never resolve them.
			local counts = rollCounts(ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 4), 5000, 7)
			expect(counts['Divine'] or 0).to.equal(0)
			expect(counts['Secret'] or 0).to.equal(0)
		end)

		it('below-baseline luck favors common tiers', function()
			local low = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 0.5)
			local base = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 1)
			expect(low['Mythic'] < base['Mythic']).to.equal(true)
			expect(low['Legendary'] < base['Legendary']).to.equal(true)
			expect(low['Common']).to.equal(base['Common'])
			expect(low['Divine']).to.equal(0)
		end)

		it('higher luck yields more high-rarity eggs, Mythic stays a minority at 4x', function()
			local base = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 1)
			local lucky = ServerLuckService.ApplyLuck(RarityConfig.SpawnWeight, 4)
			local baseCounts = rollCounts(base, 20000, 1234)
			local luckyCounts = rollCounts(lucky, 20000, 1234)
			local function hiRare(counts: { [string]: number }): number
				return (counts['Legendary'] or 0) + (counts['Mythic'] or 0)
			end
			expect(hiRare(luckyCounts) > hiRare(baseCounts)).to.equal(true)
			expect((luckyCounts['Mythic'] or 0) > (baseCounts['Mythic'] or 0)).to.equal(true)
			-- 4x must not make Mythic common: still a small
			-- minority of all rolls (spec bound: under 5%).
			expect((luckyCounts['Mythic'] or 0) / 20000 < 0.05).to.equal(true)
		end)
	end)
end
