--!strict
--[[
	CodesAndRewards — consolidated tunables (REFERENCE MODULE)

	=====================================================================
	THIS FILE IS DOCUMENTATION, NOT LIVE CONFIGURATION.
	=====================================================================

	The LIVE config for this system is already part of the system:

		ReplicatedStorage/Config/Economy/Rewards.lua
			.Codes    -- the redeem-code catalog
			.Daily    -- the weekly daily-rewards pools
			.Playtime -- the session playtime-rewards pools

	That file is in this system's `Source/` tree, at its original
	Roblox path, and it is what the three services actually require
	(`require(ReplicatedStorage.Config.Economy.Rewards).Codes`, etc.).

	TO CHANGE A VALUE: edit `Source/ReplicatedStorage/Config/Economy/Rewards.lua`.
	Editing this file changes nothing at runtime.

	Why this file exists: the Rewards config mixes three concerns (a
	live catalog plus two reward matrices) in a ~1000-line module.
	This file is the single-screen answer to "what can I tune, and
	what breaks if I change it?" — every tunable is listed below
	with its default, meaning, valid range, safety, and which module
	reads it.

	The live config is registered with the central validator as three
	separate domains in `Shared/Utilities/ConfigValidator.lua`:
		Economy.Rewards.Codes
		Economy.Rewards.Daily
		Economy.Rewards.Playtime
	Each exposes `Validate(): { string }` and returns an empty array
	when clean. A Studio boot with a validation failure is a hard
	error; a live server only warns.

	There are no secrets in this system. The redemption codes are
	game CONTENT (environment-specific), not credentials — but they
	should not be committed to a public repository for a live game.
	See the note on CODES below.
]]

local Config = {}

-- =====================================================================
-- Codes
-- =====================================================================

--[[
	CODES — the redeem-code catalog

	Default:  8 entries (see the table below).
	Meaning:  The authoritative list of redeemable codes. This is
	          DATA, not code: `CodesService` contains no
	          `if code == "WELCOME"` anywhere. Adding, disabling,
	          or expiring a code means editing this list only.
	Range:    0 .. N entries. Each entry must satisfy:
	            - Id: a non-empty, already-UPPERCASE string
	            - Code: a non-empty string whose NormalizeCode(Code)
	              equals Id  (NormalizeCode = trim + upper)
	            - Enabled: a boolean
	            - ExpiresAt: nil or a positive unix timestamp
	            - MaxPerPlayer: nil or a positive integer (default 1)
	            - MaxGlobalRedemptions: nil or a positive integer
	            - Rewards: at least one valid category
	          The Ids must be unique, and the normalized Codes must
	          not collide.
	Safe to change:  YES for the catalog itself. But note:
	            - The code ids are written to server logs
	              (Debug tag 'CD'). A code that must be secret is
	              NOT secret.
	            - `MaxGlobalRedemptions` is BEST EFFORT and PER
	              SERVER: it is an in-memory counter that resets on
	              restart and is not shared across servers. It is a
	              soft throttle, not a quota.
	Read by:  CodesService.RedeemInner (existence, Enabled, ExpiresAt,
	          MaxPerPlayer, MaxGlobalRedemptions, Rewards);
	          CodesService.NormalizeCode; Codes.ValidateList
	Placeholder:  The 8 entries below are Brainrot Arena's. A new
	              game MUST author its own. Keep `Code == Id` so
	              'welcome' and ' WELCOME ' resolve identically.
]]
Config.CODES = {
	-- The only live code in the source game.
	{ Id = 'WELCOME', Enabled = true, ExpiresAt = nil, MaxPerPlayer = 1, Cash = '2500' },
	-- Test fixtures: all DISABLED by design. Re-enable locally
	-- only while exercising the code path in Studio.
	{ Id = 'CODE_CASH_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Cash = '5000' },
	{ Id = 'CODE_EGG_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Egg = 'Common' },
	{ Id = 'CODE_MULTI_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Cash = '1000', Egg = 'Divine' },
	{ Id = 'CODE_TOOL_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Tool = 'SpeedCoil' },
	{ Id = 'CODE_ANIMAL_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Animal = 'Chicken' },
	-- Enabled=true but ExpiresAt=1 (unix epoch) so it is expired on
	-- every server, forever. Used to exercise the expiry branch.
	{ Id = 'CODE_EXPIRED_TEST', Enabled = true, ExpiresAt = 1, MaxPerPlayer = 1, Cash = '100' },
	{ Id = 'CODE_DISABLED_TEST', Enabled = false, ExpiresAt = nil, MaxPerPlayer = 1, Cash = '100' },
}

--[[
	MAX_SLOT_UNITS_PER_CODE

	Default:  10
	Meaning:  The maximum number of slot-bound units (eggs + animals
	          combined) that a single redemption may request. A code
	          can therefore never exhaust a player's base. Overflow
	          belongs in follow-up codes.
	Range:    1 .. (your base slot count). A value above the slot
	          count is harmless — the excess becomes pending — but it
	          stops being a useful guard.
	Safe to change:  YES. It is a module-local in
	          `Rewards.lua` (line 245), NOT exported. You must edit
	          the constant in the live config.
	Read by:  Codes.ValidateRewards
	Placeholder: NO
]]
Config.MAX_SLOT_UNITS_PER_CODE = 10

--[[
	MAX_CODE_INPUT_LENGTH

	Default:  64
	Meaning:  The maximum length of the raw string the client may
	          send in a `CodesAction` payload. Longer input is
	          rejected outright at the remote handler.
	Range:    1 .. 256. Must be long enough for your longest code.
	Safe to change:  YES. It is a module-local in `CodesService.lua`
	          (the `handleAction` remote handler), NOT exported.
	Read by:  CodesService.handleAction
	Placeholder: NO
]]
Config.MAX_CODE_INPUT_LENGTH = 64

-- =====================================================================
-- Daily
-- =====================================================================

--[[
	DAILY.Settings.ClaimInterval

	Default:  86400  (24 * 60 * 60 seconds)
	Meaning:  The minimum number of seconds between two daily
	          claims. Measured from the LAST claim, not from a
	          calendar midnight: a player who claims at 23:00 waits
	          24 hours, not until tomorrow.
	Range:    any positive number of seconds. 3600 (hourly) is a
	          common alternative. The validator only requires > 0.
	Safe to change:  YES. Only the interval changes; the 7-day
	          course shape is separate.
	Read by:  DailyRewardsService.computeStatus,
	          DailyRewardsService.commitDayRewards (the
	          eligibility-edge push delay)
	Placeholder: NO
]]
Config.DAILY_CLAIM_INTERVAL = 86400

--[[
	DAILY.DAYS_PER_POOL

	Default:  7
	Meaning:  The exact number of reward days in every daily pool.
	          The validator REQUIRES every pool to have exactly this
	          many contiguous days (1..N).
	Range:    1 .. 30. If you change it you must also change the
	          daily panel UI (the source game renders 7 cards).
	Safe to change:  YES but not trivially — it is a module-local
	          in `Rewards.lua` (line 588), NOT exported, and it
	          changes the UI contract.
	Read by:  DailyRewardsService (via DailyRewardsConfig.DayCount()),
	          Daily.ValidateList
	Placeholder: NO
]]
Config.DAILY_DAYS_PER_POOL = 7

--[[
	DAILY.WeeklyPools

	Default:  Pool_A, Pool_B, Pool_C — three pools, seven days each.
	Meaning:  The pool catalog. EXACTLY ONE pool is selected per
	          global week (by `DailyRewardsWeek`) and every player
	          in every server plays the SAME seven days that week.
	          Per-player progress is separate and lives on the
	          profile.
	Range:    1 .. N pools. Ids must be unique. Every pool must
	          have exactly DAYS_PER_POOL days with contiguous keys
	          1..DAYS_PER_POOL, and every day's Rewards must pass
	          `Codes.ValidateRewards`.
	Safe to change:  YES. The pool count and contents are pure
	          data. Adding a pool needs no service change.
	Read by:  DailyRewardsService.GetSnapshot / ClaimInner /
	          ClaimAllInner (via DailyRewardsConfig.FindPool)
	Placeholder:  The contents are Brainrot Arena's economy. A new
	              game must rebalance them.
]]
Config.DAILY_WEEKLY_POOLS = { 'Pool_A', 'Pool_B', 'Pool_C' }

-- =====================================================================
-- Playtime
-- =====================================================================

--[[
	PLAYTIME.Settings.SessionResetsOnLeave

	Default:  true
	Meaning:  Documents that playtime is session-based. The
	          validator REJECTS `false` — it is a rule statement,
	          not a toggle.
	Range:    must be exactly `true`.
	Safe to change:  NO without rewriting the session model.
	Read by:  Playtime.ValidateList
	Placeholder: NO
]]
Config.PLAYTIME_SESSION_RESETS_ON_LEAVE = true

--[[
	PLAYTIME.Settings.DailyResetTimezone

	Default:  'Asia/Kolkata'
	Meaning:  The human-readable label for the playtime day
	          boundary. It is DOCUMENTATION ONLY — the actual
	          arithmetic is `DayBoundaryOffsetSeconds` below. The
	          two must agree, but nothing enforces that.
	Range:    any non-empty string. Use 'UTC' with offset 0.
	Safe to change:  YES, as long as you change the offset to
	          match.
	Read by:  Playtime.ValidateList
	Placeholder: NO
]]
Config.PLAYTIME_DAILY_RESET_TIMEZONE = 'Asia/Kolkata'

--[[
	PLAYTIME.Settings.DailyResetHour / DailyResetMinute

	Default:  0 / 0
	Meaning:  The documented hour and minute of the day boundary.
	          Also documentation only.
	Range:    hour 0..23, minute 0..59 (integers).
	Safe to change:  YES, as long as it matches the offset.
	Read by:  Playtime.ValidateList
	Placeholder: NO
]]
Config.PLAYTIME_DAILY_RESET_HOUR = 0
Config.PLAYTIME_DAILY_RESET_MINUTE = 0

--[[
	PLAYTIME.Settings.DayBoundaryOffsetSeconds

	Default:  19800  (UTC+5:30)
	Meaning:  The REAL day-boundary arithmetic.
	          `DayIndexAt(now) = floor((now + offset) / 86400)`.
	          The boundary is therefore 00:00 in the configured
	          timezone, computed purely from server `os.time()` —
	          never the client clock, never server-local midnight.
	          `PlaytimeRewardsDay` reads this instead of hardcoding
	          19800.
	Range:    0 .. 86399. Set 0 for UTC.
	Safe to change:  YES, but it is PINNED in two places you must
	          update at the same time:
	            - `Shared/Utilities/ConfigValidator.lua`
	              (`_checkInvariants`, ~line 147)
	            - `Tests/ConfigArchitecture.spec.lua`
	          The default offset for IST is 19800 seconds (5.5 h);
	          note this ignores the half-hour historical offset
	          transitions, which is fine for a daily reset.
	Read by:  PlaytimeRewardsDay.DayIndexAt, PlaytimeRewardsDay.Current
	Placeholder: NO
]]
Config.PLAYTIME_DAY_BOUNDARY_OFFSET_SECONDS = 19800

--[[
	PLAYTIME.Settings.SkipAllEnabled

	Default:  false
	Meaning:  A validated boolean flag for the paid "Skip All"
	          feature. IMPORTANT: the services do NOT gate on this
	          flag — they gate on the SESSION ENTITLEMENT set by
	          `GrantSkipAccess`, which only the Shop receipt path
	          may call. The flag documents whether the feature
	          exists at all.
	Range:    boolean.
	Safe to change:  YES. Setting it to `true` without wiring the
	          Shop receipt path grants nothing; a `ClaimAll` with
	          no entitlement is rejected with `no-access`.
	Read by:  Playtime.ValidateList
	Placeholder: NO
]]
Config.PLAYTIME_SKIP_ALL_ENABLED = false

--[[
	PLAYTIME.Pools

	Default:  Pool_A, Pool_B, Pool_C — three courses, six milestones
	          each.
	Meaning:  The playtime course catalog. ONE pool is selected per
	          session (see the pool lifecycle in MEMORY.md). Each
	          pool is a complete course of CUMULATIVE playtime
	          milestones. Claiming a milestone never resets the
	          clock and never touches its siblings.
	Range:    1 .. N pools. Ids must be unique. EVERY pool must
	          have the SAME milestone count (the source game's UI
	          renders exactly 6 cards) and each milestone's
	          `RequiredPlaytime` must STRICTLY ASCEND within its
	          pool.
	Safe to change:  YES for the contents. Changing the milestone
	          COUNT requires changing the UI too.
	Read by:  PlaytimeRewardsService.resolveSession /
	          GetSnapshot / ClaimInner / ClaimAllInner
	Placeholder:  The contents are Brainrot Arena's economy.
]]
Config.PLAYTIME_POOLS = { 'Pool_A', 'Pool_B', 'Pool_C' }

--[[
	PLAYTIME_MILESTONE_COUNT

	Default:  6
	Meaning:  The number of milestones in every playtime course.
	          Derived at runtime by `PlaytimeRewardsConfig.MilestoneCount()`
	          (which returns the count of the FIRST pool) — the
	          validator requires every other pool to match.
	Range:    1 .. 12 (the UI is fixed at 6 cards in the source
	          game).
	Safe to change:  YES but not trivially — it changes the UI
	          contract.
	Read by:  PlaytimeRewardsService, Playtime.ValidateList
	Placeholder: NO
]]
Config.PLAYTIME_MILESTONE_COUNT = 6

-- =====================================================================
-- Reward shape (shared by Codes, Daily and Playtime)
-- =====================================================================

--[[
	REWARD SHAPE

	Default:  { Cash?, Eggs?, Tools?, Animals? }
	Meaning:  ONE shape for all three systems, validated by
	          `Codes.ValidateRewards`. At least one category must be
	          present. The rules:
	            - Cash:    a BigNumber decimal STRING (never a
	                      number). Granted through
	                      `EconomyService.AddMoney(userId, amount,
	                      'CodeReward', { ApplyMultiplier = false })`.
	            - Eggs:    array of { Rarity, Amount }. The rarity
	                      must exist in `Eggs.Price`. The price is
	                      derived, never authored.
	            - Tools:   array of { Id, Amount }. The id must
	                      exist in `Gear.FindGear` (the stable Gear
	                      id, NOT the Tool instance name). Granted
	                      through `GearShopService.EnsureGearTool`
	                      (session-only — tools are never
	                      persisted).
	            - Animals: array of { DefId, Trait?, Level?, Amount }.
	                      The def id must exist in `Animals.Get`, the
	                      trait in `Traits.Get`, and Level must be a
	                      positive integer (default 1).
	            - Amount:  a positive integer.
	            - Eggs + Animals together must not exceed
	              MAX_SLOT_UNITS_PER_CODE.
	Range:    n/a — this is a type contract, not a number.
	Safe to change:  the SHAPE, yes, but it is a wide-reaching
	          change: the three services, the validators, and the
	          client panels all read it.
	Read by:  Codes.ValidateRewards, and every service's grant
	          path.
	Placeholder: NO
]]
Config.REWARD_SHAPE = {
	Cash = 'string?',
	Eggs = '{ { Rarity: string, Amount: number } }?',
	Tools = '{ { Id: string, Amount: number } }?',
	Animals = '{ { DefId: string, Trait: string?, Level: number?, Amount: number } }?',
}

-- =====================================================================
-- DataStore names (environment-specific — change per game)
-- =====================================================================

--[[
	DATASTORE_NAME_DAILY_WEEK

	Default:  'p7_DailyRewards_Weekly_v1'
	Meaning:  The DataStore that holds the global weekly pool
	          selection. Owned by `DailyRewardsWeek`, which ships
	          in this system at
	          `Source/ServerScriptService/Daily/DailyRewardsWeek.lua`.
	          The name is a module-local literal in that file
	          (line 49) — edit it there.
	Range:    any non-empty string; unique per game and
	          environment.
	Safe to change:  YES — it abandons the old week's selection
	          (the fallback hash takes over until a new value is
	          committed).
	Read by:  DailyRewardsWeek
	Placeholder: NO
]]
Config.DATASTORE_NAME_DAILY_WEEK = 'p7_DailyRewards_Weekly_v1'

--[[
	DATASTORE_NAME_PLAYTIME_DAY

	Default:  'p7_PlaytimeRewards_Daily_v1'
	Meaning:  The DataStore that holds the global daily pool
	          selection. Key `'CurrentDay'`, value
	          `{ DayId, PoolId, PreviousPoolId, SetAt }`. Selected
	          inside an ATOMIC `UpdateAsync`, so exactly one pool
	          wins when several servers reach a new day at once.
	Range:    any non-empty string; unique per game and
	          environment.
	Safe to change:  YES — abandoning it falls back to the
	          deterministic hash pick (all servers still agree).
	Read by:  PlaytimeRewardsDay
	Placeholder: NO
]]
Config.DATASTORE_NAME_PLAYTIME_DAY = 'p7_PlaytimeRewards_Daily_v1'

return table.freeze(Config)
