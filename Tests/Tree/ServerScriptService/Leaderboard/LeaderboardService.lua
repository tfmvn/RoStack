--!strict
--!native
--[[
	Leaderboard.LeaderboardService
	=============================
	Server-authoritative GLOBAL leaderboard rendered on the
	authored Studio part:

	  Workspace.Map.LeaderBoard.Display (Part)
	    SurfaceGui
	      List (ScrollingFrame): Template (Frame: Name/Money/Rank) + UIListLayout
	      Rank / Name / Money (top-player TextLabels)
	      ResetTime (TextLabel)

	GLOBAL BOARD = MONEY ONLY (this module). Ranking
	(server data only, NEVER client-submitted):
	  Higher Money wins. Nothing else matters — rebirths
	  NEVER affect this board (a 1Qa/0-rebirth fortune
	  outranks 400M/100-rebirths).
	The TAB (player-list) leaderboard is a SEPARATE system
	with its own ranking (native CoreGui list over
	player.leaderstats: Rebirths first stat, Money second) —
	see TabListService. The two rankings and stores are
	never mixed: this module's Ordered value is money-
	derived only and is never used for the Tab list.

	OrderedDataStore encoding (one integer per UserId):
	  score = moneyRank(money)
	moneyRank = orderOfMagnitude * 1e6 + first6SignificantDigits,
	derived with STRING math on the canonical BigNumber
	decimal string — tonumber() is used ONLY on a 6-digit
	prefix (always exactly representable), never on the
	full fortune, so fortunes far beyond 2^53 stay exact
	(1Qa ranks above 400M by digit length alone; formatted
	strings are never compared). Precision limit
	(documented): money that differs only past the 6th
	significant digit ties for rank; display still shows
	each exact fortune. The score stays below 1e10 — exact
	in a Lua double and inside the OrderedDataStore integer
	limit — by construction, see MoneyRank/EncodeScore.

	Money is a bare canonical decimal string everywhere
	(BigNumber system). Display uses BigNumber.Format (the
	game's formatter), extended with further suffix tiers
	past Dc so values above 1e33 NEVER render as scientific
	notation.

	Writes are debounced, never per-tick: a scan every
	SCAN_SECONDS enqueues only changed snapshots, a flush
	every FLUSH_SECONDS writes a capped batch, leave
	triggers one final write, rebirth calls MarkDirty for
	a high-priority flush (rebirth resets money, so the
	money score moves too). Every DataStore call is
	pcall-guarded with retry + backoff + a consecutive-
	failure cooldown; failures only freeze the board on
	the last good render, never break the server.

	Security: NO RemoteEvent/RemoteFunction exists for
	submitting leaderboard values. All reads come from
	EconomyService.GetMoney (server-side profile data).
]]

local Players = game:GetService('Players')
local DataStoreService = game:GetService('DataStoreService')
local RunService = game:GetService('RunService')
local Workspace = game:GetService('Workspace')

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
local StudioTestMode = require(ReplicatedStorage.Utility.StudioTestMode)

local LeaderboardService = {}

-- --- Tunables (single constant block) -----------------------------

-- Dedicated MONEY-ONLY OrderedDataStore for ranking. NEVER
-- the player profile store. Renamed from the rebirth-mixed
-- store: old rebirth-dominated scores must NEVER resurface,
-- so this board reads a fresh store (abandoned rows in the
-- old store are never read again).
LeaderboardService.ORDERED_STORE_NAME = 'p7_GlobalLeaderboardMoney_v1'
-- Companion standard store: UserId -> { m = money string,
-- n = username } for exact display of offline players
-- (Ordered values are integers only). Name kept: stored
-- money strings carry over (the dropped `r` field is
-- simply ignored where present).
LeaderboardService.META_STORE_NAME = 'p7_GlobalLeaderboardMeta_v1'
-- Rows rendered (Template clones). Not hardcoded elsewhere.
LeaderboardService.MAX_ENTRIES = 10
-- Global board re-read cadence (1 GetSortedAsync each).
LeaderboardService.REFRESH_SECONDS = 60
-- Dirty-write cadence (capped batch each).
LeaderboardService.FLUSH_SECONDS = 15
-- Full in-server scan cadence (enqueue changed only).
LeaderboardService.SCAN_SECONDS = 30
-- Write cap per flush (Ordered + meta = 2 calls each).
LeaderboardService.MAX_WRITES_PER_FLUSH = 10
-- Minimum gap between join/leave-triggered early refreshes.
LeaderboardService.EARLY_REFRESH_COOLDOWN = 20

-- --- Encoding budgets ----------------------------------------------

-- Money-only scores span [0, MONEY_SLOT): safely inside the
-- OrderedDataStore integer limit and exactly representable
-- in a Lua double (far below 2^53).
local MONEY_SLOT = 10000000000
local LEAD_DIGITS = 6
local ORDER_MULT = 1000000
local ORDER_CAP = 9000

-- --- Rank colors ----------------------------------------------------

LeaderboardService.RANK_COLORS = {
	Gold = Color3.fromRGB(255, 215, 80),
	Silver = Color3.fromRGB(210, 215, 220),
	Bronze = Color3.fromRGB(205, 135, 75),
	Rest = Color3.fromRGB(225, 225, 225),
}

function LeaderboardService.RankColor(rank: number): Color3
	if rank == 1 then
		return LeaderboardService.RANK_COLORS.Gold
	elseif rank == 2 then
		return LeaderboardService.RANK_COLORS.Silver
	elseif rank == 3 then
		return LeaderboardService.RANK_COLORS.Bronze
	end
	return LeaderboardService.RANK_COLORS.Rest
end

-- --- Pure helpers (TestEZ-safe, no services) ------------------------

-- Compact monotonic money component in [0, MONEY_SLOT).
-- orderOfMagnitude * 1e6 + first-6-significant-digits.
-- A longer integer part ALWAYS beats a shorter one
-- (1e6 step > max 999999 lead spread); equal lengths
-- compare by leading digits. Fractions are ignored
-- (floor semantics); invalid input ranks as zero.
function LeaderboardService.MoneyRank(money: any): number
	if type(money) ~= 'string' then
		return 0
	end
	local intPart = string.match(money, '^(%d+)')
	if intPart == nil then
		return 0
	end
	intPart = string.gsub(intPart, '^0+', '')
	if intPart == '' then
		return ORDER_MULT
	end
	local order = #intPart
	if order > ORDER_CAP then
		order = ORDER_CAP
	end
	local head = string.sub(intPart, 1, LEAD_DIGITS)
	while #head < LEAD_DIGITS do
		head ..= '0'
	end
	-- 6 digits max: always exactly representable.
	local lead = tonumber(head) or 0
	local rank = order * ORDER_MULT + lead
	if rank >= MONEY_SLOT then
		return MONEY_SLOT - 1
	end
	return rank
end

-- Single sortable integer for the GLOBAL board: MONEY ONLY.
-- Rebirths are deliberately NOT an input — see the header.
-- (The Tab list ranks rebirths-first natively via
-- player.leaderstats; it never reads this value.)
function LeaderboardService.EncodeScore(money: any): number
	return LeaderboardService.MoneyRank(money)
end

-- Game suffixes, then deterministic extension tiers past Dc
-- (UDc..NoDc, then Vg-group, Tg-group, ...), then an
-- engineering fallback — NEVER scientific 'e' notation.
local GAME_SUFFIXES = { '', 'K', 'M', 'B', 'T', 'Qa', 'Qi', 'Sx', 'Sp', 'Oc', 'No', 'Dc' }
local EXT_ONES = { 'U', 'D', 'T', 'Qa', 'Qi', 'Sx', 'Sp', 'O', 'N' }
local EXT_GROUPS = { 'Dc', 'Vg', 'Tg', 'Qag', 'Qig', 'Sxg', 'Spg', 'Og', 'Ng', 'Dc2' }

local function suffixForTier(tier: number): string
	if tier <= 11 then
		return GAME_SUFFIXES[tier + 1]
	end
	local idx = tier - 12
	local groupIdx = math.floor(idx / 10)
	local ones = EXT_ONES[(idx % 10) + 1]
	if groupIdx < #EXT_GROUPS then
		return ones .. EXT_GROUPS[groupIdx + 1]
	end
	-- Absurd magnitudes (past ~1e336): engineering form,
	-- still no 'e'. Suffix carries the overflow group.
	return ones .. EXT_GROUPS[#EXT_GROUPS] .. '+' .. tostring(groupIdx - #EXT_GROUPS + 1)
end

-- The game's formatter, with past-Dc values rendered on
-- extended tiers instead of BigNumber.Format's scientific
-- branch. Output always matches BigNumber.Format where
-- BigNumber.Format does not go scientific.
function LeaderboardService.FormatMoney(money: any): string
	local clean = if type(money) == 'string' then BigNumber.sanitize(money) else nil
	if clean == nil then
		return '0'
	end
	local ok, short = pcall(BigNumber.Format, clean)
	if ok and type(short) == 'string' and string.find(short, 'e', 1, true) == nil then
		return short
	end
	local intPart = string.match(clean, '^(%d+)') or '0'
	intPart = string.gsub(intPart, '^0+', '')
	if intPart == '' then
		return '0'
	end
	if #intPart == 1 then
		local frac = string.match(clean, '^%d+%.(%d+)$')
		if frac ~= nil and frac ~= '' then
			return intPart .. '.' .. string.sub(frac, 1, 1)
		end
		return intPart
	end
	local intDigits = #intPart
	local tier = math.floor((intDigits - 1) / 3)
	local tierDigits = intDigits - tier * 3
	local leading = string.sub(intPart, 1, tierDigits)
	local decDigit = string.sub(intPart, tierDigits + 1, tierDigits + 1)
	if decDigit == '' then
		decDigit = '0'
	end
	-- Engineering fallback for magnitudes past the suffix
	-- table (suffixForTier never returns scientific).
	local suffix = suffixForTier(tier)
	if string.find(suffix, '+', 1, true) ~= nil then
		return leading .. '.' .. decDigit .. 'x10^' .. tostring(intDigits - 1)
	end
	return leading .. '.' .. decDigit .. suffix
end

-- --- Wiring (late-bound, cycle-free) ---------------------------------

local playerServiceRef: any = nil
local economyServiceRef: any = nil

function LeaderboardService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function LeaderboardService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

-- --- Session state ----------------------------------------------------

local started = false
local orderedStore: OrderedDataStore? = nil
local metaStore: GlobalDataStore? = nil
local storesReady = false

-- userId -> last successfully WRITTEN score (diff base).
local lastWritten: { [number]: number } = {}
-- userId -> pending snapshot { score, money, name }.
local dirty: { [number]: { score: number, money: string, name: string } } = {}
-- userId -> resolved username cache (never cleared mid-session).
local nameCache: { [number]: string } = {}
-- orderedKey -> last seen meta { m, n } (offline display).
local lastMeta: { [string]: { m: string, n: string } } = {}
-- Last successful board entries (rendered on failure).
local lastEntries: { { key: string, score: number } } = {}
local lastRefreshAt = 0
local nextRefreshAt = 0
local lastMissingWarnAt = 0

-- Consecutive-failure cooldown: after repeated DataStore
-- failures, stop hitting the budget for a while. Display
-- keeps the last good render throughout.
local consecutiveFailures = 0
local FAILURE_COOLDOWN_AFTER = 5
local FAILURE_COOLDOWN_SECONDS = 300
local cooldownUntil = 0

local function logLb(message: string, context: { [string]: any }?)
	Debug.Log('LB', message, context or {})
end

local function warnLb(message: string, context: { [string]: any }?)
	Debug.Warn('LB', message, context or {})
end

local function inCooldown(): boolean
	return os.clock() < cooldownUntil
end

local function noteSuccess()
	consecutiveFailures = 0
	cooldownUntil = 0
end

local function noteFailure(label: string)
	consecutiveFailures += 1
	if consecutiveFailures >= FAILURE_COOLDOWN_AFTER then
		cooldownUntil = os.clock() + FAILURE_COOLDOWN_SECONDS
		warnLb(label .. ': entering DataStore cooldown', {
			failures = tostring(consecutiveFailures),
			cooldown = tostring(FAILURE_COOLDOWN_SECONDS),
		})
	end
end

-- Retry with exponential backoff + jitter. Never throws:
-- returns true on success, false after attempts run out.
local function withRetry(label: string, fn: () -> (), attempts: number?): boolean
	local tries = attempts or 3
	local delay = 1
	for i = 1, tries do
		local ok, err = pcall(fn)
		if ok then
			noteSuccess()
			return true
		end
		warnLb(label .. ' failed', { attempt = tostring(i), error = tostring(err) })
		if i < tries then
			task.wait(delay + math.random())
			delay *= 2
		end
	end
	noteFailure(label)
	return false
end

local function getStores(): (OrderedDataStore?, GlobalDataStore?)
	if storesReady then
		return orderedStore, metaStore
	end
	local ok, ordered, meta = pcall(function()
		return DataStoreService:GetOrderedDataStore(LeaderboardService.ORDERED_STORE_NAME),
			DataStoreService:GetDataStore(LeaderboardService.META_STORE_NAME)
	end)
	if ok and ordered ~= nil and meta ~= nil then
		orderedStore = ordered
		metaStore = meta
		storesReady = true
		noteSuccess()
		logLb('DataStores ready')
	else
		warnLb('DataStore handles unavailable', {})
		noteFailure('getStores')
	end
	return orderedStore, metaStore
end

-- Studio multi-instance test ids (0, -1, ...) must NEVER
-- pollute the global board.
local function isBoardEligible(userId: number): boolean
	if type(userId) ~= 'number' or userId <= 0 or userId ~= math.floor(userId) then
		return false
	end
	if StudioTestMode.IsTestUserId(userId) then
		return false
	end
	return true
end

local function readMoney(userId: number): string?
	if economyServiceRef == nil then
		return nil
	end
	local ok, money = pcall(economyServiceRef.GetMoney, userId)
	if not ok or type(money) ~= 'string' then
		return nil
	end
	return (BigNumber.sanitize(money) or '0') :: string
end

local function profileLoaded(userId: number): boolean
	if playerServiceRef == nil then
		return false
	end
	local ok, data = pcall(playerServiceRef.GetPlayerData, userId)
	return ok and data ~= nil
end

local function displayNameOf(player: Player?): string
	if player ~= nil then
		local ok, name = pcall(function()
			return player.Name
		end)
		if ok and type(name) == 'string' and name ~= '' then
			return name
		end
	end
	return ''
end

-- Snapshot one in-server player's MONEY from authoritative
-- profile data. Returns nil when there is nothing safe to
-- write (unloaded profile, unwired services): callers must
-- NOT write a zero score over a real one. Rebirths are never
-- read here — this board is money-only.
local function snapshotPlayer(userId: number): { score: number, money: string, name: string }?
	if not isBoardEligible(userId) then
		return nil
	end
	if not profileLoaded(userId) then
		return nil
	end
	local money = readMoney(userId)
	if money == nil then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	local name = displayNameOf(player)
	if name == '' then
		name = nameCache[userId] or ''
	end
	return {
		score = LeaderboardService.EncodeScore(money),
		money = money,
		name = name,
	}
end

-- High-priority path: call after a committed rebirth (which
-- resets money, so the money score moves) — money ticks
-- otherwise ride the periodic scan. Never yields, never
-- throws; safe inside transactions.
function LeaderboardService.MarkDirty(userId: number)
	if not started then
		return
	end
	if not isBoardEligible(userId) then
		return
	end
	local snap = snapshotPlayer(userId)
	if snap == nil then
		return
	end
	if lastWritten[userId] == snap.score then
		return
	end
	dirty[userId] = snap
end

local function writeSnapshot(userId: number, snap: { score: number, money: string, name: string }): boolean
	local ordered, meta = getStores()
	if ordered == nil or meta == nil or inCooldown() then
		return false
	end
	local key = tostring(userId)
	local wroteOrdered = withRetry('OrderedSet', function()
		(ordered :: OrderedDataStore):SetAsync(key, snap.score)
	end, 3)
	if not wroteOrdered then
		return false
	end
	local wroteMeta = withRetry('MetaSet', function()
		(meta :: GlobalDataStore):SetAsync(key, { m = snap.money, n = snap.name })
	end, 2)
	if not wroteMeta then
		return false
	end
	lastWritten[userId] = snap.score
	if snap.name ~= '' then
		nameCache[userId] = snap.name
	end
	lastMeta[key] = { m = snap.money, n = snap.name }
	return true
end

-- Scan every in-server player; enqueue only snapshots whose
-- score differs from the last successful write.
local function scanServer()
	for _, player in ipairs(Players:GetPlayers()) do
		local userId = player.UserId
		if isBoardEligible(userId) then
			local snap = snapshotPlayer(userId)
			if snap ~= nil and lastWritten[userId] ~= snap.score then
				dirty[userId] = snap
			end
		end
	end
end

local function flushDirty()
	local count = 0
	for userId, snap in pairs(dirty) do
		if count >= LeaderboardService.MAX_WRITES_PER_FLUSH then
			break
		end
		if lastWritten[userId] == snap.score then
			dirty[userId] = nil
		elseif writeSnapshot(userId, snap) then
			dirty[userId] = nil
			count += 1
		else
			-- Keep queued for the next flush; a dead store
			-- must not spin the budget dry mid-cycle.
			count += 1
		end
	end
end

-- Final write on leave. Reads are synchronous (no yield, so
-- this is safe at the TOP of onPlayerRemoving); the write
-- itself rides a spawned thread and never blocks cleanup.
function LeaderboardService.OnPlayerLeaving(player: Player)
	if not started then
		return
	end
	local userId = player.UserId
	if not isBoardEligible(userId) then
		return
	end
	-- Snapshot BEFORE the profile is released downstream.
	local snap = snapshotPlayer(userId)
	if snap == nil or lastWritten[userId] == snap.score then
		return
	end
	task.spawn(function()
		if writeSnapshot(userId, snap) then
			dirty[userId] = nil
		else
			dirty[userId] = snap
		end
		LeaderboardService.RequestRefresh()
	end)
end

-- Join/leave-triggered early refresh, throttled so presence
-- churn can never burn the GetSortedAsync budget.
function LeaderboardService.RequestRefresh()
	if not started then
		return
	end
	local now = os.clock()
	if now - lastRefreshAt < LeaderboardService.EARLY_REFRESH_COOLDOWN then
		return
	end
	task.spawn(function()
		LeaderboardService.RefreshNow()
		scanServer()
		flushDirty()
		nextRefreshAt = os.clock() + LeaderboardService.REFRESH_SECONDS
	end)
end

local function resolveName(userId: number, fallback: string): string
	if nameCache[userId] ~= nil then
		return nameCache[userId] :: string
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(name) == 'string' and name ~= '' then
		nameCache[userId] = name
		return name
	end
	if fallback ~= '' then
		return fallback
	end
	return 'Unknown Player'
end

-- --- Board model -------------------------------------------------------

local function findBoard(): {
	display: Part,
	gui: SurfaceGui,
	list: ScrollingFrame,
	template: Frame,
	topRank: TextLabel,
	topName: TextLabel,
	topMoney: TextLabel,
	resetTime: TextLabel,
}?
	local map = Workspace:FindFirstChild('Map')
	local board = if map ~= nil then map:FindFirstChild('LeaderBoard') else nil
	local display = if board ~= nil then board:FindFirstChild('Display') else nil
	if display == nil or not display:IsA('BasePart') then
		return nil
	end
	local gui = display:FindFirstChildOfClass('SurfaceGui')
	if gui == nil then
		return nil
	end
	local list = gui:FindFirstChild('List')
	local topRank = gui:FindFirstChild('Rank')
	local topName = gui:FindFirstChild('Name')
	local topMoney = gui:FindFirstChild('Money')
	local resetTime = gui:FindFirstChild('ResetTime')
	if
		list == nil
		or not list:IsA('ScrollingFrame')
		or topRank == nil
		or not topRank:IsA('TextLabel')
		or topName == nil
		or not topName:IsA('TextLabel')
		or topMoney == nil
		or not topMoney:IsA('TextLabel')
		or resetTime == nil
		or not resetTime:IsA('TextLabel')
	then
		return nil
	end
	local template = list:FindFirstChild('Template')
	if template == nil or not template:IsA('Frame') then
		return nil
	end
	local tName = template:FindFirstChild('Name')
	local tMoney = template:FindFirstChild('Money')
	local tRank = template:FindFirstChild('Rank')
	if
		tName == nil
		or not tName:IsA('TextLabel')
		or tMoney == nil
		or not tMoney:IsA('TextLabel')
		or tRank == nil
		or not tRank:IsA('TextLabel')
	then
		return nil
	end
	return {
		display = display,
		gui = gui,
		list = list,
		template = template,
		topRank = topRank,
		topName = topName,
		topMoney = topMoney,
		resetTime = resetTime,
	}
end

local function paintRow(row: Frame, rank: number, name: string, moneyText: string)
	local color = LeaderboardService.RankColor(rank)
	row.LayoutOrder = rank
	local rankLabel = row:FindFirstChild('Rank')
	local nameLabel = row:FindFirstChild('Name')
	local moneyLabel = row:FindFirstChild('Money')
	if rankLabel ~= nil and rankLabel:IsA('TextLabel') then
		rankLabel.Text = '#' .. tostring(rank)
		rankLabel.TextColor3 = color
	end
	if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
		nameLabel.Text = name
		nameLabel.TextColor3 = color
	end
	if moneyLabel ~= nil and moneyLabel:IsA('TextLabel') then
		moneyLabel.Text = moneyText
		moneyLabel.TextColor3 = color
	end
	row.Visible = true
end

local function renderBoard(entries: { { key: string, score: number } })
	local board = findBoard()
	if board == nil then
		local now = os.clock()
		if now - lastMissingWarnAt > 300 then
			lastMissingWarnAt = now
			warnLb('Display path Workspace.Map.LeaderBoard.Display not found; board render skipped', {})
		end
		return
	end
	-- The Template is a clone source only — never a row.
	pcall(function()
		board.template.Visible = false
	end)
	-- Reuse existing row clones in rank order.
	local rows: { Frame } = {}
	for _, child in ipairs(board.list:GetChildren()) do
		if child:IsA('Frame') and child ~= board.template and string.match(child.Name, '^Row%d+$') ~= nil then
			table.insert(rows, child)
		end
	end
	table.sort(rows, function(a: Frame, b: Frame)
		return a.LayoutOrder < b.LayoutOrder
	end)
	local shown = math.min(#entries, LeaderboardService.MAX_ENTRIES)
	for i = 1, shown do
		local entry = entries[i]
		local userId = tonumber(entry.key)
		local meta = lastMeta[entry.key]
		local moneyText = '0'
		local name = 'Unknown Player'
		if meta ~= nil then
			moneyText = LeaderboardService.FormatMoney(meta.m)
			name = resolveName(if type(userId) == 'number' then userId :: number else -1, meta.n)
		elseif type(userId) == 'number' then
			name = resolveName(userId, tostring(userId))
		else
			name = entry.key
		end
		local row = rows[i]
		if row == nil then
			local ok, clone = pcall(function()
				return board.template:Clone()
			end)
			if not ok or clone == nil then
				warnLb('Template clone failed', { rank = tostring(i) })
				break
			end
			row = clone :: Frame
			row.Name = 'Row' .. tostring(i)
			row.Parent = board.list
			table.insert(rows, row)
		end
		paintRow(row :: Frame, i, name, moneyText)
	end
	-- Hide pooled rows beyond this render (and any pool
	-- grown past MAX_ENTRIES by an older config).
	for i = shown + 1, #rows do
		pcall(function()
			rows[i].Visible = false
		end)
	end
	-- Top-player display mirrors entry #1, same ranking.
	if shown >= 1 then
		local first = entries[1]
		local meta = lastMeta[first.key]
		local topMoney = if meta ~= nil then LeaderboardService.FormatMoney(meta.m) else '0'
		local topName = 'Unknown Player'
		if meta ~= nil then
			local userId = tonumber(first.key)
			topName = resolveName(if type(userId) == 'number' then userId :: number else -1, meta.n)
		end
		pcall(function()
			board.topRank.Text = '#1'
			board.topRank.TextColor3 = LeaderboardService.RANK_COLORS.Gold
			board.topName.Text = topName
			board.topName.TextColor3 = LeaderboardService.RANK_COLORS.Gold
			board.topMoney.Text = topMoney
			board.topMoney.TextColor3 = LeaderboardService.RANK_COLORS.Gold
		end)
	else
		pcall(function()
			board.topRank.Text = '—'
			board.topName.Text = '—'
			board.topMoney.Text = '—'
		end)
	end
end

-- There is no destructive leaderboard reset anywhere in the
-- game, so ResetTime shows the countdown to the next board
-- refresh — a status value, never a wipe.
local function renderResetCountdown()
	local board = findBoard()
	if board == nil then
		return
	end
	local remain = math.max(0, math.ceil(nextRefreshAt - os.clock()))
	pcall(function()
		board.resetTime.Text = ('UPDATE IN %dS'):format(remain)
	end)
end

-- Global read: top entries descending. On failure the last
-- good render stays up and the retry happens next cycle.
function LeaderboardService.RefreshNow()
	if inCooldown() then
		return
	end
	local ordered, meta = getStores()
	if ordered == nil or meta == nil then
		return
	end
	local pages: DataStorePages? = nil
	local ok, err = pcall(function()
		pages = (ordered :: OrderedDataStore):GetSortedAsync(false, LeaderboardService.MAX_ENTRIES)
	end)
	if not ok or pages == nil then
		warnLb('GetSortedAsync failed; keeping previous board', { error = tostring(err) })
		noteFailure('GetSortedAsync')
		-- Re-assert the last good render anyway: the Display
		-- part may have streamed in since the last success.
		renderBoard(lastEntries)
		return
	end
	local entries: { { key: string, score: number } } = {}
	local pageOk, pageErr = pcall(function()
		for _, item in ipairs((pages :: DataStorePages):GetCurrentPage()) do
			if type(item) == 'table' then
				local key: any = (item :: any).key
				local value: any = (item :: any).value
				if type(key) == 'string' and type(value) == 'number' then
					table.insert(entries, { key = key :: string, score = value :: number })
				end
			end
		end
	end)
	if not pageOk then
		warnLb('GetCurrentPage failed; keeping previous board', { error = tostring(pageErr) })
		noteFailure('GetCurrentPage')
		renderBoard(lastEntries)
		return
	end
	-- Exact fortunes for the displayed page (bounded reads:
	-- at most MAX_ENTRIES per refresh).
	if meta ~= nil then
		for _, entry in ipairs(entries) do
			if lastMeta[entry.key] == nil then
				local mok, mval = pcall(function()
					return (meta :: GlobalDataStore):GetAsync(entry.key)
				end)
				if mok and type(mval) == 'table' then
					local m = (mval :: any).m
					local n = (mval :: any).n
					if type(m) == 'string' then
						lastMeta[entry.key] = {
							m = m,
							n = if type(n) == 'string' then n else '',
						}
					end
				end
			end
			local userId = tonumber(entry.key)
			if type(userId) == 'number' then
				local player = Players:GetPlayerByUserId(userId)
				if player ~= nil then
					nameCache[userId] = displayNameOf(player)
				end
			end
		end
	end
	lastEntries = entries
	lastRefreshAt = os.clock()
	noteSuccess()
	renderBoard(entries)
	renderResetCountdown()
end

-- --- Loops ---------------------------------------------------------------

function LeaderboardService.Start()
	if started then
		return
	end
	started = true
	if RunService:IsClient() then
		return
	end
	nextRefreshAt = os.clock() + 5
	lastRefreshAt = 0
	-- Maintenance: scan (enqueue changed) -> flush (capped
	-- writes) -> refresh (one global read per minute).
	task.spawn(function()
		task.wait(5)
		local lastScanAt = 0
		while true do
			local now = os.clock()
			local ok, err = pcall(function()
				if now - lastScanAt >= LeaderboardService.SCAN_SECONDS then
					lastScanAt = now
					scanServer()
				end
				flushDirty()
				if now >= nextRefreshAt then
					nextRefreshAt = now + LeaderboardService.REFRESH_SECONDS
					LeaderboardService.RefreshNow()
				end
			end)
			if not ok then
				warnLb('maintenance tick failed', { error = tostring(err) })
			end
			task.wait(LeaderboardService.FLUSH_SECONDS)
		end
	end)
	-- 1 Hz ResetTime countdown (label-only, no DataStore).
	task.spawn(function()
		while true do
			local ok, err = pcall(renderResetCountdown)
			if not ok then
				warnLb('reset countdown failed', { error = tostring(err) })
			end
			task.wait(1)
		end
	end)
	-- Best-effort final flush on shutdown (no retries — the
	-- close window is short; next session's scan heals gaps).
	pcall(function()
		game:BindToClose(function()
			for _, player in ipairs(Players:GetPlayers()) do
				local userId = player.UserId
				if isBoardEligible(userId) then
					local snap = snapshotPlayer(userId)
					if snap ~= nil and lastWritten[userId] ~= snap.score then
						pcall(writeSnapshot, userId, snap)
					end
				end
			end
		end)
	end)
	logLb('started')
end

function LeaderboardService.ForgetPlayer(userId: number)
	dirty[userId] = nil
	lastWritten[userId] = nil
end

function LeaderboardService._TestReset()
	orderedStore = nil
	metaStore = nil
	storesReady = false
	lastWritten = {}
	dirty = {}
	nameCache = {}
	lastMeta = {}
	lastEntries = {}
	lastRefreshAt = 0
	nextRefreshAt = 0
	consecutiveFailures = 0
	cooldownUntil = 0
end

return LeaderboardService
