--!strict
--!native
--[[
	EconomyService.spec
	===================
	Phase 2.1: tests the single authoritative money
	mutator. We bypass ProfileService (no real persistence
	here) and inject a fake `playerService` whose
	`GetPlayerData` returns a hand-rolled profile table.
	That's enough to exercise every code path in
	AddMoney / TrySpendMoney / GetMoney / CanAfford
	without standing up a DataStore.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(script.Parent._Helpers)
	local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
	local TransactionReason = require(ReplicatedStorage.Types.TransactionReason)
	local EconomyService = require(ServerScriptService.EconomyService)
	local Money = require(ReplicatedStorage.Config.Economy.Money)

	-- Build a fake `playerService` whose GetPlayerData
	-- returns a profile keyed by userId. The table contains
	-- every field EconomyService reads or writes.
	local function fakePlayerService(initial: { [number]: any })
		return {
			GetPlayerData = function(userId: number)
				return initial[userId]
			end,
		}
	end

	describe('EconomyService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('GetMoney returns "0" for unknown user', function()
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({}))
			expect(svc.GetMoney(12345)).to.equal('0')
		end)

		it('AddMoney updates the profile', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [99] = profile }))
			local r = svc.AddMoney(99, '1000', TransactionReason.AdminGive)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal('1000')
			expect(profile.Money).to.equal('1000')
		end)

		it('AddMoney accepts arbitrary-precision amounts', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [100] = profile }))
			local r = svc.AddMoney(100, '999999999999999', TransactionReason.AdminGive)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal('999999999999999')
		end)

		it('AddMoney clamps at MaxMoney', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [101] = profile }))
			local r = svc.AddMoney(101, tostring(Money.MaxMoney), TransactionReason.AdminGive)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal(Money.MaxMoney)
			-- Try to push past the cap; should clamp.
			local r2 = svc.AddMoney(101, '1', TransactionReason.AdminGive)
			expect(r2.Success).to.equal(true)
			expect(r2.NewMoney).to.equal(Money.MaxMoney)
			expect(r2.Code).to.equal('cap-exceeded')
		end)

		it('AddMoney rejects unknown reasons', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [102] = profile }))
			local r = svc.AddMoney(102, '100', 'NotARealReason')
			expect(r.Success).to.equal(false)
			expect(r.Code).to.equal('invalid-reason')
			expect(profile.Money).to.equal('0')
		end)

		it('AddMoney rejects malformed amount', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [103] = profile }))
			local r = svc.AddMoney(103, 'abc', TransactionReason.AdminGive)
			expect(r.Success).to.equal(false)
			expect(r.Code).to.equal('invalid-amount')
		end)

		it('TrySpendMoney is atomic — insufficient returns failure without mutation', function()
			local profile = { Money = '50', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [104] = profile }))
			local r = svc.TrySpendMoney(104, '100', TransactionReason.EggPurchase)
			expect(r.Success).to.equal(false)
			expect(r.Code).to.equal('insufficient')
			-- Balance unchanged.
			expect(profile.Money).to.equal('50')
		end)

		it('TrySpendMoney succeeds and reduces balance on sufficient funds', function()
			local profile = { Money = '1000', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [105] = profile }))
			local r = svc.TrySpendMoney(105, '300', TransactionReason.EggPurchase)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal('700')
			expect(profile.Money).to.equal('700')
		end)

		it('TrySpendMoney clamps to zero on exact balance', function()
			local profile = { Money = '100', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [106] = profile }))
			local r = svc.TrySpendMoney(106, '100', TransactionReason.EggPurchase)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal('0')
		end)

		it('CanAfford is consistent with TrySpendMoney', function()
			local profile = { Money = '500', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [107] = profile }))
			expect(svc.CanAfford(107, '300')).to.equal(true)
			expect(svc.CanAfford(107, '500')).to.equal(true)
			expect(svc.CanAfford(107, '501')).to.equal(false)
			-- A zero-cost purchase is always affordable.
			expect(svc.CanAfford(107, '0')).to.equal(true)
		end)

		it('two players are isolated', function()
			local profileA = { Money = '100', Multipliers = { Money = 1 } }
			local profileB = { Money = '500', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [200] = profileA, [201] = profileB }))
			svc.AddMoney(200, '50', TransactionReason.AdminGive)
			expect(profileA.Money).to.equal('150')
			expect(profileB.Money).to.equal('500')
			svc.AddMoney(201, '50', TransactionReason.AdminGive)
			expect(profileA.Money).to.equal('150')
			expect(profileB.Money).to.equal('550')
		end)

		it('multiplier default 1 leaves amounts unchanged', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [300] = profile }))
			local r = svc.AddMoney(300, '1000', TransactionReason.AdminGive)
			expect(r.NewMoney).to.equal('1000')
		end)

		it('multiplier 0 absorbs the grant', function()
			local profile = { Money = '0', Multipliers = { Money = 0 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [301] = profile }))
			local r = svc.AddMoney(301, '1000', TransactionReason.AdminGive)
			expect(r.Success).to.equal(true)
			-- The grant was absorbed; the balance didn't move.
			expect(r.NewMoney).to.equal('0')
		end)

		it('multiplier 2 doubles the grant', function()
			local profile = { Money = '0', Multipliers = { Money = 2 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [302] = profile }))
			local r = svc.AddMoney(302, '1000', TransactionReason.AdminGive)
			expect(r.NewMoney).to.equal('2000')
		end)

		-- --- Phase 2.6.1 regression ---------------------------------------
		-- The incident lived in BigNumber, but these fixtures pin the
		-- service-level contracts the user saw break: the exact
		-- collection sequence, a cap that only trips on genuine
		-- excess, and spends whose operands differ in digit count
		-- (the pre-fix Subtract padding bug silently corrupted every
		-- such purchase).

		it('spec section 27: the incident grant sequence returns exact balances', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [400] = profile }))
			profile.Money = '650000'

			svc.AddMoney(400, '10550', TransactionReason.CashCollector, { ApplyMultiplier = false })
			expect(profile.Money).to.equal('660550') -- pre-fix: '6605500'
			svc.AddMoney(400, '5', TransactionReason.CashCollector, { ApplyMultiplier = false })
			expect(profile.Money).to.equal('660555') -- pre-fix: '66055050'
			svc.AddMoney(400, '5', TransactionReason.CashCollector, { ApplyMultiplier = false })
			expect(profile.Money).to.equal('660560') -- pre-fix: '660550550'
		end)

		it('the cap does NOT trip below MaxMoney — grants land exactly', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [401] = profile }))
			-- MaxMoney - 5, then +5: must land exactly at the cap
			-- with no clamp, no cap-exceeded code. Pre-fix, a
			-- x10-shifted add could jump past the cap and trigger
			-- cap-exceeded for honest grants.
			local below = BigNumber.Subtract(Money.MaxMoney, '5')
			svc.AddMoney(401, below, TransactionReason.AdminGive)
			expect(profile.Money).to.equal(below)
			local r = svc.AddMoney(401, '5', TransactionReason.CashCollector, { ApplyMultiplier = false })
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal(Money.MaxMoney)
			expect(r.Code).to.equal(nil)
			expect(profile.Money).to.equal(Money.MaxMoney)
		end)

		it('the cap clamps ONLY on genuine excess', function()
			local profile = { Money = '0', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [402] = profile }))
			profile.Money = Money.MaxMoney
			local r = svc.AddMoney(402, '1', TransactionReason.CashCollector, { ApplyMultiplier = false })
			expect(r.Success).to.equal(true)
			expect(r.Code).to.equal('cap-exceeded')
			expect(profile.Money).to.equal(Money.MaxMoney) -- clamped, not corrupted
		end)

		it('TrySpendMoney survives mismatched operand lengths (Subtract padding regression)', function()
			local profile = { Money = '650000', Multipliers = { Money = 1 } }
			local svc = EconomyService
			svc.SetPlayerService(fakePlayerService({ [403] = profile }))
			-- Pre-fix: Subtract('650000','10550') == '544500' — the
			-- player was CHARGED 105500, and a 100000-balance player
			-- spending 1000 kept '0'. Both directions are pinned.
			local r = svc.TrySpendMoney(403, '10550', TransactionReason.EggPurchase)
			expect(r.Success).to.equal(true)
			expect(r.NewMoney).to.equal('639450')
			expect(profile.Money).to.equal('639450')

			local profile2 = { Money = '100000', Multipliers = { Money = 1 } }
			svc.SetPlayerService(fakePlayerService({ [404] = profile2 }))
			local r2 = svc.TrySpendMoney(404, '1000', TransactionReason.EggPurchase)
			expect(r2.Success).to.equal(true)
			expect(profile2.Money).to.equal('99000') -- pre-fix: '0'
		end)
	end)
end
