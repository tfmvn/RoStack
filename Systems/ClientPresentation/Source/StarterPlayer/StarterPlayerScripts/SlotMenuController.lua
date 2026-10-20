--!strict
--!native
--[[
	SlotMenuController
	==================
	Phase 2.9 — client half of the slot interaction menus, plus
	the MAIN GAME direct-upgrade binding. Works against the EXACT
	Studio-authored hierarchy (never created, renamed, moved,
	resized, or restyled here — every lookup is FindFirstChild +
	IsA-checked and nil-safe, so a missing piece degrades to a
	dead menu, never an error):

	  MAIN GAME stand buttons (per stand, Studio-authored):
	    Stand.Slot.MenuPart.MenuGui.UpgradeButton (GuiButton)
	      -> DIRECT upgrade: fires SlotMenuAction
	         { SlotId, OccupantId, Action='Upgrade' } immediately.
	         No UpgradesFrame opens. The server revalidates +
	         transacts (SlotMenuService -> UpgradeService); the
	         server-painted Level/UpgradeAmount labels update via
	         replication.
	  Legacy workspace-menu buttons (old places only):
	    MenuPart.MenuGui.Frame.SellButton      -> open SellFrame
	    MenuPart.MenuGui.Frame.UpgradeButton   -> open UpgradesFrame
	  PlayerGui (Studio-authored, old places only):
	    MainGui.UpgradesFrame { Title, Name, CurrentLevel,
	      NewLevel, UpgradeButton [TextLabel display], CloseMenu }
	    MainGui.SellFrame { Title, Name, Level, Gen,
	      SellButton [TextLabel display], CloseMenu }

	Display + selection only: this controller NEVER computes money
	(it renders server-provided strings) and NEVER submits values.
	Sell confirm sends { SlotId, OccupantId }; the server
	re-resolves and transacts (SlotMenuService -> SlotActionHandler
	-> SellService). Direct upgrade sends { SlotId, OccupantId,
	Action='Upgrade' }; the server recalculates cost at confirm
	time and rejects maxed/stale/foreign contexts.

	Diagnostics (Phase 2.9.2): every stage prints a `[SlotMenu]`
	breadcrumb via print (client output) — startup, MainGui
	structure, per-slot discovery (paths, classes, SurfaceGui
	config, button properties, resolved slotId), binding, state
	transitions, clicks, requests, responses, opens, closes.
	Discovery/state logs run once / on-change only; clicks and
	remotes log per event. If the chain breaks, the last present
	log names the exact stage.

	Update model (all event-driven, §37-clean):
	  * open         -> SlotMenuRequest, render on SlotMenuState
	  * PlayerState  -> stale selection closes; open menu re-requests;
	                     slot button visibility syncs (§7-§8)
  * AnimalLeveledUp (owner-only, that animal) -> open upgrade
                     menu re-requests (XP level-ups move Level
                     with no slot transition, so no push follows)
                     + personal LevelUp sting (local PlayerGui
                     clone — only this client hears it; the
                     server plays no upgrade audio)
	  * stand cash-trigger CashPool attribute signal (selected slot only)
	                 -> re-request (reactive payout, §32)
	  * confirm      -> SlotMenuAction; SlotMenuResult closes +
	                     clears unconditionally (§30)
 	  * CloseMenus (ImageButton.Activated) -> hide + clear, fire
 	  nothing (§25-§27)
	No RenderStepped, no polling loops, no Workspace scans (menu
	buttons are discovered once per base assignment by bounded
	traversal of the player's own base folder only).
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace = game:GetService('Workspace')
local Debris = game:GetService('Debris')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

local SlotMenuController = {}

local localPlayer = Players.LocalPlayer
assert(localPlayer, 'SlotMenuController must run on the client')

-- Breadcrumb logger, routed through the central Debug module
-- (visible with ClientDebug on, silent otherwise).
local function _log(...: any)
	local parts: { string } = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	Debug.Log('SlotMenu', table.concat(parts, ' '))
end

-- --- Resolved UI handles (nil when the Studio UI is absent) ----------

local upgradesFrame: Frame? = nil
local sellFrame: Frame? = nil

local upTitle: TextLabel? = nil
local upName: TextLabel? = nil
local upCurrent: TextLabel? = nil
local upNew: TextLabel? = nil
-- Display labels (TextLabel in Studio): text updates only, never
-- input-bound. The upgrade confirm has no endpoint (no upgrade
-- economy exists) and the sell confirm goes through InputBegan
-- on the sell display (see confirm section).
local upConfirm: TextLabel? = nil
local upClose: GuiButton? = nil

local sellTitle: TextLabel? = nil
local sellName: TextLabel? = nil
local sellConfirm: TextLabel? = nil
local sellLevel: TextLabel? = nil
local sellGen: TextLabel? = nil
local sellClose: GuiButton? = nil

-- --- Selection ----------------------------------------------------------

-- { slotId, occupantId, kind, menu: 'sell'|'upgrade' } or nil.
-- Clearing never touches gameplay state (pure UI).
local _selection: { [string]: any }? = nil
local _knownBaseId: string? = nil
local _poolConnection: RBXScriptConnection? = nil

-- Slot menu buttons by stamped slotId: slotId -> { sell, upgrade }.
-- Scoped to the LOCAL player's base (discovery only walks that
-- folder). Visibility is shared-instance state: the owner is the
-- only actor (the server rejects everyone else), so the owner's
-- client driving it from authoritative occupancy is correct.
local _slotButtons: { [string]: { sell: GuiButton?, upgrade: GuiButton? } } = {}
local _warnedButtons: { [GuiButton]: boolean } = {}
local _lastSlots: any? = nil
-- Last applied visibility per slotId ("sell,upgrade" string) so
-- STATE logs fire on transitions only, not on every push.
local _lastVisibility: { [string]: string } = {}
-- MAIN GAME direct-upgrade buttons by stamped slotId (defined
-- here so _applyButtonVisibility can see the upvalue; bound in
-- _connectDirectUpgradeButton below).
local _directUpgradeButtons: { [string]: GuiButton } = {}

local function _clearSelection()
	_selection = nil
	if _poolConnection then
		_poolConnection:Disconnect()
		_poolConnection = nil
	end
end

local function _hideAll()
	if upgradesFrame then
		upgradesFrame.Visible = false
	end
	if sellFrame then
		sellFrame.Visible = false
	end
end

local function _closeAll()
	_hideAll()
	_clearSelection()
end

-- --- Remotes ---------------------------------------------------------------

local _requestEvent: RemoteEvent? = nil
local _actionEvent: RemoteEvent? = nil

local function _requestState(slotId: string, intent: string?)
	if _requestEvent then
		_requestEvent:FireServer({ SlotId = slotId, Intent = intent or 'refresh' })
	else
		_log('ERROR SlotMenuRequest remote missing; cannot request slot', slotId)
	end
end

-- --- Rendering (server strings only — never computed here) ------------------

local function _setText(label: TextLabel?, value: any)
	if label then
		label.Text = tostring(value)
	end
end

-- --- Reactive pool (selected slot only) --------------------------------------
--
-- The server mirrors each slot's CashPool into its cash trigger's
-- `CashPool` attribute (free replication): MAIN GAME
-- `Stand.Button.PressPart`, legacy `CashCollector`. Watching
-- THAT attribute re-renders the payout the moment income lands
-- — no polling, no scans. Resolution climbs from the pressed
-- button to the owning stand (see StandResolver); anything
-- unexpected is a silent no-op.

local function _collectorForButton(button: GuiButton): BasePart?
	return StandResolver.FindCollectorForMenuButton(button)
end

local function _watchPool(selection: { [string]: any }?)
	if _poolConnection then
		_poolConnection:Disconnect()
		_poolConnection = nil
	end
	if not selection then
		return
	end
	-- Pool only shapes animal payouts; lucky eggs have none.
	if selection.kind ~= 'animal' then
		return
	end
	local button = selection._sourceButton
	if typeof(button) ~= 'Instance' or not (button :: Instance):IsA('GuiButton') then
		return
	end
	local collector = _collectorForButton(button :: GuiButton)
	if not collector then
		_log('pool watch unavailable for slot', tostring(selection.slotId), '(no stand cash trigger resolved)')
		return
	end
	local slotId = selection.slotId
	_log('pool watch armed slot', tostring(slotId))
	_poolConnection = collector:GetAttributeChangedSignal('CashPool'):Connect(function()
		-- Pool moved under the open menu: re-read authoritative
		-- state (the server recomputes level + pool + payout).
		local current = _selection
		if current and current.slotId == slotId and current.menu == 'sell' then
			_log('pool changed slot', tostring(slotId), 're-requesting')
			_requestState(slotId, 'refresh-pool')
		end
	end)
end

local function _renderSell(state: any)
	if not sellFrame then
		_log('ERROR cannot open SellFrame: frame missing')
		return
	end
	_selection = { slotId = state.SlotId, occupantId = state.ObjectId, kind = state.Kind, menu = 'sell' }
	if state.Kind == 'egg' then
		_setText(sellTitle, 'Sell Egg')
		_setText(sellName, tostring(state.Rarity))
		_setText(sellLevel, '--')
		_setText(sellGen, '--')
	else
		_setText(sellTitle, 'Sell ' .. tostring(state.Name))
		_setText(sellName, state.Name)
		_setText(sellLevel, state.Level)
		_setText(sellGen, state.GenFormatted)
	end
	if sellConfirm then
		sellConfirm.Text = tostring(state.SellButtonText)
	end
	if upgradesFrame then
		upgradesFrame.Visible = false
	end
	sellFrame.Visible = true
	_log(
		'OPEN SellFrame slot',
		tostring(state.SlotId),
		'occupant',
		tostring(state.ObjectId),
		'kind',
		tostring(state.Kind)
	)
	_watchPool(_selection)
end

local function _renderUpgrades(state: any)
	if not upgradesFrame then
		_log('ERROR cannot open UpgradesFrame: frame missing')
		return
	end
	-- Eggs cannot be upgraded: never open the frame, and
	-- drop the intent so no stale selection lingers.
	if state.Kind ~= 'animal' then
		_log('REJECT upgrade because kind=' .. tostring(state.Kind), 'slot', tostring(state.SlotId))
		_clearSelection()
		return
	end
	_selection = { slotId = state.SlotId, occupantId = state.ObjectId, kind = state.Kind, menu = 'upgrade' }
	_setText(upTitle, 'Upgrade ' .. tostring(state.Name))
	_setText(upName, state.Name)
	_setText(upCurrent, state.Level)
	_setText(upNew, state.NewLevel)
	if upConfirm then
		-- Real authoritative cost text (or the max-level /
		-- unavailable state). Display value only — the server
		-- recalculates at confirm time. No Activated binding
		-- (TextLabel); confirm goes through InputBegan below.
		upConfirm.Text = tostring(state.UpgradeButtonText)
	end
	if sellFrame then
		sellFrame.Visible = false
	end
	upgradesFrame.Visible = true
	_log(
		'OPEN UpgradesFrame slot',
		tostring(state.SlotId),
		'animal',
		tostring(state.ObjectId),
		'level',
		tostring(state.Level),
		'cost',
		tostring(state.UpgradeCostRaw)
	)
end

local function _onMenuState(state: any)
	if type(state) ~= 'table' then
		return
	end
	if state.Valid ~= true then
		-- Slot emptied / occupant unknown: never render stale.
		_log('RESPONSE invalid slot', tostring(state.SlotId), 'closing')
		_closeAll()
		return
	end
	_log('RESPONSE slot', tostring(state.SlotId), 'kind', tostring(state.Kind), 'occupant', tostring(state.ObjectId))
	local pending = _selection
	-- Only render states for the currently requested slot; a
	-- late response for a previous selection is dropped.
	if pending and pending.slotId ~= state.SlotId then
		_log('RESPONSE dropped (stale selection) slot', tostring(state.SlotId))
		return
	end
	if not pending then
		-- No open intent (e.g. a stray re-request landed after
		-- close): do not pop a menu open.
		_log('RESPONSE dropped (no open intent) slot', tostring(state.SlotId))
		return
	end
	if pending.menu == 'sell' then
		_renderSell(state)
	elseif pending.menu == 'upgrade' then
		_renderUpgrades(state)
	end
end

-- Slot occupant rule (Phase 2.9.1 §7-§8, 2.9.2 §11-§15), GAME STATE
-- behavior: empty/reserved/unknown -> both buttons hidden; lucky
-- egg -> Sell visible, Upgrade hidden; animal -> both visible.
-- ONLY Visible is touched here — never text, size, color, font.
-- Runs on every PlayerState push (occupancy transitions push)
-- plus once after discovery, using the last payload. STATE logs
-- fire on transitions only.
local function _applyButtonVisibility()
	if type(_lastSlots) ~= 'table' then
		return
	end
	local byId: { [string]: any } = {}
	for _, s in ipairs(_lastSlots) do
		if type(s) == 'table' and type(s.Id) == 'string' then
			byId[s.Id] = s
		end
	end
	for slotId, entry in pairs(_slotButtons) do
		local live = byId[slotId]
		local kind = 'empty'
		local showSell = false
		local showUpgrade = false
		if live and live.State == 'Occupied' then
			if live.OccupantKind == 'animal' then
				kind = 'animal'
				showUpgrade = true
			elseif live.OccupantKind == 'egg' then
				kind = 'egg'
			end
		end
		-- No sell buttons anymore: selling lives on the
		-- animal's Sell prompt (eggs are not sellable). Any
		-- bound legacy SellButton is force-hidden here so a
		-- stale authored button can never afford selling.
		-- Animal stands show Upgrade only; eggs/empty show
		-- neither. No font/size/position/color changes, ever.
		if entry.sell then
			entry.sell.Visible = false
		end
		if entry.upgrade then
			entry.upgrade.Visible = showUpgrade
			if showUpgrade and entry.upgrade:IsA('TextButton') then
				(entry.upgrade :: TextButton).Text = 'Upgrade'
			end
		end
		local key = tostring(showSell) .. ',' .. tostring(showUpgrade)
		if _lastVisibility[slotId] ~= kind .. '|' .. key then
			_lastVisibility[slotId] = kind .. '|' .. key
			_log('STATE slot', slotId, 'kind', kind, 'sell', tostring(showSell), 'upgrade', tostring(showUpgrade))
		end
	end
	-- MAIN GAME direct-upgrade buttons: visible only on live
	-- animal stands (eggs cannot upgrade, empty stands show
	-- nothing). ONLY Visible is touched.
	for slotId, button in pairs(_directUpgradeButtons) do
		local live: any? = nil
		if type(byId) == 'table' then
			live = byId[slotId]
		end
		local show = live ~= nil and live.State == 'Occupied' and live.OccupantKind == 'animal'
		button.Visible = show
		local key = 'direct:' .. tostring(show)
		if _lastVisibility[slotId .. '#direct'] ~= key then
			_lastVisibility[slotId .. '#direct'] = key
			_log('STATE direct-upgrade slot', slotId, 'visible', tostring(show))
		end
	end
end

-- --- Slot menu buttons (one-time bounded discovery) ---------------------------
--
-- Runs once per base assignment over the player's OWN base folder
-- only (never Workspace-wide, never repeated). Every stage logs
-- (§31): MenuPart path, MenuGui config, Frame state, button
-- class/properties/text, resolved slotId, and BOUND lines.

local _wiredButtons: { [GuiButton]: boolean } = {}
local _wiredMenus: { [SurfaceGui]: boolean } = {}

local function _describeGui(gui: SurfaceGui, slotLabel: string)
	_log('MenuGui found path', gui:GetFullName(), slotLabel)
	_log('MenuGui.Enabled', tostring(gui.Enabled), 'Adornee', tostring(gui.Adornee), 'Face', tostring(gui.Face))
end

local function _describeButton(button: GuiButton, role: string, slotLabel: string)
	_log(role, 'found path', button:GetFullName(), slotLabel)
	_log(role, 'class', button.ClassName, slotLabel)
	_log(
		role,
		'visible',
		tostring(button.Visible),
		'active',
		tostring(button.Active),
		'selectable',
		tostring(button.Selectable),
		'zIndex',
		tostring(button.ZIndex),
		'size',
		tostring(button.AbsoluteSize),
		'position',
		tostring(button.AbsolutePosition)
	)
	if button:IsA('TextButton') then
		_log(role, 'Text', (button :: TextButton).Text, slotLabel)
	end
end

-- MAIN GAME direct-upgrade buttons by stamped slotId:
-- slotId -> UpgradeButton (GuiButton directly under MenuGui).
-- Pressing one fires the upgrade request IMMEDIATELY — no
-- UpgradesFrame opens. Kept separate from the legacy
-- sell/upgrade open-frame map above.
-- (Map declared next to _slotButtons; bound in
-- _connectDirectUpgradeButton below.)

-- Resolve the live occupant for a direct-upgrade press from the
-- last authoritative PlayerState payload. Returns
-- (slotId, occupantId) or (nil, nil) when the slot is not a
-- live animal slot (stale/egg/empty presses are dropped
-- locally; the server would reject them anyway).
local function _resolveDirectUpgradeTarget(slotId: string): (string?, string?)
	if type(_lastSlots) ~= 'table' then
		return nil, nil
	end
	for _, s in ipairs(_lastSlots) do
		if type(s) == 'table' and s.Id == slotId then
			if s.State == 'Occupied' and s.OccupantKind == 'animal' and type(s.OccupantId) == 'string' then
				return slotId, s.OccupantId
			end
			return nil, nil
		end
	end
	return nil, nil
end

local function _connectDirectUpgradeButton(button: GuiButton): boolean
	if _wiredButtons[button] then
		return false
	end
	_wiredButtons[button] = true
	local slotId = button:GetAttribute('slotId')
	if type(slotId) ~= 'string' or slotId == '' then
		if not _warnedButtons[button] then
			_warnedButtons[button] = true
			_log('ERROR direct UpgradeButton has no resolvable SlotId path', button:GetFullName())
		end
		return false
	end
	_directUpgradeButtons[slotId] = button
	_applyButtonVisibility()
	button.Activated:Connect(function()
		-- Max-level guard is local UX only: skip the pointless
		-- request. The server still validates MaxLevel on
		-- every request regardless of this attribute.
		if button:GetAttribute('maxed') == true then
			_log('direct upgrade ignored (maxed) slot', slotId)
			return
		end
		local targetSlot, occupantId = _resolveDirectUpgradeTarget(slotId)
		if targetSlot == nil or occupantId == nil then
			_log('direct upgrade ignored (no live animal) slot', slotId)
			return
		end
		_log('CLICK direct UpgradeButton slot', slotId, 'occupant', occupantId)
		Debug.Log('UpgradeTrace', ('[CLIENT] Activated slot=%s animal=%s'):format(targetSlot, occupantId))
		-- Record the intent so SlotMenuResult can be matched
		-- to this press. No frame opens — rendering waits for
		-- the server-painted stand labels + PlayerState push.
		_selection = { slotId = targetSlot, occupantId = occupantId, kind = 'animal', menu = 'direct-upgrade' }
		if _actionEvent then
			Debug.Log('UpgradeTrace', ('[CLIENT] Activated slot=%s animal=%s'):format(
					targetSlot,
					occupantId
				))
			_actionEvent:FireServer({ SlotId = targetSlot, OccupantId = occupantId, Action = 'Upgrade' })
		else
			_log('ERROR SlotMenuAction remote missing; cannot upgrade')
		end
	end)
	_log('BOUND direct UpgradeButton slot', slotId)
	return true
end

local function _connectSlotButton(button: GuiButton, intent: string): boolean
	if _wiredButtons[button] then
		return false
	end
	_wiredButtons[button] = true
	local slotId = button:GetAttribute('slotId')
	if type(slotId) ~= 'string' or slotId == '' then
		-- Phase 2.9.1 §26: never silent. The server stamps slotId
		-- on assignment; a button without one can never route, so
		-- say so loudly in output (once per button).
		if not _warnedButtons[button] then
			_warnedButtons[button] = true
			_log('ERROR menu button has no resolvable SlotId path', button:GetFullName())
		end
		return false
	end
	-- Sell intents are never bound: selling lives on the
	-- animal's Sell prompt (eggs are not sellable). Refuse
	-- loudly so a stray call site can never wire selling.
	if intent == 'sell' then
		_log('REFUSED sell bind slot', slotId, '(selling lives on the Sell prompt)')
		return false
	end
	local entry = _slotButtons[slotId]
	if not entry then
		entry = { sell = nil, upgrade = nil }
		_slotButtons[slotId] = entry
	end
	entry.upgrade = button
	_applyButtonVisibility()
	local action = intent
	button.Activated:Connect(function()
		_log('CLICK UpgradeButton slot', slotId)
		-- Record open intent, then ask the server. Rendering
		-- waits for SlotMenuState (never rendered from local
		-- guesses); exclusivity flips only on render.
		_selection = { slotId = slotId, occupantId = nil, kind = nil, menu = intent, _sourceButton = button }
		_log('sending', action, 'request slot', slotId)
		_requestState(slotId, 'open-' .. intent)
	end)
	_log('BOUND', action, 'Button slot', slotId)
	return true
end

-- Bind one runtime MenuGui (MAIN GAME shape first, legacy
-- Frame shape second). Returns buttons newly bound (0+).
-- The slot/animal identity comes from the server-stamped
-- `slotId` attribute on the button itself (set at clone time
-- by StandDisplayService, or at assignment for authored
-- buttons) — never inferred from screen position. Idempotent:
-- already-wired buttons/buttons without slotId bind nothing.
local function _bindMenuGui(descendant: SurfaceGui): number
	local bound = 0
	local menuPart = descendant.Parent
	local partPath = menuPart and menuPart:GetFullName() or 'MISSING-PARENT'
	_log('discovered MenuPart path', partPath)
	_describeGui(descendant, 'slot=pending')
	-- MAIN GAME shape: UpgradeButton parented DIRECTLY
	-- to the MenuGui (no Frame). This is the direct
	-- upgrade interaction: press upgrades immediately,
	-- no UpgradesFrame ever opens.
	local directUpgrade = descendant:FindFirstChild('UpgradeButton')
	local hasDirect = directUpgrade ~= nil and directUpgrade:IsA('GuiButton')
	if hasDirect then
		_describeButton(directUpgrade :: GuiButton, 'UpgradeButton(direct)', 'slot=pending')
		if _connectDirectUpgradeButton(directUpgrade :: GuiButton) then
			bound += 1
		end
	end
	-- SellButtons are never bound: selling lives on the
	-- animal's Sell prompt (eggs are not sellable). A
	-- legacy authored SellButton is hidden so it can
	-- never afford selling (server rejects menu sells
	-- anyway).
	local directSell = descendant:FindFirstChild('SellButton')
	if directSell ~= nil and directSell:IsA('GuiObject') then
		(directSell :: GuiObject).Visible = false
	end
	-- Late-cloned template buttons (server reconciles
	-- mid-session on pickup/place/upgrade): bind on
	-- arrival, event-driven — no polling, no rescans.
	if not _wiredMenus[descendant] then
		_wiredMenus[descendant] = true
		descendant.ChildAdded:Connect(function(child: Instance)
			if child.Name == 'UpgradeButton' and child:IsA('GuiButton') then
				_connectDirectUpgradeButton(child :: GuiButton)
				_applyButtonVisibility()
			elseif child.Name == 'SellButton' and child:IsA('GuiObject') then
				(child :: GuiObject).Visible = false
				_applyButtonVisibility()
			end
		end)
	end
	-- Legacy shape: buttons nested under a Frame (old
	-- places: open-frame sell/upgrade flow). Kept so
	-- old places keep working; stands with a direct
	-- UpgradeButton skip this branch entirely (they
	-- have no Frame by design — not an error).
	if hasDirect then
		return bound
	end
	local frame = descendant:FindFirstChild('Frame')
	if frame and frame:IsA('GuiObject') then
		_log(
			'Frame found path',
			frame:GetFullName(),
			'visible',
			tostring((frame :: GuiObject).Visible),
			'active',
			tostring((frame :: GuiObject).Active)
		)
	else
		_log('Frame absent under', descendant:GetFullName(), '(legacy open-frame flow unavailable)')
	end
	local sellButton = frame and frame:FindFirstChild('SellButton')
	if sellButton and sellButton:IsA('GuiObject') then
		-- Legacy sell buttons are never bound (see
		-- above): hide so old places afford Upgrade only.
		(sellButton :: GuiObject).Visible = false
	end
	local upgradeButton = frame and frame:FindFirstChild('UpgradeButton')
	if upgradeButton and upgradeButton:IsA('GuiButton') then
		_describeButton(upgradeButton :: GuiButton, 'UpgradeButton', 'slot=pending')
		if _connectSlotButton(upgradeButton :: GuiButton, 'upgrade') then
			bound += 1
		end
	elseif frame then
		_log(
			'UpgradeButton is not a GuiButton under',
			descendant:GetFullName(),
			'found',
			tostring(upgradeButton and upgradeButton.ClassName or 'MISSING')
		)
	end
	return bound
end

-- Base folders already fitted with the late-arrival watcher
-- (one DescendantAdded connection per folder, not per menu).
local _watchedBases: { [Instance]: boolean } = {}
-- Menus found by the last discovery pass (drives the
-- zero-menu retry in _onPlayerState).
local _lastMenuCount = 0

local function _discoverBaseButtons(baseId: string): number?
	-- MAIN GAME: bases live under `Workspace.Map.Bases`
	-- (same centralized lookup the server uses).
	_log('scanning runtime animal stands base', baseId)
	local bases = StandResolver.GetBasesFolder(Workspace)
	local baseFolder = bases and bases:FindFirstChild(baseId)
	if not baseFolder then
		_log('ERROR base folder missing for BaseId', baseId)
		return nil
	end
	-- Late-arriving stands / MenuGuis / buttons (stands are
	-- cloned after assignment; template buttons are cloned on
	-- occupy): bind on arrival, event-driven. Covers every
	-- ordering — whole-stand subtrees (button event may fire
	-- before the MenuGui branch runs) and buttons cloned
	-- into an already-bound MenuGui (also covered by the
	-- per-MenuGui ChildAdded hook in _bindMenuGui).
	if not _watchedBases[baseFolder] then
		_watchedBases[baseFolder] = true
		baseFolder.DescendantAdded:Connect(function(desc: Instance)
			if desc:IsA('SurfaceGui') and desc.Name == 'MenuGui' then
				_bindMenuGui(desc)
				if _lastMenuCount == 0 then
					_lastMenuCount = 1
				end
				_applyButtonVisibility()
			elseif desc:IsA('GuiButton') and desc.Name == 'UpgradeButton' then
				local parent = desc.Parent
				if parent ~= nil and parent:IsA('SurfaceGui') and parent.Name == 'MenuGui' then
					if _connectDirectUpgradeButton(desc) then
						_log('bound upgrade slot=late-arrival', desc:GetFullName())
					end
					_applyButtonVisibility()
				end
			end
		end)
	end
	local menuCount = 0
	local boundCount = 0
	-- Arena stands are first-class slots: their MenuGui
	-- buttons bind exactly like normal stands (server stamps
	-- arena slotIds on assign and validates them
	-- server-side). No subtree is skipped.
	for _, descendant in ipairs(baseFolder:GetDescendants()) do
		if descendant:IsA('SurfaceGui') and descendant.Name == 'MenuGui' then
			menuCount += 1
			boundCount += _bindMenuGui(descendant)
		end
	end
	_log('total slot menus discovered', tostring(menuCount), 'buttons bound', tostring(boundCount))
	_log('total upgrade buttons bound', tostring(boundCount))
	_applyButtonVisibility()
	return menuCount
end

-- --- PlayerState: stale close + reactive refresh -----------------------------------
-- The payload's Slots array is authoritative for occupancy. If the
-- selected occupant is gone (sold/opened/picked/moved), the menu
-- closes instead of displaying stale state. Otherwise an open menu
-- re-requests (level/money-affecting transitions refresh it).

local function _onPlayerState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	if type(payload.BaseId) == 'string' and (payload.BaseId ~= _knownBaseId or _lastMenuCount == 0) then
		-- (Re)discover when the base changes OR the last pass
		-- found zero menus: stands/MenuGuis replicate after the
		-- first PlayerState push, and a one-shot scan would
		-- otherwise bind nothing forever. Event-driven (only on
		-- PlayerState pushes, only while zero); the
		-- DescendantAdded watcher covers arrivals between
		-- pushes.
		local found = _discoverBaseButtons(payload.BaseId)
		if found ~= nil then
			_knownBaseId = payload.BaseId
			_lastMenuCount = found
		end
	end
	-- Cache occupancy for button visibility, then sync (§7-§8).
	if type(payload.Slots) == 'table' then
		_lastSlots = payload.Slots
		_applyButtonVisibility()
	end
	local current = _selection
	if not current or type(current.slotId) ~= 'string' then
		return
	end
	local slots = payload.Slots
	if type(slots) ~= 'table' then
		return
	end
	local live: any? = nil
	for _, s in ipairs(slots) do
		if type(s) == 'table' and s.Id == current.slotId then
			live = s
			break
		end
	end
	if not live or live.State ~= 'Occupied' then
		_log('stale selection (slot not occupied) slot', tostring(current.slotId), 'closing')
		_closeAll()
		return
	end
	if current.occupantId ~= nil and live.OccupantId ~= current.occupantId then
		_log('stale selection (occupant changed) slot', tostring(current.slotId), 'closing')
		_closeAll()
		return
	end
	-- MAIN GAME direct-upgrade intents own no frame: the first
	-- authoritative push after the press settles them. Clear the
	-- intent without re-requesting (the server-painted stand
	-- labels + this push are the feedback); never poll.
	if current.menu == 'direct-upgrade' then
		_clearSelection()
		return
	end
	-- Still valid: refresh preview data (covers moves that kept
	-- occupancy, level-ups that pushed, and money transitions).
	if current.occupantId ~= nil then
		_requestState(current.slotId, 'refresh-push')
	end
end

-- --- Level-up: reactive upgrade preview --------------------------------------
--
-- XP level-ups (arena rewards, /givexp) mutate Level without a
-- slot transition, so no PlayerState push follows them — the
-- server fires AnimalLeveledUp (owner-only) instead. An open
-- upgrade menu for THAT animal re-requests its preview, so the
-- button shows the new level + next cost immediately. Any
-- other animal (or no open menu) is ignored: reopening always
-- re-resolves current state server-side anyway. No polling.

local function _onAnimalLeveledUp(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	local current = _selection
	if not current or current.menu ~= 'upgrade' then
		return
	end
	if type(current.slotId) ~= 'string' or type(current.occupantId) ~= 'string' then
		return
	end
	-- Stable occupant identity (slots survive level-ups; a
	-- changed occupant is closed by _onPlayerState instead).
	if payload.AnimalId ~= current.occupantId then
		return
	end
	_log('level-up animal', tostring(payload.AnimalId), 'slot', tostring(current.slotId), 're-requesting')
	_requestState(current.slotId, 'refresh-level')
end

-- Personal upgrade sting (client-LOCAL audio). The server
-- celebrates every level-up with global BOP/VFX but plays NO
-- audio (a Workspace sting would be audible to every nearby
-- player); instead it FireClients ONLY the owner via
-- AnimalLeveledUp, and this handler — the single
-- AnimalLeveledUp sound listener on this client — plays the
-- mirrored LevelUp template as a 2D PlayerGui clone only
-- this player hears. Never throws; silent no-op when the
-- template or PlayerGui is missing.
-- State-gated like the old server path: the sting fires only
-- on a real level increase (OldLevel nil = unknown = play;
-- otherwise NewLevel must exceed OldLevel).
local _levelUpSfxWarned = false
local function _playLevelUpSting(payload: any)
	pcall(function()
		if type(payload) ~= 'table' then
			return
		end
		local oldLevel = payload.OldLevel
		local newLevel = payload.NewLevel
		if type(oldLevel) == 'number' and type(newLevel) == 'number' and newLevel <= oldLevel then
			return
		end
		local assets = ReplicatedStorage:FindFirstChild('Assets')
		local sfx = assets and (assets :: Instance):FindFirstChild('Sfx') or nil
		local template = sfx and (sfx :: Instance):FindFirstChild('LevelUp') or nil
		if template == nil or not (template :: Instance):IsA('Sound') then
			if not _levelUpSfxWarned then
				_levelUpSfxWarned = true
				_log('WARN level-up sting template missing (ReplicatedStorage.Assets.Sfx.LevelUp); upgrades run silent')
			end
			return
		end
		if localPlayer == nil then
			return
		end
		local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local clone = ((template :: Instance) :: Sound):Clone()
		clone.Name = 'LevelUpSting'
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = playerGui
		clone:Play()
		local length = 3
		pcall(function()
			local t = (clone :: Sound).TimeLength
			if type(t) == 'number' and t == t and t > 0 then
				length = t + 0.5
			end
		end)
		Debris:AddItem(clone, length)
	end)
end

-- --- Confirm + close ---------------------------------------------------------------

-- Shared confirm from a display label (sell payout / upgrade
-- cost). Both are TextLabels: press-type inputs only
-- (mouse/touch/gamepad), identity-only payload. `menu` selects
-- the endpoint flavor: 'sell' sends no Action (legacy sell
-- path), 'upgrade' sends Action = 'Upgrade'.
local function _confirmFromDisplay(_displayBtn: TextLabel, menu: string)
	return function(input: InputObject)
		local t = input.UserInputType
		if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
			if t ~= Enum.UserInputType.Gamepad1 then
				return
			end
		end
		local current = _selection
		if not current or current.menu ~= menu then
			_log('confirm ignored (no ' .. menu .. ' selection)')
			return
		end
		if type(current.slotId) ~= 'string' or type(current.occupantId) ~= 'string' then
			_log('confirm ignored (incomplete selection)')
			return
		end
		if menu == 'upgrade' then
			_log('confirming upgrade slot', tostring(current.slotId), 'occupant', tostring(current.occupantId))
		else
			_log('confirming sale slot', tostring(current.slotId), 'occupant', tostring(current.occupantId))
		end
		if _actionEvent then
			if menu == 'upgrade' then
				_actionEvent:FireServer({ SlotId = current.slotId, OccupantId = current.occupantId, Action = 'Upgrade' })
			else
				_actionEvent:FireServer({ SlotId = current.slotId, OccupantId = current.occupantId })
			end
		else
			_log('ERROR SlotMenuAction remote missing; cannot confirm')
		end
	end
end

local function _onMenuResult(result: any)
	if type(result) ~= 'table' then
		return
	end
	local current = _selection
	-- MAIN GAME direct-upgrade results own no frame: log and
	-- clear. The server-painted stand labels + the follow-up
	-- PlayerState push carry the new level/cost.
	if current and current.menu == 'direct-upgrade' then
		if result.Success == true then
			Debug.Log('UpgradeTrace', 
					tostring(current.slotId),
					tostring(current.occupantId),
					tostring(result.NewLevel),
					tostring(result.Cost)
				)
			_log(
				'DIRECT UPGRADE SUCCESS animal',
				tostring(current.occupantId),
				'newLevel',
				tostring(result.NewLevel),
				'cost',
				tostring(result.Cost)
			)
		else
			Debug.Log('UpgradeTrace', 
					tostring(current.slotId),
					tostring(current.occupantId),
					tostring(result.Error)
				)
			_log('DIRECT UPGRADE FAILED reason', tostring(result.Error))
		end
		_clearSelection()
		return
	end
	if result.Success == true then
		-- Upgrade success: the menu STAYS OPEN — only the
		-- CloseMenu button closes it. Re-request so the frame
		-- immediately shows the new level and next cost (a
		-- PlayerState push follows anyway and would refresh
		-- too, but this is instant).
		if current and current.menu == 'upgrade' then
			_log(
				'UPGRADE SUCCESS animal',
				tostring(current.occupantId),
				'newLevel',
				tostring(result.NewLevel),
				'cost',
				tostring(result.Cost)
			)
			_log('UPGRADE menu stays open; refreshing')
			if type(current.slotId) == 'string' then
				_requestState(current.slotId, 'refresh-push')
			end
			return
		end
		-- Sale success: the object is gone, so close. (The
		-- follow-up push would close it as stale regardless.)
		_log('CLOSE menus (sale resolved)')
		_closeAll()
		return
	end
	-- Failure moved nothing: keep the frame open and refresh from
	-- authoritative state (§35) instead of showing stale values.
	if current and current.menu == 'upgrade' then
		_log('UPGRADE FAILED reason', tostring(result.Error))
	else
		_log('confirm rejected; refreshing')
	end
	if current and type(current.slotId) == 'string' then
		_requestState(current.slotId, 'refresh-push')
	else
		_closeAll()
	end
end

-- --- MainGui resolution (exact Studio hierarchy, nil-safe) ----------------------------

local function _childClass(parent: Instance?, name: string): string
	if not parent then
		return 'NO-PARENT'
	end
	local child = parent:FindFirstChild(name)
	if not child then
		return 'MISSING'
	end
	return child.ClassName
end

-- Wait for one named child, event-driven with a bounded timeout
-- (Roblox resolves this internally via ChildAdded — no Lua
-- polling, no RenderStepped). Returns the child or nil on
-- expiry, logging exactly which path failed.
local function _awaitChild(parent: Instance, name: string, timeoutSeconds: number): Instance?
	local found = parent:WaitForChild(name, timeoutSeconds)
	if not found then
		_log('ERROR timeout waiting for', parent:GetFullName() .. '.' .. name)
	end
	return found
end

local function _awaitLabel(parent: Instance?, name: string): TextLabel?
	if not parent then
		return nil
	end
	local child = _awaitChild(parent, name, 5)
	if child and child:IsA('TextLabel') then
		return child
	end
	if child then
		_log('ERROR', name, 'is not a TextLabel, found', child.ClassName, 'under', parent:GetFullName())
	end
	return nil
end

local function _awaitButton(parent: Instance?, name: string): GuiButton?
	if not parent then
		return nil
	end
	local child = _awaitChild(parent, name, 5)
	if child and child:IsA('GuiButton') then
		return child
	end
	if child then
		_log('ERROR', name, 'is not a GuiButton, found', child.ClassName, 'under', parent:GetFullName())
	end
	return nil
end

-- Resolve the Studio-authored menu root under the RUNTIME PlayerGui
-- (never StarterGui). Canonical name is MainGui; the live place
-- carries it as Main, so Main is accepted as fallback. Waits
-- instead of single-checking: at client start the Screens may
-- not have cloned into PlayerGui yet, and a single
-- FindFirstChild would permanently (and silently) disable the
-- menus — the exact race this fixes.
--
-- Physical stand buttons NEVER depend on this root: they live
-- in Workspace and bind independently (see _discoverBaseButtons).
-- UpgradesFrame/SellFrame are OPTIONAL legacy frames: a missing
-- frame only disables its open-frame flow (renderers nil-guard),
-- never the physical direct-upgrade binding. This function
-- therefore ALWAYS returns true once PlayerGui exists — the
-- "menus inert" early-return is gone by design.
local function _resolveMainGui(playerGui: Instance): boolean
	_log('PlayerGui found')
	local gui = playerGui:FindFirstChild('MainGui')
	if gui == nil then
		gui = playerGui:FindFirstChild('Main')
	end
	if not gui then
		_log('menu root not available yet; waiting for PlayerGui child')
		gui = _awaitChild(playerGui, 'MainGui', 5)
		if gui == nil then
			gui = _awaitChild(playerGui, 'Main', 10)
		end
	end
	if not gui then
		_log('menu root (MainGui/Main) absent under PlayerGui; physical stand buttons bind without it')
		-- Diagnostic: list what IS directly under PlayerGui so a
		-- renamed/restructured Studio GUI is visible in the log
		-- instead of a bare timeout (no polling — one snapshot).
		pcall(function()
			local names: { string } = {}
			for _, child in ipairs(playerGui:GetChildren()) do
				names[#names + 1] = child.Name .. ':' .. child.ClassName
			end
			_log('PlayerGui children', table.concat(names, ', '))
		end)
		return true
	end
	_log('menu root found PlayerGui.' .. gui.Name)
	-- Optional legacy frames: short bounded waits, NEVER fatal.
	-- A missing frame only disables its own open-frame flow;
	-- physical direct-upgrade binding proceeds regardless.
	local upgrades = gui:FindFirstChild('UpgradesFrame')
	if upgrades == nil then
		upgrades = _awaitChild(gui, 'UpgradesFrame', 3)
	end
	local sell = gui:FindFirstChild('SellFrame')
	if sell == nil then
		sell = _awaitChild(gui, 'SellFrame', 3)
	end
	_log('SellFrame found', tostring(sell ~= nil))
	_log('UpgradesFrame found', tostring(upgrades ~= nil))
	if upgrades and upgrades:IsA('Frame') then
		upgradesFrame = upgrades
		_log('UpgradesFrame class', upgrades.ClassName)
		for _, name in ipairs({ 'Title', 'Name', 'CurrentLevel', 'NewLevel', 'UpgradeButton', 'CloseMenu' }) do
			_log('UpgradesFrame ' .. name, 'class', _childClass(upgrades, name))
		end
		upTitle = _awaitLabel(upgrades, 'Title')
		upName = _awaitLabel(upgrades, 'Name')
		upCurrent = _awaitLabel(upgrades, 'CurrentLevel')
		upNew = _awaitLabel(upgrades, 'NewLevel')
		upConfirm = _awaitLabel(upgrades, 'UpgradeButton')
		upClose = _awaitButton(upgrades, 'CloseMenu')
		if upClose then
			_log('UpgradesFrame.CloseMenu found')
		end
	elseif upgrades then
		_log('UpgradesFrame present but is not a Frame, found', upgrades.ClassName, '(open-upgrade flow disabled)')
	end
	if sell and sell:IsA('Frame') then
		sellFrame = sell
		_log('SellFrame class', sell.ClassName)
		for _, name in ipairs({ 'Title', 'Name', 'Level', 'Gen', 'SellButton', 'CloseMenu' }) do
			_log('SellFrame ' .. name, 'class', _childClass(sell, name))
		end
		sellTitle = _awaitLabel(sell, 'Title')
		sellName = _awaitLabel(sell, 'Name')
		sellConfirm = _awaitLabel(sell, 'SellButton')
		sellLevel = _awaitLabel(sell, 'Level')
		sellGen = _awaitLabel(sell, 'Gen')
		sellClose = _awaitButton(sell, 'CloseMenu')
		if sellClose then
			_log('SellFrame.CloseMenu found')
		end
	elseif sell then
		_log('SellFrame present but is not a Frame, found', sell.ClassName, '(open-sell flow disabled)')
	end
	-- Always true: optional frames never gate physical binding.
	return true
end

-- --- Public API ---------------------------------------------------------

local _initialized = false

function SlotMenuController.Init()
	if _initialized then
		return
	end
	_log('controller started')
	Remotes.WaitForReady()
	local folder = Remotes.WaitForReady()
	local stateEvent = folder:WaitForChild(Remotes.Names.SlotMenuState, 10)
	if stateEvent and stateEvent:IsA('RemoteEvent') then
		local stateRe = stateEvent :: RemoteEvent
		stateRe.OnClientEvent:Connect(_onMenuState)
	else
		_log('ERROR SlotMenuState remote missing')
	end
	local resultEvent = folder:WaitForChild(Remotes.Names.SlotMenuResult, 10)
	if resultEvent and resultEvent:IsA('RemoteEvent') then
		local resultRe = resultEvent :: RemoteEvent
		resultRe.OnClientEvent:Connect(_onMenuResult)
	else
		_log('ERROR SlotMenuResult remote missing')
	end
	local requestFolder = folder:WaitForChild(Remotes.Names.SlotMenuRequest, 10)
	if requestFolder and requestFolder:IsA('RemoteEvent') then
		_requestEvent = requestFolder :: RemoteEvent
	else
		_log('ERROR SlotMenuRequest remote missing')
	end
	local actionFolder = folder:WaitForChild(Remotes.Names.SlotMenuAction, 10)
	if actionFolder and actionFolder:IsA('RemoteEvent') then
		_actionEvent = actionFolder :: RemoteEvent
	else
		_log('ERROR SlotMenuAction remote missing')
	end
	local statePayload = folder:WaitForChild(Remotes.Names.PlayerState, 10)
	if statePayload and statePayload:IsA('RemoteEvent') then
		local stateRe2 = statePayload :: RemoteEvent
		stateRe2.OnClientEvent:Connect(_onPlayerState)
	else
		_log('ERROR PlayerState remote missing')
	end
	local leveledPayload = folder:WaitForChild(Remotes.Names.AnimalLeveledUp, 10)
	if leveledPayload and leveledPayload:IsA('RemoteEvent') then
		local leveledRe = leveledPayload :: RemoteEvent
		leveledRe.OnClientEvent:Connect(_onAnimalLeveledUp)
		-- Personal-audio listener (exactly one per client):
		-- plays the local upgrade sting for every owner
		-- level-up, independent of menu state (the menu
		-- refresh above intentionally ignores closed menus).
		leveledRe.OnClientEvent:Connect(_playLevelUpSting)
	else
		_log('ERROR AnimalLeveledUp remote missing')
	end

	-- MainGui is Studio-authored under the RUNTIME PlayerGui
	-- (never StarterGui). StarterGui content clones in
	-- asynchronously, so resolve with waits — never a single
	-- FindFirstChild that would permanently disable the menus.
	local playerGui = localPlayer:WaitForChild('PlayerGui', 10)
	if not playerGui then
		_log('ERROR PlayerGui did not replicate; menus inert')
		return
	end
	-- Menu-root resolution is optional and NEVER gates physical
	-- stand-button binding (Workspace buttons bind off PlayerState
	-- regardless of PlayerGui frames). Always proceeds.
	_resolveMainGui(playerGui)
	_initialized = true
	_hideAll()

	-- Close buttons (ImageButton) close ONLY (never transact,
	-- never remote).
	if upClose then
		local closeBtn = upClose
		closeBtn.Activated:Connect(function()
			_log('CLOSE UpgradesFrame')
			_closeAll()
		end)
	else
		_log('UpgradesFrame.CloseMenu absent (open-upgrade flow disabled)')
	end
	if sellClose then
		local closeBtn = sellClose
		closeBtn.Activated:Connect(function()
			_log('CLOSE SellFrame')
			_closeAll()
		end)
	else
		_log('SellFrame.CloseMenu absent (open-sell flow disabled)')
	end
	-- Sell confirm: SellFrame.SellButton is a TextLabel (display
	-- only — no Activated event exists), so the press is detected
	-- via InputBegan for press-type inputs (mouse/touch/gamepad).
	-- This binds NO new input surface beyond reading the press;
	-- the server still recalculates and validates everything at
	-- confirm time, and the payout text was preview only.
	if sellConfirm then
		local displayBtn = sellConfirm
		displayBtn.InputBegan:Connect(_confirmFromDisplay(displayBtn, 'sell'))
	end
	-- Upgrade confirm: same TextLabel-display shape as the sell
	-- confirm (no Activated event exists). Pressing the cost
	-- display sends { SlotId, OccupantId, Action = 'Upgrade' };
	-- the server revalidates kind/owner/level/money and charges
	-- the recalculated cost. At MaxLevel (or unknown cost) the
	-- display shows the unavailable state and there is nothing
	-- valid to confirm — the press is ignored locally, and the
	-- server would reject it anyway.
	if upConfirm then
		local displayBtn = upConfirm
		displayBtn.InputBegan:Connect(_confirmFromDisplay(displayBtn, 'upgrade'))
	end
	_log('GUI initialization complete')
end

return table.freeze(SlotMenuController)
