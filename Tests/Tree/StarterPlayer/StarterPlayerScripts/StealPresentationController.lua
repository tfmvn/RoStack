--!strict
--!native
--[[
	StealPresentationController
	===========================
	Client-side PRESENTATION for the server-authoritative steal
	carry (see ServerScriptService/Steal/StealService).

	While the LOCAL player is steal-carrying ANOTHER player's
	animal, the camera eases to a slightly narrower FOV (subtle
	heft, never a minigame). Everything else about the steal —
	ownership, transfer, delivery, rollback, WalkSpeed slowdown —
	stays server-side; this module only bends the thief's own
	camera and only while the server says the steal is live.

	Trust model (mirrors ResetProtectionController):
	  * The server replicates `CarriedSteal` in the per-player
	    `PlayerState` push (true while THIS player's carry is a
	    steal in progress, any kind). This controller additionally
	    requires `CarriedKind == animal`: picking up/carrying your
	    OWN animal (steal flag unset) never zooms, and egg steals
	    keep the default camera.
	  * Other players evaluate their own payloads, so the victim
	    and bystanders never zoom — thief-only by construction.
	  * The effect is one TweenService tween each way (no
	    RenderStepped loop, no per-frame writes), so it cannot
	    fight ArenaCameraImpacts (which bends CFrame, never FOV —
	    the only camera-motion system in the game).
	  * Base FOV is captured from the live camera at steal start
	    (never assumed 70) and restored exactly at steal end.
	    Cleanup is idempotent: delivery, cancel, drop, death,
	    reset, and disconnect all funnel through it.

	Tuning lives in StealConfig.StealPresentation (multiplier +
	tween time), read live so Studio tweaks apply without code.
]]

local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local TweenService = game:GetService('TweenService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local StealConfig = require(ReplicatedStorage.Config.World.Stealing)

local StealPresentationController = {}

-- Live state. _active while the server holds us steal-carrying;
-- _baseFov is the pre-steal FOV to restore (nil when clean).
local _active = false
local _baseFov: number? = nil
local _fovTween: Tween? = nil

local function _tweenSeconds(): number
	local seconds: number? = nil
	pcall(function()
		seconds = StealConfig.StealPresentation.FOVTweenTime
	end)
	if type(seconds) ~= 'number' or seconds ~= seconds or seconds < 0 then
		return 0.3
	end
	return seconds :: number
end

-- Pure target: narrowed FOV for a base value. Seamed for specs.
local function _targetFov(baseFov: number): number
	local mult: number? = nil
	pcall(function()
		mult = StealConfig.StealPresentation.FOVMultiplier
	end)
	if type(mult) ~= 'number' or mult ~= mult or mult <= 0 then
		mult = 0.9
	end
	return baseFov * (mult :: number)
end

local function _camera(): Camera?
	local cam: Camera? = nil
	pcall(function()
		cam = Workspace.CurrentCamera
	end)
	return cam
end

local function _stopTween()
	if _fovTween ~= nil then
		pcall(function()
			(_fovTween :: Tween):Cancel()
		end)
		_fovTween = nil
	end
end

-- Idempotent cleanup: stop the zoom, ease back to the exact
-- captured FOV, drop all state. Safe to call twice, safe with
-- no camera, safe mid-tween.
local function _cleanup()
	_active = false
	local base = _baseFov
	_baseFov = nil
	_stopTween()
	if base == nil then
		return
	end
	local cam = _camera()
	if cam == nil then
		return
	end
	pcall(function()
		local back = TweenService:Create(
			cam :: Camera,
			TweenInfo.new(_tweenSeconds(), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ FieldOfView = base }
		)
		_fovTween = back
		back:Play()
	end)
end

local function _start()
	if _active then
		return
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
	_stopTween()
	_active = true
	_baseFov = current
	pcall(function()
		local zoom = TweenService:Create(
			cam :: Camera,
			TweenInfo.new(_tweenSeconds(), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ FieldOfView = _targetFov(current :: number) }
		)
		_fovTween = zoom
		zoom:Play()
	end)
end

local function _onPlayerState(payload: any)
	local stealing = false
	if type(payload) == 'table' then
		-- Thief-only AND animal-only: own carries have no steal
		-- flag, and egg steals keep the default camera.
		if payload.CarriedSteal == true and payload.CarriedKind == SlotType.OccupantKind.Animal then
			stealing = true
		end
	end
	if stealing then
		_start()
	else
		_cleanup()
	end
end

function StealPresentationController.Init()
	local signal = Remotes.OnClientEvent(Remotes.Names.PlayerState)
	signal:Connect(_onPlayerState)
	-- Respawn safety: death ends every steal server-side (the
	-- clearing push restores us), but a missed push must never
	-- strand a zoomed camera on the fresh character.
	local player = Players.LocalPlayer
	if player then
		player.CharacterAdded:Connect(function()
			if _active then
				_cleanup()
			end
		end)
	end
end

-- TEST-ONLY seams (client presentation state; Studio specs drive
-- the gating logic without a camera).
function StealPresentationController._TestIsActive(): boolean
	return _active
end

function StealPresentationController._TestTargetFov(baseFov: number): number
	return _targetFov(baseFov)
end

return table.freeze(StealPresentationController)
