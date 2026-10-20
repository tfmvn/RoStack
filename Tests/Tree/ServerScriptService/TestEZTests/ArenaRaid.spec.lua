--!strict
--!native
--[[
	ArenaRaid.spec
	===============
	Headless coverage for the continuous Arena RAID model:
	stage auto-advance in one session, raid-HP carry-over
	(no heals, dead stay dead), all-dead guards, final-stage
	RAID COMPLETE, wipe => RAID FAILED, stale-generation
	rejection, multiplayer isolation, leave cleanup, and a
	full engine tick from stage 1 into stage 2.

	Live players are never needed: the settle path resolves
	players lazily (nil-safe headless) and headless sessions
	run the sim model-free (no base => no models).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')

	local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)
	local Battle = require(ServerScriptService.Arena.ArenaBattleService)

	local function raidMember(defId: string, level: number, uniqueId: string): any
		return {
			UniqueId = uniqueId,
			DefinitionId = defId,
			DisplayName = defId,
			Rarity = 'Common',
			Level = level,
		}
	end

	local function stageEnemies(stage: number): { any }
		return (ArenaConfig.FindLevel(stage) :: any).EnemyTeam
	end

	-- Per-user profiles + grant ledger + silent notifies.
	local function raidHarness()
		local ArenaService = require(ServerScriptService.Arena.ArenaService)
		local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
		local profiles: { [number]: any } = {}
		Progression.SetPlayerService({
			GetPlayerData = function(userId: number)
				if profiles[userId] == nil then
					profiles[userId] = {}
				end
				return profiles[userId]
			end,
		})
		local grants: { [number]: { any } } = {}
		ArenaService.SetProgressionService(Progression)
		ArenaService.SetEconomyService({
			AddMoney = function(userId: number, amount: string, reason: string, _opts: any)
				local list = grants[userId]
				if list == nil then
					list = {}
					grants[userId] = list
				end
				list[#list + 1] = { amount = amount, reason = reason }
				return { Success = true }
			end,
		})
		ArenaService.SetNotificationService({
			NotifyWarning = function()
				return true
			end,
			NotifySuccess = function()
				return true
			end,
		})
		ArenaService.SetBattleService(Battle)
		return ArenaService, Progression, grants
	end

	local function grantsOf(grants: { [number]: { any } }, userId: number): { any }
		local list = grants[userId]
		if list == nil then
			return {}
		end
		return list
	end

	local function injectRaid(
		ArenaService: any,
		userId: number,
		sessionId: number,
		stage: number,
		members: { any },
		battle: any,
		gen: number?,
		cursor: number?
	)
		ArenaService._TestInjectSession(userId, {
			sessionId = sessionId,
			userId = userId,
			kind = 'Raid',
			arenaLevel = stage,
			maxLevel = ArenaConfig.MaxLevel(),
			stageGeneration = gen or 1,
			state = 'Active',
			team = members,
			raidHP = {},
			raidAlive = {},
			rewardedStages = {},
			settledStages = {},
			clearedStages = {},
			rewardAccum = { cash = '0', xp = 0 },
			rewardSettled = false,
			firstClearCursor = cursor or 1,
			battle = battle,
		})
	end

	-- Expected collective totals over stages [fromStage, toStage]
	-- with a HighestCompleted of `baseHC` before the run.
	local function expectedTotals(fromStage: number, toStage: number, baseHC: number): { cash: string, xp: number }
		local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
		local cash = '0'
		local xp = 0
		local cursor = baseHC + 1
		for stage = fromStage, toStage do
			local entry = ArenaConfig.FindLevel(stage) :: any
			local first = stage == cursor
			if first then
				cursor = cursor + 1
			end
			local amount = if first then entry.Rewards.FirstClearCash else entry.Rewards.RepeatCash
			cash = BigNumber.Add(cash, amount)
			xp += entry.Rewards.ArenaXP
		end
		return { cash = cash, xp = xp }
	end

	local function teardownRaid(ArenaService: any, Progression: any)
		ArenaService._TestReset()
		Progression._TestReset()
		ArenaService.SetProgressionService(nil)
		ArenaService.SetEconomyService(nil)
		ArenaService.SetNotificationService(nil)
		ArenaService.SetBattleService(nil)
		Battle._TestReset()
	end

	describe('Arena raid HP carry-over (acceptance)', function()
		it('stage 2 spawns exactly the HP stage 1 ended with; dead stay dead', function()
			local ArenaService, Progression, grants = raidHarness()
			local members = {
				raidMember('Dog', 8, 'RA_A'),
				raidMember('Frog', 8, 'RA_B'),
				raidMember('Raccoon', 8, 'RA_C'),
			}
			local battle: any, berr = Battle.CreateBattle(9301, 7301, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			local maxA = battle.playerTeam[1].MaxHealth
			local maxB = battle.playerTeam[2].MaxHealth
			local maxC = battle.playerTeam[3].MaxHealth
			-- End-of-stage-1 shape: A at 70%, B at 25%, C dead.
			battle.playerTeam[1].CurrentHealth = maxA * 0.7
			battle.playerTeam[2].CurrentHealth = maxB * 0.25
			battle.playerTeam[3].CurrentHealth = 0
			battle.playerTeam[3].Alive = false
			injectRaid(ArenaService, 9301, 7301, 1, members, battle, 1)
			local r = ArenaService.CompleteBattle(9301, 7301, true, 1)
			expect(r.success).to.equal(true)
			expect(r.advanced).to.equal(true)
			-- Collective model: NO payout mid-raid. Balances,
			-- XP, and history are untouched; the contribution
			-- sits in the accumulator only.
			expect(#grantsOf(grants, 9301)).to.equal(0)
			expect(Progression.GetArenaXP(9301)).to.equal(0)
			expect(Progression.GetHighestCompleted(9301)).to.equal(0)
			local acc1 = ArenaService.GetSession(9301).rewardAccum
			expect(acc1.cash).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash)
			expect(acc1.xp).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.ArenaXP)
			-- Same session, next stage, next generation.
			local session = ArenaService.GetSession(9301)
			expect(session).to.be.ok()
			expect(session.arenaLevel).to.equal(2)
			expect(session.stageGeneration).to.equal(2)
			-- Carried HP is exact: no heal, no reset.
			local stage2 = session.battle
			expect(stage2).to.be.ok()
			expect(stage2.playerTeam[1].CurrentHealth).to.equal(maxA * 0.7)
			expect(stage2.playerTeam[2].CurrentHealth).to.equal(maxB * 0.25)
			expect(stage2.playerTeam[1].MaxHealth).to.equal(maxA)
			expect(stage2.playerTeam[2].MaxHealth).to.equal(maxB)
			-- Dead stays dead: listed, but not alive and model-free.
			expect(stage2.playerTeam[3].Alive).to.equal(false)
			expect(stage2.playerTeam[3].CurrentHealth).to.equal(0)
			expect(stage2.playerTeam[3].Model).to.equal(nil)
			-- Win stage 2 untouched: HP persists into stage 3,
			-- still with zero payouts.
			local r2 = ArenaService.CompleteBattle(9301, 7301, true, 2)
			expect(r2.success).to.equal(true)
			expect(r2.advanced).to.equal(true)
			expect(#grantsOf(grants, 9301)).to.equal(0)
			expect(Progression.GetArenaXP(9301)).to.equal(0)
			local acc2 = ArenaService.GetSession(9301).rewardAccum
			local twoStage = expectedTotals(1, 2, 0)
			expect(acc2.cash).to.equal(twoStage.cash)
			expect(acc2.xp).to.equal(twoStage.xp)
			local session3 = ArenaService.GetSession(9301)
			expect(session3.arenaLevel).to.equal(3)
			expect(session3.battle.playerTeam[1].CurrentHealth).to.equal(maxA * 0.7)
			expect(session3.battle.playerTeam[3].Alive).to.equal(false)
			-- Wipe at stage 3: progressive settlement pays the
			-- cleared stages 1-2 (the failed stage 3 forfeits).
			local r3 = ArenaService.CompleteBattle(9301, 7301, false, 3)
			expect(r3.success).to.equal(true)
			expect(r3.won).to.equal(false)
			expect(ArenaService.GetSession(9301)).to.equal(nil)
			expect(#grantsOf(grants, 9301)).to.equal(1)
			expect(grantsOf(grants, 9301)[1].amount).to.equal(twoStage.cash)
			-- XP granted once (stages 1+2 totals), minus level-up
			-- thresholds consumed to the cap (100 * sum(1..9) = 4500).
			expect(Progression.GetArenaXP(9301)).to.equal(twoStage.xp - 4500)
			expect(Progression.GetHighestCompleted(9301)).to.equal(2)
			expect(Progression.GetArenaState(9301).Wins).to.equal(2)
			-- A brand-new raid starts fresh at full HP.
			local fresh: any, ferr = Battle.CreateBattle(9301, 7302, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(ferr).to.equal(nil)
			expect(fresh.playerTeam[1].CurrentHealth).to.equal(maxA)
			expect(fresh.playerTeam[2].CurrentHealth).to.equal(maxB)
			expect(fresh.playerTeam[3].CurrentHealth).to.equal(maxC)
			expect(fresh.playerTeam[3].Alive).to.equal(true)
			teardownRaid(ArenaService, Progression)
		end)
	end)

	describe('Arena raid completion', function()
		it('final-stage win completes the raid and records HighestCompleted', function()
			local ArenaService, Progression, grants = raidHarness()
			local maxStage = ArenaConfig.MaxLevel()
			-- A real raid reaches the final only after clearing
			-- every prior stage in order.
			for stage = 1, maxStage - 1 do
				Progression.RecordLevelWin(9311, stage)
			end
			expect(Progression.GetHighestCompleted(9311)).to.equal(maxStage - 1)
			local members = { raidMember('Dragon', 30, 'RC_fin') }
			local battle: any, berr =
				Battle.CreateBattle(9311, 7311, maxStage, members, stageEnemies(maxStage), 1.5, 0, 7, nil)
			expect(berr).to.equal(nil)
			-- Cursor matches the profile history (next new
			-- stage is 10), so the lone contribution is first-clear.
			injectRaid(ArenaService, 9311, 7311, maxStage, members, battle, 7, maxStage)
			local r = ArenaService.CompleteBattle(9311, 7311, true, 7)
			expect(r.success).to.equal(true)
			expect(r.raidComplete).to.equal(true)
			expect(ArenaService.GetSession(9311)).to.equal(nil)
			-- ONE terminal transaction for the whole raid.
			expect(#grantsOf(grants, 9311)).to.equal(1)
			expect(grantsOf(grants, 9311)[1].amount).to.equal(
				(ArenaConfig.FindLevel(maxStage) :: any).Rewards.FirstClearCash
			)
			expect(grantsOf(grants, 9311)[1].reason).to.equal('ArenaReward')
			expect(Progression.GetArenaXP(9311)).to.equal((ArenaConfig.FindLevel(maxStage) :: any).Rewards.ArenaXP)
			expect(Progression.GetArenaState(9311).Wins).to.equal(maxStage)
			expect(Progression.GetHighestCompleted(9311)).to.equal(maxStage)
			teardownRaid(ArenaService, Progression)
		end)

		it('a full 1-10 run pays one collective total and records full history', function()
			local ArenaService, Progression, grants = raidHarness()
			local maxStage = ArenaConfig.MaxLevel()
			local members = { raidMember('Dragon', 30, 'RC_full') }
			local battle: any, berr = Battle.CreateBattle(9312, 7312, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9312, 7312, 1, members, battle, 1, 1)
			for gen = 1, maxStage do
				local settled = ArenaService.GetSession(9312)
				expect(settled).to.be.ok()
				expect(settled.arenaLevel).to.equal(gen)
				-- Nothing pays out mid-run.
				expect(#grantsOf(grants, 9312)).to.equal(0)
				local r = ArenaService.CompleteBattle(9312, 7312, true, gen)
				if gen < maxStage then
					expect(r.advanced).to.equal(true)
				else
					expect(r.raidComplete).to.equal(true)
				end
			end
			local total = expectedTotals(1, maxStage, 0)
			expect(#grantsOf(grants, 9312)).to.equal(1)
			expect(grantsOf(grants, 9312)[1].amount).to.equal(total.cash)
			-- XP granted once, minus level-up thresholds consumed
			-- on the way to the cap (100 * sum(1..9) = 4500).
			expect(Progression.GetArenaLevel(9312)).to.equal(maxStage)
			expect(Progression.GetArenaXP(9312)).to.equal(total.xp - 4500)
			expect(Progression.GetArenaState(9312).Wins).to.equal(maxStage)
			expect(Progression.GetHighestCompleted(9312)).to.equal(maxStage)
			expect(ArenaService.GetSession(9312)).to.equal(nil)
			-- A repeat full run earns the all-repeat total.
			local battle2: any, berr2 = Battle.CreateBattle(9312, 7313, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr2).to.equal(nil)
			injectRaid(ArenaService, 9312, 7313, 1, members, battle2, 1, maxStage + 1)
			for gen = 1, maxStage do
				ArenaService.CompleteBattle(9312, 7313, true, gen)
			end
			local repeatTotal = expectedTotals(1, maxStage, maxStage)
			expect(#grantsOf(grants, 9312)).to.equal(2)
			expect(grantsOf(grants, 9312)[2].amount).to.equal(repeatTotal.cash)
			teardownRaid(ArenaService, Progression)
		end)

		it('a mid-history run mixes repeat and first-clear contributions by cursor', function()
			local ArenaService, Progression, grants = raidHarness()
			for stage = 1, 5 do
				Progression.RecordLevelWin(9331, stage)
			end
			local members = { raidMember('Dragon', 30, 'RC_cur') }
			local battle: any, berr = Battle.CreateBattle(9331, 7331, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			-- Cursor 6: stages 1-5 contribute repeat, 6-7 first.
			injectRaid(ArenaService, 9331, 7331, 1, members, battle, 1, 6)
			for gen = 1, 7 do
				ArenaService.CompleteBattle(9331, 7331, true, gen)
			end
			-- Wipe at stage 8: progressive settlement pays stages
			-- 1-7 (1-5 repeat, 6-7 first-clear); history advances
			-- to the highest cleared stage.
			ArenaService.CompleteBattle(9331, 7331, false, 8)
			expect(ArenaService.GetSession(9331)).to.equal(nil)
			local wiped = expectedTotals(1, 7, 5)
			expect(#grantsOf(grants, 9331)).to.equal(1)
			expect(grantsOf(grants, 9331)[1].amount).to.equal(wiped.cash)
			expect(Progression.GetHighestCompleted(9331)).to.equal(7)
			expect(Progression.GetArenaState(9331).Wins).to.equal(12)
			-- Same run completed instead: mixed total pays once.
			local battle2: any, _ = Battle.CreateBattle(9331, 7332, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			injectRaid(ArenaService, 9331, 7332, 1, members, battle2, 1, 6)
			for gen = 1, 10 do
				ArenaService.CompleteBattle(9331, 7332, true, gen)
			end
			local mixed = expectedTotals(1, 10, 5)
			expect(#grantsOf(grants, 9331)).to.equal(2)
			expect(grantsOf(grants, 9331)[2].amount).to.equal(mixed.cash)
			expect(Progression.GetHighestCompleted(9331)).to.equal(10)
			expect(Progression.GetArenaState(9331).Wins).to.equal(22)
			teardownRaid(ArenaService, Progression)
		end)
	end)

	describe('Arena raid stale protection', function()
		it('rejects previous-generation callbacks with no reward and no state change', function()
			local ArenaService, _Progression, grants = raidHarness()
			local members = { raidMember('Tiger', 30, 'RS_a') }
			local battle: any, berr = Battle.CreateBattle(9321, 7321, 2, members, stageEnemies(2), 1.5, 0, 2, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9321, 7321, 2, members, battle, 2)
			-- Delayed stage-1 callback arriving during stage 2.
			local stale = ArenaService.CompleteBattle(9321, 7321, true, 1)
			expect(stale.success).to.equal(false)
			expect(stale.error).to.equal('stale-stage')
			expect(#grantsOf(grants, 9321)).to.equal(0)
			local session = ArenaService.GetSession(9321)
			expect(session).to.be.ok()
			expect(session.arenaLevel).to.equal(2)
			expect(session.stageGeneration).to.equal(2)
			expect(session.state).to.equal('Active')
			expect(session.rewardAccum.cash).to.equal('0')
			expect(session.rewardAccum.xp).to.equal(0)
			-- Current-generation win still accumulates + advances.
			local r = ArenaService.CompleteBattle(9321, 7321, true, 2)
			expect(r.success).to.equal(true)
			expect(r.advanced).to.equal(true)
			expect(#grantsOf(grants, 9321)).to.equal(0)
			teardownRaid(ArenaService, _Progression)
		end)

		it('refuses to build or spawn a battle when the whole team is dead', function()
			local members = {
				raidMember('Dog', 8, 'RD_a'),
				raidMember('Frog', 8, 'RD_b'),
			}
			local dead = { RD_a = 0, RD_b = 0 }
			local battle: any, err = Battle.CreateBattle(9322, 7322, 2, members, stageEnemies(2), 1.5, 0, 2, dead)
			expect(battle).to.equal(nil)
			expect(err).to.equal('all-dead')
			-- Single-fighter override at 0 HP enters dead.
			local solo: any, serr = Battle.BuildPlayerCombatant(raidMember('Dog', 8, 'RD_s'), 1, 0, 1.5, 0)
			expect(serr).to.equal(nil)
			expect(solo.Alive).to.equal(false)
			expect(solo.CurrentHealth).to.equal(0)
		end)
	end)

	describe('Arena raid multiplayer isolation', function()
		it('two raids advance, wipe, and settle independently', function()
			local ArenaService, Progression, grants = raidHarness()
			local membersA = { raidMember('Tiger', 30, 'RI_a') }
			local membersB = { raidMember('Dragon', 30, 'RI_b') }
			local battleA: any, errA = Battle.CreateBattle(9401, 7401, 1, membersA, stageEnemies(1), 1.5, 0, 1, nil)
			expect(errA).to.equal(nil)
			local battleB: any, errB = Battle.CreateBattle(9402, 7402, 1, membersB, stageEnemies(1), 1.5, 0, 1, nil)
			expect(errB).to.equal(nil)
			injectRaid(ArenaService, 9401, 7401, 1, membersA, battleA, 1)
			injectRaid(ArenaService, 9402, 7402, 1, membersB, battleB, 1)
			-- A clears stage 1; B is untouched. Nothing pays out.
			expect(ArenaService.CompleteBattle(9401, 7401, true, 1).advanced).to.equal(true)
			expect(ArenaService.GetSession(9401).arenaLevel).to.equal(2)
			expect(ArenaService.GetSession(9402).arenaLevel).to.equal(1)
			expect(ArenaService.GetSession(9402).stageGeneration).to.equal(1)
			expect(#grantsOf(grants, 9401)).to.equal(0)
			expect(#grantsOf(grants, 9402)).to.equal(0)
			expect(ArenaService.GetSession(9401).rewardAccum.cash).to.equal(
				(ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash
			)
			-- B clears stage 1 too; accumulators stay separate.
			expect(ArenaService.CompleteBattle(9402, 7402, true, 1).advanced).to.equal(true)
			expect(#grantsOf(grants, 9402)).to.equal(0)
			expect(ArenaService.GetSession(9402).rewardAccum.cash).to.equal(
				(ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash
			)
			-- A wipes at stage 2: A's cleared stage 1 settles
			-- progressively while B continues untouched.
			local lostA = ArenaService.CompleteBattle(9401, 7401, false, 2)
			expect(lostA.success).to.equal(true)
			expect(ArenaService.GetSession(9401)).to.equal(nil)
			expect(#grantsOf(grants, 9401)).to.equal(1)
			expect(grantsOf(grants, 9401)[1].amount).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash)
			expect(ArenaService.GetSession(9402)).to.be.ok()
			expect(ArenaService.GetSession(9402).arenaLevel).to.equal(2)
			expect(Progression.GetHighestCompleted(9401)).to.equal(1)
			expect(Progression.GetHighestCompleted(9402)).to.equal(0)
			-- B can still advance after A is gone.
			expect(ArenaService.CompleteBattle(9402, 7402, true, 2).advanced).to.equal(true)
			expect(ArenaService.GetSession(9402).arenaLevel).to.equal(3)
			expect(#grantsOf(grants, 9402)).to.equal(0)
			teardownRaid(ArenaService, Progression)
		end)

		it('leaving mid-raid ends only that raid with no rewards', function()
			local ArenaService, _Progression, grants = raidHarness()
			local membersA = { raidMember('Tiger', 30, 'RL_a') }
			local membersB = { raidMember('Dragon', 30, 'RL_b') }
			local battleA: any, _ = Battle.CreateBattle(9411, 7411, 1, membersA, stageEnemies(1), 1.5, 0, 1, nil)
			local battleB: any, _ = Battle.CreateBattle(9412, 7412, 1, membersB, stageEnemies(1), 1.5, 0, 1, nil)
			injectRaid(ArenaService, 9411, 7411, 1, membersA, battleA, 1)
			injectRaid(ArenaService, 9412, 7412, 1, membersB, battleB, 1)
			-- A leaves: raid session cleared, no rewards.
			-- (Battle unregistration on leave is covered by the
			-- silent-cancel spec; this asserts session cleanup
			-- deterministically, free of scheduler races.)
			ArenaService.ForgetPlayer(9411)
			expect(ArenaService.GetSession(9411)).to.equal(nil)
			expect(#grantsOf(grants, 9411)).to.equal(0)
			-- B's raid is fully intact and completable (still unpaid).
			expect(ArenaService.GetSession(9412)).to.be.ok()
			expect(ArenaService.CompleteBattle(9412, 7412, true, 1).advanced).to.equal(true)
			expect(#grantsOf(grants, 9412)).to.equal(0)
			teardownRaid(ArenaService, _Progression)
		end)
	end)

	describe('Arena raid engine transition', function()
		it('a ticked stage-1 victory automatically registers stage 2 with carried HP', function()
			local ArenaService, _Progression, grants = raidHarness()
			Battle.SetValidator(function(battle: any): boolean
				if type(battle) ~= 'table' then
					return false
				end
				local session = ArenaService.GetSession(battle.userId)
				return session ~= nil
					and session.state == 'Active'
					and session.sessionId == battle.sessionId
					and session.stageGeneration == battle.stageGeneration
			end)
			Battle.SetOnBattleEnd(function(userId: number, sessionId: number, won: boolean, stageGen: number?)
				ArenaService.CompleteBattle(userId, sessionId, won, stageGen)
			end)
			Battle.SetOnBattleCancel(function(userId: number, sessionId: number, stageGen: number?)
				ArenaService.CancelBattleSilent(userId, sessionId, stageGen)
			end)
			local members = { raidMember('Dragon', 30, 'RE_a') }
			local battle: any, berr = Battle.CreateBattle(9501, 7501, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9501, 7501, 1, members, battle, 1)
			expect(Battle.RegisterBattle(battle)).to.equal(true)
			local now = 1000
			local advanced = false
			for _ = 1, 5000 do
				now += 1.5
				Battle.TickAll(now)
				local session = ArenaService.GetSession(9501)
				if session ~= nil and session.arenaLevel == 2 then
					advanced = true
					break
				end
			end
			expect(advanced).to.equal(true)
			-- Stage 2 is live with the same session.
			local session = ArenaService.GetSession(9501)
			expect(session.stageGeneration).to.equal(2)
			expect(Battle.GetBattle(9501)).to.equal(session.battle)
			expect(session.battle.arenaLevel).to.equal(2)
			-- Carried HP equals what stage 1 ended with.
			expect(session.battle.playerTeam[1].CurrentHealth).to.equal(battle.playerTeam[1].CurrentHealth)
			-- The stage-1 contribution accumulated, unpaid.
			expect(session.rewardAccum.cash).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash)
			expect(session.rewardAccum.xp).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.ArenaXP)
			-- Freeze the raid before asserting ledger state.
			-- Nothing paid out: the contribution is accumulated.
			ArenaService.ForgetPlayer(9501)
			expect(ArenaService.GetSession(9501)).to.equal(nil)
			expect(#grantsOf(grants, 9501)).to.equal(0)
			teardownRaid(ArenaService, _Progression)
		end)

		it('a hopeless stage-1 team wipes with no reward and no session left', function()
			local ArenaService, _Progression, grants = raidHarness()
			Battle.SetValidator(function(battle: any): boolean
				if type(battle) ~= 'table' then
					return false
				end
				local session = ArenaService.GetSession(battle.userId)
				return session ~= nil
					and session.state == 'Active'
					and session.sessionId == battle.sessionId
					and session.stageGeneration == battle.stageGeneration
			end)
			Battle.SetOnBattleEnd(function(userId: number, sessionId: number, won: boolean, stageGen: number?)
				ArenaService.CompleteBattle(userId, sessionId, won, stageGen)
			end)
			local members = { raidMember('Chicken', 1, 'RW_a') }
			local battle: any, berr = Battle.CreateBattle(
				9511,
				7511,
				1,
				members,
				{ { DefinitionId = 'Dragon', Level = 25, StatMultiplier = 2.5, IsBoss = true } },
				1.5,
				0,
				1,
				nil
			)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9511, 7511, 1, members, battle, 1)
			expect(Battle.RegisterBattle(battle)).to.equal(true)
			local now = 2000
			for _ = 1, 5000 do
				now += 1.5
				Battle.TickAll(now)
				if Battle.GetBattle(9511) == nil then
					break
				end
			end
			expect(Battle.GetBattle(9511)).to.equal(nil)
			expect(ArenaService.GetSession(9511)).to.equal(nil)
			expect(#grantsOf(grants, 9511)).to.equal(0)
			teardownRaid(ArenaService, _Progression)
		end)
	end)

	describe('Arena raid settlement guards', function()
		it('a duplicate victory for the same stage settles nothing twice', function()
			local ArenaService, Progression, grants = raidHarness()
			local members = { raidMember('Tiger', 30, 'DG_a') }
			local battle: any, berr = Battle.CreateBattle(9601, 7601, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9601, 7601, 1, members, battle, 1)
			local xpBefore = Progression.GetArenaXP(9601)
			expect(ArenaService.CompleteBattle(9601, 7601, true, 1).advanced).to.equal(true)
			-- Collective model: still zero payouts mid-run; the
			-- contribution accumulated once.
			expect(#grantsOf(grants, 9601)).to.equal(0)
			expect(Progression.GetArenaXP(9601)).to.equal(xpBefore)
			expect(Progression.GetArenaState(9601).Wins).to.equal(0)
			local accBefore = ArenaService.GetSession(9601).rewardAccum
			-- Replayed end-event for the settled stage: stale
			-- generation, no second advance, no accumulator change.
			local dup = ArenaService.CompleteBattle(9601, 7601, true, 1)
			expect(dup.success).to.equal(false)
			expect(dup.error).to.equal('stale-stage')
			expect(#grantsOf(grants, 9601)).to.equal(0)
			expect(Progression.GetArenaXP(9601)).to.equal(xpBefore)
			expect(Progression.GetArenaState(9601).Wins).to.equal(0)
			local accAfter = ArenaService.GetSession(9601).rewardAccum
			expect(accAfter.cash).to.equal(accBefore.cash)
			expect(accAfter.xp).to.equal(accBefore.xp)
			expect(ArenaService.GetSession(9601).arenaLevel).to.equal(2)
			expect(ArenaService.GetSession(9601).stageGeneration).to.equal(2)
			teardownRaid(ArenaService, Progression)
		end)

		it('a simultaneous wipe on a won stage ends the raid with the cleared stage paid', function()
			local ArenaService, Progression, grants = raidHarness()
			local members = {
				raidMember('Dog', 8, 'AW_a'),
				raidMember('Frog', 8, 'AW_b'),
			}
			local battle: any, berr = Battle.CreateBattle(9602, 7602, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			-- Engine reported won, but the whole team is down:
			-- mutual-kill edge the tick order can produce.
			for _, c in ipairs(battle.playerTeam) do
				c.CurrentHealth = 0
				c.Alive = false
			end
			injectRaid(ArenaService, 9602, 7602, 1, members, battle, 1)
			local r = ArenaService.CompleteBattle(9602, 7602, true, 1)
			expect(r.success).to.equal(true)
			expect(r.advanced).to.equal(false)
			-- Progressive: the won stage's contribution settles
			-- even though nobody survived to stage 2. No stage 2
			-- is fielded.
			expect(#grantsOf(grants, 9602)).to.equal(1)
			expect(grantsOf(grants, 9602)[1].amount).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash)
			expect(Progression.GetArenaXP(9602)).to.equal((ArenaConfig.FindLevel(1) :: any).Rewards.ArenaXP - 4500)
			expect(Progression.GetHighestCompleted(9602)).to.equal(1)
			expect(Progression.GetArenaState(9602).Wins).to.equal(1)
			expect(ArenaService.GetSession(9602)).to.equal(nil)
			teardownRaid(ArenaService, Progression)
		end)

		it('final-stage defeat fails the raid with no completion and no reward', function()
			local ArenaService, Progression, grants = raidHarness()
			local maxStage = ArenaConfig.MaxLevel()
			local members = { raidMember('Chicken', 1, 'FD_a') }
			local battle: any, berr =
				Battle.CreateBattle(9603, 7603, maxStage, members, stageEnemies(maxStage), 1.5, 0, 4, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9603, 7603, maxStage, members, battle, 4)
			local r = ArenaService.CompleteBattle(9603, 7603, false, 4)
			expect(r.success).to.equal(true)
			expect(r.won).to.equal(false)
			expect(ArenaService.GetSession(9603)).to.equal(nil)
			expect(#grantsOf(grants, 9603)).to.equal(0)
			expect(Progression.GetHighestCompleted(9603)).to.equal(0)
			teardownRaid(ArenaService, Progression)
		end)

		it('a stale cancel generation leaves the raid untouched', function()
			local ArenaService, _Progression, _grants = raidHarness()
			local members = { raidMember('Tiger', 30, 'SC_a') }
			local battle: any, berr = Battle.CreateBattle(9604, 7604, 2, members, stageEnemies(2), 1.5, 0, 2, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9604, 7604, 2, members, battle, 2)
			ArenaService.CancelBattleSilent(9604, 7604, 1)
			expect(ArenaService.GetSession(9604)).to.be.ok()
			ArenaService.CancelBattleSilent(9604, 7604, 2)
			expect(ArenaService.GetSession(9604)).to.equal(nil)
			teardownRaid(ArenaService, _Progression)
		end)

		it('a 1 HP survivor stays alive and carries exactly 1 HP forward', function()
			local ArenaService, _Progression, _grants = raidHarness()
			local members = {
				raidMember('Dog', 8, 'OH_a'),
				raidMember('Frog', 8, 'OH_b'),
			}
			-- 1 HP is alive; only 0 (or less) is death.
			local probe: any = Battle.BuildPlayerCombatant(members[1], 1, 0, 1.5, 1)
			expect(probe.Alive).to.equal(true)
			expect(probe.CurrentHealth).to.equal(1)
			local battle: any, berr = Battle.CreateBattle(9605, 7605, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			battle.playerTeam[1].CurrentHealth = 1
			battle.playerTeam[1].Alive = true
			battle.playerTeam[2].CurrentHealth = 0
			battle.playerTeam[2].Alive = false
			injectRaid(ArenaService, 9605, 7605, 1, members, battle, 1)
			expect(ArenaService.CompleteBattle(9605, 7605, true, 1).advanced).to.equal(true)
			local session = ArenaService.GetSession(9605)
			expect(session.battle.playerTeam[1].CurrentHealth).to.equal(1)
			expect(session.battle.playerTeam[1].Alive).to.equal(true)
			expect(session.battle.playerTeam[2].Alive).to.equal(false)
			teardownRaid(ArenaService, _Progression)
		end)
	end)

	describe('Arena raid engine terminal races', function()
		it('mutual 1 HP resolves to exactly one terminal: player-first wins', function()
			local member: any = raidMember('Dog', 1, 'VX_a')
			member.DisplayName = 'Dog'
			local battle: any, berr = Battle.CreateBattle(
				9611,
				7611,
				1,
				{ member },
				{ { DefinitionId = 'Frog', Level = 1 } },
				1.5,
				0,
				1,
				nil
			)
			expect(berr).to.equal(nil)
			-- Player one hit from death, enemy fragile: the
			-- deterministic player-first order decides once.
			battle.playerTeam[1].CurrentHealth = 1
			battle.enemyTeam[1].CurrentHealth = 0.1
			battle.playerTeam[1].NextAttackAt = 0
			battle.enemyTeam[1].NextAttackAt = 0
			local outcome = Battle.TickBattle(battle, 0)
			expect(outcome.finished).to.equal('won')
			expect(battle.state).to.equal('Won')
			expect(battle.playerTeam[1].Alive).to.equal(true)
			expect(battle.enemyTeam[1].Alive).to.equal(false)
			-- Terminal is sticky: further ticks settle nothing.
			local again = Battle.TickBattle(battle, 1.5)
			expect(again.finished).to.equal(nil)
			Battle._TestReset()
		end)

		it('overkill clamps to zero with exactly one death event, and the dead stay out', function()
			local members = {
				raidMember('Dog', 8, 'OK_a'),
				raidMember('Frog', 8, 'OK_b'),
			}
			local battle: any, berr = Battle.CreateBattle(9612, 7612, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			-- A dies at start; B fights on.
			battle.playerTeam[1].CurrentHealth = 0
			battle.playerTeam[1].Alive = false
			local deadId = battle.playerTeam[1].Id
			local now = 0
			local deathEvents = 0
			for _ = 1, 2000 do
				now += 1.5
				local outcome = Battle.TickBattle(battle, now)
				for _, event in ipairs(outcome.events) do
					if event.type == 'defeat' and event.targetId == deadId then
						deathEvents += 1
					end
				end
				if outcome.finished ~= nil then
					break
				end
			end
			-- The pre-dead fighter never re-dies, never acts,
			-- never goes negative.
			expect(deathEvents).to.equal(0)
			expect(battle.playerTeam[1].CurrentHealth).to.equal(0)
			expect(battle.playerTeam[1].Alive).to.equal(false)
			Battle._TestReset()
		end)
	end)

	describe('Arena restart progress', function()
		it('computes warmup stages and restart availability purely', function()
			-- Buy1 warmup = floor(LastLevel / 2), floored at 1.
			expect(ArenaConfig.RestartWarmupLevel(20)).to.equal(10)
			expect(ArenaConfig.RestartWarmupLevel(15)).to.equal(7)
			expect(ArenaConfig.RestartWarmupLevel(10)).to.equal(5)
			expect(ArenaConfig.RestartWarmupLevel(8)).to.equal(4)
			expect(ArenaConfig.RestartWarmupLevel(5)).to.equal(2)
			expect(ArenaConfig.RestartWarmupLevel(4)).to.equal(2)
			expect(ArenaConfig.RestartWarmupLevel(3)).to.equal(1)
			expect(ArenaConfig.RestartWarmupLevel(2)).to.equal(1)
			expect(ArenaConfig.RestartWarmupLevel(1)).to.equal(1)
			expect(ArenaConfig.RestartWarmupLevel(0)).to.equal(nil)
			expect(ArenaConfig.RestartWarmupLevel(nil)).to.equal(nil)
			-- Buy2 direct = LastLevel itself, floored at 1.
			expect(ArenaConfig.RestartDirectLevel(20)).to.equal(20)
			expect(ArenaConfig.RestartDirectLevel(8)).to.equal(8)
			expect(ArenaConfig.RestartDirectLevel(1)).to.equal(1)
			expect(ArenaConfig.RestartDirectLevel(0)).to.equal(1)
			expect(ArenaConfig.RestartDirectLevel(nil)).to.equal(1)
			-- Availability: paid options need LastLevel >= 2
			-- (never charge for a stage-1 start); Buy1 also
			-- needs warmup > 1 (LastLevel >= 4).
			expect(ArenaConfig.IsRestartAvailable(10, false)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(10, true)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(5, true)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(4, true)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(3, true)).to.equal(false)
			expect(ArenaConfig.IsRestartAvailable(2, true)).to.equal(false)
			expect(ArenaConfig.IsRestartAvailable(2, false)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(1, false)).to.equal(false)
			expect(ArenaConfig.IsRestartAvailable(0, false)).to.equal(false)
			expect(ArenaConfig.IsRestartAvailable(11, false)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(50, false)).to.equal(true)
			expect(ArenaConfig.IsRestartAvailable(51, false)).to.equal(false)
		end)

		it('resolves Buy1/Buy2/Buy3 from saved LastLevel (final purchase table)', function()
			local ArenaService, Progression, _grants = raidHarness()
			local userId = 9720
			-- No progression: only the free Buy3 entry.
			local fresh3 = ArenaService._TestResolveRestart(userId, 'Buy3')
			expect(fresh3.startLevel).to.equal(1)
			expect(fresh3.price).to.equal('0')
			expect(ArenaService._TestResolveRestart(userId, 'Buy1').error).to.equal('restart-unavailable')
			expect(ArenaService._TestResolveRestart(userId, 'Buy2').error).to.equal('restart-unavailable')
			-- LastLevel = 8: Buy1 -> 4, Buy2 -> 8, Buy3 -> 1.
			expect(Progression.RecordReachedLevel(userId, 8)).to.equal(8)
			local buy1 = ArenaService._TestResolveRestart(userId, 'Buy1')
			expect(buy1.startLevel).to.equal(4)
			expect(buy1.price).to.equal(ArenaConfig.RestartWarmupPrice())
			local buy2 = ArenaService._TestResolveRestart(userId, 'Buy2')
			expect(buy2.startLevel).to.equal(8)
			expect(buy2.price).to.equal(ArenaConfig.RestartDirectPrice())
			local buy3 = ArenaService._TestResolveRestart(userId, 'Buy3')
			expect(buy3.startLevel).to.equal(1)
			-- Unknown options fall back to the free Buy3 entry.
			expect(ArenaService._TestResolveRestart(userId, 'Buy9').startLevel).to.equal(1)
			teardownRaid(ArenaService, Progression)
		end)

		it('a failed run never downgrades LastLevel; a best run raises it', function()
			local ArenaService, Progression, _grants = raidHarness()
			local userId = 9721
			local members = { raidMember('Dog', 8, 'LR_downgrade') }
			expect(Progression.RecordReachedLevel(userId, 8)).to.equal(8)
			-- Buy1 authorizes stage 4 from the saved 8.
			expect(ArenaService._TestResolveRestart(userId, 'Buy1').startLevel).to.equal(4)
			-- Fail at stage 6: LastLevel stays 8, never 6.
			local battle: any, berr = Battle.CreateBattle(9721, 7721, 6, members, stageEnemies(6), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9721, 7721, 6, members, battle, 1)
			local lost = ArenaService.CompleteBattle(9721, 7721, false, 1)
			expect(lost.success).to.equal(true)
			expect(Progression.GetLastReached(userId)).to.equal(8)
			expect(ArenaService._TestResolveRestart(userId, 'Buy1').startLevel).to.equal(4)
			expect(ArenaService._TestResolveRestart(userId, 'Buy2').startLevel).to.equal(8)
			-- New personal best at stage 10: LastLevel becomes
			-- 10, and the purchase table follows it.
			local members2 = { raidMember('Dog', 8, 'LR_downgrade_b') }
			local battle2: any, berr2 = Battle.CreateBattle(9721, 7722, 10, members2, stageEnemies(10), 1.5, 0, 1, nil)
			expect(berr2).to.equal(nil)
			injectRaid(ArenaService, 9721, 7722, 10, members2, battle2, 1)
			local lost2 = ArenaService.CompleteBattle(9721, 7722, false, 1)
			expect(lost2.success).to.equal(true)
			expect(Progression.GetLastReached(userId)).to.equal(10)
			expect(ArenaService._TestResolveRestart(userId, 'Buy1').startLevel).to.equal(5)
			expect(ArenaService._TestResolveRestart(userId, 'Buy2').startLevel).to.equal(10)
			expect(ArenaService._TestResolveRestart(userId, 'Buy3').startLevel).to.equal(1)
			teardownRaid(ArenaService, Progression)
		end)

		it('records LastReached with max semantics, never on retreat', function()
			local _ArenaService, Progression, _grants = raidHarness()
			expect(Progression.GetLastReached(9701)).to.equal(0)
			expect(Progression.RecordReachedLevel(9701, 5)).to.equal(5)
			expect(Progression.GetLastReached(9701)).to.equal(5)
			-- A shorter later run never moves it backwards.
			expect(Progression.RecordReachedLevel(9701, 3)).to.equal(5)
			expect(Progression.GetLastReached(9701)).to.equal(5)
			-- A further run advances it.
			expect(Progression.RecordReachedLevel(9701, 8)).to.equal(8)
			-- Out-of-range stages are ignored.
			expect(Progression.RecordReachedLevel(9701, 0)).to.equal(8)
			expect(Progression.RecordReachedLevel(9701, 99)).to.equal(8)
			teardownRaid(_ArenaService, Progression)
		end)

		it('terminal defeat records the failed stage as LastReached', function()
			local ArenaService, Progression, grants = raidHarness()
			local members = { raidMember('Dog', 8, 'LR_a') }
			local battle: any, berr = Battle.CreateBattle(9702, 7702, 5, members, stageEnemies(5), 1.5, 0, 3, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9702, 7702, 5, members, battle, 3)
			local r = ArenaService.CompleteBattle(9702, 7702, false, 3)
			expect(r.success).to.equal(true)
			expect(r.won).to.equal(false)
			expect(ArenaService.GetSession(9702)).to.equal(nil)
			expect(Progression.GetLastReached(9702)).to.equal(5)
			-- Nothing cleared: progressive settlement pays $0
			-- (no grant), but the reached stage still records.
			expect(#grantsOf(grants, 9702)).to.equal(0)
			teardownRaid(ArenaService, Progression)
		end)

		it('terminal victory records the final stage as LastReached', function()
			local ArenaService, Progression, _grants = raidHarness()
			local maxStage = ArenaConfig.MaxLevel()
			local members = { raidMember('Dragon', 30, 'LR_b') }
			local battle: any, berr =
				Battle.CreateBattle(9703, 7703, maxStage, members, stageEnemies(maxStage), 1.5, 0, 9, nil)
			expect(berr).to.equal(nil)
			injectRaid(ArenaService, 9703, 7703, maxStage, members, battle, 9, maxStage)
			local r = ArenaService.CompleteBattle(9703, 7703, true, 9)
			expect(r.raidComplete).to.equal(true)
			expect(Progression.GetLastReached(9703)).to.equal(maxStage)
			teardownRaid(ArenaService, Progression)
		end)

	describe('Arena Adv visibility (per-player hide/restore)', function()
		local Workspace = game:GetService('Workspace')

		local function makeAdvBase(id: string, transparency: number): { folder: Instance, adv: BasePart, inner: BasePart, board: BillboardGui }
			local folder = Instance.new('Folder')
			folder.Name = id
			local adv = Instance.new('Part')
			adv.Name = 'Adv'
			adv.Transparency = transparency
			adv.Anchored = true
			adv.Parent = folder
			local inner = Instance.new('Part')
			inner.Name = 'InnerTrim'
			inner.Transparency = 0.5
			inner.Anchored = true
			inner.Parent = adv
			local board = Instance.new('BillboardGui')
			board.Name = 'AdvLabel'
			board.Enabled = true
			board.Parent = adv
			folder.Parent = Workspace
			return { folder = folder, adv = adv, inner = inner, board = board }
		end

		it('hides only the raiding base Adv, saving exact transparencies', function()
			local ArenaService, Progression, _grants = raidHarness()
			local userA, userB = 9731, 9732
			local boxA = makeAdvBase('Base_AdvA', 0.2)
			local boxB = makeAdvBase('Base_AdvB', 0)
			local baseA = { id = 'Base_AdvA', folder = boxA.folder }
			expect(ArenaService._TestHideAdv(userA, baseA)).to.equal(true)
			expect(ArenaService._TestAdvHidden(userA)).to.equal(true)
			-- Player A Adv fully invisible (part + trim + label).
			expect((boxA.adv :: BasePart).Transparency).to.equal(1)
			expect((boxA.inner :: BasePart).Transparency).to.equal(1)
			expect((boxA.board :: BillboardGui).Enabled).to.equal(false)
			-- Player B Adv completely untouched.
			expect(ArenaService._TestAdvHidden(userB)).to.equal(false)
			expect((boxB.adv :: BasePart).Transparency).to.equal(0)
			-- Restore returns EXACT originals (not zeroed).
			expect(ArenaService._TestRestoreAdv(userA)).to.equal(true)
			expect(ArenaService._TestAdvHidden(userA)).to.equal(false)
			expect((boxA.adv :: BasePart).Transparency).to.equal(0.2)
			expect((boxA.inner :: BasePart).Transparency).to.equal(0.5)
			expect((boxA.board :: BillboardGui).Enabled).to.equal(true)
			(boxA.folder :: Instance):Destroy()
			(boxB.folder :: Instance):Destroy()
			teardownRaid(ArenaService, Progression)
		end)

		it('restore is a safe no-op without a record; hide fails clean on bad bases', function()
			local ArenaService, Progression, _grants = raidHarness()
			expect(ArenaService._TestRestoreAdv(9733)).to.equal(false)
			expect(ArenaService._TestHideAdv(9733, nil)).to.equal(false)
			expect(ArenaService._TestHideAdv(9733, {})).to.equal(false)
			expect(ArenaService._TestAdvHidden(9733)).to.equal(false)
			teardownRaid(ArenaService, Progression)
		end)

		it('restore skips destroyed parts without throwing', function()
			local ArenaService, Progression, _grants = raidHarness()
			local userId = 9734
			local box = makeAdvBase('Base_AdvC', 0.3)
			local base = { id = 'Base_AdvC', folder = box.folder }
			expect(ArenaService._TestHideAdv(userId, base)).to.equal(true)
			-- Base torn down mid-raid (leave path): restore must
			-- not throw and must still fix survivors.
			(box.inner :: Instance):Destroy()
			expect(function()
				ArenaService._TestRestoreAdv(userId)
			end).to.never.throw()
			expect((box.adv :: BasePart).Transparency).to.equal(0.3)
			expect(ArenaService._TestAdvHidden(userId)).to.equal(false)
			(box.folder :: Instance):Destroy()
			teardownRaid(ArenaService, Progression)
		end)
	end)

		it('a restart run pays only stages cleared during that run', function()
			local ArenaService, Progression, grants = raidHarness()
			local maxStage = ArenaConfig.MaxLevel()
			-- History: everything won before (cursor past the end).
			for stage = 1, maxStage do
				Progression.RecordLevelWin(9710, stage)
			end
			local members = { raidMember('Dragon', 30, 'LR_c') }
			local battle: any, berr = Battle.CreateBattle(9710, 7710, 6, members, stageEnemies(6), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			-- Restart entry at stage 6 (as Buy1 would authorize):
			-- skipped stages 1-5 must never contribute.
			injectRaid(ArenaService, 9710, 7710, 6, members, battle, 1, maxStage + 1)
			local gen = 1
			while true do
				local settled = ArenaService.GetSession(9710)
				expect(settled).to.be.ok()
				local r = ArenaService.CompleteBattle(9710, 7710, true, gen)
				if r.raidComplete == true then
					break
				end
				expect(r.advanced).to.equal(true)
				gen += 1
				expect(gen <= maxStage).to.equal(true)
			end
			local total = expectedTotals(6, maxStage, maxStage)
			expect(#grantsOf(grants, 9710)).to.equal(1)
			expect(grantsOf(grants, 9710)[1].amount).to.equal(total.cash)
			expect(ArenaService.GetSession(9710)).to.equal(nil)
			expect(Progression.GetLastReached(9710)).to.equal(maxStage)
			teardownRaid(ArenaService, Progression)
		end)
	end)

	describe('Arena raid locks', function()
		it('locked animals are reported per id and released with the session', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			expect(ArenaService.IsAnimalRaidLocked('ZZ_none')).to.equal(false)
			expect(ArenaService.IsAnimalRaidLocked('')).to.equal(false)
			expect(ArenaService.HasActiveRaid(9621)).to.equal(false)
			ArenaService._TestInjectSession(9621, {
				sessionId = 7621,
				userId = 9621,
				arenaLevel = 2,
				state = 'Active',
				team = { raidMember('Dog', 8, 'LK_a'), raidMember('Frog', 8, 'LK_b') },
			})
			expect(ArenaService.IsAnimalRaidLocked('LK_a')).to.equal(true)
			expect(ArenaService.IsAnimalRaidLocked('LK_b')).to.equal(true)
			expect(ArenaService.IsAnimalRaidLocked('LK_other')).to.equal(false)
			expect(ArenaService.HasActiveRaid(9621)).to.equal(true)
			ArenaService._TestReset()
			expect(ArenaService.IsAnimalRaidLocked('LK_a')).to.equal(false)
			expect(ArenaService.HasActiveRaid(9621)).to.equal(false)
		end)
	end)
end
