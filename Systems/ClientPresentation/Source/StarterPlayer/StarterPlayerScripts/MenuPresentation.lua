--!strict
--!native
--[[
	MenuPresentation
	================
	Shared menu open/close presentation for the main UI panels
	(Shop, Arena, ArenaResult, Codes, DailyRewards, GearShop,
	PlayTimeRewards, Rebirth, SellConfirmation, Settings).

	Opening a menu (MenuPresentation.Open(frame)):
	  UiOpen (local, this client only)
	  + dark overlay fades in (singleton, behind the menus)
	  + background blur fades in (singleton BlurEffect)
	  + ShopAnimations.Open(frame, "Pop")

	Closing (MenuPresentation.Close(frame)):
	  ShopAnimations.Close(frame, "Pop") — no close sound
	  + overlay/blur fade out once the last menu closes.

	Guards: opening an already-open frame plays nothing twice;
	closing an already-closed frame is a no-op hide. Overlay /
	blur are reference-counted across simultaneously open
	menus (pruned when a tracked frame is destroyed without
	Close). Singletons are find-or-create (no duplicates on
	re-init/respawn). ShopAnimations itself is never modified.
]]

local Players = game:GetService('Players')
local TweenService = game:GetService('TweenService')
local Lighting = game:GetService('Lighting')

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local ShopAnimations = require(ReplicatedStorage.ShopAnimations)
local UiSoundController = require(script.Parent.UiSoundController)
local Debug = require(ReplicatedStorage.Utility.Debug)

local MenuPresentation = {}

local localPlayer = Players.LocalPlayer
assert(localPlayer, 'MenuPresentation must run on the client')

-- Below authored menus (default DisplayOrder 0), above the
-- 3D world: dims the background without touching HUD/menus.
local DIM_DISPLAY_ORDER = -10
local DIM_TARGET_TRANSPARENCY = 0.55
local BLUR_TARGET_SIZE = 8
local CHROME_TWEEN_SECONDS = 0.25

-- Tracked open menus (frame -> Destroying connection).
-- Plain table (not weak): entries die explicitly on Close
-- or via their own Destroying handler.
local _open: { [GuiObject]: RBXScriptConnection? } = {}

local _dimGui: ScreenGui? = nil
local _dimFrame: Frame? = nil
local _dimTween: Tween? = nil
local _blurTween: Tween? = nil

local function _log(...: any)
	local parts: { string } = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	Debug.Log('MenuPresentation', table.concat(parts, ' '))
end

local function _playerGui(): PlayerGui?
	local gui: PlayerGui? = nil
	pcall(function()
		if localPlayer ~= nil then
			gui = localPlayer:FindFirstChildOfClass('PlayerGui')
		end
	end)
	return gui
end

-- Singleton dim overlay (find-or-create; never duplicated).
local function _ensureDim(): Frame?
	if _dimFrame ~= nil and (_dimFrame :: Instance).Parent ~= nil then
		return _dimFrame
	end
	_dimFrame = nil
	_dimGui = nil
	pcall(function()
		local root = _playerGui()
		if root == nil then
			return
		end
		local existing = root:FindFirstChild('MenuDimGui')
		if existing ~= nil and existing:IsA('ScreenGui') then
			_dimGui = existing
			local frame = existing:FindFirstChild('Dim')
			if frame ~= nil and frame:IsA('Frame') then
				_dimFrame = frame
				return
			end
		end
		local gui = Instance.new('ScreenGui')
		gui.Name = 'MenuDimGui'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = DIM_DISPLAY_ORDER
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local frame = Instance.new('Frame')
		frame.Name = 'Dim'
		frame.AnchorPoint = Vector2.new(0, 0)
		frame.Position = UDim2.fromScale(0, 0)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.new(0, 0, 0)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		-- Visual only: never sinks input, never changes clicks.
		frame.Active = false
		frame.Parent = gui
		gui.Parent = root
		_dimGui = gui
		_dimFrame = frame
	end)
	if _dimFrame ~= nil and (_dimFrame :: Instance).Parent ~= nil then
		return _dimFrame
	end
	_dimFrame = nil
	_dimGui = nil
	return nil
end

-- Singleton background blur (find-or-create; never duplicated).
local function _ensureBlur(): BlurEffect?
	local found: BlurEffect? = nil
	pcall(function()
		local existing = Lighting:FindFirstChild('MenuDimBlur')
		if existing ~= nil and existing:IsA('BlurEffect') then
			found = existing
			return
		end
		local blur = Instance.new('BlurEffect')
		blur.Name = 'MenuDimBlur'
		blur.Size = 0
		blur.Enabled = false
		blur.Parent = Lighting
		found = blur
	end)
	return found
end

local function _cancelChromeTweens()
	pcall(function()
		if _dimTween ~= nil then
			(_dimTween :: Tween):Cancel()
			_dimTween = nil
		end
		if _blurTween ~= nil then
			(_blurTween :: Tween):Cancel()
			_blurTween = nil
		end
	end)
end

local function _trackedCount(): number
	local n = 0
	for _ in pairs(_open) do
		n += 1
	end
	return n
end

-- Drop tracked frames that died without Close (respawn
-- resets, external destroys), then show/hide chrome to
-- match the surviving set.
local function _recomputeChrome()
	for frame in pairs(_open) do
		local alive = false
		pcall(function()
			alive = (frame :: Instance).Parent ~= nil
		end)
		if not alive then
			_open[frame] = nil
		end
	end
	_cancelChromeTweens()
	if _trackedCount() == 0 then
		pcall(function()
			local dim = _ensureDim()
			if dim ~= nil then
				local showTween = TweenService:Create(
					dim :: Frame,
					TweenInfo.new(CHROME_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 }
				)
				_dimTween = showTween
				showTween:Play()
			end
			local blur = _ensureBlur()
			if blur ~= nil then
				(blur :: BlurEffect).Enabled = true
				_blurTween = TweenService:Create(
					blur :: BlurEffect,
					TweenInfo.new(CHROME_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = 0 }
				)
				local tween = _blurTween :: Tween
				tween.Completed:Once(function()
					if _trackedCount() == 0 then
						pcall(function()
							(blur :: BlurEffect).Enabled = false
						end)
					end
				end)
				tween:Play()
			end
		end)
	else
		pcall(function()
			local dim = _ensureDim()
			if dim ~= nil then
				(dim :: Frame).BackgroundTransparency = 1
				local hideTween = TweenService:Create(
					dim :: Frame,
					TweenInfo.new(CHROME_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = DIM_TARGET_TRANSPARENCY }
				)
				_dimTween = hideTween
				hideTween:Play()
			end
			local blur = _ensureBlur()
			if blur ~= nil then
				local effect = blur :: BlurEffect
				effect.Enabled = true
				effect.Size = 0
				local blurTween = TweenService:Create(
					blur :: BlurEffect,
					TweenInfo.new(CHROME_TWEEN_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = BLUR_TARGET_SIZE }
				)
				_blurTween = blurTween
				blurTween:Play()
			end
		end)
	end
end

local function _track(frame: GuiObject)
	if _open[frame] ~= nil then
		return
	end
	_open[frame] = nil
	pcall(function()
		local conn = (frame :: Instance).Destroying:Connect(function()
			_open[frame] = nil
			_recomputeChrome()
		end)
		_open[frame] = conn
	end)
end

local function _untrack(frame: GuiObject)
	local conn = _open[frame]
	_open[frame] = nil
	pcall(function()
		if conn ~= nil then
			(conn :: RBXScriptConnection):Disconnect()
		end
	end)
end

local function _isShown(target: Instance): boolean
	local shown = false
	pcall(function()
		if (target :: Instance):IsA('LayerCollector') then
			shown = (target :: LayerCollector).Enabled
		elseif (target :: Instance):IsA('GuiObject') then
			shown = (target :: GuiObject).Visible
		end
	end)
	return shown
end

-- Open a menu with the full presentation (sound + chrome +
-- Pop). Opening an already-open frame plays nothing twice.
-- Never throws; falls back to an instant show if the
-- animation module cannot run.
function MenuPresentation.Open(frame: GuiObject)
	pcall(function()
		if typeof(frame) ~= 'Instance' then
			return
		end
		if _isShown(frame) then
			return
		end
		_track(frame)
		UiSoundController.Play('UiOpen')
		_recomputeChrome()
		if (frame :: Instance):IsA('GuiObject') then
			local ok, err = pcall(ShopAnimations.Open, frame, 'Pop')
			if not ok then
				Debug.Warn('MenuPresentation', 'Pop open failed; showing instantly', { error = tostring(err) })
				pcall(function()
					(frame :: GuiObject).Visible = true
				end)
			end
		else
			pcall(function()
				(frame :: LayerCollector).Enabled = true
			end)
		end
		_log('open', (frame :: Instance):GetFullName())
	end)
end

-- Close a menu (Pop out, no close sound). Closing an
-- already-closed frame only ensures it stays hidden. Never
-- throws; falls back to an instant hide if needed.
function MenuPresentation.Close(frame: GuiObject)
	pcall(function()
		if typeof(frame) ~= 'Instance' then
			return
		end
		if not _isShown(frame) then
			_untrack(frame)
			pcall(function()
				if (frame :: Instance):IsA('GuiObject') then
					(frame :: GuiObject).Visible = false
				else
					(frame :: LayerCollector).Enabled = false
				end
			end)
			return
		end
		_untrack(frame)
		_recomputeChrome()
		if (frame :: Instance):IsA('GuiObject') then
			local ok, err = pcall(ShopAnimations.Close, frame, 'Pop')
			if not ok then
				Debug.Warn('MenuPresentation', 'Pop close failed; hiding instantly', { error = tostring(err) })
				pcall(function()
					(frame :: GuiObject).Visible = false
				end)
			end
		else
			pcall(function()
				(frame :: LayerCollector).Enabled = false
			end)
		end
		_log('close', (frame :: Instance):GetFullName())
	end)
end

-- Visibility writer for toggle-style call sites.
function MenuPresentation.SetVisible(frame: GuiObject, visible: boolean)
	if visible then
		MenuPresentation.Open(frame)
	else
		MenuPresentation.Close(frame)
	end
end

return MenuPresentation
