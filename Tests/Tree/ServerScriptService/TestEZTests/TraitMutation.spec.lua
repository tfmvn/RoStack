--!strict
--!native
--[[
	TraitMutation.spec
	==================
	Phase 2.11 tests: Traits (0-or-1, rolled or forced) and
	Mutations (N unique, multiplicative), inheritance, audit,
	and economy integration. Uses the REAL TraitService,
	MutationService, BigNumber, AnimalStats, LevelConfig and —
	for the integration eggs — the REAL IncomeService,
	EconomyService, SellService and AnimalService with
	hand-rolled fakes (the IncomeService.spec / SellService.spec
	pattern). No models, no Workspace, no DataStore.

	Locked in (§31):
	  TRAITS: nil valid; exactly one; invalid rejected; roll at
	  most one; multipliers correct; chance config coherent.
	  MUTATIONS: empty/one/many; duplicates + invalid removed;
	  multiplicative stacking; empty = 1x; order-independent.
	  DECIMAL MATH: exact terminating strings, chained folds,
	  huge values, loud errors on malformed input.
	  INHERITANCE: forced trait 100% (no roll); nil trait rolls;
	  invalid forced falls back to roll; mutations copied (never
	  aliased); exactly one trait out.
	  AUDIT: legacy rows default (nil/{}); invalid trait clears;
	  invalid/dup mutations drop; LB mutations + pending trait
	  survive round-trips.
 	  ECONOMY: tick + offline use intrinsic (trait x mut) income
 	  and bypass the player multiplier; sales fold trait + mut
 	  multipliers exactly; CashPool stays additive.
 ]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local TraitService = require(ServerScriptService.TraitService)
	local MutationService = require(ServerScriptService.MutationService)
	local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)
	local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
	local OwnedObjectIdentity = require(ReplicatedStorage.Utility.OwnedObjectIdentity)
	local PersistenceAudit = require(ServerScriptService['Base'].PersistenceAudit)
	local IncomeService = require(ServerScriptService.IncomeService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local ModifierService = require(ServerScriptService.ModifierService)
	local AnimalService = require(ServerScriptService.AnimalService)
	local SellService = require(ServerScriptService.SellService)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local DEF = 'Chicken' -- Common: income base 2/s, sell base 100

	describe('TraitService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('nil is valid data (no trait) and folds to identity', function()
			expect(TraitService.IsValidTrait(nil)).to.equal(false)
			expect(TraitService.GetGenerationMultiplier(nil)).to.equal(1)
			expect(TraitService.GetSellMultiplier(nil)).to.equal('1')
			expect(TraitConfig.Get('None')).to.equal(nil)
		end)

		it('exactly one trait per roll, never a list', function()
			for _, override in ipairs({ 0, 0.05, 0.109, 0.11, 0.139, 0.141, 0.149, 0.5, 0.99 }) do
				local result = TraitService.RollTrait(override)
				expect(result == nil or type(result) == 'string').to.equal(true)
			end
		end)

		it('roll buckets follow RollOrder cumulative chances', function()
			-- Gold [0, .10), Diamond [.10, .14), Rainbow [.14, .15).
			expect(TraitService.RollTrait(0)).to.equal('Gold')
			expect(TraitService.RollTrait(0.099)).to.equal('Gold')
			expect(TraitService.RollTrait(0.10)).to.equal('Diamond')
			expect(TraitService.RollTrait(0.139)).to.equal('Diamond')
			expect(TraitService.RollTrait(0.14)).to.equal('Rainbow')
			expect(TraitService.RollTrait(0.149)).to.equal('Rainbow')
			expect(TraitService.RollTrait(0.15)).to.equal(nil)
			expect(TraitService.RollTrait(0.999)).to.equal(nil)
		end)

		it('bad overrides fall back to a live random roll (never crash)', function()
			for _, bad in ipairs({ nil, -1, 1, 2, 0 / 0, 'Gold', {} }) do
				local result = TraitService.RollTrait(bad)
				local ok = result == nil or TraitService.IsValidTrait(result)
				expect(ok).to.equal(true)
			end
		end)

		it('multipliers match the catalog; unknown degrades to 1x', function()
			expect(TraitService.GetGenerationMultiplier('Gold')).to.equal(3)
			expect(TraitService.GetSellMultiplier('Gold')).to.equal('1.2')
			expect(TraitService.GetGenerationMultiplier('Diamond')).to.equal(5)
			expect(TraitService.GetSellMultiplier('Diamond')).to.equal('1.5')
			expect(TraitService.GetGenerationMultiplier('Rainbow')).to.equal(10)
			expect(TraitService.GetSellMultiplier('Rainbow')).to.equal('2')
			expect(TraitService.IsValidTrait('Platinum')).to.equal(false)
			expect(TraitService.GetGenerationMultiplier('Platinum')).to.equal(1)
			expect(TraitService.GetSellMultiplier('Platinum')).to.equal('1')
		end)

		it('chance configuration is coherent (total <= 100, order covers catalog)', function()
			expect(#TraitConfig.RollOrder).to.equal(3)
			local total = 0
			for _, id in ipairs(TraitConfig.RollOrder) do
				total += TraitConfig.Catalog[id].Chance :: number
			end
			expect(total <= 100).to.equal(true)
		end)
	end)

	describe('MutationService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('SanitizeList normalizes everything to sorted unique valid ids', function()
			expect(#MutationService.SanitizeList(nil)).to.equal(0)
			expect(#MutationService.SanitizeList('Void')).to.equal(0)
			expect(#MutationService.SanitizeList({})).to.equal(0)
			local clean = MutationService.SanitizeList({ 'Galactic', 'Frost', 'Galactic', 'Dragon', 42, '' })
			expect(#clean).to.equal(2)
			expect(clean[1]).to.equal('Frost')
			expect(clean[2]).to.equal('Galactic')
		end)

		it('generation folds multiplicatively; empty is 1x; order-free', function()
			expect(MutationService.GetGenerationMultiplier({})).to.equal(1)
			expect(MutationService.GetGenerationMultiplier(nil)).to.equal(1)
			expect(MutationService.GetGenerationMultiplier({ 'Galactic' })).to.equal(3)
			-- 3 x 2.5 = 7.5.
			expect(MutationService.GetGenerationMultiplier({ 'Galactic', 'Frost' })).to.equal(7.5)
			expect(MutationService.GetGenerationMultiplier({ 'Frost', 'Galactic' })).to.equal(7.5)
		end)

		it('sell folds exact decimals; empty is 1x', function()
			expect(MutationService.GetSellMultiplier({})).to.equal('1')
			expect(MutationService.GetSellMultiplier(nil)).to.equal('1')
			expect(MutationService.GetSellMultiplier({ 'Galactic' })).to.equal('2.5')
			expect(MutationService.GetSellMultiplier({ 'Frost' })).to.equal('2')
			expect(MutationService.GetSellMultiplier({ 'Galactic', 'Frost' })).to.equal('5')
			-- 2.5 x 2 = 5 exactly.
			expect(MutationService.GetSellMultiplier({ 'Frost', 'Galactic' })).to.equal('5')
		end)

		it('ParseListInput accepts every admin spelling, rejects precisely', function()
			local ok1, list1 = MutationService.ParseListInput(nil)
			expect(ok1).to.equal(true)
			expect(#list1).to.equal(0)
			for _, empty in ipairs({ '', '-', 'none', 'NONE', '[]', '   ' }) do
				local ok, list = MutationService.ParseListInput(empty)
				expect(ok).to.equal(true)
				expect(#list).to.equal(0)
			end
			local ok2, list2 = MutationService.ParseListInput('Galactic,Frost')
			expect(ok2).to.equal(true)
			expect(#list2).to.equal(2)
			local ok3, list3 = MutationService.ParseListInput('["Galactic","Frost"]')
			expect(ok3).to.equal(true)
			expect(#list3).to.equal(2)
			expect(list3[1]).to.equal('Frost')
			local okBad, errBad = MutationService.ParseListInput('Galactic,Dragon')
			expect(okBad).to.equal(false)
			expect(errBad).to.equal('Invalid mutation: "Dragon"')
			local okDup, errDup = MutationService.ParseListInput('Galactic,Galactic')
			expect(okDup).to.equal(false)
			expect(errDup).to.equal('Duplicate mutation: "Galactic"')
			local okNum = MutationService.ParseListInput(42)
			expect(okNum).to.equal(false)
		end)
	end)

	describe('BigNumber.MultiplyDecimal', function()
		it('multiplies exact terminating decimals', function()
			expect(BigNumber.MultiplyDecimal('100', '1.5')).to.equal('150')
			expect(BigNumber.MultiplyDecimal('1000', '1.25')).to.equal('1250')
			expect(BigNumber.MultiplyDecimal('100', '1.5625')).to.equal('156.25')
			expect(BigNumber.MultiplyDecimal('100', '2')).to.equal('200')
			expect(BigNumber.MultiplyDecimal('0', '7.5')).to.equal('0')
		end)

		it('chains exactly (fractional running values)', function()
			expect(BigNumber.MultiplyDecimal('156.25', '1.5')).to.equal('234.375')
			expect(BigNumber.MultiplyDecimal('99999999999999999999999990', '2')).to.equal('199999999999999999999999980')
		end)

		it('rejects malformed input loudly', function()
			expect(function()
				BigNumber.MultiplyDecimal('abc', '1.5')
			end).to.throw()
			expect(function()
				BigNumber.MultiplyDecimal('100', 'abc')
			end).to.throw()
			expect(function()
				BigNumber.MultiplyDecimal('100', '1.2.3')
			end).to.throw()
			expect(function()
				BigNumber.MultiplyDecimal('100', '0')
			end).to.throw()
			expect(function()
				BigNumber.MultiplyDecimal('100', '-2')
			end).to.throw()
			expect(function()
				BigNumber.MultiplyDecimal('100', '1.2345678')
			end).to.throw()
		end)
	end)

	describe('TraitService.ResolveInheritance', function()
		it('forced trait transfers 100% with no roll', function()
			-- Override 0.99 would roll nil — the forced value must
			-- win regardless.
			local r = TraitService.ResolveInheritance('Rainbow', { 'Galactic' }, 0.99)
			expect(r.Trait).to.equal('Rainbow')
			expect(#r.Mutations).to.equal(1)
			expect(r.Mutations[1]).to.equal('Galactic')
		end)

		it('nil trait rolls through the override', function()
			expect(TraitService.ResolveInheritance(nil, {}, 0.05).Trait).to.equal('Gold')
			expect(TraitService.ResolveInheritance(nil, {}, 0.5).Trait).to.equal(nil)
		end)

		it('invalid forced trait falls back to the roll', function()
			local r = TraitService.ResolveInheritance('Platinum', {}, 0.05)
			expect(r.Trait).to.equal('Gold')
		end)

		it('mutations copy defensively (never aliased, sorted)', function()
			local blockMutations = { 'Galactic', 'Frost' }
			local r = TraitService.ResolveInheritance(nil, blockMutations, 0.5)
			expect(#r.Mutations).to.equal(2)
			expect(r.Mutations[1]).to.equal('Frost')
			expect(r.Mutations[2]).to.equal('Galactic')
			-- Mutating the result must not touch the egg list.
			r.Mutations[1] = 'MUTATED'
			expect(blockMutations[1]).to.equal('Galactic')
			-- The egg list itself is never reordered in place.
			expect(blockMutations[2]).to.equal('Frost')
		end)
	end)

	describe('economy integration (income tick + offline)', function()
		local USER = 8101
		local profiles: { [number]: any } = {}
		local offlineAnchors: { [number]: number } = {}
		local slots: { any } = {}

		local function fakePlayerService()
			return {
				GetPlayerData = function(userId: number)
					return profiles[userId]
				end,
				ConsumeOfflineTimestamp = function(userId: number): number
					local captured = offlineAnchors[userId] or 0
					offlineAnchors[userId] = nil
					return captured
				end,
			}
		end

		local function place(id: string, trait: string?, mutations: { string }?, pool: string?): any
			local slotId = 'p7:' .. tostring(USER) .. ':slot:' .. tostring(#slots + 1)
			local record = {
				Type = 'Brainrot',
				SlotId = slotId,
				DefId = DEF,
				Id = id,
				Level = 1,
				XP = 0,
				CashPool = pool or '0',
				Trait = trait,
				Mutations = mutations or {},
			}
			profiles[USER] = profiles[USER]
				or { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LastSeen = os.time() }
			table.insert(profiles[USER].Brainrots, record)
			slots[#slots + 1] = {
				id = slotId,
				ownerUserId = USER,
				baseId = 'Base_1',
				state = SlotType.State.Occupied,
				occupantId = id,
				occupantKind = SlotType.OccupantKind.Animal,
				cashCollector = nil,
			}
			return record
		end

		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			offlineAnchors = {}
			slots = {}
			ModifierService.ClearModifiers(USER)
			IncomeService.ForgetPlayer(USER)
			local ps = fakePlayerService()
			IncomeService.Init()
			IncomeService.SetPlayerService(ps)
			IncomeService.SetEconomyService(EconomyService)
			IncomeService.SetSlotService({
				FindSlotByOccupant = function(occupantId: string): any?
					for _, slot in ipairs(slots) do
						if slot.occupantId == occupantId then
							return slot
						end
					end
					return nil
				end,
			})
			IncomeService.SetBaseService({
				GetAllBases = function()
					return {}
				end,
			})
			IncomeService.SetAnimalService({
				GetCarriedAnimalByUserId = function(_userId: number)
					return nil
				end,
			})
			IncomeService.SetModifierService(ModifierService)
			EconomyService.Init()
			EconomyService.SetPlayerService(ps)
		end)

		afterEach(function()
			ModifierService.ClearModifiers(USER)
			IncomeService.ForgetPlayer(USER)
			IncomeService.SetModifierService(nil)
		end)

		it('online tick credits intrinsic (base x trait x mutations) x elapsed', function()
			-- Common L1 base 2/s x Gold 3 x Galactic 3 = 18/s.
			local record = place('BR_trait_tick01', 'Gold', { 'Galactic' })
			IncomeService.TickSources(10, { USER })
			expect(record.CashPool).to.equal('180')
		end)

		it('untraited rows are byte-identical to pre-2.11 behavior', function()
			local record = place('BR_trait_tick02', nil, {})
			IncomeService.TickSources(10, { USER })
			expect(record.CashPool).to.equal('20')
		end)

		it('offline applies the live multiplier at 50% effectiveness', function()
			-- A30 shape: 100 x 2 x 2 x 10 scaled down — Common
			-- L1 2/s x Diamond 5 x Frost 2.5 = 25/s, x 5 (wallet)
			-- x 0.5 (offline) x 100s = 6250.
			local record = place('BR_trait_off01', 'Diamond', { 'Frost' })
			ModifierService.AddModifier(USER, 'Whale', ModifierService.ModifierType.MoneyMultiplier, 5)
			offlineAnchors[USER] = os.time() - 100
			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER))
			expect(record.CashPool).to.equal('6250')
		end)
	end)

	describe('economy integration (sales)', function()
		local USER = 8102
		local profiles: { [number]: any } = {}
		local slots: { any } = {}
		local eggs: { [string]: any } = {}
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
				PushState = function(_player: Player, _snap: any) end,
				Notify = function(_player: Player, _category: string, _text: string) end,
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
		end

		local function placeAnimal(id: string, trait: string?, mutations: { string }?, pool: string?)
			local slotId = 'p7:' .. tostring(USER) .. ':slot:' .. tostring(#slots + 1)
			profiles[USER] = profiles[USER]
				or { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }
			table.insert(profiles[USER].Brainrots, {
				Type = 'Brainrot',
				SlotId = slotId,
				DefId = DEF,
				Id = id,
				Level = 1,
				XP = 0,
				CashPool = pool or '0',
				Trait = trait,
				Mutations = mutations or {},
			})
			slots[#slots + 1] = {
				id = slotId,
				ownerUserId = USER,
				baseId = 'Base_1',
				state = SlotType.State.Occupied,
				occupantId = id,
				occupantKind = SlotType.OccupantKind.Animal,
				cashCollector = nil,
			}
			AnimalService._TestRegister({
				uniqueId = id,
				definitionId = DEF,
				ownerUserId = USER,
				slotId = slotId,
				Level = 1,
				XP = 0,
				state = 'Slotted',
				Trait = trait,
				Mutations = mutations or {},
				model = nil,
			})
			runtimeIds[#runtimeIds + 1] = id
		end

		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slots = {}
			eggs = {}
			runtimeIds = {}
			ModifierService.ClearModifiers(USER)
			IncomeService.ForgetPlayer(USER)
			wire()
		end)

		afterEach(function()
			for _, id in ipairs(runtimeIds) do
				AnimalService._TestUnregister(id)
			end
			ModifierService.ClearModifiers(USER)
			IncomeService.ForgetPlayer(USER)
			IncomeService.SetModifierService(nil)
			AnimalService.SetModifierService(nil)
		end)

		it('animal sale folds trait + mutation sell multipliers exactly', function()
			-- Common L1: 100 x 0.75 x Rainbow 2 x Galactic 2.5
			-- x Frost 2 = 750, + pool 500 = 1250.
			placeAnimal('BR_traitsale01', 'Rainbow', { 'Galactic', 'Frost' }, '500')
			profiles[USER].Money = '0'

			local r = SellService.SellAnimal(Helpers.FakePlayer(USER), 'BR_traitsale01')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal('1250')
			expect(profiles[USER].Money).to.equal('1250')
		end)

		it('multipliers stay exact (Galactic x2.5 + Frost x2)', function()
			-- 100 x 0.75 x 2.5 x 2 = 375 exactly.
			placeAnimal('BR_traitsale02', nil, { 'Galactic', 'Frost' }, '0')

			local r = SellService.SellAnimal(Helpers.FakePlayer(USER), 'BR_traitsale02')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal('375')
		end)

		it('sale ignores a 5x multiplier and legacy profile hook alike', function()
			placeAnimal('BR_traitsale03', 'Gold', { 'Galactic' }, '10')
			profiles[USER].Multipliers = { Money = 10 }
			ModifierService.AddModifier(USER, 'Whale', ModifierService.ModifierType.MoneyMultiplier, 5)
			profiles[USER].Money = '0'

			-- 100 x 0.75 x 1.2 x 2.5 + 10 = 235. Never 5x, never 10x.
			local r = SellService.SellAnimal(Helpers.FakePlayer(USER), 'BR_traitsale03')
			expect(r.success).to.equal(true)
			expect(r.payout).to.equal('235')
		end)

		it('egg sale entry points are gone (eggs are not sellable)', function()
			expect((SellService :: any).SellEgg).to.equal(nil)
			expect((SellService :: any).GetEggSellValue).to.equal(nil)
		end)
	end)

	describe('upgrade + XP preserve trait and mutations', function()
		beforeEach(function()
			Helpers.StubRemotes()
			AnimalService.SetModifierService(ModifierService)
		end)

		afterEach(function()
			AnimalService._TestUnregister('BR_traitkeep01')
			AnimalService.SetModifierService(nil)
		end)

		it('AddXP and ApplyLevelUpgrade keep Trait/Mutations identical', function()
			AnimalService._TestRegister({
				uniqueId = 'BR_traitkeep01',
				definitionId = DEF,
				ownerUserId = 8103,
				slotId = 'p7:8103:slot:1',
				Level = 5,
				XP = 40,
				state = 'Slotted',
				Trait = 'Diamond',
				Mutations = { 'Frost', 'Galactic' },
				model = nil,
			})

			local xpResult = AnimalService:AddXP('BR_traitkeep01', 10)
			expect(xpResult.success).to.equal(true)
			local afterXP = AnimalService.Get('BR_traitkeep01')
			expect(afterXP.Trait).to.equal('Diamond')
			expect(#afterXP.Mutations).to.equal(2)

			local upResult = AnimalService.ApplyLevelUpgrade('BR_traitkeep01')
			expect(upResult.success).to.equal(true)
			expect(upResult.newLevel).to.equal(6)
			local afterUp = AnimalService.Get('BR_traitkeep01')
			expect(afterUp.Trait).to.equal('Diamond')
			expect(#afterUp.Mutations).to.equal(2)
			expect(afterUp.XP).to.equal(50)
		end)
	end)

	describe('PersistenceAudit trait/mutation cleaning', function()
		local SLOT_A = 'p7:1:slot:1'
		local SLOT_B = 'p7:1:slot:2'

		it('legacy rows default silently (nil trait, empty lists)', function()
			local profileData = {
				Brainrots = {
					{
						Type = 'Brainrot',
						SlotId = SLOT_A,
						DefId = DEF,
						Id = OwnedObjectIdentity.Generate('Brainrot'),
						Level = 1,
						XP = 0,
						CashPool = '0',
					},
				},
				LuckyBlocks = {
					{
						Type = 'LuckyBlock',
						SlotId = SLOT_B,
						Rarity = 'Common',
						Id = OwnedObjectIdentity.Generate('LuckyBlock'),
					},
				},
			}
			local result = PersistenceAudit.Audit(profileData)
			expect(#result.Issues).to.equal(0)
			expect(result.Brainrots[1].Trait).to.equal(nil)
			expect(#result.Brainrots[1].Mutations).to.equal(0)
			expect(#result.LuckyBlocks[1].Mutations).to.equal(0)
			expect(result.LuckyBlocks[1].Trait).to.equal(nil)
		end)

		it('valid trait/mutations survive exactly; invalid repair loudly', function()
			local profileData = {
				Brainrots = {
					{
						Type = 'Brainrot',
						SlotId = SLOT_A,
						DefId = DEF,
						Id = OwnedObjectIdentity.Generate('Brainrot'),
						Level = 1,
						XP = 0,
						CashPool = '0',
						Trait = 'Rainbow',
						Mutations = { 'Galactic', 'Frost' },
					},
					{
						Type = 'Brainrot',
						SlotId = SLOT_B,
						DefId = DEF,
						Id = OwnedObjectIdentity.Generate('Brainrot'),
						Level = 1,
						XP = 0,
						CashPool = '0',
						Trait = 'Platinum',
						Mutations = { 'Galactic', 'Galactic', 'Dragon' },
					},
				},
				LuckyBlocks = {},
			}
			local result = PersistenceAudit.Audit(profileData)
			local good = result.Brainrots[1]
			expect(good.Trait).to.equal('Rainbow')
			expect(#good.Mutations).to.equal(2)
			local bad = result.Brainrots[2]
			expect(bad.Trait).to.equal(nil)
			expect(#bad.Mutations).to.equal(1)
			expect(bad.Mutations[1]).to.equal('Galactic')
			expect(#result.Issues > 0).to.equal(true)
		end)

		it('egg pending trait + mutations survive; invalid pending clears', function()
			local profileData = {
				Brainrots = {},
				LuckyBlocks = {
					{
						Type = 'LuckyBlock',
						SlotId = SLOT_A,
						Rarity = 'Epic',
						Id = OwnedObjectIdentity.Generate('LuckyBlock'),
						Mutations = { 'Frost' },
						Trait = 'Gold',
					},
					{
						Type = 'LuckyBlock',
						SlotId = SLOT_B,
						Rarity = 'Epic',
						Id = OwnedObjectIdentity.Generate('LuckyBlock'),
						Mutations = {},
						Trait = 'Platinum',
					},
				},
			}
			local result = PersistenceAudit.Audit(profileData)
			expect(result.LuckyBlocks[1].Trait).to.equal('Gold')
			expect(#result.LuckyBlocks[1].Mutations).to.equal(1)
			expect(result.LuckyBlocks[2].Trait).to.equal(nil)
		end)
	end)
end
