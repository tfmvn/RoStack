--!strict
--!native
--[[
	ArenaDeployment.spec
	====================
	Headless coverage for Arena animal presentation +
	stand occupancy, driven by ONE authority (the raid
	session team):

	  * Overhead: transient combat records carrying
	    `arenaDeployed` hide Content.Income; normal records
	    keep it visible; the state reverses on flag clear.
	    All other fields (Name, Rarity, Level, Mutations,
	    Trait, Damage, Health) are untouched.
	  * Stand parking: AnimalService.SetArenaDeployed parks
	    (Parent = nil, slotId unchanged) and restores (exact
	    prior container) idempotently; unknown ids fail safe;
	    destroy paths purge parked entries.
	  * Raid wiring: terminate (victory/defeat) and leave
	    restore every session-team member through the
	    injected AnimalService — exactly once per animal.

	The Studio place owns the real overhead template; specs
	stage a structurally faithful fake only when none
	exists, and destroy only what they created (same
	convention as AnimalOverhead.spec).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ServerStorage = game:GetService('ServerStorage')
	local Workspace = game:GetService('Workspace')

	local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
	local AnimalService = require(ServerScriptService.AnimalService)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)

	local trash: { Instance } = {}
	local createdAssets = false
	local createdOverheadFolder = false
	local createdTemplate = false

	local function textLabel(name: string): TextLabel
		local label = Instance.new('TextLabel')
		label.Name = name
		label.Text = ''
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
		textLabel('Income').Parent = content
		textLabel('Level').Parent = content
		local mutations = Instance.new('Frame')
		mutations.Name = 'Mutations'
		mutations.Parent = content
		local mutation1 = Instance.new('ImageLabel')
		mutation1.Name = 'Mutation1'
		mutation1.Parent = mutations
		textLabel('Name').Parent = content
		textLabel('Rarity').Parent = content
		local stats = Instance.new('Frame')
		stats.Name = 'Stats'
		stats.Parent = content
		for _, frameName in ipairs({ 'Damage', 'Health' }) do
			local frame = Instance.new('Frame')
			frame.Name = frameName
			frame.Parent = stats
			textLabel('Value').Parent = frame
		end
		textLabel('Trait').Parent = content
		gui.Parent = overhead
		createdTemplate = true
		return gui
	end

	local function makeModel(): (Model, BasePart)
		local model = Instance.new('Model')
		model.Name = 'DeploySpec'
		local center = Instance.new('Part')
		center.Name = 'CENTER'
		center.Size = Vector3.new(1, 1, 1)
		center.Anchored = true
		center.CFrame = CFrame.new(0, 8, 0)
		center.Parent = model
		model.PrimaryPart = center
		model.Parent = Workspace
		trash[#trash + 1] = model
		return model, center
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

	local function combatRecord(model: Model, deployed: boolean?): any
		return {
			uniqueId = 'Arena_1_P-1-1',
			definitionId = 'Dog',
			displayName = 'Dog',
			Level = 8,
			Trait = nil,
			Mutations = {},
			model = model,
			CurrentHealth = 50,
			arenaDeployed = if deployed == false then nil else true,
		}
	end

	beforeEach(function()
		AnimalOverhead._TestReset()
		ensureTemplate()
	end)

	afterEach(function()
		AnimalOverhead._TestReset()
		AnimalService._TestResetArenaDeployment()
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

	describe('Arena overhead Generation visibility', function()
		it('hides Income on arena combat records, keeps every other field', function()
			local model, _ = makeModel()
			expect(AnimalOverhead.Refresh(combatRecord(model))).to.equal(true)
			local content = contentOf(model)
			local income = content:FindFirstChild('Income')
			assert(income ~= nil and income:IsA('GuiObject'), 'Income present')
			expect((income :: GuiObject).Visible).to.equal(false)
			-- Everything else stays visible and populated.
			for _, name in ipairs({ 'Name', 'Level', 'Rarity', 'Stats', 'Trait', 'Mutations' }) do
				local node = content:FindFirstChild(name)
				assert(node ~= nil and node:IsA('GuiObject'), name .. ' present')
				expect((node :: GuiObject).Visible).to.equal(true)
			end
			local nameLabel = content:FindFirstChild('Name')
			expect((nameLabel :: TextLabel).Text).to.equal('Dog')
		end)

		it('keeps Income visible on normal records', function()
			local model, _ = makeModel()
			local record = combatRecord(model, false)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local content = contentOf(model)
			local income = content:FindFirstChild('Income')
			assert(income ~= nil and income:IsA('GuiObject'), 'Income present')
			expect((income :: GuiObject).Visible).to.equal(true)
			expect((income :: TextLabel).Text ~= '').to.equal(true)
		end)

		it('reverses when the arena flag clears (no stale hidden state)', function()
			local model, _ = makeModel()
			local record = combatRecord(model)
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			local income = contentOf(model):FindFirstChild('Income')
			assert(income ~= nil and income:IsA('GuiObject'), 'Income present')
			expect((income :: GuiObject).Visible).to.equal(false)
			record.arenaDeployed = nil
			expect(AnimalOverhead.Refresh(record)).to.equal(true)
			expect((income :: GuiObject).Visible).to.equal(true)
		end)
	end)

	describe('AnimalService arena stand parking', function()
		local function parkFolder(): Folder
			local folder = Instance.new('Folder')
			folder.Name = 'DeployStandHome'
			folder.Parent = Workspace
			trash[#trash + 1] = folder
			return folder
		end

		local function standRecord(model: Model): any
			return {
				uniqueId = 'AD_park1',
				definitionId = 'Dog',
				displayName = 'Dog',
				rarity = 'Common',
				ownerUserId = 441,
				slotId = 'arena:441:1',
				Level = 8,
				Trait = nil,
				Mutations = {},
				state = 'Slotted',
				model = model,
			}
		end

		it('parks and restores to the exact prior container, slotId untouched', function()
			local home = parkFolder()
			local model, _ = makeModel()
			model.Parent = home
			local record = standRecord(model)
			expect(AnimalService._TestRegister(record)).to.equal(true)
			expect(AnimalService.SetArenaDeployed('AD_park1', true)).to.equal(true)
			expect(AnimalService.IsArenaDeployed('AD_park1')).to.equal(true)
			expect(model.Parent).to.equal(nil)
			-- Persistence-facing identity is unchanged.
			expect(record.slotId).to.equal('arena:441:1')
			expect(record.state).to.equal('Slotted')
			expect(record.Level).to.equal(8)
			expect(AnimalService.SetArenaDeployed('AD_park1', false)).to.equal(true)
			expect(AnimalService.IsArenaDeployed('AD_park1')).to.equal(false)
			expect(model.Parent).to.equal(home)
			expect(AnimalService._TestArenaParkedCount()).to.equal(0)
			AnimalService._TestUnregister('AD_park1')
		end)

		it('is idempotent: repeat deploy/restore never duplicates or strands', function()
			local home = parkFolder()
			local model, _ = makeModel()
			model.Parent = home
			expect(AnimalService._TestRegister(standRecord(model))).to.equal(true)
			expect(AnimalService.SetArenaDeployed('AD_park1', true)).to.equal(true)
			expect(AnimalService.SetArenaDeployed('AD_park1', true)).to.equal(true)
			expect(AnimalService._TestArenaParkedCount()).to.equal(1)
			expect(model.Parent).to.equal(nil)
			expect(AnimalService.SetArenaDeployed('AD_park1', false)).to.equal(true)
			expect(AnimalService.SetArenaDeployed('AD_park1', false)).to.equal(true)
			expect(model.Parent).to.equal(home)
			expect(AnimalService._TestArenaParkedCount()).to.equal(0)
			AnimalService._TestUnregister('AD_park1')
		end)

		it('fails safe on unknown ids', function()
			expect(AnimalService.SetArenaDeployed('AD_nope', true)).to.equal(false)
			expect(AnimalService.IsArenaDeployed('AD_nope')).to.equal(false)
			expect(AnimalService.SetArenaDeployed('AD_nope', false)).to.equal(true)
			expect(AnimalService._TestArenaParkedCount()).to.equal(0)
		end)

		it('restore with a destroyed record drops the entry without throwing', function()
			local home = parkFolder()
			local model, _ = makeModel()
			model.Parent = home
			expect(AnimalService._TestRegister(standRecord(model))).to.equal(true)
			expect(AnimalService.SetArenaDeployed('AD_park1', true)).to.equal(true)
			-- Leave sweep ran first (record + model gone).
			AnimalService._TestUnregister('AD_park1')
			model:Destroy()
			expect(AnimalService.SetArenaDeployed('AD_park1', false)).to.equal(false)
			expect(AnimalService._TestArenaParkedCount()).to.equal(0)
		end)
	end)

	describe('Arena stand menu deployment readout', function()
		local StandDisplayService = require(ServerScriptService.Base.StandDisplayService)
		local deployedFlag = false

		local function menuStand(): (Model, TextButton, TextLabel)
			local stand = Instance.new('Model')
			stand.Name = 'ArenaStandX'
			local slotPart = Instance.new('Part')
			slotPart.Name = 'Slot'
			slotPart.Anchored = true
			slotPart.Parent = stand
			local menuPart = Instance.new('Part')
			menuPart.Name = 'MenuPart'
			menuPart.Anchored = true
			menuPart.Parent = slotPart
			local menuGui = Instance.new('SurfaceGui')
			menuGui.Name = 'MenuGui'
			menuGui.Parent = menuPart
			local upgrade = Instance.new('TextButton')
			upgrade.Name = 'UpgradeButton'
			upgrade.Visible = true
			upgrade.Parent = menuGui
			local level = Instance.new('TextLabel')
			level.Name = 'Level'
			level.Parent = upgrade
			local cost = Instance.new('TextLabel')
			cost.Name = 'UpgradeAmount'
			cost.Parent = upgrade
			stand.Parent = Workspace
			trash[#trash + 1] = stand
			return stand, upgrade, level
		end

		it('hides Upgrade while deployed and restores it afterward', function()
			local stand, upgrade, level = menuStand()
			StandDisplayService.SetAnimalService({
				Get = function(_id: string)
					return { uniqueId = 'M_a', ownerUserId = 77, Level = 5, definitionId = 'Dog' }
				end,
				IsArenaDeployed = function(_id: string)
					return deployedFlag
				end,
			})
			StandDisplayService.SetUpgradeService({
				GetUpgradeCost = function(_defId: string, _level: number)
					return '100'
				end,
			})
			local slot: any = {
				id = 'arena:77:1',
				state = 'Occupied',
				occupantKind = 'animal',
				occupantId = 'M_a',
				ownerUserId = 77,
				stand = stand,
			}
			-- Pre-raid: Upgrade offered with live readout,
			-- filling the whole MenuGui.
			deployedFlag = false
			StandDisplayService.RefreshSlot(slot)
			expect(upgrade.Visible).to.equal(true)
			expect(level.Text).to.equal('5 >> 6')
			expect(upgrade.Size).to.equal(UDim2.fromScale(1, 1))
			expect(upgrade.Position).to.equal(UDim2.fromScale(0, 0))
			-- Deployed: stand reads empty, no Upgrade.
			deployedFlag = true
			StandDisplayService.RefreshSlot(slot)
			expect(upgrade.Visible).to.equal(false)
			expect(level.Text).to.equal('')
			-- Restored: Upgrade back with live readout.
			deployedFlag = false
			StandDisplayService.RefreshSlot(slot)
			expect(upgrade.Visible).to.equal(true)
			expect(level.Text).to.equal('5 >> 6')
			StandDisplayService.SetAnimalService(nil)
			StandDisplayService.SetUpgradeService(nil)
		end)
	end)

	describe('Arena collector escrow', function()
		local profile: { [string]: any } = {}

		local function escrowSession(): { [string]: any }
			return {
				sessionId = 78,
				userId = 77,
				state = 'Active',
				arenaLevel = 2,
				maxLevel = 10,
				team = {
					{ UniqueId = 'W_a', ArenaSlotId = 'arena:77:1' },
					{ UniqueId = 'W_b', ArenaSlotId = 'arena:77:2' },
				},
			}
		end

		local function wireEscrow()
			profile = { Brainrots = {} }
			ArenaService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			ArenaService.SetAnimalService({
				SetArenaDeployed = function(_uniqueId: string, _deployed: boolean)
					return true
				end,
			})
		end

		local function unwireEscrow()
			ArenaService.SetPlayerService(nil)
			ArenaService.SetAnimalService(nil)
			ArenaService._TestReset()
		end

		it('snapshots exact pools to $0 and restores verbatim', function()
			wireEscrow()
			profile.Brainrots = {
				{ Id = 'W_a', CashPool = '50000' },
				{ Id = 'W_b', CashPool = '51237' },
			}
			local session = escrowSession()
			ArenaService._TestSetRaidDeployment(session, true)
			expect(profile.Brainrots[1].CashPool).to.equal('0')
			expect(profile.Brainrots[2].CashPool).to.equal('0')
			expect(session.collectorEscrow.W_a).to.equal('50000')
			expect(session.collectorEscrow.W_b).to.equal('51237')
			-- Repeat deploy is idempotent: the snapshot is
			-- NOT overwritten with $0.
			ArenaService._TestSetRaidDeployment(session, true)
			expect(session.collectorEscrow.W_a).to.equal('50000')
			ArenaService._TestSetRaidDeployment(session, false)
			expect(profile.Brainrots[1].CashPool).to.equal('50000')
			expect(profile.Brainrots[2].CashPool).to.equal('51237')
			-- Repeat restore cannot double anything.
			ArenaService._TestSetRaidDeployment(session, false)
			expect(profile.Brainrots[1].CashPool).to.equal('50000')
			expect(profile.Brainrots[2].CashPool).to.equal('51237')
			unwireEscrow()
		end)

		it('zero pools round-trip as zero with no fake money', function()
			wireEscrow()
			profile.Brainrots = {
				{ Id = 'W_a', CashPool = '0' },
				{ Id = 'W_b', CashPool = '0' },
			}
			local session = escrowSession()
			ArenaService._TestSetRaidDeployment(session, true)
			ArenaService._TestSetRaidDeployment(session, false)
			expect(profile.Brainrots[1].CashPool).to.equal('0')
			expect(profile.Brainrots[2].CashPool).to.equal('0')
			unwireEscrow()
		end)

		it('leave restores the snapshot before the session clears', function()
			wireEscrow()
			profile.Brainrots = {
				{ Id = 'W_a', CashPool = '777' },
				{ Id = 'W_b', CashPool = '0' },
			}
			local session = escrowSession()
			ArenaService._TestSetRaidDeployment(session, true)
			expect(profile.Brainrots[1].CashPool).to.equal('0')
			ArenaService._TestInjectSession(77, session)
			ArenaService.ForgetPlayer(77)
			expect(profile.Brainrots[1].CashPool).to.equal('777')
			expect(profile.Brainrots[2].CashPool).to.equal('0')
			expect(ArenaService.GetSession(77)).to.equal(nil)
			unwireEscrow()
		end)

		it('restore with a destroyed record drops escrow without throwing', function()
			wireEscrow()
			profile.Brainrots = {
				{ Id = 'W_a', CashPool = '999' },
			}
			local session = escrowSession()
			ArenaService._TestSetRaidDeployment(session, true)
			expect(session.collectorEscrow.W_a).to.equal('999')
			-- Record destroyed mid-raid (genuine destroy path).
			profile.Brainrots = {}
			ArenaService._TestSetRaidDeployment(session, false)
			expect(session.collectorEscrow.W_a).to.equal(nil)
			unwireEscrow()
		end)
	end)

	describe('Arena raid deployment wiring', function()
		local deployCalls: { any } = {}

		local function wireFake()
			deployCalls = {}
			ArenaService.SetAnimalService({
				SetArenaDeployed = function(uniqueId: string, deployed: boolean)
					deployCalls[#deployCalls + 1] = { uniqueId, deployed }
					return true
				end,
			})
		end

		local function unwire()
			ArenaService.SetAnimalService(nil)
			ArenaService._TestReset()
		end

		local function raidSession(): { [string]: any }
			return {
				sessionId = 55,
				userId = 77,
				state = 'Active',
				arenaLevel = 2,
				maxLevel = 10,
				team = {
					{ UniqueId = 'W_a', ArenaSlotId = 'arena:77:1' },
					{ UniqueId = 'W_b', ArenaSlotId = 'arena:77:2' },
				},
				raidHP = {},
				raidAlive = {},
				rewardedStages = {},
				settledStages = {},
				clearedStages = {},
				rewardAccum = { cash = '0', xp = 0 },
				rewardSettled = false,
				firstClearCursor = 1,
				battle = { playerTeam = {} },
			}
		end

		it('terminate restores every team member exactly once (victory + defeat)', function()
			wireFake()
			local session = raidSession()
			local outcome: { [string]: any } = { RaidComplete = true, Stage = 2 }
			ArenaService._TestTerminateRaid(77, session, outcome)
			expect(#deployCalls).to.equal(2)
			expect(deployCalls[1][1]).to.equal('W_a')
			expect(deployCalls[1][2]).to.equal(false)
			expect(deployCalls[2][1]).to.equal('W_b')
			expect(deployCalls[2][2]).to.equal(false)
			-- Duplicate terminate of the SAME session is a
			-- no-op (raidFinalized guard): no second restore.
			ArenaService._TestTerminateRaid(77, session, { RaidComplete = false, Stage = 2 })
			expect(#deployCalls).to.equal(2)
			unwire()
		end)

		it('leave restores the team without rewards', function()
			wireFake()
			ArenaService._TestInjectSession(77, raidSession())
			ArenaService.ForgetPlayer(77)
			expect(#deployCalls).to.equal(2)
			expect(deployCalls[1][2]).to.equal(false)
			expect(deployCalls[2][2]).to.equal(false)
			expect(ArenaService.GetSession(77)).to.equal(nil)
			unwire()
		end)

		it('terminal teardown keeps models through the impact window, then cleans', function()
			wireFake()
			local destroyed = 0
			ArenaService.SetBattleService({
				DestroyBattleModels = function(_battle: any)
					destroyed += 1
				end,
				UnregisterBattle = function(_userId: number) end,
			})
			local folder = Instance.new('Folder')
			folder.Name = 'DelaySpec'
			folder.Parent = Workspace
			trash[#trash + 1] = folder
			local session = raidSession()
			session.battle = { folder = folder, playerTeam = {}, enemyTeam = {} }
			ArenaService._TestTerminateRaid(77, session, { RaidComplete = true, Stage = 2 })
			-- Settle ran, but the visual window is preserved:
			-- nothing destroyed synchronously.
			expect(folder.Parent).to.be.ok()
			expect(destroyed).to.equal(0)
			task.wait(1.6)
			expect(destroyed).to.equal(1)
			ArenaService.SetBattleService(nil)
			unwire()
		end)
	end)
end
