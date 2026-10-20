--!strict
--[[
	DailyRewardsWeek
	================
	GLOBAL weekly pool selection: exactly ONE 7-day pool per
	global week, identical on every server and every player,
	stable for the whole week, surviving server restarts.

	How (in priority order):
	  1. DataStore (authoritative): key
	     `CurrentWeek` in `p7_DailyRewards_Weekly_v1` holds
	     { WeekId, PoolId, PreviousPoolId, SetAt }. Selection
	     runs inside UpdateAsync, which is ATOMIC per key: when
	     two servers reach a new week simultaneously, their
	     transforms serialize — the loser re-runs against the
	     winner's committed value, sees its WeekId already set,
	     and keeps it. Exactly one pool wins; no split brain.
	  2. Deterministic fallback (DataStore unreachable — e.g.
	     Studio without API access): poolIndex =
	     hash(WeekId) over the catalog, skipping the previous
	     week's hash pick when more than one pool exists. Same
	     input week gives the same pool on every server with
	     zero storage. Documented limitation: the no-repeat
	     promise is best-effort here (it only knows the hash
	     chain, not a stored PreviousPoolId).

	WeekId: epoch-anchored global week index
	(`W%06d` of floor(os.time() / 604800), server time only).
	Boundaries fall on Thursday 00:00 UTC; the anchor never
	moves, so every server trivially agrees on "this week".

	Avoid-repeat: with >1 pool configured, the newly selected
	pool never equals the stored PreviousPoolId (week N+1 may
	reuse week N-1's pool — only back-to-back repeats are
	excluded; a single-pool catalog trivially repeats).

	Consumption: DailyRewardsService calls Current() per
	request (O(1) integer compare on cache hit) and broadcasts
	fresh per-player snapshots when the week rolls over.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local DataStoreService = game:GetService('DataStoreService')

local DailyRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Daily
local Debug = require(ReplicatedStorage.Utility.Debug)

local SECONDS_PER_WEEK = 7 * 24 * 60 * 60
local DATASTORE_NAME = 'p7_DailyRewards_Weekly_v1'
local DATASTORE_KEY = 'CurrentWeek'

local DailyRewardsWeek = {}

local cache: { weekIndex: number, weekId: string, poolId: string, source: string } =
	{ weekIndex = -1, weekId = '', poolId = '', source = '' }

local storeHandle: DataStore? = nil
local storeFailed = false

local function logWeek(message: string, context: any?)
	if context ~= nil then
		Debug.Log('DRW', message, context)
	else
		Debug.Log('DRW', message, {})
	end
end

local function weekIndexAt(now: number): number
	return math.floor(now / SECONDS_PER_WEEK)
end

local function weekIdOf(weekIndex: number): string
	return ('W%06d'):format(weekIndex)
end

local function validPoolId(poolId: any): boolean
	return DailyRewardsConfig.FindPool(DailyRewardsConfig.WeeklyPools, poolId) ~= nil
end

-- Small deterministic string hash (fallback path only; the
-- DataStore path uses Random for selection).
local function hashWeek(weekId: string): number
	local h = 0
	for i = 1, #weekId do
		h = (h * 33 + string.byte(weekId, i)) % 1000003
	end
	return h
end

local function poolIds(): { string }
	local ids: { string } = {}
	for _, pool in ipairs(DailyRewardsConfig.WeeklyPools) do
		if type(pool) == 'table' and type(pool.Id) == 'string' then
			ids[#ids + 1] = pool.Id
		end
	end
	return ids
end

-- Deterministic pick (fallback): hash-selected, skipping the
-- previous week's hash pick when alternatives exist.
local function deterministicPoolId(weekId: string, prevWeekId: string?): string?
	local ids = poolIds()
	if #ids < 1 then
		return nil
	end
	if #ids == 1 then
		return ids[1]
	end
	local pick = ids[(hashWeek(weekId) % #ids) + 1]
	if prevWeekId ~= nil then
		local prevPick = ids[(hashWeek(prevWeekId) % #ids) + 1]
		if pick == prevPick then
			pick = ids[((hashWeek(weekId) + 1) % #ids) + 1]
		end
	end
	return pick
end

local function randomPoolId(excludeId: string?): string?
	local ids = poolIds()
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

local function getStore(): DataStore?
	if storeHandle ~= nil then
		return storeHandle
	end
	if storeFailed then
		return nil
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok and store ~= nil then
		storeHandle = store
		return store
	end
	storeFailed = true
	return nil
end

-- Atomic load-or-select for one global week. The transform is
-- pure (no yields): it keeps a valid committed pool or selects
-- a fresh one excluding PreviousPoolId.
local function loadOrSelectGlobal(weekId: string): { [string]: any }?
	local store = getStore()
	if store == nil then
		return nil
	end
	local ok, result = pcall(function()
		return (store :: DataStore):UpdateAsync(DATASTORE_KEY, function(current: any): any
			if type(current) == 'table' and current.WeekId == weekId and validPoolId(current.PoolId) then
				return current
			end
			local prev: string? = nil
			if type(current) == 'table' and type(current.PoolId) == 'string' then
				prev = current.PoolId
			end
			local poolId = randomPoolId(prev)
			if poolId == nil then
				-- Misconfigured catalog: keep the old value (or
				-- nil) rather than writing garbage.
				return current
			end
			return {
				WeekId = weekId,
				PoolId = poolId,
				PreviousPoolId = prev,
				SetAt = os.time(),
			}
		end)
	end)
	if ok and type(result) == 'table' and result.WeekId == weekId and validPoolId(result.PoolId) then
		return result
	end
	return nil
end

-- Current global week { WeekId, PoolId, Source }. Cached per
-- weekIndex; refreshes (and reselects) exactly at the weekly
-- boundary. Never throws; falls back deterministically when
-- the global store is unreachable.
function DailyRewardsWeek.Current(nowOverride: number?): { [string]: string }
	local now = if type(nowOverride) == 'number' then nowOverride :: number else os.time()
	local weekIndex = weekIndexAt(now)
	if cache.weekIndex == weekIndex and validPoolId(cache.poolId) then
		return { WeekId = cache.weekId, PoolId = cache.poolId, Source = cache.source }
	end
	local weekId = weekIdOf(weekIndex)
	local committed = loadOrSelectGlobal(weekId)
	local poolId: string? = nil
	local source = 'global'
	if committed ~= nil then
		poolId = committed.PoolId
		logWeek('global pool active', { week = weekId, pool = tostring(poolId) })
	else
		local prevWeekId = weekIdOf(weekIndex - 1)
		poolId = deterministicPoolId(weekId, prevWeekId)
		source = 'local-fallback'
		logWeek('global store unreachable, deterministic fallback', { week = weekId, pool = tostring(poolId) })
	end
	if poolId == nil or not validPoolId(poolId) then
		-- Catalog broken (no pools): cache the miss briefly by
		-- week so we warn once per week, not per request.
		cache = { weekIndex = weekIndex, weekId = weekId, poolId = '', source = 'misconfigured' }
		Debug.Warn('DailyRewardsWeek', ('no valid weekly pool for %s (check DailyRewardsConfig)'):format(weekId))
		return { WeekId = weekId, PoolId = '', Source = 'misconfigured' }
	end
	cache = { weekIndex = weekIndex, weekId = weekId, poolId = poolId, source = source }
	return { WeekId = weekId, PoolId = poolId, Source = source }
end

function DailyRewardsWeek._TestReset()
	cache = { weekIndex = -1, weekId = '', poolId = '', source = '' }
	storeHandle = nil
	storeFailed = false
end

return table.freeze(DailyRewardsWeek)
