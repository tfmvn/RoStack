--!strict
--!native
--[[
	ArenaResult.spec
	================
	Headless coverage for the end-of-raid results flow:
	  server: end-of-raid row snapshot (pure builder — full
	    mapping, missing-record fallbacks, 6-card cap,
	    mutation sanitizing, NaN guards);
	  client: outcome messaging, level/money/wave text,
	    RaidEnd validation + SessionId dedupe, card
	    normalization.
	The visible-first ordering (Visible before deferred
	viewport clones) is structural: openFromPayload sets
	Visible=true synchronously, then task.defers fillViewports;
	there is no code path that clones before showing.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')
	local StarterPlayer = game:GetService('StarterPlayer')
	local scriptsRoot = StarterPlayer:WaitForChild('StarterPlayerScripts', 10)
	assert(scriptsRoot ~= nil, 'StarterPlayerScripts missing in test place')
	local ctrlModule = scriptsRoot:WaitForChild('ArenaResultController', 10)
	assert(ctrlModule ~= nil, 'ArenaResultController missing in test place')
	local ArenaResultController = require(ctrlModule)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)
	local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)

	describe('ArenaResult server snapshot', function()
		local function combatant(uid: string, alive: boolean): any
			return {
				SourceAnimalId = uid,
				DefinitionId = 'Dog',
				DisplayName = 'Dog',
				Level = 5,
				Alive = alive,
			}
		end

		local function record(uid: string): any
			-- NOTE: records carry NO model for results. The result
			-- viewport's single source of truth is the captured
			-- combat keepsake (extras.CombatModels); the stand
			-- model is never read here.
			return {
				uniqueId = uid,
				definitionId = 'Dog',
				displayName = 'Good Boy',
				rarity = 'Rare',
				Trait = 'Gold',
				Mutations = { 'Frost', '', 42 },
				Level = 12,
				XP = 3450,
			}
		end

		local function lookup(records: { [string]: any })
			return function(uid: string)
				return records[uid]
			end
		end
		it('maps full records with committed grants', function()
			local rec = record('a1')
			local extras = {
				PreLevels = { a1 = 12 },
				PreXP = { a1 = 3450 },
				Awards = { a1 = { LevelAfter = 15, XPAwarded = 120000, XPAfter = 700 } },
			}
			local rows = ArenaService._TestBuildResultAnimals({ combatant('a1', true) }, lookup({ a1 = rec }), extras)
			expect(#rows).to.equal(1)
			local row = rows[1]
			expect(row.UniqueId).to.equal('a1')
			expect(row.DefinitionId).to.equal('Dog')
			expect(row.DisplayName).to.equal('Good Boy')
			expect(row.Rarity).to.equal('Rare')
			expect(row.Trait).to.equal('Gold')
			-- Pre-grant level pinned; after-level + XP come ONLY
			-- from the committed grant record.
			expect(row.LevelBefore).to.equal(12)
			expect(row.LevelAfter).to.equal(15)
			expect(row.XP).to.equal(120000)
			expect(row.XPBefore).to.equal(3450)
			expect(row.XPAfter).to.equal(700)
			expect(row.Alive).to.equal(true)
			-- No stand-model reference is ever emitted: the
			-- viewport uses extras.CombatModels only.
			expect(row.Model).to.equal(nil)
			expect(row.CombatModel).to.equal(nil)
			-- Only real mutation strings survive.
			expect(#row.Mutations).to.equal(1)
			expect(row.Mutations[1]).to.equal('Frost')
		end)

		it('falls back to combatant data when the record is missing', function()
			local rows = ArenaService._TestBuildResultAnimals({ combatant('gone', false) }, lookup({}))
			expect(#rows).to.equal(1)
			local row = rows[1]
			expect(row.DisplayName).to.equal('Dog')
			expect(row.Rarity).to.equal('?')
			expect(row.LevelBefore).to.equal(5)
			expect(row.LevelAfter).to.equal(5)
			-- No grant record: honest zero awarded, never record totals.
			expect(row.XP).to.equal(0)
			expect(row.Alive).to.equal(false)
			expect(row.Model).to.equal(nil)
		end)

		it('caps at six cards and skips non-tables', function()
			local team: { any } = { 'junk' }
			for i = 1, 7 do
				team[#team + 1] = combatant('u' .. tostring(i), true)
			end
			local rows = ArenaService._TestBuildResultAnimals(team, lookup({}))
			expect(#rows).to.equal(6)
			expect(rows[6].UniqueId).to.equal('u6')
		end)

		it('sanitizes bad levels/XP and handles empty input', function()
			local rows = ArenaService._TestBuildResultAnimals(nil, lookup({}))
			expect(#rows).to.equal(0)
			local rec = record('b1')
			rec.Level = 0 / 0
			rec.XP = -50
			local rows2 = ArenaService._TestBuildResultAnimals({ combatant('b1', true) }, lookup({ b1 = rec }))
			expect(rows2[1].LevelBefore).to.equal(1)
			expect(rows2[1].XP).to.equal(0)
		end)

		it('prefers pre-grant levels over post-grant record reads', function()
			local rec = record('c1')
			rec.Level = 99
			local extras = { PreLevels = { c1 = 12 } }
			local rows = ArenaService._TestBuildResultAnimals({ combatant('c1', true) }, lookup({ c1 = rec }), extras)
			expect(rows[1].LevelBefore).to.equal(12)
			expect(rows[1].LevelAfter).to.equal(12)
		end)

		it('carries captured combat models onto rows', function()
			local keep = Instance.new('Model')
			keep.Name = 'Result_a1'
			local extras = { CombatModels = { a1 = keep } }
			local combatant: any = {
				SourceAnimalId = 'a1',
				DefinitionId = 'Dog',
				DisplayName = 'Dog',
				Level = 5,
				Alive = false,
			}
			local rows = ArenaService._TestBuildResultAnimals({ combatant }, function()
				return nil
			end, extras)
			expect(#rows).to.equal(1)
			expect(rows[1].CombatModel).to.equal(keep)
			-- Dead participants still get rows AND keepsakes.
			expect(rows[1].Alive).to.equal(false)
			keep:Destroy()
		end)
	end)

	describe('ArenaResult reward pipeline', function()
		it('exposes the 100x animal XP multiplier in config', function()
			expect(ArenaConfig.AnimalXPMultiplier()).to.equal(100)
		end)

		local function rewardHarness()
			local moneyLog: { any } = {}
			local arenaXPLog: { any } = {}
			local animalXPLog: { any } = {}
			local records: { [string]: any } = {
				a1 = {
					uniqueId = 'a1',
					definitionId = 'Dog',
					displayName = 'Good Boy',
					rarity = 'Rare',
					Level = 12,
					XP = 100,
				},
				a2 = {
					uniqueId = 'a2',
					definitionId = 'Cat',
					displayName = 'Kitty',
					rarity = 'Common',
					Level = 3,
					XP = 0,
				},
			}
			ArenaService.SetEconomyService({
				AddMoney = function(userId: number, amount: string, reason: string, _opts: any)
					moneyLog[#moneyLog + 1] = { userId = userId, amount = amount, reason = reason }
					return { Success = true, NewMoney = '999', TransactionId = 't1' }
				end,
			})
			ArenaService.SetProgressionService({
				RecordLevelWin = function(_userId: number, _stage: number) end,
				AddArenaXP = function(userId: number, amount: number)
					arenaXPLog[#arenaXPLog + 1] = { userId = userId, amount = amount }
					return { LevelsGained = 0, Level = 1 }
				end,
			})
			ArenaService.SetAnimalService({
				Get = function(uid: string)
					return records[uid]
				end,
				-- Test double: commits a visible +2 level bump so the
				-- snapshot's post-grant re-read is provable (real
				-- multi-level draining is covered by the AnimalXP
				-- and LevelUpPresentation suites).
				AddXP = function(_self: any, uid: string, amount: number)
					animalXPLog[#animalXPLog + 1] = { uid = uid, amount = amount }
					local rec = records[uid]
					if rec == nil then
						return { success = false, error = 'no-animal' }
					end
					rec.Level = rec.Level + 2
					rec.XP = (rec.XP or 0) + amount
					return {
						success = true,
						level = rec.Level,
						newXP = rec.XP,
						levelsGained = 2,
						requestedXP = amount,
						appliedXP = amount,
						xpModifier = 1,
					}
				end,
			})
			local function teardown()
				ArenaService.SetEconomyService(nil)
				ArenaService.SetProgressionService(nil)
				ArenaService.SetAnimalService(nil)
				ArenaService._TestReset()
			end
			return {
				moneyLog = moneyLog,
				arenaXPLog = arenaXPLog,
				animalXPLog = animalXPLog,
				records = records,
				teardown = teardown,
			}
		end

		local function victorySession(): { [string]: any }
			return {
				sessionId = 1,
				userId = 7,
				state = 'Active',
				arenaLevel = 3,
				maxLevel = 10,
				rewardAccum = { cash = '250000', xp = 1200 },
				clearedStages = { 1, 2, 3 },
				battle = {
					playerTeam = {
						{ SourceAnimalId = 'a1', DefinitionId = 'Dog', DisplayName = 'Dog', Level = 12, Alive = true },
						{ SourceAnimalId = 'a2', DefinitionId = 'Cat', DisplayName = 'Cat', Level = 3, Alive = false },
					},
				},
			}
		end

		it('victory grants cash + player XP + split animal XP and snapshots actuals', function()
			local h = rewardHarness()
			local outcome: { [string]: any } = { RaidComplete = true, Stage = 3 }
			ArenaService._TestTerminateRaid(7, victorySession(), outcome)
			-- Canonical cash grant with the settled amount.
			expect(#h.moneyLog).to.equal(1)
			expect(h.moneyLog[1].userId).to.equal(7)
			expect(h.moneyLog[1].amount).to.equal('250000')
			expect(h.moneyLog[1].reason).to.equal('ArenaReward')
			-- Player Arena XP uses raw totals (unchanged track).
			expect(#h.arenaXPLog).to.equal(1)
			expect(h.arenaXPLog[1].amount).to.equal(1200)
			-- No damage tracked on this legacy session: the pool
			-- (1200 x 100 = 120000) splits EQUALLY, never lost.
			expect(#h.animalXPLog).to.equal(2)
			expect(h.animalXPLog[1].amount).to.equal(60000)
			expect(h.animalXPLog[2].amount).to.equal(60000)
			-- Real record state changed (not UI-only).
			expect((h.records :: any).a1.Level).to.equal(14)
			-- Payload carries committed values.
			expect(outcome.EarnedCash).to.equal('250000')
			expect(outcome.HighestClearedWave).to.equal(3)
			expect(outcome.Outcome).to.equal('Victory')
			expect(#outcome.Animals).to.equal(2)
			expect(outcome.Animals[1].LevelBefore).to.equal(12)
			expect(outcome.Animals[1].LevelAfter).to.equal(14)
			expect(outcome.Animals[1].XP).to.equal(60000)
			expect(outcome.Animals[1].XPBefore).to.equal(100)
			expect(outcome.Animals[1].XPAfter).to.equal(60100)
			expect(outcome.Animals[2].LevelBefore).to.equal(3)
			expect(outcome.Animals[2].XP).to.equal(60000)
			h.teardown()
		end)

		it('duplicate completion grants nothing twice', function()
			local h = rewardHarness()
			local session = victorySession()
			local outcome: { [string]: any } = { RaidComplete = true, Stage = 3 }
			ArenaService._TestTerminateRaid(7, session, outcome)
			ArenaService._TestTerminateRaid(7, session, outcome)
			expect(#h.moneyLog).to.equal(1)
			expect(#h.arenaXPLog).to.equal(1)
			expect(#h.animalXPLog).to.equal(2)
			h.teardown()
		end)

		it('defeat settles cleared-stage rewards progressively and snapshots actuals', function()
			local h = rewardHarness()
			-- Cleared stages 1-3, wiped on the next stage: the
			-- accumulator (250000 cash / 1200 XP) pays in full.
			local outcome: { [string]: any } = { RaidComplete = false, Stage = 4, Reason = 'wiped' }
			ArenaService._TestTerminateRaid(7, victorySession(), outcome)
			-- Same canonical grants as victory: defeat keeps
			-- cleared-stage rewards.
			expect(#h.moneyLog).to.equal(1)
			expect(h.moneyLog[1].userId).to.equal(7)
			expect(h.moneyLog[1].amount).to.equal('250000')
			expect(h.moneyLog[1].reason).to.equal('ArenaReward')
			expect(#h.arenaXPLog).to.equal(1)
			expect(h.arenaXPLog[1].amount).to.equal(1200)
			expect(#h.animalXPLog).to.equal(2)
			expect(h.animalXPLog[1].amount).to.equal(60000)
			-- Payload carries the committed values for the
			-- result screen (RightSide.Money renders EarnedCash).
			expect(outcome.EarnedCash).to.equal('250000')
			expect(outcome.EarnedXP).to.equal(1200)
			expect(outcome.HighestClearedWave).to.equal(3)
			expect(outcome.Outcome).to.equal('Defeat')
			expect(outcome.Animals[1].XP).to.equal(60000)
			expect(outcome.Animals[1].LevelAfter).to.equal(14)
			h.teardown()
		end)

		it('splits animal XP by damage share and keeps all 3 roster cards', function()
			local h = rewardHarness()
			h.records.a3 = {
				uniqueId = 'a3',
				definitionId = 'Bird',
				displayName = 'Birb',
				rarity = 'Epic',
				Level = 7,
				XP = 50,
			}
			local function member(uid: string, defId: string): any
				return {
					UniqueId = uid,
					DefinitionId = defId,
					DisplayName = defId,
					Rarity = 'Common',
					Level = 5,
				}
			end
			-- Stable roster: 3 locked participants, even though the
			-- final battle lists a1 dead first and a3 dying last.
			local session: { [string]: any } = {
				sessionId = 9,
				userId = 7,
				state = 'Active',
				arenaLevel = 4,
				maxLevel = 10,
				rewardAccum = { cash = '11000', xp = 600 },
				clearedStages = { 1, 2, 3 },
				team = { member('a1', 'Dog'), member('a2', 'Cat'), member('a3', 'Bird') },
				raidHP = { a1 = 0, a2 = 0, a3 = 0 },
				raidAlive = { a1 = false, a2 = false, a3 = false },
				damageDealt = { a1 = 500, a2 = 300, a3 = 200 },
				battle = {
					playerTeam = {
						{ SourceAnimalId = 'a1', DefinitionId = 'Dog', DisplayName = 'Dog', Level = 5, Alive = false },
						{ SourceAnimalId = 'a2', DefinitionId = 'Cat', DisplayName = 'Cat', Level = 5, Alive = false },
						{
							SourceAnimalId = 'a3',
							DefinitionId = 'Bird',
							DisplayName = 'Bird',
							Level = 5,
							Alive = false,
						},
					},
				},
			}
			local outcome: { [string]: any } = { RaidComplete = false, Stage = 4, Reason = 'wiped' }
			ArenaService._TestTerminateRaid(7, session, outcome)
			-- Pool 600 x 100 = 60000 split 50/30/20.
			expect(#h.animalXPLog).to.equal(3)
			local byUid: { [string]: number } = {}
			for _, entry in ipairs(h.animalXPLog) do
				byUid[entry.uid] = entry.amount
			end
			expect(byUid.a1).to.equal(30000)
			expect(byUid.a2).to.equal(18000)
			expect(byUid.a3).to.equal(12000)
			expect(byUid.a1 + byUid.a2 + byUid.a3).to.equal(60000)
			-- All three roster cards survive the wipe, with the
			-- authoritative damage shares attached.
			expect(#outcome.Animals).to.equal(3)
			local rows: { [string]: any } = {}
			for _, row in ipairs(outcome.Animals) do
				rows[row.UniqueId] = row
			end
			-- Deterministic slot order (entry order), never death
			-- order: a1 died first, a3 died last, cards stay a1/a2/a3.
			expect(outcome.Animals[1].UniqueId).to.equal('a1')
			expect(outcome.Animals[2].UniqueId).to.equal('a2')
			expect(outcome.Animals[3].UniqueId).to.equal('a3')
			expect(rows.a1.XP).to.equal(30000)
			expect(rows.a2.XP).to.equal(18000)
			expect(rows.a3.XP).to.equal(12000)
			expect(rows.a1.Damage).to.equal(500)
			expect(rows.a1.DamagePercent).to.be.ok()
			expect(math.abs(rows.a1.DamagePercent - 0.5) < 0.001).to.equal(true)
			expect(rows.a1.Alive).to.equal(false)
			h.teardown()
		end)

		it('2-animal wipe shows both cards in slot order either death order', function()
			local h = rewardHarness()
			local function member(uid: string, defId: string): any
				return {
					UniqueId = uid,
					DefinitionId = defId,
					DisplayName = defId,
					Rarity = 'Common',
					Level = 5,
				}
			end
			local function wipeSession(): { [string]: any }
				return {
					sessionId = 11,
					userId = 7,
					state = 'Active',
					arenaLevel = 2,
					maxLevel = 10,
					rewardAccum = { cash = '5000', xp = 200 },
					clearedStages = { 1 },
					team = { member('a1', 'Dog'), member('a2', 'Cat') },
					raidHP = { a1 = 0, a2 = 0 },
					raidAlive = { a1 = false, a2 = false },
					damageDealt = { a1 = 700, a2 = 300 },
					battle = {
						playerTeam = {
							{
								SourceAnimalId = 'a1',
								DefinitionId = 'Dog',
								DisplayName = 'Dog',
								Level = 5,
								Alive = false,
							},
							{
								SourceAnimalId = 'a2',
								DefinitionId = 'Cat',
								DisplayName = 'Cat',
								Level = 5,
								Alive = false,
							},
						},
					},
				}
			end
			-- Pool 200 x 100 = 20000 split 70/30 = 14000/6000.
			-- Death order is irrelevant: the roster is the locked
			-- team in slot order on every terminal path.
			for _ = 1, 2 do
				local outcome: { [string]: any } = { RaidComplete = false, Stage = 2, Reason = 'wiped' }
				ArenaService._TestTerminateRaid(7, wipeSession(), outcome)
				expect(#outcome.Animals).to.equal(2)
				expect(outcome.Animals[1].UniqueId).to.equal('a1')
				expect(outcome.Animals[2].UniqueId).to.equal('a2')
				expect(outcome.Animals[1].XP).to.equal(14000)
				expect(outcome.Animals[2].XP).to.equal(6000)
			end
			h.teardown()
		end)

		it('defeat with nothing cleared settles $0/0 with no grants', function()
			local h = rewardHarness()
			local session: { [string]: any } = {
				sessionId = 2,
				userId = 7,
				state = 'Active',
				arenaLevel = 1,
				maxLevel = 10,
				rewardAccum = { cash = '0', xp = 0 },
				clearedStages = {},
				battle = { playerTeam = {} },
			}
			local outcome: { [string]: any } = { RaidComplete = false, Stage = 1, Reason = 'wiped' }
			ArenaService._TestTerminateRaid(7, session, outcome)
			expect(#h.moneyLog).to.equal(0)
			expect(#h.arenaXPLog).to.equal(0)
			expect(#h.animalXPLog).to.equal(0)
			expect(outcome.EarnedCash).to.equal('0')
			expect(outcome.EarnedXP).to.equal(0)
			expect(outcome.HighestClearedWave).to.equal(0)
			expect(outcome.Outcome).to.equal('Defeat')
			h.teardown()
		end)
	end)

	describe('ArenaResult client presentation', function()
		it('renders victory/defeat messaging from the finalized outcome', function()
			local msg = ArenaResultController._TestOutcomeMessage
			expect(msg('Victory', true)).to.equal('RAID COMPLETE!')
			expect(msg('Defeat', false)).to.equal('SQUAD DEFEATED')
			expect(msg(nil, true)).to.equal('RAID COMPLETE!')
			expect(msg(nil, false)).to.equal('SQUAD DEFEATED')
		end)

		it('formats levels, money, and wave text', function()
			expect(ArenaResultController._TestLevelText(12)).to.equal('Lv. 12')
			expect(ArenaResultController._TestLevelText(nil)).to.equal('Lv. 1')
			expect(ArenaResultController._TestLevelText(0)).to.equal('Lv. 1')
			expect(ArenaResultController._TestMoneyText('500')).to.equal('$500')
			expect(ArenaResultController._TestMoneyText('1250000')).to.equal('$1.2M')
			expect(ArenaResultController._TestMoneyText(nil)).to.equal('$0')
			expect(ArenaResultController._TestFormatXP(3450)).to.equal('XP 3.4K')
			expect(ArenaResultController._TestFormatXP(nil)).to.equal('XP 0')
			expect(ArenaResultController._TestWaveText(5, 10)).to.equal('5 / 10')
			expect(ArenaResultController._TestWaveText(3, nil)).to.equal('Wave 3')
			expect(ArenaResultController._TestWaveText(nil, nil)).to.equal(nil)
		end)

		it('formats level gain and XP gain rows exactly', function()
			local gain = ArenaResultController._TestLevelGainText
			expect(gain(40, 43)).to.equal('+ 3 Levels')
			expect(gain(55, 55)).to.equal('+ 0 Levels')
			expect(gain(12, 14)).to.equal('+ 2 Levels')
			expect(gain(nil, nil)).to.equal('+ 0 Levels')
			local xpGain = ArenaResultController._TestXpGainText
			expect(xpGain(240)).to.equal('+240 XP')
			expect(xpGain(10000)).to.equal('+10.0K XP')
			expect(xpGain(nil)).to.equal('+0 XP')
			-- Legacy total-XP text is unchanged.
			expect(ArenaResultController._TestFormatXP(3450)).to.equal('XP 3.4K')
		end)

		it('accepts RaidEnd once per completion token', function()
			local accept = ArenaResultController._TestAcceptResult
			local function raidEnd(session: any): any
				return { Action = 'RaidEnd', Success = true, SessionId = session }
			end
			local ok, key = accept(raidEnd(7), nil)
			expect(ok).to.equal(true)
			expect(key).to.equal('7')
			-- Duplicate completion ignored (one screen per raid).
			local ok2, _ = accept(raidEnd(7), '7')
			expect(ok2).to.equal(false)
			-- New raid opens normally.
			local ok3, key3 = accept(raidEnd(8), '7')
			expect(ok3).to.equal(true)
			expect(key3).to.equal('8')
			-- Non-results and malformed payloads ignored.
			local ok4, _ = accept({ Action = 'Cancel', Success = true }, nil)
			expect(ok4).to.equal(false)
			local ok5, _ = accept(nil, nil)
			expect(ok5).to.equal(false)
		end)

		it('resolves level boxes through the Title child, never the container', function()
			local resolve = ArenaResultController._TestResolveLevelLabel
			-- Authored shape: CurrentLevel (Frame) -> Title (TextLabel).
			local card = Instance.new('Frame')
			local box = Instance.new('Frame')
			box.Name = 'CurrentLevel'
			box.Parent = card
			local title = Instance.new('TextLabel')
			title.Name = 'Title'
			title.Text = 'Lvl 40'
			title.Parent = box
			expect(resolve(card, 'CurrentLevel')).to.equal(title)
			-- Flat variant (direct TextLabel) still resolves.
			local flat = Instance.new('Frame')
			local direct = Instance.new('TextLabel')
			direct.Name = 'NewLevel'
			direct.Parent = flat
			expect(resolve(flat, 'NewLevel')).to.equal(direct)
			-- Missing box or missing Title child resolves nil
			-- (paint then skips instead of writing the container).
			local empty = Instance.new('Frame')
			expect(resolve(empty, 'CurrentLevel')).to.equal(nil)
			local noTitle = Instance.new('Frame')
			local bare = Instance.new('Frame')
			bare.Name = 'NewLevel'
			bare.Parent = noTitle
			expect(resolve(noTitle, 'NewLevel')).to.equal(nil)
			expect(resolve(nil, 'CurrentLevel')).to.equal(nil)
			card:Destroy()
			flat:Destroy()
			empty:Destroy()
			noTitle:Destroy()
		end)

		it('normalizes cards: caps at six with display-safe fallbacks', function()
			local pick = ArenaResultController._TestPickCards
			local animals: { any } = { 'junk' }
			for i = 1, 7 do
				animals[#animals + 1] = {
					DisplayName = 'Dog' .. tostring(i),
					Rarity = 'Rare',
					LevelBefore = 10 + i,
					LevelAfter = 10 + i,
					XP = 100 * i,
				}
			end
			local rows = pick(animals)
			expect(#rows).to.equal(6)
			expect(rows[1].Title).to.equal('Dog1')
			expect(rows[6].Title).to.equal('Dog6')
			expect(rows[1].Rarity).to.equal('Rare')
			expect(rows[1].LevelBefore).to.equal(11)
			expect(rows[1].XP).to.equal(100)
			-- No Model field exists: CombatModel is the only
			-- viewport source (nil without a keepsake).
			expect(rows[1].CombatModel).to.equal(nil)
			expect(rows[1].UniqueId).to.equal('?')
			-- Identity rides along for viewport logging (never a lookup key).
			expect(rows[1].DefinitionId).to.equal('?')
			expect(rows[1].Trait).to.equal('Normal')
			local identified = pick({
				{ DisplayName = 'Jerboa', UniqueId = 'uid-j', DefinitionId = 'Jerboa', Rarity = 'Epic', Trait = 'Gold' },
			})
			expect(identified[1].DefinitionId).to.equal('Jerboa')
			expect(identified[1].Trait).to.equal('Gold')
			expect(identified[1].UniqueId).to.equal('uid-j')
			-- Empty animal normalizes to safe fallbacks.
			local fallback = pick({ {} })
			expect(#fallback).to.equal(1)
			expect(fallback[1].Title).to.equal('Animal')
			expect(fallback[1].Rarity).to.equal('?')
			expect(fallback[1].LevelBefore).to.equal(1)
			expect(fallback[1].XP).to.equal(0)
			-- A legacy stand-model Model ref is IGNORED entirely
			-- (viewport skips without a keepsake; error logged).
			local part = Instance.new('Part')
			local withPart = pick({ { DisplayName = 'X', UniqueId = 'uX', Model = part } })
			expect(withPart[1].CombatModel).to.equal(nil)
			expect(withPart[1].UniqueId).to.equal('uX')
			part:Destroy()
			-- Combat keepsakes pass through; non-models are dropped.
			local keep = Instance.new('Model')
			local withKeep = pick({ { DisplayName = 'Y', CombatModel = keep } })
			expect(withKeep[1].CombatModel).to.equal(keep)
			keep:Destroy()
			local withBadKeep = pick({ { DisplayName = 'Z', CombatModel = part } })
			expect(withBadKeep[1].CombatModel).to.equal(nil)
			expect(#pick(nil)).to.equal(0)
		end)
	end)
end
