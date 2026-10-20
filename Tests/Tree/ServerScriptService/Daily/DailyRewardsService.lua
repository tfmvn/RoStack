--!strict
--!native
--[[
	DailyRewardsService
	===================
	Server-authoritative GLOBAL-weekly daily rewards. The client
	sends ONLY intent (DailyRewardsAction { Action = 'State' |
	'Claim' }); the server decides the week, the pool, the day,
	the eligibility, and the rewards. A client-sent Day is
	UX/debug only and NEVER authoritative.

	Two separate concepts (§18):
	  GLOBAL (DailyRewardsWeek): ONE 7-day pool per global
	    week, identical on every server/player, persisted
	    through the DataStore (atomic UpdateAsync) with a
	    deterministic fallback. Changes only at the weekly
	    boundary; in-game players receive fresh per-player
	    snapshots when a rollover is observed (no timers —
	    piggybacked on reward traffic).
	  PLAYER (profile.Data.DailyRewards): { WeekId, Day,
	    LastClaimAt }. Day is the NEXT claimable day 1..7;
	    Day 8 is the internal "week complete" sentinel (never
	    a reward day, never displayed as one). On a new WeekId
	    the slice resets to Day 1 AVAILABLE (never
	    auto-granted). Progress never crosses weeks.

	Streak model (server os.time() only — client clocks are
	never trusted):
	  * Never claimed (LastClaimAt <= 0): current Day
	    claimable now.
	  * elapsed >= ClaimInterval: current Day claimable.
	  * Otherwise: locked until LastClaimAt + ClaimInterval.
	  * After claiming day 7: Day becomes 8 (week complete)
	    until the next global week.

	Reward pipeline: the SAME canonical systems as Codes —
	EconomyService.AddMoney (cash auto-replicates to the cash
	UI through the root money pipeline), GearShopService for
	tools, and CodesService.DeliverEggReward /
	DeliverAnimalReward for slot-bound rewards with the SAME
	profile pending queue (CodesService.TryDeliverPending
	delivers them; join/sell hooks already exist). No second
	egg inventory, no polling, no retry loops.

	Transaction safety mirrors Codes: tools (idempotent) ->
	cash (infallible post-validation) -> slot rewards (direct
	or persisted-as-pending) -> streak advance. The streak
	advances ONLY after everything is committed or safely
	queued. Per-player mutex closes double-click/remote-spam
	races; the mutex is set synchronously before any yield.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local DailyRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Daily
local DailyRewardsWeek = require(script.Parent.DailyRewardsWeek)
local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)
local CodesConfig = require(ReplicatedStorage.Config.Economy.Rewards).Codes
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Validation = require(ReplicatedStorage.Utility.Validation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
local NotificationService = require(ServerScriptService.Base.NotificationService)
local MoneyIcon = require(ServerScriptService.Utility.MoneyIcon)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(ServerScriptService.FunnelService)

local DailyRewardsService = {}

local playerServiceRef: any = nil
local economyServiceRef: any = nil
local gearShopServiceRef: any = nil
local codesServiceRef: any = nil

-- Per-player claim mutex (double-click, multi-fire, exploiter
-- spam). Set synchronously on ingress before any yield.
local locks: { [number]: boolean } = {}
-- Per-player skip-all entitlement (session only): set by
-- GrantSkipAccess, which ONLY the Shop SkipDaily receipt path
-- calls after a validated Robux purchase. Never persisted.
local _skipAccess: { [number]: boolean } = {}
-- Last global week broadcast to in-game players (rollover push
-- marker; per-player snapshots, never a shared payload).
local lastBroadcastWeekId: string? = nil

local started = false

-- Internal sentinel: Day 8 = week complete (all 7 claimed).
-- Never a reward day; the client renders it as all-claimed.
local WEEK_COMPLETE_DAY = 8

function DailyRewardsService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function DailyRewardsService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

function DailyRewardsService.SetGearShopService(svc: any)
	gearShopServiceRef = svc
end

function DailyRewardsService.SetCodesService(svc: any)
	codesServiceRef = svc
end

local function logDaily(message: string, context: any?)
	if context ~= nil then
		Debug.Log('DR', message, context)
	else
		Debug.Log('DR', message, {})
	end
end

local function pushStateRemote(player: Player, snapshot: any)
	pcall(Remotes.FireClient, player, Remotes.Names.DailyRewardsState, snapshot)
end

local function pushResult(player: Player, payload: any)
	pcall(Remotes.FireClient, player, Remotes.Names.DailyRewardsResult, payload)
end

local function failClaim(player: Player, reason: string, warningId: string): { [string]: any }
	local message: string? = nil
	pcall(function()
		message = NotificationService.GetWarningText(warningId, nil)
	end)
	pcall(NotificationService.NotifyWarning, player, warningId, nil)
	return { Success = false, Reason = reason, Message = message }
end

-- Forward: shared day-grant used by ClaimInner (below) and
-- ClaimAll. Assigned further down; declared here so ClaimInner
-- captures the local instead of a global.
local commitDayRewards: (
	player: Player,
	userId: number,
	data: any,
	slice: any,
	week: any,
	claimDay: number,
	entry: any,
	now: number,
	quiet: boolean?
) -> { [string]: any }

local function getData(userId: number): any?
	if playerServiceRef == nil then
		return nil
	end
	local data: any = nil
	pcall(function()
		data = playerServiceRef.GetPlayerData(userId)
	end)
	return data
end

-- Lazy-heal the streak slice (template + load-normalize cover
-- the normal paths; this covers live edge cases without ever
-- deleting progress).
local function sliceOf(data: any): { [string]: any }
	if type(data.DailyRewards) ~= 'table' then
		data.DailyRewards = { WeekId = '', Day = 1, LastClaimAt = 0 }
	end
	local slice = data.DailyRewards
	if type(slice.WeekId) ~= 'string' then
		slice.WeekId = ''
	end
	if type(slice.Day) ~= 'number' or slice.Day ~= math.floor(slice.Day) or slice.Day < 1 then
		slice.Day = 1
	end
	if slice.Day > WEEK_COMPLETE_DAY then
		slice.Day = WEEK_COMPLETE_DAY
	end
	if type(slice.LastClaimAt) ~= 'number' or slice.LastClaimAt < 0 then
		slice.LastClaimAt = 0
	end
	return slice
end

-- Align the slice to the current global week (§45): a new
-- WeekId starts a fresh 1..7 course, Day 1 AVAILABLE (never
-- auto-granted). Progress never crosses weeks.
local function ensureWeek(slice: { [string]: any }, weekId: string): boolean
	if slice.WeekId == weekId then
		return false
	end
	slice.WeekId = weekId
	slice.Day = 1
	slice.LastClaimAt = 0
	return true
end

-- Pure eligibility computation (server timestamps only).
-- Returns { day, claimDay?, canClaim, nextAt }. Day 8 (week
-- complete) is NEVER claimable — the week is done until the
-- next global week, no matter how much time passes.
local function computeStatus(slice: { [string]: any }, now: number): { [string]: any }
	local day = math.clamp(math.floor(slice.Day), 1, WEEK_COMPLETE_DAY)
	if day > DailyRewardsConfig.DayCount() then
		return { day = day, claimDay = nil, canClaim = false, nextAt = 0 }
	end
	if day > DailyRewardsConfig.DayCount() then
		return { day = day, claimDay = nil, canClaim = false, nextAt = 0 }
	end
	local last = slice.LastClaimAt
	if type(last) ~= 'number' or last <= 0 then
		return { day = day, claimDay = day, canClaim = true, nextAt = 0 }
	end
	local interval = DailyRewardsConfig.Settings.ClaimInterval
	local elapsed = now - last
	if elapsed < 0 then
		-- Clock moved backwards: fail closed until the anchor
		-- passes again rather than granting on skew.
		return { day = day, claimDay = day, canClaim = false, nextAt = last + interval }
	end
	if elapsed >= interval then
		return { day = day, claimDay = day, canClaim = true, nextAt = 0 }
	end
	return { day = day, claimDay = day, canClaim = false, nextAt = last + interval }
end

local function gearDisplayName(id: string): string
	local name = tostring(id)
	pcall(function()
		local entry = GearConfig.FindGear(id)
		if entry ~= nil and type(entry.Name) == 'string' then
			name = entry.Name
		end
	end)
	return name
end

local function animalDisplayName(defId: string): string
	local name = tostring(defId)
	pcall(function()
		local _rarity, def = AnimalConfig.Get(defId)
		if type(def) == 'table' and type(def.displayName) == 'string' then
			name = def.displayName
		end
	end)
	return name
end

-- Per-day authoritative state strings (§5-6, §36): exactly
-- one of 'Claimable' | 'Claimed' | 'Locked', computed ONLY
-- from explicit claims — never from the progression marker.
--
-- Single source of truth: slice.Day is the NEXT claimable day
-- (1..7, or 8 = week complete). A day is Claimed IFF it was
-- explicitly claimed, i.e. d < slice.Day. The current Day is
-- NEVER Claimed by virtue of being current: after claiming
-- Day 1 (Day becomes 2), Day 2 is Locked until its own timer
-- expires and its own claim commits. Deriving "claimed" from
-- "day <= current Day" was the Day-2-auto-Claimed bug.
local function dayState(day: number, status: { [string]: any }): string
	if status.canClaim and status.claimDay == day then
		return 'Claimable'
	end
	if day < status.day then
		return 'Claimed'
	end
	return 'Locked'
end

-- Server-resolved per-day descriptors for the cards (the
-- client renders text/state from these; it never calculates).
local function describeDay(pool: { [string]: any }?, day: number, state: string): { [string]: any }
	local out: { [string]: any } = { Day = day, State = state, Cash = nil, Eggs = {}, Tools = {}, Animals = {} }
	if type(pool) ~= 'table' or type(pool.Days) ~= 'table' then
		return out
	end
	local entry = pool.Days[day]
	if type(entry) ~= 'table' then
		return out
	end
	local rewards = entry.Rewards
	if type(rewards.Cash) == 'string' then
		out.Cash = rewards.Cash
	end
	if type(rewards.Eggs) == 'table' then
		for _, egg in ipairs(rewards.Eggs) do
			if type(egg) == 'table' then
				out.Eggs[#out.Eggs + 1] = { Rarity = egg.Rarity, Amount = egg.Amount }
			end
		end
	end
	if type(rewards.Tools) == 'table' then
		for _, tool in ipairs(rewards.Tools) do
			if type(tool) == 'table' then
				out.Tools[#out.Tools + 1] = { Id = tool.Id, Name = gearDisplayName(tool.Id), Amount = tool.Amount }
			end
		end
	end
	if type(rewards.Animals) == 'table' then
		for _, animal in ipairs(rewards.Animals) do
			if type(animal) == 'table' then
				out.Animals[#out.Animals + 1] =
					{ DefId = animal.DefId, Name = animalDisplayName(animal.DefId), Amount = animal.Amount }
			end
		end
	end
	return out
end

-- Development invariant audit (§36). The player's week
-- state must ALWAYS satisfy:
--   1. At most ONE Claimable day.
--   2. Claimed ⟺ explicitly claimed (d < slice.Day) — a Locked
--      day can never read Claimed without its own committed
--      claim, and claiming day N can only newly mark day N.
--   3. A Claimed day never reverts (single-week slice; the
--      week change resets the whole slice explicitly).
-- Violations log loudly; state is still returned (fail-open
-- display, fail-closed grants — ClaimInner revalidates).
local function checkInvariants(days: { any }, slice: { [string]: any }, status: { [string]: any }, context: string)
	local claimable = 0
	for _, entry in ipairs(days) do
		if type(entry) == 'table' then
			local d = entry.Day
			local state = entry.State
			if state == 'Claimable' then
				claimable += 1
				if not status.canClaim or status.claimDay ~= d then
										Debug.Warn('DailyRewards', ('STATE INVARIANT VIOLATION (%s): day %s Claimable without eligibility'):format(
							context,
							tostring(d)
						))
				end
			elseif state == 'Claimed' then
				if not (type(d) == 'number' and d < slice.Day) then
										Debug.Warn('DailyRewards', ('STATE INVARIANT VIOLATION (%s): day %s Claimed without explicit claim (Day=%s)'):format(
							context,
							tostring(d),
							tostring(slice.Day)
						))
				end
			elseif state ~= 'Locked' then
				warn(
					('[DailyRewards] STATE INVARIANT VIOLATION (%s): day %s has unknown state %s'):format(
						context,
						tostring(d),
						tostring(state)
					)
				)
			end
		end
	end
	if claimable > 1 then
				Debug.Warn('DailyRewards', ('STATE INVARIANT VIOLATION (%s): %d Claimable days (max 1)'):format(context, claimable))
	end
end

local function formatCash(amount: string): string
	local text: string? = nil
	pcall(function()
		text = BigNumber.Format(amount)
	end)
	if type(text) == 'string' and text ~= '' then
		return '+$' .. text
	end
	return '+$' .. tostring(amount)
end

-- Authoritative snapshot for one player (state requests +
-- post-claim pushes + rollover broadcasts). now defaults to
-- os.time(). Repairs the slice's week alignment as a side
-- effect (fresh course on a new global week, never a grant).
function DailyRewardsService.GetSnapshot(userId: number, nowOverride: number?): { [string]: any }?
	local data = getData(userId)
	if type(data) ~= 'table' then
		return nil
	end
	local now = if type(nowOverride) == 'number' then nowOverride :: number else os.time()
	local week = DailyRewardsWeek.Current(now)
	if week.PoolId == '' then
		return nil
	end
	local slice = sliceOf(data)
	ensureWeek(slice, week.WeekId)
	local status = computeStatus(slice, now)
	local pool = DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, week.PoolId)
	local dayCount = DailyRewardsConfig.DayCount()
	local days: { any } = {}
	for day = 1, dayCount do
		days[#days + 1] = describeDay(pool, day, dayState(day, status))
	end
	checkInvariants(days, slice, status, 'snapshot')
	return {
		WeekId = week.WeekId,
		PoolId = week.PoolId,
		Day = status.day,
		ClaimableDay = if status.canClaim then status.claimDay else nil,
		CanClaim = status.canClaim,
		NextClaimAt = status.nextAt,
		LastClaimAt = slice.LastClaimAt,
		DayCount = dayCount,
		Days = days,
	}
end

function DailyRewardsService.PushState(player: Player)
	local snapshot: { [string]: any }? = nil
	pcall(function()
		snapshot = DailyRewardsService.GetSnapshot(player.UserId)
	end)
	if snapshot ~= nil then
		pushStateRemote(player, snapshot)
	end
end

-- Rollover broadcast (§37): when the global week changed
-- under us, every in-game player gets their own fresh
-- snapshot (per-player progress differs, so this is a loop,
-- never a shared broadcast payload). No timers — piggybacked
-- on reward traffic; idle players pull on open.
local function maybeBroadcastWeek(weekId: string)
	if weekId == '' or weekId == lastBroadcastWeekId then
		return
	end
	lastBroadcastWeekId = weekId
	pcall(function()
		for _, player in ipairs(Players:GetPlayers()) do
			DailyRewardsService.PushState(player)
		end
	end)
	logDaily('weekly pool broadcast', { week = weekId })
end

-- The one authoritative claim path. clickedDay (the UI
-- card the player pressed) is validated but NEVER trusted:
-- the server recomputes the claimable day and rejects any
-- mismatch. Omitted day = claim whatever is claimable.
function DailyRewardsService.Claim(player: Player, clickedDay: any): { [string]: any }
	local userId = player.UserId
	logDaily('claim requested', {
		player = player.Name,
		userId = tostring(userId),
		clickedDay = tostring(clickedDay),
	})
	if locks[userId] then
		local busy = failClaim(player, 'busy', 'General_Cooldown')
		pushResult(player, busy)
		return busy
	end
	locks[userId] = true
	local result: { [string]: any } = { Success = false, Reason = 'internal' }
	local ok = false
	pcall(function()
		result = DailyRewardsService.ClaimInner(player, userId, clickedDay)
		ok = true
	end)
	locks[userId] = nil
	if not ok then
		warn(('[DailyRewards] Claim errored player=%s'):format(player.Name))
		result = failClaim(player, 'internal', 'General_Generic')
	end
	-- Funnel: successful single-day claim only.
	if result.Success == true then
		pcall(function()
			FunnelService:LogStep(player, 'Rewards', 'DailyRewardClaimed', { day = clickedDay })
		end)
	end
	pushResult(player, result)
	return result
end

function DailyRewardsService.ClaimInner(player: Player, userId: number, clickedDay: any): { [string]: any }
	if playerServiceRef == nil or economyServiceRef == nil or codesServiceRef == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local data = getData(userId)
	if type(data) ~= 'table' then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local now = os.time()
	local week = DailyRewardsWeek.Current(now)
	if week.PoolId == '' then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	local slice = sliceOf(data)
	ensureWeek(slice, week.WeekId)
	local status = computeStatus(slice, now)
	-- Clicked-day validation (§19-21): the server recomputes
	-- eligibility and the click must match it. An explicitly
	-- claimed day re-clicked reports AlreadyClaimed; anything
	-- else out-of-window reports NotAvailable. No reward, no
	-- state change, warning SFX via the catalog entries.
	local clicked = if type(clickedDay) == 'number' then clickedDay :: number else nil
	if clicked ~= nil and clicked >= 1 and clicked <= DailyRewardsConfig.DayCount() and clicked < slice.Day then
		logDaily('claim rejected', {
			player = player.Name,
			reason = 'already-claimed',
			week = week.WeekId,
			clicked = tostring(clicked),
		})
		return failClaim(player, 'already-claimed', 'Daily_AlreadyClaimed')
	end
	if not status.canClaim or type(status.claimDay) ~= 'number' then
		logDaily('claim rejected', { player = player.Name, reason = 'not-ready', week = week.WeekId })
		return failClaim(player, 'not-ready', 'Daily_NotReady')
	end
	local claimDay = status.claimDay :: number
	if clicked ~= nil and clicked ~= claimDay then
		logDaily('claim rejected', {
			player = player.Name,
			reason = 'wrong-day',
			week = week.WeekId,
			clicked = tostring(clicked),
		})
		return failClaim(player, 'not-ready', 'Daily_NotReady')
	end
	if claimDay < 1 or claimDay > DailyRewardsConfig.DayCount() then
		return failClaim(player, 'not-ready', 'Daily_NotReady')
	end
	local pool = DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, week.PoolId)
	local entry = if type(pool) == 'table' then pool.Days[claimDay] else nil
	if type(entry) ~= 'table' or #CodesConfig.ValidateRewards(entry.Rewards) > 0 then
		logDaily('claim rejected', {
			player = player.Name,
			reason = 'invalid-config',
			week = week.WeekId,
			day = tostring(claimDay),
		})
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	return commitDayRewards(player, userId, data, slice, week, claimDay, entry, now, false)
end

-- Shared day-grant: tools (idempotent) -> cash (infallible) ->
-- slot rewards (direct-or-pending), then the streak advances.
-- Used by single Claim AND by ClaimAll, so both paths grant
-- identically. `quiet` suppresses the per-day toast/state
-- push/delay (ClaimAll composes one summary instead); the
-- streak still advances per day, exactly as single claims do.
-- Returns the standard claim result table.
commitDayRewards = function(
	player: Player,
	userId: number,
	data: any,
	slice: any,
	week: any,
	claimDay: number,
	entry: any,
	now: number,
	quiet: boolean?
): { [string]: any }
	local function fail(reason: string, toastId: string): { [string]: any }
		return failClaim(player, reason, toastId)
	end
	local rewards = entry.Rewards
	if rewards.Tools ~= nil and gearShopServiceRef == nil then
		return fail('no-systems', 'General_Generic')
	end
	logDaily('claim validated', { player = player.Name, week = week.WeekId, day = tostring(claimDay) })

	-- Commit order mirrors Codes (tools idempotent -> cash
	-- infallible -> slot rewards direct-or-pending). The
	-- streak advances ONLY after everything lands.
	local label = ('DAILY_%s_D%d'):format(week.PoolId, claimDay)
	local toolParts: { string } = {}
	if rewards.Tools ~= nil then
		for _, tool in ipairs(rewards.Tools) do
			local granted = false
			pcall(function()
				granted = gearShopServiceRef.EnsureGearTool(player, tool.Id) == true
			end)
			if not granted then
				logDaily('claim rejected', {
					player = player.Name,
					reason = 'grant-failed',
					week = week.WeekId,
					day = tostring(claimDay),
				})
				return failClaim(player, 'grant-failed', 'General_Generic')
			end
			toolParts[#toolParts + 1] = '+' .. gearDisplayName(tool.Id)
			logDaily('tool granted', { player = player.Name, week = week.WeekId, day = tostring(claimDay) })
		end
	end

	local cashText: string? = nil
	if type(rewards.Cash) == 'string' then
		local res: any = nil
		pcall(function()
			res = economyServiceRef.AddMoney(userId, rewards.Cash, 'CodeReward', { ApplyMultiplier = false })
		end)
		if type(res) ~= 'table' or res.Success ~= true then
			return failClaim(player, 'grant-failed', 'General_Generic')
		end
		cashText = formatCash(rewards.Cash)
		-- Same money-burst presentation as collects/sales/arena
		-- (and code rewards): the existing CashCollected remote
		-- drives the icon burst + count-up in
		-- MoneyPoolController. Raw BigNumber strings, never
		-- formatted; no world Origin, same as arena rewards.
		-- Skipped on zero amounts, like the collect path.
		if not BigNumber.IsZero(rewards.Cash) then
			pcall(function()
				Remotes.FireClient(player, Remotes.Names.CashCollected, {
					Amount = rewards.Cash,
					NewMoney = res.NewMoney,
					Icon = MoneyIcon.Resolve(),
				})
			end)
		end
		logDaily('cash granted', {
			player = player.Name,
			week = week.WeekId,
			day = tostring(claimDay),
			amount = tostring(rewards.Cash),
			new = tostring(res.NewMoney),
		})
	end

	local eggParts: { string } = {}
	local animalParts: { string } = {}
	local queuedCount = 0
	if type(rewards.Eggs) == 'table' then
		for _, egg in ipairs(rewards.Eggs) do
			for _ = 1, egg.Amount do
				local r = codesServiceRef.DeliverEggReward(userId, data, label, egg.Rarity)
				if r.ok then
					eggParts[#eggParts + 1] = ('+1 %s Egg'):format(egg.Rarity)
					logDaily('egg delivered', { player = player.Name, week = week.WeekId, day = tostring(claimDay) })
				else
					codesServiceRef.QueuePendingReward(data, { Code = label, Kind = 'Egg', Rarity = egg.Rarity })
					eggParts[#eggParts + 1] = ('+1 %s Egg'):format(egg.Rarity)
					queuedCount += 1
					logDaily('egg queued', { player = player.Name, week = week.WeekId, day = tostring(claimDay) })
				end
			end
		end
	end
	if type(rewards.Animals) == 'table' then
		for _, animal in ipairs(rewards.Animals) do
			for _ = 1, animal.Amount do
				local r =
					codesServiceRef.DeliverAnimalReward(userId, data, label, animal.DefId, animal.Trait, animal.Level)
				if r.ok then
					animalParts[#animalParts + 1] = ('+%s'):format(animalDisplayName(animal.DefId))
				else
					codesServiceRef.QueuePendingReward(data, {
						Code = label,
						Kind = 'Animal',
						DefId = animal.DefId,
						Trait = animal.Trait,
						Level = animal.Level,
					})
					animalParts[#animalParts + 1] = ('+%s'):format(animalDisplayName(animal.DefId))
					queuedCount += 1
					logDaily('animal queued', { player = player.Name, week = week.WeekId, day = tostring(claimDay) })
				end
			end
		end
	end

	-- Advance the streak ONLY now: everything is committed or
	-- safely persisted as pending. Day 8 = week complete.
	slice.Day = claimDay + 1
	slice.LastClaimAt = now
	logDaily('reward committed', {
		player = player.Name,
		week = week.WeekId,
		day = tostring(claimDay),
		queued = tostring(queuedCount),
	})

	local parts: { string } = {}
	if cashText ~= nil and cashText ~= '' then
		parts[#parts + 1] = cashText
	end
	for _, p in ipairs(eggParts) do
		parts[#parts + 1] = p
	end
	for _, p in ipairs(toolParts) do
		parts[#parts + 1] = p
	end
	for _, p in ipairs(animalParts) do
		parts[#parts + 1] = p
	end
	local rewardText = ' ' .. table.concat(parts, ', ')
	if queuedCount > 0 then
		rewardText ..= ' (queued: free a base slot!)'
	end
	if not quiet then
		pcall(NotificationService.NotifySuccess, player, 'Daily_Success', { RewardText = rewardText })
	end
	-- The result carries the COMPLETE fresh state (§27): the
	-- client renders it directly instead of waiting for (or
	-- racing) the separate state push below.
	local snapshot = DailyRewardsService.GetSnapshot(userId)
	if snapshot ~= nil and not quiet then
		pushStateRemote(player, snapshot)
	end
	maybeBroadcastWeek(week.WeekId)
	-- Eligibility-edge push: when this claim's timer expires
	-- the next day becomes claimable even if the panel is
	-- closed (topbar alert must turn ON without reopening).
	-- Single-shot task.delay — no loop, no polling, no
	-- Heartbeat. Safe if the player left (snapshot builds
	-- nil) or already progressed (snapshot is current
	-- anyway); the client's version guard orders delivery.
	-- Skipped for quiet (ClaimAll) callers: the final summary
	-- push below covers it.
	if slice.Day <= DailyRewardsConfig.DayCount() and not quiet then
		local delaySecs = DailyRewardsConfig.Settings.ClaimInterval + 1
		task.delay(delaySecs, function()
			pcall(function()
				DailyRewardsService.PushState(player)
			end)
		end)
	end
	return { Success = true, Day = claimDay, RewardText = rewardText, State = snapshot }
end

function DailyRewardsService.ForgetPlayer(userId: number)
	locks[userId] = nil
	_skipAccess[userId] = nil
end

-- Skip-all: claims every remaining day of the current week in
-- one authoritative pass. ROBUX-GATED: the GUI Skip button
-- prompts the Shop SkipDaily product purchase, and the Shop
-- receipt grants access (GrantSkipAccess) before claiming — a
-- bare ClaimAll remote with no entitlement is rejected with
-- Shop_SkipRequired, never granted. Grants through the SAME
-- commitDayRewards each single Claim uses — no duplicated
-- reward logic — but composes ONE summary toast and ONE state
-- push instead of seven. Days that cannot grant (config error)
-- stop the pass; already-granted days stay granted, so a retry
-- continues instead of duplicating (idempotent).
-- Fully-claimed weeks succeed immediately with zero grants.
-- Returns { Success, ClaimedDays, Complete }.
function DailyRewardsService.ClaimAll(player: Player): { [string]: any }
	local userId = player.UserId
	logDaily('skip-all requested', { player = player.Name, userId = tostring(userId) })
	if _skipAccess[userId] ~= true then
		local denied = failClaim(player, 'no-access', 'Shop_SkipRequired')
		pushResult(player, denied)
		return denied
	end
	if locks[userId] then
		local busy = failClaim(player, 'busy', 'General_Cooldown')
		pushResult(player, busy)
		return busy
	end
	locks[userId] = true
	local result: { [string]: any } = { Success = false, Reason = 'internal' }
	local ok = false
	pcall(function()
		result = DailyRewardsService.ClaimAllInner(player, userId)
		ok = true
	end)
	locks[userId] = nil
	if not ok then
		warn(('[DailyRewards] ClaimAll errored player=%s'):format(player.Name))
		result = failClaim(player, 'internal', 'General_Generic')
	end
	-- Funnel: successful skip-all sweep only (receipt-gated
	-- entitlement + identical ClaimAll path).
	if result.Success == true then
		pcall(function()
			FunnelService:LogStep(player, 'Rewards', 'DailyRewardClaimed', { via = 'skip-all' })
		end)
	end
	pushResult(player, result)
	return result
end

function DailyRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }
	if playerServiceRef == nil or economyServiceRef == nil or codesServiceRef == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local data = getData(userId)
	if type(data) ~= 'table' then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local now = os.time()
	local week = DailyRewardsWeek.Current(now)
	if week.PoolId == '' then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	local slice = sliceOf(data)
	ensureWeek(slice, week.WeekId)
	local pool = DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, week.PoolId)
	if type(pool) ~= 'table' then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	local dayCount = DailyRewardsConfig.DayCount()
	local claimedDays = 0
	local texts: { string } = {}
	for day = slice.Day, dayCount do
		local entry = pool.Days[day]
		if type(entry) ~= 'table' or #CodesConfig.ValidateRewards(entry.Rewards) > 0 then
			logDaily('skip-all stopped', {
				player = player.Name,
				reason = 'invalid-config',
				week = week.WeekId,
				day = tostring(day),
			})
			break
		end
		local r = commitDayRewards(player, userId, data, slice, week, day, entry, now, true)
		if not r.Success then
			logDaily('skip-all stopped', {
				player = player.Name,
				reason = tostring(r.Reason),
				week = week.WeekId,
				day = tostring(day),
			})
			break
		end
		claimedDays += 1
		if type(r.RewardText) == 'string' and r.RewardText ~= '' then
			texts[#texts + 1] = ('Day %d:%s'):format(day, r.RewardText)
		end
	end
	local complete = slice.Day > dayCount
	local summary = ('Skipped %d day(s). %s'):format(claimedDays, table.concat(texts, ' | '))
	pcall(NotificationService.NotifySuccess, player, 'Daily_Success', { RewardText = ' ' .. summary })
	local snapshot = DailyRewardsService.GetSnapshot(userId)
	if snapshot ~= nil then
		pushStateRemote(player, snapshot)
	end
	maybeBroadcastWeek(week.WeekId)
	logDaily('skip-all committed', {
		player = player.Name,
		week = week.WeekId,
		claimed = tostring(claimedDays),
		complete = tostring(complete),
	})
	return { Success = true, ClaimedDays = claimedDays, Complete = complete, RewardText = summary, State = snapshot }
end

-- --- Remote ingress ----------------------------------------------------

local function handleAction(player: Player, payload: any)
	local ok, err = pcall(function()
		if not Validation.LivePlayer(player) then
			return
		end
		if type(payload) ~= 'table' or type(payload.Action) ~= 'string' then
			return
		end
		if payload.Action == 'State' then
			logDaily('state requested', { player = player.Name })
			DailyRewardsService.PushState(player)
			local week = DailyRewardsWeek.Current()
			maybeBroadcastWeek(week.WeekId)
		elseif payload.Action == 'Claim' then
			-- payload.Day (if present) is UX/debug only: the
			-- server computes the claimable day itself, so a
			-- forged "Day 7" grants nothing extra.
			DailyRewardsService.Claim(player, payload.Day)
		elseif payload.Action == 'ClaimAll' then
			-- GUI Skip button + Shop skip purchase share this
			-- path: identical authoritative skip-all behavior.
			DailyRewardsService.ClaimAll(player)
		end
	end)
	if not ok then
		warn(('[DailyRewards] Action handler errored: %s'):format(tostring(err)))
	end
end

-- --- Init ------------------------------------------------------------------

function DailyRewardsService.Init()
	if started then
		return
	end
	started = true
	for _, issue in ipairs(DailyRewardsConfig.ValidateLive()) do
		warn(('[DailyRewards] Config issue: %s'):format(issue))
	end
	local ok, err = pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.DailyRewardsAction, 10)
		assert(remote and remote:IsA('RemoteEvent'), 'DailyRewardsAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
	end)
	if not ok then
		warn(('[DailyRewards] Action remote wiring failed: %s'):format(tostring(err)))
	end
	logDaily('Init done')
end

function DailyRewardsService._TestReset()
	for key in pairs(locks) do
		locks[key] = nil
	end
	for key in pairs(_skipAccess) do
		_skipAccess[key] = nil
	end
	lastBroadcastWeekId = nil
	DailyRewardsWeek._TestReset()
end

-- Entitlement grant for the paid skip-all. Called ONLY by the
-- Shop SkipDaily receipt path after Roblox confirms payment.
-- Idempotent; per-userId session state (leave clears it).
-- Accepts the same player-likes ClaimAll itself does (numeric
-- UserId — real players and table fakes alike).
function DailyRewardsService.GrantSkipAccess(player: any): boolean
	local userId: any = nil
	pcall(function()
		userId = (player :: any).UserId
	end)
	if type(userId) ~= 'number' then
		return false
	end
	_skipAccess[userId] = true
	return true
end

return table.freeze(DailyRewardsService)
