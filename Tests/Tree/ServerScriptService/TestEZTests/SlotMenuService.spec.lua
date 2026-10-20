--!strict
--!native
--[[
	SlotMenuService.spec
	====================
	Phase 2.9 tests for the slot-menu server endpoints. Uses the
	REAL SlotMenuService + AnimalService (runtime records via
	the documented test seam) + ModifierService, with
	hand-rolled slot/base/profile registries. The menu owns
	Upgrade only: upgrade confirms run the real
	UpgradeService transaction, and every sell confirm
	(animal or egg, plain or forged) rejects with nothing
	moved. Full sale transactions are covered by
	SellService.spec through the Sell prompt path.

  Locked in:
  * animal menu state: identity, level, NewLevel preview,
    disabled upgrade, effective generation (base x live
    multiplier), pool — and NO sell fields (selling lives
    on the Sell prompt)
  * lucky menu state: name/rarity, no upgrade, no animal
    fields and no sell fields (nil, never faked; eggs are
    not sellable)
  * empty / unknown / foreign slots reject (Valid = false)
  * sell confirms (animal AND egg) reject with no money
    moved — the menu owns Upgrade only
  * stale occupant / wrong owner reject with no money moved
  * no upgrade API exists and none can charge or level
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local SlotMenuService = require(ServerScriptService.SlotMenuService)
	local SellService = require(ServerScriptService.SellService)
	local UpgradeService = require(ServerScriptService.UpgradeService)
	local NotificationService = require(ServerScriptService.Base.NotificationService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local IncomeService = require(ServerScriptService.IncomeService)
	local ModifierService = require(ServerScriptService.ModifierService)
	local AnimalService = require(ServerScriptService.AnimalService)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local U1 = 7901
	local U2 = 7902

	local COMMON_DEF = 'Chicken' -- Common: sell base 100, income 2/s

	local profiles: { [number]: any } = {}
	local slotMap: { [string]: any } = {}
	local baseMap: { [string]: any } = {}
	local eggs: { [string]: any } = {}
	local notifies: { any } = {}
	local runtimeIds: { string } = {}
	-- Stand display repaints captured per test (slot ids passed
	-- to the canonical RefreshDisplays pipeline).
	local refreshCalls: { string } = {}

	local function fakePlayerService()
		return {
			GetPlayerData = function(userId: number)
				return profiles[userId]
			end,
			RemoveAnimal = function(userId: number, id: string): boolean
				local data = profiles[userId]
				if not data then
					return false
				end
				for i, rec in ipairs(data.Brainrots) do
					if type(rec) == 'table' and rec.Id == id then
						table.remove(data.Brainrots, i)
						return true
					end
				end
				return false
			end,
			RemoveEgg = function(userId: number, id: string): boolean
				local data = profiles[userId]
				if not data then
					return false
				end
				for i, rec in ipairs(data.LuckyBlocks) do
					if type(rec) == 'table' and rec.Id == id then
						table.remove(data.LuckyBlocks, i)
						return true
					end
				end
				return false
			end,
			PushState = function(_player: Player, _snap: any) end,
			Notify = function(player: Player, category: string, _text: string)
				notifies[#notifies + 1] = { userId = player.UserId, category = category }
			end,
		}
	end

	local function makeSlot(id: string, userId: number, occupantId: string?, kind: string?): any
		local slot = {
			id = id,
			ownerUserId = userId,
			baseId = 'Base_menu',
			state = SlotType.State.Occupied,
			occupantId = occupantId,
			occupantKind = kind,
			cashCollector = nil,
		}
		slotMap[id] = slot
		return slot
	end

	local function wire()
		local ps = fakePlayerService()
		local ss = {
			_findSlotById = function(slotId: string): any?
				return slotMap[slotId]
			end,
			FindSlotByOccupant = function(occupantId: string): any?
				for _, slot in pairs(slotMap) do
					if slot.occupantId == occupantId then
						return slot
					end
				end
				return nil
			end,
			ReleaseSlot = function(slotId: string): boolean
				local slot = slotMap[slotId]
				if not slot then
					return false
				end
				slot.state = SlotType.State.Empty
				slot.occupantId = nil
				slot.occupantKind = nil
				return true
			end,
			RefreshDisplays = function(slotId: string): boolean
				refreshCalls[#refreshCalls + 1] = slotId
				return true
			end,
		}
		EconomyService.Init()
		EconomyService.SetPlayerService(ps)
		IncomeService.Init()
		IncomeService.SetPlayerService(ps)
		IncomeService.SetEconomyService(EconomyService)
		IncomeService.SetSlotService(ss)
		IncomeService.SetBaseService({
			GetAllBases = function()
				return {}
			end,
		})
		IncomeService.SetAnimalService(AnimalService)
		IncomeService.SetModifierService(ModifierService)
		AnimalService.SetModifierService(ModifierService)
		-- Level changes repaint through the slot display
		-- pipeline: wire the same fake slot service the menu
		-- reads through so repaint calls are observable.
		AnimalService.SetSlotService(ss)
		SellService.SetPlayerService(ps)
		SellService.SetSlotService(ss)
		SellService.SetBaseService({
			Snapshot = function(_userId: number)
				return { slots = {}, _occupiedCount = 0 }
			end,
		})
		SellService.SetAnimalService(AnimalService)
		SellService.SetEggService({
			GetEgg = function(uniqueId: string): any?
				return eggs[uniqueId]
			end,
			DropEggRuntime = function(uniqueId: string): boolean
				if eggs[uniqueId] == nil then
					return false
				end
				eggs[uniqueId] = nil
				return true
			end,
		})
		SellService.SetEconomyService(EconomyService)
		SellService.SetIncomeService(IncomeService)
		SlotMenuService.SetPlayerService(ps)
		SlotMenuService.SetBaseService({
			GetBaseById = function(baseId: string): any?
				return baseMap[baseId]
			end,
		})
		SlotMenuService.SetSlotService(ss)
		SlotMenuService.SetAnimalService(AnimalService)
		SlotMenuService.SetEggService({
			GetEgg = function(uniqueId: string): any?
				return eggs[uniqueId]
			end,
		})
		-- Real upgrade transaction, wired to this spec's fakes,
		-- so menu upgrade confirms move real money/levels.
		UpgradeService.SetPlayerService(ps)
		UpgradeService.SetSlotService(ss)
		UpgradeService.SetBaseService({
			GetBaseById = function(baseId: string): any?
				return baseMap[baseId]
			end,
		})
		UpgradeService.SetAnimalService(AnimalService)
		UpgradeService.SetEconomyService(EconomyService)
		-- Canonical rejection path observes the same fake
		-- PlayerService (Notify stub) as the services above.
		NotificationService.SetPlayerService(ps)
	end

	local function setupBrainrotSlot(userId: number, slotId: string, id: string, level: number, pool: string)
		profiles[userId] = profiles[userId]
			or { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }
		table.insert(profiles[userId].Brainrots, {
			Type = 'Brainrot',
			SlotId = slotId,
			DefId = COMMON_DEF,
			Id = id,
			Level = level,
			XP = 0,
			CashPool = pool,
		})
		makeSlot(slotId, userId, id, SlotType.OccupantKind.Animal)
		AnimalService._TestRegister({
			uniqueId = id,
			definitionId = COMMON_DEF,
			displayName = 'Boneca Ambalabu',
			rarity = 'Common',
			ownerUserId = userId,
			slotId = slotId,
			Level = level,
			XP = 0,
			state = 'Slotted',
			model = nil,
		})
		runtimeIds[#runtimeIds + 1] = id
	end

	local function setupBlockSlot(userId: number, slotId: string, id: string, rarity: string)
		profiles[userId] = profiles[userId]
			or { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }
		table.insert(profiles[userId].LuckyBlocks, { Type = 'LuckyBlock', SlotId = slotId, Rarity = rarity, Id = id })
		makeSlot(slotId, userId, id, SlotType.OccupantKind.Egg)
		eggs[id] = {
			uniqueId = id,
			rarity = rarity,
			ownerUserId = userId,
			slotId = slotId,
			state = 'Placed',
			model = nil,
			_mutex = false,
		}
	end

	describe('SlotMenuService menu state', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slotMap = {}
			eggs = {}
			notifies = {}
			runtimeIds = {}
			refreshCalls = {}
			baseMap = { Base_menu = { ownerUserId = U1 } }
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
			wire()
			NotificationService._TestReset()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			-- Drop the fake slot service so later specs observe
			-- the unwired (guard-skipped) behavior, as before.
			AnimalService.SetSlotService(nil :: any)
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		it('animal: identity, preview levels, real upgrade cost, effective gen, total payout', function()
			-- Common L5, pool 2500, live 2x multiplier:
			-- sale 100 x 5 + 2500 = 3000;
			-- upgrade 100 x 1.12^4 = 157.351936.
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu001', 5, '2500')
			-- Common L1 alongside: integer-exact generation
			-- (base rate 2/s x 2 = 4/s) for a float-safe assert.
			setupBrainrotSlot(U1, 'p7:7901:slot:3', 'BR_menu001b', 1, '0')
			ModifierService.AddModifier(U1, 'Evt', ModifierService.ModifierType.MoneyMultiplier, 2)

			local state = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(state.Valid).to.equal(true)
			expect(state.Kind).to.equal('animal')
			expect(state.ObjectId).to.equal('BR_menu001')
			expect(state.Name).to.equal('Boneca Ambalabu')
			expect(state.Level).to.equal(5)
			expect(state.NewLevel).to.equal(6)
			-- Real authoritative upgrade preview (not a stub).
			expect(state.CanUpgrade).to.equal(true)
			expect(state.UpgradeCostRaw).to.equal('157.351936')
			expect(state.UpgradeButtonText).to.equal('Upgrade $157.3')
			expect(state.GenFormatted ~= 'N/A').to.equal(true)
			expect(string.find(state.GenFormatted, '/sec') ~= nil).to.equal(true)
			expect(state.PoolFormatted).to.equal('$2.5K')
			-- No sell fields: selling lives on the Sell prompt.
			expect((state :: any).SellTotalRaw).to.equal(nil)
			expect((state :: any).SellButtonText).to.equal(nil)

			local l1 = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:3')
			expect(l1.GenFormatted).to.equal('$4/sec')
			expect((l1 :: any).SellButtonText).to.equal(nil)
		end)

		it('opening the menu never upgrades: level and money untouched', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu002', 5, '2500')
			profiles[U1].Money = '1000'

			SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(AnimalService.GetLevel('BR_menu002')).to.equal(5)
			expect(profiles[U1].Money).to.equal('1000')
		end)

		it('max-level menu: NewLevel Max, Max Level button, no upgrade offered', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menuMax', 100, '0')

			local state = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(state.Level).to.equal(100)
			expect(state.NewLevel).to.equal('Max')
			expect(state.CanUpgrade).to.equal(false)
			expect(state.UpgradeButtonText).to.equal('Max Level')
		end)

		it('lucky egg: name/rarity, no upgrade, no animal fields, no sell fields', function()
			setupBlockSlot(U1, 'p7:7901:slot:2', 'LB_menu001', 'Epic')

			local state = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:2')
			expect(state.Valid).to.equal(true)
			expect(state.Kind).to.equal('egg')
			expect(state.Name).to.equal('Egg')
			expect(state.Rarity).to.equal('Epic')
			expect(state.CanUpgrade).to.equal(false)
			-- Eggs are not sellable: no sell fields either.
			expect((state :: any).SellValueRaw).to.equal(nil)
			expect((state :: any).SellButtonText).to.equal(nil)
			-- Never fabricated.
			expect(state.Level).to.equal(nil)
			expect(state.GenFormatted).to.equal(nil)
			expect(state.PoolRaw).to.equal(nil)
		end)

		it('empty, unknown, and foreign slots are invalid (never rendered)', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu003', 1, '0')
			slotMap['p7:7901:slot:9'] = {
				id = 'p7:7901:slot:9',
				ownerUserId = U1,
				baseId = 'Base_menu',
				state = SlotType.State.Empty,
				occupantId = nil,
				occupantKind = nil,
			}

			expect(SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:9').Valid).to.equal(false)
			expect(SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:9:slot:99').Valid).to.equal(false)
			local foreign = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U2), 'p7:7901:slot:1')
			expect(foreign.Valid).to.equal(false)
		end)

		it('no upgrade API exists on the service', function()
			expect((SlotMenuService :: any).ApplyUpgrade).to.equal(nil)
			expect((SlotMenuService :: any).Upgrade).to.equal(nil)
			expect((SlotMenuService :: any).UpgradeAnimal).to.equal(nil)
		end)
	end)

	describe('SlotMenuService confirm', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slotMap = {}
			eggs = {}
			notifies = {}
			runtimeIds = {}
			refreshCalls = {}
			baseMap = { Base_menu = { ownerUserId = U1 } }
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
			wire()
			NotificationService._TestReset()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			-- Drop the fake slot service so later specs observe
			-- the unwired (guard-skipped) behavior, as before.
			AnimalService.SetSlotService(nil :: any)
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		it('sell confirms reject for animals: the menu owns Upgrade only', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu010', 5, '2500')
			profiles[U1].Money = '0'
			local p = Helpers.FakePlayer(U1)

			-- No Action (legacy sell confirm shape): rejected,
			-- nothing moves, animal intact.
			local result = SlotMenuService.HandleAction(p, { SlotId = 'p7:7901:slot:1', OccupantId = 'BR_menu010' })
			expect(result.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('0')
			expect(AnimalService.Get('BR_menu010') ~= nil).to.equal(true)
			expect(slotMap['p7:7901:slot:1'].state).to.equal('Occupied')
			-- Forged explicit sell action: same rejection.
			local forged = SlotMenuService.HandleAction(p, {
				SlotId = 'p7:7901:slot:1',
				OccupantId = 'BR_menu010',
				Action = 'SellAnimal',
			})
			expect(forged.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('0')
			expect(AnimalService.Get('BR_menu010') ~= nil).to.equal(true)
		end)

		it('sell confirms reject for lucky eggs: eggs are not sellable', function()
			setupBlockSlot(U1, 'p7:7901:slot:2', 'LB_menu010', 'Epic')
			profiles[U1].Money = '0'

			local result = SlotMenuService.HandleAction(
				Helpers.FakePlayer(U1),
				{ SlotId = 'p7:7901:slot:2', OccupantId = 'LB_menu010' }
			)
			expect(result.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('0')
			expect(eggs['LB_menu010'] ~= nil).to.equal(true)
			local forged = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:2',
				OccupantId = 'LB_menu010',
				Action = 'SellEgg',
			})
			expect(forged.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('0')
			expect(eggs['LB_menu010'] ~= nil).to.equal(true)
		end)

		it('stale occupant rejects with no money moved', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu011', 5, '2500')
			profiles[U1].Money = '100'
			-- Moved since the menu opened: slot now holds another id.
			slotMap['p7:7901:slot:1'].occupantId = 'BR_somebody_else'

			local result = SlotMenuService.HandleAction(
				Helpers.FakePlayer(U1),
				{ SlotId = 'p7:7901:slot:1', OccupantId = 'BR_menu011' }
			)
			expect(result.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('100')
			expect(#notifies).to.equal(1)
		end)

		it('wrong owner and unknown object reject cleanly', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu012', 1, '0')
			profiles[U1].Money = '100'

			local foreign = SlotMenuService.HandleAction(
				Helpers.FakePlayer(U2),
				{ SlotId = 'p7:7901:slot:1', OccupantId = 'BR_menu012' }
			)
			expect(foreign.Success).to.equal(false)

			local ghost = SlotMenuService.HandleAction(
				Helpers.FakePlayer(U1),
				{ SlotId = 'p7:7901:slot:1', OccupantId = 'BR_ghost' }
			)
			expect(ghost.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('100')
		end)

		it('upgrade confirm buys exactly one level for the live cost', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu020', 1, '0')
			profiles[U1].Money = '1000'

			local result = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:1',
				OccupantId = 'BR_menu020',
				Action = 'Upgrade',
			})
			expect(result.Success).to.equal(true)
			expect(result.NewLevel).to.equal(2)
			expect(result.Cost).to.equal('100')
			expect(profiles[U1].Money).to.equal('900')
			expect(AnimalService.GetLevel('BR_menu020')).to.equal(2)
		end)

		it('upgrade confirm rejects lucky eggs, stale, and poor buyers', function()
			setupBlockSlot(U1, 'p7:7901:slot:2', 'LB_menu020', 'Epic')
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_menu021', 1, '0')
			profiles[U1].Money = '50'

			local egg = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:2',
				OccupantId = 'LB_menu020',
				Action = 'Upgrade',
			})
			expect(egg.Success).to.equal(false)

			slotMap['p7:7901:slot:1'].occupantId = 'BR_somebody_else'
			local stale = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:1',
				OccupantId = 'BR_menu021',
				Action = 'Upgrade',
			})
			expect(stale.Success).to.equal(false)

			slotMap['p7:7901:slot:1'].occupantId = 'BR_menu021'
			local poor = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:1',
				OccupantId = 'BR_menu021',
				Action = 'Upgrade',
			})
			expect(poor.Success).to.equal(false)
			expect(profiles[U1].Money).to.equal('50')
			expect(AnimalService.GetLevel('BR_menu021')).to.equal(1)
		end)
	end)

	describe('SlotMenuService upgrade refresh', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slotMap = {}
			eggs = {}
			notifies = {}
			runtimeIds = {}
			refreshCalls = {}
			baseMap = { Base_menu = { ownerUserId = U1 } }
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
			wire()
			NotificationService._TestReset()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			AnimalService.SetSlotService(nil :: any)
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		it('XP level-up repaints the stand and the menu state shows the new cost', function()
			-- Chicken L1: upgrade preview is exactly the base.
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_refresh01', 1, '0')
			local before = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(before.Level).to.equal(1)
			expect(before.UpgradeCostRaw).to.equal('100')
			-- Arena-style XP grant: 100 XP crosses L1 -> L2.
			local granted = AnimalService:AddXP('BR_refresh01', 200)
			expect(granted.leveledUp).to.equal(true)
			expect(granted.level).to.equal(2)
			-- The stand readout repaints through the slot
			-- pipeline (no reopen, no polling).
			expect(#refreshCalls).to.equal(1)
			expect(refreshCalls[1]).to.equal('p7:7901:slot:1')
			-- Reopening (or the level-up re-request) reads the
			-- current cost: 100 x 1.12 = 112.
			local after = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(after.Level).to.equal(2)
			expect(after.NewLevel).to.equal(3)
			expect(after.UpgradeCostRaw).to.equal('112')
			expect(after.UpgradeButtonText).to.equal('Upgrade $112')
		end)

		it('bare XP without a level-up repaints nothing', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_refresh02', 1, '0')
			local granted = AnimalService:AddXP('BR_refresh02', 10)
			expect(granted.leveledUp).to.equal(false)
			expect(granted.level).to.equal(1)
			expect(#refreshCalls).to.equal(0)
		end)

		it('upgrade confirm then menu state shows the next cost immediately', function()
			setupBrainrotSlot(U1, 'p7:7901:slot:1', 'BR_refresh03', 1, '0')
			profiles[U1].Money = '1000'
			local result = SlotMenuService.HandleAction(Helpers.FakePlayer(U1), {
				SlotId = 'p7:7901:slot:1',
				OccupantId = 'BR_refresh03',
				Action = 'Upgrade',
			})
			expect(result.Success).to.equal(true)
			expect(result.NewLevel).to.equal(2)
			local after = SlotMenuService.BuildMenuState(Helpers.FakePlayer(U1), 'p7:7901:slot:1')
			expect(after.Level).to.equal(2)
			expect(after.UpgradeCostRaw).to.equal('112')
			expect(after.UpgradeButtonText).to.equal('Upgrade $112')
		end)
	end)
end
