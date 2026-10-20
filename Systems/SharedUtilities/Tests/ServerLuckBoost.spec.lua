--!strict
--!native
--[[
	ServerLuckBoost.spec
	====================
	Temporary server-wide luck boosts (Robux purchase path):

	  * ActivateBoost sets the effective luck for its duration
	  * a newer purchase REPLACES (never stacks/multiplies)
	  * admin SetLuck cancels any boost immediately
	  * invalid multiplier/duration rejected (nil, state kept)
	  * GetBoostInfo reports live snapshot or nil
	  * expiry listeners subscribe without throwing

	Timed expiry itself is a task.delay path (Studio-verified);
	here we lock the state machine around it.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local ServerLuckService = require(ServerScriptService.ServerLuckService)

	describe('ServerLuckService temporary boosts', function()
		beforeEach(function()
			ServerLuckService._TestReset()
		end)

		afterEach(function()
			ServerLuckService._TestReset()
		end)

		it('activates a boost that GetLuck reports', function()
			local token = ServerLuckService.ActivateBoost(4, 1800, 'spec')
			expect(type(token)).to.equal('number')
			expect(ServerLuckService.GetLuck()).to.equal(4)
			local info = ServerLuckService.GetBoostInfo()
			expect(info).to.be.ok()
			expect(info.mult).to.equal(4)
			expect(info.remainingSecs > 0).to.equal(true)
		end)

		it('a newer purchase replaces instead of stacking', function()
			ServerLuckService.ActivateBoost(2, 3600, 'spec')
			expect(ServerLuckService.GetLuck()).to.equal(2)
			local token2 = ServerLuckService.ActivateBoost(8, 900, 'spec')
			expect(type(token2)).to.equal('number')
			expect(ServerLuckService.GetLuck()).to.equal(8)
			local info = ServerLuckService.GetBoostInfo()
			expect(info.mult).to.equal(8)
		end)

		it('admin SetLuck cancels the boost immediately', function()
			ServerLuckService.ActivateBoost(4, 1800, 'spec')
			expect(ServerLuckService.GetLuck()).to.equal(4)
			expect(ServerLuckService.SetLuck(1)).to.equal(true)
			expect(ServerLuckService.GetLuck()).to.equal(1)
			expect(ServerLuckService.GetBoostInfo()).to.equal(nil)
		end)

		it('rejects invalid boost params without changing state', function()
			expect(ServerLuckService.ActivateBoost(0, 100, 'spec')).to.equal(nil)
			expect(ServerLuckService.ActivateBoost(-2, 100, 'spec')).to.equal(nil)
			expect(ServerLuckService.ActivateBoost('4' :: any, 100, 'spec')).to.equal(nil)
			expect(ServerLuckService.ActivateBoost(4, 0, 'spec')).to.equal(nil)
			expect(ServerLuckService.ActivateBoost(4, -5, 'spec')).to.equal(nil)
			expect(ServerLuckService.ActivateBoost(4, math.huge, 'spec')).to.equal(nil)
			expect(ServerLuckService.GetLuck()).to.equal(1)
			expect(ServerLuckService.GetBoostInfo()).to.equal(nil)
		end)

		it('expiry listeners subscribe without throwing', function()
			expect(function()
				ServerLuckService.OnBoostExpired(function(_info: any) end)
				ServerLuckService.OnBoostExpired(nil :: any)
			end).to.never.throw()
		end)
	end)
end
