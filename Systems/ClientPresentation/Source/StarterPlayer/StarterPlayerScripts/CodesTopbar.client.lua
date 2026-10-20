--!strict
--!native
--[[
	CodesTopbar.client
	==================
	FAST UI BOOT: the TopbarPlus Codes icon. Standalone
	LocalScript — deliberately NOT wired through
	bootstrap.client.lua — so it never waits on the slow game
	bootstrap (CmdrClient replication, Remotes, profile, base,
	animals, arena, rebirth, or any server system). Same
	integration as SettingsTopbar.client.lua (same package,
	same singleton pattern, same selected/deselected ownership
	of panel visibility); only the target panel and glyph
	differ. Icon-only: no setLabel call (matches the Settings
	icon), so the topbar shows the glyph alone.

	Each LocalScript in StarterPlayerScripts runs on its own
	thread: bootstrap.client.lua can block indefinitely on
	`WaitForChild('CmdrClient')` while this script binds the
	Codes icon as soon as its ONLY real dependencies exist:

	  PlayerGui.Main.Codes  (Studio-authored UI)
	  ReplicatedStorage.Packages.TopbarPlus (Wally package)

	Single owner of open/close: icon selection drives
	`Codes.Visible`; `TopBar.CloseButton` hides the panel and
	deselects the icon. The icon is created exactly once per
	client (Icon.getIcon singleton check), so respawns and
	PlayerGui reloads can never duplicate it.

	No arbitrary waits, no polling, no Heartbeat — bounded
	WaitForChild on exactly the objects above, then immediate
	binding. No-ops (with a warning) when the authored UI or
	the package is missing.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Debug = require(ReplicatedStorage.Utility.Debug)
local MenuPresentation = require(script.Parent.MenuPresentation)

local localPlayer = Players.LocalPlayer

local CODES_ICON_NAME = 'Codes'
-- Verified-rendering reward gem (green Robux hexagon
-- 12512459063 was the alternate; both confirmed crisp with
-- transparency via the thumbnail API in Oct 2026). One-line
-- swap if art direction wants a ticket/gift glyph instead.
local CODES_GEM_IMAGE_ID = 10734983868

-- Bounded waits on OUR objects only (never remotes, never
-- gameplay state). Single-shot; StarterGui-authored UI and
-- Rojo-synced Packages replicate at join, so these resolve
-- essentially immediately.
local PLAYER_GUI_WAIT_S = 10
local MAIN_WAIT_S = 10
local CODES_WAIT_S = 10
local PACKAGES_WAIT_S = 10

local function warnTopbar(message: string)
	Debug.Warn('CodesTopbar', message)
end

local function logTopbar(message: string)
	Debug.Log('CodesTopbar', message)
end

local ok, err = pcall(function()
	if localPlayer == nil then
		warnTopbar('no LocalPlayer; topbar icon disabled')
		return
	end
	local playerGui = localPlayer:WaitForChild('PlayerGui', PLAYER_GUI_WAIT_S)
	if playerGui == nil then
		warnTopbar('PlayerGui missing; topbar icon disabled')
		return
	end
	local main = (playerGui :: PlayerGui):WaitForChild('Main', MAIN_WAIT_S)
	if main == nil then
		warnTopbar('PlayerGui.Main missing; topbar icon disabled')
		return
	end
	local codes = (main :: Instance):WaitForChild('Codes', CODES_WAIT_S)
	if codes == nil or not (codes :: Instance):IsA('GuiObject') then
		warnTopbar('PlayerGui.Main.Codes missing; topbar icon disabled')
		return
	end
	local frame = codes :: GuiObject
	local packages = ReplicatedStorage:WaitForChild('Packages', PACKAGES_WAIT_S)
	if packages == nil then
		warnTopbar('ReplicatedStorage.Packages missing; topbar icon disabled')
		return
	end
	local topbarMod = (packages :: Instance):WaitForChild('TopbarPlus', PACKAGES_WAIT_S)
	if topbarMod == nil then
		warnTopbar('TopbarPlus package missing; topbar icon disabled')
		return
	end
	local Icon: any = require(topbarMod)

	-- Singleton: exactly ONE Codes icon per client.
	local existing: any = nil
	pcall(function()
		existing = Icon.getIcon(CODES_ICON_NAME)
	end)
	local icon: any = existing
	if icon == nil then
		icon = Icon.new()
		icon:setName(CODES_ICON_NAME)
		icon:setImage(CODES_GEM_IMAGE_ID)
		logTopbar('TopbarPlus Codes icon created')
	else
		logTopbar('TopbarPlus Codes icon reused')
	end

	local syncing = false
	local function setVisible(visible: boolean)
		if syncing then
			return
		end
		syncing = true
		-- Full menu presentation (UiOpen + overlay/blur + Pop
		-- on open; Pop out on close). Already-open/closed
		-- calls are safe no-ops inside.
		MenuPresentation.SetVisible(frame :: GuiObject, visible)
		syncing = false
	end

	icon.selected:Connect(function()
		logTopbar('icon selected -> open')
		setVisible(true)
	end)
	icon.deselected:Connect(function()
		logTopbar('icon deselected -> close')
		setVisible(false)
	end)

	local topBar = frame:FindFirstChild('TopBar')
	local close = if topBar ~= nil then topBar:FindFirstChild('CloseButton') else nil
	if close ~= nil and (close :: Instance):IsA('GuiButton') then
		(close :: GuiButton).Activated:Connect(function()
			MenuPresentation.Close(frame :: GuiObject)
			-- Closing via the CloseButton must also deselect
			-- the icon so the two controls stay synchronized.
			pcall(function()
				if (icon :: any).isSelected == true then
					(icon :: any):deselect()
				end
			end)
		end)
		logTopbar('CloseButton bound')
	else
		warnTopbar('TopBar.CloseButton missing; icon toggles only')
	end

	-- Codes starts closed; agree with the authored initial
	-- visibility (never forces the panel itself); the icon then
	-- owns open/close.
	pcall(function()
		if (frame :: GuiObject).Visible then
			(icon :: any):select()
		else
			(icon :: any):deselect()
		end
	end)
	logTopbar('Codes topbar ready')
end)
if not ok then
	warnTopbar(('failed: %s'):format(tostring(err)))
end
