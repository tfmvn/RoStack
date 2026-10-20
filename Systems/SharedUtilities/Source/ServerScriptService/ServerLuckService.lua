--!strict
--!native
--[[
	ServerLuckService
	=================
	Authoritative server-wide Luck multiplier for NORMAL egg
	rarity rolls. Global runtime state — never per-player, never
	persisted (no profiles, no DataStores).

	  * Default 1x (baseline weights, unchanged behavior).
	  * Future purchase flows raise it via SetLuck (2x/4x).
	  * Luck ONLY reshapes the normal roll. It never touches
	    guarantee intervals, never creates eggs, and can never
	    produce Divine/Secret (their normal weights are 0 and
	    0 × anything stays 0).
	  * Curve: weight × luck^(tierIndex / LuckExponentDivisor)
	    over the design pool Common(0) … Mythic(5). luck=1x is
	    the identity. Non-pool keys pass through unscaled.

	Replication (no new remotes): the current value is published
	as the `ServerLuck` attribute on ReplicatedStorage on every
	change (and once at Init). Late joiners read the attribute;
	live clients watch it with GetAttributeChangedSignal. The
	attribute is the single source clients may read; GetLuck()
	is the single source server code may read.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Events = require(ReplicatedStorage.Config.World.Events)
local Debug = require(ReplicatedStorage.Utility.Debug)

local ServerLuckService = {}

-- Design pool order for luck tiers (Events.LuckPoolOrder — NOT
-- Rarity.Order, which canonically sorts Mythic below Legendary;
-- luck must favor Mythic most, so the design pool Common … Mythic
-- lives in config as the single source of truth).
local LUCK_POOL: { string } = Events.LuckPoolOrder

local ATTRIBUTE = 'ServerLuck'
local DEFAULT_LUCK = 1
-- Overflow guard: luck above this is rejected (weights scale
-- as luck^(5/3) at the top tier, so 1e6 is already far beyond
-- any sane test value while keeping every intermediate value
-- in comfortable double range). Testing values like
-- 10/100/1000/10000 all pass.
local MAX_LUCK = 1000000

local _baseLuck = DEFAULT_LUCK
-- Active temporary boost (nil when none): { mult, expiresAt
-- (os.clock), version }. While active, GetLuck returns the
-- boost; otherwise the base. Session-scoped, never persisted.
local _boost: { mult: number, expiresAt: number, version: number }? = nil
local _version = 0
local _published = false
-- Expiry listeners (ShopService announces expiry through
-- these; this service stays notification-free).
local _expiryListeners: { (any) -> () } = {}

-- Longest boost the service will schedule (24h). Durations
-- come from ShopConfig.ServerLuckDurations; anything above
-- this is rejected as configuration error, not clamped.
local MAX_BOOST_DURATION_S = 86400

local function _publish()
	pcall(function()
		ReplicatedStorage:SetAttribute(ATTRIBUTE, ServerLuckService.GetLuck())
	end)
	_published = true
end

-- Drop a stale boost record (expiry task owns the publish +
-- listener fan-out; this just keeps reads truthful if a task
-- ever misfires). Never yields, never throws.
local function _reapStaleBoost()
	local b = _boost
	if b ~= nil and os.clock() >= b.expiresAt then
		_boost = nil
	end
end

-- Publish the default so the attribute exists from boot (late
-- joiners + first rolls). Idempotent. Called from
-- EggService.Init (no bootstrap changes needed).
function ServerLuckService.Init()
	if not _published then
		_publish()
	end
	Debug.Log('LUCK', 'ServerLuckService ready', { luck = tostring(ServerLuckService.GetLuck()) })
end

-- Effective luck: active boost wins, otherwise the base.
-- Time-based and self-healing: an expired boost reads as the
-- base even before its expiry task runs.
function ServerLuckService.GetLuck(): number
	_reapStaleBoost()
	local b = _boost
	if b ~= nil then
		return b.mult
	end
	return _baseLuck
end

function ServerLuckService.DefaultLuck(): number
	return DEFAULT_LUCK
end

-- Set the BASE multiplier (admin path). Cancels any active
-- boost: admin wins immediately and deterministically.
-- Accepts any finite positive number up to MAX_LUCK.
-- Returns true on change, false on rejection (state
-- unchanged). Publishes immediately so the next normal roll
-- uses it — no rejoin, no restart.
function ServerLuckService.SetLuck(mult: any): boolean
	if type(mult) ~= 'number' or mult ~= mult or mult == math.huge or mult == -math.huge then
		return false
	end
	if mult <= 0 or mult > MAX_LUCK then
		return false
	end
	if mult == _baseLuck and _boost == nil then
		return true
	end
	_baseLuck = mult
	_boost = nil
	_publish()
	Debug.Log('LUCK', 'server luck changed', { luck = tostring(ServerLuckService.GetLuck()) })
	return true
end

function ServerLuckService.MaxLuck(): number
	return MAX_LUCK
end

function ServerLuckService.ResetLuck(): boolean
	return ServerLuckService.SetLuck(DEFAULT_LUCK)
end

-- Activate a TEMPORARY server-wide boost (Robux purchase
-- path). Replacement policy: a new purchase replaces the
-- current multiplier AND its duration (never stacks, never
-- multiplies). Returns the version token on success, nil on
-- rejection. On expiry the state returns to the base luck
-- and registered listeners fire once with
-- { expiredMult, version }.
function ServerLuckService.ActivateBoost(mult: any, durationSecs: any, source: any): number?
	if type(mult) ~= 'number' or mult ~= mult or mult == math.huge or mult == -math.huge then
		return nil
	end
	if mult < 1 or mult > MAX_LUCK then
		return nil
	end
	if
		type(durationSecs) ~= 'number'
		or durationSecs ~= durationSecs
		or durationSecs < 1
		or durationSecs > MAX_BOOST_DURATION_S
	then
		return nil
	end
	_version += 1
	local token = _version
	_boost = { mult = mult, expiresAt = os.clock() + durationSecs, version = token }
	_publish()
	Debug.Log('LUCK', 'boost activated', {
		mult = tostring(mult),
		duration = tostring(durationSecs),
		source = tostring(source),
		version = tostring(token),
	})
	task.delay(durationSecs, function()
		pcall(function()
			local b = _boost
			-- Version gate: a newer purchase superseded this
			-- token, or admin cancelled it — either way this
			-- expiry is stale and must NOT clear the new luck.
			if b == nil or b.version ~= token then
				return
			end
			local expiredMult = b.mult
			_boost = nil
			_publish()
			Debug.Log('LUCK', 'boost expired', { mult = tostring(expiredMult), version = tostring(token) })
			for _, fn in ipairs(_expiryListeners) do
				pcall(fn, { expiredMult = expiredMult, version = token })
			end
		end)
	end)
	return token
end

-- Current boost snapshot or nil ({ mult, remainingSecs,
-- version }). Never throws.
function ServerLuckService.GetBoostInfo(): any?
	local b = _boost
	if b == nil or os.clock() >= b.expiresAt then
		return nil
	end
	return { mult = b.mult, remainingSecs = math.max(0, b.expiresAt - os.clock()), version = b.version }
end

-- Subscribe to boost expiry (ShopService announces it).
-- Listeners are pcall'd with the expiry info. Never throws.
function ServerLuckService.OnBoostExpired(fn: (any) -> ())
	if type(fn) == 'function' then
		_expiryListeners[#_expiryListeners + 1] = fn
	end
end

-- Luck-scaled COPY of a weight table (the canonical config is
-- never mutated). Pool tiers scale by luck^(index/divisor);
-- every other key (Divine, Secret, unknown) passes through
-- with its weight untouched. Never throws; a degenerate
-- divisor falls back to unscaled weights.
function ServerLuckService.ApplyLuck(weights: { [string]: number }, luckOverride: number?): { [string]: number }
	local out: { [string]: number } = {}
	pcall(function()
		if type(weights) ~= 'table' then
			return
		end
		local luck = if type(luckOverride) == 'number' then luckOverride :: number else ServerLuckService.GetLuck()
		if type(luck) ~= 'number' or luck ~= luck or luck <= 0 or luck > MAX_LUCK then
			luck = DEFAULT_LUCK
		end
		local divisor = RarityConfig.LuckExponentDivisor
		if type(divisor) ~= 'number' or divisor ~= divisor or divisor <= 0 then
			divisor = 3
		end
		local tierIndex: { [string]: number } = {}
		for i, rarity in ipairs(LUCK_POOL) do
			tierIndex[rarity] = i - 1
		end
		for rarity, w in pairs(weights) do
			local base = tonumber(w) or 0
			local idx = tierIndex[rarity]
			if idx ~= nil then
				out[rarity] = base * (luck ^ (idx / divisor))
			else
				out[rarity] = base
			end
		end
	end)
	return out
end

-- TEST-ONLY seam: reset to default without publishing noise.
function ServerLuckService._TestReset()
	_baseLuck = DEFAULT_LUCK
	_boost = nil
	_version = 0
	_published = false
	table.clear(_expiryListeners)
end

return table.freeze(ServerLuckService)
