--!strict
--!native
--[[
	RebirthUnlocks.spec
	====================
	Headless-safe coverage for the Rebirth UnlockItems derivation +
	the clone-only showcase helpers. Live viewport rendering,
	Studio templates, and the authored UnlockItems GUI are
	Studio-playtest items — see StandShowcase header.

	Pinned deltas mirror the CURRENT RebirthConfig/GearConfig
	baseline (repo convention: baselines pin so a rebalance can
	never pass silently — update this spec WITH the configs).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local RebirthUnlocks = require(ReplicatedStorage.Utility.RebirthUnlocks)
	local StandShowcase = require(ReplicatedStorage.Utility.StandShowcase)

	describe('RebirthUnlocks.BuildForPreview', function()
		it('R0 -> R1 grants +2 Animal, +1 Arena, and the Rebirth-1 gears', function()
			local unlocks = RebirthUnlocks.BuildForPreview(0, 1)
			expect(#unlocks).to.equal(4)
			expect(unlocks[1].Kind).to.equal('AnimalStand')
			expect(unlocks[1].Amount).to.equal(2)
			expect(unlocks[2].Kind).to.equal('ArenaStand')
			expect(unlocks[2].Amount).to.equal(1)
			expect(unlocks[3].Kind).to.equal('Gear')
			expect(unlocks[3].GearId).to.equal('GravityCoil')
			expect(unlocks[3].Amount).to.equal(1)
			expect(unlocks[4].Kind).to.equal('Gear')
			expect(unlocks[4].GearId).to.equal('GoldBat')
		end)

		it('R1 -> R2 grants only the +1 Arena delta plus Rebirth-2 gears', function()
			local unlocks = RebirthUnlocks.BuildForPreview(1, 2)
			expect(#unlocks).to.equal(3)
			expect(unlocks[1].Kind).to.equal('ArenaStand')
			expect(unlocks[1].Amount).to.equal(1)
			expect(unlocks[2].GearId).to.equal('CoilCombo')
			expect(unlocks[3].GearId).to.equal('DiamondBat')
		end)

		it('R2 -> R3 grants no stands (flat counts) but the Rebirth-3 gear', function()
			local unlocks = RebirthUnlocks.BuildForPreview(2, 3)
			expect(#unlocks).to.equal(1)
			expect(unlocks[1].Kind).to.equal('Gear')
			expect(unlocks[1].GearId).to.equal('ObsidianBat')
		end)

		it('rejects non-sequential, unconfigured, and malformed previews', function()
			expect(#RebirthUnlocks.BuildForPreview(0, 2)).to.equal(0)
			expect(#RebirthUnlocks.BuildForPreview(1, 1)).to.equal(0)
			expect(#RebirthUnlocks.BuildForPreview(3, 4)).to.equal(0)
			expect(#RebirthUnlocks.BuildForPreview(nil :: any, 1)).to.equal(0)
			expect(#RebirthUnlocks.BuildForPreview(0, nil :: any)).to.equal(0)
			expect(#RebirthUnlocks.BuildForPreview(0.5, 1)).to.equal(0)
		end)

		it('never emits zero or negative stand deltas', function()
			for _, entry in ipairs(RebirthUnlocks.BuildForPreview(0, 1)) do
				if entry.Kind == 'AnimalStand' or entry.Kind == 'ArenaStand' then
					expect(entry.Amount > 0).to.equal(true)
				end
			end
		end)
	end)

	describe('RebirthUnlocks text helpers', function()
		it('DisplayName uses plain Stand labels and canonical gear names', function()
			expect(RebirthUnlocks.DisplayName({ Kind = 'AnimalStand', Amount = 1 })).to.equal('Stand')
			expect(RebirthUnlocks.DisplayName({ Kind = 'ArenaStand', Amount = 1 })).to.equal('Stand')
			expect(RebirthUnlocks.DisplayName({ Kind = 'Gear', Amount = 1, GearId = 'GravityCoil' })).to.equal(
				'Gravity Coil'
			)
			-- Unknown gear ids degrade to the id itself, never nil.
			expect(RebirthUnlocks.DisplayName({ Kind = 'Gear', Amount = 1, GearId = 'Nope' })).to.equal('Nope')
			expect(RebirthUnlocks.DisplayName({ Kind = 'Nope', Amount = 1 })).to.equal('?')
		end)

		it('NameColor is white except Arena Stand gold (canonical constants)', function()
			local OverheadConfig = require(ReplicatedStorage.Config.Presentation.UI).Overhead
			expect(RebirthUnlocks.White).to.equal(OverheadConfig.FallbackColor)
			expect(RebirthUnlocks.ArenaGold).to.equal(OverheadConfig.TraitColors.Gold)
			expect(RebirthUnlocks.NameColor({ Kind = 'AnimalStand', Amount = 1 })).to.equal(RebirthUnlocks.White)
			expect(RebirthUnlocks.NameColor({ Kind = 'ArenaStand', Amount = 1 })).to.equal(RebirthUnlocks.ArenaGold)
			expect(RebirthUnlocks.NameColor({ Kind = 'Gear', Amount = 1, GearId = 'GoldBat' })).to.equal(
				RebirthUnlocks.White
			)
			expect(RebirthUnlocks.NameColor(nil :: any)).to.equal(RebirthUnlocks.White)
		end)

		it('NumberVisible hides gear counts, shows stand deltas', function()
			expect(RebirthUnlocks.NumberVisible({ Kind = 'AnimalStand', Amount = 2 })).to.equal(true)
			expect(RebirthUnlocks.NumberVisible({ Kind = 'ArenaStand', Amount = 1 })).to.equal(true)
			expect(RebirthUnlocks.NumberVisible({ Kind = 'Gear', Amount = 1, GearId = 'GoldBat' })).to.equal(false)
			expect(RebirthUnlocks.NumberVisible(nil :: any)).to.equal(true)
		end)

		it('CountText formats deltas as +N, fail-closed', function()
			expect(RebirthUnlocks.CountText(1)).to.equal('+1')
			expect(RebirthUnlocks.CountText(2)).to.equal('+2')
			expect(RebirthUnlocks.CountText(0)).to.equal('+0')
			expect(RebirthUnlocks.CountText(nil)).to.equal('+0')
		end)

		it('Signature is stable and preview-sensitive', function()
			local a = RebirthUnlocks.BuildForPreview(0, 1)
			local b = RebirthUnlocks.BuildForPreview(0, 1)
			expect(RebirthUnlocks.Signature(1, a)).to.equal(RebirthUnlocks.Signature(1, b))
			expect(RebirthUnlocks.Signature(1, a)).never.to.equal(
				RebirthUnlocks.Signature(2, RebirthUnlocks.BuildForPreview(1, 2))
			)
			expect(RebirthUnlocks.Signature(nil :: any, nil :: any)).to.equal('nil:none')
		end)
	end)

	describe('StandShowcase clone-only helpers', function()
		it('StripInteractiveOnly removes UI/prompts but keeps geometry', function()
			local model = Instance.new('Model')
			local part = Instance.new('Part')
			part.Parent = model
			local gui = Instance.new('SurfaceGui')
			gui.Name = 'SurfaceGui'
			gui.Parent = part
			local prompt = Instance.new('ProximityPrompt')
			prompt.Parent = part
			StandShowcase.StripInteractiveOnly(model)
			expect(model:FindFirstChildOfClass('Part')).never.to.equal(nil)
			expect(part:FindFirstChildOfClass('SurfaceGui')).to.equal(nil)
			expect(part:FindFirstChildOfClass('ProximityPrompt')).to.equal(nil)
			model:Destroy()
		end)

		it('FrontYawOffset is nil without a resolvable button (no guessing)', function()
			local model = Instance.new('Model')
			local part = Instance.new('Part')
			part.Parent = model
			expect(StandShowcase.FrontYawOffset(model)).to.equal(nil)
			model:Destroy()
		end)

		it('ClearOutlines removes only ShowcaseOutline siblings', function()
			local card = Instance.new('Frame')
			local outline = Instance.new('ViewportFrame')
			outline.Name = 'ShowcaseOutline3'
			outline.Parent = card
			local main = Instance.new('ViewportFrame')
			main.Name = 'ViewportFrame'
			main.Parent = card
			StandShowcase.ClearOutlines(card)
			expect(card:FindFirstChild('ShowcaseOutline3')).to.equal(nil)
			expect(card:FindFirstChild('ViewportFrame')).never.to.equal(nil)
			card:Destroy()
		end)
	end)
end
