--!strict
--[[
	PlaytimeRewardsDay
	==================
	GLOBAL daily pool selection for playtime courses: exactly
	ONE pool per global IST day, identical on every server and
	every player, stable for the whole day, surviving server
	restarts. Mirrors DailyRewardsWeek (weekly) at day
	granularity.

	How (in priority order):
	  1. DataStore (authoritative): key `CurrentDay` in
	     `p7_PlaytimeRewards_Daily_v1` holds { DayId, PoolId,
	     PreviousPoolId, SetAt }. Selection runs inside
	     UpdateAsync, which is ATOMIC per key: servers
	     reaching a new day simultaneously serialize — the
	     loser re-runs against the winner's committed value
	     and keeps it. Exactly one pool wins.
	  2. Deterministic fallback (DataStore unreachable):
	     hash(DayId) over the catalog, skipping the previous
	     day's hash pick when alternatives exist.

	DayId: explicit 00:00 Asia/Kolkata boundary derived from
	server os.time() by pure arithmetic — (os.time() + offset)
	divided into 86400-second days (UTC+5:30, never the client
	clock, never server-local midnight). The offset lives in
	Rewards.Playtime.Settings.DayBoundaryOffsetSeconds. The anchor
	never moves, so every server agrees on "today".

	Avoid-repeat: with >1 pool, the new pick never equals the
	stored PreviousPoolId (a single-pool catalog repeats).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local DataStoreService = game:GetService('DataStoreService')

local PlaytimeRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Playtime
local Debug = require(ReplicatedStorage.Utility.Debug)

-- Day-boundary offset (UTC+5:30): canonical in Rewards.Playtime.Settings
-- (DayBoundaryOffsetSeconds; must match DailyResetTimezone). Was a
-- hardcoded 19800 here; the config is now the single source of truth.
local IST_OFFSET_SECONDS = PlaytimeRewardsConfig.Settings.DayBoundaryOffsetSeconds
local SECONDS_PER_DAY = 24 * 60 * 60
local DATASTORE_NAME = 'p7_PlaytimeRewards_Daily_v1'
local DATASTORE_KEY = 'CurrentDay'

local PlaytimeRewardsDay = {}

local cache: { dayIndex: number, dayId: string, poolId: string, source: string } =
	{ dayIndex = -1, dayId = '', poolId = '', source = '' }

local storeHandle: DataStore? = nil
local storeFailed = false

local function logDay(message: string, context: any?)
	if context ~= nil then
		Debug.Log('PTD', message, context)
	else
		Debug.Log('PTD', message, {})
	end
end

-- IST calendar day index (pure arithmetic on server time).
function PlaytimeRewardsDay.DayIndexAt(now: number): number
	return math.floor((now + IST_OFFSET_SECONDS) / SECONDS_PER_DAY)
end

local function dayIdOf(dayIndex: number): string
	return ('D%06d'):format(dayIndex)
end

local function validPoolId(poolId: any): boolean
	return PlaytimeRewardsConfig.FindPool(PlaytimeRewardsConfig.Pools, poolId) ~= nil
end

local function hashDay(dayId: string): number
	local h = 0
	for i = 1, #dayId do
		h = (h * 33 + string.byte(dayId, i)) % 1000003
	end
	return h
end

local function poolIds(): { string }
	local ids: { string } = {}
	for _, pool in ipairs(PlaytimeRewardsConfig.Pools) do
		if type(pool) == 'table' and type(pool.Id) == 'string' then
			ids[#ids + 1] = pool.Id
		end
	end
	return ids
end

local function deterministicPoolId(dayId: string, prevDayId: string?): string?
	local ids = poolIds()
	if #ids < 1 then
		return nil
	end
	if #ids == 1 then
		return ids[1]
	end
	local pick = ids[(hashDay(dayId) % #ids) + 1]
	if prevDayId ~= nil then
		local prevPick = ids[(hashDay(prevDayId) % #ids) + 1]
		if pick == prevPick then
			pick = ids[((hashDay(dayId) + 1) % #ids) + 1]
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

local function loadOrSelectGlobal(dayId: string): { [string]: any }?
	local store = getStore()
	if store == nil then
		return nil
	end
	local ok, result = pcall(function()
		return (store :: DataStore):UpdateAsync(DATASTORE_KEY, function(current: any): any
			if type(current) == 'table' and current.DayId == dayId and validPoolId(current.PoolId) then
				return current
			end
			local prev: string? = nil
			if type(current) == 'table' and type(current.PoolId) == 'string' then
				prev = current.PoolId
			end
			local poolId = randomPoolId(prev)
			if poolId == nil then
				return current
			end
			return {
				DayId = dayId,
				PoolId = poolId,
				PreviousPoolId = prev,
				SetAt = os.time(),
			}
		end)
	end)
	if ok and type(result) == 'table' and result.DayId == dayId and validPoolId(result.PoolId) then
		return result
	end
	return nil
end

-- Current global day { DayId, PoolId, Source }. Cached per
-- dayIndex; refreshes exactly at the IST boundary. Never
-- throws; falls back deterministically when the global store
-- is unreachable.
function PlaytimeRewardsDay.Current(nowOverride: number?): { [string]: string }
	local now = if type(nowOverride) == 'number' then nowOverride :: number else os.time()
	local dayIndex = PlaytimeRewardsDay.DayIndexAt(now)
	if cache.dayIndex == dayIndex and validPoolId(cache.poolId) then
		return { DayId = cache.dayId, PoolId = cache.poolId, Source = cache.source }
	end
	local dayId = dayIdOf(dayIndex)
	local committed = loadOrSelectGlobal(dayId)
	local poolId: string? = nil
	local source = 'global'
	if committed ~= nil then
		poolId = committed.PoolId
		logDay('global pool active', { day = dayId, pool = tostring(poolId) })
	else
		poolId = deterministicPoolId(dayId, dayIdOf(dayIndex - 1))
		source = 'local-fallback'
		logDay('global store unreachable, deterministic fallback', { day = dayId, pool = tostring(poolId) })
	end
	if poolId == nil or not validPoolId(poolId) then
		cache = { dayIndex = dayIndex, dayId = dayId, poolId = '', source = 'misconfigured' }
		Debug.Warn('PlaytimeRewardsDay', ('no valid daily pool for %s (check PlaytimeRewardsConfig)'):format(dayId))
		return { DayId = dayId, PoolId = '', Source = 'misconfigured' }
	end
	cache = { dayIndex = dayIndex, dayId = dayId, poolId = poolId, source = source }
	return { DayId = dayId, PoolId = poolId, Source = source }
end

function PlaytimeRewardsDay._TestReset()
	cache = { dayIndex = -1, dayId = '', poolId = '', source = '' }
	storeHandle = nil
	storeFailed = false
end

return table.freeze(PlaytimeRewardsDay)
