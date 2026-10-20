--!strict
--!native
--[[
	PlayerLogger.PlayerRegistry
	============================
	Persistent all-time player registry for Brainrot Arena:
	everyone who has EVER played, not just players online now.

	Storage: a dedicated DataStore (NOT the gameplay profile
	store), one key per player (`player_<userId>`), so the
	registry grows without a single ever-growing blob and the
	bot can page it through the Roblox Open Cloud DataStore
	API (list entries + get entry — no custom backend needed).

	Entry shape (all plain JSON-safe values):
	  {
	    userId: number, username: string, displayName: string,
	    firstSeen: number (unix UTC), lastSeen: number,
	    sessions: number, playtimeSeconds: number,
	    rebirths: number, arenaLevel: number, arenaWins: number,
	    tutorialCompleted: boolean, lastJobId: string,
	  }

	Concurrency: every mutation runs through UpdateAsync with
	a pure merge, so concurrent servers/retries can never
	overwrite each other's counters (sessions +1, playtime
	added, timestamps max()'d, snapshots refreshed — never
	replaced wholesale). Duplicate join events are safe: the
	caller dedupes by session, and even a double Upsert only
	counts sessions twice in a pathological double-join the
	engine itself prevents (one Player object per userId).

	Budgets: one write on join, one on leave, one per tracked
	milestone (rebirth/tutorial/arena/purchase touches only
	snapshot fields). No reads on the hot path — UpdateAsync
	hands the old value to the transform.

	Privacy: usernames, display names, counters, timestamps
	only. No chat, no credentials, no raw profiles.

	This module never throws (all DataStore calls pcall'd) and
	never yields into gameplay: callers should still wrap in
	pcall/task.spawn per convention.
]]

local DataStoreService = game:GetService('DataStoreService')

local Config = require(script.Parent.PlayerLoggerConfig)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local PlayerRegistry = {}

local _store: DataStore? = nil
local _storeWarned = false

local function _getStore(): DataStore?
	if _store ~= nil then
		return _store
	end
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(Config.RegistryStoreName)
	end)
	if ok and store ~= nil then
		_store = store
		return _store
	end
	if not _storeWarned then
		_storeWarned = true
		Debug.Warn('REGISTRY', 'datastore unavailable; registry writes skipped', {})
	end
	return nil
end

function PlayerRegistry.KeyFor(userId: number): string
	return Config.RegistryKeyPrefix .. tostring(userId)
end

-- Pure merge: old entry (or nil) + delta + now -> new entry.
-- Exported for headless tests. Never throws.
function PlayerRegistry.MergeEntry(old: any, delta: any, now: number): { [string]: any }
	local entry: { [string]: any } = {}
	pcall(function()
		if type(old) == 'table' then
			for k, v in pairs(old) do
				entry[k] = v
			end
		end
		if type(delta) == 'table' then
			local d: any = delta
			if type(d.userId) == 'number' then
				entry.userId = d.userId
			end
			if type(d.username) == 'string' and d.username ~= '' then
				entry.username = d.username
			end
			if type(d.displayName) == 'string' and d.displayName ~= '' then
				entry.displayName = d.displayName
			end
			if type(d.firstSeen) == 'number' then
				entry.firstSeen = d.firstSeen
			end
			if type(d.lastSeen) == 'number' then
				entry.lastSeen = math.max(tonumber(entry.lastSeen) or 0, d.lastSeen)
			end
			if type(d.sessionsAdd) == 'number' then
				entry.sessions = (tonumber(entry.sessions) or 0) + math.max(0, math.floor(d.sessionsAdd))
			end
			if type(d.playtimeAdd) == 'number' then
				entry.playtimeSeconds = (tonumber(entry.playtimeSeconds) or 0) + math.max(0, math.floor(d.playtimeAdd))
			end
			if type(d.rebirths) == 'number' then
				entry.rebirths = math.max(tonumber(entry.rebirths) or 0, math.floor(d.rebirths))
			end
			if type(d.arenaLevel) == 'number' then
				entry.arenaLevel = math.max(tonumber(entry.arenaLevel) or 0, math.floor(d.arenaLevel))
			end
			if type(d.arenaWins) == 'number' then
				entry.arenaWins = math.max(tonumber(entry.arenaWins) or 0, math.floor(d.arenaWins))
			end
			if type(d.tutorialCompleted) == 'boolean' then
				entry.tutorialCompleted = (entry.tutorialCompleted == true) or d.tutorialCompleted
			end
			if type(d.lastJobId) == 'string' and d.lastJobId ~= '' then
				entry.lastJobId = d.lastJobId
			end
		end
		if type(entry.firstSeen) ~= 'number' then
			entry.firstSeen = now
		end
		if type(entry.lastSeen) ~= 'number' then
			entry.lastSeen = now
		end
		if type(entry.sessions) ~= 'number' then
			entry.sessions = 0
		end
		if type(entry.playtimeSeconds) ~= 'number' then
			entry.playtimeSeconds = 0
		end
	end)
	return entry
end

-- Join upsert: +1 session, refresh names/snapshots. Returns
-- { ok, entry, isFirst }. isFirst=false on ANY doubt
-- (store error, transform failure) — callers must render
-- "Unknown", never claim first-time unconfirmed.
function PlayerRegistry.UpsertOnJoin(userId: number, delta: any): { [string]: any }
	local result: { [string]: any } = { ok = false, entry = nil, isFirst = false }
	pcall(function()
		local store = _getStore()
		if store == nil then
			return
		end
		local now = os.time()
		local created = false
		local merged: any = nil
		local okUpdate = false
		pcall(function()
			local newValue: any = nil
			local ok, err = pcall(function()
				newValue = store:UpdateAsync(PlayerRegistry.KeyFor(userId), function(old: any)
					if old == nil then
						created = true
					end
					local d: any = { sessionsAdd = 1, lastSeen = now }
					if type(delta) == 'table' then
						for k, v in pairs(delta) do
							d[k] = v
						end
					end
					d.lastSeen = now
					return PlayerRegistry.MergeEntry(old, d, now)
				end)
			end)
			okUpdate = ok
			if not ok then
				Debug.Warn('REGISTRY', 'join upsert failed', { userId = tostring(userId), err = tostring(err) })
			else
				merged = newValue
			end
		end)
		if okUpdate then
			result.ok = true
			result.entry = merged
			result.isFirst = created
		end
	end)
	return result
end

-- Leave update: accumulate session playtime, refresh lastSeen
-- + snapshots. A missing entry (join write failed) is created
-- minimally WITHOUT inflating the session count.
function PlayerRegistry.UpdateOnLeave(userId: number, sessionSeconds: number, delta: any): { [string]: any }
	local result: { [string]: any } = { ok = false }
	pcall(function()
		local store = _getStore()
		if store == nil then
			return
		end
		local now = os.time()
		local okUpdate = false
		pcall(function()
			local ok, err = pcall(function()
				store:UpdateAsync(PlayerRegistry.KeyFor(userId), function(old: any)
					local d: any = { playtimeAdd = sessionSeconds, lastSeen = now }
					if type(delta) == 'table' then
						for k, v in pairs(delta) do
							d[k] = v
						end
					end
					d.playtimeAdd = sessionSeconds
					d.lastSeen = now
					return PlayerRegistry.MergeEntry(old, d, now)
				end)
			end)
			okUpdate = ok
			if not ok then
				Debug.Warn('REGISTRY', 'leave update failed', { userId = tostring(userId), err = tostring(err) })
			end
		end)
		result.ok = okUpdate
	end)
	return result
end

-- Milestone snapshot refresh (rebirth/tutorial/arena/purchase
-- checkpoints): merge snapshot fields only, no counters.
function PlayerRegistry.UpdateProgress(userId: number, patch: any): { [string]: any }
	local result: { [string]: any } = { ok = false }
	pcall(function()
		local store = _getStore()
		if store == nil or type(patch) ~= 'table' then
			return
		end
		local now = os.time()
		local okUpdate = false
		pcall(function()
			local ok, err = pcall(function()
				store:UpdateAsync(PlayerRegistry.KeyFor(userId), function(old: any)
					if old == nil then
						return nil -- never create from a milestone alone
					end
					local d: any = { lastSeen = now }
					for k, v in pairs(patch :: any) do
						d[k] = v
					end
					d.lastSeen = now
					return PlayerRegistry.MergeEntry(old, d, now)
				end)
			end)
			okUpdate = ok
			if not ok then
				Debug.Warn('REGISTRY', 'progress update failed', { userId = tostring(userId), err = tostring(err) })
			end
		end)
		result.ok = okUpdate
	end)
	return result
end

-- TEST-ONLY seam.
function PlayerRegistry._TestReset()
	_store = nil
	_storeWarned = false
end

return table.freeze(PlayerRegistry)
