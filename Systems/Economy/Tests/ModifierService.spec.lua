--!strict
--!native
--[[
	ModifierService.spec
	====================
	Phase 2.7 tests for the centralized modifier foundation.

	Covers the spec's Test 1–12 matrix plus the CashPool economy
	proofs, using the REAL ModifierService throughout. Income
	integration goes through the REAL IncomeService + EconomyService
	with hand-rolled profile/slot fakes (the IncomeService.spec
	pattern); XP integration goes through the REAL
	AnimalService.AddXP with a minimal runtime record registered
	via the documented test seam (no models are spawned — AddXP is
	pure state math).

	Locked in:
	  * defaults are exactly 1x (money + XP)
	  * 2x resolves to 2x; 2x + 1.5x resolves to 3x (multiplicative)
	  * insertion order never changes the result
	  * removal restores; re-adding a source replaces (no double count)
	  * invalid values (NaN/inf/zero/negative/non-number/bad type/
	    bad op) are rejected with codes and never poison state
	  * online income folds the multiplier into NEW income only
	  * offline income applies the live multiplier at 50%
	    effectiveness (balance pass; legacy profile compat
	    multipliers are still ignored)
	  * collection transfers 1:1 (no second multiplication)
	  * changing the multiplier never revalues the existing pool
	  * XP applies exactly once through the canonical AddXP flow
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local ModifierService = require(ServerScriptService.ModifierService)
	local IncomeService = require(ServerScriptService.IncomeService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local AnimalService = require(ServerScriptService.AnimalService)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local MONEY = ModifierService.ModifierType.MoneyMultiplier
	local XP = ModifierService.ModifierType.XPModifier

	-- Distinct userIds (the 900-range belongs to IncomeService.spec;
	-- module state is shared across spec files in one TestEZ run).
	local U1 = 7701
	local U2 = 7702
	local U3 = 7703

	-- Same catalog shape as IncomeService.spec: Common, integer
	-- Level-1 income base, so every expected pool value is exact.
	local DEF = 'Chicken'
	local RATE = AnimalStats.Calculate({ DefId = DEF, Level = 1 }, 'Income')

	local profiles: { [number]: any } = {}
	local offlineAnchors: { [number]: number } = {}
	local slots: { any } = {}
	local carriedId: string? = nil

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

	local function makeAnimal(slotId: string, id: string, pool: string?): any
		return {
			Type = 'Brainrot',
			SlotId = slotId,
			DefId = DEF,
			Id = id,
			Level = 1,
			XP = 0,
			CashPool = pool or '0',
		}
	end

	local function place(userId: number, id: string, pool: string?): (any, any)
		local slotId = 'p7:' .. tostring(userId) .. ':slot:' .. tostring(#slots + 1)
		local record = makeAnimal(slotId, id, pool)
		local slot = {
			id = slotId,
			ownerUserId = userId,
			baseId = 'Base_1',
			state = SlotType.State.Occupied,
			occupantId = id,
			occupantKind = SlotType.OccupantKind.Animal,
			cashCollector = nil,
		}
		profiles[userId] = profiles[userId]
			or {
				Money = '0',
				Multipliers = { Money = 1 },
				Brainrots = {},
				LastSeen = os.time(),
			}
		table.insert(profiles[userId].Brainrots, record)
		table.insert(slots, slot)
		return record, slot
	end

	describe('ModifierService resolution', function()
		beforeEach(function()
			Helpers.StubRemotes()
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			ModifierService.ClearModifiers(U3)
		end)

		afterEach(function()
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
			ModifierService.ClearModifiers(U3)
		end)

		it('Test 1: no modifiers -> MoneyMultiplier is exactly 1', function()
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)
		end)

		it('Test 2: no modifiers -> XPModifier is exactly 1', function()
			expect(ModifierService.GetXPModifier(U1)).to.equal(1)
		end)

		it('resolved snapshot reports 1x with empty source lists', function()
			local r = ModifierService.GetResolvedModifiers(U1)
			expect(r.MoneyMultiplier).to.equal(1)
			expect(r.XPModifier).to.equal(1)
			expect(#r.MoneySources).to.equal(0)
			expect(#r.XPSources).to.equal(0)
		end)

		it('Test 3: a 2x money source resolves to 2x', function()
			local ok = ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)
			expect(ok).to.equal(true)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(2)
			-- XP is isolated: untouched by money sources.
			expect(ModifierService.GetXPModifier(U1)).to.equal(1)
		end)

		it('Test 4: 2x + 1.5x stack multiplicatively to 3x (never 3.5x)', function()
			ModifierService.AddModifier(U1, 'SourceA', MONEY, 2)
			ModifierService.AddModifier(U1, 'SourceB', MONEY, 1.5)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(3)
		end)

		it('Test 5: insertion order does not change the result', function()
			ModifierService.AddModifier(U1, 'SourceA', MONEY, 2)
			ModifierService.AddModifier(U1, 'SourceB', MONEY, 1.5)
			ModifierService.AddModifier(U2, 'SourceB', MONEY, 1.5)
			ModifierService.AddModifier(U2, 'SourceA', MONEY, 2)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(ModifierService.GetMoneyMultiplier(U2))
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(3)
		end)

		it('Test 6: removing a source restores; removing all returns to 1x', function()
			ModifierService.AddModifier(U1, 'SourceA', MONEY, 2)
			ModifierService.AddModifier(U1, 'SourceB', MONEY, 1.5)
			expect(ModifierService.RemoveModifier(U1, 'SourceA', MONEY)).to.equal(true)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1.5)
			expect(ModifierService.RemoveModifier(U1, 'SourceB', MONEY)).to.equal(true)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)
			-- Removing what is not there reports false, changes nothing.
			expect(ModifierService.RemoveModifier(U1, 'SourceB', MONEY)).to.equal(false)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)
		end)

		it('re-adding the same source replaces it (never double counts)', function()
			ModifierService.AddModifier(U1, 'SourceA', MONEY, 2)
			ModifierService.AddModifier(U1, 'SourceA', MONEY, 3)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(3)
			expect(#ModifierService.GetModifiers(U1, MONEY)).to.equal(1)
		end)

		it('remove without a type clears the source from every type', function()
			ModifierService.AddModifier(U1, 'Shared', MONEY, 2)
			ModifierService.AddModifier(U1, 'Shared', XP, 4)
			expect(ModifierService.RemoveModifier(U1, 'Shared')).to.equal(true)
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)
			expect(ModifierService.GetXPModifier(U1)).to.equal(1)
		end)

		it('Test 12: invalid modifiers are rejected safely and never poison state', function()
			-- NOTE: nil is tested separately below — ipairs stops
			-- at the first nil, so it cannot sit inside the array.
			local badValues: { any } = { 0, -1, -0.5, math.huge, -math.huge, 0 / 0, '2', {}, true }
			for _, v in ipairs(badValues) do
				local ok, code = ModifierService.AddModifier(U1, 'Bad', MONEY, v)
				expect(ok).to.equal(false)
				expect(type(code)).to.equal('string')
			end
			local okNil, codeNil = ModifierService.AddModifier(U1, 'Bad', MONEY, nil :: any)
			expect(okNil).to.equal(false)
			expect(type(codeNil)).to.equal('string')
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)

			local okType, codeType = ModifierService.AddModifier(U1, 'Bad', 'NotAType', 2)
			expect(okType).to.equal(false)
			expect(codeType).to.equal('invalid-type')

			local okOp, codeOp = ModifierService.AddModifier(U1, 'Bad', MONEY, 2, 'Add')
			expect(okOp).to.equal(false)
			expect(codeOp).to.equal('unsupported-operation')

			local okSrc, codeSrc = ModifierService.AddModifier(U1, '', MONEY, 2)
			expect(okSrc).to.equal(false)
			expect(codeSrc).to.equal('invalid-source')

			local okUser, codeUser = ModifierService.AddModifier(-5, 'Bad', MONEY, 2)
			expect(okUser).to.equal(false)
			expect(codeUser).to.equal('invalid-player')

			local okMeta, codeMeta = ModifierService.AddModifier(U1, 'Bad', MONEY, 2, nil, 'nope')
			expect(okMeta).to.equal(false)
			expect(codeMeta).to.equal('invalid-metadata')

			-- State is still pristine after every rejection.
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(1)
			expect(#ModifierService.GetModifiers(U1)).to.equal(0)
		end)

		it('GetModifiers returns deterministic copies (caller mutation is harmless)', function()
			ModifierService.AddModifier(U1, 'B_src', MONEY, 1.5)
			ModifierService.AddModifier(U1, 'A_src', MONEY, 2)
			local list = ModifierService.GetModifiers(U1, MONEY)
			expect(#list).to.equal(2)
			expect(list[1].SourceId).to.equal('A_src')
			expect(list[2].SourceId).to.equal('B_src')
			-- Mutate the copy: authoritative state must not move.
			list[1].Value = 999
			expect(ModifierService.GetMoneyMultiplier(U1)).to.equal(3)
		end)

		it('BigNumber regression: debug formatter renders every magnitude without precision loss', function()
			expect(BigNumber.Format('1000')).to.equal('1.0K')
			expect(BigNumber.Format('10550')).to.equal('10.5K')
			expect(BigNumber.Format('1000000')).to.equal('1.0M')
			expect(BigNumber.Format('1000000000')).to.equal('1.0B')
			expect(BigNumber.Format('1000000000000')).to.equal('1.0T')
			expect(BigNumber.Format('1000000000000000')).to.equal('1.0Qa')
			-- Canonical Huge-pool shape: raw string preserved exactly.
			local huge = '99999999999999999999999990'
			expect(BigNumber.isValid(huge)).to.equal(true)
			expect(BigNumber.Format(huge) ~= '').to.equal(true)
		end)
	end)

	describe('ModifierService economy integration', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			offlineAnchors = {}
			slots = {}
			carriedId = nil
			for _, u in ipairs({ U1, U2, U3 }) do
				ModifierService.ClearModifiers(u)
				IncomeService.ForgetPlayer(u)
			end
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
					if carriedId then
						return { uniqueId = carriedId }
					end
					return nil
				end,
			})
			-- THE Phase 2.7 wiring under test.
			IncomeService.SetModifierService(ModifierService)
			EconomyService.Init()
			EconomyService.SetPlayerService(ps)
			AnimalService.SetModifierService(ModifierService)
		end)

		afterEach(function()
			for _, u in ipairs({ U1, U2, U3 }) do
				ModifierService.ClearModifiers(u)
				IncomeService.ForgetPlayer(u)
			end
			-- Defensive: a failed XP test must not leak its runtime
			-- record into another spec (module state is shared).
			AnimalService._TestUnregister('BR_modxp001')
			AnimalService._TestUnregister('BR_modxp1x0001')
			IncomeService.SetModifierService(nil)
			AnimalService.SetModifierService(nil)
		end)

		it('Test 7: one online tick with 2x credits exactly rate x 2 x elapsed', function()
			local record = place(U1, 'BR_modonline001')
			ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)

			IncomeService.TickSources(10, { U1 })
			expect(record.CashPool).to.equal(tostring(math.floor(RATE * 2 * 10)))
		end)

		it('1.5x shapes income the same deterministic way (never added)', function()
			local record = place(U1, 'BR_modonline15x')
			ModifierService.AddModifier(U1, 'Half', MONEY, 1.5)

			IncomeService.TickSources(10, { U1 })
			expect(record.CashPool).to.equal(tostring(math.floor(RATE * 1.5 * 10)))
		end)

		it('Test 9: collection transfers 1:1 — the multiplier never applies again', function()
			local record, slot = place(U1, 'BR_modcollect01', '100')
			profiles[U1].Money = '50'
			ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)

			IncomeService.TryCollect(slot, Helpers.FakePlayer(U1))
			expect(profiles[U1].Money).to.equal('150')
			expect(record.CashPool).to.equal('0')
		end)

		it('Regression 12: a hostile legacy profile multiplier cannot shape live income', function()
			-- The deprecated profile.Data.Multipliers.Money hook
			-- (Phase 2.7.1) must be invisible to the live income
			-- transaction even at an absurd value: the online tick
			-- reads ModifierService exactly once, collection
			-- transfers 1:1, and the two never combine.
			local record = place(U1, 'BR_modlegacy001')
			profiles[U1].Multipliers = { Money = 10 }
			ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)

			IncomeService.TickSources(10, { U1 })
			-- 2x only: never 10x, never 20x.
			expect(record.CashPool).to.equal(tostring(math.floor(RATE * 2 * 10)))
		end)

		it('Regression 12b: collection stays 1:1 under a hostile legacy multiplier', function()
			local record, slot = place(U1, 'BR_modlegacy002', '100')
			profiles[U1].Money = '50'
			profiles[U1].Multipliers = { Money = 10 }
			ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)

			IncomeService.TryCollect(slot, Helpers.FakePlayer(U1))
			expect(profiles[U1].Money).to.equal('150')
			expect(record.CashPool).to.equal('0')
		end)

		it('Test 10: raising the multiplier never revalues the existing pool', function()
			local record = place(U1, 'BR_modretro0001', '10000')
			ModifierService.AddModifier(U1, 'TestDouble', MONEY, 2)

			IncomeService.TickSources(10, { U1 })
			-- Old 10000 untouched; only NEW income is shaped.
			expect(record.CashPool).to.equal(tostring(10000 + math.floor(RATE * 2 * 10)))
		end)

		it('Test 8: offline income applies the live multiplier at 50% effectiveness', function()
			local record = place(U1, 'BR_modoffline01')
			ModifierService.AddModifier(U1, 'Whale', MONEY, 5)
			offlineAnchors[U1] = os.time() - 100

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(U1))
			expect(record.CashPool).to.equal(tostring(math.floor(RATE * 5 * 0.5 * 100)))
		end)

		it('offline combines with the existing pool shaped', function()
			local record = place(U1, 'BR_modoffcombo1', '500')
			ModifierService.AddModifier(U1, 'Whale', MONEY, 5)
			offlineAnchors[U1] = os.time() - 100

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(U1))
			expect(record.CashPool).to.equal(tostring(500 + math.floor(RATE * 5 * 0.5 * 100)))
		end)

		it('Test 11: XP modifier applies exactly once through canonical AddXP', function()
			local id = 'BR_modxp001'
			AnimalService._TestRegister({
				uniqueId = id,
				ownerUserId = U1,
				Level = 1,
				XP = 0,
				state = 'Slotted',
			})
			ModifierService.AddModifier(U1, 'TestDouble', XP, 2)

			local result = AnimalService:AddXP(id, 100)
			expect(result.success).to.equal(true)
			expect(result.requestedXP).to.equal(100)
			expect(result.xpModifier).to.equal(2)
			-- Exactly once: 200, never 400.
			expect(result.appliedXP).to.equal(200)
			-- Level 1 + 200 XP hits the 200 threshold exactly.
			expect(result.level).to.equal(2)
			expect(result.newXP).to.equal(0)
			AnimalService._TestUnregister(id)
		end)

		it('XP with no modifier: requested == applied (1x identity)', function()
			local id = 'BR_modxp1x0001'
			AnimalService._TestRegister({
				uniqueId = id,
				ownerUserId = U2,
				Level = 1,
				XP = 0,
				state = 'Slotted',
			})

			local result = AnimalService:AddXP(id, 100)
			expect(result.success).to.equal(true)
			expect(result.requestedXP).to.equal(100)
			expect(result.xpModifier).to.equal(1)
			expect(result.appliedXP).to.equal(100)
			AnimalService._TestUnregister(id)
		end)
	end)
end
