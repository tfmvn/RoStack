--!strict
--!native
--[[
	PlayerLogger.PlayerLogger
	==========================
	Centralized server-side player monitoring for Brainrot
	Arena: lifecycle + milestone events shipped as Discord
	webhook embeds, plus the persistent all-time registry.

	What fires what (single call sites — no duplicates):
	  * bootstrap onPlayerAdded tail  -> NotifyJoin (once per
	    session; registry upsert decides first/returning)
	  * bootstrap onPlayerRemoving    -> NotifyLeave (session
	    duration from the server join tick)
	  * TutorialService Completed     -> LogMilestone
	  * ArenaService RaidComplete     -> LogMilestone
	  * RebirthService success        -> LogMilestone
	  * ShopService granted receipt   -> LogMilestone (the
	    granted branch runs once per PurchaseId, so retries
	    never double-log)

	Guarantees:
	  * NEVER gameplay-critical. Every send is async through a
	    bounded queue; gameplay never waits for Discord.
	  * Webhook URL lives ONLY in the ServerScriptService
	    `PlayerLoggerWebhookUrl` attribute (place file, never
	    git). It is never logged, never replicated, never in
	    ReplicatedStorage or client-visible state.
	  * Missing/invalid URL or disabled HTTP → Discord sends
	    off, registry still updates, one diagnostic.
	  * Bounded queue (drop-oldest + counter), bounded retries
	    with backoff, 429 Retry-After honored, shutdown
	    best-effort flush. A Discord outage cannot OOM the
	    server or wedge a join/leave/save/purchase/rebirth.
]]

local HttpService = game:GetService('HttpService')
local ServerScriptService = game:GetService('ServerScriptService')

local Config = require(script.Parent.PlayerLoggerConfig)
local PlayerRegistry = require(script.Parent.PlayerRegistry)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local PlayerLogger = {}

-- --- Internal state ------------------------------------------

local _webhookUrl: string? = nil
local _enabled = false
local _workerStarted = false
local _closing = false
local _queue: { any } = {}
local _lastSendTick = 0
local _droppedCount = 0
local _configWarned = false
-- userId -> { joinTick: number, joinTime: number }
local _sessions: { [number]: { joinTick: number, joinTime: number } } = {}

-- --- Small pure helpers (testable) ----------------------------

local function _truncate(text: string, max: number): string
	if #text <= max then
		return text
	end
	return string.sub(text, 1, math.max(0, max - 1)) .. '…'
end

function PlayerLogger.FormatUtc(epoch: number): string
	-- ISO8601 UTC for the Discord embed `timestamp` field.
	local ok, text = pcall(os.date, '!%Y-%m-%dT%H:%M:%SZ', epoch)
	if ok and type(text) == 'string' then
		return text
	end
	return '1970-01-01T00:00:00Z'
end

function PlayerLogger.FormatDuration(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds or 0))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local rest = s % 60
	if h > 0 then
		return ('%dh %02dm'):format(h, m)
	end
	if m > 0 then
		return ('%dm %02ds'):format(m, rest)
	end
	return ('%ds'):format(rest)
end

function PlayerLogger.FormatPlaytime(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds or 0))
	local h = math.floor(s / 3600)
	if h >= 48 then
		return ('%.1fd'):format(h / 24)
	end
	if h > 0 then
		return ('%.1fh'):format(s / 3600)
	end
	return PlayerLogger.FormatDuration(s)
end

local function _mentionTime(epoch: number): string
	return ('<t:%d:F> (<t:%d:R>)'):format(epoch, epoch)
end

local function _field(name: string, value: string, inline: boolean?): { [string]: any }
	return {
		name = _truncate(name, 256),
		value = _truncate(value, 1024),
		inline = inline == true,
	}
end

local function _displayNameOf(player: Player): string
	local name: string = player.Name
	pcall(function()
		if type((player :: Player).DisplayName) == 'string' then
			name = (player :: Player).DisplayName
		end
	end)
	return name
end

-- Cheap, safe progression snapshot (scalars only — never raw
-- profile data). Lazy requires keep this module cycle-free.
-- Never throws.
local function _progressSnapshot(userId: number): { [string]: any }
	local snap: { [string]: any } = { rebirths = 0, arenaLevel = 1, arenaWins = 0, tutorialCompleted = false }
	pcall(function()
		local sss = game:GetService('ServerScriptService')
		local okPs, playerService = pcall(require, sss:WaitForChild('PlayerService', 2))
		if okPs and type(playerService) == 'table' then
			local data: any = nil
			pcall(function()
				data = (playerService :: any).GetPlayerData(userId)
			end)
			if type(data) == 'table' then
				if type(data.Rebirth) == 'number' then
					snap.rebirths = math.max(0, math.floor(data.Rebirth))
				end
				if type(data.Arena) == 'table' then
					if type(data.Arena.Level) == 'number' then
						snap.arenaLevel = math.max(1, math.floor(data.Arena.Level))
					end
					if type(data.Arena.Wins) == 'number' then
						snap.arenaWins = math.max(0, math.floor(data.Arena.Wins))
					end
				end
				if type(data.Tutorial) == 'table' and data.Tutorial.Completed == true then
					snap.tutorialCompleted = true
				end
			end
		end
	end)
	return snap
end

-- --- Embed builders (pure, headless-testable) -----------------

function PlayerLogger.BuildJoinEmbed(ctx: any): { [string]: any }
	local c: any = if type(ctx) == 'table' then ctx else {}
	local username = tostring(c.username or '???')
	local display = tostring(c.displayName or username)
	local userId = tostring(c.userId or '?')
	return {
		title = _truncate('🟢 Player Joined', 256),
		description = _truncate('A player has joined Brainrot Arena.', 4096),
		color = Config.Colors.Join,
		timestamp = PlayerLogger.FormatUtc(tonumber(c.joinTime) or os.time()),
		fields = {
			_field('Player', username .. ' (@' .. display .. ')', true),
			_field('User ID', userId, true),
			_field('Account Age', tostring(c.accountAgeDays or '?') .. ' days', true),
			_field('Rebirths', tostring(c.rebirths or 0), true),
			_field('Player Status', tostring(c.statusText or 'Unknown'), true),
			_field('Server', _truncate(tostring(c.jobId or '?'), 64), true),
			_field('Joined At', _mentionTime(tonumber(c.joinTime) or os.time()), false),
		},
		footer = { text = _truncate('Brainrot Arena • Player Monitoring', 2048) },
	}
end

function PlayerLogger.BuildLeaveEmbed(ctx: any): { [string]: any }
	local c: any = if type(ctx) == 'table' then ctx else {}
	local username = tostring(c.username or '???')
	local userId = tostring(c.userId or '?')
	return {
		title = _truncate('🔴 Player Left', 256),
		description = _truncate('A player has left Brainrot Arena.', 4096),
		color = Config.Colors.Leave,
		timestamp = PlayerLogger.FormatUtc(tonumber(c.leaveTime) or os.time()),
		fields = {
			_field('Player', username .. ' (@' .. tostring(c.displayName or username) .. ')', true),
			_field('User ID', userId, true),
			_field('Session Duration', PlayerLogger.FormatDuration(tonumber(c.sessionSeconds) or 0), true),
			_field('Rebirths', tostring(c.rebirths or 0), true),
			_field('Joined At', _mentionTime(tonumber(c.joinTime) or os.time()), true),
			_field('Left At', _mentionTime(tonumber(c.leaveTime) or os.time()), true),
		},
		footer = { text = _truncate('Brainrot Arena • Player Monitoring', 2048) },
	}
end

local MILESTONE_COPY: { [string]: { [string]: any } } = {
	TutorialCompleted = {
		title = '📘 Tutorial Completed',
		description = 'A player finished onboarding.',
		color = Config.Colors.TutorialCompleted,
	},
	ArenaCompleted = {
		title = '⚔️ Arena Completed',
		description = 'A player cleared a full arena run.',
		color = Config.Colors.ArenaCompleted,
	},
	RebirthSucceeded = {
		title = '♻️ Rebirth Succeeded',
		description = 'A player rebirthed.',
		color = Config.Colors.RebirthSucceeded,
	},
	PurchaseGranted = {
		title = '💰 Purchase Granted',
		description = 'A Developer Product grant committed.',
		color = Config.Colors.PurchaseGranted,
	},
}

function PlayerLogger.BuildMilestoneEmbed(kind: string, ctx: any, details: any): { [string]: any }
	local c: any = if type(ctx) == 'table' then ctx else {}
	local d: any = if type(details) == 'table' then details else {}
	local copy: any = MILESTONE_COPY[kind]
		or { title = '📌 Event', description = 'A tracked event occurred.', color = Config.Colors.TutorialCompleted }
	local fields: { any } = {
		_field('Player', tostring(c.username or '???') .. ' (' .. tostring(c.userId or '?') .. ')', true),
		_field('Rebirths', tostring(c.rebirths or 0), true),
	}
	if kind == 'RebirthSucceeded' and d.rebirth ~= nil then
		fields[#fields + 1] = _field('New Rebirth', 'R' .. tostring(d.rebirth), true)
	elseif kind == 'PurchaseGranted' then
		if d.product_key ~= nil then
			fields[#fields + 1] = _field('Product', _truncate(tostring(d.product_key), 64), true)
		end
		if d.kind ~= nil then
			fields[#fields + 1] = _field('Kind', _truncate(tostring(d.kind), 64), true)
		end
	elseif kind == 'ArenaCompleted' and d.stage ~= nil then
		fields[#fields + 1] = _field('Stage', tostring(d.stage), true)
	end
	while #fields > 25 do
		table.remove(fields, #fields)
	end
	return {
		title = _truncate(tostring(copy.title), 256),
		description = _truncate(tostring(copy.description), 4096),
		color = copy.color,
		timestamp = PlayerLogger.FormatUtc(os.time()),
		fields = fields,
		footer = { text = _truncate('Brainrot Arena • Player Monitoring', 2048) },
	}
end

-- --- Delivery -------------------------------------------------

local function _readWebhookUrl(): string?
	local url: string? = nil
	pcall(function()
		local raw: any = ServerScriptService:GetAttribute(Config.WebhookAttribute)
		if type(raw) == 'string' and string.match(raw, '^https://discord%.com/api/webhooks/') ~= nil then
			url = raw
		end
	end)
	return url
end

local function _enqueue(embed: { [string]: any })
	if not _enabled then
		return
	end
	if #_queue >= Config.QueueCap then
		table.remove(_queue, 1)
		_droppedCount += 1
		if _droppedCount == 1 or _droppedCount % 50 == 0 then
			Debug.Warn('PLOG', 'queue full; oldest event dropped', { dropped = tostring(_droppedCount) })
		end
	end
	_queue[#_queue + 1] = { embed = embed, attempts = 0 }
end

local function _postEmbed(item: any): (boolean, string?)
	local body: string? = nil
	pcall(function()
		body = HttpService:JSONEncode({ username = 'Brainrot Arena', embeds = { item.embed } })
	end)
	if body == nil then
		return false, 'encode'
	end
	local response: any = nil
	local ok = pcall(function()
		response = HttpService:RequestAsync({
			Method = 'POST',
			Url = _webhookUrl :: string,
			Headers = { ['Content-Type'] = 'application/json' },
			Body = body,
		})
	end)
	if not ok or type(response) ~= 'table' then
		return false, 'request'
	end
	local status = tonumber(response.StatusCode) or 0
	if status >= 200 and status < 300 then
		return true, nil
	end
	if status == 429 then
		local waitSecs = 5
		pcall(function()
			local headers: any = response.Headers
			local raw = headers['retry-after'] or headers['Retry-After'] or headers['Retry-after']
			local n = tonumber(raw)
			if n ~= nil and n > 0 and n <= 60 then
				waitSecs = n
			end
		end)
		return false, 'rate-limited:' .. tostring(waitSecs)
	end
	return false, 'status:' .. tostring(status)
end

local function _worker()
	while not _closing do
		if #_queue == 0 then
			task.wait(0.5)
			continue
		end
		local gap = Config.SendIntervalSeconds - (os.clock() - _lastSendTick)
		if gap > 0 then
			task.wait(gap)
			continue
		end
		local item = table.remove(_queue, 1)
		if item == nil then
			continue
		end
		_lastSendTick = os.clock()
		local sent, reason = _postEmbed(item)
		if sent then
			continue
		end
		item.attempts += 1
		if item.attempts >= Config.MaxAttempts then
			-- Concise diagnostic; the URL is NEVER logged.
			Debug.Warn('PLOG', 'webhook delivery failed; event dropped', {
				reason = tostring(reason),
				attempts = tostring(item.attempts),
			})
			continue
		end
		local backoff = Config.RetryBackoffSeconds
		local waitSecs = backoff[math.min(item.attempts, #backoff)] or 8
		if type(reason) == 'string' and string.sub(reason, 1, 13) == 'rate-limited:' then
			waitSecs = math.max(waitSecs, tonumber(string.sub(reason, 14)) or waitSecs)
		end
		task.wait(waitSecs)
		table.insert(_queue, 1, item)
	end
end

-- --- Public API -----------------------------------------------

function PlayerLogger.Init()
	if _workerStarted then
		return
	end
	_workerStarted = true
	_webhookUrl = _readWebhookUrl()
	local httpOn = false
	pcall(function()
		httpOn = HttpService.HttpEnabled == true
	end)
	if _webhookUrl ~= nil and httpOn then
		_enabled = true
		Debug.Log('PLOG', 'player logger ready (webhook configured)', {})
	else
		if not _configWarned then
			_configWarned = true
			Debug.Warn('PLOG', 'webhook disabled (missing URL attribute or HTTP off); registry-only mode', {})
		end
	end
	task.spawn(_worker)
	pcall(function()
		game:BindToClose(function()
			_closing = true
			local flushed = 0
			while #_queue > 0 and flushed < Config.ShutdownFlushMax do
				local item = table.remove(_queue, 1)
				if item == nil then
					break
				end
				pcall(_postEmbed, item)
				flushed += 1
			end
		end)
	end)
end

function PlayerLogger.IsEnabled(): boolean
	return _enabled
end

-- Join: registry upsert FIRST (decides first/returning
-- atomically), then the embed. Runs in a spawned thread so
-- the join pipeline never waits on DataStores or Discord.
function PlayerLogger.NotifyJoin(player: Player)
	local userId: number? = nil
	pcall(function()
		userId = (player :: Player).UserId
	end)
	if type(userId) ~= 'number' then
		return
	end
	if _sessions[userId] ~= nil then
		return -- duplicate join event for a live session
	end
	_sessions[userId] = { joinTick = os.clock(), joinTime = os.time() }
	if Config.Events.Join ~= true then
		return
	end
	task.spawn(function()
		local okPlayer = false
		pcall(function()
			okPlayer = (player :: Player).Parent ~= nil
		end)
		if not okPlayer then
			_sessions[userId] = nil
			return
		end
		local snap = _progressSnapshot(userId)
		local upsert = PlayerRegistry.UpsertOnJoin(userId, {
			userId = userId,
			username = player.Name,
			displayName = _displayNameOf(player),
			rebirths = snap.rebirths,
			arenaLevel = snap.arenaLevel,
			arenaWins = snap.arenaWins,
			tutorialCompleted = snap.tutorialCompleted,
			lastJobId = game.JobId,
		})
		local statusText = 'Unknown'
		if upsert.ok == true then
			statusText = if upsert.isFirst == true then 'First-Time Player' else 'Returning Player'
		end
		local accountAge = 0
		pcall(function()
			accountAge = (player :: Player).AccountAge or 0
		end)
		_enqueue(PlayerLogger.BuildJoinEmbed({
			username = player.Name,
			displayName = _displayNameOf(player),
			userId = userId,
			accountAgeDays = accountAge,
			rebirths = snap.rebirths,
			statusText = statusText,
			jobId = game.JobId,
			joinTime = (_sessions[userId] or {}).joinTime or os.time(),
		}))
	end)
end

-- Leave: instant embed from memory + spawned registry write.
-- Never yields into the caller's cleanup path.
function PlayerLogger.NotifyLeave(player: Player)
	local userId: number? = nil
	pcall(function()
		userId = (player :: Player).UserId
	end)
	if type(userId) ~= 'number' then
		return
	end
	local session = _sessions[userId]
	_sessions[userId] = nil
	if Config.Events.Leave ~= true then
		return
	end
	local joinTick = if type(session) == 'table' then session.joinTick else os.clock()
	local joinTime = if type(session) == 'table' then session.joinTime else os.time()
	local durationSecs = math.max(0, math.floor(os.clock() - joinTick))
	local leaveTime = os.time()
	local snap = _progressSnapshot(userId)
	task.spawn(function()
		PlayerRegistry.UpdateOnLeave(userId, durationSecs, {
			username = player.Name,
			displayName = _displayNameOf(player),
			rebirths = snap.rebirths,
			arenaLevel = snap.arenaLevel,
			arenaWins = snap.arenaWins,
			tutorialCompleted = snap.tutorialCompleted,
			lastJobId = game.JobId,
		})
	end)
	_enqueue(PlayerLogger.BuildLeaveEmbed({
		username = player.Name,
		displayName = _displayNameOf(player),
		userId = userId,
		sessionSeconds = durationSecs,
		joinTime = joinTime,
		leaveTime = leaveTime,
		rebirths = snap.rebirths,
	}))
end

-- Milestone: registry snapshot refresh (spawned) + embed.
-- Call AFTER the authoritative commit, inside pcall, from the
-- owning service. Never throws.
function PlayerLogger.LogMilestone(player: Player, kind: string, details: any?)
	if Config.Events[kind] ~= true then
		return
	end
	pcall(function()
		local userId: number? = (player :: Player).UserId
		if type(userId) ~= 'number' then
			return
		end
		local snap = _progressSnapshot(userId)
		task.spawn(function()
			PlayerRegistry.UpdateProgress(userId, {
				rebirths = snap.rebirths,
				arenaLevel = snap.arenaLevel,
				arenaWins = snap.arenaWins,
				tutorialCompleted = snap.tutorialCompleted,
			})
		end)
		_enqueue(PlayerLogger.BuildMilestoneEmbed(kind, {
			username = player.Name,
			userId = userId,
			rebirths = snap.rebirths,
		}, details))
	end)
end

-- TEST-ONLY seams.
function PlayerLogger._TestReset()
	_webhookUrl = nil
	_enabled = false
	_workerStarted = false
	_closing = false
	table.clear(_queue)
	_lastSendTick = 0
	_droppedCount = 0
	_configWarned = false
	table.clear(_sessions)
end

function PlayerLogger._TestQueueLen(): number
	return #_queue
end

function PlayerLogger._TestEnable()
	_enabled = true
end

return table.freeze(PlayerLogger)
