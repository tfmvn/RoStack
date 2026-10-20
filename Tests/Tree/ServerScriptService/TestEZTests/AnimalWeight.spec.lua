--!strict
--!native
--[[
	AnimalWeight.spec
	=================
	Tests for the authoritative weight / physical-growth layer
	(ReplicatedStorage/Utility/AnimalWeight.lua).

	Locks in (§16 acceptance, calculator half):
	  * Level 1 = Base exactly; MaxLevel = Maximum exactly.
	  * Strictly increasing log curve between; capped at Maximum
	    (Weight <= Maximum ALWAYS, even past MaxLevel).
	  * GrowthAlpha 0 -> 1 across the curve; multiplier
	    1.00 -> MaxGrowthScale.
	  * Per-definition override beats the rarity row.
	  * Unknown def / bad input fails safe to nil (celebration
	    unaffected), never throws.
	  * GetTargetScale = baseScale * multiplier; missing baseScale
	    (or bad record) -> nil, never throws, never compounds
	    (pure function of baseline, not of live scale).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local AnimalWeight = require(ReplicatedStorage.Utility.AnimalWeight)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)

	local MAX = LevelConfig.MaxLevel

	describe('AnimalWeight.CalculateWeight', function()
		it('returns Base at Level 1 and Maximum at MaxLevel (Common)', function()
			expect(AnimalWeight.CalculateWeight('Chicken', 1)).to.equal(10)
			expect(AnimalWeight.CalculateWeight('Chicken', MAX)).to.equal(40)
		end)

		it('is strictly increasing across the curve and capped', function()
			local prev = AnimalWeight.CalculateWeight('Chicken', 1) :: number
			for level = 2, MAX do
				local w = AnimalWeight.CalculateWeight('Chicken', level) :: number
				expect(w > prev).to.equal(true)
				expect(w <= 40).to.equal(true)
				prev = w
			end
		end)

		it('levels up visibly from L1 (L2 weight > Base)', function()
			local w2 = AnimalWeight.CalculateWeight('Chicken', 2) :: number
			expect(w2 > 10).to.equal(true)
		end)

		it('caps past MaxLevel (Weight <= Maximum ALWAYS)', function()
			expect(AnimalWeight.CalculateWeight('Chicken', MAX + 50)).to.equal(40)
		end)

		it('repairs malformed levels instead of throwing', function()
			expect(AnimalWeight.CalculateWeight('Chicken', 0)).to.equal(10)
			expect(AnimalWeight.CalculateWeight('Chicken', -5)).to.equal(10)
			expect(AnimalWeight.CalculateWeight('Chicken', 'x' :: any)).to.equal(10)
			expect(AnimalWeight.CalculateWeight('Chicken', nil :: any)).to.equal(10)
		end)

		it('fails safe to nil on unknown definitions', function()
			expect(AnimalWeight.CalculateWeight('Nope_NotReal', 10)).to.equal(nil)
			expect(AnimalWeight.CalculateWeight('', 10)).to.equal(nil)
			expect(AnimalWeight.CalculateWeight(nil :: any, 10)).to.equal(nil)
		end)

		it('scales per rarity (Dragon row differs from Chicken row)', function()
			local dragon = AnimalWeight.CalculateWeight('Dragon', 50) :: number
			local chicken = AnimalWeight.CalculateWeight('Chicken', 50) :: number
			expect(dragon > chicken).to.equal(true)
			expect(AnimalWeight.CalculateWeight('Dragon', 1)).to.equal(700)
			expect(AnimalWeight.CalculateWeight('Dragon', MAX)).to.equal(2800)
		end)
	end)

	describe('AnimalWeight.GrowthAlpha', function()
		it('spans 0 -> 1 across the curve', function()
			expect(AnimalWeight.GrowthAlpha('Chicken', 1)).to.equal(0)
			expect(AnimalWeight.GrowthAlpha('Chicken', MAX)).to.equal(1)
			local mid = AnimalWeight.GrowthAlpha('Chicken', 50) :: number
			expect(mid > 0 and mid < 1).to.equal(true)
		end)
	end)

	describe('AnimalWeight.GetGrowthMultiplier', function()
		it('spans 1.00 -> MaxGrowthScale', function()
			expect(AnimalWeight.GetGrowthMultiplier('Chicken', 1)).to.equal(1)
			expect(AnimalWeight.GetGrowthMultiplier('Chicken', MAX)).to.equal(AnimalWeight.MaxGrowthScale)
			local mid = AnimalWeight.GetGrowthMultiplier('Chicken', 50) :: number
			expect(mid > 1 and mid < AnimalWeight.MaxGrowthScale).to.equal(true)
		end)
	end)

	describe('AnimalWeight.GetTargetScale', function()
		it('is baseScale * multiplier (relative, never universal)', function()
			local target = AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = 1, baseScale = 1.8 })
			expect(target).to.equal(1.8)
			local grown = AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = MAX, baseScale = 1.8 })
			expect(grown).to.equal(1.8 * AnimalWeight.MaxGrowthScale)
		end)

		it('never compounds: same inputs always give the same target', function()
			local a = AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = 50, baseScale = 1 })
			local b = AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = 50, baseScale = 1 })
			expect(a).to.equal(b)
		end)

		it('returns nil (no throw) without a baseline or record', function()
			expect(AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = 50 })).to.equal(nil)
			expect(AnimalWeight.GetTargetScale({ definitionId = 'Chicken', Level = 50, baseScale = 0 })).to.equal(nil)
			expect(AnimalWeight.GetTargetScale(nil)).to.equal(nil)
			expect(AnimalWeight.GetTargetScale('nope' :: any)).to.equal(nil)
			expect(AnimalWeight.GetTargetScale({ definitionId = 'Nope_NotReal', Level = 5, baseScale = 1 })).to.equal(
				nil
			)
		end)
	end)
end
