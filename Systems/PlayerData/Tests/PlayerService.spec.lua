--!strict
--!native
--[[
	PlayerService.spec
	==================
	Phase 2.1: PlayerService is no longer the money
	mutator — that role moved to EconomyService. These tests
	cover read-only invariants when no profile is loaded,
	plus the new shape sanity-checks.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Money = require(ReplicatedStorage.Config.Economy.Money)

	describe('PlayerService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('returns no data for an unknown user', function()
			local services = Helpers.GetServices()
			expect(services.PlayerService.GetPlayerData(12345)).to.equal(nil)
			expect(services.PlayerService.GetBaseId(12345)).to.equal(nil)
			expect(services.PlayerService.IsLoaded(12345)).to.equal(false)
		end)

		it('MaxMoney is a non-empty string in config', function()
			-- MaxMoney is a string-backed BigNumber, so it
			-- has no Lua-number representation. The check
			-- is "non-empty string" — the actual ceiling
			-- is enforced by EconomyService.AddMoney's
			-- cap-exceeded path.
			expect(Money.MaxMoney).to.be.a('string')
			expect(Money.MaxMoney).never.to.equal('')
		end)

		it('StartingMoney is a non-empty string in config', function()
			expect(Money.StartingMoney).to.be.a('string')
			expect(Money.StartingMoney).never.to.equal('')
		end)

		it('BumpStat fail-closes without a loaded profile', function()
			local services = Helpers.GetServices()
			expect(services.PlayerService.BumpStat(12345, 'EggsPurchased')).to.equal(false)
			expect(services.PlayerService.BumpStat(12345, 'NotAStat')).to.equal(false)
		end)
	end)
end
