--!strict
--[[
	Leaderboards — consolidated tunables (REFERENCE MODULE)

	=====================================================================
	THIS FILE IS DOCUMENTATION, NOT LIVE CONFIGURATION.
	=====================================================================

	Neither `LeaderboardService` nor `TabListService` requires this
	module. Every value below is a *transcription* of a public constant
	that lives on the service module itself:

		ServerScriptService.Leaderboard.LeaderboardService.ORDERED_STORE_NAME
		ServerScriptService.Leaderboard.LeaderboardService.META_STORE_NAME
		ServerScriptService.Leaderboard.LeaderboardService.MAX_ENTRIES
		ServerScriptService.Leaderboard.LeaderboardService.REFRESH_SECONDS
		ServerScriptService.Leaderboard.LeaderboardService.FLUSH_SECONDS
		ServerScriptService.Leaderboard.LeaderboardService.SCAN_SECONDS
		ServerScriptService.Leaderboard.LeaderboardService.MAX_WRITES_PER_FLUSH
		ServerScriptService.Leaderboard.LeaderboardService.EARLY_REFRESH_COOLDOWN
		ServerScriptService.Leaderboard.LeaderboardService.RANK_COLORS
		ServerScriptService.TabList.TabListService.PUSH_SECONDS
		ServerScriptService.TabList.TabListService.EARLY_PUSH_COOLDOWN
		ServerScriptService.TabList.TabListService.FOLDER_NAME
		ServerScriptService.TabList.TabListService.REBIRTHS_STAT
		ServerScriptService.TabList.TabListService.MONEY_STAT

	TO CHANGE A VALUE: edit the constant on the service module, not
	this file. Editing this file changes nothing at runtime.

	Why it is like this: the Leaderboards system has no config module of
	its own — no `ReplicatedStorage/Config/...` domain, and no entry in
	`ConfigValidator._MODULES`. Putting the tunables on the service
	module keeps the system self-contained (two files, zero config
	dependencies). This file exists so a reader can see all the tunables
	in one place with their meaning, range, and safety.

	There are no placeholders and no secrets in this system. The only
	environment-specific values are the two DataStore names.
]]

local Config = {}

-- =====================================================================
-- DataStore names
-- =====================================================================

--[[
	ORDERED_STORE_NAME

	Default:  'p7_GlobalLeaderboardMoney_v1'
	Meaning:  Name of the OrderedDataStore that holds the sortable
	          integer score for the global money board.
	Range:    any non-empty string; must be unique per game AND per
	          environment (dev/live) to avoid cross-game contamination.
	Safe to change:  YES — but it ABANDONS the existing rows. The old
	          store is not read again and not migrated. Every player
	          re-ranks from zero.
	Read by:  LeaderboardService.getStores() (via DataStoreService)
	Placeholder: NO — but the 'p7_' prefix is Brainrot Arena specific and
	          MUST be changed by a new game. Suggest:
	              ('%s_GlobalLeaderboardMoney_v1_%s'):format(GAME_PREFIX, ENV)
]]
Config.ORDERED_STORE_NAME = 'p7_GlobalLeaderboardMoney_v1'

--[[
	META_STORE_NAME

	Default:  'p7_GlobalLeaderboardMeta_v1'
	Meaning:  Name of the standard (Global) DataStore holding the exact
	          money string and the username for each ranked user, keyed
	          by tostring(userId). Needed because OrderedDataStore values
	          can only be integers, so the exact fortune cannot live
	          there.
	Range:    any non-empty string; same uniqueness rule as above.
	Safe to change:  YES — abandoning it loses the exact displayed
	          fortune for offline players (the board falls back to '0'
	          money for keys with no cached meta) but the ranking itself
	          still works from the ordered store.
	Read by:  LeaderboardService.getStores()
	Placeholder: NO — same 'p7_' prefix requirement.
]]
Config.META_STORE_NAME = 'p7_GlobalLeaderboardMeta_v1'

-- =====================================================================
-- Global board (LeaderboardService)
-- =====================================================================

--[[
	MAX_ENTRIES

	Default:  10
	Meaning:  How many rows the global board renders. Also the
	          GetSortedAsync page size, so it bounds the number of
	          meta GetAsync calls per refresh.
	Range:    1 .. 50 (practical DataStore page limit is 100; the
	          Studio board only has room for a handful of rows).
	Safe to change:  YES. Lowering it hides lower ranks AND reduces
	          DataStore reads. The row pool grows to the new size
	          automatically; rows beyond the new count are hidden, not
	          destroyed.
	Read by:  LeaderboardService.renderBoard(), LeaderboardService.RefreshNow()
	Placeholder: NO
]]
Config.MAX_ENTRIES = 10

--[[
	REFRESH_SECONDS

	Default:  60
	Meaning:  How often the global board re-reads the OrderedDataStore
	          (one GetSortedAsync) and re-renders.
	Range:    15 .. 600. Roblox throttles DataStore reads per server;
	          60 s is conservative.
	Safe to change:  YES. The first refresh happens 5 s after Start(),
	          not after REFRESH_SECONDS.
	Read by:  LeaderboardService.RefreshNow(), the maintenance loop
	Placeholder: NO
]]
Config.REFRESH_SECONDS = 60

--[[
	FLUSH_SECONDS

	Default:  15
	Meaning:  The maintenance loop tick period. Every tick the service
	          scans (if due), flushes dirty snapshots, and refreshes the
	          board (if due). Also the maximum delay between a dirty
	          snapshot being queued and written.
	Range:    5 .. 60. Lower = more responsive board, more DataStore
	          writes.
	Safe to change:  YES, but it multiplies the write rate: each tick
	          can write up to MAX_WRITES_PER_FLUSH entries.
	Read by:  LeaderboardService.Start() (the maintenance loop)
	Placeholder: NO
]]
Config.FLUSH_SECONDS = 15

--[[
	SCAN_SECONDS

	Default:  30
	Meaning:  How often the service walks every in-server player to
	          enqueue changed snapshots. This is how ordinary money
	          gains (not just rebirths) reach the board.
	Range:    10 .. 300.
	Safe to change:  YES. A snapshot is only enqueued when the score
	          differs from the last successfully written one, so a
	          frequent scan is cheap but not free (it reads the profile
	          for every player).
	Read by:  LeaderboardService.scanServer()
	Placeholder: NO
]]
Config.SCAN_SECONDS = 30

--[[
	MAX_WRITES_PER_FLUSH

	Default:  10
	Meaning:  Cap on how many player snapshots are written per flush.
	          Each snapshot is 2 DataStore calls (ordered + meta).
	Range:    1 .. 50. 10 entries = up to 20 calls per flush.
	Safe to change:  YES. Lowering it throttles the write budget but
	          delays the tail of the queue; a failed write still counts
	          against the cap (deliberately — a dead store must not spin
	          the budget).
	Read by:  LeaderboardService.flushDirty()
	Placeholder: NO
]]
Config.MAX_WRITES_PER_FLUSH = 10

--[[
	EARLY_REFRESH_COOLDOWN

	Default:  20
	Meaning:  Minimum gap between join/leave-triggered early board
	          refreshes. Prevents presence churn from burning the
	          GetSortedAsync budget.
	Range:    5 .. 300.
	Safe to change:  YES. NOTE: this throttles RequestRefresh() only.
	          RefreshNow() called directly is NOT throttled.
	Read by:  LeaderboardService.RequestRefresh()
	Placeholder: NO
]]
Config.EARLY_REFRESH_COOLDOWN = 20

--[[
	RANK_COLORS

	Default:  Gold  RGB(255, 215, 80)
	          Silver RGB(210, 215, 220)
	          Bronze RGB(205, 135, 75)
	          Rest   RGB(225, 225, 225)
	Meaning:  Tint applied to the rank, name and money text of each
	          board row. Ranks 1/2/3 get the medal colours; 4+ get Rest.
	          The top-player block (the SurfaceGui-level labels) is
	          always Gold regardless of this table.
	Range:    any Color3.
	Safe to change:  YES — cosmetic only. The spec
	          (Tests/Leaderboard.spec.lua) pins the exact RGB values,
	          so update the spec if you change them.
	Read by:  LeaderboardService.RankColor(), LeaderboardService.paintRow()
	Placeholder: NO
]]
Config.RANK_COLORS = {
	Gold = Color3.fromRGB(255, 215, 80),
	Silver = Color3.fromRGB(210, 215, 220),
	Bronze = Color3.fromRGB(205, 135, 75),
	Rest = Color3.fromRGB(225, 225, 225),
}

-- =====================================================================
-- Tab list (TabListService)
-- =====================================================================

--[[
	PUSH_SECONDS

	Default:  15
	Meaning:  How often the leaderstats values are refreshed from the
	          server-side profile (when nothing is dirty).
	Range:    5 .. 120. The values are cheap live reads, and Roblox
	          dedupes unchanged replicated values.
	Safe to change:  YES.
	Read by:  TabListService.Start() (the refresh loop)
	Placeholder: NO
]]
Config.PUSH_SECONDS = 15

--[[
	EARLY_PUSH_COOLDOWN

	Default:  5
	Meaning:  Minimum gap between join/leave/dirty-triggered refreshes.
	          It is ALSO the loop tick period, so the tab list can
	          never refresh more often than every 5 s.
	Range:    1 .. 60.
	Safe to change:  YES. Lowering it makes the loop spin faster
	          (it wakes up more often) without making the effective
	          refresh rate faster than PUSH_SECONDS unless you also
	          lower that.
	Read by:  TabListService.RequestRefresh(), TabListService.Start()
	Placeholder: NO
]]
Config.EARLY_PUSH_COOLDOWN = 5

--[[
	FOLDER_NAME

	Default:  'leaderstats'
	Meaning:  The name of the native leaderboard folder created on the
	          Player. Roblox's CoreGui PlayerList only renders a
	          folder with exactly this name.
	Range:    must remain 'leaderstats' unless you are willing to lose
	          the native player list entirely.
	Safe to change:  NO in practice.
	Read by:  TabListService.EnsureLeaderstats()
	Placeholder: NO
]]
Config.FOLDER_NAME = 'leaderstats'

--[[
	REBIRTHS_STAT

	Default:  'Rebirths'
	Meaning:  Name of the first child of `leaderstats`. An IntValue.
	          Being the FIRST child makes it the native primary sort
	          key, so the tab list ranks by rebirths.
	Range:    any non-empty string.
	Safe to change:  YES (the spec pins the name 'Rebirths'; update it
	          if you rename). The ORDER is the load-bearing part, not
	          the name.
	Read by:  TabListService.EnsureLeaderstats(), .RefreshValues()
	Placeholder: NO
]]
Config.REBIRTHS_STAT = 'Rebirths'

--[[
	MONEY_STAT

	Default:  'Money'
	Meaning:  Name of the second child of `leaderstats`. A StringValue
	          holding the game-formatted fortune (e.g. '1.0Qa').
	          A StringValue is deliberate: a NumberValue cannot hold a
	          BigNumber fortune, and a raw integer would render
	          unreadably huge. It is DISPLAY ONLY — the native list sorts
	          on the Rebirths stat.
	Range:    any non-empty string.
	Safe to change:  YES (the spec pins the name 'Money'; update it if
	          you rename).
	Read by:  TabListService.EnsureLeaderstats(), .RefreshValues()
	Placeholder: NO
]]
Config.MONEY_STAT = 'Money'

return table.freeze(Config)
