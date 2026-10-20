--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Rewards: redeem codes + daily + playtime matrices (shared CodeRewards shape).
-- Sections: Rewards.Codes / Rewards.Daily / Rewards.Playtime.
local Eggs = require(script.Parent.Parent.Creatures.Eggs)
local Gear = require(script.Parent.Gear)
local Animals = require(script.Parent.Parent.Creatures.Animals)
local Traits = require(script.Parent.Parent.Creatures.Traits)
local BigNumber = require(script.Parent.Parent.Parent.Utility.BigNumber)
--[[
	Codes
	===========
	Data-driven redeem-code catalog. Each entry is display data +
	reward rules; CodesService never hardcodes per-code behavior
	(no `if code == "WELCOME"` anywhere — add, disable, or expire
	codes here only).

	Conventions:
	  * Id: canonical UPPER_SNAKE identifier, e.g. 'WELCOME'. This
	    is what players type after normalization (trim + upper),
	    what is stored in profile.Data.RedeemedCodes, and what
	    server logs print. Never shown raw to players except in
	    logs (the Codes UI echoes their own input back).
	  * Code: the human-entered string. NormalizeCode(Code) MUST
	    equal Id (validated) so 'welcome', ' WELCOME ' etc. all
	    resolve to the same entry.
	  * Enabled: false behaves like an unavailable code (never
	    awards, never marks redeemed).
	  * ExpiresAt: unix seconds (os.time convention). nil = never
	    expires. A code is expired when os.time() >= ExpiresAt.
	  * MaxPerPlayer: redemptions allowed per player (default 1).
	  * MaxGlobalRedemptions: optional server-wide cap. BEST
	    EFFORT, per-server in-memory only: it resets on server
	    restart and is NOT shared across servers. Documented
	    limitation, not a persistent quota.
	  * Rewards.Cash: BigNumber decimal STRING (never a number),
	    granted through EconomyService with reason 'CodeReward'.
	  * Rewards.Eggs: array of { Rarity, Amount }. Rarity is the
	    Eggs rarity string ('Common' .. 'Secret'); price is
	    derived, never authored.
	  * Rewards.Tools: array of { Id, Amount }. Id is the stable
	    Gear Id (NOT the Tool instance name). Granted
	    through GearShopService.EnsureGearTool (session-only, like
	    every tool in this project — tools are never persisted).
	  * Rewards.Animals: array of { DefId, Trait?, Level?,
	    Amount }. DefId must exist in Animals; Trait must be
	    nil or a Traits trait; Level defaults to 1.
	  * Amount: positive integer units. Slot-bound rewards (eggs,
	    animals) are capped per code so one redemption can never
	    exhaust a base.

	Validation: ValidateList(codes) is pure (safe in tests);
	ValidateLive() re-runs it against the live catalogs;
	Validate() is the ConfigValidator entry point.
]]

export type CodeEggReward = {
	Rarity: string,
	Amount: number,
}

export type CodeToolReward = {
	Id: string,
	Amount: number,
}

export type CodeAnimalReward = {
	DefId: string,
	Trait: string?,
	Level: number?,
	Amount: number,
}

export type CodeRewards = {
	Cash: string?,
	Eggs: { CodeEggReward }?,
	Tools: { CodeToolReward }?,
	Animals: { CodeAnimalReward }?,
}

export type CodeDef = {
	Id: string,
	Code: string,
	Enabled: boolean,
	ExpiresAt: number?,
	MaxPerPlayer: number?,
	MaxGlobalRedemptions: number?,
	Rewards: CodeRewards,
}

local Codes = {}

-- Displayed verbatim in the Codes UI? No — the client only ever
-- sends the typed string; the server normalizes and looks up by
-- Id. Keep Code == Id here so normalization is the identity.
local CODES: { CodeDef } = {
	{
		Id = 'WELCOME',
		Code = 'WELCOME',
		Enabled = true,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Cash = '2500',
		},
	},
	{
		Id = 'CODE_CASH_TEST',
		Code = 'CODE_CASH_TEST',
		-- Test fixture: never redeemable in production. Re-enable
		-- locally only when exercising the code path in Studio.
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Cash = '5000',
		},
	},
	{
		Id = 'CODE_EGG_TEST',
		Code = 'CODE_EGG_TEST',
		-- Test fixture: never redeemable in production. Re-enable
		-- locally only when exercising the code path in Studio.
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Eggs = {
				{ Rarity = 'Common', Amount = 1 },
			},
		},
	},
	{
		Id = 'CODE_MULTI_TEST',
		Code = 'CODE_MULTI_TEST',
		-- Test fixture: never redeemable in production. Re-enable
		-- locally only when exercising the code path in Studio.
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Cash = '1000',
			Eggs = {
				{ Rarity = 'Divine', Amount = 1 },
			},
		},
	},
	{
		Id = 'CODE_TOOL_TEST',
		Code = 'CODE_TOOL_TEST',
		-- Test fixture: never redeemable in production. Re-enable
		-- locally only when exercising the code path in Studio.
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Tools = {
				{ Id = 'SpeedCoil', Amount = 1 },
			},
		},
	},
	{
		Id = 'CODE_ANIMAL_TEST',
		Code = 'CODE_ANIMAL_TEST',
		-- Test fixture: never redeemable in production. Re-enable
		-- locally only when exercising the code path in Studio.
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Animals = {
				{ DefId = 'Chicken', Level = 1, Amount = 1 },
			},
		},
	},
	{
		Id = 'CODE_EXPIRED_TEST',
		Code = 'CODE_EXPIRED_TEST',
		Enabled = true,
		-- Unix 1 (1970): expired on every server, forever.
		ExpiresAt = 1,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Cash = '100',
		},
	},
	{
		Id = 'CODE_DISABLED_TEST',
		Code = 'CODE_DISABLED_TEST',
		Enabled = false,
		ExpiresAt = nil,
		MaxPerPlayer = 1,
		MaxGlobalRedemptions = nil,
		Rewards = {
			Cash = '100',
		},
	},
}

-- Canonical input normalization (server-authoritative; the
-- client sends raw TextBox text). Trim + upper so 'welcome',
-- ' WELCOME ' etc. resolve identically. Never stored raw.
function Codes.NormalizeCode(input: any): string?
	if type(input) ~= 'string' then
		return nil
	end
	local trimmed = (input :: string):match('^%s*(.-)%s*$')
	if trimmed == nil or trimmed == '' then
		return nil
	end
	return (trimmed :: string):upper()
end

function Codes.GetAll(): { CodeDef }
	return CODES
end

function Codes.FindById(id: string): CodeDef?
	if type(id) ~= 'string' then
		return nil
	end
	for _, entry in ipairs(CODES) do
		if entry.Id == id then
			return entry
		end
	end
	return nil
end

-- Max slot-bound units one redemption may request (eggs +
-- animals combined). A single code can never exhaust a base;
-- overflow belongs in follow-up codes, not here.
local MAX_SLOT_UNITS_PER_CODE = 10

-- Pure reward-shape validation (no profile, no services). Used
-- at boot AND defensively at redeem time (fail-closed).
function Codes.ValidateRewards(rewards: any): { string }
	local issues: { string } = {}
	if type(rewards) ~= 'table' then
		issues[#issues + 1] = 'Codes.Rewards must be a table'
		return issues
	end
	local r = rewards :: CodeRewards
	local count = 0
	if r.Cash ~= nil then
		count += 1
		if type(r.Cash) ~= 'string' or BigNumber.sanitize(r.Cash) == nil then
			issues[#issues + 1] = ('Codes.Rewards.Cash must be a BigNumber string, got %s'):format(tostring(r.Cash))
		end
	end
	local slotUnits = 0
	if r.Eggs ~= nil then
		count += 1
		if type(r.Eggs) ~= 'table' then
			issues[#issues + 1] = 'Codes.Rewards.Eggs must be an array'
		else
			for i, entry in ipairs(r.Eggs) do
				if type(entry) ~= 'table' or type(entry.Rarity) ~= 'string' then
					issues[#issues + 1] = ('Codes.Rewards.Eggs[%d].Rarity must be a string'):format(i)
				elseif Eggs.Price[entry.Rarity] == nil then
					issues[#issues + 1] = ('Codes.Rewards.Eggs[%d].Rarity=%s is not an Eggs rarity'):format(
						i,
						tostring(entry.Rarity)
					)
				end
				if
					type(entry) ~= 'table'
					or type(entry.Amount) ~= 'number'
					or entry.Amount ~= math.floor(entry.Amount)
					or entry.Amount < 1
				then
					issues[#issues + 1] = ('Codes.Rewards.Eggs[%d].Amount must be a positive integer'):format(i)
				else
					slotUnits += entry.Amount
				end
			end
		end
	end
	if r.Tools ~= nil then
		count += 1
		if type(r.Tools) ~= 'table' then
			issues[#issues + 1] = 'Codes.Rewards.Tools must be an array'
		else
			for i, entry in ipairs(r.Tools) do
				if type(entry) ~= 'table' or type(entry.Id) ~= 'string' then
					issues[#issues + 1] = ('Codes.Rewards.Tools[%d].Id must be a string'):format(i)
				elseif Gear.FindGear(entry.Id) == nil then
					issues[#issues + 1] = ('Codes.Rewards.Tools[%d].Id=%s is not a Gear Id'):format(
						i,
						tostring(entry.Id)
					)
				end
				if
					type(entry) ~= 'table'
					or type(entry.Amount) ~= 'number'
					or entry.Amount ~= math.floor(entry.Amount)
					or entry.Amount < 1
				then
					issues[#issues + 1] = ('Codes.Rewards.Tools[%d].Amount must be a positive integer'):format(i)
				end
			end
		end
	end
	if r.Animals ~= nil then
		count += 1
		if type(r.Animals) ~= 'table' then
			issues[#issues + 1] = 'Codes.Rewards.Animals must be an array'
		else
			for i, entry in ipairs(r.Animals) do
				if type(entry) ~= 'table' or type(entry.DefId) ~= 'string' then
					issues[#issues + 1] = ('Codes.Rewards.Animals[%d].DefId must be a string'):format(i)
				else
					local rarity = Animals.Get(entry.DefId)
					if rarity == nil then
						issues[#issues + 1] = ('Codes.Rewards.Animals[%d].DefId=%s is not an Animals definition'):format(
							i,
							tostring(entry.DefId)
						)
					end
				end
				if entry ~= nil and type(entry) == 'table' and entry.Trait ~= nil then
					if type(entry.Trait) ~= 'string' or Traits.Get(entry.Trait) == nil then
						issues[#issues + 1] = ('Codes.Rewards.Animals[%d].Trait=%s is not a Traits trait'):format(
							i,
							tostring(entry.Trait)
						)
					end
				end
				if entry ~= nil and type(entry) == 'table' and entry.Level ~= nil then
					if type(entry.Level) ~= 'number' or entry.Level ~= math.floor(entry.Level) or entry.Level < 1 then
						issues[#issues + 1] = ('Codes.Rewards.Animals[%d].Level must be a positive integer'):format(i)
					end
				end
				if
					type(entry) ~= 'table'
					or type(entry.Amount) ~= 'number'
					or entry.Amount ~= math.floor(entry.Amount)
					or entry.Amount < 1
				then
					issues[#issues + 1] = ('Codes.Rewards.Animals[%d].Amount must be a positive integer'):format(i)
				else
					slotUnits += entry.Amount
				end
			end
		end
	end
	if count < 1 then
		issues[#issues + 1] = 'Codes.Rewards must grant at least one category (Cash/Eggs/Tools/Animals)'
	end
	if slotUnits > MAX_SLOT_UNITS_PER_CODE then
		issues[#issues + 1] = ('Codes.Rewards requests %d slot units, max %d per code'):format(
			slotUnits,
			MAX_SLOT_UNITS_PER_CODE
		)
	end
	return issues
end

-- Pure catalog validation (safe in tests and at boot).
function Codes.ValidateList(codes: any): { string }
	local issues: { string } = {}
	if type(codes) ~= 'table' then
		return { 'Codes catalog must be a table' }
	end
	local seenId: { [string]: boolean } = {}
	local seenCode: { [string]: boolean } = {}
	for i, entry in ipairs(codes) do
		local tag = ('Codes[%d]'):format(i)
		if type(entry) ~= 'table' then
			issues[#issues + 1] = ('%s must be a table'):format(tag)
			continue
		end
		local e = entry :: CodeDef
		if type(e.Id) ~= 'string' or e.Id == '' then
			issues[#issues + 1] = ('%s.Id must be a non-empty string'):format(tag)
		elseif e.Id ~= e.Id:upper() then
			issues[#issues + 1] = ('%s.Id=%s must already be normalized (upper)'):format(tag, e.Id)
		elseif seenId[e.Id] then
			issues[#issues + 1] = ('%s.Id=%s is duplicated'):format(tag, e.Id)
		else
			seenId[e.Id] = true
		end
		if type(e.Code) ~= 'string' or e.Code == '' then
			issues[#issues + 1] = ('%s.Code must be a non-empty string'):format(tag)
		else
			local norm = Codes.NormalizeCode(e.Code)
			if norm ~= e.Id then
				issues[#issues + 1] = ('%s.Code=%s must normalize to Id=%s'):format(tag, e.Code, tostring(e.Id))
			elseif seenCode[norm :: string] then
				issues[#issues + 1] = ('%s.Code=%s collides with another entry after normalization'):format(tag, e.Code)
			else
				seenCode[norm :: string] = true
			end
		end
		if type(e.Enabled) ~= 'boolean' then
			issues[#issues + 1] = ('%s.Enabled must be a boolean'):format(tag)
		end
		if e.ExpiresAt ~= nil and (type(e.ExpiresAt) ~= 'number' or e.ExpiresAt <= 0) then
			issues[#issues + 1] = ('%s.ExpiresAt must be nil or a positive unix timestamp'):format(tag)
		end
		local maxPer = e.MaxPerPlayer or 1
		if
			type(e.MaxPerPlayer) ~= 'nil'
			and (type(e.MaxPerPlayer) ~= 'number' or e.MaxPerPlayer ~= math.floor(e.MaxPerPlayer) or e.MaxPerPlayer < 1)
		then
			issues[#issues + 1] = ('%s.MaxPerPlayer must be nil or a positive integer'):format(tag)
		end
		if
			e.MaxGlobalRedemptions ~= nil
			and (
				type(e.MaxGlobalRedemptions) ~= 'number'
				or e.MaxGlobalRedemptions ~= math.floor(e.MaxGlobalRedemptions)
				or e.MaxGlobalRedemptions < 1
			)
		then
			issues[#issues + 1] = ('%s.MaxGlobalRedemptions must be nil or a positive integer'):format(tag)
		end
		if maxPer < 1 then
			issues[#issues + 1] = ('%s.MaxPerPlayer resolves below 1'):format(tag)
		end
		for _, issue in ipairs(Codes.ValidateRewards(e.Rewards)) do
			issues[#issues + 1] = ('%s: %s'):format(tag, issue)
		end
	end
	return issues
end

-- Live validation (server boot + codes service init). The
-- catalog probes above are the shared pure configs, so this is
-- the same pass; kept as a separate entry point per the
-- ArenaConfig/Gear ValidateLive convention.
function Codes.ValidateLive(): { string }
	return Codes.ValidateList(CODES)
end

-- ConfigValidator entry point (pure).
function Codes.Validate(): { string }
	return Codes.ValidateList(CODES)
end

--[[
	Daily
	==================
	GLOBAL weekly pool catalog for the 7-day daily-rewards
	course. The service selects exactly ONE pool per global
	week (see DailyRewardsWeek); every player in every server
	plays the SAME 7 fixed days that week. Per-player claim
	progress (Day 1..7) is separate and lives on the profile.

	Conventions:
	  * Settings.ClaimInterval: seconds between claims (server
	    os.time() only — client clocks are never trusted).
	  * WeeklyPools: array of { Id, Days }. Order is stable
	    (selection indexes it); Ids must be unique. Add/edit
	    DAILY_POOLS here freely — no service rewrite needed for 7,
	    14, or 30 DAILY_POOLS. Every pool has EXACTLY 7 days
	    (validated); Days keys are contiguous 1..7.
	  * Rewards shape is EXACTLY Codes's (Cash BigNumber
	    string, Eggs { Rarity, Amount }, Tools { Id, Amount },
	    Animals { DefId, Trait?, Level?, Amount? }). Reward-shape
	    validation is delegated to Codes.ValidateRewards —
	    one rule set, not two. All reward ids below are live
	    catalog ids (verified against Egg/Gear/AnimalConfig).

	Validation: ValidateList(DAILY_POOLS, settings) is pure (safe in
	tests); ValidateLive() re-runs it; Validate() is the
	ConfigValidator entry point.
]]

export type DailyDayDef = {
	Rewards: CodeRewards,
}

export type DailyPoolDef = {
	Id: string,
	Days: { DailyDayDef },
}

export type DailySettings = {
	ClaimInterval: number,
}

local Daily = {}

local DAILY_DEFAULT_SETTINGS: DailySettings = {
	ClaimInterval = 24 * 60 * 60,
}
Daily.Settings = DAILY_DEFAULT_SETTINGS

local DAILY_POOLS: { DailyPoolDef } = {
	{
		Id = 'Pool_A',
		Days = {
			[1] = { Rewards = { Cash = '5000' } },
			[2] = { Rewards = { Eggs = { { Rarity = 'Rare', Amount = 1 } } } },
			[3] = {
				Rewards = {
					Cash = '25000',
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
				},
			},
			[4] = { Rewards = { Cash = '100000' } },
			[5] = { Rewards = { Cash = '150000' } },
			[6] = {
				Rewards = {
					Tools = { { Id = 'CoilCombo', Amount = 1 } },
				},
			},
			[7] = {
				Rewards = {
					Cash = '150000',
					Eggs = { { Rarity = 'Legendary', Amount = 1 } },
				},
			},
		},
	},
	{
		Id = 'Pool_B',
		Days = {
			[1] = { Rewards = { Eggs = { { Rarity = 'Common', Amount = 1 } } } },
			[2] = { Rewards = { Cash = '25000',
		                        Eggs = { { Rarity = 'Epic', Amount = 1 } } } },
			[3] = {
				Rewards = {
					Cash = '50000',
					Tools = { { Id = 'SpeedCoil', Amount = 1 } },
				},
			},
			[4] = { Rewards = { Eggs = { { Rarity = 'Epic', Amount = 1 } } } },
			[5] = {
				Rewards = {
					Cash = '75000',
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
				},
			},
			[6] = { Rewards = { Tools = { { Id = 'CoilCombo', Amount = 1 } } } },
			[7] = {
				Rewards = {
					Cash = '250000',
					Eggs = { { Rarity = 'Legendary', Amount = 1 } },
					Tools = { { Id = 'ObsidianBat', Amount = 1 } },
				},
			},
		},
	},
	{
		Id = 'Pool_C',
		Days = {
			[1] = { Rewards = { Cash = '5000' } },
			[2] = { Rewards = { Tools = { { Id = 'SpeedCoil', Amount = 1 } } } },
			[3] = { Rewards = { Eggs = { { Rarity = 'Rare', Amount = 1 } } } },
			[4] = {
				Rewards = {
					Cash = '50000',
				},
			},
			[5] = {
				Rewards = {
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
				},
			},
			[6] = { Rewards = { Cash = '100000' } },
			[7] = {
				Rewards = {
					Cash = '150000',
					Eggs = { { Rarity = 'Legendary', Amount = 1 } },
				},
			},
		},
	},
}

Daily.WeeklyPools = DAILY_POOLS

-- Exactly 7 reward days per pool, no exceptions.
local DAYS_PER_POOL = 7

function Daily.DayCount(): number
	return DAYS_PER_POOL
end

function Daily.FindPool(pools: any, poolId: string): DailyPoolDef?
	if type(pools) ~= 'table' or type(poolId) ~= 'string' then
		return nil
	end
	for _, pool in ipairs(pools) do
		if type(pool) == 'table' and pool.Id == poolId then
			return pool
		end
	end
	return nil
end

-- Pure catalog validation (safe in tests and at boot).
function Daily.ValidateList(pools: any, settings: any): { string }
	local issues: { string } = {}
	if type(pools) ~= 'table' then
		return { 'Daily.WeeklyPools must be a table' }
	end
	if #pools < 1 then
		issues[#issues + 1] = 'Daily.WeeklyPools must define at least 1 pool'
	end
	local seenId: { [string]: boolean } = {}
	for i, pool in ipairs(pools) do
		local tag = ('Daily.WeeklyPools[%d]'):format(i)
		if type(pool) ~= 'table' then
			issues[#issues + 1] = ('%s must be a table'):format(tag)
			continue
		end
		local p = pool :: DailyPoolDef
		if type(p.Id) ~= 'string' or p.Id == '' then
			issues[#issues + 1] = ('%s.Id must be a non-empty string'):format(tag)
		elseif seenId[p.Id] then
			issues[#issues + 1] = ('%s.Id=%s is duplicated'):format(tag, p.Id)
		else
			seenId[p.Id] = true
		end
		if type(p.Days) ~= 'table' then
			issues[#issues + 1] = ('%s.Days must be a table'):format(tag)
		else
			for day = 1, DAYS_PER_POOL do
				local dayTag = ('%s.Days[%d]'):format(tag, day)
				local entry = p.Days[day]
				if type(entry) ~= 'table' then
					issues[#issues + 1] = ('%s is missing (every pool needs exactly %d days)'):format(
						dayTag,
						DAYS_PER_POOL
					)
				else
					for _, issue in ipairs(Codes.ValidateRewards((entry :: DailyDayDef).Rewards)) do
						issues[#issues + 1] = ('%s: %s'):format(dayTag, issue)
					end
				end
			end
			for key in pairs(p.Days) do
				if type(key) ~= 'number' or key ~= math.floor(key) or key < 1 or key > DAYS_PER_POOL then
					issues[#issues + 1] = ('%s.Days has out-of-range key %s'):format(tag, tostring(key))
					break
				end
			end
		end
	end
	if type(settings) ~= 'table' then
		issues[#issues + 1] = 'Daily.Settings must be a table'
		return issues
	end
	local s = settings :: DailySettings
	if type(s.ClaimInterval) ~= 'number' or s.ClaimInterval <= 0 then
		issues[#issues + 1] = 'Daily.Settings.ClaimInterval must be a positive number of seconds'
	end
	return issues
end

-- Live validation (server boot + service init). The reward
-- probes are the shared pure configs, so this is the same
-- pass; kept as a separate entry point per the
-- ArenaConfig/GearConfig ValidateLive convention.
function Daily.ValidateLive(): { string }
	return Daily.ValidateList(Daily.WeeklyPools, Daily.Settings)
end

-- ConfigValidator entry point (pure).
function Daily.Validate(): { string }
	return Daily.ValidateList(Daily.WeeklyPools, Daily.Settings)
end

--[[
	Playtime
	=====================
	SESSION playtime reward courses. Each pool is one complete
	course of cumulative playtime milestones; the service
	selects exactly ONE pool per player session (global daily
	pool by default, personal pick after a completed course —
	see PlaytimeRewardsService for the lifecycle).

	Conventions:
	  * Settings.SessionResetsOnLeave: always true (playtime
	    is session-based by design; the field documents the
	    rule, it is not a toggle).
	  * Settings.DailyResetTimezone / DailyResetHour /
	    DailyResetMinute: the explicit global boundary —
	    00:00 Asia/Kolkata. Server arithmetic only (UTC+5:30
	    offset, never the client clock, never server-local
	    midnight).
	  * PLAYTIME_POOLS: array of { Id, Milestones }. Order is stable;
	    Ids unique. Every pool has the SAME milestone count
	    (validated) so any pool fits the 6-card UI; every
	    milestone's RequiredPlaytime is strictly ascending
	    within its pool (validated).
	  * Milestone: { RequiredPlaytime (cumulative seconds,
	    positive), Rewards }. Rewards shape is EXACTLY
	    Codes's (Cash BigNumber string, Eggs { Rarity,
	    Amount }, Tools { Id, Amount }, Animals { DefId,
	    Trait?, Level?, Amount? }); validation delegates to
	    Codes.ValidateRewards — one rule set, not two.
    All reward ids below are live catalog ids.
  * SkipAll: paid "Skip All" via the Shop SkipPlaytime
    Developer Product. GUI Skip prompts the purchase; the
    Shop receipt grants session entitlement, then the gated
    ClaimAll runs. SkipAllEnabled stays as a validated
    boolean flag (services gate on the entitlement, not it).

 Validation: ValidateList(PLAYTIME_POOLS, settings) is pure (safe in
 tests); ValidateLive() re-runs it; Validate() is the
 ConfigValidator entry point.
]]

export type PlaytimeMilestone = {
	RequiredPlaytime: number,
	Rewards: CodeRewards,
}

export type PlaytimePoolDef = {
	Id: string,
	Milestones: { PlaytimeMilestone },
}

export type PlaytimeSettings = {
	SessionResetsOnLeave: boolean,
	DailyResetTimezone: string,
	DailyResetHour: number,
	DailyResetMinute: number,
	SkipAllEnabled: boolean,
	DayBoundaryOffsetSeconds: number,
}

local Playtime = {}

local PLAYTIME_DEFAULT_SETTINGS: PlaytimeSettings = {
	SessionResetsOnLeave = true,
	DailyResetTimezone = 'Asia/Kolkata',
	DailyResetHour = 0,
	DailyResetMinute = 0,
	SkipAllEnabled = false,
	-- UTC+5:30 midnight boundary in seconds. MUST match DailyResetTimezone;
	-- PlaytimeRewardsDay reads this instead of hardcoding 19800.
	DayBoundaryOffsetSeconds = 19800,
}
Playtime.Settings = PLAYTIME_DEFAULT_SETTINGS

local PLAYTIME_POOLS: { PlaytimePoolDef } = {
	{
		Id = 'Pool_A',
		Milestones = {
			[1] = { RequiredPlaytime = 5 * 60, Rewards = { Cash = '10000' } },
			[2] = {
				RequiredPlaytime = 10 * 60,
				Rewards = { Eggs = { { Rarity = 'Rare', Amount = 1 } } },
			},
			[3] = {
				RequiredPlaytime = 20 * 60,
				Rewards = {
					Cash = '25000',
					Eggs = { { Rarity = 'Rare', Amount = 1 } },
				},
			},
			[4] = {
				RequiredPlaytime = 30 * 60,
				Rewards = { Tools = { { Id = 'SpeedCoil', Amount = 1 } } },
			},
			[5] = { RequiredPlaytime = 45 * 60, Rewards = { Cash = '25000' } },
			[6] = {
				RequiredPlaytime = 60 * 60,
				Rewards = {
					Cash = '50000',
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
					Tools = { { Id = 'GoldBat', Amount = 1 } },
				},
			},
		},
	},
	{
		Id = 'Pool_B',
		Milestones = {
			[1] = {
				RequiredPlaytime = 5 * 60,
				Rewards = { Eggs = { { Rarity = 'Rare', Amount = 1 } } },
			},
			[2] = { RequiredPlaytime = 10 * 60, Rewards = { Cash = '25000' } },
			[3] = {
				RequiredPlaytime = 20 * 60,
				Rewards = {
					Cash = '30000',
					Tools = { { Id = 'GoldBat', Amount = 1 } },
				},
			},
			[4] = {
				RequiredPlaytime = 30 * 60,
				Rewards = { Eggs = { { Rarity = 'Epic', Amount = 1 } } },
			},
			[5] = {
				RequiredPlaytime = 45 * 60,
				Rewards = {
					Cash = '75000',
				},
			},
			[6] = {
				RequiredPlaytime = 60 * 60,
				Rewards = {
					Tools = { { Id = 'DiamondBat', Amount = 1 } },
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
				},
			},
		},
	},
	{
		Id = 'Pool_C',
		Milestones = {
			[1] = { RequiredPlaytime = 5 * 60, Rewards = { Cash = '10000' } },
			[2] = {
				RequiredPlaytime = 10 * 60,
				Rewards = { Tools = { { Id = 'SpeedCoil', Amount = 1 } } },
			},
			[3] = {
				RequiredPlaytime = 15 * 60,
				Rewards = {
					Eggs = { { Rarity = 'Rare', Amount = 1 } },
				},
			},
			[4] = {
				RequiredPlaytime = 30 * 60,
				Rewards = {
					Cash = '25000',
					Tools = { { Id = 'SilverBat', Amount = 1 } },
				},
			},
			[5] = { RequiredPlaytime = 45 * 60, Rewards = { Cash = '30000' } },
			[6] = {
				RequiredPlaytime = 60 * 60,
				Rewards = {
					Cash = '35000',
					Eggs = { { Rarity = 'Epic', Amount = 1 } },
				},
			},
		},
	},
}

Playtime.Pools = PLAYTIME_POOLS

function Playtime.MilestoneCount(): number
	local pools = Playtime.Pools
	if type(pools) ~= 'table' or #pools < 1 then
		return 0
	end
	local first = pools[1]
	if type(first) ~= 'table' or type(first.Milestones) ~= 'table' then
		return 0
	end
	return #first.Milestones
end

function Playtime.FindPool(pools: any, poolId: string): PlaytimePoolDef?
	if type(pools) ~= 'table' or type(poolId) ~= 'string' then
		return nil
	end
	for _, pool in ipairs(pools) do
		if type(pool) == 'table' and pool.Id == poolId then
			return pool
		end
	end
	return nil
end

-- Pure catalog validation (safe in tests and at boot).
function Playtime.ValidateList(pools: any, settings: any): { string }
	local issues: { string } = {}
	if type(pools) ~= 'table' then
		return { 'Playtime.Pools must be a table' }
	end
	if #pools < 1 then
		issues[#issues + 1] = 'Playtime.Pools must define at least 1 pool'
	end
	local seenId: { [string]: boolean } = {}
	local milestoneCount: number? = nil
	for i, pool in ipairs(pools) do
		local tag = ('Playtime.Pools[%d]'):format(i)
		if type(pool) ~= 'table' then
			issues[#issues + 1] = ('%s must be a table'):format(tag)
			continue
		end
		local p = pool :: PlaytimePoolDef
		if type(p.Id) ~= 'string' or p.Id == '' then
			issues[#issues + 1] = ('%s.Id must be a non-empty string'):format(tag)
		elseif seenId[p.Id] then
			issues[#issues + 1] = ('%s.Id=%s is duplicated'):format(tag, p.Id)
		else
			seenId[p.Id] = true
		end
		if type(p.Milestones) ~= 'table' then
			issues[#issues + 1] = ('%s.Milestones must be a table'):format(tag)
		else
			local count = #p.Milestones
			if count < 1 then
				issues[#issues + 1] = ('%s.Milestones must define at least 1 milestone'):format(tag)
			end
			if milestoneCount == nil then
				milestoneCount = count
			elseif count ~= milestoneCount then
				issues[#issues + 1] = ('%s has %d milestones, expected %d (pools must match the UI)'):format(
					tag,
					count,
					milestoneCount :: number
				)
			end
			local prevThreshold = 0
			for index = 1, count do
				local mTag = ('%s.Milestones[%d]'):format(tag, index)
				local entry = p.Milestones[index]
				if type(entry) ~= 'table' then
					issues[#issues + 1] = ('%s is missing (milestones must be contiguous from 1)'):format(mTag)
					continue
				end
				local threshold = entry.RequiredPlaytime
				if type(threshold) ~= 'number' or threshold <= 0 then
					issues[#issues + 1] = ('%s.RequiredPlaytime must be a positive number of seconds'):format(mTag)
				elseif threshold <= prevThreshold then
					issues[#issues + 1] = ('%s.RequiredPlaytime=%s must strictly ascend (prev %s)'):format(
						mTag,
						tostring(threshold),
						tostring(prevThreshold)
					)
				else
					prevThreshold = threshold
				end
				for _, issue in ipairs(Codes.ValidateRewards(entry.Rewards)) do
					issues[#issues + 1] = ('%s: %s'):format(mTag, issue)
				end
			end
		end
	end
	if type(settings) ~= 'table' then
		issues[#issues + 1] = 'Playtime.Settings must be a table'
		return issues
	end
	local s = settings :: PlaytimeSettings
	if s.SessionResetsOnLeave ~= true then
		issues[#issues + 1] = 'Playtime.Settings.SessionResetsOnLeave must be true (session-based by design)'
	end
	if type(s.DailyResetTimezone) ~= 'string' or s.DailyResetTimezone == '' then
		issues[#issues + 1] = 'Playtime.Settings.DailyResetTimezone must be a non-empty string'
	end
	if
		type(s.DailyResetHour) ~= 'number'
		or s.DailyResetHour ~= math.floor(s.DailyResetHour)
		or s.DailyResetHour < 0
		or s.DailyResetHour > 23
	then
		issues[#issues + 1] = 'Playtime.Settings.DailyResetHour must be an integer 0..23'
	end
	if
		type(s.DailyResetMinute) ~= 'number'
		or s.DailyResetMinute ~= math.floor(s.DailyResetMinute)
		or s.DailyResetMinute < 0
		or s.DailyResetMinute > 59
	then
		issues[#issues + 1] = 'Playtime.Settings.DailyResetMinute must be an integer 0..59'
	end
	if type(s.SkipAllEnabled) ~= 'boolean' then
		issues[#issues + 1] = 'Playtime.Settings.SkipAllEnabled must be a boolean'
	end
	return issues
end

-- Live validation (server boot + service init). The reward
-- probes are the shared pure configs, so this is the same
-- pass; kept as a separate entry point per convention.
function Playtime.ValidateLive(): { string }
	return Playtime.ValidateList(Playtime.Pools, Playtime.Settings)
end

-- ConfigValidator entry point (pure).
function Playtime.Validate(): { string }
	return Playtime.ValidateList(Playtime.Pools, Playtime.Settings)
end

table.freeze(Codes)
table.freeze(Daily)
table.freeze(Playtime)
local Rewards = {
	Codes = Codes,
	Daily = Daily,
	Playtime = Playtime,
}

return table.freeze(Rewards)
