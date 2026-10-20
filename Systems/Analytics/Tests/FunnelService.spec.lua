--!strict
--!native
--[[
	FunnelService.spec
	==================
	Central funnel analytics contract:

	  * successful LogStep reaches the sender with the correct
	    funnel, step, and positional step number
	  * analytics failure never throws into gameplay (LogStep
	    still returns true; gameplay continues)
	  * one-time milestones are suppressed per session
	  * players and sessions are isolated
	  * invalid players / unknown funnels / disabled service
	    safely resolve false with no send
	  * metadata (incl. scoped _key) passes through to the
	    recorded call
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local Helpers = require(script.Parent._Helpers)
	local FunnelService = require(ServerScriptService.FunnelService)

	describe('FunnelService', function()
		local sent: { { [string]: any } } = {}

		beforeEach(function()
			Helpers.StubRemotes()
			FunnelService._TestReset()
			sent = {}
			FunnelService._TestSetSender(
				function(player: Player, funnel: string, sessionId: string?, stepNumber: number, stepName: string)
					table.insert(sent, {
						UserId = (player :: any).UserId,
						Funnel = funnel,
						SessionId = sessionId,
						StepNumber = stepNumber,
						Step = stepName,
					})
					return true
				end
			)
		end)

		afterEach(function()
			FunnelService._TestReset()
		end)

		it('logs a step with the positional step number', function()
			local player = Helpers.FakePlayer(101)
			expect(FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)).to.equal(true)
			expect(#sent).to.equal(1)
			expect(sent[1].Funnel).to.equal('Onboarding')
			expect(sent[1].Step).to.equal('FirstEggPurchased')
			expect(sent[1].StepNumber).to.equal(2)
			expect(type(sent[1].SessionId)).to.equal('string')
		end)

		it('numbers rebirth steps in fire order (attempted before requirement)', function()
			local player = Helpers.FakePlayer(112)
			FunnelService:LogStep(player, 'Rebirth', 'RebirthAttempted', { rebirth_number = 3, _key = '3' })
			FunnelService:LogStep(player, 'Rebirth', 'RebirthRequirementReached', { rebirth_number = 3, _key = '3' })
			FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', { rebirth_number = 3, _key = '3' })
			expect(#sent).to.equal(3)
			expect(sent[1].StepNumber).to.equal(1)
			expect(sent[2].StepNumber).to.equal(2)
			expect(sent[3].StepNumber).to.equal(3)
		end)

		it('analytics failure never throws into gameplay', function()
			FunnelService._TestSetSender(function()
				return false
			end)
			local player = Helpers.FakePlayer(102)
			local ok = false
			pcall(function()
				ok = FunnelService:LogStep(player, 'Arena', 'ArenaStarted', nil)
			end)
			expect(ok).to.equal(true)
		end)

		it('throwing sender never propagates', function()
			FunnelService._TestSetSender(function()
				error('analytics exploded')
				return true
			end)
			local player = Helpers.FakePlayer(103)
			local ok = false
			pcall(function()
				ok = FunnelService:LogStep(player, 'Arena', 'ArenaStarted', nil)
			end)
			expect(ok).to.equal(true)
		end)

		it('suppresses duplicate one-time milestones per session', function()
			local player = Helpers.FakePlayer(104)
			expect(FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)).to.equal(true)
			expect(FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)).to.equal(true)
			expect(#sent).to.equal(1)
		end)

		it('repeatable steps log every time', function()
			local player = Helpers.FakePlayer(105)
			FunnelService:LogStep(player, 'Arena', 'ArenaStarted', nil)
			FunnelService:LogStep(player, 'Arena', 'ArenaStarted', nil)
			expect(#sent).to.equal(2)
		end)

		it('isolates players from each other', function()
			local a = Helpers.FakePlayer(106)
			local b = Helpers.FakePlayer(107)
			FunnelService:LogStep(a, 'Onboarding', 'FirstEggPurchased', nil)
			FunnelService:LogStep(b, 'Onboarding', 'FirstEggPurchased', nil)
			expect(#sent).to.equal(2)
			expect(FunnelService._TestWasLogged(106, 'Onboarding', 'FirstEggPurchased')).to.equal(true)
			expect(FunnelService._TestWasLogged(107, 'Onboarding', 'FirstEggPurchased')).to.equal(true)
		end)

		it('isolates sessions via ForgetPlayer', function()
			local player = Helpers.FakePlayer(108)
			FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)
			FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)
			expect(#sent).to.equal(1)
			FunnelService.ForgetPlayer(108)
			FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)
			expect(#sent).to.equal(2)
		end)

		it('scopes rebirth success per rebirth number', function()
			local player = Helpers.FakePlayer(109)
			FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', { rebirth_number = 1, _key = '1' })
			FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', { rebirth_number = 1, _key = '1' })
			FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', { rebirth_number = 2, _key = '2' })
			expect(#sent).to.equal(2)
		end)

		it('rejects invalid players and unknown funnels safely', function()
			expect(FunnelService:LogStep(nil :: any, 'Onboarding', 'FirstEggPurchased', nil)).to.equal(false)
			local player = Helpers.FakePlayer(110)
			expect(FunnelService:LogStep(player, 'Nope', 'FirstEggPurchased', nil)).to.equal(false)
			expect(FunnelService:LogStep(player, 'Onboarding', 'Nope', nil)).to.equal(false)
			expect(#sent).to.equal(0)
		end)

		it('is a safe no-op while disabled', function()
			FunnelService._TestSetEnabled(false)
			local player = Helpers.FakePlayer(111)
			expect(FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)).to.equal(false)
			expect(#sent).to.equal(0)
			expect(#FunnelService._TestGetCalls()).to.equal(0)
		end)

		it('buckets upgrade levels into bands', function()
			expect(FunnelService.LevelBand(1)).to.equal('1-10')
			expect(FunnelService.LevelBand(10)).to.equal('1-10')
			expect(FunnelService.LevelBand(11)).to.equal('11-25')
			expect(FunnelService.LevelBand(50)).to.equal('26-50')
			expect(FunnelService.LevelBand(99)).to.equal('51-100')
			expect(FunnelService.LevelBand(150)).to.equal('100+')
		end)

		it('only treats milestone stages as funnel-worthy', function()
			expect(FunnelService.IsArenaMilestone(1)).to.equal(true)
			expect(FunnelService.IsArenaMilestone(5)).to.equal(true)
			expect(FunnelService.IsArenaMilestone(10)).to.equal(true)
			expect(FunnelService.IsArenaMilestone(25)).to.equal(true)
			expect(FunnelService.IsArenaMilestone(50)).to.equal(true)
			expect(FunnelService.IsArenaMilestone(2)).to.equal(false)
			expect(FunnelService.IsArenaMilestone(49)).to.equal(false)
		end)
	end)
end
