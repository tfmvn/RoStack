--!strict
--!native
--[[
	StandMenu.spec
	===============
	Headless coverage for StandDisplayService MenuGui
	reconciliation: template cloning, full-size single-button
	layout (no list layout), live text, idempotency, state
	transitions, arena rules (upgrade only, never sell), and
	fail-safe template gaps.
]]

return function()
	local ServerStorage = game:GetService('ServerStorage')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local UID = 960001

	local function installTemplates(withTitle: boolean)
		local assets = Instance.new('Folder')
		assets.Name = 'Assets'
		local map = Instance.new('Folder')
		map.Name = 'Map'
		map.Parent = assets
		local bases = Instance.new('Folder')
		bases.Name = 'Bases'
		bases.Parent = map
		local base = Instance.new('Folder')
		base.Name = 'Base'
		base.Parent = bases
		local ui = Instance.new('Folder')
		ui.Name = 'Ui'
		ui.Parent = base
		local standUi = Instance.new('Folder')
		standUi.Name = 'Stand'
		standUi.Parent = ui
		local upgrade = Instance.new('TextButton')
		upgrade.Name = 'UpgradeButtonTemplate'
		upgrade.Size = UDim2.new(0.8, 0, 0.3, 0)
		local level = Instance.new('TextLabel')
		level.Name = 'Level'
		level.Parent = upgrade
		local cost = Instance.new('TextLabel')
		cost.Name = 'UpgradeAmount'
		cost.Parent = upgrade
		upgrade.Parent = standUi
		local sell = Instance.new('TextButton')
		sell.Name = 'SellButtonTemplate'
		sell.Size = UDim2.new(0.8, 0, 0.3, 0)
		if withTitle then
			local title = Instance.new('TextLabel')
			title.Name = 'Title'
			title.Parent = sell
			local amount = Instance.new('TextLabel')
			amount.Name = 'SellAmount'
			amount.Parent = sell
		end
		sell.Parent = standUi
		assets.Parent = ServerStorage
		return assets
	end

	local function menuStand()
		local stand = Instance.new('Model')
		stand.Name = 'Stand9'
		local slot = Instance.new('Part')
		slot.Name = 'Slot'
		local root = Instance.new('Part')
		root.Name = 'Root'
		root.Parent = slot
		local menuPart = Instance.new('Part')
		menuPart.Name = 'MenuPart'
		local menuGui = Instance.new('SurfaceGui')
		menuGui.Name = 'MenuGui'
		menuGui.Parent = menuPart
		menuPart.Parent = slot
		slot.Parent = stand
		return { stand = stand, menuGui = menuGui }
	end

	local function wireRefs(animal: any?, egg: any?)
		local StandDisplayService = require(game:GetService('ServerScriptService').Base.StandDisplayService)
		StandDisplayService.SetAnimalService({
			Get = function(_uniqueId: string)
				return animal
			end,
		})
		StandDisplayService.SetUpgradeService({
			GetUpgradeCost = function(_defId: string, _level: number)
				return '1000'
			end,
		})
		StandDisplayService.SetSellService({
			GetAnimalTotalPayout = function(_defId: string, _level: number, _pool: string, _trait: any, _muts: any)
				return '5000'
			end,
			GetEggSellValue = function(_rarity: string, _muts: any, _trait: any)
				return '750'
			end,
		})
		StandDisplayService.SetEggService({
			GetEgg = function(_uniqueId: string)
				return egg
			end,
		})
		StandDisplayService.SetPlayerService({
			GetPlayerData = function(_userId: number)
				return { Brainrots = { { Id = 'AN_m1', Type = 'Brainrot', CashPool = '200' } } }
			end,
		})
		return StandDisplayService
	end

	local function unwireRefs()
		local StandDisplayService = require(game:GetService('ServerScriptService').Base.StandDisplayService)
		StandDisplayService.SetAnimalService(nil)
		StandDisplayService.SetUpgradeService(nil)
		StandDisplayService.SetSellService(nil)
		StandDisplayService.SetEggService(nil)
		StandDisplayService.SetPlayerService(nil)
	end

	local function animalSlot(stand: Instance, arena: boolean): any
		return {
			id = SlotType.BuildId(UID, SlotType.Kind.Slot, if arena then 1001 else 3),
			ownerUserId = UID,
			baseId = 'Base_MenuSpec',
			kind = SlotType.Kind.Slot,
			index = if arena then 1001 else 3,
			arena = if arena then true else nil,
			state = SlotType.State.Occupied,
			occupantId = 'AN_m1',
			occupantKind = SlotType.OccupantKind.Animal,
			_mutex = false,
			part = nil,
			cashCollector = nil,
			stand = stand,
			standIndex = 1,
			offset = Vector3.new(0, 2, 0),
		}
	end

	local TEST_ANIMAL = {
		uniqueId = 'AN_m1',
		definitionId = 'Tiger',
		displayName = 'TestTiger',
		rarity = 'Epic',
		ownerUserId = UID,
		state = 'Slotted',
		slotId = SlotType.BuildId(UID, SlotType.Kind.Slot, 3),
		Level = 5,
		XP = 0,
		Trait = nil,
		Mutations = {},
	}

	describe('StandMenu reconciliation', function()
		it('builds Upgrade only from templates: no SellButton anywhere', function()
			local assets = installTemplates(true)
			local built = menuStand()
			local svc = wireRefs(TEST_ANIMAL, nil)
			local slot = animalSlot(built.stand, false)
			svc.RefreshSlot(slot)
			local layoutCount = 0
			local upgrades: { Instance } = {}
			local sells: { Instance } = {}
			for _, child in ipairs(built.menuGui:GetChildren()) do
				if child:IsA('UIListLayout') then
					layoutCount += 1
				elseif child.Name == 'UpgradeButton' then
					upgrades[#upgrades + 1] = child
				elseif child.Name == 'SellButton' then
					sells[#sells + 1] = child
				end
			end
			-- Single-button menu: no list layout of any kind.
			expect(layoutCount).to.equal(0)
			expect(#upgrades).to.equal(1)
			expect(#sells).to.equal(0)
			-- Full MenuGui coverage (template sizing overridden).
			local button = upgrades[1] :: GuiObject
			expect(button.AnchorPoint).to.equal(Vector2.new(0, 0))
			expect(button.Position).to.equal(UDim2.fromScale(0, 0))
			expect(button.Size).to.equal(UDim2.fromScale(1, 1))
			-- Routing stamp for the client bind.
			expect((upgrades[1] :: Instance):GetAttribute('slotId')).to.equal(slot.id)
			-- Upgrade readout painted on the clone.
			local level = (upgrades[1] :: Instance):FindFirstChild('Level')
			expect((level :: TextLabel).Text).to.equal('5 >> 6')
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
		end)

		it('is idempotent across repeated refreshes', function()
			local assets = installTemplates(true)
			local built = menuStand()
			local svc = wireRefs(TEST_ANIMAL, nil)
			local slot = animalSlot(built.stand, false)
			svc.RefreshSlot(slot)
			svc.RefreshSlot(slot)
			svc.RefreshSlot(slot)
			local upgrades = 0
			local sells = 0
			local layouts = 0
			for _, child in ipairs(built.menuGui:GetChildren()) do
				if child:IsA('UIListLayout') then
					layouts += 1
				elseif child.Name == 'UpgradeButton' then
					upgrades += 1
				elseif child.Name == 'SellButton' then
					sells += 1
				end
			end
			expect(layouts).to.equal(0)
			expect(upgrades).to.equal(1)
			expect(sells).to.equal(0)
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
		end)

		it('clears to empty and rebuilds across transitions; eggs get no buttons', function()
			local assets = installTemplates(true)
			local built = menuStand()
			local svc = wireRefs(TEST_ANIMAL, {
				uniqueId = 'EG_e1',
				ownerUserId = UID,
				state = 'Placed',
				rarity = 'Common',
				Mutations = {},
				Trait = '',
			})
			local slot = animalSlot(built.stand, false)
			svc.RefreshSlot(slot)
			expect(built.menuGui:FindFirstChild('UpgradeButton')).to.be.ok()
			-- Animal leaves: managed button destroyed (no layout
			-- is kept or needed for the single-button menu).
			slot.state = SlotType.State.Empty
			slot.occupantId = nil
			slot.occupantKind = nil
			svc.RefreshSlot(slot)
			expect(built.menuGui:FindFirstChild('UpgradeButton')).to.equal(nil)
			expect(built.menuGui:FindFirstChild('SellButton')).to.equal(nil)
			-- Egg arrives: no buttons at all (eggs are not
			-- sellable and cannot upgrade).
			slot.state = SlotType.State.Occupied
			slot.occupantId = 'EG_e1'
			slot.occupantKind = SlotType.OccupantKind.Egg
			svc.RefreshSlot(slot)
			expect(built.menuGui:FindFirstChild('UpgradeButton')).to.equal(nil)
			expect(built.menuGui:FindFirstChild('SellButton')).to.equal(nil)
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
		end)

		it('gives arena animals the identical Upgrade-only menu', function()
			local assets = installTemplates(true)
			local built = menuStand()
			local svc = wireRefs(TEST_ANIMAL, nil)
			local slot = animalSlot(built.stand, true)
			svc.RefreshSlot(slot)
			local upgrade = built.menuGui:FindFirstChild('UpgradeButton')
			local sell = built.menuGui:FindFirstChild('SellButton')
			expect(upgrade).to.be.ok()
			expect(sell).to.equal(nil)
			-- Parity: same full-coverage geometry as normal
			-- stands (no separate arena sizing).
			local button = upgrade :: GuiObject
			expect(button.AnchorPoint).to.equal(Vector2.new(0, 0))
			expect(button.Position).to.equal(UDim2.fromScale(0, 0))
			expect(button.Size).to.equal(UDim2.fromScale(1, 1))
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
		end)

		it('fails safe on missing templates and missing labels', function()
			local assets = installTemplates(false)
			local built = menuStand()
			local svc = wireRefs(TEST_ANIMAL, nil)
			local slot = animalSlot(built.stand, false)
			-- No crash; upgrade readout still paints (its
			-- labels exist); no SellButton regardless.
			svc.RefreshSlot(slot)
			expect(built.menuGui:FindFirstChild('SellButton')).to.equal(nil)
			local level = built.menuGui:FindFirstChild('UpgradeButton')
			expect(level).to.be.ok()
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
			-- Templates wholly absent: no buttons, no crash.
			local built2 = menuStand()
			local svc2 = wireRefs(TEST_ANIMAL, nil)
			svc2.RefreshSlot(animalSlot(built2.stand, false))
			expect(built2.menuGui:FindFirstChild('UpgradeButton')).to.equal(nil)
			expect(built2.menuGui:FindFirstChild('SellButton')).to.equal(nil)
			unwireRefs()
			built2.stand:Destroy()
		end)
		it('hides authored SellButtons while keeping authored UpgradeButtons full-size', function()
			local assets = installTemplates(true)
			local built = menuStand()
			-- Authored direct buttons (no managed tag): Upgrade
			-- is reused and fitted to full coverage; authored
			-- Sell is hidden (never destroyed, never bound,
			-- never affording).
			local authoredU = Instance.new('TextButton')
			authoredU.Name = 'UpgradeButton'
			authoredU.Parent = built.menuGui
			local authoredS = Instance.new('TextButton')
			authoredS.Name = 'SellButton'
			authoredS.Parent = built.menuGui
			local svc = wireRefs(TEST_ANIMAL, nil)
			svc.RefreshSlot(animalSlot(built.stand, false))
			local upgrades = 0
			for _, child in ipairs(built.menuGui:GetChildren()) do
				if child.Name == 'UpgradeButton' then
					upgrades += 1
					expect((child :: GuiObject).Size).to.equal(UDim2.fromScale(1, 1))
				end
			end
			expect(upgrades).to.equal(1)
			expect((authoredS :: GuiObject).Visible).to.equal(false)
			unwireRefs()
			built.stand:Destroy()
			assets:Destroy()
		end)
	end)
end
