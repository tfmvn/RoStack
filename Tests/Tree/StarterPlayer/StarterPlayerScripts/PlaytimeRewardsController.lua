--!strict
--!native
--[[
	PlaytimeRewardsController
	=========================
	Client owner of the authored `PlayerGui.Main.PlayTimeRewards`
	CONTENT (milestone cards, status text). Open/close ownership
	lives in PlaytimeTopbar.client.lua (the fast-boot TopbarPlus
	icon) — this controller never shows or hides the panel.

	Server-authoritative: the server decides pool, playtime,
	eligibility, and rewards (PlaytimeRewardsState snapshot);
	the client renders text/overlays from that snapshot and
	sends ONLY intent (PlaytimeRewardsAction { Action = 'State'
	| 'Claim', Index }). A clicked card index is never
	authority — the server recomputes everything from its
	session clock.

	Immediate binding: resolves the authored panel without
	waiting on profile, base, animals, arena, or server data
	(same fast pattern as Settings/Codes/Daily). Reward state
	arrives asynchronously afterwards. Countdown text derives
	from the snapshot (CurrentPlaytime + local tick) and
	refreshes locally while visible — presentation only, the
	server decides Claimable. No Heartbeat state polling: the
	server pushes at threshold crossings (single-shot delays).

	Existing elements only (never built here): Items day
	buttons 1..6, per-card Timer/Text state label, Text status
	label. ViewportFrame/Image/gradients are left exactly as
	authored. Skip is the PAID Skip All: it prompts the Shop
	SkipPlaytime Developer Product (Marketplace dialog); the
	server receipt grants access and claims. The button never
	grants anything itself.
]]

local Players = game:GetService('Players')
local MarketplaceService = game:GetService('MarketplaceService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local NotificationConfig = require(ReplicatedStorage.Config.Presentation.UI).Notify
local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)

local PlaytimeRewardsController = {}

local localPlayer = Players.LocalPlayer

local function logPlaytime(message: string)
	Debug.Log('PlaytimeRewards', message)
end

local function warnPlaytime(message: string)
	Debug.Warn('PlaytimeRewards', message)
end

local wired = false
local actionRemote: RemoteEvent? = nil

local playtimeGui: GuiObject? = nil
local statusText: TextLabel? = nil
local countdownThread: thread? = nil

type Card = {
	button: GuiButton,
	index: number,
	timerText: TextLabel?,
}

local cards: { Card } = {}
local inFlight = false
local lastSnapshot: any = nil
-- The open-hook connects once the panel exists; late creation
-- is caught via Main.ChildAdded.
local openHooked = false
-- Out-of-order guard: Version is the server build tick (ms),
-- monotonic per server. A stale response never rolls the UI
-- backwards.
local lastVersion: number? = nil
-- Threshold-crossing pull anchor: pull fresh state once per
-- passed threshold while visible (server decides Claimable).
local expiryPulledFor: number? = nil

local CLAIM_BACKSTOP_S = 5

-- Timer state colors (§12/47): Claim = white, Claimed = the
-- game's success green (NotificationConfig Reward category).
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

-- State label resolution: the authored Timer/Text element;
-- falls back to the first descendant TextLabel (never built
-- here, never renamed there).
local function findStateLabel(button: GuiButton): TextLabel?
	local found: TextLabel? = nil
	pcall(function()
		local timer = (button :: Instance):FindFirstChild('Timer')
		local text = timer and (timer :: Instance):FindFirstChild('Text') or nil
		if text ~= nil and (text :: Instance):IsA('TextLabel') then
			found = text :: TextLabel
			return
		end
		local deep = (button :: Instance):FindFirstChildWhichIsA('TextLabel', true)
		if deep ~= nil then
			found = deep
		end
	end)
	return found
end

local function setOverlayVisible(_card: Card, _visible: boolean)
	-- The authored playtime cards expose state through the
	-- Timer text (Claim white / Claimed green / remaining
	-- timer); no overlay element exists in this panel, so
	-- there is nothing to toggle. Kept as an explicit no-op
	-- so future overlays have one call site.
end

-- Ordered milestone cards: Items buttons sorted by name
-- (days 1..6). Extra config milestones beyond the authored
-- cards reuse the last card; missing cards hide.
local function ensureCards(): boolean
	if playtimeGui ~= nil and (playtimeGui :: GuiObject).Parent ~= nil and #cards > 0 then
		return true
	end
	cards = {}
	statusText = nil
	pcall(function()
		local gui = playerGui()
		local main = gui and gui:FindFirstChild('Main') or nil
		local root = main and (main :: Instance):FindFirstChild('PlayTimeRewards') or nil
		if root == nil or not (root :: Instance):IsA('GuiObject') then
			return
		end
		playtimeGui = root :: GuiObject
		local text = (root :: Instance):FindFirstChild('Text')
		if text ~= nil and (text :: Instance):IsA('TextLabel') then
			statusText = text :: TextLabel
		end
		local items = (root :: Instance):FindFirstChild('Items')
		if items == nil then
			return
		end
		local named: { { order: number, button: GuiButton } } = {}
		for _, child in ipairs((items :: Instance):GetChildren()) do
			if (child :: Instance):IsA('GuiButton') then
				local n = tonumber((child :: Instance).Name) or 1e9
				named[#named + 1] = { order = n, button = child :: GuiButton }
			end
		end
		table.sort(named, function(a, b)
			return a.order < b.order
		end)
		for index, entry in ipairs(named) do
			cards[#cards + 1] = {
				button = entry.button,
				index = index,
				timerText = findStateLabel(entry.button),
			}
		end
	end)
	return #cards > 0
end

local function formatCountdown(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds))
	local h = math.floor(s / 3600)
	local m = math.floor((s % 3600) / 60)
	local sec = s % 60
	return ('%02d:%02d:%02d'):format(h, m, sec)
end

-- Displayed session playtime: snapshot anchor + local tick
-- (presentation only; eligibility stays server-side).
local function displayPlaytime(): number
	if type(lastSnapshot) ~= 'table' then
		return 0
	end
	local base = tonumber(lastSnapshot.Playtime) or 0
	local at = tonumber(lastSnapshot.ClientReceivedAt) or os.clock()
	return math.max(0, base + (os.clock() - at))
end

local function paintStatus()
	if statusText == nil or lastSnapshot == nil then
		return
	end
	local box = statusText
	pcall(function()
		if lastSnapshot.Completed == true then
			(box :: TextLabel).Text = 'All rewards claimed!'
		else
			(box :: TextLabel).Text = 'Playtime: ' .. formatCountdown(displayPlaytime())
		end
	end)
end

local function stopCountdown()
	if countdownThread ~= nil then
		pcall(task.cancel, countdownThread)
		countdownThread = nil
	end
end

-- Pure render from the authoritative snapshot: safe to call
-- repeatedly; fresh state always produces the correct UI.
-- Timer label carries state on the EXISTING element:
-- 'Claim' (white) / 'Claimed' (green) / remaining MM:SS.
-- Every rendered card stays clickable: locked/claimed clicks
-- reach the server, which rejects them with the existing
-- warning notification + SFX (never silent, never trusted).
local function renderState(snapshot: any)
	if type(snapshot) ~= 'table' or #cards < 1 then
		return
	end
	local rewards = snapshot.Rewards
	local count = if type(rewards) == 'table' then #rewards else 0
	for _, card in ipairs(cards) do
		local index = card.index
		if index > count then
			pcall(function()
				(card.button :: GuiButton).Visible = false
			end)
			continue
		end
		pcall(function()
			(card.button :: GuiButton).Visible = true
		end)
		local entry = if type(rewards) == 'table' then rewards[index] else nil
		local state = if type(entry) == 'table' and type(entry.State) == 'string' then entry.State else 'Locked'
		local text: string
		if state == 'Claimable' then
			text = 'Claim'
		elseif state == 'Claimed' then
			text = 'Claimed'
		else
			-- Remaining derives from the ticking display
			-- playtime (snapshot anchor + local tick), never
			-- from the snapshot's frozen Remaining, so the
			-- per-second repaint actually counts down.
			local required = if type(entry) == 'table' then tonumber(entry.RequiredPlaytime) or 0 else 0
			text = formatCountdown(math.max(0, required - displayPlaytime()))
		end
		pcall(function()
			local btn = card.button :: GuiButton
			if card.timerText ~= nil then
				local label = card.timerText :: TextLabel
				label.Text = text
				if state == 'Claimable' then
					label.TextColor3 = CLAIM_WHITE
				elseif state == 'Claimed' then
					label.TextColor3 = CLAIMED_GREEN
				end
			end
			setOverlayVisible(card, false)
			btn.Active = true
			btn.AutoButtonColor = true
		end)
	end
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

local function startCountdown()
	stopCountdown()
	countdownThread = task.spawn(function()
		while true do
			if playtimeGui == nil or not (playtimeGui :: GuiObject).Visible then
				return
			end
			paintStatus()
			-- Repaint cards each tick so remaining timers and
			-- threshold crossings track the ticking display;
			-- state strings still come only from snapshots.
			renderState(lastSnapshot)
			if lastSnapshot ~= nil then
				local rewards = lastSnapshot.Rewards
				if type(rewards) == 'table' then
					for _, entry in ipairs(rewards) do
						if type(entry) == 'table' and type(entry.RequiredPlaytime) == 'number' then
							local threshold = entry.RequiredPlaytime
							if displayPlaytime() >= threshold and expiryPulledFor ~= threshold then
								expiryPulledFor = threshold
								requestState()
								break
							end
						end
					end
				end
			end
			task.wait(1)
		end
	end)
end

local function onClaimClicked(index: number)
	if inFlight then
		return
	end
	if actionRemote == nil then
		warnPlaytime('PlaytimeRewardsAction remote missing; cannot claim')
		return
	end
	inFlight = true
	logPlaytime('claim clicked')
	local remote = actionRemote
	pcall(function()
		(remote :: RemoteEvent):FireServer({ Action = 'Claim', Index = index })
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
	-- Paid Skip All: prompt the Shop SkipPlaytime Developer
	-- Product. No remote fires here — the server receipt is
	-- the ONLY grant path (it sets entitlement, then runs
	-- the identical gated ClaimAll). ProductId comes from
	-- ShopConfig, never hardcoded.
	local player = localPlayer or Players.LocalPlayer
	if player == nil then
		warnPlaytime('skip ignored (no LocalPlayer)')
		return
	end
	local productId: number? = nil
	pcall(function()
		local entry = ShopConfig.DeveloperProducts.SkipPlaytime
		if type(entry) == 'table' and type(entry.ProductId) == 'number' then
			productId = entry.ProductId
		end
	end)
	if productId == nil then
		warnPlaytime('SkipPlaytime product missing from ShopConfig; cannot skip')
		return
	end
	logPlaytime(('skip clicked productId=%s'):format(tostring(productId)))
	local promptOk, promptErr = pcall(function()
		MarketplaceService:PromptProductPurchase(player, productId :: number)
	end)
	logPlaytime(('skip prompt ok=%s err=%s'):format(tostring(promptOk), tostring(promptErr)))
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
		local index = card.index
		local button = card.button
		pcall(function()
			(button :: GuiButton).Activated:Connect(function()
				-- Every card submits; the server recomputes
				-- eligibility and rejects locked/claimed
				-- clicks with a warning (never silent).
				onClaimClicked(index)
			end)
		end)
	end
	-- Skip button (paid Skip All): prompts the Shop
	-- SkipPlaytime product purchase (see onSkipClicked). The
	-- server receipt grants entitlement + claims; the button
	-- itself grants nothing. Connected once (attribute guard
	-- survives re-wire); a missing Studio Skip button simply
	-- means no affordance.
	pcall(function()
		if playtimeGui == nil then
			return
		end
		local skip = (playtimeGui :: GuiObject):FindFirstChild('Skip', true)
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

-- Accept a server snapshot unless it is strictly older than
-- what is already rendered (Version = server build tick ms,
-- monotonic per server).
local function acceptSnapshot(payload: any): boolean
	if type(payload) ~= 'table' then
		return false
	end
	local version = tonumber(payload.Version) or 0
	if lastVersion ~= nil and version < (lastVersion :: number) then
		return false
	end
	lastVersion = version
	lastSnapshot = payload
	if type(lastSnapshot) == 'table' then
		lastSnapshot.ClientReceivedAt = os.clock()
	end
	return true
end

-- Neutral loading paint: Timer labels show '...' (never a
-- fake Claimed) until the first authoritative snapshot lands
-- and renderState replaces it.
local function paintLoading()
	if lastSnapshot ~= nil then
		return
	end
	for _, card in ipairs(cards) do
		pcall(function()
			if card.timerText ~= nil then
				local label = card.timerText :: TextLabel
				label.Text = '...'
			end
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

local function playtimeIcon(): any
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
		icon = topbarModule.getIcon('PlaytimeRewards')
	end)
	return icon
end

-- TopbarPlus alert from the SAME authoritative snapshot as
-- the cards: ON iff ≥1 milestone reads State == 'Claimable'.
-- Starts OFF (§57), never from UI text or local time.
-- notify() fires once per OFF→ON transition (badge counts
-- stack otherwise); a private never-fired signal avoids the
-- default deselect-clear so only authoritative no-Claimable
-- clears it via clearNotices().
local function updateTopbarNotification(snapshot: any)
	if type(snapshot) ~= 'table' or type(snapshot.Rewards) ~= 'table' then
		return
	end
	local claimable = 0
	for _, entry in ipairs(snapshot.Rewards) do
		if type(entry) == 'table' and entry.State == 'Claimable' then
			claimable += 1
		end
	end
	local icon = playtimeIcon()
	if icon == nil then
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
			logPlaytime('topbar notification ON reason=Claimable')
		end
	elseif noticeOn then
		noticeOn = false
		pcall(function()
			(icon :: any):clearNotices()
		end)
		logPlaytime('topbar notification OFF reason=NoClaimableReward')
	end
end

local function onState(payload: any)
	if not acceptSnapshot(payload) then
		logPlaytime('stale state ignored')
		return
	end
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
	if playtimeGui ~= nil and (playtimeGui :: GuiObject).Visible then
		startCountdown()
	end
	logPlaytime('state received')
end

local function onResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	inFlight = false
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
		logPlaytime(('claimed index=%s'):format(tostring((payload :: any).Index)))
	else
		logPlaytime(('claim failed reason=%s'):format(tostring((payload :: any).Reason)))
	end
end

function PlaytimeRewardsController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnPlaytime('no LocalPlayer; controller disabled')
		return
	end
	-- Re-resolve + refresh state on every open (bindOpen is
	-- idempotent; Main.ChildAdded catches late panels).
	local function bindOpen()
		if openHooked then
			return
		end
		if playtimeGui == nil or (playtimeGui :: GuiObject).Parent == nil then
			return
		end
		openHooked = true
		pcall(function()
			(playtimeGui :: GuiObject):GetPropertyChangedSignal('Visible'):Connect(function()
				if (playtimeGui :: GuiObject).Visible then
					pcall(function()
						if ensureCards() then
							wireCards()
						end
					end)
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
	-- Immediate, independent binding: resolve the authored
	-- panel without waiting on remotes or server data.
	pcall(function()
		if ensureCards() then
			wireCards()
			logPlaytime('UI ready')
		end
		paintLoading()
		bindOpen()
	end)
	-- Eager single-shot retry on OUR panel only + late-panel
	-- catch via Main.ChildAdded (event-driven, no polling).
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
			(main :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name == 'PlayTimeRewards' then
					pcall(function()
						if ensureCards() then
							wireCards()
						end
						paintLoading()
						bindOpen()
					end)
				end
			end)
			if (main :: Instance):WaitForChild('PlayTimeRewards', 5) == nil then
				return
			end
			if ensureCards() then
				wireCards()
				logPlaytime('eager UI ready')
			end
			paintLoading()
			bindOpen()
			renderState(lastSnapshot)
		end)
	end)
	local folder = Remotes.WaitForReady()
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.PlaytimeRewardsAction, 10)
	end)
	if okAction and actionEvent ~= nil and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent :: RemoteEvent
	else
		warnPlaytime('PlaytimeRewardsAction remote missing; state/claim disabled')
	end
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.PlaytimeRewardsState, 10)
	end)
	if okState and stateEvent ~= nil and (stateEvent :: Instance):IsA('RemoteEvent') then
		(stateEvent :: RemoteEvent).OnClientEvent:Connect(onState)
	else
		warnPlaytime('PlaytimeRewardsState remote missing; cards stay empty')
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.PlaytimeRewardsResult, 10)
	end)
	if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
		(resultEvent :: RemoteEvent).OnClientEvent:Connect(onResult)
	else
		warnPlaytime('PlaytimeRewardsResult remote missing; claim feedback disabled')
	end
	-- Asynchronous content init (never blocks the binding
	-- above): pull the authoritative snapshot once remotes
	-- exist. Re-pulled on every open.
	requestState()
	logPlaytime('controller ready')
end

return table.freeze(PlaytimeRewardsController)
