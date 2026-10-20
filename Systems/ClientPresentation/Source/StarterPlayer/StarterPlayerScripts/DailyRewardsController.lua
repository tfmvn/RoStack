--!strict
--!native
--[[
	DailyRewardsController
	======================
	Client owner of the authored `PlayerGui.Main.DailyRewards`
	CONTENT (day cards, status text). Open/close ownership lives
	in DailyTopbar.client.lua (the fast-boot TopbarPlus icon) —
	this controller never shows or hides the panel.

	Server-authoritative: the server decides the day, the
	eligibility, and the rewards (DailyRewardsState snapshot);
	the client renders text/overlays from that snapshot and
	sends ONLY intent (DailyRewardsAction { Action = 'State' |
	'Claim' }). A clicked card Day is never authority — the
	server computes the claimable day itself.

	Immediate binding: resolves the authored panel without
	waiting on profile, base, animals, arena, or server data
	(same fast pattern as the Settings/Codes fix). Reward data
	arrives asynchronously afterwards via DailyRewardsState.
	Countdown text derives from the server-supplied
	NextClaimAt anchor (display only; eligibility stays
	server-side) and refreshes locally while the panel is
	visible — no remote polling.

	Existing elements only (never built here): Items1 day
	buttons 1..6, the Items2 featured card (last day),
	LockedOverlay per card, Name/Day labels, Text status
	label. ViewportFrame/Image/gradients are left exactly as
	authored. Skip is the PAID Skip All: it prompts the Shop
	SkipDaily Developer Product (Marketplace dialog); the
	server receipt grants access and claims. The button never
	grants anything itself.
]]

local Players = game:GetService('Players')
local MarketplaceService = game:GetService('MarketplaceService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local NotificationConfig = require(ReplicatedStorage.Config.Presentation.UI).Notify
local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)

local DailyRewardsController = {}

local localPlayer = Players.LocalPlayer

local function logDaily(message: string)
	Debug.Log('DailyRewards', message)
end

local function warnDaily(message: string)
	Debug.Warn('DailyRewards', message)
end

local wired = false
local actionRemote: RemoteEvent? = nil

local dailyGui: GuiObject? = nil
local statusText: TextLabel? = nil
local countdownThread: thread? = nil

type Card = {
	button: GuiButton,
	day: number,
	dayLabel: TextLabel?,
	nameLabel: TextLabel?,
	overlay: GuiObject?,
}

local cards: { Card } = {}
local inFlight = false
local lastSnapshot: any = nil
-- The open-hook (Visible -> request state) connects once the
-- panel exists; late creation is caught via Main.ChildAdded.
local openHooked = false
-- Out-of-order guard (§24): WeekIds sort chronologically
-- (zero-padded W%06d); LastClaimAt is monotonic per week. A
-- stale response never rolls the UI backwards.
local lastSnapWeekId: string? = nil
local lastSnapVersion: number? = nil
-- Countdown-expiry pull anchor (§12-13): pull fresh state once
-- per passed anchor (presentation only — never grants).
local expiryPulledFor: number? = nil

local CLAIM_BACKSTOP_S = 5

-- Day-label state colors (§20-22): Claim = white, Claimed =
-- the game's success green (NotificationConfig Reward
-- category). Locked keeps its authored color (untouched).
local CLAIM_WHITE = Color3.fromRGB(255, 255, 255)
local CLAIMED_GREEN = Color3.fromRGB(120, 230, 140)

pcall(function()
	local category = (NotificationConfig :: any).CategoryColor
	if type(category) == 'table' and typeof(category.Reward) == 'Color3' then
		CLAIMED_GREEN = category.Reward
	end
end)

local function playerGui(): PlayerGui?
	local ok, gui = pcall(function()
		if localPlayer == nil then
			return nil
		end
		return localPlayer:FindFirstChildOfClass('PlayerGui')
	end)
	if ok and gui ~= nil then
		return gui
	end
	return nil
end

local function textOf(node: Instance?, childName: string): TextLabel?
	if node == nil then
		return nil
	end
	local found: Instance? = nil
	pcall(function()
		found = (node :: Instance):FindFirstChild(childName)
	end)
	if found ~= nil and (found :: Instance):IsA('TextLabel') then
		return found :: TextLabel
	end
	return nil
end

local function overlayOf(node: Instance?): GuiObject?
	if node == nil then
		return nil
	end
	local found: Instance? = nil
	pcall(function()
		found = (node :: Instance):FindFirstChild('LockedOverlay')
	end)
	if found ~= nil and (found :: Instance):IsA('GuiObject') then
		return found :: GuiObject
	end
	return nil
end

local function setOverlay(card: Card, visible: boolean)
	pcall(function()
		if card.overlay ~= nil then
			(card.overlay :: GuiObject).Visible = visible
		end
	end)
end

-- Ordered day cards: Items1 buttons sorted by name (days
-- 1..6), then the Items2 featured button (last day). Extra
-- config days beyond the authored cards reuse the last card;
-- missing cards hide (never error).
local function ensureCards(): boolean
	if dailyGui ~= nil and (dailyGui :: GuiObject).Parent ~= nil and #cards > 0 then
		return true
	end
	cards = {}
	statusText = nil
	pcall(function()
		local gui = playerGui()
		local main = gui and gui:FindFirstChild('Main') or nil
		local root = main and (main :: Instance):FindFirstChild('DailyRewards') or nil
		if root == nil or not (root :: Instance):IsA('GuiObject') then
			return
		end
		dailyGui = root :: GuiObject
		statusText = textOf(root, 'Text')
		local items1 = (root :: Instance):FindFirstChild('Items1')
		local ordered: { GuiButton } = {}
		if items1 ~= nil then
			local named: { { order: number, button: GuiButton } } = {}
			for _, child in ipairs((items1 :: Instance):GetChildren()) do
				if (child :: Instance):IsA('GuiButton') then
					local n = tonumber((child :: Instance).Name) or 1e9
					named[#named + 1] = { order = n, button = child :: GuiButton }
				end
			end
			table.sort(named, function(a, b)
				return a.order < b.order
			end)
			for _, entry in ipairs(named) do
				ordered[#ordered + 1] = entry.button
			end
		end
		local items2 = (root :: Instance):FindFirstChild('Items2')
		if items2 ~= nil then
			local featured = (items2 :: Instance):FindFirstChildWhichIsA('GuiButton', true)
			if featured ~= nil then
				ordered[#ordered + 1] = featured
			end
		end
		for index, button in ipairs(ordered) do
			cards[#cards + 1] = {
				button = button,
				day = index,
				dayLabel = textOf(button, 'Day'),
				nameLabel = textOf(button, 'Name'),
				overlay = overlayOf(button),
			}
		end
	end)
	return #cards > 0
end

local function rewardText(dayEntry: any): string
	if type(dayEntry) ~= 'table' then
		return 'Reward'
	end
	local parts: { string } = {}
	if type(dayEntry.Cash) == 'string' and dayEntry.Cash ~= '' then
		local formatted: string? = nil
		pcall(function()
			formatted = BigNumber.Format(dayEntry.Cash)
		end)
		if type(formatted) == 'string' and formatted ~= '' then
			parts[#parts + 1] = '+$' .. (formatted :: string)
		else
			parts[#parts + 1] = '+$' .. tostring(dayEntry.Cash)
		end
	end
	if type(dayEntry.Eggs) == 'table' then
		for _, egg in ipairs(dayEntry.Eggs) do
			if type(egg) == 'table' and type(egg.Rarity) == 'string' then
				parts[#parts + 1] = ('+1 %s Egg'):format(egg.Rarity)
			end
		end
	end
	if type(dayEntry.Tools) == 'table' then
		for _, tool in ipairs(dayEntry.Tools) do
			if type(tool) == 'table' then
				local name = if type(tool.Name) == 'string' then tool.Name else tostring(tool.Id)
				parts[#parts + 1] = '+' .. name
			end
		end
	end
	if type(dayEntry.Animals) == 'table' then
		for _, animal in ipairs(dayEntry.Animals) do
			if type(animal) == 'table' then
				local name = if type(animal.Name) == 'string' then animal.Name else tostring(animal.DefId)
				parts[#parts + 1] = '+' .. name
			end
		end
	end
	if #parts < 1 then
		return 'Reward'
	end
	return table.concat(parts, ', ')
end

local function formatCountdown(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	return ('%02d:%02d:%02d'):format(h, m, sec)
end

local function requestState()
	if actionRemote == nil then
		return
	end
	local remote = actionRemote
	pcall(function()
		(remote :: RemoteEvent):FireServer({ Action = 'State' })
	end)
end

local function paintStatus()
	if statusText == nil or lastSnapshot == nil then
		return
	end
	pcall(function()
		local box = statusText :: TextLabel
		if lastSnapshot.CanClaim == true then
			box.Text = 'Claim available!'
		else
			local nextAt = tonumber(lastSnapshot.NextClaimAt) or 0
			if nextAt > 0 then
				box.Text = 'Next reward in ' .. formatCountdown(nextAt - os.time())
			else
				box.Text = 'Come back tomorrow!'
			end
		end
	end)
end

local function stopCountdown()
	if countdownThread ~= nil then
		pcall(task.cancel, countdownThread)
		countdownThread = nil
	end
end

local function startCountdown()
	stopCountdown()
	countdownThread = task.spawn(function()
		while true do
			if dailyGui == nil or not (dailyGui :: GuiObject).Visible then
				return
			end
			paintStatus()
			-- Timer expiry (§12-13): the countdown is
			-- presentation only. When the server-supplied
			-- anchor passes, pull fresh authoritative state
			-- ONCE per anchor (the server decides
			-- eligibility; this never grants or mutates).
			-- The fresh snapshot carries a new anchor.
			if lastSnapshot ~= nil then
				local nextAt = tonumber(lastSnapshot.NextClaimAt) or 0
				if nextAt > 0 and os.time() >= nextAt and expiryPulledFor ~= nextAt then
					expiryPulledFor = nextAt
					requestState()
				end
			end
			task.wait(1)
		end
	end)
end

-- Pure render from the authoritative snapshot (§33-34):
-- safe to call repeatedly; fresh state always produces the
-- correct UI. Card Day label carries the state text on the
-- EXISTING label: 'Claim' (white) / 'Claimed' (green) /
-- 'Locked' (authored color). Every rendered card stays
-- clickable: claimed/future clicks reach the server, which
-- rejects them with the existing warning notification + SFX
-- (never silent, never trusted client-side).
local function renderState(snapshot: any)
	if type(snapshot) ~= 'table' or #cards < 1 then
		return
	end
	local dayCount = tonumber(snapshot.DayCount) or 0
	local days = snapshot.Days
	for _, card in ipairs(cards) do
		local day = card.day
		if day > dayCount then
			pcall(function()
				(card.button :: GuiButton).Visible = false
			end)
			continue
		end
		pcall(function()
			(card.button :: GuiButton).Visible = true
		end)
		local dayEntry = if type(days) == 'table' then days[day] else nil
		local text = rewardText(dayEntry)
		local state = if type(dayEntry) == 'table' and type(dayEntry.State) == 'string'
			then dayEntry.State
			else 'Locked'
		pcall(function()
			local btn = card.button :: GuiButton
			if card.nameLabel ~= nil then
				-- Name carries the reward only; claim state
				-- lives on the Day label (never blank authored
				-- text on cards without labels).
				(card.nameLabel :: TextLabel).Text = text
			end
			if card.dayLabel ~= nil then
				local label = card.dayLabel :: TextLabel
				if state == 'Claimable' then
					label.Text = 'Claim'
					label.TextColor3 = CLAIM_WHITE
				elseif state == 'Claimed' then
					label.Text = 'Claimed'
					label.TextColor3 = CLAIMED_GREEN
				else
					label.Text = 'Locked'
				end
			end
			setOverlay(card, state ~= 'Claimable')
			btn.Active = true
			btn.AutoButtonColor = true
		end)
	end
end

local function onClaimClicked(day: number)
	if inFlight then
		return
	end
	if actionRemote == nil then
		warnDaily('DailyRewardsAction remote missing; cannot claim')
		return
	end
	inFlight = true
	logDaily('claim clicked')
	local remote = actionRemote
	pcall(function()
		(remote :: RemoteEvent):FireServer({ Action = 'Claim', Day = day })
	end)
	renderState(lastSnapshot)
	task.delay(CLAIM_BACKSTOP_S, function()
		if inFlight then
			inFlight = false
			renderState(lastSnapshot)
		end
	end)
end

local function onSkipClicked()
	-- Paid Skip All: prompt the Shop SkipDaily Developer
	-- Product. No remote fires here — the server receipt is
	-- the ONLY grant path (it sets entitlement, then runs
	-- the identical gated ClaimAll). ProductId comes from
	-- ShopConfig, never hardcoded.
	local player = localPlayer or Players.LocalPlayer
	if player == nil then
		warnDaily('skip ignored (no LocalPlayer)')
		return
	end
	local productId: number? = nil
	pcall(function()
		local entry = ShopConfig.DeveloperProducts.SkipDaily
		if type(entry) == 'table' and type(entry.ProductId) == 'number' then
			productId = entry.ProductId
		end
	end)
	if productId == nil then
		warnDaily('SkipDaily product missing from ShopConfig; cannot skip')
		return
	end
	logDaily(('skip clicked productId=%s'):format(tostring(productId)))
	local promptOk, promptErr = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId :: number)
	end)
	logDaily(('skip prompt ok=%s err=%s'):format(tostring(promptOk), tostring(promptErr)))
	-- Funnel prompt-intent ping (analytics ONLY) on the
	-- existing ShopAction remote; the receipt stays the sole
	-- grant path.
	if promptOk then
		pcall(function()
			local folder = Remotes.WaitForReady()
			if folder == nil then
				return
			end
			local remote = (folder :: Instance):FindFirstChild(Remotes.Names.ShopAction)
			if remote ~= nil and (remote :: Instance):IsA('RemoteEvent') then
				((remote :: Instance) :: RemoteEvent):FireServer({ Action = 'FunnelPrompt', ProductId = productId })
			end
		end)
	end
end

local function wireCards()
	for _, card in ipairs(cards) do
		local day = card.day
		local button = card.button
		pcall(function()
			(button :: GuiButton).Activated:Connect(function()
				-- Every card submits; the server recomputes
				-- eligibility and rejects claimed/future
				-- clicks with a warning (never silent).
				onClaimClicked(day)
			end)
		end)
	end
	-- Skip button (paid Skip All): prompts the Shop SkipDaily
	-- product purchase (see onSkipClicked). The server receipt
	-- grants entitlement + claims; the button itself grants
	-- nothing. Connected once (attribute guard survives
	-- re-wire); a missing Studio Skip button simply means no
	-- affordance.
	pcall(function()
		if dailyGui == nil then
			return
		end
		local skip = (dailyGui :: GuiObject):FindFirstChild('Skip', true)
		if
			skip ~= nil
			and (skip :: Instance):IsA('GuiButton')
			and (skip :: GuiButton):GetAttribute('ShopSkipWired') ~= true
		then
			-- SetAttribute returns void: the trailing semicolon
			-- is REQUIRED, otherwise Lua parses the next line
			-- as a call on its result (the original crash).
			(skip :: GuiButton):SetAttribute('ShopSkipWired', true);
			((skip :: Instance) :: GuiButton).Activated:Connect(function()
				onSkipClicked()
			end)
		end
	end)
end

-- Accept a server snapshot unless it is strictly older
-- than what is already rendered (§24). Equal versions
-- (re-requests) always apply.
local function acceptSnapshot(payload: any): boolean
	if type(payload) ~= 'table' then
		return false
	end
	local weekId = payload.WeekId
	local version = tonumber(payload.LastClaimAt) or 0
	if type(weekId) == 'string' and lastSnapWeekId ~= nil then
		if weekId < (lastSnapWeekId :: string) then
			return false
		end
		if weekId == lastSnapWeekId and lastSnapVersion ~= nil and version < (lastSnapVersion :: number) then
			return false
		end
	end
	if type(weekId) == 'string' then
		lastSnapWeekId = weekId
	end
	lastSnapVersion = version
	lastSnapshot = payload
	return true
end

-- Neutral loading paint (§38): Day labels show '...' (never
-- a fake Claimed) until the first authoritative snapshot
-- lands and renderState replaces it.
local function paintLoading()
	if lastSnapshot ~= nil then
		return
	end
	for _, card in ipairs(cards) do
		pcall(function()
			if card.dayLabel ~= nil then
				local label = card.dayLabel :: TextLabel
				label.Text = '...'
			end
			setOverlay(card, true)
		end)
	end
	if statusText ~= nil then
		local box = statusText
		pcall(function()
			(box :: TextLabel).Text = 'Loading...'
		end)
	end
end

local topbarModule: any = nil
local noticeOn = false
local noticeClearEvent: BindableEvent? = nil

local function dailyIcon(): any
	if topbarModule == nil then
		pcall(function()
			local packages = ReplicatedStorage:FindFirstChild('Packages')
			local mod = packages and (packages :: Instance):FindFirstChild('TopbarPlus') or nil
			if mod ~= nil then
				topbarModule = require(mod)
			end
		end)
	end
	if topbarModule == nil then
		return nil
	end
	local icon: any = nil
	pcall(function()
		icon = topbarModule.getIcon('DailyRewards')
	end)
	return icon
end

-- TopbarPlus alert, derived from the SAME authoritative
-- snapshot as the cards (§6/§32). Shows iff ≥1 day reads
-- State == 'Claimable' — never for claimed/locked/future,
-- never before the first snapshot (starts OFF, §10), never
-- from UI text (§26) or a drifting boolean (§27).
--
-- Verified API (TopbarPlus v3.4.0 init.lua:707-724): a bare
-- icon:notify() defaults to clearing on icon DESELECT, which
-- would drop the alert on panel close while the reward is
-- still claimable — so we pass a private never-fired signal
-- and clear ONLY via clearNotices() on authoritative
-- no-Claimable. Repeated notify() calls STACK badge counts
-- (Notice.lua totalNotices), so notify fires exactly once per
-- OFF→ON transition, tracked by noticeOn.
local function updateTopbarNotification(snapshot: any)
	if type(snapshot) ~= 'table' or type(snapshot.Days) ~= 'table' then
		return
	end
	local claimable = 0
	local claimDay: any = nil
	for _, entry in ipairs(snapshot.Days) do
		if type(entry) == 'table' and entry.State == 'Claimable' then
			claimable += 1
			claimDay = entry.Day
		end
	end
	if claimable > 1 then
		warnDaily('multiple claimable days detected')
	end
	local icon = dailyIcon()
	if icon == nil then
		-- Topbar icon not bound yet (binding is independent
		-- and instant); the next state update retries —
		-- state re-arrives on every open, claim, and weekly
		-- push, so no timer or poll is needed.
		logDaily('topbar icon not bound yet; notification deferred')
		return
	end
	if claimable >= 1 then
		if not noticeOn then
			noticeOn = true
			if noticeClearEvent == nil then
				pcall(function()
					noticeClearEvent = Instance.new('BindableEvent')
				end)
			end
			local evt = noticeClearEvent
			pcall(function()
				if evt ~= nil then
					(icon :: any):notify((evt :: BindableEvent).Event)
				else
					(icon :: any):notify()
				end
			end)
			logDaily(('topbar notification ON reason=Claimable day=%s'):format(tostring(claimDay)))
		end
	elseif noticeOn then
		noticeOn = false
		pcall(function()
			(icon :: any):clearNotices()
		end)
		logDaily('topbar notification OFF reason=NoClaimableReward')
	end
end

local function onState(payload: any)
	if not acceptSnapshot(payload) then
		logDaily('stale state ignored')
		return
	end
	-- Self-healing render: cards may have replicated after
	-- the last resolve attempt (first-open path).
	if #cards < 1 then
		pcall(function()
			if ensureCards() then
				wireCards()
			end
		end)
	end
	renderState(lastSnapshot)
	paintStatus()
	updateTopbarNotification(lastSnapshot)
	if dailyGui ~= nil and (dailyGui :: GuiObject).Visible then
		startCountdown()
	end
	logDaily('state received')
end

local function onResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	inFlight = false
	-- Failed claims change nothing (§28): keep the existing
	-- authoritative render. Successful claims carry the
	-- COMPLETE fresh state (§27): render it directly so the
	-- result can neither race nor wait for the state push.
	if (payload :: any).Success == true then
		if type((payload :: any).State) == 'table' then
			if acceptSnapshot((payload :: any).State) then
				renderState(lastSnapshot)
				paintStatus()
				updateTopbarNotification(lastSnapshot)
			end
		else
			renderState(lastSnapshot)
		end
		logDaily(('claimed day=%s'):format(tostring((payload :: any).Day)))
	else
		logDaily(('claim failed reason=%s'):format(tostring((payload :: any).Reason)))
	end
	-- The server pushes a fresh DailyRewardsState after every
	-- claim; onState repaints authoritatively.
end

function DailyRewardsController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnDaily('no LocalPlayer; controller disabled')
		return
	end
	-- Immediate, independent binding: resolve the authored
	-- panel without waiting on remotes or server data.
	pcall(function()
		if ensureCards() then
			wireCards()
			logDaily('UI ready')
		end
		paintLoading()
	end)
	-- Re-resolve + refresh state on every open: late content
	-- and fresh eligibility land the moment the player looks.
	-- bindOpen is idempotent; Main.ChildAdded catches panels
	-- that replicate after Init runs (event-driven — no
	-- polling, no arbitrary timeout beyond the bounded waits).
	local function bindOpen()
		if openHooked then
			return
		end
		if dailyGui == nil or (dailyGui :: GuiObject).Parent == nil then
			return
		end
		openHooked = true
		pcall(function()
			(dailyGui :: GuiObject):GetPropertyChangedSignal('Visible'):Connect(function()
				if (dailyGui :: GuiObject).Visible then
					pcall(function()
						if ensureCards() then
							wireCards()
						end
					end)
					-- Fresh authoritative state on EVERY open:
					-- render latest known immediately (onState
					-- already stored it; neutral loading paint
					-- when nothing arrived yet) and pull
					-- current truth; the response replaces the
					-- cache via renderState.
					if lastSnapshot ~= nil then
						renderState(lastSnapshot)
					else
						paintLoading()
					end
					requestState()
					startCountdown()
				else
					stopCountdown()
				end
			end)
		end)
	end
	pcall(function()
		bindOpen()
		local gui = playerGui()
		local main = gui and gui:FindFirstChild('Main') or nil
		if main ~= nil then
			(main :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name == 'DailyRewards' then
					pcall(function()
						if ensureCards() then
							wireCards()
						end
						paintLoading()
						bindOpen()
					end)
				end
			end)
		end
	end)
	-- Eager single-shot retry on OUR panel only.
	task.spawn(function()
		pcall(function()
			local gui = playerGui()
			if gui == nil then
				return
			end
			local main = gui:WaitForChild('Main', 5)
			if main == nil then
				return
			end
			if (main :: Instance):WaitForChild('DailyRewards', 5) == nil then
				return
			end
			if ensureCards() then
				wireCards()
				logDaily('eager UI ready')
			end
			paintLoading()
			bindOpen()
			-- If a snapshot already landed (Init requests
			-- state regardless of UI presence), paint it now
			-- so first open is never stale.
			renderState(lastSnapshot)
		end)
	end)
	local folder = Remotes.WaitForReady()
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.DailyRewardsAction, 10)
	end)
	if okAction and actionEvent ~= nil and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent :: RemoteEvent
	else
		warnDaily('DailyRewardsAction remote missing; state/claim disabled')
	end
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.DailyRewardsState, 10)
	end)
	if okState and stateEvent ~= nil and (stateEvent :: Instance):IsA('RemoteEvent') then
		(stateEvent :: RemoteEvent).OnClientEvent:Connect(onState)
	else
		warnDaily('DailyRewardsState remote missing; cards stay empty')
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.DailyRewardsResult, 10)
	end)
	if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
		(resultEvent :: RemoteEvent).OnClientEvent:Connect(onResult)
	else
		warnDaily('DailyRewardsResult remote missing; claim feedback disabled')
	end
	-- Asynchronous content init (never blocks the binding
	-- above): pull the authoritative snapshot once remotes
	-- exist. Re-pulled on every open.
	requestState()
	logDaily('controller ready')
end

return table.freeze(DailyRewardsController)
