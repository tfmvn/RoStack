--!strict
--!native
--[[
	AnimalOverhead.spec
	====================
	Tests for the live Animal overhead GUI (presentation-only
	BillboardGui cloned from the authored
	ServerStorage.Assets.OverheadGui.OverheadGuiTemplate).

	The Studio place owns the real template; specs stage a
	structurally faithful fake (same hierarchy/names) only
	when no template exists, and destroy only what they
	created. All data assertions compare against the SAME
	authoritative calls production uses (AnimalStats,
	MutationConfig, LevelConfig) — the spec locks WIRING
	(correct source -> correct label), not stat math.

	Coverage:
	  1. Exactly one overhead per model (duplicate-safe).
	  2. Fields populated from authoritative state (Name,
	     Level, Income, Rarity, Trait, Health Value, Damage
	     Value, Data mirror; no bar exists).
	  3. Trait hidden when absent; container hidden when no
	     mutations; icons reconciled without duplicates.
	  4. Level-up refresh updates every level-derived field.
	  5. Missing template / missing anchor fail gracefully.
	  6. RemoveForAnimal destroys the overhead.
	  7. Legacy OverheadTemplate clones are migrated away.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ServerStorage = game:GetService('ServerStorage')
	local Workspace = game:GetService('Workspace')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)

	local createdAssets = false
	local createdOverheadFolder = false
	local createdTemplate = false
	local trash: { Instance } = {}

	local function textLabel(name: string, withStroke: boolean, withGradient: boolean): TextLabel
		local label = Instance.new('TextLabel')
		label.Name = name
		label.Text = ''
		if withStroke then
			local stroke = Instance.new('UIStroke')
			stroke.Parent = label
		end
		if withGradient then
			local grad = Instance.new('UIGradient')
			grad.Parent = label
		end
		return label
	end

	local function ensureTemplate(): BillboardGui
		local assets = ServerStorage:FindFirstChild('Assets')
		if not assets then
			assets = Instance.new('Folder')
			assets.Name = 'Assets'
			assets.Parent = ServerStorage
			createdAssets = true
		end
		local overhead = (assets :: Instance):FindFirstChild('OverheadGui')
		if not overhead then
			overhead = Instance.new('Folder')
			overhead.Name = 'OverheadGui'
			overhead.Parent = assets
			createdOverheadFolder = true
		end
		local existing = (overhead :: Instance):FindFirstChild('OverheadGuiTemplate')
		if existing and existing:IsA('BillboardGui') then
			return existing
		end
		local gui = Instance.new('BillboardGui')
		gui.Name = 'OverheadGuiTemplate'
		gui.Size = UDim2.fromOffset(220, 140)
		local container = Instance.new('Frame')
		container.Name = 'Container'
		container.Parent = gui
		local content = Instance.new('Frame')
		content.Name = 'Content'
		content.Parent = container
		local contentLayout = Instance.new('UIListLayout')
		contentLayout.Parent = content
		local income = textLabel('Income', true, true)
		income.Parent = content
		local level = textLabel('Level', true, true)
		level.Parent = content
		local mutations = Instance.new('Frame')
		mutations.Name = 'Mutations'
		mutations.Parent = content
		local mutationLayout = Instance.new('UIListLayout')
		mutationLayout.Parent = mutations
		local mutation1 = Instance.new('ImageLabel')
		mutation1.Name = 'Mutation1'
		mutation1.Parent = mutations
		local nameLabel = textLabel('Name', true, false)
		nameLabel.Parent = content
		local rarity = textLabel('Rarity', true, true)
		rarity.Parent = content
		local stats = Instance.new('Frame')
		stats.Name = 'Stats'
		stats.Parent = content
		local statsLayout = Instance.new('UIListLayout')
		statsLayout.Parent = stats
		local damage = Instance.new('Frame')
		damage.Name = 'Damage'
		damage.Parent = stats
		local damageIcon = Instance.new('ImageLabel')
		damageIcon.Name = 'Icon'
		damageIcon.Parent = damage
		local damageLayout = Instance.new('UIListLayout')
		damageLayout.Parent = damage
		local damageValue = textLabel('Value', true, true)
		damageValue.Parent = damage
		local health = Instance.new('Frame')
		health.Name = 'Health'
		health.Parent = stats
		local healthIcon = Instance.new('ImageLabel')
		healthIcon.Name = 'Icon'
		healthIcon.Parent = health
		local healthLayout = Instance.new('UIListLayout')
		healthLayout.Parent = health
		-- Health mirrors Damage structurally (Icon + Value,
		-- no bar): Value carries Gradient + Stroke.
		local healthValue = textLabel('Value', true, true)
		healthValue.Parent = health
		local trait = textLabel('Trait', true, false)
		do
			-- Already has Stroke from textLabel; no gradient by
			-- design (Rainbow animates the stroke centrally).
		end
		trait.Parent = content
		gui.Parent = overhead
		local data = Instance.new('Folder')
		data.Name = 'Data'
		data.Parent = gui
		for _, key in ipairs({ 'Damage', 'Health', 'MaxHealth' }) do
			local value = Instance.new('NumberValue')
			value.Name = key
			value.Parent = data
		end
		createdTemplate = true
		return gui
	end

	local function makeModel(): (Model, BasePart)
		local model = Instance.new('Model')
		model.Name = 'OverheadSpec'
		local hrp = Instance.new('Part')
		hrp.Name = 'HumanoidRootPart'
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(0, 5, 0)
		hrp.Parent = model
		model.PrimaryPart = hrp
		model.Parent = Workspace
		trash[#trash + 1] = model
		return model, hrp
	end

	local function makeCenter(model: Model): BasePart
		local center = Instance.new('Part')
		center.Name = 'CENTER'
		center.Size = Vector3.new(1, 1, 1)
		center.Anchored = true
		center.CFrame = CFrame.new(0, 8, 0)
		center.Parent = model
		return center
	end

	local function makeRecord(model: Model, overrides: any?): any
		local record: any = {
			uniqueId = 'AN_overhead01',
			definitionId = 'Chicken',
			displayName = 'TestCat',
			Level = 5,
			XP = 0,
			Trait = 'Gold',
			Mutations = { 'Galactic', 'Frost' },
			state = 'Slotted',
			ownerUserId = 9801,
			model = model,
		}
		if type(overrides) == 'table' then
			for k, v in pairs(overrides :: any) do
				record[k] = v
			end
		end
		return record
	end

	local function contentOf(model: Model): Instance
		local center = model:FindFirstChild('CENTER')
		local host = (center or model.PrimaryPart) :: BasePart
		local gui = host:FindFirstChild('OverheadGui')
		assert(gui ~= nil and gui:IsA('BillboardGui'), 'overhead attached')
		local container = (gui :: BillboardGui):FindFirstChild('Container')
		assert(container ~= nil, 'Container present')
		local content = (container :: Instance):FindFirstChild('Content')
		assert(content ~= nil, 'Content present')
		return content
	end

	local function labelText(content: Instance, name: string): string
		local label = content:FindFirstChild(name)
		assert(label ~= nil and label:IsA('TextLabel'), name .. ' present')
		return (label :: TextLabel).Text
	end

	beforeEach(function()
		AnimalOverhead._TestReset()
		ensureTemplate()
	end)

	afterEach(function()
		AnimalOverhead._TestReset()
		for _, inst in ipairs(trash) do
			if inst.Parent then
				inst:Destroy()
			end
		end
		trash = {}
		if createdTemplate then
			local assets = ServerStorage:FindFirstChild('Assets')
			local overhead = assets and (assets :: Instance):FindFirstChild('OverheadGui') or nil
			local template = overhead and (overhead :: Instance):FindFirstChild('OverheadGuiTemplate') or nil
			if template then
				template:Destroy()
			end
			createdTemplate = false
		end
		if createdOverheadFolder then
			local assets = ServerStorage:FindFirstChild('Assets')
			local overhead = assets and (assets :: Instance):FindFirstChild('OverheadGui') or nil
			if overhead then
				overhead:Destroy()
			end
			createdOverheadFolder = false
		end
		if createdAssets then
			local assets = ServerStorage:FindFirstChild('Assets')
			if assets then
				assets:Destroy()
			end
			createdAssets = false
		end
	end)

	describe('AnimalOverhead', function()
		it('creates exactly one overhead on CENTER and populates authoritative fields', function()
			local model = makeModel()
			makeCenter(model)
			local record = makeRecord(model)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local center = model:FindFirstChild('CENTER') :: BasePart
			local count = 0
			for _, child in ipairs(center:GetChildren()) do
				if child:IsA('BillboardGui') and child.Name == 'OverheadGui' then
					count += 1
				end
			end
			expect(count).to.equal(1)
			local content = contentOf(model)
			expect(labelText(content, 'Name')).to.equal('TestCat')
			expect(labelText(content, 'Level')).to.equal('Lv. 5')
			expect(labelText(content, 'Rarity')).to.equal('Common')
			expect(labelText(content, 'Trait')).to.equal('Gold')
			local expectedIncome = '$'
				.. BigNumber.Format(tostring(math.floor(AnimalStats.Calculate(record, 'Income'))))
				.. '/s'
			expect(labelText(content, 'Income')).to.equal(expectedIncome)
			-- Stats + Data from the same canonical snapshot.
			local stats = content:FindFirstChild('Stats')
			assert(stats ~= nil, 'Stats present')
			local damageFrame = (stats :: Instance):FindFirstChild('Damage')
			assert(damageFrame ~= nil, 'Damage present')
			local damageValue = (damageFrame :: Instance):FindFirstChild('Value')
			assert(damageValue ~= nil and damageValue:IsA('TextLabel'), 'Damage Value present')
			expect((damageValue :: TextLabel).Text).to.equal(
				BigNumber.Format(tostring(math.floor(AnimalStats.Calculate(record, 'Damage'))))
			)
			local healthFrame = (stats :: Instance):FindFirstChild('Health')
			assert(healthFrame ~= nil, 'Health present')
			local healthValue = (healthFrame :: Instance):FindFirstChild('Value')
			assert(healthValue ~= nil and healthValue:IsA('TextLabel'), 'Health Value present')
			expect((healthValue :: TextLabel).Text).to.equal(
				BigNumber.Format(tostring(math.floor(AnimalStats.Calculate(record, 'Health'))))
			)
			-- Health mirrors Damage structurally now (Icon +
			-- Value, no bar): assert absence of the retired bar.
			expect((healthFrame :: Instance):FindFirstChild('Bar')).to.equal(nil)
			local gui = center:FindFirstChild('OverheadGui') :: BillboardGui
			local data = (gui :: BillboardGui):FindFirstChild('Data')
			assert(data ~= nil, 'Data present')
			-- Init hardening: explicit render configuration.
			expect(gui.Enabled).to.equal(true)
			expect(gui.Adornee).to.equal(center)
			local function dataValue(name: string): number
				local node = (data :: Instance):FindFirstChild(name)
				assert(node ~= nil and node:IsA('NumberValue'), 'Data.' .. name .. ' present')
				return (node :: NumberValue).Value
			end
			expect(dataValue('Damage')).to.equal(AnimalStats.Calculate(record, 'Damage'))
			expect(dataValue('Health')).to.equal(AnimalStats.Calculate(record, 'Health'))
			expect(dataValue('MaxHealth')).to.equal(AnimalStats.Calculate(record, 'Health'))
		end)

		it('shows a live CurrentHealth override in Value and Data', function()
			local model = makeModel()
			makeCenter(model)
			local record = makeRecord(model)
			local full = AnimalStats.Calculate(record, 'Health')
			record.CurrentHealth = full / 2
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local stats = content:FindFirstChild('Stats')
			assert(stats ~= nil, 'Stats present')
			local healthFrame = (stats :: Instance):FindFirstChild('Health')
			assert(healthFrame ~= nil, 'Health present')
			local healthValue = (healthFrame :: Instance):FindFirstChild('Value')
			assert(healthValue ~= nil and healthValue:IsA('TextLabel'), 'Health Value present')
			expect((healthValue :: TextLabel).Text).to.equal(BigNumber.Format(tostring(math.floor(full / 2))))
			local center = model:FindFirstChild('CENTER') :: BasePart
			local gui = center:FindFirstChild('OverheadGui') :: BillboardGui
			local data = (gui :: BillboardGui):FindFirstChild('Data')
			assert(data ~= nil, 'Data present')
			local healthNode = (data :: Instance):FindFirstChild('Health')
			assert(healthNode ~= nil and healthNode:IsA('NumberValue'), 'Data.Health present')
			expect((healthNode :: NumberValue).Value).to.equal(full / 2)
			local maxNode = (data :: Instance):FindFirstChild('MaxHealth')
			assert(maxNode ~= nil and maxNode:IsA('NumberValue'), 'Data.MaxHealth present')
			expect((maxNode :: NumberValue).Value).to.equal(full)
		end)

		it('hides Trait when absent and Mutations container when empty', function()
			local model = makeModel()
			local record = makeRecord(model, { Trait = nil, Mutations = {} })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local trait = content:FindFirstChild('Trait')
			assert(trait ~= nil and trait:IsA('TextLabel'), 'Trait present')
			expect((trait :: TextLabel).Visible).to.equal(false)
			local container = content:FindFirstChild('Mutations')
			assert(container ~= nil, 'Mutations present')
			expect((container :: Frame).Visible).to.equal(false)
			local icons = 0
			for _, child in ipairs((container :: Instance):GetChildren()) do
				if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
					icons += 1
				end
			end
			expect(icons).to.equal(0)
		end)

		it('reconciles Mutation1-prototype icons without duplicates', function()
			local model = makeModel()
			local record = makeRecord(model, { Mutations = { 'Galactic' } })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local container = content:FindFirstChild('Mutations') :: Instance
			expect((container:FindFirstChild('Galactic') ~= nil)).to.equal(true)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local count = 0
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
					count += 1
				end
			end
			expect(count).to.equal(1)
			record.Mutations = { 'Frost', 'Galactic' }
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(container:FindFirstChild('Frost') ~= nil).to.equal(true)
			expect(container:FindFirstChild('Galactic') ~= nil).to.equal(true)
			expect(container:FindFirstChild('Ancient')).to.equal(nil)
			record.Mutations = { 'Frost', 'Nope', 'Frost' }
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(MutationConfig.SanitizeIds(record.Mutations)).to.equal({ 'Frost' })
			count = 0
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
					count += 1
				end
			end
			expect(count).to.equal(1)
		end)

		it('level-up refresh updates Name, Level, Health, Damage, Income', function()
			local model = makeModel()
			local record = makeRecord(model, { Mutations = {} })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			expect(labelText(content, 'Name')).to.equal('TestCat')
			record.Level = 6
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(labelText(content, 'Name')).to.equal('TestCat')
			expect(labelText(content, 'Level')).to.equal('Lv. 6')
			expect(labelText(content, 'Income')).to.equal(
				'$' .. BigNumber.Format(tostring(math.floor(AnimalStats.Calculate(record, 'Income')))) .. '/s'
			)
			local stats = content:FindFirstChild('Stats')
			assert(stats ~= nil, 'Stats present')
		end)

		it('fails gracefully without template, model, or anchor', function()
			local model = makeModel()
			local record = makeRecord(model)
			model.PrimaryPart = nil
			expect(AnimalOverhead.Refresh(record)).to.equal(false)
			expect(AnimalOverhead._TestFind(record)).to.equal(nil)
			model.PrimaryPart = model:FindFirstChild('HumanoidRootPart')
			local assets = ServerStorage:FindFirstChild('Assets')
			local overhead = assets and (assets :: Instance):FindFirstChild('OverheadGui') or nil
			local template = overhead and (overhead :: Instance):FindFirstChild('OverheadGuiTemplate') or nil
			local parented: Instance? = nil
			if template then
				parented = template.Parent
				template.Parent = nil
			end
			AnimalOverhead._TestReset()
			expect(AnimalOverhead.Refresh(record)).to.equal(false)
			if template and parented then
				template.Parent = parented
			end
			AnimalOverhead._TestReset()
			expect(AnimalOverhead.Refresh({ uniqueId = 'x' })).to.equal(false)
			expect(function()
				AnimalOverhead.RemoveForAnimal(nil)
			end).to.never.throw()
		end)

		it('RemoveForAnimal destroys the overhead', function()
			local model = makeModel()
			local record = makeRecord(model)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(AnimalOverhead._TestFind(record) ~= nil).to.equal(true)
			AnimalOverhead.RemoveForAnimal(record)
			expect(AnimalOverhead._TestFind(record)).to.equal(nil)
		end)

		it('migrates legacy OverheadTemplate clones away', function()
			local model, hrp = makeModel()
			local legacy = Instance.new('BillboardGui')
			legacy.Name = 'OverheadTemplate'
			legacy.Parent = hrp
			local record = makeRecord(model)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(hrp:FindFirstChild('OverheadTemplate')).to.equal(nil)
			expect(hrp:FindFirstChild('OverheadGui') ~= nil).to.equal(true)
		end)

		it('styles Rarity from the canonical rarity color', function()
			local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
			local model = makeModel()
			local record = makeRecord(model, { definitionId = 'Triceratops', displayName = 'Trike' })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			expect(labelText(content, 'Rarity')).to.equal('Legendary')
			local label = content:FindFirstChild('Rarity')
			assert(label ~= nil and label:IsA('TextLabel'), 'Rarity present')
			expect((label :: TextLabel).TextColor3).to.equal(RarityConfig.RarityColor.Legendary)
			local grad = (label :: TextLabel):FindFirstChildOfClass('UIGradient')
			assert(grad ~= nil, 'Rarity gradient present')
			local keys = (grad :: UIGradient).Color.Keypoints
			expect(keys[#keys].Value).to.equal(RarityConfig.RarityColor.Legendary)
		end)

		it('styles Trait per trait and animates Rainbow centrally', function()
			local model = makeModel()
			local record = makeRecord(model, { Trait = 'Gold', Mutations = {} })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local trait = content:FindFirstChild('Trait')
			assert(trait ~= nil and trait:IsA('TextLabel'), 'Trait present')
			expect((trait :: TextLabel).TextColor3).to.equal(Color3.fromRGB(245, 200, 70))
			expect(AnimalOverhead._TestRainbowCount()).to.equal(0)
			record.Trait = 'Rainbow'
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(labelText(content, 'Trait')).to.equal('Rainbow')
			expect(AnimalOverhead._TestRainbowCount()).to.equal(1)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(1)
			record.Trait = 'Diamond'
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(labelText(content, 'Trait')).to.equal('Diamond')
			expect((trait :: TextLabel).TextColor3).to.equal(Color3.fromRGB(150, 225, 255))
			expect(AnimalOverhead._TestRainbowCount()).to.equal(0)
			record.Trait = 'Rainbow'
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(1)
			record.Trait = nil
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect((trait :: TextLabel).Visible).to.equal(false)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(0)
			record.Trait = 'Rainbow'
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(1)
			AnimalOverhead.RemoveForAnimal(record)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(0)
		end)

		it('shares one animation across multiple Rainbow overheads', function()
			local m1 = makeModel()
			local r1 = makeRecord(m1, { uniqueId = 'AN_overhead_r1', Trait = 'Rainbow', Mutations = {} })
			local m2 = makeModel()
			local r2 = makeRecord(m2, { uniqueId = 'AN_overhead_r2', Trait = 'Rainbow', Mutations = {} })
			expect(AnimalOverhead.Refresh(r1)).to.equal(true)
			expect(AnimalOverhead.Refresh(r2)).to.equal(true)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(2)
			AnimalOverhead.RemoveForAnimal(r1)
			expect(AnimalOverhead._TestRainbowCount()).to.equal(1)
			expect(AnimalOverhead._TestFind(r2) ~= nil).to.equal(true)
		end)
	end)

	describe('AnimalOverhead stolen presentation', function()
		it('shows STOLEN in red with only the name visible, record untouched', function()
			local OverheadConfig = require(ReplicatedStorage.Config.Presentation.UI).Overhead
			local model = makeModel()
			makeCenter(model)
			local record = makeRecord(model, { uniqueId = 'AN_stolen01', Trait = 'Gold', Mutations = {} })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local name = content:FindFirstChild('Name')
			assert(name ~= nil and name:IsA('TextLabel'), 'Name present')
			local beforeColor = (name :: TextLabel).TextColor3
			expect(AnimalOverhead.SetStolen(record, true)).to.equal(true)
			expect(AnimalOverhead._TestIsStolen('AN_stolen01')).to.equal(true)
			expect((name :: TextLabel).Text).to.equal('STOLEN')
			expect((name :: TextLabel).TextColor3).to.equal(OverheadConfig.StolenTextColor)
			for _, child in ipairs(content:GetChildren()) do
				if child:IsA('GuiObject') and child.Name ~= 'Name' then
					expect((child :: GuiObject).Visible).to.equal(false)
				end
			end
			-- The record's own identity is never rewritten.
			expect(record.displayName).to.equal('TestCat')
		end)

		it('restores the exact previous look, keeping pre-hidden labels hidden', function()
			local model = makeModel()
			makeCenter(model)
			-- No trait: the Trait label starts hidden (assigned
			-- after construction — pairs() skips nil overrides).
			local record = makeRecord(model, { uniqueId = 'AN_stolen02', Mutations = {} })
			record.Trait = nil
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local trait = content:FindFirstChild('Trait')
			assert(trait ~= nil and trait:IsA('TextLabel'), 'Trait present')
			expect((trait :: TextLabel).Visible).to.equal(false)
			local name = content:FindFirstChild('Name')
			assert(name ~= nil and name:IsA('TextLabel'), 'Name present')
			local beforeText = (name :: TextLabel).Text
			local beforeColor = (name :: TextLabel).TextColor3
			expect(AnimalOverhead.SetStolen(record, true)).to.equal(true)
			expect(AnimalOverhead.SetStolen(record, false)).to.equal(true)
			expect(AnimalOverhead._TestIsStolen('AN_stolen02')).to.equal(false)
			expect((name :: TextLabel).Text).to.equal(beforeText)
			expect((name :: TextLabel).TextColor3).to.equal(beforeColor)
			expect(labelText(content, 'Level')).to.equal('Lv. 5')
			-- Pre-hidden stays hidden (never a blind Visible = true).
			expect((trait :: TextLabel).Visible).to.equal(false)
			local level = content:FindFirstChild('Level')
			assert(level ~= nil and level:IsA('GuiObject'), 'Level present')
			expect((level :: GuiObject).Visible).to.equal(true)
		end)

		it('is idempotent and safe without a live overhead', function()
			local model = makeModel()
			makeCenter(model)
			local record = makeRecord(model, { uniqueId = 'AN_stolen03', Trait = 'Gold', Mutations = {} })
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			expect(AnimalOverhead.SetStolen(record, true)).to.equal(true)
			-- Second steal re-applies without clobbering originals.
			expect(AnimalOverhead.SetStolen(record, true)).to.equal(true)
			expect(AnimalOverhead.SetStolen(record, false)).to.equal(true)
			expect(labelText(content, 'Name')).to.equal('TestCat')
			-- Clearing a never-stolen animal is a clean no-op.
			expect(AnimalOverhead.SetStolen(record, false)).to.equal(true)
			expect(AnimalOverhead._TestIsStolen('AN_stolen03')).to.equal(false)
			-- No model/gui at all: set fails safe, clear is a no-op.
			local ghost: any = { uniqueId = 'AN_stolen_ghost', model = nil }
			expect(AnimalOverhead.SetStolen(ghost, true)).to.equal(false)
			expect(AnimalOverhead.SetStolen(ghost, false)).to.equal(true)
			expect(AnimalOverhead.SetStolen(nil, true)).to.equal(false)
		end)
	end)
end
