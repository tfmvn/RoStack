--!strict
--!native
--[[
	ArenaController (raid menu — simple view, server owns state)
	=============================================================
	AUTHORITY MODEL (read before touching this file):
	  * The server owns the raid: loadout, stages, HP, rewards,
	    restart progress, and prices. This file NEVER selects
	    stages, NEVER computes HP or prices, NEVER trusts its own
	    labels. It renders the last authoritative ArenaState
	    payload and forwards ONLY { Action, Option }:
	    'Start' + Buy1/Buy2/Buy3 begins a raid at the
	    server-authorized stage. (Server-side retreat/cancel in
	    ArenaService is untouched; this controller no longer
	    presents a retreat button.)
	  * Server re-validates every request (progress, funds,
	    session); rejection arrives via ArenaResult + a fresh
	    ArenaState push.

	START UI (authored, never built here):
	  PlayerGui.Main.Arena is the ONLY start UI — resolved and
	  painted, never constructed. Buy3 = free stage-1 entry,
	  Buy1 = paid warmup restart, Buy2 = paid direct restart,
	  CloseButton dismisses. The legacy code-built ArenaGui raid
	  HUD ("ARENA RAID" panel) was REMOVED: this file builds
	  ZERO UI. Mid-raid there is intentionally no panel; the
	  result screen is owned by ArenaResultController.

	VIEW STATES (explicit `screen`, never inferred):
	  Hidden  — everything closed.
	  Start   — authored menu open, ONLY from Adventure/Arena
	            interaction (server Show).
	  Running — start accepted; menu hidden for the run.
	  Result  — terminal RaidEnd received; menu hidden while the
	            result panel owns the screen.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- Display-only formatting (shared pure modules). Every call
-- is pcall-guarded with a raw fallback: the client never
-- computes rewards, only renders server-settled values.
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local NumberUtils = require(ReplicatedStorage.Utility.NumberUtils)
local ArenaUIState = require(ReplicatedStorage.Utility.ArenaUIState)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)

local ArenaController = {}

local function debugLog(message: string)
	pcall(function()
		Debug.Warn('Arena', message)
	end)
end

local actionRemote: RemoteEvent? = nil
local wired = false

local lastLoadout: { [string]: any }? = nil
local lastSession: { [string]: any }? = nil
local startInFlight = false

-- Explicit menu screen state (never inferred from visibility):
--   Hidden  — authored menu closed (initial, raid running,
--             result open, player walked away).
--   Start   — authored Main.Arena open, ONLY from an actual
--             Adventure/Arena interaction (server Show).
--   Running — start request accepted; menu hidden for the run.
--   Result  — terminal RaidEnd received; menu hidden while the
--             result panel owns the screen.
-- Transitions: interaction -> Start; Buy1/2/3 accept -> Running;
-- RaidEnd -> Result; Continue/close -> Hidden (result controller
-- owns its panel; this controller only hides its own menu);
-- new interaction -> Start. Result -> Start automatically NEVER
-- happens (guarded by the shared result-open flag).
local screen: string = 'Hidden'

local function logArenaUi(message: string)
	Debug.Log('ArenaUI', message)
end

local function warnUi(message: string)
	Debug.Warn('Arena', message)
end

-- Forward declaration: the authored start-UI refs live in the
-- block below (after the shared helpers); the central writer
-- only needs the root.
local startGui: Instance? = nil

-- Authored root may be a Frame (Visible) or a ScreenGui
-- (Enabled) depending on Studio authoring — handle both.
local function setStartRootVisible(root: Instance, visible: boolean)
	if root:IsA('LayerCollector') then
		(root :: LayerCollector).Enabled = visible
	else
		(root :: GuiObject).Visible = visible
	end
end

-- Central START-menu visibility writer: the ONLY place the
-- authored start UI visibility is set. Every transition logs
-- with an explicit next screen — never inferred from
-- visibility.
local function setMenuVisible(visible: boolean, reason: string, nextScreen: string)
	screen = nextScreen
	pcall(function()
		if startGui ~= nil then
			-- Full menu presentation (UiOpen + overlay/blur +
			-- Pop on open; Pop out on close). LayerCollector
			-- roots toggle instantly with sound; GuiObject
			-- roots animate. Already-open/closed calls are
			-- safe no-ops inside.
			local root = startGui :: Instance
			if root:IsA('GuiObject') then
				MenuPresentation.SetVisible(root :: GuiObject, visible)
			else
				setStartRootVisible(root, visible)
			end
		end
	end)
	logArenaUi(('%s screen=%s'):format(reason, screen))
end

-- --- Authored start menu (PlayerGui.Main.Arena) --------------------------
-- The ONLY start UI: resolved, painted, never constructed. Refs
-- are re-resolved whenever the GUI resets (respawn); buttons are
-- bound exactly once per instance set. Dynamic text only:
-- WarmupLevel/LastLevel titles + Buy price labels. Layout,
-- styling, and static wording stay exactly as authored.
-- (startGui root is forward-declared above the central
-- writer; the remaining refs live here with the resolvers.)
local buyButtons: { GuiButton? } = { nil, nil, nil }
local buyLabels: { TextLabel? } = { nil, nil, nil }
local warmupTitle: TextLabel? = nil
local lastLevelTitle: TextLabel? = nil
local startButtonsWired = false
local lastRestart: { [string]: any }? = nil

local BUY_OPTIONS = { 'Buy1', 'Buy2', 'Buy3' }

local function findStartChild(parent: Instance?, name: string, className: string): Instance?
	if parent == nil then
		return nil
	end
	local found: Instance? = nil
	pcall(function()
		found = parent:FindFirstChild(name)
	end)
	if found == nil or not (found :: Instance):IsA(className) then
		return nil
	end
	return found
end

local function ensureStartGui(): boolean
	if startGui ~= nil and (startGui :: Instance).Parent ~= nil then
		return true
	end
	startGui = nil
	startButtonsWired = false
	buyButtons = { nil, nil, nil }
	buyLabels = { nil, nil, nil }
	warmupTitle = nil
	lastLevelTitle = nil
	pcall(function()
		local player = Players.LocalPlayer
		local playerGui = player and player:FindFirstChildOfClass('PlayerGui') or nil
		local main = playerGui and playerGui:FindFirstChild('Main') or nil
		local arena = main and (main :: Instance):FindFirstChild('Arena') or nil
		if arena == nil then
			return
		end
		if not (arena :: Instance):IsA('GuiObject') and not (arena :: Instance):IsA('LayerCollector') then
			return
		end
		for i, opt in ipairs(BUY_OPTIONS) do
			local button = findStartChild(arena, opt, 'GuiButton')
			if button ~= nil then
				buyButtons[i] = button :: GuiButton
				buyLabels[i] = findStartChild(button, 'TextLabel', 'TextLabel') :: TextLabel?
			end
		end
		local warmup = findStartChild(arena, 'WarmupLevel', 'GuiObject')
		if warmup ~= nil then
			warmupTitle = findStartChild(warmup, 'Title', 'TextLabel') :: TextLabel?
		end
		local last = findStartChild(arena, 'LastLevel', 'GuiObject')
		if last ~= nil then
			lastLevelTitle = findStartChild(last, 'Title', 'TextLabel') :: TextLabel?
		end
		startGui = arena
	end)
	if startGui == nil then
		return false
	end
	-- Minimum viable start menu: all three buy buttons + close.
	-- Titles/labels are optional (paint skips nils).
	if buyButtons[1] == nil or buyButtons[2] == nil or buyButtons[3] == nil then
		startGui = nil
		return false
	end
	local closeButton = findStartChild(startGui, 'CloseButton', 'GuiButton')
	if closeButton == nil then
		startGui = nil
		return false
	end
	return true
end

local function priceText(raw: any): string
	if type(raw) ~= 'string' or raw == '' or raw == '0' then
		return 'FREE'
	end
	local formatted: string? = nil
	pcall(function()
		local text = BigNumber.Format(raw)
		if type(text) == 'string' and text ~= '' then
			formatted = text
		end
	end)
	if formatted == nil then
		formatted = raw
	end
	return '$' .. (formatted :: string)
end

-- Paint the authored menu from the last authoritative Restart
-- snapshot (server-provided LastLevel/WarmupLevel/prices/
-- availability). Runs on every open so values can never go
-- stale across runs. Static design untouched — text only.
local function paintStartMenu()
	local restart = lastRestart
	local last = 0
	local warmup = 1
	if type(restart) == 'table' then
		last = math.floor(tonumber(restart.LastLevel) or 0)
		warmup = math.floor(tonumber(restart.WarmupLevel) or 1)
	end
	pcall(function()
		if warmupTitle ~= nil then
			(warmupTitle :: TextLabel).Text = ('Lvl %d'):format(math.max(1, warmup))
		end
		if lastLevelTitle ~= nil then
			(lastLevelTitle :: TextLabel).Text = ('Lvl %d'):format(math.max(1, last))
		end
	end)
	for i, opt in ipairs(BUY_OPTIONS) do
		local button = buyButtons[i]
		if button ~= nil then
			pcall(function()
				local info: { [string]: any }? = nil
				if type(restart) == 'table' and type(restart[opt]) == 'table' then
					info = restart[opt]
				end
				local available = info ~= nil and (info :: { [string]: any }).Available == true
				if lastSession ~= nil or startInFlight then
					available = false
				end
				local label = buyLabels[i]
				-- NOTE: bind casts to locals first — a statement
				-- beginning with `(...)` would otherwise glue onto
				-- the previous line as a call.
				local textLabel = label :: TextLabel?
				if opt == 'Buy3' then
					if textLabel ~= nil then
						textLabel.Text = 'Lv 1 · FREE'
					end
				else
					local price: any = nil
					if info ~= nil then
						price = (info :: { [string]: any }).Price
					end
					if textLabel ~= nil then
						if available then
							textLabel.Text = priceText(price)
						else
							textLabel.Text = 'Locked'
						end
					end
				end
				local btn = button :: GuiButton
				btn.Active = available
				btn.AutoButtonColor = available
			end)
		end
	end
	if type(restart) == 'table' then
		logArenaUi(('opened lastLevel=%s warmupLevel=%s'):format(tostring(last), tostring(warmup)))
	end
end

local function onBuyClicked(option: string)
	if startInFlight or lastSession ~= nil then
		return
	end
	if actionRemote == nil then
		warnUi('ArenaAction remote missing; cannot start')
		return
	end
	-- Client-side availability gate (server re-validates: never
	-- trusted). Prevents pointless doomed requests.
	if option ~= 'Buy3' and type(lastRestart) == 'table' then
		local info = (lastRestart :: { [string]: any })[option]
		if type(info) ~= 'table' or info.Available ~= true then
			return
		end
	end
	startInFlight = true
	logArenaUi(('%s requested'):format(option))
	pcall(function()
		(actionRemote :: RemoteEvent):FireServer({ Action = 'Start', Option = option })
	end)
	-- Self-heal backstop (same pattern as the old menu): a lost
	-- result must never wedge the buttons. The authoritative
	-- ArenaResult / ArenaState clears the flight first.
	task.delay(ArenaPresentationConfig.AdventurerPlaceholder.StartButtonBackstop, function()
		if startInFlight then
			startInFlight = false
			pcall(paintStartMenu)
		end
	end)
end

local function wireStartButtons()
	if startButtonsWired then
		return
	end
	startButtonsWired = true
	for i, opt in ipairs(BUY_OPTIONS) do
		local button = buyButtons[i]
		if button ~= nil then
			local option = opt
			local btn = button :: GuiButton
			pcall(function()
				btn.Activated:Connect(function()
					onBuyClicked(option)
				end)
				btn.MouseButton1Click:Connect(function()
					onBuyClicked(option)
				end)
			end)
		end
	end
	local closeButton: Instance? = nil
	if startGui ~= nil then
		closeButton = findStartChild(startGui, 'CloseButton', 'GuiButton')
	end
	if closeButton ~= nil then
		local closeBtn = closeButton :: GuiButton
		pcall(function()
			closeBtn.Activated:Connect(function()
				setMenuVisible(false, 'closed -> HIDDEN', 'Hidden')
			end)
			closeBtn.MouseButton1Click:Connect(function()
				setMenuVisible(false, 'closed -> HIDDEN', 'Hidden')
			end)
		end)
	else
		warnUi('authored Arena CloseButton missing')
	end
end

-- Forward declaration (applyState is assigned below; onState
-- calls it). No render forward declaration remains: the
-- generated-HUD painter was removed with the legacy panel.
local applyState: (any) -> () = nil :: any

local function rowText(member: any): string
	if type(member) ~= 'table' then
		return '?'
	end
	local name = tostring(member.DisplayName or member.DefinitionId or 'Animal')
	local level = tonumber(member.Level) or 1
	-- Mid-raid entries carry run HP; loadout entries carry
	-- MaxHealth only (full by definition pre-raid).
	local hp = tonumber(member.Health)
	local maxHp = tonumber(member.MaxHealth)
	if member.Alive == false then
		return ('%s  Lv %d  DEAD'):format(name, level)
	end
	if hp ~= nil and maxHp ~= nil and maxHp > 0 then
		return ('%s  Lv %d  %d / %d'):format(name, level, math.floor(hp + 0.5), math.floor(maxHp + 0.5))
	end
	if maxHp ~= nil and maxHp > 0 then
		return ('%s  Lv %d  %d HP'):format(name, level, math.floor(maxHp + 0.5))
	end
	return ('%s  Lv %d'):format(name, level)
end

-- 0..1 run-HP fraction for the bar. Loadout entries (no
-- run HP yet) read full; dead reads empty. Never NaN.
local function hpFraction(member: any): number
	if type(member) ~= 'table' or member.Alive == false then
		return 0
	end
	local hp = tonumber(member.Health)
	local maxHp = tonumber(member.MaxHealth)
	if hp == nil or maxHp == nil or maxHp <= 0 then
		return 1
	end
	if hp ~= hp then
		return 0
	end
	return math.clamp(hp / maxHp, 0, 1)
end

-- Server-settled earnings for the results line. Cash is a
-- BigNumber decimal string ('2500' -> '+$2.5K'); XP is a
-- plain number. Zero/unknown renders as '' (never '+$0').
local function earnedText(raid: { [string]: any }): string
	local parts: { string } = {}
	local cash = raid.EarnedCash
	if type(cash) == 'string' and cash ~= '' and cash ~= '0' then
		local text: string? = nil
		pcall(function()
			text = BigNumber.Format(cash)
		end)
		if type(text) == 'string' and text ~= '' then
			parts[#parts + 1] = '+$' .. text
		else
			parts[#parts + 1] = '+$' .. cash
		end
	end
	local xp = tonumber(raid.EarnedXP) or 0
	if xp > 0 then
		local text: string? = nil
		pcall(function()
			text = NumberUtils.Abbreviate(xp)
		end)
		if type(text) == 'string' and text ~= '' then
			parts[#parts + 1] = '+' .. text .. ' XP'
		else
			parts[#parts + 1] = '+' .. tostring(math.floor(xp)) .. ' XP'
		end
	end
	return table.concat(parts, '   ')
end

-- Pure display helpers above (rowText/hpFraction/earnedText)
-- stay for their test seams; they compute strings only and
-- touch no UI. (The generated-HUD painter render(), the
-- retreat-button handler, and the legacy panel builder were
-- removed with the legacy panel. Server-side retreat/cancel in
-- ArenaService is untouched.)

-- Pure wave text (TEST seam): "Wave N" from the authoritative
-- session Stage (ArenaLevel fallback), nil when absent.
local function _waveText(session: any): string?
	if type(session) ~= 'table' then
		return nil
	end
	local stage = tonumber((session :: any).Stage) or tonumber((session :: any).ArenaLevel)
	if stage == nil then
		return nil
	end
	return 'Wave ' .. tostring(stage)
end

local function _paintWave()
	pcall(function()
		local player = Players.LocalPlayer
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local root = HudTree.WaveRoot(playerGui)
		if root == nil then
			return
		end
		if lastSession == nil then
			-- No raid: hide only our own counter and give back
			-- ancestors we borrowed — shared Bottom stays up
			-- iff other UI still needs it.
			if (root :: Instance):IsA('GuiObject') then
				(root :: GuiObject).Visible = false
			end
			HudTree.ReleaseChain(root)
			return
		end
		-- Raid active: the Bottom chain must be up or the
		-- counter paints invisibly.
		HudTree.EnsureChainVisible(root)
		if (root :: Instance):IsA('GuiObject') then
			(root :: GuiObject).Visible = true
		end
		local text = _waveText(lastSession)
		if text ~= nil then
			local counter = HudTree.WaveCounter(playerGui)
			if counter ~= nil then
				counter.Text = text
			end
		end
	end)
end

applyState = function(state: any)
	if type(state) ~= 'table' then
		return
	end
	if type(state.Loadout) == 'table' then
		lastLoadout = state.Loadout
	end
	if type(state.Restart) == 'table' then
		lastRestart = state.Restart
	end
	-- Session snapshot drives the screen machine; a generation
	-- switch (new raid or raid gone) clears the start flight so
	-- a stale callback can never wedge the buttons. No UI is
	-- built or updated here — the authored start menu repaints
	-- itself when open, and combat/result presentation lives in
	-- their own controllers.
	local sess = state.Session
	if type(sess) == 'table' then
		lastSession = sess
		startInFlight = false
	else
		lastSession = nil
	end
	-- HUD.Bottom.WaveCounter: visible during a raid, showing the
	-- authoritative current wave (Session.Stage, pushed by the
	-- server on start/advance/end). Hidden whenever no session
	-- exists (lobby, result, retreat, wipe). Presentation only.
	_paintWave()
	-- Repaint the authored menu if it is open so prices and
	-- availability track the latest authoritative snapshot.
	if screen == 'Start' then
		pcall(paintStartMenu)
	end
end

-- NOTE: the legacy code-built ArenaGui raid HUD
-- ("ARENA RAID" panel: status/team/retreat/close) was removed
-- here. This controller intentionally builds ZERO UI now:
-- start = authored PlayerGui.Main.Arena, result = authored
-- PlayerGui.Main.ArenaResult (separate controller). Server-side
-- retreat/cancel (ArenaService.CancelArena) is untouched.

local function onState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	debugLog('Arena state received')
	local ok, err = pcall(applyState, payload)
	if not ok then
		warnUi('applyState failed: ' .. tostring(err))
		return
	end
	if payload.Show == true then
		-- Interaction is the ONLY normal trigger for the START
		-- menu. Mid-raid interaction only records the Running
		-- screen (there is no raid panel anymore). And result
		-- wins: a stale/duplicate Show while the result panel is
		-- open must never reopen anything underneath it.
		if lastSession ~= nil then
			screen = 'Running'
			logArenaUi('interaction mid-raid -> Running (no raid panel)')
			return
		end
		if ArenaUIState.IsResultOpen() then
			logArenaUi(
				('BLOCKED_START reason=result_visible session=%s'):format(tostring(ArenaUIState.ResultSession()))
			)
			return
		end
		if not ensureStartGui() then
			warnUi('authored Arena start UI missing; cannot open')
			return
		end
		wireStartButtons()
		paintStartMenu()
		setMenuVisible(true, 'interaction -> START', 'Start')
		logArenaUi('authored Arena start UI opened')
	end
end

local function onResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	if payload.Action == 'Start' then
		if payload.Success == true then
			-- Accepted: authored menu hides for the run (the
			-- server-selected startLevel is logged for proof).
			-- No legacy raid HUD is shown: combat runs with no
			-- code-built panel at all.
			startInFlight = false
			setMenuVisible(false, 'start accepted -> RUNNING', 'Running')
			logArenaUi(('start authorized startLevel=%s'):format(tostring(payload.StartLevel)))
			logArenaUi(('Arena started without legacy raid HUD session=%s'):format(tostring(payload.SessionId)))
			warnUi('raid started session=' .. tostring(payload.SessionId))
		else
			-- Rejected: drop the flight and repaint the menu
			-- from the last authoritative snapshot (fresh
			-- ArenaState push arrives from the server as well —
			-- resync, no wedge). Menu visibility is untouched
			-- (stays however the player left it).
			startInFlight = false
			warnUi('request failed action=Start error=' .. tostring(payload.Error))
			if screen == 'Start' then
				pcall(paintStartMenu)
			end
		end
	elseif payload.Action == 'RaidEnd' then
		-- Terminal outcome: the RESULT panel owns the screen now.
		-- The Start menu must NEVER reopen here. There is no
		-- raid panel to hide anymore — only the authored menu,
		-- hidden explicitly until the next real Adventure/Arena
		-- interaction.
		startInFlight = false
		setMenuVisible(false, 'result received -> RESULT (menu stays hidden)', 'Result')
	elseif payload.Action == 'Cancel' and payload.Success == true then
		-- Retreat confirmed: never leave the buttons wedged on
		-- STARTING if a retreat raced the start flight. The
		-- server's state push re-renders authoritatively too.
		startInFlight = false
		if screen == 'Start' then
			pcall(paintStartMenu)
		end
	elseif payload.Success == false then
		warnUi('request failed action=' .. tostring(payload.Action) .. ' error=' .. tostring(payload.Error))
	end
end

function ArenaController.Init()
	if wired then
		return
	end
	wired = true
	local folder = Remotes.WaitForReady()
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaState, 10)
	end)
	if okState and stateEvent and (stateEvent :: Instance):IsA('RemoteEvent') then
		(stateEvent :: RemoteEvent).OnClientEvent:Connect(onState)
	else
		warnUi('ArenaState remote missing; arena menu cannot open')
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaResult, 10)
	end)
	if okResult and resultEvent and (resultEvent :: Instance):IsA('RemoteEvent') then
		(resultEvent :: RemoteEvent).OnClientEvent:Connect(onResult)
	else
		warnUi('ArenaResult remote missing; start feedback disabled')
	end
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaAction, 10)
	end)
	if okAction and actionEvent and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent
	else
		warnUi('ArenaAction remote missing; arena actions disabled')
	end
	local okCombat, combatEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaCombatEvent, 10)
	end)
	if okCombat and combatEvent and (combatEvent :: Instance):IsA('RemoteEvent') then
		(combatEvent :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
			if type(payload) ~= 'table' then
				return
			end
			debugLog(('combat event=%s session=%s'):format(tostring(payload.Event), tostring(payload.SessionId)))
		end)
	else
		warnUi('ArenaCombatEvent remote missing; battle feed disabled')
	end
	-- Hide the authored start menu if already present (never
	-- flash on join) and bind its buttons once. Re-resolution
	-- after GUI resets happens lazily on the next open. The wave
	-- counter likewise starts hidden (no raid on join).
	task.spawn(function()
		pcall(function()
			_paintWave()
			if ensureStartGui() then
				wireStartButtons()
				if startGui ~= nil then
					setStartRootVisible(startGui :: Instance, false)
				end
			end
		end)
	end)
	logArenaUi('old generated raid HUD disabled/removed (authored UI only)')
end

-- TEST-ONLY seams (headless-verifiable without a live GUI).
function ArenaController._TestReset()
	lastLoadout = nil
	lastSession = nil
	lastRestart = nil
	startInFlight = false
	screen = 'Hidden'
	startGui = nil
	buyButtons = { nil, nil, nil }
	buyLabels = { nil, nil, nil }
	warmupTitle = nil
	lastLevelTitle = nil
	startButtonsWired = false
end

function ArenaController._TestScreen(): string
	return screen
end

function ArenaController._TestInjectState(loadout: any?, session: any?)
	lastLoadout = loadout
	lastSession = session
end

function ArenaController._TestStartState(): string
	if lastSession ~= nil then
		return 'in_progress'
	end
	if startInFlight then
		return 'starting'
	end
	if lastLoadout ~= nil then
		local count = tonumber((lastLoadout :: { [string]: any }).Count) or 0
		local minTeam = tonumber((lastLoadout :: { [string]: any }).MinTeam) or 1
		if count >= minTeam then
			return 'ready'
		end
	end
	return 'unavailable'
end

function ArenaController._TestRowText(member: any): string
	return rowText(member)
end

function ArenaController._TestPriceText(raw: any): string
	return priceText(raw)
end

function ArenaController._TestHpFraction(member: any): number
	return hpFraction(member)
end
function ArenaController._TestWaveText(session: any): string?
	return _waveText(session)
end

function ArenaController._TestEarnedText(raid: { [string]: any }): string
	return earnedText(raid)
end

return table.freeze(ArenaController)
