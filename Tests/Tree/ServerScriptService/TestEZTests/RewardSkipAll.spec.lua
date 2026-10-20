--!strict
--!native
--[[
	RewardSkipAll.spec
	==================
	Skip-all parity for Daily + Playtime rewards: the Shop
	Developer Product receipt and the GUI Skip button share
	ClaimAll, which grants through the SAME per-day/per-
	milestone commit each single Claim uses (no duplicated
	reward logic), composing one summary instead of N toasts.

	  * fresh week/session: ClaimAll grants everything, streak
	    advances to complete
	  * second ClaimAll: Success with zero grants (idempotent —
	    retry continues instead of duplicating)
	  * equivalence: single Claim then ClaimAll grants exactly
	    the remainder (Daily; Playtime single claims are
	    time-gated headless, so parity is via the marked set)

	Fakes are injected through the services' own setters and
	restored to nil afterwards (WireServices never wires these
	services, so nil is the pristine spec state).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local DailyRewardsService = require(ServerScriptService.Daily.DailyRewardsService)
	local PlaytimeRewardsService = require(ServerScriptService.Playtime.PlaytimeRewardsService)
	local DailyRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Daily

	local USER = 424242

	local function fakeServices()
		local data: any = {}
		local playerService = {
			GetPlayerData = function(_userId: number)
				return data
			end,
		}
		local economyService = {
			AddMoney = function(_userId: number, _amount: string, _reason: string, _opts: any?)
				return { Success = true, NewMoney = '1' }
			end,
		}
		local codesService = {
			DeliverEggReward = function(_userId: number, _data: any, _label: string, _rarity: string)
				return { ok = true }
			end,
			DeliverAnimalReward = function(_userId: number, _data: any, _label: string, _defId: string, _trait: any, _level: any)
				return { ok = true }
			end,
			QueuePendingReward = function(_data: any, _reward: any)
				return true
			end,
		}
		local gearShopService = {
			EnsureGearTool = function(_player: Player, _gearId: string)
				return true
			end,
		}
		return data, playerService, economyService, codesService, gearShopService
	end

	describe('DailyRewardsService.ClaimAll', function()
		local data: any = nil

		beforeEach(function()
			Helpers.StubRemotes()
			DailyRewardsService._TestReset()
			local d, ps, es, cs, gs = fakeServices()
			data = d
			DailyRewardsService.SetPlayerService(ps)
			DailyRewardsService.SetEconomyService(es)
			DailyRewardsService.SetCodesService(cs)
			DailyRewardsService.SetGearShopService(gs)
		end)

		afterEach(function()
			DailyRewardsService.SetPlayerService(nil)
			DailyRewardsService.SetEconomyService(nil)
			DailyRewardsService.SetCodesService(nil)
			DailyRewardsService.SetGearShopService(nil)
			DailyRewardsService._TestReset()
		end)

		it('grants the whole week then idempotently grants nothing', function()
			local player = Helpers.FakePlayer(USER, 'Skipper')
			expect(DailyRewardsService.GrantSkipAccess(player)).to.equal(true)
			local dayCount = DailyRewardsConfig.DayCount()
			expect(dayCount >= 1).to.equal(true)
			local first = DailyRewardsService.ClaimAll(player)
			expect(first.Success).to.equal(true)
			expect(first.ClaimedDays).to.equal(dayCount)
			expect(data.DailyRewards.Day).to.equal(dayCount + 1)
			local second = DailyRewardsService.ClaimAll(player)
			expect(second.Success).to.equal(true)
			expect(second.ClaimedDays).to.equal(0)
			expect(data.DailyRewards.Day).to.equal(dayCount + 1)
		end)

		it('single Claim then ClaimAll grants exactly the remainder', function()
			local player = Helpers.FakePlayer(USER, 'Skipper')
			expect(DailyRewardsService.GrantSkipAccess(player)).to.equal(true)
			local dayCount = DailyRewardsConfig.DayCount()
			local one = DailyRewardsService.Claim(player, nil)
			expect(one.Success).to.equal(true)
			local rest = DailyRewardsService.ClaimAll(player)
			expect(rest.Success).to.equal(true)
			expect(rest.ClaimedDays).to.equal(dayCount - 1)
			expect(data.DailyRewards.Day).to.equal(dayCount + 1)
		end)

		it('rejects ClaimAll with no skip entitlement', function()
			local player = Helpers.FakePlayer(USER, 'Skipper')
			expect(DailyRewardsService.GrantSkipAccess(nil :: any)).to.equal(false)
			local denied = DailyRewardsService.ClaimAll(player)
			expect(denied.Success).to.equal(false)
			expect(denied.Reason).to.equal('no-access')
		end)
	end)

	describe('PlaytimeRewardsService.ClaimAll', function()
		beforeEach(function()
			Helpers.StubRemotes()
			PlaytimeRewardsService._TestReset()
			local _d, ps, es, cs, gs = fakeServices()
			PlaytimeRewardsService.SetPlayerService(ps)
			PlaytimeRewardsService.SetEconomyService(es)
			PlaytimeRewardsService.SetCodesService(cs)
			PlaytimeRewardsService.SetGearShopService(gs)
		end)

		afterEach(function()
			PlaytimeRewardsService.SetPlayerService(nil)
			PlaytimeRewardsService.SetEconomyService(nil)
			PlaytimeRewardsService.SetCodesService(nil)
			PlaytimeRewardsService.SetGearShopService(nil)
			PlaytimeRewardsService._TestReset()
		end)

		it('marks every milestone exactly once, then grants nothing', function()
			local player = Helpers.FakePlayer(USER, 'Skipper')
			expect(PlaytimeRewardsService.GrantSkipAccess(player)).to.equal(true)
			local first = PlaytimeRewardsService.ClaimAll(player)
			expect(first.Success).to.equal(true)
			expect(first.ClaimedCount >= 1).to.equal(true)
			local second = PlaytimeRewardsService.ClaimAll(player)
			expect(second.Success).to.equal(true)
			expect(second.ClaimedCount).to.equal(0)
		end)

		it('rejects ClaimAll with no skip entitlement', function()
			local player = Helpers.FakePlayer(USER, 'Skipper')
			expect(PlaytimeRewardsService.GrantSkipAccess(nil :: any)).to.equal(false)
			local denied = PlaytimeRewardsService.ClaimAll(player)
			expect(denied.Success).to.equal(false)
			expect(denied.Reason).to.equal('no-access')
		end)
	end)
end
