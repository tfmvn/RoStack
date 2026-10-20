--!strict
--!native
--[[
	TabList.TabListService
	======================
	TAB (player-list) leaderboard via NATIVE Roblox leaderstats.

	There is deliberately NO custom UI here (no ScreenGui, no
	frames, no scrolling list) and NO feed remote: the server
	maintains `player.leaderstats` and Roblox's native CoreGui
	PlayerList (kept enabled in bootstrap.client) renders and
	sorts it. Pressing TAB shows the normal Roblox player list.

	This is a SEPARATE system from the global physical board
	(LeaderboardService), with its own ranking and NO shared
	ranking values:

	  TAB (native):  Rebirths first, Money second
	  GLOBAL board:  money ONLY (see LeaderboardService)

	Visible stats (exactly these two, in this order):
	  1. Rebirths (IntValue, FIRST child = the native primary
	     sort key, so the list ranks rebirths-first)
	  2. Money (StringValue, game-formatted text like "1.0Qa" —
	     a numeric stat cannot hold BigNumber fortunes, and a
	     raw integer would display unreadably huge)

	No derived/ugly ranking stat is exposed: the native list
	sorts by the Rebirths stat; the Money column is display.
	All values come from server-side profile reads
	(EconomyService/RebirthService) on a short cadence — the
	client submits nothing, and replication dedupes unchanged
	values. Folders die with the player; nothing persists.
]]

local Players = game:GetService('Players')
local RunService = game:GetService('RunService')

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
-- Display formatting reuse (leaf module — cycle-free).
local LeaderboardService = require(ServerScriptService.Leaderboard.LeaderboardService)

local TabListService = {}

-- leaderstats refresh cadence (cheap live reads + engine-
-- deduped replication; in-server players only).
TabListService.PUSH_SECONDS = 15
-- Minimum gap between join/leave/dirty-triggered refreshes.
TabListService.EARLY_PUSH_COOLDOWN = 5

TabListService.FOLDER_NAME = 'leaderstats'
TabListService.REBIRTHS_STAT = 'Rebirths'
TabListService.MONEY_STAT = 'Money'

-- --- Wiring (late-bound, cycle-free) ---------------------------------

local playerServiceRef: any = nil
local economyServiceRef: any = nil
local rebirthServiceRef: any = nil

function TabListService.SetPlayerService(svc: any)
	playerServiceRef = svc
end

function TabListService.SetEconomyService(svc: any)
	economyServiceRef = svc
end

function TabListService.SetRebirthService(svc: any)
	rebirthServiceRef = svc
end

-- --- leaderstats ---------------------------------------------------------

-- Ensure `host.leaderstats` exists with exactly the two
-- visible stats IN ORDER (Rebirths first = native primary
-- sort key, Money second). Repairs wrong-typed leftovers by
-- rebuilding. Returns the folder, or nil when host is unusable.
-- Never throws.
function TabListService.EnsureLeaderstats(host: Instance): Folder?
	local folder: Folder? = nil
	pcall(function()
		if typeof(host) ~= 'Instance' then
			return
		end
		local existing = (host :: Instance):FindFirstChild(TabListService.FOLDER_NAME)
		if existing ~= nil and existing:IsA('Folder') then
			folder = existing
		else
			if existing ~= nil then
				pcall(function()
					(existing :: Instance):Destroy()
				end)
			end
			local made = Instance.new('Folder')
			made.Name = TabListService.FOLDER_NAME
			made.Parent = host
			folder = made
		end
		local live = folder :: Folder
		local rebirths = live:FindFirstChild(TabListService.REBIRTHS_STAT)
		if rebirths == nil or not rebirths:IsA('IntValue') then
			if rebirths ~= nil then
				pcall(function()
					(rebirths :: Instance):Destroy()
				end)
			end
			-- Parent FIRST: creation order is the native
			-- column/sort order (Rebirths primary).
			local stat = Instance.new('IntValue')
			stat.Name = TabListService.REBIRTHS_STAT
			stat.Value = 0
			stat.Parent = live
		end
		local money = live:FindFirstChild(TabListService.MONEY_STAT)
		if money == nil or not money:IsA('StringValue') then
			if money ~= nil then
				pcall(function()
					(money :: Instance):Destroy()
				end)
			end
			local stat = Instance.new('StringValue')
			stat.Name = TabListService.MONEY_STAT
			stat.Value = '0'
			stat.Parent = live
		end
	end)
	return folder
end

-- Refresh one player's visible stats from authoritative
-- profile data. Skips (never zeroes) when the profile is
-- unloaded or services are unwired. Never throws. Returns
-- true when values were written.
function TabListService.RefreshValues(host: Instance, userId: number): boolean
	local wrote = false
	pcall(function()
		if typeof(host) ~= 'Instance' then
			return
		end
		if playerServiceRef == nil or economyServiceRef == nil or rebirthServiceRef == nil then
			return
		end
		local profileOk = false
		pcall(function()
			profileOk = playerServiceRef.GetPlayerData(userId) ~= nil
		end)
		if not profileOk then
			return
		end
		local money: string? = nil
		pcall(function()
			local m = economyServiceRef.GetMoney(userId)
			if type(m) == 'string' then
				money = BigNumber.sanitize(m) or '0'
			end
		end)
		local rebirths: number? = nil
		pcall(function()
			local r = rebirthServiceRef.GetRebirth(userId)
			if type(r) == 'number' then
				rebirths = math.floor(r)
			end
		end)
		if money == nil or rebirths == nil then
			return
		end
		local folder = TabListService.EnsureLeaderstats(host)
		if folder == nil then
			return
		end
		local rebirthsStat = (folder :: Folder):FindFirstChild(TabListService.REBIRTHS_STAT)
		if rebirthsStat ~= nil and rebirthsStat:IsA('IntValue') then
			(rebirthsStat :: IntValue).Value = rebirths :: number
			wrote = true
		end
		local moneyStat = (folder :: Folder):FindFirstChild(TabListService.MONEY_STAT)
		if moneyStat ~= nil and moneyStat:IsA('StringValue') then
			(moneyStat :: StringValue).Value = LeaderboardService.FormatMoney(money)
			wrote = true
		end
	end)
	return wrote
end

-- --- Feed ---------------------------------------------------------------

local started = false
local lastPushAt = 0
local dirty = false

local function refreshAll()
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(TabListService.RefreshValues, player, player.UserId)
	end
	lastPushAt = os.clock()
	dirty = false
end

-- Expedite the next refresh (rebirth commits, joins,
-- leaves). Throttled: presence churn can never spam work.
function TabListService.MarkDirty()
	dirty = true
end

function TabListService.RequestRefresh()
	if not started then
		return
	end
	if os.clock() - lastPushAt < TabListService.EARLY_PUSH_COOLDOWN then
		dirty = true
		return
	end
	task.spawn(function()
		pcall(refreshAll)
	end)
end

function TabListService.Start()
	if started then
		return
	end
	started = true
	if RunService:IsClient() then
		return
	end
	task.spawn(function()
		task.wait(3)
		while true do
			local ok, err = pcall(function()
				local now = os.clock()
				if dirty or now - lastPushAt >= TabListService.PUSH_SECONDS then
					refreshAll()
				end
			end)
			if not ok then
				pcall(Debug.Warn, 'TAB', 'refresh tick failed', { error = tostring(err) })
			end
			task.wait(TabListService.EARLY_PUSH_COOLDOWN)
		end
	end)
	pcall(Debug.Log, 'TAB', 'started (native leaderstats)', {})
end

return TabListService
