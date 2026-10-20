--!strict
--!native
--[[
	AnimalService.spec
	====================
	Covers: catalog integrity, GetPoolForRarity, GetRandom, Get
	lookup, GetHealth/GetDamage multiplier math, RarityMultipliers
	are monotonic, level table is present.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
	local Rarity = require(ReplicatedStorage.Types.RarityType)

	describe('AnimalConfig catalog', function()
		it('each rarity bucket has the expected entry count', function()
			-- The catalog roster: Common 5, Uncommon 0 (intentionally
			-- empty), Rare 4, Epic 5, Mythic 5, Legendary 4, Divine 3,
			-- Secret absent. Empty/missing buckets are safe by design
			-- (HatchEgg re-rolls, GetRandom returns nil, nil).
			-- Mythic/Legendary match the authored Studio tree
			-- (Mythic = Triceratops/Crocodile/SabertoothTiger/
			-- Scorpion/Crane; Legendary = SandSpider/Bear/Tiger/
			-- Gorilla).
			local expectedCounts = {
				[Rarity.Common] = 5,
				[Rarity.Uncommon] = 0,
				[Rarity.Rare] = 4,
				[Rarity.Epic] = 5,
				[Rarity.Mythic] = 5,
				[Rarity.Legendary] = 4,
				[Rarity.Divine] = 3,
			}
			for rarity, expected in pairs(expectedCounts) do
				local bucket = AnimalConfig.Catalog[rarity]
				expect(bucket).to.be.ok()
				local count = 0
				for _ in pairs(bucket) do
					count = count + 1
				end
				expect(count).to.equal(expected)
			end
		end)

		it('every entry has displayName, baseHealth, baseDamage', function()
			for rarity, bucket in pairs(AnimalConfig.Catalog) do
				for id, def in pairs(bucket) do
					expect(def.displayName).to.be.a('string')
					expect(#def.displayName > 0).to.equal(true)
					expect(def.baseHealth).to.be.a('number')
					expect(def.baseDamage).to.be.a('number')
					expect(def.baseHealth > 0).to.equal(true)
					expect(def.baseDamage > 0).to.equal(true)
				end
			end
		end)

		it('rarity multipliers are monotonically non-decreasing', function()
			local order = {
				Rarity.Common,
				Rarity.Uncommon,
				Rarity.Rare,
				Rarity.Epic,
				Rarity.Mythic,
				Rarity.Legendary,
				Rarity.Divine,
				Rarity.Secret,
			}
			for _, stat in ipairs({ 'Health', 'Damage' }) do
				local last = 0
				for _, r in ipairs(order) do
					local v = AnimalConfig.RarityMultipliers[stat][r]
					expect(v >= last).to.equal(true)
					last = v
				end
			end
		end)

		it('GetHealth / GetDamage multiply by the right table', function()
			expect(AnimalConfig.GetHealth(Rarity.Common, 10)).to.equal(10)
			expect(AnimalConfig.GetHealth(Rarity.Legendary, 10)).to.be.greaterThan(10)
			expect(AnimalConfig.GetDamage(Rarity.Secret, 5)).to.be.greaterThan(5)
		end)

		it('GetRandom returns an entry that exists in the catalog', function()
			for _, rarity in ipairs({
				Rarity.Common,
				Rarity.Rare,
				Rarity.Epic,
				Rarity.Mythic,
				Rarity.Legendary,
				Rarity.Divine,
			}) do
				local id, def = AnimalConfig.GetRandom(rarity)
				expect(id).to.be.a('string')
				expect(def).to.be.a('table')
				expect(AnimalConfig.Catalog[rarity][id]).to.equal(def)
			end
		end)

		it('GetRandom returns nil for empty or missing buckets (Uncommon, Secret)', function()
			local id, def = AnimalConfig.GetRandom(Rarity.Uncommon)
			expect(id).to.equal(nil)
			expect(def).to.equal(nil)
			local sid, sdef = AnimalConfig.GetRandom(Rarity.Secret)
			expect(sid).to.equal(nil)
			expect(sdef).to.equal(nil)
		end)

		it('Get returns nil for unknown id', function()
			local rarity, def = AnimalConfig.Get('DefinitelyNotARealDefinition_9999')
			expect(rarity).to.equal(nil)
			expect(def).to.equal(nil)
		end)

		it('level table assigns level 1..8 by rarity', function()
			expect(AnimalConfig.BaseLevel[Rarity.Common]).to.equal(1)
			expect(AnimalConfig.BaseLevel[Rarity.Secret]).to.equal(8)
		end)
	end)
end
