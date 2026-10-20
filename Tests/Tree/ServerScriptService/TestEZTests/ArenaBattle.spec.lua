--!strict
--!native
--[[
	ArenaBattle.spec
	=================
	Headless coverage for Arena combat V1: config rosters +
	validation, canonical combatant stats (10:1 invariant,
	multiplier math), deterministic targeting, full battle
	simulation to win AND loss, session isolation, and
	exactly-once reward settlement (stale + duplicate end
	events). Live players are never needed: the battle engine
	takes userId numbers and the settle path resolves players
	lazily (nil-safe headless).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')

	local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)
	local AnimalStats = require(ReplicatedStorage.Utility.AnimalStats)
	local Battle = require(ServerScriptService.Arena.ArenaBattleService)

	local function canonical(defId: string, level: number, stat: string): number
		return AnimalStats.Calculate({ DefId = defId, Level = level }, stat)
	end

	local function closeEnough(a: number, b: number): boolean
		return math.abs(a - b) < 1e-6
	end

	local function playerMember(defId: string, level: number, uniqueId: string?): any
		return {
			UniqueId = uniqueId or ('AN_' .. defId),
			DefinitionId = defId,
			DisplayName = defId,
			Rarity = 'Common',
			Level = level,
		}
	end

	local function runToEnd(battle: any, cooldown: number): string?
		local now = 1000
		local ticks = 0
		while (battle :: any).state == 'Active' and ticks < 5000 do
			now += cooldown
			local outcome = Battle.TickBattle(battle, now)
			if outcome.finished ~= nil then
				return outcome.finished
			end
			ticks += 1
		end
		return nil
	end

	describe('ArenaBattleService combatants', function()
		it('builds player combatants from canonical stats (10:1)', function()
			local member = playerMember('Tiger', 5, 'AN_t500')
			local c: any, err = Battle.BuildPlayerCombatant(member, 1, 0, 1.5)
			expect(err).to.equal(nil)
			expect(c).to.be.ok()
			expect(c.MaxHealth).to.equal(canonical('Tiger', 5, 'Health'))
			expect(c.Damage).to.equal(canonical('Tiger', 5, 'Damage'))
			expect(c.CurrentHealth).to.equal(c.MaxHealth)
			expect(closeEnough(c.Damage * 10, c.MaxHealth)).to.equal(true)
			expect(c.SourceAnimalId).to.equal('AN_t500')
			expect(c.Team).to.equal('Player')
			expect(c.IsBoss).to.equal(false)
			expect(c.Alive).to.equal(true)
			-- Member table untouched (no persistent mutation).
			expect(member.Level).to.equal(5)
		end)

		it('builds enemy combatants with multiplier on health, damage derived', function()
			local c: any, err =
				Battle.BuildEnemyCombatant({ DefinitionId = 'Spider', Level = 20, StatMultiplier = 1.25 }, 1, 0, 1.5)
			expect(err).to.equal(nil)
			expect(c).to.be.ok()
			expect(c.MaxHealth).to.equal(canonical('Spider', 20, 'Health') * 1.25)
			expect(c.Damage).to.equal(c.MaxHealth / 10)
			expect(closeEnough(c.Damage * 10, c.MaxHealth)).to.equal(true)
			expect(c.SourceAnimalId).to.equal(nil)
			expect(c.Team).to.equal('Enemy')
		end)

		it('defaults a missing multiplier to 1 and flags bosses', function()
			local c: any, err = Battle.BuildEnemyCombatant(
				{ DefinitionId = 'Dragon', Level = 25, StatMultiplier = 2.5, IsBoss = true },
				1,
				0,
				1.5
			)
			expect(err).to.equal(nil)
			expect(c.IsBoss).to.equal(true)
			expect(c.MaxHealth).to.equal(canonical('Dragon', 25, 'Health') * 2.5)
		end)

		it('snapshots identity without touching combat stats', function()
			local member = playerMember('Tiger', 5, 'AN_snap')
			member.Rarity = 'Mythic'
			member.Trait = 'Swift'
			member.Mutations = { 'Golden', 'Giant' }
			member.OwnerUserId = 4242
			local c: any, err = Battle.BuildPlayerCombatant(member, 1, 0, 1.5)
			expect(err).to.equal(nil)
			expect(c.Trait).to.equal('Swift')
			expect(#c.Mutations).to.equal(2)
			expect(c.Rarity).to.equal('Mythic')
			expect(c.OwnerUserId).to.equal(4242)
			-- Stats stay canonical: identity never feeds math.
			expect(c.MaxHealth).to.equal(canonical('Tiger', 5, 'Health'))
			expect(c.Damage).to.equal(canonical('Tiger', 5, 'Damage'))
		end)

		it('player team attacks before enemies on tied ticks', function()
			local battle: any, berr = Battle.CreateBattle(
				11,
				21,
				1,
				{ playerMember('Dragon', 25, 'AN_first') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				100
			)
			expect(berr).to.equal(nil)
			-- Sequential turns: the opening turn belongs to Player,
			-- and each tick executes at most one attack.
			local outcome = Battle.TickBattle(battle, 101.5)
			expect(#outcome.events > 0).to.equal(true)
			expect(outcome.events[1].type).to.equal('attack')
			expect(outcome.events[1].attackerTeam).to.equal('Player')
			local attacks = 0
			for _, event in ipairs(outcome.events) do
				if event.type == 'attack' then
					attacks += 1
				end
			end
			expect(attacks).to.equal(1)
			local anim = outcome.events[1].attackAnimation
			expect(anim >= 1 and anim <= 5).to.equal(true)
		end)

		it('rejects bad combatant inputs without building', function()
			expect(Battle.BuildPlayerCombatant(nil, 1, 0, 1.5)).to.equal(nil)
			local _, e1 = Battle.BuildPlayerCombatant(playerMember('Nope', 5), 1, 0, 1.5)
			expect(e1).to.be.ok()
			local _, e2 = Battle.BuildEnemyCombatant({ DefinitionId = 'Dog', Level = 0 }, 1, 0, 1.5)
			expect(e2).to.be.ok()
			local _, e3 =
				Battle.BuildEnemyCombatant({ DefinitionId = 'Dog', Level = 3, StatMultiplier = -2 }, 1, 0, 1.5)
			expect(e3).to.be.ok()
			local _, e4 = Battle.CreateBattle(1, 1, 1, {}, { { DefinitionId = 'Dog', Level = 1 } }, 1.5, 0)
			expect(e4).to.equal('empty-player-team')
			local _, e5 = Battle.CreateBattle(1, 1, 1, { playerMember('Dog', 1) }, {}, 1.5, 0)
			expect(e5).to.equal('empty-enemy-team')
		end)
	end)

	describe('ArenaBattleService targeting', function()
		it('maps front-to-front and falls back to first alive, never dead', function()
			local battle: any, err = Battle.CreateBattle(
				11,
				101,
				1,
				{ playerMember('Dog', 30), playerMember('Frog', 30), playerMember('Tiger', 30) },
				{ { DefinitionId = 'Spider', Level = 1 }, { DefinitionId = 'Frog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local function targetId(attacker: any): string?
				local target: any = Battle.PickTarget(battle, attacker)
				if target == nil then
					return nil
				end
				return target.Id
			end
			-- P1 -> E1, P2 -> E2, P3 wraps to E1 (first alive).
			expect(targetId(battle.playerTeam[1])).to.equal(battle.enemyTeam[1].Id)
			expect(targetId(battle.playerTeam[2])).to.equal(battle.enemyTeam[2].Id)
			expect(targetId(battle.playerTeam[3])).to.equal(battle.enemyTeam[1].Id)
			-- Kill E1: everyone retargets to E2, never the corpse.
			battle.enemyTeam[1].Alive = false
			battle.enemyTeam[1].CurrentHealth = 0
			expect(targetId(battle.playerTeam[1])).to.equal(battle.enemyTeam[2].Id)
			expect(targetId(battle.playerTeam[3])).to.equal(battle.enemyTeam[2].Id)
			-- All dead: nil, never stuck.
			battle.enemyTeam[2].Alive = false
			battle.enemyTeam[2].CurrentHealth = 0
			expect(targetId(battle.playerTeam[1])).to.equal(nil)
		end)
	end)

	describe('ArenaBattleService full battles', function()
		it('a strong team beats level-1 enemies (win, enemies dealt damage)', function()
			local battle: any, err = Battle.CreateBattle(
				21,
				201,
				1,
				{ playerMember('Tiger', 30), playerMember('Dragon', 30) },
				{ { DefinitionId = 'Dog', Level = 1 }, { DefinitionId = 'Frog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local playerHpBefore = battle.playerTeam[1].MaxHealth + battle.playerTeam[2].MaxHealth
			local result = runToEnd(battle, 1.5)
			expect(result).to.equal('won')
			expect(battle.state).to.equal('Won')
			for _, foe in ipairs(battle.enemyTeam) do
				expect(foe.Alive).to.equal(false)
				expect(foe.CurrentHealth).to.equal(0)
			end
			-- Enemies acted before dying (player team took damage).
			local playerHpAfter = battle.playerTeam[1].CurrentHealth + battle.playerTeam[2].CurrentHealth
			expect(playerHpAfter < playerHpBefore).to.equal(true)
		end)

		it('a weak team loses quickly (no reward path here)', function()
			local battle: any, err = Battle.CreateBattle(
				22,
				202,
				10,
				{ playerMember('Chicken', 1) },
				{ { DefinitionId = 'Dog', Level = 1 }, { DefinitionId = 'Frog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local result = runToEnd(battle, 1.5)
			expect(result).to.equal('lost')
			expect(battle.state).to.equal('Lost')
			expect(battle.playerTeam[1].Alive).to.equal(false)
			-- Dead combatants never act again: extra ticks change nothing.
			local hp = battle.enemyTeam[1].CurrentHealth
			Battle.TickBattle(battle, 99999)
			expect(battle.enemyTeam[1].CurrentHealth).to.equal(hp)
		end)

		it('two battles tick in complete isolation', function()
			local a: any, _ = Battle.CreateBattle(
				31,
				301,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			local b: any, _ = Battle.CreateBattle(
				32,
				302,
				1,
				{ playerMember('Chicken', 1) },
				{ { DefinitionId = 'Dragon', Level = 5 } },
				1.5,
				0
			)
			expect(a).to.be.ok()
			expect(b).to.be.ok()
			expect(runToEnd(a, 1.5)).to.equal('won')
			expect(runToEnd(b, 1.5)).to.equal('lost')
			Battle._TestReset()
		end)

		it('a 3v3 battle resolves to exactly one terminal outcome', function()
			local battle: any, err = Battle.CreateBattle(
				33,
				303,
				7,
				{ playerMember('Tiger', 30), playerMember('Dragon', 30), playerMember('Bear', 30) },
				{
					{ DefinitionId = 'Gorilla', Level = 10 },
					{ DefinitionId = 'Bear', Level = 10 },
					{
						DefinitionId = 'Tiger',
						Level = 10,
					},
				},
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local result = runToEnd(battle, 1.5)
			expect(result == 'won' or result == 'lost').to.equal(true)
			expect(battle.state == 'Won' or battle.state == 'Lost').to.equal(true)
			-- Losers are all dead at zero; winners keep at least one alive.
			local losers = if result == 'won' then battle.enemyTeam else battle.playerTeam
			local winners = if result == 'won' then battle.playerTeam else battle.enemyTeam
			for _, c in ipairs(losers) do
				expect(c.Alive).to.equal(false)
				expect(c.CurrentHealth).to.equal(0)
			end
			local anyAlive = false
			for _, c in ipairs(winners) do
				if c.Alive == true and c.CurrentHealth > 0 then
					anyAlive = true
				end
				expect(c.CurrentHealth >= 0).to.equal(true)
			end
			expect(anyAlive).to.equal(true)
			-- Terminal is sticky: further ticks change nothing.
			local snapshot: { number } = {}
			for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
				for _, c in ipairs(team) do
					snapshot[#snapshot + 1] = c.CurrentHealth
				end
			end
			Battle.TickBattle(battle, 99999)
			local i = 1
			for _, team in ipairs({ battle.playerTeam, battle.enemyTeam }) do
				for _, c in ipairs(team) do
					expect(c.CurrentHealth).to.equal(snapshot[i])
					i += 1
				end
			end
			Battle._TestReset()
		end)
	end)

	describe('ArenaBattleService combat guarantees', function()
		it('respects attack cooldowns (no double-acting in one window)', function()
			local battle: any, err = Battle.CreateBattle(
				51,
				501,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Tiger', Level = 30 } },
				1.5,
				100
			)
			expect(err).to.equal(nil)
			-- Even matchup: the opening Player turn acts once,
			-- nobody dies.
			local first = Battle.TickBattle(battle, 101.5)
			expect(#first.events > 0).to.equal(true)
			local firstAttacks = 0
			for _, event in ipairs(first.events) do
				if event.type == 'attack' then
					firstAttacks += 1
				end
			end
			expect(firstAttacks).to.equal(1)
			expect(battle.state).to.equal('Active')
			-- Same timestamp: the next turn gates behind
			-- nextTurnAt and must stay silent.
			local second = Battle.TickBattle(battle, 101.5)
			local attacks = 0
			for _, event in ipairs(second.events) do
				if event.type == 'attack' then
					attacks += 1
				end
			end
			expect(attacks).to.equal(0)
			Battle._TestReset()
		end)

		it('rejects NaN cooldowns at creation', function()
			local nan = 0 / 0
			local battle: any, err = Battle.CreateBattle(
				52,
				502,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				nan,
				0
			)
			expect(err).to.equal(nil)
			expect(battle.cooldown).to.equal(1.5)
			Battle._TestReset()
		end)

		it('a dead attacker cannot attack', function()
			local battle: any, err = Battle.CreateBattle(
				53,
				503,
				1,
				{ playerMember('Tiger', 30), playerMember('Dragon', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			battle.playerTeam[1].Alive = false
			battle.playerTeam[1].CurrentHealth = 0
			local outcome = Battle.TickBattle(battle, 1.5)
			for _, event in ipairs(outcome.events) do
				if event.type == 'attack' then
					expect(event.attackerId ~= battle.playerTeam[1].Id).to.equal(true)
				end
			end
			Battle._TestReset()
		end)

		it('dead targets take no further damage and emit no second defeat', function()
			local battle: any, err = Battle.CreateBattle(
				54,
				504,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 }, { DefinitionId = 'Frog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			battle.enemyTeam[1].Alive = false
			battle.enemyTeam[1].CurrentHealth = 0
			local outcome = Battle.TickBattle(battle, 1.5)
			expect(battle.enemyTeam[1].CurrentHealth).to.equal(0)
			for _, event in ipairs(outcome.events) do
				if event.type == 'attack' then
					expect(event.targetId).to.equal(battle.enemyTeam[2].Id)
				end
				if event.type == 'defeat' then
					expect(event.targetId ~= battle.enemyTeam[1].Id).to.equal(true)
				end
			end
			Battle._TestReset()
		end)

		it('NaN and negative damage never corrupt health', function()
			local battle: any, err = Battle.CreateBattle(
				55,
				505,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local before = battle.enemyTeam[1].CurrentHealth
			battle.playerTeam[1].Damage = 0 / 0
			Battle.TickBattle(battle, 1.5)
			expect(battle.enemyTeam[1].CurrentHealth).to.equal(before)
			battle.playerTeam[1].Damage = -50
			battle.playerTeam[1].NextAttackAt = 1.5
			Battle.TickBattle(battle, 1.5)
			expect(battle.enemyTeam[1].CurrentHealth).to.equal(before)
			Battle._TestReset()
		end)

		it('targets always belong to the same battle and opposing team', function()
			local a: any, _ = Battle.CreateBattle(
				56,
				506,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			local b: any, _ = Battle.CreateBattle(
				57,
				507,
				5,
				{ playerMember('Chicken', 1) },
				{ { DefinitionId = 'Dragon', Level = 5 } },
				1.5,
				0
			)
			for _, attacker in ipairs(a.playerTeam) do
				local target: any = Battle.PickTarget(a, attacker)
				expect(target).to.be.ok()
				expect(target.Team).to.equal('Enemy')
				local found = false
				for _, c in ipairs(a.enemyTeam) do
					if c == target then
						found = true
					end
				end
				expect(found).to.equal(true)
			end
			for _, attacker in ipairs(b.enemyTeam) do
				local target: any = Battle.PickTarget(b, attacker)
				expect(target).to.be.ok()
				expect(target.Team).to.equal('Player')
			end
			-- Cross-battle attacker tables are not valid foes:
			-- PickTarget only scans the passed battle's teams.
			local foreign: any = Battle.PickTarget(a, b.playerTeam[1])
			if foreign ~= nil then
				expect(foreign.Team).to.equal('Enemy')
				local found = false
				for _, c in ipairs(a.enemyTeam) do
					if c == foreign then
						found = true
					end
				end
				expect(found).to.equal(true)
			end
			Battle._TestReset()
		end)

		it('attack presentation is a safe no-op without live models', function()
			local battle: any, err = Battle.CreateBattle(
				58,
				508,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			-- No models attached headless: must never throw
			-- (malformed payloads degrade the same way).
			Battle.PresentAttack(battle, {
				attackerId = battle.playerTeam[1].Id,
				targetId = battle.enemyTeam[1].Id,
			})
			Battle.PresentAttack(battle, { attackerId = 'Nope-0-0', targetId = 'Nope-0-1' })
			Battle.PresentAttack(nil :: any, {})
			Battle.PresentDeath(battle, battle.enemyTeam[1].Id)
			Battle._TestReset()
		end)
	end)

	describe('ArenaBattleService turn choreography', function()
		-- Rigged slugfest: a tanky boss enemy that hits for 1,
		-- so the turn SEQUENCE (not the outcome) is asserted
		-- deterministically over many turns.
		local function slugfest(): any
			local battle: any, err = Battle.CreateBattle(61, 601, 1, {
				playerMember('Tiger', 30, 'AN_t1'),
				playerMember('Dragon', 30, 'AN_t2'),
				playerMember('Bear', 30, 'AN_t3'),
			}, { { DefinitionId = 'Dragon', Level = 25, StatMultiplier = 2.5, IsBoss = true } }, 1.5, 0)
			expect(err).to.equal(nil)
			local foe = battle.enemyTeam[1]
			foe.Damage = 1
			foe.CurrentHealth = 1000000
			return battle
		end

		local function attackIds(outcome: any): { string }
			local ids: { string } = {}
			for _, event in ipairs(outcome.events) do
				if type(event) == 'table' and event.type == 'attack' then
					ids[#ids + 1] = event.attackerId
				end
			end
			return ids
		end

		it('alternates Player/Enemy turns from Player, one attack per tick', function()
			local battle = slugfest()
			local p1 = battle.playerTeam[1].Id
			local p2 = battle.playerTeam[2].Id
			local p3 = battle.playerTeam[3].Id
			local e1 = battle.enemyTeam[1].Id
			local now = 0
			local teams: { string } = {}
			local attackers: { string } = {}
			for _ = 1, 8 do
				local outcome = Battle.TickBattle(battle, now)
				local ids = attackIds(outcome)
				expect(#ids).to.equal(1)
				expect(outcome.finished).to.equal(nil)
				teams[#teams + 1] = outcome.events[1].attackerTeam
				attackers[#attackers + 1] = ids[1]
				now += 1.5
			end
			local wantTeams = { 'Player', 'Enemy', 'Player', 'Enemy', 'Player', 'Enemy', 'Player', 'Enemy' }
			for i, want in ipairs(wantTeams) do
				expect(teams[i]).to.equal(want)
			end
			-- Within-side round robin: P1, P2, P3, P1.
			local wantAttackers = { p1, e1, p2, e1, p3, e1, p1, e1 }
			for i, want in ipairs(wantAttackers) do
				expect(attackers[i]).to.equal(want)
			end
			Battle._TestReset()
		end)

		it('skips dead combatants in rotation and never lets them act', function()
			local battle = slugfest()
			local now = 0
			for _ = 1, 3 do
				Battle.TickBattle(battle, now)
				now += 1.5
			end
			-- P1, E, P2 have acted. Kill P2 mid-run.
			local p2id = battle.playerTeam[2].Id
			battle.playerTeam[2].Alive = false
			battle.playerTeam[2].CurrentHealth = 0
			local playerAttackers: { string } = {}
			for _ = 1, 6 do
				local outcome = Battle.TickBattle(battle, now)
				now += 1.5
				for _, id in ipairs(attackIds(outcome)) do
					local attacker: any = nil
					for _, c in ipairs(battle.playerTeam) do
						if c.Id == id then
							attacker = c
							break
						end
					end
					if attacker ~= nil then
						playerAttackers[#playerAttackers + 1] = id
					end
					expect(id == p2id).to.equal(false)
				end
			end
			-- Rotation continues P3 -> P1 -> P3 without P2.
			expect(#playerAttackers).to.equal(3)
			expect(playerAttackers[1]).to.equal(battle.playerTeam[3].Id)
			expect(playerAttackers[2]).to.equal(battle.playerTeam[1].Id)
			expect(playerAttackers[3]).to.equal(battle.playerTeam[3].Id)
			Battle._TestReset()
		end)

		it('cycles sounds 1-2-3 and numbers attacks in event order', function()
			local battle = slugfest()
			local now = 0
			local sounds: { number } = {}
			local seqs: { number } = {}
			for _ = 1, 7 do
				local outcome = Battle.TickBattle(battle, now)
				now += 1.5
				for _, event in ipairs(outcome.events) do
					if type(event) == 'table' and event.type == 'attack' then
						sounds[#sounds + 1] = event.soundIndex
						seqs[#seqs + 1] = event.attackSequence
					end
				end
			end
			expect(#sounds).to.equal(7)
			local wantSounds = { 1, 2, 3, 1, 2, 3, 1 }
			for i, want in ipairs(wantSounds) do
				expect(sounds[i]).to.equal(want)
			end
			for i, seq in ipairs(seqs) do
				expect(seq).to.equal(i)
			end
			-- Headless (no homes): no contact point, never a crash.
			local outcome = Battle.TickBattle(battle, now)
			for _, event in ipairs(outcome.events) do
				if type(event) == 'table' and event.type == 'attack' then
					expect(event.impactPosition).to.equal(nil)
				end
			end
			Battle._TestReset()
		end)

		it('records applied player damage per animal with overkill clamped', function()
			local battle: any, err = Battle.CreateBattle(61, 601, 1, {
				playerMember('Tiger', 30, 'AN_t1'),
				playerMember('Dragon', 30, 'AN_t2'),
			}, { { DefinitionId = 'Dog', Level = 1 } }, 1.5, 0)
			expect(err).to.equal(nil)
			expect(type(battle.damageBySource) == 'table').to.equal(true)
			-- Rig: player hits for 25, enemy survives with 10 HP so
			-- the killing blow overkills by 15.
			battle.playerTeam[1].Damage = 25
			battle.playerTeam[2].Damage = 25
			battle.enemyTeam[1].CurrentHealth = 10
			battle.enemyTeam[1].MaxHealth = 10
			battle.enemyTeam[1].Damage = 1
			local now = 0
			Battle.TickBattle(battle, now)
			-- Applied = 10 (remaining HP), not 25.
			expect(battle.damageBySource.AN_t1).to.equal(10)
			expect(battle.enemyTeam[1].Alive).to.equal(false)
			Battle._TestReset()
		end)

		it('emits animation indices 1-5 with no immediate repeats', function()
			local battle = slugfest()
			local now = 0
			local anims: { number } = {}
			for _ = 1, 10 do
				local outcome = Battle.TickBattle(battle, now)
				now += 1.5
				for _, event in ipairs(outcome.events) do
					if type(event) == 'table' and event.type == 'attack' then
						local anim = event.attackAnimation
						expect(type(anim) == 'number' and anim >= 1 and anim <= 5).to.equal(true)
						anims[#anims + 1] = anim
					end
				end
			end
			expect(#anims).to.equal(10)
			for i = 2, #anims do
				expect(anims[i] ~= anims[i - 1]).to.equal(true)
			end
			local distinct: { [number]: boolean } = {}
			for _, anim in ipairs(anims) do
				distinct[anim] = true
			end
			local count = 0
			for _ in pairs(distinct) do
				count += 1
			end
			expect(count >= 2).to.equal(true)
			Battle._TestReset()
		end)

		it('attack animations restore the canonical pivot for all five', function()
			local Workspace = game:GetService('Workspace')
			local battle: any, err = Battle.CreateBattle(
				62,
				602,
				1,
				{ playerMember('Tiger', 30, 'AN_p1') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local function livePart(name: string, pos: Vector3): (Model, BasePart)
				local model = Instance.new('Model')
				model.Name = name
				local root = Instance.new('Part')
				root.Name = 'HumanoidRootPart'
				root.Size = Vector3.new(2, 2, 2)
				root.Anchored = true
				root.CFrame = CFrame.new(pos)
				root.Parent = model
				model.PrimaryPart = root
				model.Parent = Workspace
				return model, root
			end
			local model, _ = livePart('AtkSpec', Vector3.new(0, 5, 0))
			local foe, _ = livePart('AtkFoe', Vector3.new(12, 5, 0))
			battle.playerTeam[1].Model = model
			battle.playerTeam[1].HomeCFrame = model:GetPivot()
			battle.enemyTeam[1].Model = foe
			battle.enemyTeam[1].HomeCFrame = foe:GetPivot()
			local home = battle.playerTeam[1].HomeCFrame
			for anim = 1, 5 do
				local impact = Battle.PresentAttack(battle, {
					attackerId = battle.playerTeam[1].Id,
					targetId = battle.enemyTeam[1].Id,
					attackAnimation = anim,
					soundIndex = 1,
					damage = 10,
					attackSequence = anim,
				})
				expect(impact > 0).to.equal(true)
				task.wait(1.4)
				local piv = model:GetPivot()
				expect((piv.Position - home.Position).Magnitude < 0.05).to.equal(true)
				expect(piv.LookVector:Dot(home.LookVector) > 0.999).to.equal(true)
			end
			model:Destroy()
			foe:Destroy()
			Battle._TestReset()
		end)
	end)

	describe('ArenaService battle settlement', function()
		it('pays one collective total on raid completion; empty failures pay nothing', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
			local profile: any = {}
			Progression.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			local grants: { any } = {}
			ArenaService.SetProgressionService(Progression)
			ArenaService.SetEconomyService({
				AddMoney = function(_userId: number, amount: string, reason: string, _opts: any)
					grants[#grants + 1] = { amount = amount, reason = reason }
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
			local members = { playerMember('Tiger', 30, 'AN_set') }
			local function stageEnemies(stage: number): { any }
				return (ArenaConfig.FindLevel(stage) :: any).EnemyTeam
			end
			local battle: any, berr = Battle.CreateBattle(9001, 7001, 1, members, stageEnemies(1), 1.5, 0, 1, nil)
			expect(berr).to.equal(nil)
			ArenaService._TestInjectSession(9001, {
				sessionId = 7001,
				userId = 9001,
				kind = 'Raid',
				arenaLevel = 1,
				maxLevel = ArenaConfig.MaxLevel(),
				stageGeneration = 1,
				state = 'Active',
				team = members,
				raidHP = {},
				raidAlive = {},
				rewardedStages = {},
				settledStages = {},
				clearedStages = {},
				rewardAccum = { cash = '0', xp = 0 },
				rewardSettled = false,
				firstClearCursor = 1,
				battle = battle,
			})
			-- Collective totals over the full run (fresh profile:
			-- every stage is a first clear).
			local totalCash = '0'
			local totalXP = 0
			for stage = 1, ArenaConfig.MaxLevel() do
				local entry = ArenaConfig.FindLevel(stage) :: any
				totalCash = BigNumber.Add(totalCash, entry.Rewards.FirstClearCash)
				totalXP += entry.Rewards.ArenaXP
			end
			-- Clear every stage: zero payouts mid-run.
			for gen = 1, ArenaConfig.MaxLevel() do
				expect(ArenaService.GetSession(9001).arenaLevel).to.equal(gen)
				expect(#grants).to.equal(0)
				expect(Progression.GetArenaXP(9001)).to.equal(0)
				local r = ArenaService.CompleteBattle(9001, 7001, true, gen)
				if gen < ArenaConfig.MaxLevel() then
					expect(r.advanced).to.equal(true)
				else
					expect(r.raidComplete).to.equal(true)
				end
			end
			-- Exactly ONE terminal transaction for the whole raid.
			expect(#grants).to.equal(1)
			expect(grants[1].amount).to.equal(totalCash)
			expect(grants[1].reason).to.equal('ArenaReward')
			expect(ArenaService.GetSession(9001)).to.equal(nil)
			expect(Progression.GetHighestCompleted(9001)).to.equal(ArenaConfig.MaxLevel())
			expect(Progression.GetArenaState(9001).Wins).to.equal(ArenaConfig.MaxLevel())
			-- XP granted once, minus thresholds consumed leveling
			-- to the cap (100 * sum(1..9) = 4500).
			expect(Progression.GetArenaLevel(9001)).to.equal(ArenaConfig.MaxLevel())
			expect(Progression.GetArenaXP(9001)).to.equal(totalXP - 4500)
			-- Duplicate end event after completion: rejected, unpaid.
			local rDup = ArenaService.CompleteBattle(9001, 7001, true, ArenaConfig.MaxLevel())
			expect(rDup.success).to.equal(false)
			expect(#grants).to.equal(1)
			-- Loss on a fresh raid with an empty accumulator:
			-- nothing cleared, no grant (progressive $0).
			local members2 = { playerMember('Tiger', 30, 'AN_set2') }
			local battle2: any, berr2 = Battle.CreateBattle(9001, 7002, 5, members2, stageEnemies(5), 1.5, 0, 1, nil)
			expect(berr2).to.equal(nil)
			ArenaService._TestInjectSession(9001, {
				sessionId = 7002,
				userId = 9001,
				kind = 'Raid',
				arenaLevel = 5,
				maxLevel = ArenaConfig.MaxLevel(),
				stageGeneration = 1,
				state = 'Active',
				team = members2,
				raidHP = {},
				raidAlive = {},
				rewardedStages = {},
				settledStages = {},
				clearedStages = {},
				rewardAccum = { cash = '0', xp = 0 },
				rewardSettled = false,
				firstClearCursor = 1,
				battle = battle2,
			})
			local r3 = ArenaService.CompleteBattle(9001, 7002, false, 1)
			expect(r3.success).to.equal(true)
			expect(#grants).to.equal(1)
			-- Stale session id: ignored.
			local rStale = ArenaService.CompleteBattle(9001, 9999, true)
			expect(rStale.success).to.equal(false)
			expect(#grants).to.equal(1)
			ArenaService._TestReset()
			Progression._TestReset()
			ArenaService.SetProgressionService(nil)
			ArenaService.SetEconomyService(nil)
			ArenaService.SetNotificationService(nil)
			ArenaService.SetBattleService(nil)
			Battle._TestReset()
		end)

		it('toasts the RAW settled raid total once at completion (never $0, never mid-raid)', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local NotificationService = require(ServerScriptService.Base.NotificationService)
			local profile: any = {}
			Progression.SetPlayerService({
				GetPlayerData = function(_userId: number)
					return profile
				end,
			})
			local notices: { any } = {}
			ArenaService.SetProgressionService(Progression)
			ArenaService.SetEconomyService({
				AddMoney = function(_userId: number, amount: string, reason: string, _opts: any)
					return { Success = true }
				end,
			})
			ArenaService.SetNotificationService({
				NotifyWarning = function()
					return true
				end,
				NotifySuccess = function(_player: any, id: string, data: any)
					notices[#notices + 1] = { id = id, data = data }
					return true
				end,
			})
			ArenaService.SetBattleService(Battle)
			-- History through stage 9: the final contributes first-clear.
			for stage = 1, ArenaConfig.MaxLevel() - 1 do
				Progression.RecordLevelWin(9011, stage)
			end
			local maxStage = ArenaConfig.MaxLevel()
			local members = { playerMember('Dragon', 30, 'AN_t500') }
			local battle: any, berr = Battle.CreateBattle(
				9011,
				7011,
				maxStage,
				members,
				(ArenaConfig.FindLevel(maxStage) :: any).EnemyTeam,
				1.5,
				0,
				7,
				nil
			)
			expect(berr).to.equal(nil)
			ArenaService._TestInjectSession(9011, {
				sessionId = 7011,
				userId = 9011,
				kind = 'Raid',
				arenaLevel = maxStage,
				maxLevel = maxStage,
				stageGeneration = 7,
				state = 'Active',
				team = members,
				raidHP = {},
				raidAlive = {},
				rewardedStages = {},
				settledStages = {},
				clearedStages = {},
				rewardAccum = { cash = '0', xp = 0 },
				rewardSettled = false,
				firstClearCursor = maxStage,
				battle = battle,
			})
			expect(ArenaService.CompleteBattle(9011, 7011, true, 7).raidComplete).to.equal(true)
			expect(#notices).to.equal(1)
			expect(notices[1].id).to.equal('Arena_RaidComplete')
			-- Raw BigNumber string: the single formatting point
			-- (NotificationService._cleanAmount) owns display.
			local finalCash = (ArenaConfig.FindLevel(maxStage) :: any).Rewards.FirstClearCash
			expect(notices[1].data.Amount).to.equal(finalCash)
			local text = NotificationService.GetSuccessText('Arena_RaidComplete', notices[1].data)
			expect(text).to.be.ok()
			expect(string.find(text :: string, '%$0', 1, true)).to.equal(nil)
			ArenaService._TestReset()
			Progression._TestReset()
			ArenaService.SetProgressionService(nil)
			ArenaService.SetEconomyService(nil)
			ArenaService.SetNotificationService(nil)
			ArenaService.SetBattleService(nil)
			Battle._TestReset()
		end)
	end)

	describe('ArenaResult combat keepsakes', function()
		it('captures player combat models pre-destruction, keyed by animal id', function()
			local Workspace = game:GetService('Workspace')
			local battle: any, err = Battle.CreateBattle(61, 601, 1, {
				playerMember('Tiger', 30, 'AN_k1'),
				playerMember('Dragon', 30, 'AN_k2'),
			}, { { DefinitionId = 'Dog', Level = 1 } }, 1.5, 0)
			expect(err).to.equal(nil)
			local function mkmodel(name: string): Model
				local m = Instance.new('Model')
				m.Name = name
				local p = Instance.new('Part')
				p.Name = 'CENTER'
				p.Size = Vector3.new(2, 2, 2)
				p.Parent = m
				m.Parent = Workspace
				return m
			end
			local m1 = mkmodel('Arena_Player1')
			local m2 = mkmodel('Arena_Player2')
			local foe = mkmodel('Arena_Enemy1')
			battle.playerTeam[1].Model = m1
			battle.playerTeam[2].Model = m2
			battle.enemyTeam[1].Model = foe
			-- Death-time capture for the first animal; live capture
			-- for the survivor; enemies are never kept.
			Battle.CaptureKeepsake(battle, battle.playerTeam[1], nil)
			Battle.CaptureLiveKeepsakes(battle)
			local kept = Battle.TakeKeepsakes(battle)
			expect(kept.AN_k1).to.be.ok()
			expect(kept.AN_k2).to.be.ok()
			-- Pristine clones: geometry present, originals untouched.
			expect((kept.AN_k1 :: Model):FindFirstChild('CENTER')).to.be.ok()
			expect(m1.Parent).to.equal(Workspace)
			expect(m2.Parent).to.equal(Workspace)
			-- Enemy combatant excluded (keyed by SourceAnimalId).
			local count = 0
			for _ in pairs(kept) do
				count += 1
			end
			expect(count).to.equal(2)
			-- Take drains: repeats collect nothing.
			local kept2 = Battle.TakeKeepsakes(battle)
			local count2 = 0
			for _ in pairs(kept2) do
				count2 += 1
			end
			expect(count2).to.equal(0)
			m1:Destroy()
			m2:Destroy()
			foe:Destroy()
			Battle.ClearSessionKeepsakes(601)
			Battle._TestReset()
		end)
	end)

	describe('ArenaConfig combat catalog', function()
		it('every enemy def resolves and every roster is non-empty', function()
			local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
			for _, entry in ipairs(ArenaConfig.GetAll()) do
				expect(#entry.EnemyTeam > 0).to.equal(true)
				for _, enemy in ipairs(entry.EnemyTeam) do
					local rarity = AnimalConfig.Get(enemy.DefinitionId)
					expect(type(rarity)).to.equal('string')
				end
			end
		end)

		it('live catalog validates clean with the real def probe', function()
			expect(#ArenaConfig.ValidateLive()).to.equal(0)
		end)

		it('ships the specified first/repeat bounties', function()
			expect((ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash).to.equal('15000')
			expect((ArenaConfig.FindLevel(1) :: any).Rewards.RepeatCash).to.equal('500')
			expect((ArenaConfig.FindLevel(10) :: any).Rewards.FirstClearCash).to.equal('3000')
			expect((ArenaConfig.FindLevel(10) :: any).Rewards.RepeatCash).to.equal('2000')
			expect((ArenaConfig.FindLevel(10) :: any).EnemyTeam[1].IsBoss).to.equal(true)
		end)

		it('rosters fit the 3v3 spawn cap with real descriptions', function()
			expect(ArenaConfig.MinTeamSize()).to.equal(1)
			expect(ArenaConfig.MaxTeamSize()).to.equal(3)
			for _, entry in ipairs(ArenaConfig.GetAll()) do
				expect(#entry.EnemyTeam >= 1).to.equal(true)
				expect(#entry.EnemyTeam <= ArenaConfig.MaxTeamSize()).to.equal(true)
				expect(string.find(entry.Description, 'PLACEHOLDER')).to.equal(nil)
				expect(#entry.Description > 0).to.equal(true)
				expect(tonumber(entry.Rewards.FirstClearCash) > 0).to.equal(true)
				expect(tonumber(entry.Rewards.RepeatCash) > 0).to.equal(true)
			end
		end)

		it('ValidateList rejects bad cash and level gaps', function()
			local function level(overrides: any): any
				local base: any = {
					Level = 1,
					Name = 'X',
					Description = 'd',
					Boss = false,
					EnemyTeam = { { DefinitionId = 'Dog', Level = 1 } },
					Rewards = { ArenaXP = 1, FirstClearCash = '10', RepeatCash = '5' },
				}
				if type(overrides) == 'table' then
					for k, v in pairs(overrides) do
						base[k] = v
					end
				end
				return base
			end
			local badCash = level({ Rewards = { ArenaXP = 1, FirstClearCash = 'lots', RepeatCash = '5' } })
			expect(#ArenaConfig.ValidateList({ badCash }) > 0).to.equal(true)
			local negCash = level({ Rewards = { ArenaXP = 1, FirstClearCash = '-10', RepeatCash = '5' } })
			expect(#ArenaConfig.ValidateList({ negCash }) > 0).to.equal(true)
			local gap = level({ Level = 2 })
			expect(#ArenaConfig.ValidateList({ gap }) > 0).to.equal(true)
			expect(#ArenaConfig.ValidateList({ level(nil) })).to.equal(0)
		end)
	end)

	describe('ArenaBattleService positions', function()
		local trash: { Instance } = {}

		local function part(name: string, pos: Vector3): Part
			local p = Instance.new('Part')
			p.Name = name
			p.Size = Vector3.new(2, 1, 2)
			p.Anchored = true
			p.CFrame = CFrame.new(pos)
			trash[#trash + 1] = p
			return p
		end

		local function arenaBase(): any
			local folder = Instance.new('Folder')
			folder.Name = 'Base_VisSpec'
			trash[#trash + 1] = folder
			local arena = Instance.new('Folder')
			arena.Name = 'Arena'
			arena.Parent = folder
			local ps = Instance.new('Folder')
			ps.Name = 'PlayerSpawns'
			ps.Parent = arena
			part('Position1', Vector3.new(0, 1, 0)).Parent = ps
			part('Position2', Vector3.new(4, 1, 0)).Parent = ps
			local es = Instance.new('Folder')
			es.Name = 'EnemySpawns'
			es.Parent = arena
			part('Position1', Vector3.new(0, 1, 40)).Parent = es
			return { id = 'Base_VisSpec', folder = folder }
		end

		it('resolves indexed spawns and reports gaps explicitly', function()
			local base = arenaBase()
			local res = Battle.ResolveBattlePositions(base, 2, 1)
			expect(res.ready).to.equal(true)
			expect(#res.player).to.equal(2)
			expect(#res.enemy).to.equal(1)
			expect(res.player[1].Position).to.equal(Vector3.new(0, 1, 0))
			expect(res.enemy[1].Position).to.equal(Vector3.new(0, 1, 40))
			local short = Battle.ResolveBattlePositions(base, 3, 2)
			expect(short.ready).to.equal(false)
			expect(#short.missing).to.equal(2)
			local bare: any = { id = 'Base_Bare', folder = Instance.new('Folder') }
			trash[#trash + 1] = bare.folder
			local nobase = Battle.ResolveBattlePositions(bare, 1, 1)
			expect(nobase.ready).to.equal(false)
			expect(Battle.ResolveBattlePositions(nil, 1, 1).ready).to.equal(false)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)
	end)

	describe('ArenaService.ResolveArenaArea', function()
		local trash: { Instance } = {}

		local function areaBase(withCenter: boolean, centerClass: string?): any
			local folder = Instance.new('Folder')
			folder.Name = 'Base_AreaSpec'
			trash[#trash + 1] = folder
			local arena = Instance.new('Folder')
			arena.Name = 'Arena'
			arena.Parent = folder
			if withCenter then
				local center: Instance
				if centerClass == 'Attachment' then
					center = Instance.new('Attachment')
				elseif centerClass == 'Folder' then
					center = Instance.new('Folder')
				else
					local part = Instance.new('Part')
					part.Size = Vector3.new(2, 1, 2)
					part.Anchored = true
					center = part
				end
				center.Name = 'Center'
				center.Parent = arena
			end
			for _, folderName in ipairs({ 'PlayerSpawns', 'EnemySpawns' }) do
				local spawns = Instance.new('Folder')
				spawns.Name = folderName
				spawns.Parent = arena
				local marker = Instance.new('Part')
				marker.Name = 'Position1'
				marker.Size = Vector3.new(2, 1, 2)
				marker.Anchored = true
				marker.Parent = spawns
			end
			return { id = 'Base_AreaSpec', folder = folder }
		end

		it('is ready with Center + spawns and WITHOUT BossSpawn', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local area = ArenaService.ResolveArenaArea(areaBase(true, 'Part'))
			expect(area.ready).to.equal(true)
			expect(area.center).to.be.ok()
			expect(#area.missing).to.equal(0)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)

		it('fails closed on missing Center, naming it exactly', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local area = ArenaService.ResolveArenaArea(areaBase(false, nil))
			expect(area.ready).to.equal(false)
			expect(area.center).to.equal(nil)
			local found = false
			for _, item in ipairs(area.missing) do
				if item == 'Arena/Center' then
					found = true
				end
			end
			expect(found).to.equal(true)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)

		it('rejects a wrong-class Center explicitly', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local area = ArenaService.ResolveArenaArea(areaBase(true, 'Folder'))
			expect(area.ready).to.equal(false)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)

		it('fails closed with no Arena folder at all', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local folder = Instance.new('Folder')
			folder.Name = 'Base_NoArena'
			trash[#trash + 1] = folder
			local area = ArenaService.ResolveArenaArea({ id = 'Base_NoArena', folder = folder })
			expect(area.ready).to.equal(false)
			expect(#area.missing > 0).to.equal(true)
			expect(ArenaService.ResolveArenaArea(nil).ready).to.equal(false)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)

		it('DebugArea runs without throwing on good and bad bases', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			ArenaService.DebugArea(areaBase(true, 'Part'))
			ArenaService.DebugArea(areaBase(false, nil))
			ArenaService.DebugArea(nil)
			for _, inst in ipairs(trash) do
				pcall(function()
					inst:Destroy()
				end)
			end
			trash = {}
		end)
	end)

	describe('ArenaBattleService visual lifecycle', function()
		local function fakeModel(name: string): Model
			local model = Instance.new('Model')
			model.Name = name
			local hrp = Instance.new('Part')
			hrp.Name = 'HumanoidRootPart'
			hrp.Size = Vector3.new(2, 2, 1)
			hrp.Parent = model
			model.PrimaryPart = hrp
			return model
		end

		local function fakeAnimalService(models: { [string]: Model }, templates: { [string]: Model }): any
			return {
				Get = function(uniqueId: string)
					local model = models[uniqueId]
					if model == nil then
						return nil
					end
					return { uniqueId = uniqueId, model = model, Trait = nil, Mutations = {}, displayName = 'Vis' }
				end,
				GetTemplate = function(_rarity: string, defId: string)
					return templates[defId]
				end,
			}
		end

		local function arenaBase(): any
			local folder = Instance.new('Folder')
			folder.Name = 'Base_VisSpawn'
			local arena = Instance.new('Folder')
			arena.Name = 'Arena'
			arena.Parent = folder
			local ps = Instance.new('Folder')
			ps.Name = 'PlayerSpawns'
			ps.Parent = arena
			local p1 = Instance.new('Part')
			p1.Name = 'Position1'
			p1.Size = Vector3.new(2, 1, 2)
			p1.Anchored = true
			p1.CFrame = CFrame.new(0, 1, 0)
			p1.Parent = ps
			local es = Instance.new('Folder')
			es.Name = 'EnemySpawns'
			es.Parent = arena
			local e1 = Instance.new('Part')
			e1.Name = 'Position1'
			e1.Size = Vector3.new(2, 1, 2)
			e1.Anchored = true
			e1.CFrame = CFrame.new(0, 1, 30)
			e1.Parent = es
			return { id = 'Base_VisSpawn', folder = folder }
		end

		it('spawns, positions, faces, and tears down models', function()
			local sourceModel = fakeModel('TigerLive')
			local templateModel = fakeModel('DogT')
			-- Live/template sources must be parented: the
			-- clone path rejects parentless models.
			local ws = game:GetService('Workspace')
			sourceModel.Parent = ws
			templateModel.Parent = ws
			Battle.SetAnimalService(fakeAnimalService({ AN_v1 = sourceModel }, { Dog = templateModel }))
			local base = arenaBase()
			local battle: any, err = Battle.CreateBattle(
				41,
				401,
				1,
				{ playerMember('Tiger', 30, 'AN_v1') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local spawned = Battle.SpawnBattleModels(battle, base)
			expect(spawned.ok).to.equal(true)
			local folder = battle.folder
			expect(typeof(folder) == 'Instance' and (folder :: Instance).Parent ~= nil).to.equal(true)
			local pModel = battle.playerTeam[1].Model
			local eModel = battle.enemyTeam[1].Model
			expect(pModel ~= nil and pModel.Parent == folder).to.equal(true)
			expect(eModel ~= nil and eModel.Parent == folder).to.equal(true)
			-- Grounded on the marker top surface (2x1x2 part at
			-- Y=1 -> top 1.5): single-part 2-tall models pivot
			-- at 2.5 with bottoms flush at 1.5, facing each
			-- other (flattened).
			expect((pModel:GetPivot().Position - Vector3.new(0, 2.5, 0)).Magnitude < 0.1).to.equal(true)
			expect((eModel:GetPivot().Position - Vector3.new(0, 2.5, 30)).Magnitude < 0.1).to.equal(true)
			local pbb, psize = pModel:GetBoundingBox()
			expect(pbb.Position.Y - psize.Y / 2 - 1.5 < 0.05).to.equal(true)
			local ebb, esize = eModel:GetBoundingBox()
			expect(ebb.Position.Y - esize.Y / 2 - 1.5 < 0.05).to.equal(true)
			local toEnemy = (eModel:GetPivot().Position - pModel:GetPivot().Position)
			expect(pModel:GetPivot().LookVector:Dot(toEnemy.Unit) > 0.9).to.equal(true)
			-- Overhead records attached (headless: template
			-- missing, so Refresh degrades gracefully).
			expect(type(battle.playerTeam[1].overheadRecord)).to.equal('table')
			-- Persistent source model untouched: still alive,
			-- unmoved, and NOT the combat clone.
			expect(sourceModel.Parent).to.be.ok()
			expect(battle.playerTeam[1].Model ~= sourceModel).to.equal(true)
			expect(templateModel.Parent).to.be.ok()
			-- Teardown is idempotent and complete.
			Battle.DestroyBattleModels(battle)
			expect(folder.Parent).to.equal(nil)
			expect(battle.playerTeam[1].Model).to.equal(nil)
			Battle.DestroyBattleModels(battle)
			base.folder:Destroy()
			sourceModel:Destroy()
			templateModel:Destroy()
			Battle.SetAnimalService(nil)
			Battle._TestReset()
		end)

		it('grounds small and tall models on the same surface plane', function()
			local function tallModel(name: string, height: number): Model
				local model = Instance.new('Model')
				model.Name = name
				local hrp = Instance.new('Part')
				hrp.Name = 'HumanoidRootPart'
				hrp.Size = Vector3.new(2, height, 2)
				hrp.Anchored = true
				hrp.Parent = model
				model.PrimaryPart = hrp
				return model
			end
			local small = tallModel('GSmall', 2)
			local large = tallModel('GLarge', 6)
			local foeModel = tallModel('GFoe', 4)
			-- Live/template sources must be parented: the
			-- clone path rejects parentless models.
			local ws = game:GetService('Workspace')
			small.Parent = ws
			large.Parent = ws
			foeModel.Parent = ws
			Battle.SetAnimalService(fakeAnimalService({ G1 = small, G2 = large }, { Dog = foeModel }))
			local folder = Instance.new('Folder')
			folder.Name = 'Base_Ground'
			local arena = Instance.new('Folder')
			arena.Name = 'Arena'
			arena.Parent = folder
			local ps = Instance.new('Folder')
			ps.Name = 'PlayerSpawns'
			ps.Parent = arena
			for i, x in ipairs({ 0, 6 }) do
				local marker = Instance.new('Part')
				marker.Name = 'Position' .. tostring(i)
				marker.Size = Vector3.new(2, 1, 2)
				marker.Anchored = true
				marker.CFrame = CFrame.new(x, 1, 0)
				marker.Parent = ps
			end
			local es = Instance.new('Folder')
			es.Name = 'EnemySpawns'
			es.Parent = arena
			local em = Instance.new('Part')
			em.Name = 'Position1'
			em.Size = Vector3.new(2, 1, 2)
			em.Anchored = true
			em.CFrame = CFrame.new(3, 1, 30)
			em.Parent = es
			local base = { id = 'Base_Ground', folder = folder }
			local battle: any, err = Battle.CreateBattle(
				45,
				405,
				1,
				{ playerMember('Tiger', 30, 'G1'), playerMember('Dog', 1, 'G2') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			expect(Battle.SpawnBattleModels(battle, base).ok).to.equal(true)
			-- Marker tops are all at Y=1.5; every bottom must
			-- sit flush there regardless of model height,
			-- while pivots differ (2.5 / 4.5 / 3.5).
			local p1 = battle.playerTeam[1].Model
			local p2 = battle.playerTeam[2].Model
			local e1 = battle.enemyTeam[1].Model
			expect((p1:GetPivot().Position - Vector3.new(0, 2.5, 0)).Magnitude < 0.1).to.equal(true)
			expect((p2:GetPivot().Position - Vector3.new(6, 4.5, 0)).Magnitude < 0.1).to.equal(true)
			expect((e1:GetPivot().Position - Vector3.new(3, 3.5, 30)).Magnitude < 0.1).to.equal(true)
			for _, entry in ipairs({ { p1, 0 }, { p2, 6 }, { e1, 3 } }) do
				local bb, size = (entry[1] :: Model):GetBoundingBox()
				expect(bb.Position.Y - size.Y / 2 - 1.5 < 0.05).to.equal(true)
				expect(math.abs(bb.Position.X - (entry[2] :: number)) < 0.05).to.equal(true)
			end
			-- Canonical homes are the grounded transforms, so
			-- attack returns stay grounded.
			expect((battle.playerTeam[2].HomeCFrame.Position - Vector3.new(6, 4.5, 0)).Magnitude < 0.05).to.equal(true)
			folder:Destroy()
			small:Destroy()
			large:Destroy()
			foeModel:Destroy()
			Battle.SetAnimalService(nil)
			Battle._TestReset()
		end)

		it('fires exactly one ArenaHit packet at contact with the full payload', function()
			local Workspace = game:GetService('Workspace')
			local battle: any, err = Battle.CreateBattle(
				63,
				603,
				1,
				{ playerMember('Tiger', 30, 'AN_c1') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local function livePart(name: string, pos: Vector3): (Model, BasePart)
				local model = Instance.new('Model')
				model.Name = name
				local root = Instance.new('Part')
				root.Name = 'HumanoidRootPart'
				root.Size = Vector3.new(2, 2, 2)
				root.Anchored = true
				root.CFrame = CFrame.new(pos)
				root.Parent = model
				model.PrimaryPart = root
				model.Parent = Workspace
				return model, root
			end
			local model, _ = livePart('CtxSpec', Vector3.new(0, 5, 0))
			local foe, _ = livePart('CtxFoe', Vector3.new(12, 5, 0))
			battle.playerTeam[1].Model = model
			battle.playerTeam[1].HomeCFrame = model:GetPivot()
			battle.enemyTeam[1].Model = foe
			battle.enemyTeam[1].HomeCFrame = foe:GetPivot()
			-- Rig the foe to survive the commit tick so the
			-- battle stays Active through contact.
			battle.enemyTeam[1].CurrentHealth = 1000000
			-- Commit tick still carries the contact point
			-- (foe home CENTER — the VFX anchors on/in the
			-- target body, never offset beside it).
			local outcome = Battle.TickBattle(battle, 0)
			local contact: Vector3? = nil
			for _, event in ipairs(outcome.events) do
				if type(event) == 'table' and event.type == 'attack' then
					contact = event.impactPosition
					expect(event.soundIndex).to.equal(1)
				end
			end
			expect(contact).to.be.ok()
			expect(((contact :: Vector3) - Vector3.new(12, 5, 0)).Magnitude < 0.1).to.equal(true)
			-- Presentation thread fires exactly ONE ArenaHit
			-- packet at contact (no duplicates, full payload
			-- for instant client presentation).
			local hits: { any } = {}
			Battle.SetEventSink(function(_userId: number, event: { [string]: any })
				if type(event) == 'table' and event.Event == 'ArenaHit' then
					hits[#hits + 1] = event
				end
			end)
			Battle.PresentAttack(battle, {
				attackerId = battle.playerTeam[1].Id,
				targetId = battle.enemyTeam[1].Id,
				attackAnimation = 3,
				soundIndex = 2,
				damage = 50,
				attackSequence = 7,
			})
			task.wait(1.2)
			expect(#hits).to.equal(1)
			local hit = hits[1]
			expect(hit.AttackerId).to.equal(battle.playerTeam[1].Id)
			expect(hit.TargetId).to.equal(battle.enemyTeam[1].Id)
			expect(hit.Damage).to.equal(50)
			expect(hit.AttackIndex).to.equal(3)
			expect(hit.SoundIndex).to.equal(2)
			expect(hit.AttackSequence).to.equal(7)
			expect(hit.SessionId).to.equal(603)
			expect(hit.OwnerUserId).to.equal(63)
			expect(typeof(hit.ImpactPosition) == 'Vector3').to.equal(true)
			expect(((hit.ImpactPosition :: Vector3) - Vector3.new(12, 5, 0)).Magnitude < 0.1).to.equal(true)
			model:Destroy()
			foe:Destroy()
			Battle.SetEventSink(nil)
			Battle.SetAnimalService(nil)
			Battle._TestReset()
		end)

		it('fires no hit packet when the battle is already over', function()
			local Workspace = game:GetService('Workspace')
			local battle: any, err = Battle.CreateBattle(
				64,
				604,
				1,
				{ playerMember('Tiger', 30, 'AN_c2') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local model = Instance.new('Model')
			model.Name = 'CtxDone'
			local root = Instance.new('Part')
			root.Name = 'HumanoidRootPart'
			root.Size = Vector3.new(2, 2, 2)
			root.Anchored = true
			root.CFrame = CFrame.new(0, 5, 0)
			root.Parent = model
			model.PrimaryPart = root
			model.Parent = Workspace
			battle.playerTeam[1].Model = model
			battle.playerTeam[1].HomeCFrame = model:GetPivot()
			local foeDone = Instance.new('Model')
			foeDone.Name = 'CtxDoneFoe'
			local foeRoot = Instance.new('Part')
			foeRoot.Name = 'HumanoidRootPart'
			foeRoot.Size = Vector3.new(2, 2, 2)
			foeRoot.Anchored = true
			foeRoot.CFrame = CFrame.new(12, 5, 0)
			foeRoot.Parent = foeDone
			foeDone.PrimaryPart = foeRoot
			foeDone.Parent = Workspace
			battle.enemyTeam[1].Model = foeDone
			battle.enemyTeam[1].HomeCFrame = foeDone:GetPivot()
			battle.state = 'Lost'
			local hits = 0
			Battle.SetEventSink(function(_userId: number, event: { [string]: any })
				if type(event) == 'table' and event.Event == 'ArenaHit' then
					hits += 1
				end
			end)
			Battle.PresentAttack(battle, {
				attackerId = battle.playerTeam[1].Id,
				targetId = battle.enemyTeam[1].Id,
			})
			task.wait(1.2)
			expect(hits).to.equal(0)
			model:Destroy()
			foeDone:Destroy()
			Battle.SetEventSink(nil)
			Battle._TestReset()
		end)

		it('fails spawn closed when models are unavailable', function()
			Battle.SetAnimalService(fakeAnimalService({}, {}))
			local base = arenaBase()
			local battle: any, err = Battle.CreateBattle(
				42,
				402,
				1,
				{ playerMember('Tiger', 30, 'AN_gone') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			local spawned = Battle.SpawnBattleModels(battle, base)
			expect(spawned.ok).to.equal(false)
			expect(battle.folder).to.equal(nil)
			base.folder:Destroy()
			Battle.SetAnimalService(nil)
			Battle._TestReset()
		end)

		it('presentation helpers are safe with no models', function()
			local battle: any, _ = Battle.CreateBattle(
				43,
				403,
				1,
				{ playerMember('Tiger', 30) },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			Battle.PresentAttack(battle, {
				attackerId = battle.playerTeam[1].Id,
				targetId = battle.enemyTeam[1].Id,
			})
			Battle.PresentDeath(battle, battle.enemyTeam[1].Id)
			Battle.DestroyBattleModels(battle)
			Battle.DestroyBattleModels(nil :: any)
			Battle._TestReset()
		end)

		it('full visual battle resolves to victory with models cleaned', function()
			local events: { any } = {}
			local sourceModel = fakeModel('TigerLive')
			local templateModel = fakeModel('DogT')
			Battle.SetAnimalService(fakeAnimalService({ AN_w1 = sourceModel }, { Dog = templateModel }))
			Battle.SetValidator(function(_battle: any)
				return true
			end)
			Battle.SetOnBattleEnd(function(_userId: number, _sessionId: number, _won: boolean) end)
			Battle.SetEventSink(function(_userId: number, event: { [string]: any })
				events[#events + 1] = event
			end)
			local base = arenaBase()
			local battle: any, err = Battle.CreateBattle(
				44,
				404,
				1,
				{ playerMember('Tiger', 30, 'AN_w1') },
				{ { DefinitionId = 'Dog', Level = 1 } },
				1.5,
				0
			)
			expect(err).to.equal(nil)
			expect(Battle.SpawnBattleModels(battle, base).ok).to.equal(true)
			expect(Battle.RegisterBattle(battle)).to.equal(true)
			local now = 1000
			local result: string? = nil
			for _ = 1, 2000 do
				now += 1.5
				Battle.TickAll(now)
				if battle.state ~= 'Active' then
					result = battle.result
					break
				end
			end
			expect(result).to.equal('won')
			local kinds: { [string]: boolean } = {}
			for _, event in ipairs(events) do
				kinds[event.Event or event.type] = true
			end
			expect(kinds['CombatStarted']).to.equal(true)
			expect(kinds['CombatantSpawned']).to.equal(true)
			expect(kinds['attack']).to.equal(true)
			expect(kinds['defeat']).to.equal(true)
			expect(kinds['Victory']).to.equal(true)
			-- Dead enemy model refs cleared by presentation.
			expect(battle.enemyTeam[1].Model).to.equal(nil)
			base.folder:Destroy()
			sourceModel:Destroy()
			templateModel:Destroy()
			local root = game:GetService('Workspace'):FindFirstChild('ArenaBattles')
			if root then
				for _, child in ipairs(root:GetChildren()) do
					if child.Name == 'Battle_404' then
						child:Destroy()
					end
				end
			end
			Battle.SetAnimalService(nil)
			Battle._TestReset()
		end)
	end)

	describe('ArenaService silent cancel', function()
		it('drops the session with no reward and no error', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			ArenaService.SetBattleService(Battle)
			ArenaService._TestInjectSession(9101, {
				sessionId = 7101,
				userId = 9101,
				arenaLevel = 1,
				state = 'Active',
				team = {},
				rewarded = false,
				battle = { sessionId = 7101, userId = 9101, state = 'Active', playerTeam = {}, enemyTeam = {} },
			})
			ArenaService.CancelBattleSilent(9101, 7101)
			expect(ArenaService.GetSession(9101)).to.equal(nil)
			-- Stale repeat is a silent no-op.
			ArenaService.CancelBattleSilent(9101, 7101)
			ArenaService._TestReset()
			ArenaService.SetBattleService(nil)
			Battle._TestReset()
		end)
	end)

	describe('Arena multiplayer settlement', function()
		-- Two-client harness: per-user profiles, per-user grant
		-- capture, and direct stage-end calls with explicit
		-- generations (deterministic, free of scheduler races).
		-- The collective model pays nothing mid-run: assertions
		-- target accumulators during the run and exactly one
		-- terminal transaction per completed raid.
		local function twoUserHarness()
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

		-- Inject a raid-shaped session with a real stage battle.
		-- No registration: direct CompleteBattle calls drive the
		-- run deterministically (engine tick coverage lives in
		-- ArenaRaid.spec).
		local function startRaidBattle(
			ArenaService: any,
			userId: number,
			sessionId: number,
			stage: number,
			members: { any },
			gen: number?,
			cursor: number?
		)
			local enemies = (ArenaConfig.FindLevel(stage) :: any).EnemyTeam
			local battle: any, err = Battle.CreateBattle(userId, sessionId, stage, members, enemies, 1.5, 0, gen, nil)
			expect(err).to.equal(nil)
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

		local function fullTotals(): { cash: string, xp: number }
			local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
			local cash = '0'
			local xp = 0
			for stage = 1, ArenaConfig.MaxLevel() do
				local entry = ArenaConfig.FindLevel(stage) :: any
				cash = BigNumber.Add(cash, entry.Rewards.FirstClearCash)
				xp += entry.Rewards.ArenaXP
			end
			return { cash = cash, xp = xp }
		end

		local function teardownMulti(ArenaService: any, Progression: any)
			ArenaService._TestReset()
			Progression._TestReset()
			ArenaService.SetProgressionService(nil)
			ArenaService.SetEconomyService(nil)
			ArenaService.SetNotificationService(nil)
			ArenaService.SetBattleService(nil)
			Battle._TestReset()
		end

		it('two raids accumulate independently with zero mid-run payouts', function()
			local ArenaService, Progression, grants = twoUserHarness()
			startRaidBattle(ArenaService, 9201, 7201, 1, { playerMember('Tiger', 30, 'AN_a1') }, 1, 1)
			startRaidBattle(ArenaService, 9202, 7202, 1, { playerMember('Dragon', 30, 'AN_b1') }, 1, 1)
			expect(ArenaService.CompleteBattle(9201, 7201, true, 1).advanced).to.equal(true)
			expect(ArenaService.CompleteBattle(9202, 7202, true, 1).advanced).to.equal(true)
			expect(ArenaService.GetSession(9201).arenaLevel).to.equal(2)
			expect(ArenaService.GetSession(9202).arenaLevel).to.equal(2)
			-- Per-raid accumulators, identical contributions,
			-- zero transactions so far.
			expect(ArenaService.GetSession(9201).rewardAccum.cash).to.equal(
				(ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash
			)
			expect(ArenaService.GetSession(9202).rewardAccum.cash).to.equal(
				(ArenaConfig.FindLevel(1) :: any).Rewards.FirstClearCash
			)
			expect(#grantsOf(grants, 9201)).to.equal(0)
			expect(#grantsOf(grants, 9202)).to.equal(0)
			expect(Progression.GetArenaXP(9201)).to.equal(0)
			expect(Progression.GetArenaXP(9202)).to.equal(0)
			expect(Progression.GetHighestCompleted(9201)).to.equal(0)
			expect(Progression.GetHighestCompleted(9202)).to.equal(0)
			teardownMulti(ArenaService, Progression)
		end)

		it('one raid completing pays once while the other wiping keeps cleared-stage rewards', function()
			local ArenaService, Progression, grants = twoUserHarness()
			startRaidBattle(ArenaService, 9211, 7211, 1, { playerMember('Dragon', 30, 'AN_a5') }, 1, 1)
			startRaidBattle(ArenaService, 9212, 7212, 1, { playerMember('Tiger', 30, 'AN_b5') }, 1, 1)
			-- A clears the full run: exactly one payment.
			for gen = 1, ArenaConfig.MaxLevel() do
				local r = ArenaService.CompleteBattle(9211, 7211, true, gen)
				if gen < ArenaConfig.MaxLevel() then
					expect(r.advanced).to.equal(true)
				else
					expect(r.raidComplete).to.equal(true)
				end
			end
			local total = fullTotals()
			local g1 = grantsOf(grants, 9211)
			expect(#g1).to.equal(1)
			expect(g1[1].amount).to.equal(total.cash)
			expect(g1[1].reason).to.equal('ArenaReward')
			expect(Progression.GetHighestCompleted(9211)).to.equal(ArenaConfig.MaxLevel())
			expect(Progression.GetArenaState(9211).Wins).to.equal(ArenaConfig.MaxLevel())
			-- B wipes at stage 3: cleared stages 1-2 settle
			-- progressively (one transaction), history to 2.
			expect(ArenaService.CompleteBattle(9212, 7212, true, 1).advanced).to.equal(true)
			expect(ArenaService.CompleteBattle(9212, 7212, true, 2).advanced).to.equal(true)
			expect(ArenaService.CompleteBattle(9212, 7212, false, 3).won).to.equal(false)
			expect(ArenaService.GetSession(9212)).to.equal(nil)
			local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
			local bCash = '0'
			local bXP = 0
			for stage = 1, 2 do
				local entry = ArenaConfig.FindLevel(stage) :: any
				bCash = BigNumber.Add(bCash, entry.Rewards.FirstClearCash)
				bXP += entry.Rewards.ArenaXP
			end
			local bGrants = grantsOf(grants, 9212)
			expect(#bGrants).to.equal(1)
			expect(bGrants[1].amount).to.equal(bCash)
			expect(Progression.GetArenaXP(9212)).to.equal(bXP - 4500)
			expect(Progression.GetHighestCompleted(9212)).to.equal(2)
			teardownMulti(ArenaService, Progression)
		end)

		it('one player wiping does not touch the other player clearing', function()
			local ArenaService, Progression, grants = twoUserHarness()
			startRaidBattle(ArenaService, 9221, 7221, 1, { playerMember('Chicken', 1, 'AN_aL') }, 1, 1)
			startRaidBattle(ArenaService, 9222, 7222, 1, { playerMember('Tiger', 30, 'AN_bW') }, 1, 1)
			-- A wipes immediately: empty accumulator, nothing
			-- paid, nothing recorded.
			expect(ArenaService.CompleteBattle(9221, 7221, false, 1).won).to.equal(false)
			expect(ArenaService.GetSession(9221)).to.equal(nil)
			expect(#grantsOf(grants, 9221)).to.equal(0)
			expect(Progression.GetHighestCompleted(9221)).to.equal(0)
			-- B clears the full run: one collective payment.
			for gen = 1, ArenaConfig.MaxLevel() do
				ArenaService.CompleteBattle(9222, 7222, true, gen)
			end
			local total = fullTotals()
			local g2 = grantsOf(grants, 9222)
			expect(#g2).to.equal(1)
			expect(g2[1].amount).to.equal(total.cash)
			expect(Progression.GetHighestCompleted(9222)).to.equal(ArenaConfig.MaxLevel())
			teardownMulti(ArenaService, Progression)
		end)

		it('a player leaving mid-raid pays nothing and spares the other raid', function()
			local ArenaService, _Progression, grants = twoUserHarness()
			startRaidBattle(ArenaService, 9231, 7231, 1, { playerMember('Tiger', 30, 'AN_aQ') }, 1, 1)
			startRaidBattle(ArenaService, 9232, 7232, 1, { playerMember('Dragon', 30, 'AN_bQ') }, 1, 1)
			-- A leaves: session cleared, accumulator dies with it.
			ArenaService.ForgetPlayer(9231)
			expect(ArenaService.GetSession(9231)).to.equal(nil)
			expect(#grantsOf(grants, 9231)).to.equal(0)
			-- B completes the full run: one collective payment.
			for gen = 1, ArenaConfig.MaxLevel() do
				ArenaService.CompleteBattle(9232, 7232, true, gen)
			end
			local total = fullTotals()
			local g2 = grantsOf(grants, 9232)
			expect(#g2).to.equal(1)
			expect(g2[1].amount).to.equal(total.cash)
			expect(#grantsOf(grants, 9231)).to.equal(0)
			teardownMulti(ArenaService, _Progression)
		end)

		it('duplicate terminal callbacks pay nothing twice across players', function()
			local ArenaService, _Progression, grants = twoUserHarness()
			startRaidBattle(ArenaService, 9241, 7241, 1, { playerMember('Tiger', 30, 'AN_aD') }, 1, 1)
			startRaidBattle(ArenaService, 9242, 7242, 1, { playerMember('Dragon', 30, 'AN_bD') }, 1, 1)
			for gen = 1, ArenaConfig.MaxLevel() do
				ArenaService.CompleteBattle(9241, 7241, true, gen)
				ArenaService.CompleteBattle(9242, 7242, true, gen)
			end
			expect(#grantsOf(grants, 9241)).to.equal(1)
			expect(#grantsOf(grants, 9242)).to.equal(1)
			-- Replayed end-events for settled raids: rejected, unpaid.
			expect(ArenaService.CompleteBattle(9241, 7241, true, ArenaConfig.MaxLevel()).success).to.equal(false)
			expect(ArenaService.CompleteBattle(9242, 7242, true, 1).success).to.equal(false)
			expect(ArenaService.CompleteBattle(9241, 9999, true).success).to.equal(false)
			expect(#grantsOf(grants, 9241)).to.equal(1)
			expect(#grantsOf(grants, 9242)).to.equal(1)
			teardownMulti(ArenaService, _Progression)
		end)
	end)
end
