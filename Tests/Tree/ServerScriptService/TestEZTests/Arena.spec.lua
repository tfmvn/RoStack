--!strict
--!native
--[[
	Arena.spec
	==========
	Phase 1 headless coverage: ArenaConfig pure rules,
	ArenaProgressionService normalization + level-up math
	(with an injected fake PlayerService, no DataStore),
	and ArenaService fail-closed validation (no live player
	needed for the rejection paths).
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerScriptService = game:GetService('ServerScriptService')

	local ArenaConfig = require(ReplicatedStorage.Config.World.Arena)

	local function fakePlayerService(profiles: { [number]: any })
		return {
			GetPlayerData = function(userId: number)
				return profiles[userId]
			end,
		}
	end

	describe('ArenaConfig', function()
		it('ships fifty levels in stable order with boss every 10', function()
			local all = ArenaConfig.GetAll()
			expect(#all).to.equal(50)
			expect(ArenaConfig.MaxLevel()).to.equal(50)
			for i, entry in ipairs(all) do
				expect(entry.Level).to.equal(i)
				expect(entry.Boss).to.equal(ArenaConfig.IsBossLevel(i))
			end
			expect(ArenaConfig.IsBossLevel(5)).to.equal(false)
			expect(ArenaConfig.IsBossLevel(10)).to.equal(true)
			expect(ArenaConfig.IsBossLevel(50)).to.equal(true)
			expect(ArenaConfig.IsBossLevel(1)).to.equal(false)
			expect(ArenaConfig.IsBossLevel(0)).to.equal(false)
		end)

		it('FindLevel resolves by level number only', function()
			local found = ArenaConfig.FindLevel(3)
			expect(found).to.be.ok()
			expect((found :: any).Name).to.equal('Meadow Hunter')
			expect(ArenaConfig.FindLevel(99)).to.equal(nil)
			expect(ArenaConfig.FindLevel('3' :: any)).to.equal(nil)
		end)

		it('unlock rule gates above progression', function()
			expect(ArenaConfig.IsUnlocked(1, 1)).to.equal(true)
			expect(ArenaConfig.IsUnlocked(1, 2)).to.equal(false)
			expect(ArenaConfig.IsUnlocked(4, 4)).to.equal(true)
			expect(ArenaConfig.IsUnlocked(4, 5)).to.equal(false)
			expect(ArenaConfig.IsUnlocked(1, 99)).to.equal(false)
		end)

		it('XPRequired scales and caps', function()
			-- Exponential player track (5 * 1.25^(L-1)): a
			-- frontier full-clear settles ~2x one threshold.
			expect(ArenaConfig.XPRequired(1)).to.equal(5)
			expect(ArenaConfig.XPRequired(9)).to.equal(30)
			expect(ArenaConfig.XPRequired(10)).to.equal(37)
			expect(ArenaConfig.XPRequired(49)).to.equal(224208)
			expect(ArenaConfig.XPRequired(50)).to.equal(nil)
			expect(ArenaConfig.XPRequired(0)).to.equal(nil)
		end)

		it('ValidateList accepts the live catalog', function()
			expect(#ArenaConfig.ValidateList(ArenaConfig.GetAll())).to.equal(0)
			expect(#ArenaConfig.ValidateLive()).to.equal(0)
		end)

		it('ValidateList rejects bad shapes', function()
			local bad = {
				{ Level = 2, Name = 'X', Description = 'd', Boss = false, Rewards = { ArenaXP = 1, Cash = '1' } },
			}
			local issues = ArenaConfig.ValidateList(bad)
			expect(#issues > 0).to.equal(true)
		end)

		it('dialogue always returns lines', function()
			expect(#ArenaConfig.Dialogue('Boss') > 0).to.equal(true)
			expect(#ArenaConfig.Dialogue('Nope') > 0).to.equal(true)
		end)
	end)

	describe('ArenaProgressionService', function()
		it('normalizes missing and malformed fields', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local data: any = {}
			local arena = Progression.NormalizeArena(data)
			expect(arena).to.be.ok()
			expect((arena :: any).Level).to.equal(1)
			expect((arena :: any).XP).to.equal(0)
			expect((arena :: any).Wins).to.equal(0)
			expect((arena :: any).HighestCompleted).to.equal(0)
			expect(type((arena :: any).PendingEggs)).to.equal('table')
			local bad: any = { Arena = { Level = 99, XP = -5, Wins = 'x', HighestCompleted = -3, PendingEggs = 4 } }
			local fixed = Progression.NormalizeArena(bad)
			expect((fixed :: any).Level).to.equal(ArenaConfig.MaxLevel())
			expect((fixed :: any).XP).to.equal(0)
			expect((fixed :: any).Wins).to.equal(0)
			expect((fixed :: any).HighestCompleted).to.equal(0)
			expect(type((fixed :: any).PendingEggs)).to.equal('table')
			expect(Progression.NormalizeArena(nil)).to.equal(nil)
		end)

		it('normalizes LastReached and records reached stages', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local data: any = {}
			local arena = Progression.NormalizeArena(data)
			expect((arena :: any).LastReached).to.equal(0)
			local bad: any = { Arena = { LastReached = -4 } }
			expect((Progression.NormalizeArena(bad) :: any).LastReached).to.equal(0)
			local high: any = { Arena = { LastReached = 99 } }
			expect((Progression.NormalizeArena(high) :: any).LastReached).to.equal(ArenaConfig.MaxLevel())
		end)

		it('tracks LastReached with max semantics', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			Progression.SetPlayerService(fakePlayerService({ [779] = {} }))
			expect(Progression.GetLastReached(779)).to.equal(0)
			expect(Progression.GetLastReached(424242)).to.equal(0)
			expect(Progression.RecordReachedLevel(779, 5)).to.equal(5)
			expect(Progression.GetLastReached(779)).to.equal(5)
			expect(Progression.RecordReachedLevel(779, 3)).to.equal(5)
			expect(Progression.RecordReachedLevel(779, 8)).to.equal(8)
			expect(Progression.GetLastReached(779)).to.equal(8)
			Progression._TestReset()
		end)

		it('levels up through thresholds and caps at max', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local arena: any = { Level = 1, XP = 0, Wins = 0, PendingEggs = {} }
			local r1 = Progression.AddXPToData(arena, 50)
			expect(r1.LevelsGained).to.equal(0)
			expect(arena.Level).to.equal(1)
			expect(arena.XP).to.equal(50)
			local r2 = Progression.AddXPToData(arena, 60)
			expect(r2.LevelsGained).to.equal(1)
			expect(arena.Level).to.equal(2)
			expect(arena.XP).to.equal(10)
			local top: any = { Level = ArenaConfig.MaxLevel(), XP = 0, Wins = 0, PendingEggs = {} }
			local r3 = Progression.AddXPToData(top, 99999)
			expect(r3.LevelsGained).to.equal(0)
			expect(top.Level).to.equal(ArenaConfig.MaxLevel())
		end)

		it('reads fail closed without a profile', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			Progression.SetPlayerService(fakePlayerService({}))
			expect(Progression.GetArenaLevel(424242)).to.equal(1)
			expect(Progression.GetArenaXP(424242)).to.equal(0)
			expect(Progression.IsUnlocked(424242, 2)).to.equal(false)
			local state = Progression.GetArenaState(424242)
			expect(state.Level).to.equal(1)
			Progression._TestReset()
		end)

		it('AddArenaXP persists through the injected profile', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local profile: any = {}
			Progression.SetPlayerService(fakePlayerService({ [777] = profile }))
			local result = Progression.AddArenaXP(777, 120)
			expect(result.LevelsGained).to.equal(1)
			expect(Progression.GetArenaLevel(777)).to.equal(2)
			expect(Progression.RecordWin(777)).to.equal(1)
			Progression._TestReset()
		end)

		it('wins unlock without touching XP progression', function()
			local Progression = require(ServerScriptService.Arena.ArenaProgressionService)
			local profile: any = {}
			Progression.SetPlayerService(fakePlayerService({ [778] = profile }))
			expect(Progression.IsUnlocked(778, 2)).to.equal(false)
			local first = Progression.RecordLevelWin(778, 1)
			expect(first.FirstClear).to.equal(true)
			expect(first.HighestCompleted).to.equal(1)
			expect(Progression.IsUnlocked(778, 2)).to.equal(true)
			expect(Progression.GetArenaLevel(778)).to.equal(1)
			local repeatWin = Progression.RecordLevelWin(778, 1)
			expect(repeatWin.FirstClear).to.equal(false)
			expect(Progression.GetArenaLevel(778)).to.equal(1)
			Progression._TestReset()
		end)
	end)

	describe('ArenaService', function()
		it('loads and resets cleanly', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			expect(ArenaService).to.be.ok()
			ArenaService._TestReset()
			expect(ArenaService.GetSession(31337)).to.equal(nil)
			expect(ArenaService.ResolveTeam(31337).count).to.equal(0)
		end)

		it('rejects starts without a live player', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local Helpers = require(script.Parent._Helpers)
			local player = Helpers.FakePlayer(31338)
			local started = ArenaService.StartArena(player, 1)
			expect(started.success).to.equal(false)
			expect(started.error).to.equal('invalid-player')
			local checked = ArenaService.ValidateStart(player, 1)
			expect(checked.ok).to.equal(false)
			local cancelled = ArenaService.CancelArena(player)
			expect(cancelled.success).to.equal(false)
			ArenaService._TestReset()
		end)

		it('area discovery fails closed without markers', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local area = ArenaService.ResolveArenaArea(nil)
			expect(area.ready).to.equal(false)
			expect(#area.missing > 0).to.equal(true)
			ArenaService._TestReset()
		end)
	end)

	describe('ArenaService.EnsureAdventurer', function()
		-- Fake bases are plain tables (folder + spawnCFrame);
		-- folders stay unparented (zero Workspace pollution).
		local function fakeBase(suffix: string): any
			local folder = Instance.new('Folder')
			folder.Name = 'Base_' .. suffix
			return {
				id = 'Base_' .. suffix,
				folder = folder,
				spawnCFrame = CFrame.new(0, 5, 0),
			}
		end

		local function stagePart(parent: Instance, name: string): Part
			local part = Instance.new('Part')
			part.Name = name
			part.Anchored = true
			part.Parent = parent
			return part
		end

		local function promptCount(folder: Instance): number
			local n = 0
			for _, desc in ipairs(folder:GetDescendants()) do
				if desc:IsA('ProximityPrompt') then
					n += 1
				end
			end
			return n
		end

		local function tempCount(folder: Instance): number
			local n = 0
			for _, child in ipairs(folder:GetChildren()) do
				if
					(child.Name == 'Adventurer' or child.Name == 'Adv')
					and child:GetAttribute('ArenaTemporary') == true
				then
					n += 1
				end
			end
			return n
		end

		it('uses an authored Adv model without creating a duplicate', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local base = fakeBase('adv1')
			local adv = Instance.new('Model')
			adv.Name = 'Adv'
			adv.Parent = base.folder
			local host = stagePart(adv, 'Body')
			expect(ArenaService.EnsureAdventurer(base)).to.equal(true)
			-- No temporary NPC spawned alongside it.
			expect(tempCount(base.folder)).to.equal(0)
			-- Prompt wired on the Adv model's part, exactly once.
			expect(promptCount(base.folder)).to.equal(1)
			expect(host:FindFirstChildOfClass('ProximityPrompt') ~= nil).to.equal(true)
			-- Idempotent: a second call wires nothing new.
			expect(ArenaService.EnsureAdventurer(base)).to.equal(true)
			expect(tempCount(base.folder)).to.equal(0)
			expect(promptCount(base.folder)).to.equal(1)
			base.folder:Destroy()
			ArenaService._TestReset()
		end)

		it('prefers full Adventurer over Adv and temp over nothing', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local base = fakeBase('adv2')
			local adv = Instance.new('Model')
			adv.Name = 'Adv'
			adv.Parent = base.folder
			stagePart(adv, 'Body')
			local full = stagePart(base.folder, 'Adventurer')
			expect(ArenaService.EnsureAdventurer(base)).to.equal(true)
			expect(tempCount(base.folder)).to.equal(0)
			-- The prompt lands on the full Adventurer, not Adv.
			expect(full:FindFirstChildOfClass('ProximityPrompt') ~= nil).to.equal(true)
			base.folder:Destroy()
			ArenaService._TestReset()
		end)

		it('creates exactly one temporary NPC when nothing authored exists', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local base = fakeBase('adv3')
			expect(ArenaService.EnsureAdventurer(base)).to.equal(true)
			expect(tempCount(base.folder)).to.equal(1)
			local temp = base.folder:FindFirstChild('Adventurer')
			assert(temp ~= nil, 'temporary Adventurer created')
			expect((temp :: Instance):GetAttribute('ArenaTemporary')).to.equal(true)
			expect(ArenaService.EnsureAdventurer(base)).to.equal(true)
			expect(tempCount(base.folder)).to.equal(1)
			base.folder:Destroy()
			ArenaService._TestReset()
		end)

		it('an Adv model with no BasePart fails closed without crashing', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			local base = fakeBase('adv4')
			local adv = Instance.new('Model')
			adv.Name = 'Adv'
			adv.Parent = base.folder
			local note = Instance.new('StringValue')
			note.Name = 'Note'
			note.Parent = adv
			expect(ArenaService.EnsureAdventurer(base)).to.equal(false)
			expect(tempCount(base.folder)).to.equal(0)
			base.folder:Destroy()
			ArenaService._TestReset()
		end)

		it('rejects bases without folders', function()
			local ArenaService = require(ServerScriptService.Arena.ArenaService)
			expect(ArenaService.EnsureAdventurer(nil)).to.equal(false)
			expect(ArenaService.EnsureAdventurer({ id = 'Base_x' })).to.equal(false)
			ArenaService._TestReset()
		end)
	end)
end
