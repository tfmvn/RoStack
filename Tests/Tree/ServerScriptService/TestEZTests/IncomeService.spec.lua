--!strict
--!native
--[[
	IncomeService.spec
	==================
	Phase 2.6 tests for the central income system. Real
	ProfileService profiles cannot load in a test session
	(GameConfig is frozen; ProfileService needs DataStore
	access), so — the same pattern as EconomyService.spec —
	every service ref is a hand-rolled fake and the shared
	profile tables stand in for profile.Data.

	Real modules in the loop: IncomeService, EconomyService,
	AnimalStats (via the real AnimalConfig chain). The
	Touch path (Touched wiring, _playerFromHit) is
	Studio-only and NOT exercised here — TryCollect is
	tested directly as the touch handler's endpoint.

	Locked in (spec §48-§56):
	  * accumulate: rate x elapsed lands in the record's
	    CashPool; fractional income is retained across ticks
	  * ineligible sources never change (carried, no slot,
	    wrong owner, wrong kind, empty slot, Eggs)
	  * collect: $pool -> Money, pool zeroed; empty pool is a
	    silent no-op; a repeat pays nothing; wrong owner pays
	    nothing; AddMoney failure preserves the pool
	  * the multiplier NEVER applies at collection (transfer,
	    not grant) and NEVER on the offline path
	  * offline: 1h -> rate x 3600; 5h/8h/24h cap at
	    rate x MaxOfflineSeconds; offline + existing pool
	    combines; the anchor is consumed exactly once; no
	    Money/XP side effects
	  * settlement: removal transfers the pool to Money and
	    zeroes it; a zero pool makes no transaction; failure
	    preserves the value

	Phase 2.6.2 adds the MoneyLabel binding egg: the
	EXISTING CashCollector.CollectorGui.MoneyLabel mirrors
	the authoritative pool at the same publish boundary that
	writes the CashPool attribute. Real instances stand in
	for the GUI chain (TestEZ runs inside Studio) and the
	real SlotService drives the place/pickup/release
	transition hook — display only; the GUI never mutates
	the pool.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local IncomeService = require(ServerScriptService.IncomeService)
	local EconomyService = require(ServerScriptService.EconomyService)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local SlotType = require(ReplicatedStorage.Types.SlotType)
	local SlotService = require(ServerScriptService.Base.SlotService)

	local USER_A = 900
	local USER_B = 901

	-- A real catalog definition: Common, whose Level-1 income
	-- Base is an exact integer (2/s), making every expected pool
	-- value below exact.
	local DEF = 'Chicken'
	local RATE_L1 = AnimalStats.Calculate({ DefId = DEF, Level = 1 }, 'Income')

	local profiles: { [number]: any } = {}
	local offlineAnchors: { [number]: number } = {}
	local slots: { any } = {}
	local carriedId: string? = nil
	local deployedIds: { [string]: boolean } = {}

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

	local function fakeAnimalService()
		return {
			GetCarriedAnimalByUserId = function(_userId: number)
				if carriedId then
					return { uniqueId = carriedId }
				end
				return nil
			end,
			IsArenaDeployed = function(id: string)
				return deployedIds[id] == true
			end,
		}
	end

	local function makeAnimal(slotId: string, id: string, level: number?, pool: string?): any
		return {
			Type = 'Brainrot',
			SlotId = slotId,
			DefId = DEF,
			Id = id,
			Level = level or 1,
			XP = 0,
			CashPool = pool or '0',
		}
	end

	local function makeOccupiedSlot(slotId: string, userId: number, occupantId: string): any
		return {
			id = slotId,
			ownerUserId = userId,
			baseId = 'Base_1',
			state = SlotType.State.Occupied,
			occupantId = occupantId,
			occupantKind = SlotType.OccupantKind.Animal,
			cashCollector = nil, -- attribute publishing is Studio-only; no-op here
		}
	end

	local function place(userId: number, id: string, pool: string?): (any, any)
		local slotId = 'p7:' .. tostring(userId) .. ':slot:' .. tostring(#slots + 1)
		local record = makeAnimal(slotId, id, nil, pool)
		local slot = makeOccupiedSlot(slotId, userId, id)
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

	describe('IncomeService', function()
		beforeEach(function()
			Helpers.StubRemotes()
			profiles = {}
			offlineAnchors = {}
			slots = {}
			carriedId = nil
			deployedIds = {}
			-- Reset per-session income state (debounce + fractional
			-- remainders) so tests are order-independent even when
			-- they reuse a userId.
			IncomeService.ForgetPlayer(USER_A)
			IncomeService.ForgetPlayer(USER_B)
			local ps = fakePlayerService()
			IncomeService.Init()
			IncomeService.SetPlayerService(ps)
			IncomeService.SetEconomyService(EconomyService)
			IncomeService.SetSlotService(fakeSlotService())
			IncomeService.SetBaseService({
				GetAllBases = function()
					return {}
				end,
			})
			IncomeService.SetAnimalService(fakeAnimalService())
			EconomyService.Init()
			EconomyService.SetPlayerService(ps)
		end)

		-- --- Accumulation (online) -------------------------------------

		it('a placed animal accumulates rate x elapsed into its CashPool', function()
			local record = place(USER_A, 'BR_incomeacc001')
			expect(record.CashPool).to.equal('0')

			IncomeService.TickSources(RATE_L1 * 5, { USER_A }) -- the $10/s x 5s = $50 shape
			expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 5)))
		end)

		it('an existing pool combines with newly earned cash ($100 + $50 -> $150 shape)', function()
			local record = place(USER_A, 'BR_incomecomb01', '100')

			IncomeService.TickSources(RATE_L1 * 25, { USER_A })
			expect(record.CashPool).to.equal(tostring(100 + math.floor(RATE_L1 * 25)))
		end)

		it('an arena-deployed animal earns nothing while its pool is preserved', function()
			local record = place(USER_A, 'BR_incomearena01', '50000')
			deployedIds['BR_incomearena01'] = true
			IncomeService.TickSources(RATE_L1 * 100, { USER_A })
			expect(record.CashPool).to.equal('50000')
			-- Restored: the exact control delta lands on top.
			deployedIds['BR_incomearena01'] = nil
			IncomeService.TickSources(RATE_L1 * 5, { USER_A })
			expect(record.CashPool).to.equal(tostring(50000 + math.floor(RATE_L1 * 5)))
		end)

		it('fractional income is retained across ticks — no floor loss', function()
			local record = place(USER_A, 'BR_incomefrac01')

			-- 0.75s at the Level-1 rate leaves a .5 remainder after
			-- flooring (RATE_L1 is integral): whole = floor(rate*0.75).
			IncomeService.TickSources(0.75, { USER_A })
			local afterFirst = tonumber(record.CashPool) or 0
			expect(afterFirst).to.equal(math.floor(RATE_L1 * 0.75))

			-- A follow-up 0.25s completes the fractional dollar.
			IncomeService.TickSources(0.25, { USER_A })
			local afterSecond = tonumber(record.CashPool) or 0
			-- Whole dollars credited total: floor(rate*0.75) + 1 —
			-- the .5 remainder was not lost to the first floor.
			expect(afterSecond).to.equal(math.floor(RATE_L1 * 0.75) + 1)
		end)

		it('a record with NO CashPool field earns from zero (never errors)', function()
			local record = place(USER_A, 'BR_incomenofield')
			record.CashPool = nil -- simulate a pre-2.6 row post-audit edge

			IncomeService.TickSources(RATE_L1 * 3, { USER_A })
			expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 3)))
		end)

		it('a carried animal earns nothing (pool preserved, resumes on place)', function()
			local record = place(USER_A, 'BR_incomecarry01')
			carriedId = record.Id

			IncomeService.TickSources(RATE_L1 * 10, { USER_A })
			expect(record.CashPool).to.equal('0')

			-- Set down: the SAME record resumes earning.
			carriedId = nil
			IncomeService.TickSources(RATE_L1 * 10, { USER_A })
			expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 10)))
		end)

		it('an animal with no slot, a wrong-owner slot, or an ineligible slot state never earns', function()
			local noSlot = makeAnimal('p7:9:slot:1', 'BR_incomenoslot1')
			profiles[USER_A] = {
				Money = '0',
				Multipliers = { Money = 1 },
				Brainrots = { noSlot },
				LastSeen = os.time(),
			}

			local wrongOwner = place(USER_A, 'BR_incomewrongown')
			for _, slot in ipairs(slots) do
				if slot.occupantId == 'BR_incomewrongown' then
					slot.ownerUserId = 42
				end
			end

			local luckyKind = place(USER_A, 'BR_incomeluckyk1')
			for _, slot in ipairs(slots) do
				if slot.occupantId == 'BR_incomeluckyk1' then
					slot.occupantKind = SlotType.OccupantKind.Egg
				end
			end

			local emptyState = place(USER_A, 'BR_incomeemptyst')
			for _, slot in ipairs(slots) do
				if slot.occupantId == 'BR_incomeemptyst' then
					slot.state = SlotType.State.Empty
				end
			end

			IncomeService.TickSources(RATE_L1 * 10, { USER_A })
			expect(noSlot.CashPool).to.equal('0')
			expect(wrongOwner.CashPool).to.equal('0')
			expect(luckyKind.CashPool).to.equal('0')
			expect(emptyState.CashPool).to.equal('0')
		end)

		it("another player's sources are untouched by one player's tick", function()
			local recA = place(USER_A, 'BR_incomeisoA01')
			local recB = place(USER_B, 'BR_incomeisoB01')

			IncomeService.TickSources(RATE_L1 * 5, { USER_A })
			expect(recA.CashPool).to.equal(tostring(math.floor(RATE_L1 * 5)))
			expect(recB.CashPool).to.equal('0')
		end)

		-- --- Collection -------------------------------------------------

		it('collecting a $100 pool adds exactly $100 to Money and zeroes the pool', function()
			local record, slot = place(USER_A, 'BR_collectpool01', '100')
			profiles[USER_A].Money = '50'

			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('150')
			expect(record.CashPool).to.equal('0')
		end)

		it('an empty pool touch is a silent no-op (no transaction)', function()
			local record, slot = place(USER_A, 'BR_collectempty1', '0')
			profiles[USER_A].Money = '50'

			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('50')
			expect(record.CashPool).to.equal('0')
		end)

		it('a repeated collection pays nothing extra (one pool, one collect)', function()
			local record, slot = place(USER_A, 'BR_collecttwice1', '100')
			local player = Helpers.FakePlayer(USER_A)

			IncomeService.TryCollect(slot, player)
			IncomeService.TryCollect(slot, player)
			expect(profiles[USER_A].Money).to.equal('100')
			expect(record.CashPool).to.equal('0')
		end)

		it('a touch from a NON-OWNER transfers nothing (ownership boundary)', function()
			local recordA, slotA = place(USER_A, 'BR_collectowner01', '100')
			place(USER_B, 'BR_collectownerB1', '0')

			IncomeService.TryCollect(slotA, Helpers.FakePlayer(USER_B))
			expect(profiles[USER_B].Money).to.equal('0')
			expect(recordA.CashPool).to.equal('100')
			expect(profiles[USER_A].Money).to.equal('0')
		end)

		it('collection is a TRANSFER — the Money multiplier never applies at collection', function()
			local record, slot = place(USER_A, 'BR_collectmult001', '100')
			profiles[USER_A].Money = '0'
			profiles[USER_A].Multipliers = { Money = 5 } -- hostile multiplier

			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			-- Exactly the pool moved: $100, not $500.
			expect(profiles[USER_A].Money).to.equal('100')
			expect(record.CashPool).to.equal('0')
		end)

		it('an AddMoney failure preserves the pool (atomic: zero only on success)', function()
			local record, slot = place(USER_A, 'BR_collectfail001', '100')
			IncomeService.SetEconomyService({
				AddMoney = function(_userId: number, _amount: string, _reason: string, _opts: any)
					return { Success = false, Code = 'insufficient' }
				end,
			})

			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal('100')
		end)

		-- --- Offline earnings -------------------------------------------

		it('1h offline credits rate x 3600 into the CashPool', function()
			local record, _slot = place(USER_A, 'BR_offline1h0001')
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 1800)))
		end)

		it('5h, 8h and 24h offline all cap at rate x 50% x MaxOfflineSeconds (3h)', function()
			for i, hours in ipairs({ 5, 8, 24 }) do
				local userId = 910 + i
				local record = makeAnimal('p7:' .. tostring(userId) .. ':slot:1', 'BR_offlinecap' .. tostring(hours))
				profiles[userId] = {
					Money = '0',
					Multipliers = { Money = 1 },
					Brainrots = { record },
					LastSeen = os.time(),
				}
				slots = { makeOccupiedSlot(record.SlotId, userId, record.Id) }
				offlineAnchors[userId] = os.time() - hours * 3600

				IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(userId))
				expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 5400)))
				expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 5400)))
			end
		end)

		it('offline earnings combine with an existing pool ($500 + offline -> sum)', function()
			local record = makeAnimal('p7:920:slot:1', 'BR_offlinecombine')
			record.CashPool = '500'
			profiles[920] = {
				Money = '0',
				Multipliers = { Money = 1 },
				Brainrots = { record },
				LastSeen = os.time(),
			}
			slots = { makeOccupiedSlot(record.SlotId, 920, record.Id) }
			offlineAnchors[920] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(920))
			expect(record.CashPool).to.equal(tostring(500 + math.floor(RATE_L1 * 1800)))
		end)

		it('a missing/unusable anchor pays nothing (fresh profile, DebugSkipPersistence)', function()
			local record = place(USER_A, 'BR_offlineanchor1')
			-- No offlineAnchors entry: ConsumeOfflineTimestamp -> 0.

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal('0')
		end)

		it('the offline window is consumed exactly once — no double payout', function()
			local record = place(USER_A, 'BR_offlineonce001')
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			local first = record.CashPool
			expect(first).to.equal(tostring(math.floor(RATE_L1 * 1800)))

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal(first)
		end)

		it('offline earnings never touch Money, Level or XP (pool-only, no XP)', function()
			local record = place(USER_A, 'BR_offlinepure0001')
			record.Level = 3
			record.XP = 7
			profiles[USER_A].Money = '50'
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('50')
			expect(record.Level).to.equal(3)
			expect(record.XP).to.equal(7)
		end)

		it('the legacy profile multiplier NEVER applies offline; live wallet mult applies at 50% (balance pass)', function()
			local record = place(USER_A, 'BR_offlinemult001')
			profiles[USER_A].Multipliers = { Money = 5 } -- hostile legacy multiplier, still ignored
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal(tostring(math.floor(RATE_L1 * 1800)))
		end)

		it('offline earns nothing for a carried animal (same eligibility chain)', function()
			local record = place(USER_A, 'BR_offlinecarried')
			carriedId = record.Id
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(record.CashPool).to.equal('0')
		end)

		-- --- Settlement (removal path) -----------------------------------

		it('SettleAnimalPool transfers the pool to Money and zeroes the record', function()
			local record = place(USER_A, 'BR_settlepool0001', '75')
			profiles[USER_A].Money = '50'

			IncomeService.SettleAnimalPool(USER_A, record)
			expect(profiles[USER_A].Money).to.equal('125')
			expect(record.CashPool).to.equal('0')
		end)

		it('a zero-pool settlement makes no transaction', function()
			local record = place(USER_A, 'BR_settlepoolzero')
			profiles[USER_A].Money = '50'

			IncomeService.SettleAnimalPool(USER_A, record)
			expect(profiles[USER_A].Money).to.equal('50')
		end)

		it('a settlement failure preserves the pool value (never a silent delete)', function()
			local record = place(USER_A, 'BR_settlepoolfail', '75')
			IncomeService.SetEconomyService({
				AddMoney = function(_userId: number, _amount: string, _reason: string, _opts: any)
					return { Success = false, Code = 'cap-exceeded' }
				end,
			})

			IncomeService.SettleAnimalPool(USER_A, record)
			expect(record.CashPool).to.equal('75')
		end)

		it('an Egg record is never settled (eggs carry no pool)', function()
			local lbRecord = { Type = 'LuckyBlock', Id = 'LB_settlepool001', CashPool = '999' }
			profiles[USER_A].Money = '50'

			IncomeService.SettleAnimalPool(USER_A, lbRecord)
			expect(profiles[USER_A].Money).to.equal('50')
			expect(lbRecord.CashPool).to.equal('999')
		end)

		it('BigNumber integrity: pools stay integer strings through every path', function()
			local record = place(USER_A, 'BR_bignumber0001', '99999999999999999999999990')
			offlineAnchors[USER_A] = os.time() - 3600

			IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
			expect(BigNumber.isValid(record.CashPool)).to.equal(true)
			expect(record.CashPool).to.equal(
				BigNumber.Add('99999999999999999999999990', tostring(math.floor(RATE_L1 * 3600)))
			)

			local _, slot
			for _, s in ipairs(slots) do
				if s.occupantId == 'BR_bignumber0001' then
					slot = s
				end
			end
			local poolBefore = record.CashPool
			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			-- Money started at '0'; the whole pool transferred 1:1.
			expect(profiles[USER_A].Money).to.equal(poolBefore)
			expect(BigNumber.isValid(profiles[USER_A].Money)).to.equal(true)
			expect(record.CashPool).to.equal('0')
		end)
		-- --- Phase 2.6.1 regression: the incident replayed end to end --

		it('spec section 23: the exact Studio incident replays correctly through the real service chain', function()
			-- Studio observed (pre-fix): Money 650000, collect pool
			-- 10550 -> Money 6605500; then each later +5 collect
			-- produced 66055050 / 660550550 / 6605505550 ... until
			-- cap-exceeded. The collector was honest every time —
			-- BigNumber.Add multiplied each grant by 10. This test
			-- walks the identical sequence through the REAL
			-- TryCollect -> EconomyService.AddMoney -> BigNumber.Add
			-- chain and demands the correct values.
			local record, slot = place(USER_A, 'BR_incidentreplay', '10550')
			profiles[USER_A].Money = '650000'

			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('660550')
			expect(record.CashPool).to.equal('0')

			-- An immediate repeat touch pays nothing: the pool is
			-- already zero (the pre-fix +10 came from arithmetic,
			-- never from a double collection).
			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('660550')

			-- The next income tick credits +5 (2.5s at the Level-1
			-- rate of 2/s) into the pool...
			IncomeService.TickSources(5 / RATE_L1, { USER_A })
			expect(record.CashPool).to.equal('5')

			-- ...and the next collect adds exactly 5, not 50.
			IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
			expect(profiles[USER_A].Money).to.equal('660555')
			expect(record.CashPool).to.equal('0')
		end)

		it('spec section 28: repeated collect / earn / collect cycles never drift', function()
			-- Five cycles of: pool earns 5, collect. Each transfer
			-- must move exactly 5 — no x10, no drift, no residue.
			local record, slot = place(USER_A, 'BR_incidentcycles', '0')
			profiles[USER_A].Money = '0'

			for i = 1, 5 do
				IncomeService.TickSources(5 / RATE_L1, { USER_A })
				expect(record.CashPool).to.equal('5')
				IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
				expect(profiles[USER_A].Money).to.equal(tostring(5 * i))
				expect(record.CashPool).to.equal('0')
			end
		end)

		-- --- Phase 2.6.2: MoneyLabel binding (display only) -------------
		-- The collector's EXISTING CashCollector.CollectorGui.MoneyLabel
		-- mirrors the authoritative pool. These tests use REAL instances
		-- (TestEZ runs inside Studio) for the label chain, and the REAL
		-- SlotService for the transition-hook test, exercising the same
		-- publish boundary production uses.

		describe('MoneyLabel binding (Phase 2.6.2)', function()
			local registeredBaseIds: { string } = {}

			-- Build the exact production hierarchy on a fresh part:
			-- CashCollector -> CollectorGui -> MoneyLabel.
			local function makeCollectorPart(): BasePart
				local part = Instance.new('Part')
				local gui = Instance.new('SurfaceGui')
				gui.Name = 'CollectorGui'
				local label = Instance.new('TextLabel')
				label.Name = 'MoneyLabel'
				label.Text = 'UNSET'
				label.Parent = gui
				gui.Parent = part
				return part
			end

			afterEach(function()
				-- Never leak the display hook or registered bases into
				-- other specs (module state is shared across files).
				for _, baseId in ipairs(registeredBaseIds) do
					SlotService.UnregisterBase(baseId)
				end
				registeredBaseIds = {}
				SlotService.SetPoolDisplayCallback(nil)
			end)

			it('Test A: an empty pool displays "$0" and publishes the attribute', function()
				local _record, slot = place(USER_A, 'BR_labelA_empty01', '0')
				slot.cashCollector = makeCollectorPart()

				IncomeService.RepublishSlot(slot)
				expect(slot.cashCollector:GetAttribute('CashPool')).to.equal('0')
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')
			end)

			it('Test B: income accumulation reaches the label', function()
				local record, slot = place(USER_A, 'BR_labelB_income1', '0')
				slot.cashCollector = makeCollectorPart()

				IncomeService.TickSources(5 / RATE_L1, { USER_A })
				expect(record.CashPool).to.equal('5')
				-- In Studio the throttled sweep publishes within one
				-- window; the test drives the same publish boundary
				-- directly (value derivation is what is under test).
				IncomeService.RepublishSlot(slot)
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$5')
			end)

			it('Test C: a large pool renders compactly ($10.5K)', function()
				local _record, slot = place(USER_A, 'BR_labelC_large01', '10550')
				slot.cashCollector = makeCollectorPart()

				IncomeService.RepublishSlot(slot)
				expect(slot.cashCollector:GetAttribute('CashPool')).to.equal('10550')
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$10.5K')
			end)

			it('Test D: collection zeroes the label immediately (no sweep, no tick)', function()
				local _record, slot = place(USER_A, 'BR_labelD_collect', '10550')
				slot.cashCollector = makeCollectorPart()
				profiles[USER_A].Money = '650000'

				IncomeService.RepublishSlot(slot)
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$10.5K')

				IncomeService.TryCollect(slot, Helpers.FakePlayer(USER_A))
				expect(profiles[USER_A].Money).to.equal('660550')
				-- TryCollect publishes '0' itself: the label must never
				-- keep showing the old value after a successful collect.
				expect(slot.cashCollector:GetAttribute('CashPool')).to.equal('0')
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')
			end)

			it('Test E: multiple slots display independent values (no shared pool)', function()
				local rec1, slot1 = place(USER_A, 'BR_labelE_slot001', '10')
				local _rec2, slot2 = place(USER_A, 'BR_labelE_slot002', '500')
				local _rec3, slot3 = place(USER_A, 'BR_labelE_slot003', '25000')
				local _rec4, slot4 = place(USER_A, 'BR_labelE_slot004', '0')
				local _rec5, slot5 = place(USER_A, 'BR_labelE_slot005', '1000000')
				local _rec6, slot6 = place(USER_A, 'BR_labelE_slot006', '50')
				for _, slot in ipairs({ slot1, slot2, slot3, slot4, slot5, slot6 }) do
					slot.cashCollector = makeCollectorPart()
				end

				for _, slot in ipairs({ slot1, slot2, slot3, slot4, slot5, slot6 }) do
					IncomeService.RepublishSlot(slot)
				end

				expect(slot1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$10')
				expect(slot2.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$500')
				expect(slot3.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$25.0K')
				expect(slot4.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')
				expect(slot5.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$1.0M')
				expect(slot6.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$50')

				-- Changing one slot's pool never touches another label.
				rec1.CashPool = '999999'
				IncomeService.RepublishSlot(slot1)
				expect(slot1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$999.9K')
				expect(slot2.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$500')
			end)

			it('Test G: offline earnings land in the label via the direct publish', function()
				local _record, slot = place(USER_A, 'BR_labelG_offlin1', '0')
				slot.cashCollector = makeCollectorPart()
				offlineAnchors[USER_A] = os.time() - 3600

				IncomeService.ApplyOfflineEarnings(Helpers.FakePlayer(USER_A))
				-- ApplyOfflineEarnings force-publishes its slots before
				-- the loaded state is pushed: no sweep, no multiplier.
				local pool = tostring(math.floor(RATE_L1 * 1800))
				expect(slot.cashCollector:GetAttribute('CashPool')).to.equal(pool)
				expect(slot.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$' .. BigNumber.Format(pool))
			end)

			it('a missing/mistyped GUI chain fails safely (attribute still publishes)', function()
				-- Bare part: no CollectorGui at all.
				local barePart = Instance.new('Part')
				local _r1, slot1 = place(USER_A, 'BR_labelSaf_bare01', '777')
				slot1.cashCollector = barePart
				IncomeService.RepublishSlot(slot1) -- must not error
				expect(barePart:GetAttribute('CashPool')).to.equal('777')

				-- CollectorGui present, MoneyLabel missing.
				local guiOnlyPart = Instance.new('Part')
				local guiOnly = Instance.new('SurfaceGui')
				guiOnly.Name = 'CollectorGui'
				guiOnly.Parent = guiOnlyPart
				local _r2, slot2 = place(USER_A, 'BR_labelSaf_gui001', '777')
				slot2.cashCollector = guiOnlyPart
				IncomeService.RepublishSlot(slot2) -- must not error
				expect(guiOnlyPart:GetAttribute('CashPool')).to.equal('777')

				-- MoneyLabel present but not a TextLabel.
				local wrongPart = Instance.new('Part')
				local wrongGui = Instance.new('SurfaceGui')
				wrongGui.Name = 'CollectorGui'
				local notALabel = Instance.new('Folder')
				notALabel.Name = 'MoneyLabel'
				notALabel.Parent = wrongGui
				wrongGui.Parent = wrongPart
				local _r3, slot3 = place(USER_A, 'BR_labelSaf_wrong', '777')
				slot3.cashCollector = wrongPart
				IncomeService.RepublishSlot(slot3) -- must not error
				expect(wrongPart:GetAttribute('CashPool')).to.equal('777')
			end)

			it('Test H: rearrangement follows the pool — no duplication, loss or stale label', function()
				-- REAL SlotService + the exact bootstrap wiring shape:
				-- slot transitions call IncomeService.RepublishSlot.
				SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)

				local record = makeAnimal('p7:' .. tostring(USER_A) .. ':slot:101', 'BR_labelH_brain01', nil, '10550')
				profiles[USER_A] = {
					Money = '0',
					Multipliers = { Money = 1 },
					Brainrots = { record },
					LastSeen = os.time(),
				}
				local s1 = makeOccupiedSlot('p7:' .. tostring(USER_A) .. ':slot:101', USER_A, record.Id)
				local s2 = makeOccupiedSlot('p7:' .. tostring(USER_A) .. ':slot:102', USER_A, 'BR_labelH_unused')
				-- At boot every slot is Empty with a live collector.
				for _, s in ipairs({ s1, s2 }) do
					s.state = SlotType.State.Empty
					s.occupantId = nil
					s.occupantKind = nil
					s.cashCollector = makeCollectorPart()
				end
				SlotService.RegisterBase({ id = 'Base_labelH', slots = { s1, s2 } })
				registeredBaseIds[#registeredBaseIds + 1] = 'Base_labelH'

				-- Restore/rejoin path: the animal is placed into s1;
				-- the hook republishes the restored pool immediately.
				expect(SlotService.ReserveSlot(s1.id)).to.equal(true)
				expect(SlotService.OccupySlot(s1.id, record.Id, SlotType.OccupantKind.Animal)).to.equal(true)
				expect(s1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$10.5K')

				-- Rearrangement: pick up (Demote keeps the pool on the
				-- record; the vacated slot shows $0), place into s2.
				expect(SlotService.DemoteSlotToReserved(s1.id)).to.equal(true)
				expect(s1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')
				expect(SlotService.ReserveSlot(s2.id)).to.equal(true)
				expect(SlotService.OccupySlot(s2.id, record.Id, SlotType.OccupantKind.Animal)).to.equal(true)
				expect(s2.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$10.5K')
				expect(s1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')

				-- The pool itself moved with the record: not duplicated,
				-- not lost, not reset by the GUI.
				expect(record.CashPool).to.equal('10550')
			end)

			it('ReleaseSlot (removal path) zeroes the label through the hook', function()
				SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)

				local record = makeAnimal('p7:' .. tostring(USER_A) .. ':slot:103', 'BR_labelH_release', nil, '500')
				profiles[USER_A] = {
					Money = '0',
					Multipliers = { Money = 1 },
					Brainrots = { record },
					LastSeen = os.time(),
				}
				local s1 = makeOccupiedSlot('p7:' .. tostring(USER_A) .. ':slot:103', USER_A, record.Id)
				s1.state = SlotType.State.Empty
				s1.occupantId = nil
				s1.occupantKind = nil
				s1.cashCollector = makeCollectorPart()
				SlotService.RegisterBase({ id = 'Base_labelRelease', slots = { s1 } })
				registeredBaseIds[#registeredBaseIds + 1] = 'Base_labelRelease'

				expect(SlotService.ReserveSlot(s1.id)).to.equal(true)
				expect(SlotService.OccupySlot(s1.id, record.Id, SlotType.OccupantKind.Animal)).to.equal(true)
				expect(s1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$500')

				-- The removal path releases the slot; the label goes $0.
				expect(SlotService.ReleaseSlot(s1.id)).to.equal(true)
				expect(s1.cashCollector.CollectorGui.MoneyLabel.Text).to.equal('$0')
				expect(s1.cashCollector:GetAttribute('CashPool')).to.equal('0')
			end)
		end)
	end)
end
