--!strict
--!native
--[[
	ToastController
	===============
	Notify-remote forwarder. Subscribes to the Notify remote and
	delegates every notification to HudNotificationController,
	which paints the Studio-authored HUD.Center.Notifications
	label (queue, coalescing, duration, and animation live
	there). This module creates NO UI of its own: no ScreenGui,
	no fallback stack, no generated labels — the authored HUD
	is the single notification target. Also hosts the
	arrival/carry hooks that feed HUD slot state.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local HUDController = require(script.Parent.HUDController)
local HudNotificationController = require(script.Parent.HudNotificationController)

local ToastController = {}

local _started = false
local _warnedNoPanel = false

function ToastController.Init()
	if _started then
		return
	end
	_started = true

	Remotes.OnClientEvent(Remotes.Names.Notify):Connect(function(payload: any)
		ToastController.Push(payload)
	end)

	Remotes.OnClientEvent(Remotes.Names.AnimalArrived):Connect(function(payload: any)
		if payload and payload.SlotId and payload.DisplayName then
			HUDController.SetSlotAnimal(payload.SlotId, payload.DisplayName, payload.Rarity)
		end
	end)

	Remotes.OnClientEvent(Remotes.Names.EggArrived):Connect(function(payload: any)
		-- Phase 2: lucky-egg-arrived payload now also carries
		-- the rarity. The HUD caches it so the slot row renders
		-- the correct rarity color even before the next
		-- PlayerState push arrives.
		if payload and payload.SlotId and payload.Rarity then
			HUDController.SetSlotEgg(payload.SlotId, payload.Rarity)
		end
	end)

	-- Phase 1.5 + Phase 2: carry/place carry hooks. The HUD is
	-- not required to consume these — PlayerState already
	-- reflects the slot's new occupancy — but they're a
	-- useful future hook for grab/place feedback (SFX, toast,
	-- anim). The handlers exist so the wire is in place when
	-- those features land.
	Remotes.OnClientEvent(Remotes.Names.AnimalCarried):Connect(function(_payload: any)
		-- no-op; PlayerState already reflects the carry.
	end)
	Remotes.OnClientEvent(Remotes.Names.AnimalPlaced):Connect(function(_payload: any)
		-- no-op; PlayerState already reflects the placement.
	end)
	Remotes.OnClientEvent(Remotes.Names.EggCarried):Connect(function(_payload: any)
		-- no-op; PlayerState already reflects the carry.
	end)
	Remotes.OnClientEvent(Remotes.Names.EggPlaced):Connect(function(_payload: any)
		-- no-op; PlayerState already reflects the placement.
	end)
end

function ToastController.Push(payload: any)
	if not payload or not payload.Category or not payload.Text then
		return
	end
	-- Single target: the authored HUD.Center.Notifications
	-- label via HudNotificationController. No generated
	-- fallback exists by design — a missing panel warns loudly
	-- (expected path in the message) instead of silently
	-- swallowing the notification.
	local owned = false
	pcall(function()
		owned = HudNotificationController.Show(payload.Category, payload.Text)
	end)
	if not owned and not _warnedNoPanel then
		_warnedNoPanel = true
		warn(
			('[Toast] HUD.Center.Notifications unavailable; notification dropped category=%s'):format(
				tostring(payload.Category)
			)
		)
	end
end

return table.freeze(ToastController)
