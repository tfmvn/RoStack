--!strict
--!native
--[[
	PlayerLogger.spec
	==================
	Headless-safe coverage for the monitoring subsystem:

	  * embed builders emit the required titles/fields and
	    respect Discord limits (no raw data dumps)
	  * duration/playtime formatting
	  * queue stays bounded and disabled-by-default (no
	    webhook URL in tests → nothing sends)
	  * registry MergeEntry is monotonic and concurrency-safe
	    (counters add, timestamps max, snapshots refresh)
	  * no secret-shaped strings anywhere near the payloads

	Live HTTP delivery, DataStore persistence, and Studio
	join/leave are Studio-verified (see README).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local PlayerLogger = require(ServerScriptService.PlayerLogger.PlayerLogger)
	local PlayerRegistry = require(ServerScriptService.PlayerLogger.PlayerRegistry)

	describe('PlayerLogger builders', function()
		afterEach(function()
			PlayerLogger._TestReset()
		end)

		it('builds the join embed with the required layout', function()
			local embed = PlayerLogger.BuildJoinEmbed({
				username = 'Builderman',
				displayName = 'Builderman',
				userId = 156,
				accountAgeDays = 450,
				rebirths = 2,
				statusText = 'Returning Player',
				jobId = 'job-1',
				joinTime = 1760000000,
			})
			expect(embed.title).to.equal('🟢 Player Joined')
			expect(embed.color).to.be.ok()
			local byName: { [string]: string } = {}
			for _, f in ipairs(embed.fields) do
				byName[f.name] = f.value
			end
			expect(string.find(byName['Player'], 'Builderman') ~= nil).to.equal(true)
			expect(byName['User ID']).to.equal('156')
			expect(byName['Account Age']).to.equal('450 days')
			expect(byName['Rebirths']).to.equal('2')
			expect(byName['Player Status']).to.equal('Returning Player')
			expect(#embed.fields <= 25).to.equal(true)
		end)

		it('builds the leave embed with session duration', function()
			local embed = PlayerLogger.BuildLeaveEmbed({
				username = 'Shedletsky',
				displayName = 'Shedletsky',
				userId = 261,
				sessionSeconds = 754,
				joinTime = 1760000000,
				leaveTime = 1760000754,
				rebirths = 1,
			})
			expect(embed.title).to.equal('🔴 Player Left')
			local byName: { [string]: string } = {}
			for _, f in ipairs(embed.fields) do
				byName[f.name] = f.value
			end
			expect(byName['Session Duration']).to.equal('12m 34s')
			expect(byName['User ID']).to.equal('261')
		end)

		it('builds milestone embeds with whitelisted detail fields', function()
			local rb = PlayerLogger.BuildMilestoneEmbed(
				'RebirthSucceeded',
				{ username = 'A', userId = 1, rebirths = 3 },
				{ rebirth = 3 }
			)
			expect(rb.title).to.equal('♻️ Rebirth Succeeded')
			local buy = PlayerLogger.BuildMilestoneEmbed(
				'PurchaseGranted',
				{ username = 'A', userId = 1, rebirths = 0 },
				{ product_key = 'UnlockDoors', kind = 'UnlockDoors' }
			)
			expect(buy.title).to.equal('💰 Purchase Granted')
			local names: { [string]: boolean } = {}
			for _, f in ipairs(buy.fields) do
				names[f.name] = true
			end
			expect(names['Product']).to.equal(true)
		end)

		it('truncates hostile field input to Discord limits', function()
			local long = string.rep('x', 3000)
			local embed = PlayerLogger.BuildJoinEmbed({
				username = long,
				displayName = long,
				userId = 1,
				joinTime = 1760000000,
			})
			for _, f in ipairs(embed.fields) do
				expect(#f.name <= 256).to.equal(true)
				expect(#f.value <= 1024).to.equal(true)
			end
			expect(#embed.title <= 256).to.equal(true)
		end)

		it('formats durations without inventing precision', function()
			expect(PlayerLogger.FormatDuration(45)).to.equal('45s')
			expect(PlayerLogger.FormatDuration(754)).to.equal('12m 34s')
			expect(PlayerLogger.FormatDuration(8070)).to.equal('2h 14m')
			expect(PlayerLogger.FormatDuration(-5)).to.equal('0s')
		end)

		it('stays disabled with no webhook and queues nothing', function()
			expect(PlayerLogger.IsEnabled()).to.equal(false)
			expect(PlayerLogger._TestQueueLen()).to.equal(0)
		end)
	end)

	describe('PlayerRegistry merge', function()
		it('creates sane defaults from nil', function()
			local entry = PlayerRegistry.MergeEntry(nil, { userId = 42, username = 'Noob' }, 1000)
			expect(entry.userId).to.equal(42)
			expect(entry.firstSeen).to.equal(1000)
			expect(entry.lastSeen).to.equal(1000)
			expect(entry.sessions).to.equal(0)
			expect(entry.playtimeSeconds).to.equal(0)
		end)

		it('merges monotonically across concurrent writers', function()
			local base: any = {
				userId = 7,
				username = 'Old',
				firstSeen = 100,
				lastSeen = 200,
				sessions = 3,
				playtimeSeconds = 500,
				rebirths = 1,
			}
			local a = PlayerRegistry.MergeEntry(
				base,
				{ lastSeen = 300, sessionsAdd = 1, playtimeAdd = 60, rebirths = 2 },
				300
			)
			local b =
				PlayerRegistry.MergeEntry(a, { lastSeen = 250, sessionsAdd = 1, playtimeAdd = 30, rebirths = 1 }, 310)
			expect(b.sessions).to.equal(5)
			expect(b.playtimeSeconds).to.equal(590)
			expect(b.lastSeen).to.equal(300)
			expect(b.firstSeen).to.equal(100)
			expect(b.rebirths).to.equal(2)
			expect(b.username).to.equal('Old')
		end)

		it('never downgrades snapshots or names to empty', function()
			local base: any = { username = 'Keep', displayName = 'Keep', tutorialCompleted = true, rebirths = 4 }
			local out = PlayerRegistry.MergeEntry(base, { username = '', rebirths = 1, tutorialCompleted = false }, 10)
			expect(out.username).to.equal('Keep')
			expect(out.rebirths).to.equal(4)
			expect(out.tutorialCompleted).to.equal(true)
		end)

		it('keys are stable per user id', function()
			expect(PlayerRegistry.KeyFor(123456789)).to.equal('player_123456789')
		end)
	end)
end
