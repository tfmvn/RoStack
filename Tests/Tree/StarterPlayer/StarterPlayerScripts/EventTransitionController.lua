--!strict
--!native
--[[
	EventTransitionController
	=========================
	Client-side PRESENTATION for server-authoritative Event
	start/stop transitions (see ServerScriptService/Event/
	EventService). ONE broadcast remote (EventTransition)
	reaches every client in the server:

	  Prepare { Kind = 'Start' | 'End', EventId, TransitionId,
	    FovMultiplier, FovSeconds, FlashDelaySeconds,
	    FlashInSeconds, FadeOutSeconds, CoverSeconds }:
	    FOV zoom begins now, white flash builds right after;
	    the server performs the world change after
	    CoverSeconds, behind full white.
	  Reveal { Kind, EventId, TransitionId }: the world change
	    is committed; fade the white out and ease FOV back.

	Trust model (mirrors StealPresentationController):
	  * The server decides everything (phase, kind, event,
	    timing, world change). This module only bends the
	    local camera and a temporary overlay. Event truth
	    stays in the replicated attributes read by
	    EventController — this controller never decides it.
	  * Unknown/replayed TransitionIds are ignored, so joins
	    (missed Prepare), lag, and duplicate pushes can never
	    stick a white screen or a zoomed camera.
	  * An interrupt (new Prepare while active) abandons the
	    old visuals cleanly and starts the new transition —
	    no double tweens, no stuck overlay, no stuck FOV.
	  * Base FOV is captured live per transition (never
	    assumed) and restored exactly. One TweenService tween
	    per property (no RenderStepped writes), so it cannot
	    fight ArenaCameraImpacts (CFrame-only) or the steal
	    zoom (separate lifecycle; last writer wins a tween,
	    both restore to their own captured base).

	The overlay is temporary and event-transition owned: a
	full-screen white Frame in a dedicated ScreenGui,
	destroyed after every fade. Normal UI is never altered.
]]

local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local TweenService = game:GetService('TweenService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local EventConfig = require(ReplicatedStorage.Config.World.Events)

local EventTransitionController = {}

-- Flash overlay layering: above every gameplay HUD (the only
-- other code-built overlay, MoneyPoolOverlay, sits at 50) so
-- the white genuinely covers world pop-in; temporary — the
-- gui is destroyed after every reveal fade.
local FLASH_DISPLAY_ORDER = 100

-- Live transition state. _activeId nil = idle (no overlay, no
-- tweens, FOV untouched). _baseFov is the pre-transition FOV
-- captured per transition and restored exactly.
local _activeId: number? = nil
local _baseFov: number? = nil
local _fovTween: Tween? = nil
local _flashTween: Tween? = nil
local _gui: ScreenGui? = nil
local _frame: Frame? = nil
-- Reveal-completion generation: a delayed destroy must not
-- kill a NEWER transition's overlay.
local _revealGen = 0

-- Resolve animation timings: well-formed payload numbers win
-- (server authority), else the shared EventConfig table, else
-- the same hardcoded defaults the server falls back to.
-- Pure given its inputs (seamed for specs). Never throws.
local function _timingsFor(payload: any): any
	local out = {
		FovMultiplier = 0.83,
		FovSeconds = 0.35,
		FlashDelaySeconds = 0.05,
		FlashInSeconds = 0.3,
		FadeOutSeconds = 1,
	}
	pcall(function()
		local cfg: any = EventConfig.Transition
		if type(cfg) == 'table' then
			if type(cfg.FovMultiplier) == 'number' and cfg.FovMultiplier > 0 and cfg.FovMultiplier < 1 then
				out.FovMultiplier = cfg.FovMultiplier
			end
			if type(cfg.FovSeconds) == 'number' and cfg.FovSeconds >= 0 then
				out.FovSeconds = cfg.FovSeconds
			end
			if type(cfg.FlashDelaySeconds) == 'number' and cfg.FlashDelaySeconds >= 0 then
				out.FlashDelaySeconds = cfg.FlashDelaySeconds
			end
			if type(cfg.FlashInSeconds) == 'number' and cfg.FlashInSeconds > 0 then
				out.FlashInSeconds = cfg.FlashInSeconds
			end
			if type(cfg.FadeOutSeconds) == 'number' and cfg.FadeOutSeconds > 0 then
				out.FadeOutSeconds = cfg.FadeOutSeconds
			end
		end
		if type(payload) == 'table' then
			if type(payload.FovMultiplier) == 'number' and payload.FovMultiplier > 0 and payload.FovMultiplier < 1 then
				out.FovMultiplier = payload.FovMultiplier
			end
			if type(payload.FovSeconds) == 'number' and payload.FovSeconds >= 0 then
				out.FovSeconds = payload.FovSeconds
			end
			if type(payload.FlashDelaySeconds) == 'number' and payload.FlashDelaySeconds >= 0 then
				out.FlashDelaySeconds = payload.FlashDelaySeconds
			end
			if type(payload.FlashInSeconds) == 'number' and payload.FlashInSeconds > 0 then
				out.FlashInSeconds = payload.FlashInSeconds
			end
			if type(payload.FadeOutSeconds) == 'number' and payload.FadeOutSeconds > 0 then
				out.FadeOutSeconds = payload.FadeOutSeconds
			end
		end
	end)
	return out
end

local function _camera(): Camera?
	local cam: Camera? = nil
	pcall(function()
		cam = Workspace.CurrentCamera
	end)
	return cam
end

local function _playerGui(): PlayerGui?
	local gui: PlayerGui? = nil
	pcall(function()
		local player = Players.LocalPlayer
		local found = player and player:FindFirstChildOfClass('PlayerGui') or nil
		if found ~= nil then
			gui = found
		end
	end)
	return gui
end

local function _stopTweens()
	if _fovTween ~= nil then
		pcall(function()
			(_fovTween :: Tween):Cancel()
		end)
		_fovTween = nil
	end
	if _flashTween ~= nil then
		pcall(function()
			(_flashTween :: Tween):Cancel()
		end)
		_flashTween = nil
	end
end

local function _destroyOverlay()
	_frame = nil
	if _gui ~= nil then
		pcall(function()
			(_gui :: ScreenGui):Destroy()
		end)
		_gui = nil
	end
end

-- Interrupt path: drop the old visuals instantly and keep the
-- FOV wherever it is — the incoming Prepare re-captures it
-- as its base, so there is never a snap and never a leak.
local function _abandon()
	_revealGen += 1
	_activeId = nil
	_baseFov = nil
	_stopTweens()
	_destroyOverlay()
end

-- Full cleanup: cancel everything, destroy the overlay,
-- restore the captured FOV exactly. Idempotent: safe twice,
-- safe idle, safe cameraless. Never throws.
local function _cleanup()
	_revealGen += 1
	_activeId = nil
	local base = _baseFov
	_baseFov = nil
	_stopTweens()
	_destroyOverlay()
	if base ~= nil then
		local cam = _camera()
		if cam ~= nil then
			pcall(function()
				(cam :: Camera).FieldOfView = base
			end)
		end
	end
end

local function _ensureOverlay(): Frame?
	if _frame ~= nil and (_frame :: Instance).Parent ~= nil and _gui ~= nil and (_gui :: Instance).Parent ~= nil then
		return _frame
	end
	_destroyOverlay()
	pcall(function()
		local root = _playerGui()
		if root == nil then
			return
		end
		local gui = Instance.new('ScreenGui')
		gui.Name = 'EventTransitionFlash'
		gui.ResetOnSpawn = false
		gui.IgnoreGuiInset = true
		gui.DisplayOrder = FLASH_DISPLAY_ORDER
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local frame = Instance.new('Frame')
		frame.Name = 'Flash'
		frame.AnchorPoint = Vector2.new(0, 0)
		frame.Position = UDim2.fromScale(0, 0)
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = Color3.new(1, 1, 1)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.Active = false
		frame.Parent = gui
		gui.Parent = root
		_gui = gui
		_frame = frame
	end)
	if _frame ~= nil and (_frame :: Instance).Parent ~= nil then
		return _frame
	end
	_destroyOverlay()
	return nil
end

local function _onPrepare(payload: any)
	local id: number? = nil
	pcall(function()
		if type(payload) == 'table' and type(payload.TransitionId) == 'number' then
			id = payload.TransitionId
		end
	end)
	if id == nil then
		return
	end
	-- Duplicate push for the live transition: ignore (never
	-- double tweens, never double overlays).
	if _activeId == id then
		return
	end
	-- Interrupt: a newer transition replaces the live one.
	if _activeId ~= nil then
		_abandon()
	end
	local cam = _camera()
	if cam == nil then
		return
	end
	local current: number? = nil
	pcall(function()
		current = (cam :: Camera).FieldOfView
	end)
	if type(current) ~= 'number' or current ~= current or (current :: number) <= 0 then
		return
	end
	local frame = _ensureOverlay()
	if frame == nil then
		return
	end
	local timings = _timingsFor(payload)
	_activeId = id
	_baseFov = current
	pcall(function()
		(frame :: Frame).BackgroundTransparency = 1
		local zoom = TweenService:Create(
			cam :: Camera,
			TweenInfo.new(timings.FovSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ FieldOfView = (current :: number) * timings.FovMultiplier }
		)
		_fovTween = zoom
		zoom:Play()
		local flash = TweenService:Create(
			frame :: Frame,
			TweenInfo.new(
				timings.FlashInSeconds,
				Enum.EasingStyle.Sine,
				Enum.EasingDirection.InOut,
				0,
				false,
				timings.FlashDelaySeconds
			),
			{ BackgroundTransparency = 0 }
		)
		_flashTween = flash
		flash:Play()
	end)
end

local function _onReveal(payload: any)
	local id: number? = nil
	pcall(function()
		if type(payload) == 'table' and type(payload.TransitionId) == 'number' then
			id = payload.TransitionId
		end
	end)
	-- Unknown/stale reveal (join missed Prepare, lagged
	-- duplicate, superseded transition): ignore.
	if id == nil or _activeId ~= id then
		return
	end
	local frame = _frame
	local cam = _camera()
	local base = _baseFov
	local timings = _timingsFor(payload)
	_stopTweens()
	pcall(function()
		if frame ~= nil and (frame :: Instance).Parent ~= nil then
			local fade = TweenService:Create(
				frame :: Frame,
				TweenInfo.new(timings.FadeOutSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ BackgroundTransparency = 1 }
			)
			_flashTween = fade
			fade:Play()
		end
		if cam ~= nil and base ~= nil then
			local back = TweenService:Create(
				cam :: Camera,
				TweenInfo.new(timings.FadeOutSeconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				{ FieldOfView = base }
			)
			_fovTween = back
			back:Play()
		end
	end)
	-- Delayed destroy, generation-guarded: an interrupt that
	-- started a newer transition must not lose its overlay.
	_revealGen += 1
	local gen = _revealGen
	_activeId = nil
	_baseFov = nil
	task.delay(timings.FadeOutSeconds + 0.05, function()
		pcall(function()
			if gen ~= _revealGen then
				return
			end
			if _activeId ~= nil then
				return
			end
			_stopTweens()
			_destroyOverlay()
		end)
	end)
end

local function _onTransition(payload: any)
	local phase: string? = nil
	pcall(function()
		if type(payload) == 'table' and type(payload.Phase) == 'string' then
			phase = payload.Phase
		end
	end)
	if phase == 'Prepare' then
		_onPrepare(payload)
	elseif phase == 'Reveal' then
		_onReveal(payload)
	end
end

function EventTransitionController.Init()
	local signal = Remotes.OnClientEvent(Remotes.Names.EventTransition)
	signal:Connect(_onTransition)
end

-- TEST-ONLY seams (Studio specs drive the gating logic).
function EventTransitionController._TestIsActive(): boolean
	return _activeId ~= nil
end

function EventTransitionController._TestActiveId(): number?
	return _activeId
end

function EventTransitionController._TestTimingsFor(payload: any): any
	return _timingsFor(payload)
end

function EventTransitionController._TestReset()
	_cleanup()
end

return table.freeze(EventTransitionController)
