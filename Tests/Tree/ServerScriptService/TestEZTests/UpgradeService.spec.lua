--!strict
--!native
--[[
	UpgradeService.spec
	===================
	Phase 2.10 tests for paid Animal level upgrades. Uses the
	REAL UpgradeService + EconomyService + AnimalService
	(minimal runtime records via the documented test seam) +
	ModifierService, with hand-rolled profile/slot/player fakes
	and a fake Egg runtime registry.

	Locked in (§42-§52):
	  * L99 -> L100 succeeds when affordable; L100 -> L101 fails
	    with money untouched
	  * insufficient money fails with money/level/XP/pool intact
	  * double-clicks charge per-request CURRENT-level costs,
	    never skip levels, never go negative
	  * Egg / wrong owner / stale / invalid definition
	    reject with nothing moved
	  * XP untouched, CashPool untouched, Id/slot/definition kept
	  * paid level survives AddXP (no Normalize undo), persists
	    in the profile record, re-derives cost after "rejoin"
	  * stats, income, and sale value follow the new level
	    through the existing calculators (no second formulas)
	  * 5x multiplier changes nothing (ModifierService is never
	    consulted for upgrades)
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local UpgradeService = require(ServerScriptService.UpgradeService)
	local SellService = require(ServerScriptService.SellService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local IncomeService = require(ServerScriptService.IncomeService)
	local ModifierService = require(ServerScriptService.ModifierService)
	local AnimalService = require(ServerScriptService.AnimalService)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local LevelConfig = require(ReplicatedStorage.Config.Creatures.Progression)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local U1 = 8001
	local U2 = 8002

	local COMMON_DEF = 'Chicken' -- Common: base 100

	local profiles: { [number]: any } = {}
	local slots: { any } = {}
	local eggs: { [string]: any } = {}
	local pushes: { any } = {}
	local notifies: { any } = {}
	local runtimeIds: { string } = {}

	local function fakePlayerService()
		return {
			GetPlayerData = function(userId: number)
				return profiles[userId]
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
		}
	end

	local function fakeBaseService()
		return {
			GetBaseById = function(_baseId: string): any?
				return { ownerUserId = U1 }
			end,
			Snapshot = function(_userId: number)
				return { slots = {}, _occupiedCount = 0 }
			end,
		}
	end

	local function fakeEggService()
		return {
			GetEgg = function(uniqueId: string): any?
				return eggs[uniqueId]
			end,
		}
	end

	local function wire()
		local ps = fakePlayerService()
		EconomyService.Init()
		EconomyService.SetPlayerService(ps)
		IncomeService.Init()
		IncomeService.SetPlayerService(ps)
		IncomeService.SetEconomyService(EconomyService)
		IncomeService.SetSlotService(fakeSlotService())
		IncomeService.SetBaseService({
			GetAllBases = function()
				return {}
			end,
		})
		IncomeService.SetAnimalService(AnimalService)
		IncomeService.SetModifierService(ModifierService)
		AnimalService.SetModifierService(ModifierService)
		UpgradeService.SetPlayerService(ps)
		UpgradeService.SetSlotService(fakeSlotService())
		UpgradeService.SetBaseService(fakeBaseService())
		UpgradeService.SetAnimalService(AnimalService)
		UpgradeService.SetEconomyService(EconomyService)
		SellService.SetPlayerService(ps)
		SellService.SetSlotService(fakeSlotService())
	end

	local function placeAnimal(
		userId: number,
		id: string,
		opts: { level: number?, pool: string?, xp: number?, defId: string? }?
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
			XP = o.xp or 0,
			CashPool = o.pool or '0',
		}
		profiles[userId] = profiles[userId]
			or { Money = '0', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }
		table.insert(profiles[userId].Brainrots, record)
		local slot = {
			id = slotId,
			ownerUserId = userId,
			baseId = 'Base_1',
			state = SlotType.State.Occupied,
			occupantId = id,
			occupantKind = SlotType.OccupantKind.Animal,
			cashCollector = nil,
		}
		slots[#slots + 1] = slot
		AnimalService._TestRegister({
			uniqueId = id,
			definitionId = defId,
			displayName = 'TestAnimal',
			rarity = 'Common',
			ownerUserId = userId,
			slotId = slot.id,
			Level = level,
			XP = o.xp or 0,
			state = 'Slotted',
			model = nil,
		})
		runtimeIds[#runtimeIds + 1] = id
		return record, slot
	end

	local function profileRecord(userId: number, id: string): any?
		local data = profiles[userId]
		if not data then
			return nil
		end
		for _, rec in ipairs(data.Brainrots) do
			if type(rec) == 'table' and rec.Id == id then
				return rec
			end
		end
		return nil
	end

	describe('UpgradeService transactions', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			slots = {}
			eggs = {}
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
			AnimalService.SetModifierService(nil)
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			IncomeService.ForgetPlayer(U1)
			IncomeService.ForgetPlayer(U2)
		end)

		it('successful upgrade: money debited, level +1, XP/pool/identity kept', function()
			placeAnimal(U1, 'BR_up001', { level = 5, pool = '50000', xp = 40 })
			profiles[U1].Money = '100000'

			local r = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_up001')
			expect(r.success).to.equal(true)
			expect(r.oldLevel).to.equal(5)
			expect(r.newLevel).to.equal(6)
			-- Common L5 cost: 100 x 1.12^4 = 157.351936.
			expect(r.upgradeCost).to.equal('157.351936')
			expect(profiles[U1].Money).to.equal(BigNumber.Subtract('100000', '157.351936'))
			expect(AnimalService.GetLevel('BR_up001')).to.equal(6)
			-- Untouched: XP, pool, slot, identity.
			expect(AnimalService.GetXP('BR_up001')).to.equal(40)
			local rec = profileRecord(U1, 'BR_up001')
			expect(rec.Level).to.equal(6)
			expect(rec.XP).to.equal(40)
			expect(rec.CashPool).to.equal('50000')
			expect(rec.Id).to.equal('BR_up001')
			expect(#pushes).to.equal(1)
			expect(#notifies).to.equal(1)
		end)

		it('Test 42: L99 -> L100 succeeds; L100 -> L101 fails with money intact', function()
			placeAnimal(U1, 'BR_upmax01', { level = 99 })
			profiles[U1].Money = '99999999999999999999999999'

			local ok = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upmax01')
			expect(ok.success).to.equal(true)
			expect(ok.newLevel).to.equal(100)
			local afterMoney = profiles[U1].Money

			local capped = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upmax01')
			expect(capped.success).to.equal(false)
			expect(capped.error).to.equal('max-level')
			expect(AnimalService.GetLevel('BR_upmax01')).to.equal(100)
			expect(profiles[U1].Money).to.equal(afterMoney)
		end)

		it('Test 43: insufficient money fails with everything intact', function()
			placeAnimal(U1, 'BR_uppoor01', { level = 2, pool = '7', xp = 9 })
			-- L2 Common cost is 112; hold one less.
			profiles[U1].Money = '111'

			local r = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_uppoor01')
			expect(r.success).to.equal(false)
			expect(profiles[U1].Money).to.equal('111')
			expect(AnimalService.GetLevel('BR_uppoor01')).to.equal(2)
			expect(AnimalService.GetXP('BR_uppoor01')).to.equal(9)
			local rec = profileRecord(U1, 'BR_uppoor01')
			expect(rec.CashPool).to.equal('7')
		end)

		it('Test 44: rapid double upgrade charges current-level costs, never skips', function()
			placeAnimal(U1, 'BR_updbl01', { level = 1 })
			-- Exactly L1->L2 (100) + L2->L3 (112).
			profiles[U1].Money = '212'
			local p = Helpers.FakePlayer(U1)

			local first = UpgradeService.UpgradeAnimal(p, 'BR_updbl01')
			expect(first.success).to.equal(true)
			expect(first.upgradeCost).to.equal('100')
			local second = UpgradeService.UpgradeAnimal(p, 'BR_updbl01')
			expect(second.success).to.equal(true)
			expect(second.upgradeCost).to.equal('112')
			expect(AnimalService.GetLevel('BR_updbl01')).to.equal(3)
			expect(profiles[U1].Money).to.equal('0')
			-- A third fires with nothing left: clean reject.
			local third = UpgradeService.UpgradeAnimal(p, 'BR_updbl01')
			expect(third.success).to.equal(false)
			expect(AnimalService.GetLevel('BR_updbl01')).to.equal(3)
		end)

		it('rejects lucky egg, wrong owner, stale, and invalid definition', function()
			eggs['LB_up001'] = {
				uniqueId = 'LB_up001',
				rarity = 'Epic',
				ownerUserId = U1,
				slotId = 'p7:7901:slot:9',
				state = 'Placed',
				model = nil,
				_mutex = false,
			}
			placeAnimal(U1, 'BR_upown01', { level = 1 })
			profiles[U1].Money = '5000'
			profiles[U2] = { Money = '5000', Multipliers = { Money = 1 }, Brainrots = {}, LuckyBlocks = {} }

			-- Egg is never upgradeable (would-be upgrade path).
			local egg = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'LB_up001')
			expect(egg.success).to.equal(false)

			-- Wrong owner.
			local foreign = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U2), 'BR_upown01')
			expect(foreign.success).to.equal(false)
			expect(foreign.error).to.equal('not-owner')

			-- Stale: slot now holds another occupant.
			for _, slot in ipairs(slots) do
				if slot.occupantId == 'BR_upown01' then
					slot.occupantId = 'BR_somebody_else'
				end
			end
			local stale = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upown01')
			expect(stale.success).to.equal(false)

			-- Invalid definition.
			AnimalService._TestRegister({
				uniqueId = 'BR_upbaddef',
				definitionId = 'DefinitelyNotReal',
				ownerUserId = U1,
				slotId = 'p7:1:slot:9',
				Level = 1,
				XP = 0,
				state = 'Slotted',
				model = nil,
			})
			runtimeIds[#runtimeIds + 1] = 'BR_upbaddef'
			local badDef = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upbaddef')
			expect(badDef.success).to.equal(false)

			expect(profiles[U1].Money).to.equal('5000')
			expect(AnimalService.GetLevel('BR_upown01')).to.equal(1)
		end)

		it('paid level survives AddXP: no Normalize undo, stats follow Level 6', function()
			placeAnimal(U1, 'BR_upxp001', { level = 5, xp = 40 })
			profiles[U1].Money = '100000'
			local before = AnimalStats.Calculate({ DefId = COMMON_DEF, Level = 5 }, 'Health')

			local up = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upxp001')
			expect(up.success).to.equal(true)
			-- XP grants route through the canonical flow and must
			-- neither regress the paid level nor misbehave.
			local xpResult = AnimalService:AddXP('BR_upxp001', 10)
			expect(xpResult.success).to.equal(true)
			expect(AnimalService.GetLevel('BR_upxp001')).to.equal(6)
			expect(AnimalService.GetXP('BR_upxp001')).to.equal(50)
			-- Stats derive from the NEW level through the
			-- existing calculator (no second formula).
			local after = AnimalStats.Calculate({ DefId = COMMON_DEF, Level = 6 }, 'Health')
			expect(after > before).to.equal(true)
			local snap = AnimalService.GetStats('BR_upxp001')
			expect(snap.Health).to.equal(after)
		end)

		it('income, sell value, and next cost all follow the upgraded level', function()
			placeAnimal(U1, 'BR_upfollow1', { level = 5, pool = '2000' })
			profiles[U1].Money = '100000'

			local incomeBefore = AnimalStats.Calculate({ DefId = COMMON_DEF, Level = 5 }, 'Income')
			local r = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upfollow1')
			expect(r.success).to.equal(true)
			local incomeAfter = AnimalStats.Calculate({ DefId = COMMON_DEF, Level = 6 }, 'Income')
			expect(incomeAfter > incomeBefore).to.equal(true)
			-- §50 example: 1000 x 6 + 2000 = 8000 (Rare ladder
			-- shape shown here on Common: 100 x 6 + 2000 = 2600).
			expect(SellService.GetAnimalTotalPayout(COMMON_DEF, 6, '2000')).to.equal('2450')
			-- Next cost derives from the NEW level (§37).
			expect(UpgradeService.GetUpgradeCost(COMMON_DEF, 6)).to.equal('176.23416832')
		end)

		it('multiplier live or legacy never shapes the cost', function()
			placeAnimal(U1, 'BR_upmult01', { level = 2 })
			profiles[U1].Multipliers = { Money = 10 }
			ModifierService.AddModifier(U1, 'Whale', ModifierService.ModifierType.MoneyMultiplier, 5)
			profiles[U1].Money = '10000'

			local r = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_upmult01')
			expect(r.success).to.equal(true)
			expect(r.upgradeCost).to.equal('112')
			expect(profiles[U1].Money).to.equal('9888')
		end)

		it('rejoin shape: record keeps Id/slot/XP/pool/Level; cost re-derives', function()
			placeAnimal(U1, 'BR_uprejoin', { level = 5, pool = '31337', xp = 11 })
			profiles[U1].Money = '100000'

			local r = UpgradeService.UpgradeAnimal(Helpers.FakePlayer(U1), 'BR_uprejoin')
			expect(r.success).to.equal(true)
			-- The persisted record is the whole story: no cost
			-- field, no second record, identity intact.
			local rec = profileRecord(U1, 'BR_uprejoin')
			expect(rec.Id).to.equal('BR_uprejoin')
			expect(rec.Level).to.equal(6)
			expect(rec.XP).to.equal(11)
			expect(rec.CashPool).to.equal('31337')
			expect(rec.UpgradeCost).to.equal(nil)
			-- After a hypothetical rejoin, the next cost derives
			-- from the persisted Level alone.
			expect(UpgradeService.GetUpgradeCost(rec.DefId, rec.Level)).to.equal('176.23416832')
		end)
	end)
end
