--!strict
--!native
--[[
	HudNotificationController
	=======================
	Drives the Studio-authored `PlayerGui.HUD.Center.Notifications`
	panel (PLURAL canonical; singular `Center.Notification` and
	legacy `HUD.Notifications` accepted as fallbacks — see
	HudTree.NotificationPanel). Single temporary "window" with
	an explicit Visible lifecycle:

	  idle (Visible = false)
	    ↓ show()
	  content updated -> staged above resting (Y only) ->
	  Visible = true
	    ↓
	  clean vertical ease-in from above (0.25s Quint Out)
	    ↓
	  SAME fixed resting position
	    ↓
	  visible (rolling spam window, DISPLAY_DURATION = 2.0s)
	    ↓ expiry, no refresh
	  clean vertical ease-out upward (0.20s Quint Out)
	    ↓
	  Visible = false -> idle

	MOTION CONTRACT: every animated position is built by
	_withYOffset(resting, dy), which copies resting X.Scale /
	X.Offset verbatim and touches only Y.Offset. X cannot move
	— no bounce, no overshoot, no scale tricks, no rotation.
	A runtime invariant check warns if X ever disagrees with
	resting. Spam never moves the toast: arrivals only update
	text and extend expiry.

	Spam semantics: every arrival (same or different content)
	updates the text, extends expiry = now + DISPLAY_DURATION,
	and plays only a subtle scale punch — the entrance animation
	never replays while the window is alive. Different warnings
	replace content in the single window (no queue, no pile).
	Dynamic re-fires ("$10K" -> "$20K") update to the latest
	authoritative text and extend the window.

	Race safety: one state block {phase, generation, expiry} +
	cancelled tween handles. Old timers/tweens can never hide a
	newer notification: every callback re-checks its generation
	and the live expiry before touching Visible.

	Resilience: the panel is resolved lazily per call and
	re-validated every use (respawn-safe; a recreated HUD is
	re-bound automatically). Unknown hierarchy is adapted to:
	the controller writes text into the best text label it can
	find (named Message/Text/Body, else title + first TextLabel,
	else the panel itself when it renders text). Exactly one
	UIScale is created per panel instance and reused. No polling,
	no Heartbeat/RenderStepped, no Workspace scans — tweens +
	generation-guarded state timers only. No remote listeners
	here: ToastController.Push delegates to Show() (one Notify
	subscription total, no duplicates).

	Returns true from Show() when the HUD panel owned the
	notification; false when no usable panel exists (the caller
	warns loudly instead of silently swallowing it).
]]

local Players = game:GetService('Players')
local TweenService = game:GetService('TweenService')

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local NotificationConfig = require(game:GetService('ReplicatedStorage').Config.Presentation.UI).Notify
local HudTree = require(script.Parent.HudTree)

local HudNotificationController = {}

local localPlayer = Players.LocalPlayer

-- Rolling spam-window hold time (seconds). Every arrival pushes
-- expiry to now + DISPLAY_DURATION.
local DISPLAY_DURATION = NotificationConfig.HudMotion.DisplayDuration

-- Motion spec (all pixel offsets on Y ONLY — X is copied
-- field-for-field from resting, so the path is exactly vertical
-- by construction, never by arithmetic luck). Single ease in,
-- single ease out; no overshoot, no scale, no bounce.
local ENTER_OFFSET_PX = NotificationConfig.HudMotion.EnterOffsetPx
local EXIT_OFFSET_PX = NotificationConfig.HudMotion.ExitOffsetPx
local DROP_SECONDS = NotificationConfig.HudMotion.DropSeconds
local EXIT_SECONDS = NotificationConfig.HudMotion.ExitSeconds
local EXIT_CANCEL_SECONDS = NotificationConfig.HudMotion.ExitCancelSeconds
local EXIT_CANCEL_DELAY_SECONDS = NotificationConfig.HudMotion.ExitCancelDelaySeconds
local RESTORE_BUFFER_SECONDS = NotificationConfig.HudMotion.RestoreBufferSeconds

local categoryColorFallback: { [string]: Color3 } = {
	Warning = Color3.fromRGB(255, 200, 80),
	Reward = Color3.fromRGB(120, 230, 140),
	System = Color3.fromRGB(160, 200, 255),
	Error = Color3.fromRGB(255, 90, 90),
}

local function _categoryColor(cat: string): Color3
	local colors: any = nil
	pcall(function()
		colors = NotificationConfig.CategoryColor
	end)
	if type(colors) == 'table' then
		local c = (colors :: { [string]: any })[cat]
		if typeof(c) == 'Color3' then
			return c
		end
	end
	return categoryColorFallback[cat] or Color3.fromRGB(255, 255, 255)
end

-- --- Live state (one window) --------------------------------------------

local _panel: GuiObject? = nil
local _resting: UDim2? = nil
local _msgLabel: TextLabel? = nil
local _titleLabel: TextLabel? = nil
local _phase: string = 'idle' -- idle | entering | visible | exiting
local _generation: number = 0
local _expiry: number = 0
local _activeTweens: { Tween } = {}

local function _cancelTweens()
	for _, tw in ipairs(_activeTweens) do
		pcall(function()
			tw:Cancel()
		end)
	end
	table.clear(_activeTweens)
end

-- Build an animated position from resting with a Y-pixel delta.
-- X.Scale and X.Offset are copied verbatim: the motion path is
-- exactly vertical by construction.
local function _withYOffset(resting: UDim2, dy: number): UDim2
	return UDim2.new(resting.X.Scale, resting.X.Offset, resting.Y.Scale, resting.Y.Offset + dy)
end

-- Runtime invariant (Studio self-test): X must equal resting X.
-- Warns loudly instead of drifting silently.
local function _assertVertical(resting: UDim2, target: UDim2, where: string)
	if target.X.Scale ~= resting.X.Scale or target.X.Offset ~= resting.X.Offset then
				Debug.Warn('HudNotification', ('X drift at %s: resting=(%s,%s) target=(%s,%s)'):format(
				where,
				tostring(resting.X.Scale),
				tostring(resting.X.Offset),
				tostring(target.X.Scale),
				tostring(target.X.Offset)
			))
	end
end

local function _trackTween(tw: Tween)
	_activeTweens[#_activeTweens + 1] = tw
	pcall(function()
		tw:Play()
	end)
end

local function _isUsablePanel(obj: any): boolean
	return typeof(obj) == 'Instance' and (obj :: Instance):IsA('GuiObject') and (obj :: GuiObject).Parent ~= nil
end

-- Resolve the notification surface right now (never cached
-- blindly — the HUD can be recreated on respawn). Canonical
-- path is HUD.Center.Notifications (plural) via
-- HudTree.NotificationPanel (singular + legacy fallbacks
-- inside). A lone label works as its own panel (content writes
-- directly, Visible toggles on show/expiry). Returns nil when
-- any link of the chain is missing.
local function _resolvePanel(): GuiObject?
	if not localPlayer then
		return nil
	end
	local playerGui: Instance? = nil
	pcall(function()
		playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
	end)
	if playerGui == nil then
		return nil
	end
	local panel: GuiObject? = nil
	pcall(function()
		panel = HudTree.NotificationPanel(playerGui)
	end)
	if _isUsablePanel(panel) then
		return panel :: GuiObject
	end
	return nil
end

local function _isTextWriter(obj: Instance): boolean
	return obj:IsA('TextLabel') or obj:IsA('TextButton') or obj:IsA('TextBox')
end

-- Bind message/title writers for a panel instance. Named roles
-- first (Message/Text/Body/Description, Title/Header/Category),
-- then shallow fallbacks. Cached per panel instance.
local function _bindContent(panel: GuiObject)
	_msgLabel = nil
	_titleLabel = nil
	local messageNames: { [string]: boolean } = {
		Message = true,
		Text = true,
		Body = true,
		Description = true,
		Content = true,
	}
	local titleNames: { [string]: boolean } = {
		Title = true,
		Header = true,
		Category = true,
		Heading = true,
		Label = true,
	}
	pcall(function()
		for _, desc in ipairs(panel:GetDescendants()) do
			if _isTextWriter(desc) then
				if _msgLabel == nil and messageNames[desc.Name] then
					_msgLabel = desc :: TextLabel
				elseif _titleLabel == nil and titleNames[desc.Name] then
					_titleLabel = desc :: TextLabel
				end
				if _msgLabel ~= nil and _titleLabel ~= nil then
					break
				end
			end
		end
		if _msgLabel == nil then
			for _, desc in ipairs(panel:GetDescendants()) do
				if _isTextWriter(desc) then
					_msgLabel = desc :: TextLabel
					break
				end
			end
		end
	end)
end

local function _trimText(text: string): string
	local maxLen = 120
	pcall(function()
		local n = (NotificationConfig :: any).MaxTextLength
		if type(n) == 'number' and n > 0 then
			maxLen = n
		end
	end)
	if #text <= maxLen then
		return text
	end
	return text:sub(1, maxLen - 1) .. '…'
end

-- Ensure a live, bound panel. Re-resolves (and re-binds) when the
-- cached instance died; captures the resting position only while
-- idle so a mid-window HUD rebuild cannot bake a moved position
-- in as the new rest (no cumulative drift).
local function _ensurePanel(): GuiObject?
	local live = _resolvePanel()
	if not live then
		_panel = nil
		return nil
	end
	if live ~= _panel then
		_panel = live
		_bindContent(live)
		-- One-line binding census (proves WHICH instance owns
		-- notifications + whether its chain can render).
		pcall(function()
			local chain: { string } = {}
			local node: Instance? = live
			while typeof(node) == 'Instance' and (node :: Instance).Name ~= 'PlayerGui' do
				local seg = (node :: Instance).Name
				if (node :: Instance):IsA('GuiObject') then
					seg ..= ' visible=' .. tostring((node :: GuiObject).Visible)
				end
				table.insert(chain, seg)
				node = (node :: Instance).Parent
			end
			Debug.Warn('HudNotification', 
					(live :: Instance):GetFullName(),
					table.concat(chain, ' < ')
				)
		end)
		-- Fresh panel instance (e.g. HUD rebuilt on respawn):
		-- drop any in-flight window so the next Show runs a
		-- full entrance on the new instance.
		if _phase ~= 'idle' then
			_phase = 'idle'
			_cancelTweens()
		end
	end
	if _phase == 'idle' then
		pcall(function()
			_resting = (live :: GuiObject).Position
		end)
	end
	if _resting == nil then
		pcall(function()
			_resting = (live :: GuiObject).Position
		end)
	end
	return live
end

local function _setContent(panel: GuiObject, category: string, text: string)
	local body = _trimText(text)
	pcall(function()
		local msg = _msgLabel
		if msg ~= nil and msg.Parent ~= nil then
			-- RichText on (server sends rarity markup), body
			-- white by default; surrounding copy stays clean.
			msg.RichText = true
			msg.TextColor3 = Color3.fromRGB(255, 255, 255)
			msg.Text = body
			msg.TextTransparency = 0
		elseif _isTextWriter(panel) then
			local writer = panel :: TextLabel
			writer.RichText = true
			writer.TextColor3 = Color3.fromRGB(255, 255, 255)
			writer.Text = body
			writer.TextTransparency = 0
		end
	end)
	pcall(function()
		local title = _titleLabel
		if title ~= nil and title.Parent ~= nil and title ~= _msgLabel then
			title.Text = category
			title.TextColor3 = _categoryColor(category)
		end
	end)
end

-- Forward declaration: expiry arms call _startExit, which is
-- defined below (Lua resolves the upvalue at call time).
local _startExit: (number) -> ()

-- Arm (or re-arm) the rolling expiry for `gen`. Old arms die on
-- the generation check or re-arm when they find fresh expiry —
-- an old timer can never hide a newer notification.
local function _armExpiry(gen: number)
	local wait = _expiry - os.clock()
	task.delay(math.max(wait, 0) + RESTORE_BUFFER_SECONDS, function()
		if gen ~= _generation then
			return
		end
		if os.clock() < _expiry then
			_armExpiry(gen)
			return
		end
		_startExit(gen)
	end)
end

_startExit = function(gen: number)
	if gen ~= _generation or _phase == 'idle' then
		return
	end
	local raw = _panel
	if raw == nil or typeof(raw) ~= 'Instance' then
		_phase = 'idle'
		_panel = nil
		return
	end
	local panel = raw :: GuiObject
	if panel.Parent == nil then
		_phase = 'idle'
		_panel = nil
		return
	end
	_phase = 'exiting'
	_cancelTweens()
	local startPos = panel.Position
	local rest = _resting
	if rest == nil then
		rest = startPos
	end
	-- Y-only exit target; X verified identical to resting.
	local target = _withYOffset(rest, -EXIT_OFFSET_PX)
	_assertVertical(rest, target, 'exit')
	pcall(function()
		_trackTween(
			TweenService:Create(
				panel,
				TweenInfo.new(EXIT_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
				{ Position = target }
			)
		)
	end)
	task.delay(EXIT_SECONDS + RESTORE_BUFFER_SECONDS, function()
		-- Superseded mid-exit (a new arrival took over and is
		-- running its own restore): touch nothing.
		if gen ~= _generation or _phase ~= 'exiting' then
			return
		end
		local view = _panel
		if view == nil or typeof(view) ~= 'Instance' then
			_phase = 'idle'
			_panel = nil
			return
		end
		local gp = view :: GuiObject
		local home = _resting
		pcall(function()
			if home ~= nil then
				gp.Position = home
			end
			gp.Visible = false
		end)
		-- Give back ancestors borrowed for this window — but
		-- only while nothing else visible still needs them
		-- (shared Center stays up for other UI).
		HudTree.ReleaseChain(view)
		_phase = 'idle'
	end)
end

-- --- Public API -----------------------------------------------------------

-- Present a notification in the HUD panel. Returns true when the
-- panel owned it (caller skips any fallback display), false when
-- no usable panel exists.
function HudNotificationController.Show(category: string, text: string): boolean
	local handled = false
	pcall(function()
		local panel = _ensurePanel()
		if not panel then
			return
		end
		-- Content BEFORE visibility: never flash a stale message.
		-- Pre-bound locals: closures do not inherit the guard
		-- refinements, so everything a pcall touches is bound
		-- here with a concrete type.
		local view: GuiObject = panel
		_setContent(view, category, text)
		-- The Center chain (or legacy panel chain) must be up or
		-- the content paints invisibly; tracked so expiry can
		-- give shared ancestors back.
		HudTree.EnsureChainVisible(view)
		_generation += 1
		local gen = _generation
		_expiry = os.clock() + DISPLAY_DURATION
		if _phase == 'idle' then
			-- Fresh window: stage above (Y only), make visible
			-- FIRST, then one clean ease-in onto resting.
			-- Entrance runs exactly once per window.
			_phase = 'entering'
			_cancelTweens()
			local resting = _resting or view.Position
			local staged = _withYOffset(resting, -ENTER_OFFSET_PX)
			_assertVertical(resting, staged, 'enter')
			pcall(function()
				view.Position = staged
				view.Visible = true
				_trackTween(
					TweenService:Create(
						view,
						TweenInfo.new(DROP_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
						{ Position = resting }
					)
				)
			end)
			task.delay(DROP_SECONDS + RESTORE_BUFFER_SECONDS, function()
				if gen ~= _generation or _phase ~= 'entering' then
					return
				end
				-- Absolute restore: exact resting, so 1000
				-- windows later the panel is exact.
				pcall(function()
					view.Position = resting
				end)
				_phase = 'visible'
				_armExpiry(gen)
			end)
			handled = true
		elseif _phase == 'entering' or _phase == 'visible' then
			-- Entrance still running or already visible: message
			-- updated above, window extended. No movement, no
			-- re-entrance, no scale tricks.
			_armExpiry(gen)
			handled = true
		elseif _phase == 'exiting' then
			-- Cancel the exit: ease back onto resting (Y only).
			_phase = 'entering'
			_cancelTweens()
			local resting = _resting or view.Position
			_assertVertical(resting, resting, 'exit-restore')
			pcall(function()
				view.Visible = true
				_trackTween(
					TweenService:Create(
						view,
						TweenInfo.new(EXIT_CANCEL_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Position = resting }
					)
				)
			end)
			task.delay(EXIT_CANCEL_DELAY_SECONDS, function()
				if gen ~= _generation or _phase ~= 'entering' then
					return
				end
				_phase = 'visible'
				_armExpiry(gen)
			end)
			handled = true
		end
	end)
	return handled
end

function HudNotificationController.Init()
	-- Lifecycle is fully lazy (resolve per notification) so init
	-- order relative to HUD replication cannot break it, and no
	-- listeners are created here (ToastController owns the one
	-- Notify subscription). Present for bootstrap parity.
end

return table.freeze(HudNotificationController)
