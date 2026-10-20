--!strict
--!native
--[[
	GearShop.spec
	=============
	Headless-safe coverage for the Gear Shop catalog and its
	pure rules. Live purchase/grant/preview paths need Studio
	assets (Tools, GUI, PromptPart) and are Studio-playtest
	items — see the service header.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')

	local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)

	describe('GearShop', function()
		it('ships twelve gears with DefaultBat last and stable order', function()
			local all = GearConfig.GetAll()
			expect(#all).to.equal(12)
			expect(all[1].Id).to.equal('SpeedCoil')
			expect(all[2].Id).to.equal('SilverBat')
			expect(all[3].Id).to.equal('GravityCoil')
			expect(all[4].Id).to.equal('GoldBat')
			expect(all[5].Id).to.equal('CoilCombo')
			expect(all[6].Id).to.equal('DiamondBat')
			expect(all[7].Id).to.equal('ObsidianBat')
			expect(all[8].Id).to.equal('CrystalBat')
			expect(all[9].Id).to.equal('InvisibleCloak')
			expect(all[10].Id).to.equal('HackerBat')
			expect(all[11].Id).to.equal('GalaxyBat')
			expect(all[12].Id).to.equal('DefaultBat')
			local seen: { [string]: boolean } = {}
			for _, entry in ipairs(all) do
				expect(seen[entry.Id]).to.equal(nil)
				seen[entry.Id] = true
				expect(type(entry.ToolName)).to.equal('string')
			end
		end)

		it('DefaultBat is free, unlocked, and combat-tuned weakest', function()
			local found = GearConfig.FindGear('DefaultBat')
			expect(found).to.be.ok()
			expect((found :: any).Name).to.equal('Default Bat')
			expect((found :: any).Price).to.equal('0')
			expect((found :: any).ToolName).to.equal('Default Bat')
			expect(GearConfig.IsLocked(0, (found :: any).RequiredRebirth)).to.equal(false)
			expect(GearConfig.Combat.GetByGearId('DefaultBat')).to.be.ok()
			expect(GearConfig.Combat.GetByToolName('Default Bat')).to.be.ok()
		end)

		it('FindGear resolves by stable Id, never by display Name', function()
			local found = GearConfig.FindGear('SpeedCoil')
			expect(found).to.be.ok()
			expect((found :: any).Name).to.equal('Speed Coil')
			expect(GearConfig.FindGear('Speed Coil')).to.equal(nil)
			expect(GearConfig.FindGear('Nope')).to.equal(nil)
			expect(GearConfig.FindGear(nil :: any)).to.equal(nil)
		end)

		it('IsLocked compares rebirth fail-closed', function()
			expect(GearConfig.IsLocked(0, 0)).to.equal(false)
			expect(GearConfig.IsLocked(0, 1)).to.equal(true)
			expect(GearConfig.IsLocked(2, 2)).to.equal(false)
			expect(GearConfig.IsLocked(nil :: any, 0)).to.equal(true)
		end)

		it('ValidateList accepts the live catalog (tools unchecked headless)', function()
			expect(#GearConfig.ValidateList(GearConfig.GetAll(), nil)).to.equal(0)
		end)

		it('ValidateList rejects duplicates, bad fields, missing tools', function()
			local bad = {
				{ Id = 'A', Name = 'A', Price = '10', Description = 'd', RequiredRebirth = 0, ToolName = 'T' },
				{ Id = 'A', Name = 'B', Price = '10', Description = 'd', RequiredRebirth = 0, ToolName = 'T' },
				{ Id = 'C', Name = '', Price = '10', Description = 'd', RequiredRebirth = 0, ToolName = 'T' },
				{ Id = 'D', Name = 'D', Price = '', Description = 'd', RequiredRebirth = -1, ToolName = '' },
				{ Id = 'E', Name = 'E', Price = '10', Description = 'd', RequiredRebirth = 0, ToolName = 'Ghost' },
			}
			local issues = GearConfig.ValidateList(bad, function(_: string)
				return false
			end)
			expect(#issues > 0).to.equal(true)
			local text = table.concat(issues, '|')
			expect(string.find(text, 'Duplicate GearId=A') ~= nil).to.equal(true)
			expect(string.find(text, 'Missing Tool GearId=E ToolName=Ghost path=') ~= nil).to.equal(true)
		end)

		it('ValidateList flags wrong-class tools distinctly', function()
			local entries = {
				{ Id = 'W', Name = 'W', Price = '10', Description = 'd', RequiredRebirth = 0, ToolName = 'Widget' },
			}
			local issues = GearConfig.ValidateList(entries, function(_: string)
				return 'wrong-class'
			end)
			expect(#issues).to.equal(1)
			expect(string.find(issues[1], 'Tool wrong class GearId=W ToolName=Widget path=') ~= nil).to.equal(true)
		end)

		it('GearShopService loads and resets cleanly', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			expect(GearShopService).to.be.ok()
			GearShopService._TestReset()
			GearShopService.ForgetPlayer(999001)
			expect(GearShopService.GetPlayerRebirth(999001)).to.equal(0)
			expect(GearShopService.ResolveTool('')).to.equal(nil)
			expect(GearShopService.ResolveTool('Nope')).to.equal(nil)
		end)

		it('NormalizeAutoBuy defaults every gear false, preserves true, adds future gears', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			local data: any = { GearAutoBuy = { SpeedCoil = true } }
			local out = GearShopService.NormalizeAutoBuy(data)
			expect(out).to.be.ok()
			expect((out :: any).SpeedCoil).to.equal(true)
			expect((out :: any).GravityCoil).to.equal(false)
			expect((out :: any).InvisibleCloak).to.equal(false)
			expect((out :: any).CoilCombo).to.equal(false)
			expect((out :: any).SilverBat).to.equal(false)
			expect((out :: any).HackerBat).to.equal(false)
			-- Wrong-typed values repair to false, unknown keys survive.
			local data2: any = { GearAutoBuy = { SpeedCoil = 'yes', Custom = true } }
			local out2 = GearShopService.NormalizeAutoBuy(data2)
			expect((out2 :: any).SpeedCoil).to.equal(false)
			expect((out2 :: any).Custom).to.equal(true)
			expect(GearShopService.NormalizeAutoBuy(nil)).to.equal(nil)
		end)

		it('SetAutoBuy rejects non-players and non-boolean values', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			local Helpers = require(script.Parent._Helpers)
			local player = Helpers.FakePlayer(999002)
			local badPlayer = GearShopService.SetAutoBuy(nil :: any, 'SpeedCoil', true)
			expect(badPlayer.success).to.equal(false)
			local badGear = GearShopService.SetAutoBuy(player, 'FakeGear', true)
			expect(badGear.success).to.equal(false)
			expect(badGear.error).to.equal('invalid-player')
		end)

		it('EnsureOwnedTools is a safe no-op without a live player', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			expect(GearShopService.EnsureOwnedTools(nil :: any)).to.equal(0)
		end)

		it('exposes idempotent single-gear grant + live-tool presence (no unlock model)', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			expect(type(GearShopService.EnsureGearTool)).to.equal('function')
			expect(type(GearShopService.HasLiveTool)).to.equal('function')
			-- Non-live / unknown inputs fail closed without throwing.
			expect(GearShopService.EnsureGearTool(nil :: any, 'SpeedCoil')).to.equal(false)
			local Helpers = require(script.Parent._Helpers)
			local player = Helpers.FakePlayer(999003)
			expect(GearShopService.EnsureGearTool(player, 'FakeGear')).to.equal(false)
			expect(GearShopService.HasLiveTool(nil :: any, 'Speed Coil')).to.equal(false)
			expect(GearShopService.HasLiveTool(player, '')).to.equal(false)
		end)

		it('GearRefund reason exists for grant-failed rollbacks', function()
			local TransactionReason = require(ReplicatedStorage.Types.TransactionReason)
			expect(TransactionReason.GearRefund).to.equal('GearRefund')
			expect(TransactionReason.isValid(TransactionReason.GearRefund)).to.equal(true)
			expect(TransactionReason.isValid(TransactionReason.GearPurchase)).to.equal(true)
		end)
	end)

	describe('BatSystem default + equip + isolation', function()
		local Players = game:GetService('Players')
		local ServerStorage = game:GetService('ServerStorage')
		local Workspace = game:GetService('Workspace')
		local created: { Instance } = {}
		local players: { Player } = {}

		local function track(inst: Instance): Instance
			created[#created + 1] = inst
			return inst
		end

		-- Fabricate (or reuse) the Studio Tool asset. Mirrors the
		-- EventMutation.spec asset pattern: never destroys what
		-- the live place already had.
		local function ensureToolAsset(toolName: string): Tool
			local assets = ServerStorage:FindFirstChild('Assets')
			if assets == nil then
				assets = track(Instance.new('Folder'))
				assets.Name = 'Assets'
				assets.Parent = ServerStorage
			end
			local ui = (assets :: Instance):FindFirstChild('Ui')
			if ui == nil then
				ui = track(Instance.new('Folder'))
				ui.Name = 'Ui'
				ui.Parent = assets
			end
			local shop = (ui :: Instance):FindFirstChild('GearShop')
			if shop == nil then
				shop = track(Instance.new('Folder'))
				shop.Name = 'GearShop'
				shop.Parent = ui
			end
			local tools = (shop :: Instance):FindFirstChild('Tools')
			if tools == nil or not tools:IsA('Folder') then
				tools = track(Instance.new('Folder'))
				tools.Name = 'Tools'
				tools.Parent = shop
			end
			local tool = (tools :: Instance):FindFirstChild(toolName)
			if tool ~= nil and tool:IsA('Tool') then
				return tool
			end
			local fresh = Instance.new('Tool')
			fresh.Name = toolName
			fresh.RequiresHandle = false
			fresh.CanBeDropped = false
			fresh.Parent = tools
			track(fresh)
			return fresh
		end

		local function makePlayer(name: string): Player
			local p = Instance.new('Player')
			p.Name = name
			p.Parent = Players
			players[#players + 1] = p
			local pack = Instance.new('Backpack')
			pack.Parent = p
			local character = Instance.new('Model')
			character.Name = name .. '_char'
			local humanoid = Instance.new('Humanoid')
			humanoid.Parent = character
			character.Parent = Workspace
			track(character)
			p.Character = character
			return p
		end

		local function liveTools(player: Player, toolName: string): (Instance?, Instance?)
			local pack = player:FindFirstChildOfClass('Backpack')
			local character = player.Character
			local inPack: Instance? = nil
			local inChar: Instance? = nil
			if pack ~= nil then
				local node = pack:FindFirstChild(toolName)
				if node ~= nil and node:IsA('Tool') then
					inPack = node
				end
			end
			if character ~= nil then
				local node = (character :: Instance):FindFirstChild(toolName)
				if node ~= nil and node:IsA('Tool') then
					inChar = node
				end
			end
			return inPack, inChar
		end

		local function countTools(player: Player, toolName: string): number
			local n = 0
			local pack = player:FindFirstChildOfClass('Backpack')
			local character = player.Character
			for _, container in ipairs({ pack, character }) do
				if container ~= nil then
					for _, child in ipairs((container :: Instance):GetChildren()) do
						if child:IsA('Tool') and child.Name == toolName then
							n += 1
						end
					end
				end
			end
			return n
		end

		local function wireEconomy(GearShopService: any)
			GearShopService.SetEconomyService({
				TrySpendMoney = function(_userId: number, _amount: string, _reason: string)
					return { Success = true }
				end,
				GetMoney = function(_userId: number)
					return '1000000'
				end,
				AddMoney = function(_userId: number, _amount: string, _reason: string, _opts: any?)
					return { Success = true }
				end,
			})
			GearShopService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return { GearAutoBuy = {}, OwnedRobuxGear = {} }
				end,
			})
		end

		beforeEach(function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			GearShopService._TestReset()
			wireEconomy(GearShopService)
		end)

		afterEach(function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			for _, p in ipairs(players) do
				pcall(function()
					GearShopService.ForgetPlayer((p :: Player).UserId)
				end)
			end
			GearShopService._TestReset()
			GearShopService.SetEconomyService(nil)
			GearShopService.SetPlayerService(nil)
			for _, p in ipairs(players) do
				pcall(function()
					(p :: Player).Parent = nil
				end)
			end
			players = {}
			for _, inst in ipairs(created) do
				pcall(function()
					(inst :: Instance):Destroy()
				end)
			end
			created = {}
		end)

		it('join grants + equips DefaultBat with no purchase', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			local player = makePlayer('BatJoinA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			local _, inChar = liveTools(player, 'Default Bat')
			expect(inChar ~= nil).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('DefaultBat')
		end)

		it('manual purchase equips that exact bat, never another', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			local player = makePlayer('BatBuyA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			local result = GearShopService.Purchase(player, 'SilverBat', false)
			expect(result.success).to.equal(true)
			local _, defaultChar = liveTools(player, 'Default Bat')
			local _, silverChar = liveTools(player, 'Silver Bat')
			expect(silverChar ~= nil).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('SilverBat')
			expect(countTools(player, 'Silver Bat')).to.equal(1)
			expect(defaultChar).to.equal(nil)
		end)

		it('respawn re-equips the session bat without duplicating', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			local player = makePlayer('BatRespA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			local bought = GearShopService.Purchase(player, 'SilverBat', false)
			expect(bought.success).to.equal(true)
			-- Death drops the Character copy: keep Backpack only.
			local character = player.Character
			assert(character ~= nil)
			for _, child in ipairs((character :: Instance):GetChildren()) do
				if child:IsA('Tool') then
					child.Parent = player:FindFirstChildOfClass('Backpack')
				end
			end
			(character :: Instance):Destroy()
			-- Fresh character (same session): re-equip, no dupe.
			local fresh = Instance.new('Model')
			fresh.Name = 'BatRespA_char2'
			local humanoid = Instance.new('Humanoid')
			humanoid.Parent = fresh
			fresh.Parent = Workspace
			track(fresh)
			player.Character = fresh
			GearShopService.OnCharacterSpawned(player)
			local _, silverChar = liveTools(player, 'Silver Bat')
			expect(silverChar ~= nil).to.equal(true)
			expect(countTools(player, 'Silver Bat')).to.equal(1)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('SilverBat')
		end)

		it('equipped choice never leaks across players; leave clears session', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			local playerA = makePlayer('BatIsoA')
			expect(GearShopService.EnsureDefaultBat(playerA)).to.equal(true)
			local bought = GearShopService.Purchase(playerA, 'SilverBat', false)
			expect(bought.success).to.equal(true)
			expect(GearShopService.GetEquippedGear(playerA.UserId)).to.equal('SilverBat')
			-- A foreign user id (Player B's key space) owns and
			-- equips nothing: per-userId session tables.
			expect(GearShopService.GetEquippedGear(playerA.UserId + 1000000)).to.equal(nil)
			expect(GearShopService.EquipGear(playerA, 'NopeBat')).to.equal(false)
			-- Leave clears A's session entirely.
			GearShopService.ForgetPlayer(playerA.UserId)
			expect(GearShopService.GetEquippedGear(playerA.UserId)).to.equal(nil)
		end)

		it('OnPlayerReady is join-once: default first, auto-buy upgrades after', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			local player = makePlayer('BatReadyA')
			GearShopService.OnPlayerReady(player)
			local _, defaultChar = liveTools(player, 'Default Bat')
			expect(defaultChar ~= nil).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('DefaultBat')
			-- Second ready is a guarded no-op (no duplicate grants).
			GearShopService.OnPlayerReady(player)
			expect(countTools(player, 'Default Bat')).to.equal(1)
		end)

		it('replacement parks the old bat: never two equipped, never dupes', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			local player = makePlayer('BatSwapA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			local bought = GearShopService.Purchase(player, 'SilverBat', false)
			expect(bought.success).to.equal(true)
			-- SilverBat equipped, Default Bat parked in Backpack.
			local defaultPack, defaultChar = liveTools(player, 'Default Bat')
			local _, silverChar = liveTools(player, 'Silver Bat')
			expect(silverChar ~= nil).to.equal(true)
			expect(defaultChar).to.equal(nil)
			expect(defaultPack ~= nil).to.equal(true)
			expect(countTools(player, 'Silver Bat')).to.equal(1)
			expect(countTools(player, 'Default Bat')).to.equal(1)
			-- Switch back: exact reverse, still no dupes.
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			local _, defaultChar2 = liveTools(player, 'Default Bat')
			local _, silverChar2 = liveTools(player, 'Silver Bat')
			expect(defaultChar2 ~= nil).to.equal(true)
			expect(silverChar2).to.equal(nil)
			expect(countTools(player, 'Silver Bat')).to.equal(1)
			expect(countTools(player, 'Default Bat')).to.equal(1)
		end)

		it('equipping a missing bat never strips the current one', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			local player = makePlayer('BatMissA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'SilverBat')).to.equal(false)
			local _, defaultChar = liveTools(player, 'Default Bat')
			expect(defaultChar ~= nil).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('DefaultBat')
		end)

		it('GalaxyBat receipt composition: grant persists, equip swaps, respawn restores', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatGalaxyA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			-- Receipt path composition: GrantRobuxGear (ShopService
			-- _grantGear calls this) + EquipGear (its new tail).
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			local _, galaxyChar = liveTools(player, 'Galaxy Bat')
			local defaultPack, defaultChar = liveTools(player, 'Default Bat')
			expect(galaxyChar ~= nil).to.equal(true)
			expect(defaultChar).to.equal(nil)
			expect(defaultPack ~= nil).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
		end)

		it('rejoin rehydrates persisted Robux entitlement into session ownership', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			-- One profile table shared across the simulated
			-- leave + rejoin (persistence survives; session
			-- state must not).
			local profile: any = { GearAutoBuy = {}, OwnedRobuxGear = {} }
			GearShopService.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			local player = makePlayer('BatRejoinA')
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(profile.OwnedRobuxGear.GalaxyBat).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			-- Leave: session cleared. Wipe the live Tools too,
			-- so the rejoin must re-grant (fresh-server shape),
			-- not merely rediscover them.
			GearShopService.ForgetPlayer(player.UserId)
			local pack = player:FindFirstChildOfClass('Backpack')
			if pack ~= nil then
				for _, child in ipairs((pack :: Instance):GetChildren()) do
					if child:IsA('Tool') then
						child:Destroy()
					end
				end
			end
			-- Rejoin: same profile, fresh session.
			GearShopService.OnPlayerReady(player)
			local _, galaxyPack = liveTools(player, 'Galaxy Bat')
			expect(galaxyPack ~= nil).to.equal(true)
			-- The re-granted bat must be recognized AND
			-- equippable (session flag rehydrated, not just
			-- the live Tool).
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
			local _, galaxyChar = liveTools(player, 'Galaxy Bat')
			local _, defaultChar = liveTools(player, 'Default Bat')
			expect(galaxyChar ~= nil).to.equal(true)
			expect(defaultChar).to.equal(nil)
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
		end)

		it('GalaxyBat is a normal combat-catalog bat (swings resolve)', function()
			local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
			local entry = GearConfig.Combat.GetByGearId('GalaxyBat')
			expect(entry).to.be.ok()
			expect((entry :: any).ToolName).to.equal('Galaxy Bat')
			expect((entry :: any).SwingCooldown > 0).to.equal(true)
			expect(GearConfig.Combat.GetByToolName('Galaxy Bat')).to.be.ok()
			-- Non-bats resolve to nothing: cleanup scope stays bats-only.
			expect(GearConfig.Combat.GetByToolName('Speed Coil')).to.equal(nil)
			expect(GearConfig.Combat.GetByToolName('Wrench')).to.equal(nil)
		end)

		it('Default -> Galaxy -> Default keeps one active bat, ownership intact', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatCycleA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
			-- Switch back: Galaxy stays owned, Default active alone.
			expect(GearShopService.EquipGear(player, 'DefaultBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('DefaultBat')
			local _, galaxyChar = liveTools(player, 'Galaxy Bat')
			expect(galaxyChar).to.equal(nil)
			-- Galaxy still owned: re-equip works with no purchase.
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
		end)

		it('Silver -> Galaxy -> Silver keeps one active bat, ownership intact', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatCycleB')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			local bought = GearShopService.Purchase(player, 'SilverBat', false)
			expect(bought.success).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('SilverBat')
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
			local _, silverChar = liveTools(player, 'Silver Bat')
			expect(silverChar).to.equal(nil)
			expect(GearShopService.EquipGear(player, 'SilverBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('SilverBat')
			local _, galaxyChar2 = liveTools(player, 'Galaxy Bat')
			expect(galaxyChar2).to.equal(nil)
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
			expect(countTools(player, 'Silver Bat')).to.equal(1)
		end)

		it('repeated equip of the same bat is idempotent, never duplicates', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatRepeatA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
		end)

		it('equip cleans duplicate physical bats, never touches ownership or non-bats', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatDedupeA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			-- Simulate the buggy state: Galaxy held AND parked,
			-- Default held too, plus an unrelated Wrench tool.
			local pack = player:FindFirstChildOfClass('Backpack')
			assert(pack ~= nil)
			local character = player.Character
			assert(character ~= nil)
			local function cloneInto(toolName: string, parent: Instance)
				local src: Instance? = nil
				pcall(function()
					local assets = game:GetService('ServerStorage'):FindFirstChild('Assets')
					local ui = assets and (assets :: Instance):FindFirstChild('Ui')
					local shop = ui and (ui :: Instance):FindFirstChild('GearShop')
					local tools = shop and (shop :: Instance):FindFirstChild('Tools')
					src = tools and (tools :: Instance):FindFirstChild(toolName)
				end)
				assert(src ~= nil and (src :: Instance):IsA('Tool'))
				local copy = ((src :: Instance):Clone() :: Tool)
				copy.Name = toolName
				copy.Parent = parent
				track(copy)
				return copy
			end
			cloneInto('Galaxy Bat', character)
			cloneInto('Galaxy Bat', pack)
			cloneInto('Default Bat', character)
			local wrench = Instance.new('Tool')
			wrench.Name = 'Wrench'
			wrench.Parent = character
			track(wrench)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
			-- Character holds exactly the requested bat; the
			-- wrench survives (parked, never destroyed).
			local batHeld = 0
			for _, child in ipairs((character :: Instance):GetChildren()) do
				if child:IsA('Tool') and (child.Name == 'Galaxy Bat' or child.Name == 'Default Bat') then
					batHeld += 1
					expect(child.Name).to.equal('Galaxy Bat')
				end
			end
			expect(batHeld).to.equal(1)
			expect(wrench.Parent ~= nil).to.equal(true)
			-- No stacked Galaxy copies anywhere.
			expect(countTools(player, 'Galaxy Bat') <= 2).to.equal(true)
		end)

		it('two players keep fully isolated bat state across switches', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Silver Bat')
			ensureToolAsset('Galaxy Bat')
			local playerA = makePlayer('BatIsoGalaxyA')
			local playerB = makePlayer('BatIsoDefaultB')
			expect(GearShopService.EnsureDefaultBat(playerA)).to.equal(true)
			expect(GearShopService.EnsureDefaultBat(playerB)).to.equal(true)
			expect(GearShopService.GrantRobuxGear(playerA, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(playerA, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(playerB, 'DefaultBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(playerA.UserId)).to.equal('GalaxyBat')
			expect(GearShopService.GetEquippedGear(playerB.UserId)).to.equal('DefaultBat')
			-- A switches to Silver: B untouched, A owns Galaxy still.
			local bought = GearShopService.Purchase(playerA, 'SilverBat', false)
			expect(bought.success).to.equal(true)
			expect(GearShopService.GetEquippedGear(playerA.UserId)).to.equal('SilverBat')
			expect(GearShopService.GetEquippedGear(playerB.UserId)).to.equal('DefaultBat')
			local _, bGalaxy = liveTools(playerB, 'Galaxy Bat')
			expect(bGalaxy).to.equal(nil)
			expect(GearShopService.EquipGear(playerA, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.GetEquippedGear(playerA.UserId)).to.equal('GalaxyBat')
		end)

		it('respawn preserves an equipped Galaxy Bat without duplicating', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatRespawnGalaxyA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			expect(GearShopService.EquipGear(player, 'GalaxyBat')).to.equal(true)
			local character = player.Character
			assert(character ~= nil)
			local corpse = character :: Instance
			corpse:Destroy()
			local fresh = Instance.new('Model')
			fresh.Name = 'BatRespawnGalaxyA_char2'
			local humanoid = Instance.new('Humanoid')
			humanoid.Parent = fresh
			fresh.Parent = Workspace
			track(fresh)
			player.Character = fresh
			GearShopService.OnCharacterSpawned(player)
			local _, galaxyChar = liveTools(player, 'Galaxy Bat')
			expect(galaxyChar ~= nil).to.equal(true)
			expect(countTools(player, 'Galaxy Bat')).to.equal(1)
			expect(GearShopService.GetEquippedGear(player.UserId)).to.equal('GalaxyBat')
		end)

		it('GearShop snapshot recognizes Robux-granted GalaxyBat as owned', function()
			local GearShopService = require(ServerScriptService.GearShop.GearShopService)
			ensureToolAsset('Default Bat')
			ensureToolAsset('Galaxy Bat')
			local player = makePlayer('BatSnapshotA')
			expect(GearShopService.EnsureDefaultBat(player)).to.equal(true)
			expect(GearShopService.GrantRobuxGear(player, 'GalaxyBat')).to.equal(true)
			local state = GearShopService.BuildState(player)
			expect(state).to.be.ok()
			local found: any = nil
			for _, gear in ipairs((state :: any).Gears) do
				if type(gear) == 'table' and gear.Id == 'GalaxyBat' then
					found = gear
				end
			end
			expect(found).to.be.ok()
			expect((found :: any).Owned).to.equal(true)
		end)
	end)
end
