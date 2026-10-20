--!strict
--!native
--[[
	PlaytimeRewardsService
	======================
	Server-authoritative SESSION playtime courses. The client
	sends ONLY intent (PlaytimeRewardsAction { Action = 'State'
	| 'Claim', Index }); the server decides the pool, the
	playtime, the eligibility, and the rewards. No playtime,
	pool, or reward field is ever accepted from the client.

	Session model (§1-2, §15-17):
	  * sessions[userId] = { start (server os.clock, monotonic),
	    poolId, dayId, token }. Playtime = os.clock() - start.
	    AFK counts (no activity tracking exists by design).
	  * Raw playtime is NEVER persisted and NEVER Heartbeat-
	    ticked into the profile (§16): it derives from the
	    session timestamp on demand.
	  * Leave discards the session (ForgetPlayer). Rejoin
	    starts at 0 with pool selection per the lifecycle
	    below; already-claimed milestones are NOT re-granted.

	Pool lifecycle (§19-26, §58-65):
	  * Global IST-day pool (PlaytimeRewardsDay, 00:00
	    Asia/Kolkata by pure UTC+5:30 arithmetic) is the
	    default for every session — all players share it.
	  * Resume: persisted DayId == today, pool valid, not
	    completed → same pool, claimed preserved, playtime 0.
	  * Completed course (any day) → next session picks a
	    personal fresh pool (random, excluding the completed
	    one when alternatives exist). This is the ONE
	    documented exception to globally-identical pools: it
	    never touches other players' live sessions.
	  * New IST day / fresh profile → today's global pool.
	  * Mid-session (including IST midnight while online):
	    the session pool NEVER changes and the UI never
	    swaps; the next join resolves anew. Session playtime
	    simply continues (§59).

	Eligibility (§8-11): milestone i is Locked until
	playtime >= RequiredPlaytime (cumulative, never reset by
	claims), Claimable once reached, Claimed only by its own
	committed claim. Multiple milestones may be Claimable at
	once (§10); each is claimed individually (§38).

	Reward pipeline: the SAME canonical systems as Codes —
	EconomyService.AddMoney (cash auto-replicates + cash-pool
	burst with the shared MoneyIcon), GearShopService for
	tools, CodesService.DeliverEggReward / DeliverAnimalReward
	for slot-bound rewards with the SAME profile pending queue
	(delivered by the existing join/sell hooks). Commit order
	tools -> cash -> slots-or-pending -> mark; per-player
	mutex; threshold pushes are single-shot task.delays (no
	loops, no Heartbeat), guarded by session token.

	Skip All (§41-42): NOT implemented — no monetization
	exists. Skip button stays visually present and unwired;
	this file + config carry the (disabled) extension point.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local PlaytimeRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Playtime
local PlaytimeRewardsDay = require(script.Parent.PlaytimeRewardsDay)
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

local PlaytimeRewardsService = {}

local playerServiceRef: any = nil
local economyServiceRef: any = nil
local gearShopServiceRef: any = nil
local codesServiceRef: any = nil

-- Live sessions: [userId] -> { start, poolId, dayId, token }.
-- Session objects are never persisted; the profile carries
-- only pool identity + explicit claims.
local sessions: { [number]: { [string]: any } } = {}
local sessionToken: number = 0
-- Per-player claim mutex (spam-click / remote-spam guard).
local locks: { [number]: boolean } = {}
-- Per-player skip-all entitlement (session only): set by
-- GrantSkipAccess, which ONLY the Shop SkipPlaytime receipt
-- path calls after a validated Robux purchase. Never persisted.
local _skipAccess: { [number]: boolean } = {}

local started = false

function PlaytimeRewardsService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function PlaytimeRewardsService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

function PlaytimeRewardsService.SetGearShopService(svc: any)
	gearShopServiceRef = svc
end

function PlaytimeRewardsService.SetCodesService(svc: any)
	codesServiceRef = svc
end

local function logPlaytime(message: string, context: any?)
	if context ~= nil then
		Debug.Log('PT', message, context)
	else
		Debug.Log('PT', message, {})
	end
end

local function pushStateRemote(player: Player, snapshot: any)
	pcall(Remotes.FireClient, player, Remotes.Names.PlaytimeRewardsState, snapshot)
end

local function pushResult(player: Player, payload: any)
	pcall(Remotes.FireClient, player, Remotes.Names.PlaytimeRewardsResult, payload)
end

local function failClaim(player: Player, reason: string, warningId: string): { [string]: any }
	local message: string? = nil
	pcall(function()
		message = NotificationService.GetWarningText(warningId, nil)
	end)
	pcall(NotificationService.NotifyWarning, player, warningId, nil)
	return { Success = false, Reason = reason, Message = message }
end

-- Forward: shared milestone-grant used by ClaimInner (below)
-- and ClaimAll. Assigned further down; declared here so
-- ClaimInner captures the local instead of a global.
local commitMilestone: (
	player: Player,
	userId: number,
	data: any,
	session: any,
	persisted: any,
	pool: any,
	index: number,
	milestone: any,
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

-- Lazy-heal the persisted course slice (template + load
-- normalize cover the normal paths).
local function persistedOf(data: any): { [string]: any }
	if type(data.PlaytimeRewards) ~= 'table' then
		data.PlaytimeRewards = { DayId = '', PoolId = '', Claimed = {}, Completed = false }
	end
	local persisted = data.PlaytimeRewards
	if type(persisted.DayId) ~= 'string' then
		persisted.DayId = ''
	end
	if type(persisted.PoolId) ~= 'string' then
		persisted.PoolId = ''
	end
	if type(persisted.Claimed) ~= 'table' then
		persisted.Claimed = {}
	end
	if type(persisted.Completed) ~= 'boolean' then
		persisted.Completed = false
	end
	return persisted
end

local function randomPoolExcluding(excludeId: string?): string?
	local ids: { string } = {}
	for _, pool in ipairs(PlaytimeRewardsConfig.Pools) do
		if type(pool) == 'table' and type(pool.Id) == 'string' then
			ids[#ids + 1] = pool.Id
		end
	end
	if #ids < 1 then
		return nil
	end
	if #ids == 1 then
		return ids[1]
	end
	local candidates: { string } = {}
	for _, id in ipairs(ids) do
		if id ~= excludeId then
			candidates[#candidates + 1] = id
		end
	end
	if #candidates < 1 then
		candidates = ids
	end
	return candidates[math.random(#candidates)]
end

-- Resolve (or resume) the live session, persisting pool
-- identity back to the profile. Never grants, never claims —
-- pure session setup. Returns nil when unresolvable.
local function resolveSession(userId: number, data: any): { [string]: any }?
	local existing = sessions[userId]
	if existing ~= nil then
		return existing
	end
	local today = PlaytimeRewardsDay.Current()
	if today.PoolId == '' then
		return nil
	end
	local persisted = persistedOf(data)
	local poolId: string? = nil
	local claimed: { [number]: boolean } = {}
	if persisted.Completed == true then
		-- Completed course (any day): personal fresh pool next
		-- session, excluding the completed one when possible.
		poolId = randomPoolExcluding(persisted.PoolId)
		persisted.DayId = today.DayId
		persisted.PoolId = poolId or ''
		persisted.Claimed = {}
		persisted.Completed = false
		claimed = {}
		logPlaytime('new session pool selected', {
			userId = tostring(userId),
			reason = 'completed-course',
			pool = tostring(poolId),
		})
	elseif persisted.DayId == today.DayId and persisted.PoolId ~= '' then
		if PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, persisted.PoolId) ~= nil then
			-- Incomplete same-day course: resume pool + claims,
			-- playtime restarts at 0 below.
			poolId = persisted.PoolId
			if type(persisted.Claimed) == 'table' then
				for key, value in pairs(persisted.Claimed) do
					if type(key) == 'number' and value == true then
						claimed[key] = true
					end
				end
			end
		end
	end
	if poolId == nil or poolId == '' then
		-- Fresh profile, new IST day, or config drift: today's
		-- global pool with a clean claimed set.
		poolId = today.PoolId
		persisted.DayId = today.DayId
		persisted.PoolId = poolId
		persisted.Claimed = {}
		persisted.Completed = false
		claimed = {}
	end
	sessionToken += 1
	local session = {
		start = os.clock(),
		poolId = poolId,
		dayId = today.DayId,
		token = sessionToken,
	}
	sessions[userId] = session
	logPlaytime('session started', { userId = tostring(userId), pool = tostring(poolId), day = today.DayId })
	-- Single-shot threshold pushes (no loops, no Heartbeat):
	-- when each unclaimed milestone unlocks, push a fresh
	-- snapshot so the topbar alert turns ON without reopening.
	-- Guarded by session token (stale sessions never push).
	local pool = PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, poolId)
	if type(pool) == 'table' then
		for index, milestone in ipairs(pool.Milestones) do
			if not claimed[index] and type(milestone) == 'table' and type(milestone.RequiredPlaytime) == 'number' then
				local remaining = milestone.RequiredPlaytime
				if remaining > 0 then
					local token = sessionToken
					local capturedPool = poolId
					local capturedDay = today.DayId
					task.delay(remaining + 1, function()
						pcall(function()
							local live = sessions[userId]
							if live == nil or live.token ~= token then
								return
							end
							if live.poolId ~= capturedPool or live.dayId ~= capturedDay then
								return
							end
							PlaytimeRewardsService.PushStateById(userId)
						end)
					end)
				end
			end
		end
	end
	return session
end

local function sessionPlaytime(session: { [string]: any }): number
	return math.max(0, os.clock() - (session.start :: number))
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

-- Per-milestone authoritatitve states: 'Claimed' (explicit
-- claim only) | 'Claimable' (threshold reached) | 'Locked'.
local function milestoneState(claimed: boolean, playtime: number, required: number): string
	if claimed then
		return 'Claimed'
	end
	if playtime >= required then
		return 'Claimable'
	end
	return 'Locked'
end

-- Authoritative snapshot (state requests, post-claim pushes,
-- threshold pushes). Resolves the session lazily so any order
-- of join/request works.
function PlaytimeRewardsService.GetSnapshot(userId: number): { [string]: any }?
	local data = getData(userId)
	if type(data) ~= 'table' then
		return nil
	end
	local session = resolveSession(userId, data)
	if session == nil then
		return nil
	end
	local pool = PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, session.poolId)
	if type(pool) ~= 'table' then
		return nil
	end
	local persisted = persistedOf(data)
	local claimed: { [number]: boolean } = {}
	if type(persisted.Claimed) == 'table' then
		for key, value in pairs(persisted.Claimed) do
			if type(key) == 'number' and value == true then
				claimed[key] = true
			end
		end
	end
	local playtime = sessionPlaytime(session)
	local rewards: { any } = {}
	local completedCount = 0
	for index, milestone in ipairs(pool.Milestones) do
		if type(milestone) ~= 'table' then
			continue
		end
		local isClaimed = claimed[index] == true
		if isClaimed then
			completedCount += 1
		end
		local entry: { [string]: any } = {
			Index = index,
			RequiredPlaytime = milestone.RequiredPlaytime,
			State = milestoneState(isClaimed, playtime, milestone.RequiredPlaytime),
			Remaining = math.max(0, math.floor(milestone.RequiredPlaytime - playtime)),
			Cash = nil,
			Eggs = {},
			Tools = {},
			Animals = {},
		}
		local rw = milestone.Rewards
		if type(rw.Cash) == 'string' then
			entry.Cash = rw.Cash
		end
		if type(rw.Eggs) == 'table' then
			for _, egg in ipairs(rw.Eggs) do
				if type(egg) == 'table' then
					entry.Eggs[#entry.Eggs + 1] = { Rarity = egg.Rarity, Amount = egg.Amount }
				end
			end
		end
		if type(rw.Tools) == 'table' then
			for _, tool in ipairs(rw.Tools) do
				if type(tool) == 'table' then
					entry.Tools[#entry.Tools + 1] =
						{ Id = tool.Id, Name = gearDisplayName(tool.Id), Amount = tool.Amount }
				end
			end
		end
		if type(rw.Animals) == 'table' then
			for _, animal in ipairs(rw.Animals) do
				if type(animal) == 'table' then
					entry.Animals[#entry.Animals + 1] =
						{ DefId = animal.DefId, Name = animalDisplayName(animal.DefId), Amount = animal.Amount }
				end
			end
		end
		rewards[#rewards + 1] = entry
	end
	return {
		PoolId = session.poolId,
		DayId = session.dayId,
		Playtime = math.floor(playtime),
		SessionStart = session.start,
		Completed = completedCount >= #pool.Milestones and #pool.Milestones > 0,
		ClaimedCount = completedCount,
		Version = math.floor(os.clock() * 1000),
		Rewards = rewards,
	}
end

function PlaytimeRewardsService.PushState(player: Player)
	local snapshot: { [string]: any }? = nil
	pcall(function()
		snapshot = PlaytimeRewardsService.GetSnapshot(player.UserId)
	end)
	if snapshot ~= nil then
		pushStateRemote(player, snapshot)
	end
end

function PlaytimeRewardsService.PushStateById(userId: number)
	local player: Player? = nil
	pcall(function()
		player = Players:GetPlayerByUserId(userId)
	end)
	if player ~= nil then
		PlaytimeRewardsService.PushState(player)
	end
end

-- Join hook (bootstrap, after profile load): start the session
-- clock + arm threshold pushes immediately so the topbar
-- alert can turn ON without the player opening anything.
function PlaytimeRewardsService.OnPlayerReady(player: Player)
	pcall(function()
		local data = getData(player.UserId)
		if type(data) ~= 'table' then
			return
		end
		resolveSession(player.UserId, data)
	end)
end

function PlaytimeRewardsService.ForgetPlayer(userId: number)
	sessions[userId] = nil
	locks[userId] = nil
end

-- The one authoritative claim path. Index is validated but
-- NEVER trusted: threshold, claimed-set, pool, and rewards
-- all recompute server-side.
function PlaytimeRewardsService.Claim(player: Player, index: any): { [string]: any }
	local userId = player.UserId
	logPlaytime('reward claim requested', {
		player = player.Name,
		userId = tostring(userId),
		index = tostring(index),
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
		result = PlaytimeRewardsService.ClaimInner(player, userId, index)
		ok = true
	end)
	locks[userId] = nil
	if not ok then
		warn(('[PlaytimeRewards] Claim errored player=%s'):format(player.Name))
		result = failClaim(player, 'internal', 'General_Generic')
	end
	-- Funnel: successful milestone claim only.
	if result.Success == true then
		pcall(function()
			FunnelService:LogStep(player, 'Rewards', 'PlaytimeRewardClaimed', { milestone = index })
		end)
	end
	pushResult(player, result)
	return result
end

function PlaytimeRewardsService.ClaimInner(player: Player, userId: number, index: any): { [string]: any }
	if playerServiceRef == nil or economyServiceRef == nil or codesServiceRef == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local data = getData(userId)
	if type(data) ~= 'table' then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local session = resolveSession(userId, data)
	if session == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local pool = PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, session.poolId)
	if type(pool) ~= 'table' or #pool.Milestones < 1 then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	if type(index) ~= 'number' or index ~= math.floor(index) or index < 1 or index > #pool.Milestones then
		return failClaim(player, 'not-ready', 'Playtime_NotReady')
	end
	local milestone = pool.Milestones[index]
	if type(milestone) ~= 'table' or #CodesConfig.ValidateRewards(milestone.Rewards) > 0 then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	local persisted = persistedOf(data)
	local claimed: { [number]: boolean } = {}
	if type(persisted.Claimed) == 'table' then
		for key, value in pairs(persisted.Claimed) do
			if type(key) == 'number' and value == true then
				claimed[key] = true
			end
		end
	end
	if claimed[index] == true then
		logPlaytime('claim rejected', { player = player.Name, reason = 'already-claimed', index = tostring(index) })
		return failClaim(player, 'already-claimed', 'Playtime_AlreadyClaimed')
	end
	local playtime = sessionPlaytime(session)
	if playtime < milestone.RequiredPlaytime then
		logPlaytime('claim rejected', { player = player.Name, reason = 'not-ready', index = tostring(index) })
		return failClaim(player, 'not-ready', 'Playtime_NotReady')
	end
	if milestone.Rewards.Tools ~= nil and gearShopServiceRef == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	logPlaytime('reward claim validated', { player = player.Name, index = tostring(index) })
	return commitMilestone(player, userId, data, session, persisted, pool, index, milestone, false)
end

-- Shared milestone-grant: tools (idempotent) -> cash
-- (infallible) -> slot rewards (direct-or-pending), then the
-- milestone is marked. Used by single Claim AND by ClaimAll,
-- so both paths grant identically. `quiet` suppresses the
-- per-milestone toast/state push (ClaimAll composes one
-- summary instead); marking still happens per milestone,
-- exactly as single claims do. Returns the standard claim
-- result table.
commitMilestone = function(
	player: Player,
	userId: number,
	data: any,
	session: any,
	persisted: any,
	pool: any,
	index: number,
	milestone: any,
	quiet: boolean?
): { [string]: any }
	-- Commit order mirrors Codes (tools idempotent -> cash
	-- infallible -> slot rewards direct-or-pending). The
	-- milestone is marked ONLY after everything lands.
	local rewards = milestone.Rewards
	local label = ('PLAYTIME_%s_M%d'):format(session.poolId, index)
	local toolParts: { string } = {}
	if rewards.Tools ~= nil then
		for _, tool in ipairs(rewards.Tools) do
			local granted = false
			pcall(function()
				granted = gearShopServiceRef.EnsureGearTool(player, tool.Id) == true
			end)
			if not granted then
				return failClaim(player, 'grant-failed', 'General_Generic')
			end
			toolParts[#toolParts + 1] = '+' .. gearDisplayName(tool.Id)
			logPlaytime('tool granted', { player = player.Name, index = tostring(index) })
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
		if not BigNumber.IsZero(rewards.Cash) then
			pcall(function()
				Remotes.FireClient(player, Remotes.Names.CashCollected, {
					Amount = rewards.Cash,
					NewMoney = res.NewMoney,
					Icon = MoneyIcon.Resolve(),
				})
			end)
		end
		logPlaytime('cash granted', {
			player = player.Name,
			index = tostring(index),
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
					logPlaytime('egg delivered', { player = player.Name, index = tostring(index) })
				else
					codesServiceRef.QueuePendingReward(data, { Code = label, Kind = 'Egg', Rarity = egg.Rarity })
					eggParts[#eggParts + 1] = ('+1 %s Egg'):format(egg.Rarity)
					queuedCount += 1
					logPlaytime('egg queued', { player = player.Name, index = tostring(index) })
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
					logPlaytime('animal queued', { player = player.Name, index = tostring(index) })
				end
			end
		end
	end

	-- Mark ONLY this milestone. Claiming never advances
	-- playtime and never touches siblings.
	persisted.Claimed[index] = true
	local total = 0
	for _, value in pairs(persisted.Claimed) do
		if value == true then
			total += 1
		end
	end
	local completed = total >= #pool.Milestones
	if completed then
		persisted.Completed = true
		logPlaytime('session completed', { player = player.Name, pool = tostring(session.poolId) })
	end
	logPlaytime('reward claimed', {
		player = player.Name,
		index = tostring(index),
		queued = tostring(queuedCount),
		completed = tostring(completed),
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
		pcall(NotificationService.NotifySuccess, player, 'Playtime_Success', { RewardText = rewardText })
	end
	local snapshot = PlaytimeRewardsService.GetSnapshot(userId)
	if snapshot ~= nil and not quiet then
		pushStateRemote(player, snapshot)
	end
	return { Success = true, Index = index, RewardText = rewardText, State = snapshot }
end

function PlaytimeRewardsService.ForgetPlayer(userId: number)
	sessions[userId] = nil
	locks[userId] = nil
	_skipAccess[userId] = nil
end

-- Skip-all: claims every unclaimed milestone of the current
-- session pool in one authoritative pass. ROBUX-GATED: the
-- GUI Skip button prompts the Shop SkipPlaytime product
-- purchase, and the Shop receipt grants access
-- (GrantSkipAccess) before claiming — a bare ClaimAll remote
-- with no entitlement is rejected with Shop_SkipRequired,
-- never granted. Grants through the SAME commitMilestone each single
-- Claim uses — no duplicated reward logic — but composes ONE
-- summary toast and ONE state push. A milestone that cannot
-- grant stops the pass; already-marked milestones stay
-- marked, so a retry continues instead of duplicating
-- (idempotent). Fully-claimed sessions succeed immediately
-- with zero grants. Returns { Success, ClaimedCount }.
function PlaytimeRewardsService.ClaimAll(player: Player): { [string]: any }
	local userId = player.UserId
	logPlaytime('skip-all requested', { player = player.Name, userId = tostring(userId) })
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
		result = PlaytimeRewardsService.ClaimAllInner(player, userId)
		ok = true
	end)
	locks[userId] = nil
	if not ok then
		warn(('[PlaytimeRewards] ClaimAll errored player=%s'):format(player.Name))
		result = failClaim(player, 'internal', 'General_Generic')
	end
	-- Funnel: successful skip-all sweep only.
	if result.Success == true then
		pcall(function()
			FunnelService:LogStep(player, 'Rewards', 'PlaytimeRewardClaimed', { via = 'skip-all' })
		end)
	end
	pushResult(player, result)
	return result
end

function PlaytimeRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }
	if playerServiceRef == nil or economyServiceRef == nil or codesServiceRef == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local data = getData(userId)
	if type(data) ~= 'table' then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local session = resolveSession(userId, data)
	if session == nil then
		return failClaim(player, 'no-systems', 'General_Generic')
	end
	local pool = PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, session.poolId)
	if type(pool) ~= 'table' or #pool.Milestones < 1 then
		return failClaim(player, 'invalid-config', 'General_Generic')
	end
	local persisted = persistedOf(data)
	local claimed: { [number]: boolean } = {}
	if type(persisted.Claimed) == 'table' then
		for key, value in pairs(persisted.Claimed) do
			if type(key) == 'number' and value == true then
				claimed[key] = true
			end
		end
	end
	local claimedCount = 0
	local texts: { string } = {}
	for index = 1, #pool.Milestones do
		if claimed[index] == true then
			continue
		end
		local milestone = pool.Milestones[index]
		if type(milestone) ~= 'table' or #CodesConfig.ValidateRewards(milestone.Rewards) > 0 then
			logPlaytime('skip-all stopped', {
				player = player.Name,
				reason = 'invalid-config',
				index = tostring(index),
			})
			break
		end
		if milestone.Rewards.Tools ~= nil and gearShopServiceRef == nil then
			logPlaytime('skip-all stopped', { player = player.Name, reason = 'no-systems', index = tostring(index) })
			break
		end
		local r = commitMilestone(player, userId, data, session, persisted, pool, index, milestone, true)
		if not r.Success then
			logPlaytime('skip-all stopped', {
				player = player.Name,
				reason = tostring(r.Reason),
				index = tostring(index),
			})
			break
		end
		claimed[index] = true
		claimedCount += 1
		if type(r.RewardText) == 'string' and r.RewardText ~= '' then
			texts[#texts + 1] = ('M%d:%s'):format(index, r.RewardText)
		end
	end
	local summary = ('Skipped %d milestone(s). %s'):format(claimedCount, table.concat(texts, ' | '))
	pcall(NotificationService.NotifySuccess, player, 'Playtime_Success', { RewardText = ' ' .. summary })
	local snapshot = PlaytimeRewardsService.GetSnapshot(userId)
	if snapshot ~= nil then
		pushStateRemote(player, snapshot)
	end
	logPlaytime('skip-all committed', { player = player.Name, claimed = tostring(claimedCount) })
	return { Success = true, ClaimedCount = claimedCount, RewardText = summary, State = snapshot }
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
			logPlaytime('playtime state requested', { player = player.Name })
			PlaytimeRewardsService.PushState(player)
		elseif payload.Action == 'Claim' then
			-- payload.Index is validated but NEVER trusted:
			-- threshold, claimed-set, pool, and rewards all
			-- recompute server-side from the session clock.
			PlaytimeRewardsService.Claim(player, payload.Index)
		elseif payload.Action == 'ClaimAll' then
			-- GUI Skip button + Shop skip purchase share this
			-- path: identical authoritative skip-all behavior.
			PlaytimeRewardsService.ClaimAll(player)
		end
	end)
	if not ok then
		warn(('[PlaytimeRewards] Action handler errored: %s'):format(tostring(err)))
	end
end

-- --- Init ------------------------------------------------------------------

function PlaytimeRewardsService.Init()
	if started then
		return
	end
	started = true
	for _, issue in ipairs(PlaytimeRewardsConfig.ValidateLive()) do
		warn(('[PlaytimeRewards] Config issue: %s'):format(issue))
	end
	local ok, err = pcall(function()
		local folder = Remotes.GetFolder()
		local remote = folder:WaitForChild(Remotes.Names.PlaytimeRewardsAction, 10)
		assert(remote and remote:IsA('RemoteEvent'), 'PlaytimeRewardsAction remote missing')
		local actionRemote = remote :: RemoteEvent
		actionRemote.OnServerEvent:Connect(handleAction)
	end)
	if not ok then
		warn(('[PlaytimeRewards] Action remote wiring failed: %s'):format(tostring(err)))
	end
	logPlaytime('Init done')
end

function PlaytimeRewardsService._TestReset()
	for key in pairs(sessions) do
		sessions[key] = nil
	end
	for key in pairs(locks) do
		locks[key] = nil
	end
	for key in pairs(_skipAccess) do
		_skipAccess[key] = nil
	end
	sessionToken = 0
	PlaytimeRewardsDay._TestReset()
end

-- Entitlement grant for the paid skip-all. Called ONLY by the
-- Shop SkipPlaytime receipt path after Roblox confirms payment.
-- Idempotent; per-userId session state (leave clears it).
-- Accepts the same player-likes ClaimAll itself does (numeric
-- UserId — real players and table fakes alike).
function PlaytimeRewardsService.GrantSkipAccess(player: any): boolean
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

return table.freeze(PlaytimeRewardsService)
