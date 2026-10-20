--!strict
--!native
--[[
	NotificationService
	===================
	The ONE canonical player-feedback system: WARNINGS + SUCCESSES
	through the same server-authoritative architecture.

	  PLAYER ACTION
	       |
	       v
	  SERVER VALIDATES (the gameplay service owns the rules)
	       |
	     +---+---+
	     |       |
	   SUCCESS  REJECT
	     |       |
	     v       v
	  NotifySuccess  NotifyWarning
	     |       |
	     +---+---+
	         |
	         v
	  PlayerService.Notify -> Notify RemoteEvent
	  (ToastController: Warning amber / Reward green,
	  coalesced, animated, capped) + one-shot SFX clone
	  in the actor's PlayerGui (Steal pattern C).

	API (server chooses everything; the client only renders):
	  NotifyWarning(player, id, data?) — id is a WarningMessages
	    catalog Id. Silent/Internal severities never send (log
	    only). Unknown ids fall back to General_Generic.
	  NotifySuccess(player, id, data?) — id is a SuccessMessages
	    catalog Id, sent ONLY after the authoritative commit.
	    Unknown ids send nothing (a fabricated success is worse
	    than silence) and warn server-side.

	Data: {Placeholder} templates resolve here with
	server-calculated values (names clamped, amounts formatted
	via BigNumber — never client math). Wire format stays
	{Category, Text} so ToastController is untouched; the
	structured {Type, Id, Data} decision happens at this API.

	Spam policy: warnings throttle per player (same id 2s window
 + 6-per-5s burst cap); successes never throttle — each commit
	sends at most once by construction, and legitimate rapid
	successes (Buy Buy Buy) must all show. ToastController also
	coalesces identical text client-side as a second layer.

	Sounds: Warning -> Assets.Sfx.Error; Success -> the catalog
	entry's Sound ('Approved' or 'None'). One-shot PlayerGui clones
	play for the acting player only; existing gameplay sounds
	(steal robbery alert, CashClaim, LevelUp, roulette Reward)
	are preserved untouched. Pickup/Place/Hatch/steal-start
	successes are visual-only by catalog policy (high frequency
	/ roulette already celebrated / victim alert carries it).

	Requires only ReplicatedStorage leaves at load: every gameplay
	service requires this directly, cycle-free. Delivery needs the
	PlayerService ref (bootstrap-injected); unwired calls degrade
	to Debug.Log (tests, early boot). Never throws; both entry
	points return whether a toast was delivered.
]]

local ServerStorage = game:GetService('ServerStorage')
local Debris = game:GetService('Debris')

local WarningMessages = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Messages).Warning
local SuccessMessages = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Messages).Success
local DebugConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local RichTextFormatter = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.RichTextFormatter)
local AudioGroups = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)

local NotificationService = {}

-- --- Catalog indexes (id -> entry; built once, read-only) --------------

local _warnings: { [string]: any } = {}
for _, entry in ipairs(WarningMessages) do
	if type(entry) == 'table' and type((entry :: any).Id) == 'string' then
		_warnings[(entry :: any).Id] = entry
	end
end

local _successes: { [string]: any } = {}
for _, entry in ipairs(SuccessMessages) do
	if type(entry) == 'table' and type((entry :: any).Id) == 'string' then
		_successes[(entry :: any).Id] = entry
	end
end

local WARNING_CATEGORY = 'Warning'
local SUCCESS_CATEGORY = 'Reward'

-- --- Spam protection tuning (warnings only; feel only) -------------------

local REASON_WINDOW_S = 2.0
local BURST_MAX = 6
local BURST_WINDOW_S = 5.0

-- --- Injected refs --------------------------------------------------------

local playerServiceRef: any = nil

function NotificationService.SetPlayerService(ps: any)
	playerServiceRef = ps
end

-- --- SFX (ServerStorage.Assets.Sfx.<name>, Steal pattern C) ---------------

local _sfxCache: { [string]: Sound? } = {}
local _sfxCacheValid: { [string]: boolean } = {}
local _warnedMissing: { [string]: boolean } = {}

local function _resolveSfx(name: string): Sound?
	if _sfxCacheValid[name] then
		return _sfxCache[name]
	end
	_sfxCacheValid[name] = true
	_sfxCache[name] = nil
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local sfxRoot = assets and assets:FindFirstChild('Sfx') or nil
		local template = sfxRoot and sfxRoot:FindFirstChild(name) or nil
		if not template then
			return
		end
		if template:IsA('Sound') then
			_sfxCache[name] = template
		else
			local inner = template:FindFirstChildWhichIsA('Sound', true)
			if inner then
				_sfxCache[name] = inner
			end
		end
	end)
	if _sfxCache[name] == nil and not _warnedMissing[name] then
		_warnedMissing[name] = true
		Debug.Warn('NS', 'ServerStorage.Assets.Sfx missing — notifications run silent', { asset = name })
	end
	return _sfxCache[name]
end

-- One-shot clone into the player's PlayerGui (replicates to that
-- client alone). Never throws; silent no-op for non-players and
-- missing assets/playerGui.
local function _playSfx(player: any, assetName: string)
	pcall(function()
		if typeof(player) ~= 'Instance' or not (player :: Instance):IsA('Player') then
			return
		end
		local source = _resolveSfx(assetName)
		if not source then
			return
		end
		local typedPlayer = player :: Player
		local playerGui = typedPlayer:FindFirstChildOfClass('PlayerGui')
		if not playerGui then
			return
		end
		local clone = source:Clone()
		clone.Name = assetName .. 'NotifySfx'
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = playerGui
		if DebugConfig.Audio.Enabled == true then
						Debug.Log('Audio', ('notify resolve=%s soundId=%s volume=%s parent=PlayerGui play=called'):format(
					tostring(assetName),
					tostring((source :: Sound).SoundId),
					tostring((source :: Sound).Volume)
				))
		end
		clone:Play()
		local length = 2
		pcall(function()
			local t = (clone :: Sound).TimeLength
			if type(t) == 'number' and t == t and t > 0 then
				length = t
			end
		end)
		Debris:AddItem(clone, length + 0.5)
	end)
end

-- --- Throttle state (warnings only; per userId; dropped on leave) --------

local _lastReasonAt: { [string]: number } = {}
local _burst: { [string]: { number } } = {}

local function _userKey(player: any): string
	local id: any = nil
	pcall(function()
		id = (player :: any).UserId
	end)
	if type(id) == 'number' and id == math.floor(id) then
		return tostring(id)
	end
	return '?'
end

-- Team-Test identity for the trace line: player name when the
-- instance is live, else the user-id key.
local function _who(player: any, key: string): string
	local name: any = nil
	pcall(function()
		name = (player :: any).Name
	end)
	if type(name) == 'string' and name ~= '' then
		return name
	end
	return key
end

function NotificationService.ForgetPlayer(userId: number)
	local prefix = tostring(userId) .. ':'
	for key in pairs(_lastReasonAt) do
		if string.sub(key, 1, #prefix) == prefix then
			_lastReasonAt[key] = nil
		end
	end
	_burst[tostring(userId)] = nil
end

-- TEST-ONLY seam: drop throttle/SFX state so specs observe fresh.
function NotificationService._TestReset()
	table.clear(_lastReasonAt)
	table.clear(_burst)
	table.clear(_sfxCache)
	table.clear(_sfxCacheValid)
end

-- --- Template resolution (single formatting point) ------------------------

local _PLACEHOLDER_FALLBACK: { [string]: string } = {
	EggName = 'Egg',
	AnimalName = 'Animal',
	Name = 'item',
	Level = '?',
	Amount = '$0',
}

local function _cleanAmount(raw: any): string
	if type(raw) ~= 'string' or raw == '' then
		return '$0'
	end
	local sane = BigNumber.sanitize(raw)
	if not sane then
		return '$0'
	end
	local pretty = '0'
	pcall(function()
		pretty = BigNumber.Format(sane)
	end)
	return '$' .. pretty
end

local function _resolvePlaceholders(template: string, data: any): string
	local out = template
	pcall(function()
		-- The authoritative rarity rides alongside the entity
		-- name in `data.Rarity` (server-resolved, never client
		-- input). One rarity per message by catalog design.
		local rarity: any = nil
		if type(data) == 'table' then
			rarity = (data :: { any }).Rarity
		end
		out = string.gsub(out, '{(%w+)}', function(key: string): string
			local value: any = nil
			if type(data) == 'table' then
				value = (data :: { any })[key]
			end
			if key == 'Amount' then
				return _cleanAmount(value)
			elseif key == 'Level' then
				if type(value) == 'number' and value == math.floor(value) then
					return tostring(value)
				end
				return _PLACEHOLDER_FALLBACK.Level
			elseif key == 'EggName' or key == 'AnimalName' or key == 'Name' then
				-- Escaped always; rarity-colored when the
				-- authoritative rarity resolves. Surrounding
				-- copy stays unstyled (HUD renders it white).
				return RichTextFormatter.Entity(value, rarity, _PLACEHOLDER_FALLBACK[key] or '?')
			elseif key == 'MutationName' then
				-- Escaped always; mutation-colored when the id
				-- resolves in OverheadConfig.MutationColors.
				-- The id doubles as the display name (mutation
				-- ids are player-facing, e.g. Galactic/Frost).
				-- Surrounding copy stays unstyled (white).
				local text = if type(value) == 'string' then value else 'mutation'
				return RichTextFormatter.Mutation(text, value, 'mutation')
			else
				return RichTextFormatter.Escape(value ~= nil and tostring(value) or '?')
			end
		end)
	end)
	return out
end

-- Test seams: resolve display text without delivering.
function NotificationService.GetWarningText(id: any, data: any): string
	local entry = (type(id) == 'string' and _warnings[id]) or _warnings.General_Generic
	return _resolvePlaceholders(entry.Message, data)
end

function NotificationService.GetSuccessText(id: any, data: any): string?
	local entry = type(id) == 'string' and _successes[id] or nil
	if not entry then
		return nil
	end
	return _resolvePlaceholders(entry.Message, data)
end

-- --- Internal deliver (single wire path) ----------------------------------

local function _deliver(player: any, category: string, text: string): boolean
	if not playerServiceRef or not playerServiceRef.Notify then
		return false
	end
	local ok = false
	pcall(function()
		playerServiceRef.Notify(player, category, text)
		ok = true
	end)
	return ok
end

-- --- Public API -------------------------------------------------------------

-- Player-facing WARNING for a rejected action. `id` is a
-- WarningMessages catalog Id; `data` carries server-calculated
-- dynamic values ({ Amount } BigNumber string). Silent/Internal
-- severities never send. Unknown ids use General_Generic.
function NotificationService.NotifyWarning(player: any, id: any, data: any): boolean
	local delivered = false
	pcall(function()
		local key = _userKey(player)
		local now = os.clock()
		local entry = (type(id) == 'string' and _warnings[id]) or nil
		local resolvedId = (entry and entry.Id) or 'General_Generic'
		if entry and (entry.Severity == 'Silent' or entry.Severity == 'Internal') then
			Debug.Log('NS', 'suppressed(silent/internal)', { player = key, id = resolvedId })
			return
		end
		local text = NotificationService.GetWarningText(resolvedId, data)
		-- Same-id suppression (held-E spammer: one toast).
		local reasonKey = key .. ':' .. resolvedId
		local lastReason = _lastReasonAt[reasonKey]
		if lastReason and now - lastReason < REASON_WINDOW_S then
			return
		end
		-- Burst flood cap across all warnings.
		local stamps = _burst[key]
		if not stamps then
			stamps = {}
			_burst[key] = stamps
		end
		local fresh: { number } = {}
		for _, t in ipairs(stamps) do
			if now - t < BURST_WINDOW_S then
				fresh[#fresh + 1] = t
			end
		end
		_burst[key] = fresh
		if #fresh >= BURST_MAX then
			return
		end
		if not _deliver(player, WARNING_CATEGORY, text) then
			return
		end
		delivered = true
		_lastReasonAt[reasonKey] = now
		fresh[#fresh + 1] = now
		Debug.Log('NotificationTrace', 
				_who(player, key),
				resolvedId
			)
		Debug.Log('NS', 'warning', { player = key, id = resolvedId, text = text })
		_playSfx(player, 'Error')
	end)
	return delivered
end

-- Player-facing SUCCESS for a committed action. `id` is a
-- SuccessMessages catalog Id; `data` carries server-calculated
-- values (names, BigNumber amounts, levels). Call ONLY after the
-- authoritative commit. Never throttled: each commit sends at
-- most once by construction. Unknown ids send nothing + warn.
function NotificationService.NotifySuccess(player: any, id: any, data: any): boolean
	local delivered = false
	pcall(function()
		local key = _userKey(player)
		local entry = (type(id) == 'string' and _successes[id]) or nil
		if not entry then
			Debug.Warn('NS', 'unknown success id — nothing sent', { id = tostring(id) })
			return
		end
		local text = NotificationService.GetSuccessText(id, data)
		if not text then
			return
		end
		if not _deliver(player, SUCCESS_CATEGORY, text) then
			return
		end
		delivered = true
		Debug.Log('NotificationTrace', 
				_who(player, key),
				entry.Id
			)
		Debug.Log('NS', 'success', { player = key, id = entry.Id, text = text })
		if entry.Sound ~= nil and entry.Sound ~= '' and entry.Sound ~= 'None' then
			_playSfx(player, entry.Sound)
		end
	end)
	return delivered
end

function NotificationService.Init() end

return table.freeze(NotificationService)
