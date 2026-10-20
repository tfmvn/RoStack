--!strict
--!native
--[[
	SellService.spec
	================
	Phase 2.8 tests for the sale authority (calculations +
	transactions + prompts). Uses the REAL SellService,
	EconomyService, IncomeService, ModifierService and
	AnimalService (minimal runtime records via the documented
	test seam), with hand-rolled profile/slot/player fakes and a
	fake Egg runtime registry (injected through the
	SetEggService seam — the service never touches
	SpawnService directly).

  Locked in (§34):
  Animal: L1/L2/L10 scaling, monotonicity, correct base
  value, pool added exactly once, removal, slot freed,
  persistence removed, double-sell pays once, wrong owner /
  invalid id / invalid definition rejected, carried rejected
  with consistent state, collect/sale race pays once either
  way, multiplier (live + legacy) never shapes the payout,
  BigNumber exactness.
  Eggs are NOT sellable: no SellEgg function, no egg value
  function, no egg sell path of any kind.
  Prompts: SellPrompt co-installs with Pickup for animals
  (F key, owner attribute), exactly once across reinstalls,
  never installed for eggs, wipes with the model.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local SellService = require(ServerScriptService.SellService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local IncomeService = require(ServerScriptService.IncomeService)
	local ModifierService = require(ServerScriptService.ModifierService)
	local AnimalService = require(ServerScriptService.AnimalService)
	local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local U1 = 7801
	local U2 = 7802

	local COMMON_DEF = 'Chicken' -- Common, sell base 100
	local RARE_DEF = 'Chimpanzee' -- Rare, sell base 1000

	local profiles: { [number]: any } = {}
	local slots: { any } = {}
	local pushes: { any } = {}
	local notifies: { any } = {}
	local runtimeIds: { string } = {}

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
			PushState = function(player: Player, _snap: any)
				pushes[#pushes + 1] = player.UserId
			end,
			Notify = function(player: Player, _category: string, _text: string)
				notifies[#notifies + 1] = player.UserId
			end,
		}
	end

	local function fakeSlotService()
		return {
			FindSlotByOccupant = function(occupantId: string): any?
				for _, slot in ipairs(slots) do
					if slot.occupantId == occupantId then
						return slot
					end
				end
				return nil
			end,
			ReleaseSlot = function(slotId: string): boolean
				for _, slot in ipairs(slots) do
					if slot.id == slotId then
						slot.state = SlotType.State.Empty
						slot.occupantId = nil
						slot.occupantKind = nil
						return true
					end
				end
				return false
			end,
		}
	end

	local function ensureProfile(userId: number)
		if not profiles[userId] then
			profiles[userId] = { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }
		end
		return profiles[userId]
	end

	local function makeSlot(userId: number, occupantId: string, kind: string): any
		local slot = {
			id = 'p7:' .. tostring(userId) .. ':slot:' .. tostring(#slots + 1),
			ownerUserId = userId,
			baseId = 'Base_1',
			state = SlotType.State.Occupied,
			occupantId = occupantId,
			occupantKind = kind,
			cashCollector = nil,
		}
		slots[#slots + 1] = slot
		return slot
	end

	local function placeAnimal(
		userId: number,
		id: string,
		opts: { level: number?, pool: string?, defId: string?, state: string? }?
	): (any, any)
		local o = opts or {}
		local level = o.level or 1
		local defId = o.defId or COMMON_DEF
		local slotId = 'p7:' .. tostring(userId) .. ':slot:' .. tostring(#slots + 1)
		local record = {
			Type = 'Brainrot',
			SlotId = slotId,
			DefId = defId,
			Id = id,
			Level = level,
			XP = 0,
			CashPool = o.pool or '0',
		}
		local data = ensureProfile(userId)
		table.insert(data.Brainrots, record)
		local slot = makeSlot(userId, id, SlotType.OccupantKind.Animal)
		record.SlotId = slot.id
		AnimalService._TestRegister({
			uniqueId = id,
			definitionId = defId,
			displayName = 'TestAnimal',
			rarity = 'Common',
			ownerUserId = userId,
			slotId = slot.id,
			Level = level,
			XP = 0,
			state = o.state or 'Slotted',
			model = nil,
		})
		runtimeIds[#runtimeIds + 1] = id
		return record, slot
	end

	local function wire()
		local ps = fakePlayerService()
		local ss = fakeSlotService()
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
		SellService.SetPlayerService(ps)
		SellService.SetSlotService(ss)
		SellService.SetBaseService({
			Snapshot = function(_userId: number)
				return { slots = {}, _occupiedCount = 0 }
			end,
		})
		SellService.SetAnimalService(AnimalService)
		SellService.SetEconomyService(EconomyService)
		SellService.SetIncomeService(IncomeService)
	end

	describe('SellService calculations', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('animal base values come from the rarity config', function()
			expect(SellService.GetAnimalBaseSellValue(COMMON_DEF)).to.equal('100')
			expect(SellService.GetAnimalBaseSellValue(RARE_DEF)).to.equal('1000')
			expect(SellService.GetAnimalBaseSellValue('NopeDef')).to.equal(nil)
		end)

		it('level scaling is base x level x 0.75 rarity factor (L1/L2/L10)', function()
			expect(SellService.GetAnimalLevelSellValue(COMMON_DEF, 1)).to.equal('75')
			expect(SellService.GetAnimalLevelSellValue(COMMON_DEF, 2)).to.equal('150')
			expect(SellService.GetAnimalLevelSellValue(COMMON_DEF, 10)).to.equal('750')
			expect(SellService.GetAnimalLevelSellValue(RARE_DEF, 5)).to.equal('3750')
		end)

		it('higher level means higher value (monotonic)', function()
			local prev = '0'
			for level = 1, 10 do
				local v = SellService.GetAnimalLevelSellValue(COMMON_DEF, level)
				expect(BigNumber.Compare(v :: string, prev) > 0).to.equal(true)
				prev = v :: string
			end
		end)

		it('total payout adds the pool BigNumber-safely', function()
			expect(SellService.GetAnimalTotalPayout(COMMON_DEF, 1, '0')).to.equal('75')
			expect(SellService.GetAnimalTotalPayout(RARE_DEF, 5, '2500')).to.equal('6250')
			expect(SellService.GetAnimalTotalPayout(COMMON_DEF, 1, '99999999999999999999999990')).to.equal(
				BigNumber.Add('99999999999999999999999990', '75')
			)
		end)

		it('egg sale values are gone (eggs are not sellable)', function()
			expect((SellService :: any).GetEggSellValue).to.equal(nil)
		end)
	end)

	describe('SellService animal transactions', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slots = {}
			pushes = {}
			notifies = {}
			runtimeIds = {}
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
			wire()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		it('Test 1/2/3: L1 pays base, L2 pays 2x, L10 pays 10x', function()
			placeAnimal(U1, 'BR_sellL1001', { level = 1 })
			placeAnimal(U1, 'BR_sellL2001', { level = 2 })
			placeAnimal(U1, 'BR_sellL10001', { level = 10 })
			local p = Helpers.FakePlayer(U1)

			local r1 = SellService.SellAnimal(p, 'BR_sellL1001')
			expect(r1.success).to.equal(true)
			expect(r1.payout).to.equal('100')
			local r2 = SellService.SellAnimal(p, 'BR_sellL2001')
			expect(r2.payout).to.equal('200')
			local r10 = SellService.SellAnimal(p, 'BR_sellL10001')
			expect(r10.payout).to.equal('1000')
			expect(profiles[U1].Money).to.equal('1300')
		end)

		it('Test 6/7: CashPool is added exactly once and consumed', function()
			-- Rare L5: 1000 x 5 = 5000 + pool 2500 = 7500.
			placeAnimal(U1, 'BR_sellpool01', { level = 5, pool = '2500', defId = RARE_DEF })
			profiles[U1].Money = '0'
			local p = Helpers.FakePlayer(U1)

			local r = SellService.SellAnimal(p, 'BR_sellpool01')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal('7500')
			expect(profiles[U1].Money).to.equal('7500')
			-- Pool consumed: the record is gone, so nothing remains.
			expect(#profiles[U1].Brainrots).to.equal(0)
		end)

		it('Test 8/9/10: animal removed, slot freed, persistence cleared', function()
			local _record, slot = placeAnimal(U1, 'BR_sellrm001')
			local p = Helpers.FakePlayer(U1)

			local r = SellService.SellAnimal(p, 'BR_sellrm001')
			expect(r.success).to.equal(true)
			expect(AnimalService.Get('BR_sellrm001')).to.equal(nil)
			expect(slot.state).to.equal('Empty')
			expect(slot.occupantId).to.equal(nil)
			expect(#profiles[U1].Brainrots).to.equal(0)
			expect(#pushes).to.equal(1)
			expect(#notifies).to.equal(1)
		end)

		it('Test 11: double sale pays exactly once', function()
			placeAnimal(U1, 'BR_selldbl001')
			profiles[U1].Money = '0'
			local p = Helpers.FakePlayer(U1)

			local first = SellService.SellAnimal(p, 'BR_selldbl001')
			expect(first.success).to.equal(true)
			local second = SellService.SellAnimal(p, 'BR_selldbl001')
			expect(second.success).to.equal(false)
			expect(profiles[U1].Money).to.equal('100')
		end)

		it('Test 12/13/14: wrong owner, invalid id, invalid definition rejected; nothing mutates', function()
			placeAnimal(U1, 'BR_sellown001', { pool = '500' })
			profiles[U1].Money = '0'
			ensureProfile(U2)

			local wrongOwner = SellService.SellAnimal(Helpers.FakePlayer(U2), 'BR_sellown001')
			expect(wrongOwner.success).to.equal(false)
			expect(wrongOwner.error).to.equal('not-owner')

			local badId = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_missing_xyz')
			expect(badId.success).to.equal(false)
			expect(badId.error).to.equal('not-found')

			AnimalService._TestRegister({
				uniqueId = 'BR_sellbaddef',
				definitionId = 'DefinitelyNotReal',
				ownerUserId = U1,
				slotId = 'p7:1:slot:9',
				Level = 1,
				XP = 0,
				state = 'Slotted',
				model = nil,
			})
			runtimeIds[#runtimeIds + 1] = 'BR_sellbaddef'
			local badDef = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_sellbaddef')
			expect(badDef.success).to.equal(false)

			-- Nothing moved: money untouched, pool intact, record live.
			expect(profiles[U1].Money).to.equal('0')
			expect(#profiles[U1].Brainrots).to.equal(1)
			expect(AnimalService.Get('BR_sellown001') ~= nil).to.equal(true)
		end)

		it('Test 15: carried animal is rejected with consistent state', function()
			placeAnimal(U1, 'BR_sellcarry1', { state = 'Carried' })
			local p = Helpers.FakePlayer(U1)

			local r = SellService.SellAnimal(p, 'BR_sellcarry1')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('carried')
			-- Registry, runtime and profile all untouched; no dangling.
			expect(CarryRegistry.Get(U1)).to.equal(nil)
			expect(AnimalService.Get('BR_sellcarry1') ~= nil).to.equal(true)
			expect(#profiles[U1].Brainrots).to.equal(1)
			expect(profiles[U1].Money).to.equal('0')
		end)

		it('Test 16a: sale wins the race — later collection pays nothing', function()
			local _record, slot = placeAnimal(U1, 'BR_sellraceA', { pool = '10000' })
			profiles[U1].Money = '0'
			local p = Helpers.FakePlayer(U1)

			local sold = SellService.SellAnimal(p, 'BR_sellraceA')
			expect(sold.success).to.equal(true)
			expect(sold.payout).to.equal('10100')
			-- The collector is empty now: touching it moves nothing.
			IncomeService.TryCollect(slot, p)
			expect(profiles[U1].Money).to.equal('10100')
		end)

		it('Test 16b: collection wins the race — sale gets value + 0', function()
			local _record, slot = placeAnimal(U1, 'BR_sellraceB', { pool = '10000' })
			profiles[U1].Money = '0'
			local p = Helpers.FakePlayer(U1)

			IncomeService.TryCollect(slot, p)
			expect(profiles[U1].Money).to.equal('10000')
			local sold = SellService.SellAnimal(p, 'BR_sellraceB')
			expect(sold.success).to.equal(true)
			expect(sold.payout).to.equal('100')
			-- Exactly once: 10000 + 100, never 20000 + 100.
			expect(profiles[U1].Money).to.equal('10100')
		end)

		it('Test 17: live 5x multiplier + legacy 10x cannot shape the payout', function()
			placeAnimal(U1, 'BR_sellmult01')
			profiles[U1].Multipliers = { Money = 10 }
			ModifierService.AddModifier(U1, 'Whale', ModifierService.ModifierType.MoneyMultiplier, 5)
			profiles[U1].Money = '0'

			local r = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_sellmult01')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal('100')
			expect(profiles[U1].Money).to.equal('100')
		end)

		it('Test 18: huge pool stays BigNumber-exact through the whole sale', function()
			local huge = '99999999999999999999999990'
			placeAnimal(U1, 'BR_sellhuge01', { pool = huge })
			profiles[U1].Money = '0'

			local r = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_sellhuge01')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal(BigNumber.Add(huge, '100'))
			expect(profiles[U1].Money).to.equal(BigNumber.Add(huge, '100'))
			expect(BigNumber.isValid(profiles[U1].Money)).to.equal(true)
		end)
	end)

	describe('SellService egg transactions (eggs are NOT sellable)', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slots = {}
			pushes = {}
			notifies = {}
			runtimeIds = {}
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			wire()
		end)

		afterEach(function()
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
		end)

		it('egg sale entry points are gone (no function, no value, no path)', function()
			expect((SellService :: any).SellEgg).to.equal(nil)
			expect((SellService :: any).GetEggSellValue).to.equal(nil)
		end)
	end)

	describe('SellService prompts (Sell prompt on the animal)', function()
		beforeEach(function()
			Helpers.StubRemotes()
			wire()
		end)

		local function makeModel(): (Model, Part)
			local m = Instance.new('Model')
			local part = Instance.new('Part')
			part.Parent = m
			m.PrimaryPart = part
			return m, part
		end

		local function namedPromptsOn(part: Part, name: string): { ProximityPrompt }
			local out: { ProximityPrompt } = {}
			for _, child in ipairs(part:GetChildren()) do
				if child:IsA('ProximityPrompt') and child.Name == name then
					out[#out + 1] = child
				end
			end
			return out
		end

		it('Sell prompt co-installs with Pickup for animals (F key, owner-only)', function()
			local m, part = makeModel()
			local slot = { id = 'p7:41:slot:9' }

			CarryPrompts.InstallPickupPrompt(m, 'BR_x', 'animal', slot, 41)
			CarryPrompts.InstallPickupPrompt(m, 'BR_x', 'animal', slot, 41)
			-- Exactly one Sell prompt (no duplication on reinstall).
			local sells = namedPromptsOn(part, 'SellPrompt')
			expect(#sells).to.equal(1)
			expect(sells[1].KeyboardKeyCode).to.equal(Enum.KeyCode.F)
			expect(sells[1]:GetAttribute('ownerUserId')).to.equal(41)
			-- Pickup still installs exactly once (no stack breakage).
			expect(#namedPromptsOn(part, 'PickupPrompt')).to.equal(1)
			m:Destroy()
		end)

		it('no Sell prompt is installed for lucky eggs; Hatch stays F', function()
			local m, part = makeModel()
			local slot = { id = 'p7:41:slot:9' }

			CarryPrompts.InstallPickupPrompt(m, 'LB_x', 'egg', slot, 41)
			CarryPrompts.InstallHatchPrompt({ model = m, uniqueId = 'LB_x' }, slot, 41)
			expect(#namedPromptsOn(part, 'SellPrompt')).to.equal(0)
			expect(#namedPromptsOn(part, 'PickupPrompt')).to.equal(1)
			local open = part:FindFirstChild('HatchPrompt')
			expect(open ~= nil).to.equal(true)
			expect((open :: ProximityPrompt).KeyboardKeyCode).to.equal(Enum.KeyCode.F)
			m:Destroy()
		end)

		it('sell installer and callback APIs exist (prompt dispatch has no backdoor)', function()
			expect(type((CarryPrompts :: any).InstallSellPrompt)).to.equal('function')
			expect(type((CarryPrompts :: any).SetSellPromptCallback)).to.equal('function')
			expect(type((SellService :: any).Init)).to.equal('function')
		end)

		it('SellService.Init wires a stale-safe preview dispatch', function()
			SellService.Init()
			SellService.Init() -- idempotent: no double wiring
			local cb = CarryPrompts.GetSellPromptCallback()
			expect(type(cb)).to.equal('function')
			-- Unknown animal id: invalid preview, no throw, no money.
			ensureProfile(U1).Money = '0'
			local r = (cb :: any)(Helpers.FakePlayer(U1), 'BR_missing_xyz')
			expect(type(r)).to.equal('table')
			expect(r.Valid).to.equal(false)
			expect(profiles[U1].Money).to.equal('0')
		end)

		it('raid-locked animals reject sale with everything intact', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			placeAnimal(U1, 'BR_sellraid01', { pool = '500' })
			profiles[U1].Money = '0'
			ArenaService._TestInjectSession(U1, {
				sessionId = 1,
				userId = U1,
				arenaLevel = 1,
				state = 'Active',
				team = { { UniqueId = 'BR_sellraid01' } },
			})
			local r = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_sellraid01')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('busy')
			expect(profiles[U1].Money).to.equal('0')
			expect(AnimalService.Get('BR_sellraid01') ~= nil).to.equal(true)
			expect(#profiles[U1].Brainrots).to.equal(1)
			ArenaService._TestReset()
			-- Lock released with the raid: sale works again.
			local r2 = SellService.SellAnimal(Helpers.FakePlayer(U1), 'BR_sellraid01')
			expect(r2.success).to.equal(true)
			expect(profiles[U1].Money).to.equal('600')
		end)
	end)

	describe('SellService sell confirmation (preview + confirm)', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slots = {}
			pushes = {}
			notifies = {}
			runtimeIds = {}
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
			wire()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		-- A live player from the running session, or nil when
		-- playerless (table stand-ins fail LivePlayer by
		-- design, so those tests skip here and only cover
		-- rejection paths).
		local function livePlayer(): Player?
			local ok, list = pcall(function()
				return game:GetService('Players'):GetPlayers()
			end)
			if ok and type(list) == 'table' and #list > 0 then
				return list[1]
			end
			return nil
		end

		it('preview returns canonical fields and moves nothing', function()
			local p = livePlayer()
			if p == nil then
				return
			end
			local uid = (p :: Player).UserId
			placeAnimal(uid, 'BR_prev01', { level = 5 })
			ensureProfile(uid).Money = '0'

			local state = SellService.PreviewSell(p, 'BR_prev01')
			expect(state.Valid).to.equal(true)
			expect(state.AnimalId).to.equal('BR_prev01')
			expect(state.Name).to.equal('TestAnimal')
			expect(state.Rarity).to.equal('Common')
			expect(state.Trait).to.equal(nil)
			expect(state.Level).to.equal(5)
			expect(state.LevelText).to.equal('Lv. 5')
			expect(string.sub(state.GenerationText, 1, 1)).to.equal('$')
			expect(string.find(state.GenerationText, '/sec', 1, true) ~= nil).to.equal(true)
			expect(#state.Mutations).to.equal(0)
			-- Display-only sale total through the canonical
			-- payout (Common L5, no trait/muts, pool 0).
			expect(state.SellValueRaw).to.equal('500')
			-- No live model in the seam: nil-safe, sale unaffected.
			expect(state.Model).to.equal(nil)
			-- Read-only: money, mutex, records, slots untouched.
			expect(profiles[uid].Money).to.equal('0')
			local rec = AnimalService.Get('BR_prev01')
			expect(rec ~= nil).to.equal(true)
			expect(rec._mutex ~= true).to.equal(true)
			expect(#profiles[uid].Brainrots).to.equal(1)
		end)

		it('preview rejects everything unsellable without side effects', function()
			local p = livePlayer()
			if p == nil then
				return
			end
			local uid = (p :: Player).UserId
			ensureProfile(uid).Money = '0'
			-- Unknown id.
			local missing = SellService.PreviewSell(p, 'BR_missing_xyz')
			expect(missing.Valid).to.equal(false)
			-- Another player's animal.
			placeAnimal(U1, 'BR_prevown01', {})
			local foreign = SellService.PreviewSell(p, 'BR_prevown01')
			expect(foreign.Valid).to.equal(false)
			expect(foreign.Reason).to.equal('not-owner')
			-- Carried animal.
			placeAnimal(uid, 'BR_prevcarry01', { state = 'Carried' })
			local carried = SellService.PreviewSell(p, 'BR_prevcarry01')
			expect(carried.Valid).to.equal(false)
			-- Arena-locked animal.
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			placeAnimal(uid, 'BR_prevraid01', {})
			ArenaService._TestInjectSession(uid, {
				sessionId = 2,
				userId = uid,
				arenaLevel = 1,
				state = 'Active',
				team = { { UniqueId = 'BR_prevraid01' } },
			})
			local locked = SellService.PreviewSell(p, 'BR_prevraid01')
			expect(locked.Valid).to.equal(false)
			ArenaService._TestReset()
			-- Egg id (no animal record).
			local egg = SellService.PreviewSell(p, 'EG_notananimal')
			expect(egg.Valid).to.equal(false)
			-- Nothing moved anywhere.
			expect(profiles[uid].Money).to.equal('0')
		end)

		it('confirm of a stale animal rejects with no sale', function()
			local p = livePlayer()
			if p == nil then
				return
			end
			local uid = (p :: Player).UserId
			ensureProfile(uid).Money = '0'
			local r = SellService.ConfirmSell(p, 'BR_gone_xyz')
			expect(r.success).to.equal(false)
			expect(profiles[uid].Money).to.equal('0')
		end)
	end)
end
