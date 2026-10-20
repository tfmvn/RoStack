--!strict
--!native
--[[
	FunnelService
	=============
	The ONE centralized server-side analytics layer for Roblox
	Funnel Events. Every gameplay service reports meaningful
	player-journey milestones here; this module is the only
	place that touches AnalyticsService.

	Non-goals (by design):
	  * NEVER gameplay-critical. Every send is pcall-guarded;
	    an analytics failure logs a diagnostic and gameplay
	    continues normally. No retries, no rollbacks.
	  * NO DataStore persistence. Session ids are memory-only
	    (UserId + join stamp); a session ends when the player
	    leaves. Analytics dedupe is a lightweight per-session
	    guard, never gameplay state.
	  * NO new remotes, NO second receipt handler, NO gameplay
	    systems. Callers invoke LogStep AFTER their own
	    authoritative commit and continue.

	Usage from gameplay services (always AFTER success):

	    pcall(function()
	        local Funnel = require(script.Parent.FunnelService)
	        Funnel:LogStep(player, "Onboarding", "FirstEggPurchased", nil)
	    end)

	Sub-paths adjust the require (script.Parent.Parent for
	Tutorial/Event/etc.). FunnelService itself is a leaf: it
	requires only Debug, so no require cycles are possible.

	Funnel step numbering is positional: step N is the index of
	the step name inside Funnels[funnel]. Roblox funnel
	telemetry keys on (funnelName, stepNumber); the stepName
	is passed through where the API accepts it.

	API contract (verified against the Creator Hub
	AnalyticsService reference): LogFunnelStepEvent(player,
	funnelName, funnelSessionId, step, stepName) and, for the
	one-time onboarding journey,
	LogOnboardingFunnelStepEvent(player, step, stepName).
	The memory-only session key (UserId + join stamp) doubles
	as funnelSessionId so recurring funnels stay session-
	scoped without any DataStore writes.

	Dashboard setup: create one funnel per Funnels key below
	with steps in the listed order and EXACT step names, or
	the dashboard will not attribute the events. Events still
	fire safely when no dashboard funnel exists (the API call
	is pcall-guarded).

	Metadata: the funnel API carries no custom fields, so
	metadata is diagnostic-only (Debug log + test seam). Keep
	payloads tiny: product keys, level bands, milestone
	numbers. Never positions, inventories, or PII.
]]

local Players = game:GetService('Players')

local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)

local FunnelService = {}

-- --- Canonical funnel plan ----------------------------------------
-- Order matters: the index IS the funnel step number.

FunnelService.Funnels = {
	Onboarding = {
		'TutorialStarted',
		'FirstEggPurchased',
		'FirstEggHatched',
		'FirstAnimalPlaced',
		'FirstArenaStarted',
		'FirstArenaCompleted',
		'TutorialCompleted',
		'TutorialSkipped',
	},
	Progression = {
		'FirstEggPurchased',
		'FirstAnimalUpgraded',
		'FirstRebirth',
	},
	Upgrade = {
		'FirstAnimalUpgraded',
		'UpgradeSucceeded',
	},
	Rebirth = {
		'RebirthAttempted',
		'RebirthRequirementReached',
		'RebirthSucceeded',
	},
	Arena = {
		'ArenaStarted',
		'StageProgressed',
		'ArenaCompleted',
	},
	Monetization = {
		'ShopItemPrompted',
		'PurchaseConfirmed',
		'ItemGranted',
	},
	GalaxyBat = {
		'GalaxyBatPrompted',
		'GalaxyBatReceiptConfirmed',
		'GalaxyBatGranted',
		'GalaxyBatEquipped',
	},
	Gear = {
		'FirstGearPurchased',
		'FirstGearEquipped',
	},
	Gamepass = {
		'GamepassPrompted',
		'GamepassSynced',
	},
	Event = {
		'EventParticipated',
		'MutationReceived',
	},
	Rewards = {
		'DailyRewardClaimed',
		'PlaytimeRewardClaimed',
		'CodeRedeemed',
	},
	Social = {
		'StealSucceeded',
		'FirstBaseLocked',
	},
}

-- One-time milestones: logged at most once per session. The key
-- is funnel/step; repeat calls in the same session are dropped.
local ONCE: { [string]: boolean } = {
	['Onboarding/TutorialStarted'] = true,
	['Onboarding/FirstEggPurchased'] = true,
	['Onboarding/FirstEggHatched'] = true,
	['Onboarding/FirstAnimalPlaced'] = true,
	['Onboarding/FirstArenaStarted'] = true,
	['Onboarding/FirstArenaCompleted'] = true,
	['Onboarding/TutorialCompleted'] = true,
	['Onboarding/TutorialSkipped'] = true,
	['Progression/FirstEggPurchased'] = true,
	['Progression/FirstAnimalUpgraded'] = true,
	['Progression/FirstRebirth'] = true,
	['Upgrade/FirstAnimalUpgraded'] = true,
	['Gear/FirstGearPurchased'] = true,
	['Gear/FirstGearEquipped'] = true,
	['Social/FirstBaseLocked'] = true,
	['Gamepass/GamepassSynced'] = true,
}

-- Suffix-scoped milestones: logged at most once per session per
-- metadata._key (e.g. one RebirthSucceeded per rebirth number,
-- one StageProgressed per milestone stage, one
-- PurchaseConfirmed per PurchaseId). Callers MUST pass _key for
-- these; without it the event logs every time (still safe,
-- just noisier).
local SCOPED: { [string]: boolean } = {
	['Rebirth/RebirthRequirementReached'] = true,
	['Rebirth/RebirthAttempted'] = true,
	['Rebirth/RebirthSucceeded'] = true,
	['Arena/StageProgressed'] = true,
	['Monetization/PurchaseConfirmed'] = true,
	['Monetization/ItemGranted'] = true,
	['GalaxyBat/GalaxyBatReceiptConfirmed'] = true,
	['GalaxyBat/GalaxyBatGranted'] = true,
	['GalaxyBat/GalaxyBatEquipped'] = true,
	['Event/EventParticipated'] = true,
}

-- Arena stages worth telemetry. The game has 50 stages; every
-- stage win would be noise, so only these milestones emit.
local ARENA_MILESTONES: { [number]: boolean } = {
	[1] = true,
	[5] = true,
	[10] = true,
	[25] = true,
	[50] = true,
}

-- --- State (memory-only, never persisted) --------------------------

local _enabled = true
local _started = false
local _sessions: { [number]: number } = {}
local _logged: { [string]: boolean } = {}
local _calls: { { [string]: any } } = {}
local _CALLS_CAP = 1000
local _sender: ((player: Player, funnel: string, sessionId: string?, stepNumber: number, stepName: string) -> boolean)? =
	nil

-- --- Helpers -------------------------------------------------------

local function _userIdOf(player: any): number?
	local id: any = nil
	pcall(function()
		id = (player :: any).UserId
	end)
	if type(id) == 'number' then
		return id
	end
	return nil
end

local function _stepNumber(funnel: string, step: string): number?
	local steps = FunnelService.Funnels[funnel]
	if type(steps) ~= 'table' then
		return nil
	end
	for i, name in ipairs(steps) do
		if name == step then
			return i
		end
	end
	return nil
end

local function _defaultSend(
	player: Player,
	funnel: string,
	sessionId: string?,
	stepNumber: number,
	stepName: string
): boolean
	local okSvc, svc = pcall(game.GetService, game, 'AnalyticsService')
	if not okSvc or svc == nil then
		return false
	end
	local sent = false
	-- Exact documented argument order: (player, funnelName,
	-- funnelSessionId, step, stepName). The one-time onboarding
	-- journey uses its dedicated endpoint. A single attempt:
	-- on failure sent stays false and the caller logs a
	-- diagnostic (gameplay is never affected).
	pcall(function()
		if funnel == 'Onboarding' then
			(svc :: any):LogOnboardingFunnelStepEvent(player, stepNumber, stepName)
		else
			(svc :: any):LogFunnelStepEvent(player, funnel, sessionId, stepNumber, stepName)
		end
		sent = true
	end)
	return sent
end

-- --- Session API ---------------------------------------------------

function FunnelService.RegisterSession(player: Player): string?
	local userId = _userIdOf(player)
	if userId == nil then
		return nil
	end
	if _sessions[userId] == nil then
		_sessions[userId] = os.clock()
	end
	return tostring(userId) .. ':' .. tostring(_sessions[userId])
end

function FunnelService.GetSessionKey(userId: number): string?
	local stamp = _sessions[userId]
	if stamp == nil then
		return nil
	end
	return tostring(userId) .. ':' .. tostring(stamp)
end

function FunnelService.ForgetPlayer(userId: number)
	if type(userId) ~= 'number' then
		return
	end
	_sessions[userId] = nil
	local prefix = tostring(userId) .. ':'
	for key in pairs(_logged) do
		if string.sub(key, 1, #prefix) == prefix then
			_logged[key] = nil
		end
	end
end

-- --- Bucketing helpers (pure, testable) ----------------------------

-- Coarse level bands for upgrade metadata: bounded
-- cardinality for analysis, never raw levels everywhere.
function FunnelService.LevelBand(level: any): string
	local n = tonumber(level) or 0
	if n <= 10 then
		return '1-10'
	end
	if n <= 25 then
		return '11-25'
	end
	if n <= 50 then
		return '26-50'
	end
	if n <= 100 then
		return '51-100'
	end
	return '100+'
end

-- True only for arena stages worth a funnel event.
function FunnelService.IsArenaMilestone(stage: any): boolean
	local n = tonumber(stage)
	if n == nil then
		return false
	end
	return ARENA_MILESTONES[math.floor(n)] == true
end

-- --- Core API ------------------------------------------------------

-- Records one funnel step for a player's current session.
-- Safe to call from ANY gameplay commit path: never throws,
-- never yields, never blocks gameplay. Returns true when the
-- event was accepted (sent or intentionally scoped), false
-- when dropped (disabled, invalid player/funnel/step).
function FunnelService:LogStep(
	player: Player,
	funnelName: string,
	stepName: string,
	metadata: { [string]: any }?
): boolean
	local ok = false
	pcall(function()
		if not _enabled then
			return
		end
		local userId = _userIdOf(player)
		if userId == nil then
			return
		end
		if type(funnelName) ~= 'string' or type(stepName) ~= 'string' then
			return
		end
		local stepNumber = _stepNumber(funnelName, stepName)
		if stepNumber == nil then
			Debug.Warn('FUNNEL', 'unknown funnel step; dropped', {
				funnel = tostring(funnelName),
				step = tostring(stepName),
			})
			return
		end
		local sessionKey = FunnelService.GetSessionKey(userId)
		if sessionKey == nil then
			sessionKey = FunnelService.RegisterSession(player)
		end
		if sessionKey == nil then
			return
		end
		local base = funnelName .. '/' .. stepName
		local scopeKey: string? = nil
		if type(metadata) == 'table' and type(metadata._key) == 'string' and metadata._key ~= '' then
			scopeKey = metadata._key
		end
		local dedupeKey: string? = nil
		if ONCE[base] then
			dedupeKey = (sessionKey :: string) .. '|' .. base
		elseif SCOPED[base] and scopeKey ~= nil then
			dedupeKey = (sessionKey :: string) .. '|' .. base .. '/' .. (scopeKey :: string)
		end
		if dedupeKey ~= nil and _logged[dedupeKey] == true then
			ok = true
			return
		end
		if dedupeKey ~= nil then
			_logged[dedupeKey] = true
		end
		if #_calls < _CALLS_CAP then
			table.insert(_calls, {
				UserId = userId,
				Session = sessionKey,
				Funnel = funnelName,
				Step = stepName,
				StepNumber = stepNumber,
				Metadata = metadata,
			})
		end
		Debug.Log('FUNNEL', 'step', {
			user = tostring(userId),
			funnel = funnelName,
			step = stepName,
			n = tostring(stepNumber),
		})
		local send = _sender or _defaultSend
		local sent, sendErr = pcall(send, player, funnelName, sessionKey, stepNumber, stepName)
		if not sent or sendErr ~= true then
			Debug.Warn('FUNNEL', 'send failed; gameplay unaffected', {
				funnel = funnelName,
				step = stepName,
			})
		end
		ok = true
	end)
	return ok
end

-- --- Lifecycle -----------------------------------------------------

function FunnelService.Start()
	if _started then
		return
	end
	_started = true
	pcall(function()
		for _, player in ipairs(Players:GetPlayers()) do
			FunnelService.RegisterSession(player)
		end
		Players.PlayerAdded:Connect(function(player: Player)
			FunnelService.RegisterSession(player)
		end)
		Players.PlayerRemoving:Connect(function(player: Player)
			local userId = _userIdOf(player)
			if userId ~= nil then
				FunnelService.ForgetPlayer(userId)
			end
		end)
	end)
end

-- --- Test seams ----------------------------------------------------

function FunnelService._TestReset()
	table.clear(_sessions)
	table.clear(_logged)
	table.clear(_calls)
	_sender = nil
	_enabled = true
	_started = false
end

function FunnelService._TestSetSender(fn: ((
	player: Player,
	funnel: string,
	sessionId: string?,
	stepNumber: number,
	stepName: string
) -> boolean)?)
	_sender = fn
end

function FunnelService._TestSetEnabled(enabled: boolean)
	_enabled = enabled and true or false
end

function FunnelService._TestGetCalls(): { { [string]: any } }
	local out: { { [string]: any } } = {}
	for _, call in ipairs(_calls) do
		table.insert(out, call)
	end
	return out
end

function FunnelService._TestWasLogged(userId: number, funnel: string, step: string): boolean
	for _, call in ipairs(_calls) do
		if call.UserId == userId and call.Funnel == funnel and call.Step == step then
			return true
		end
	end
	return false
end

return table.freeze(FunnelService)
