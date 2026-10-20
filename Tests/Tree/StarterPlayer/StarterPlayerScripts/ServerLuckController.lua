--!strict
--!native
--[[
	ServerLuckController
	====================
	Client display for the authoritative server-wide Luck
	multiplier: HUD.BottomLeft.ServerLuckCounter.Text shows
	"1.0x" / "2.0x" / "4.0x" (legacy HUD.ServerLuckCounter /
	HUD.ServerLuck accepted as fallback).

	Authority model (display-only client):
	  Server (ServerLuckService) publishes the `ServerLuck`
	  attribute on ReplicatedStorage on every change (and once
	  at boot). This controller paints the label from that
	  attribute immediately at Init (no race with UI creation)
	  and rewatches it with GetAttributeChangedSignal, so HUD
	  updates arrive with no heartbeat, no polling, no remotes.
	  The client never decides or stores luck.

	The HUD tree is Studio-authored, so every lookup is
	defensive with ChildAdded re-try: a late/missing label
	degrades to a warn, never an error, never a boot block.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local HudTree = require(script.Parent.HudTree)

local ServerLuckController = {}

local ATTRIBUTE = 'ServerLuck'
local DEFAULT_TEXT = '1.0x'

local _label: TextLabel? = nil -- gotta add funnel event into the Economy, Tutorial, Eggs, Animals, Arena, and also perhaps the arena system designnn nad 
local _resolved = false
local _warned: { [string]: boolean } = {}
local _attrConn: RBXScriptConnection? = nil

local function _warnOnce(key: string, message: string)
	if _warned[key] then
		return
	end
	_warned[key] = true
	Debug.Warn('LUCK', message, {})
end

-- Pure text builder (TEST seam): canonical "%.1fx" display. though we can change it to  something else to get a diff output, right now its more like x.x ex-1.0 1.5 1.4 etc
function ServerLuckController._TestFormatLuck(luck: any): string
	local v = tonumber(luck)
	if v ~= v or v == nil then
		return DEFAULT_TEXT
	end
	return ('%.1fx'):format(v)
end

local function _readLuck(): number
	local v: any = nil
	pcall(function()
		v = ReplicatedStorage:GetAttribute(ATTRIBUTE)
	end)
	local n = tonumber(v)
	if n == nil or n ~= n or n < 1 then
		return 1
	end
	return n
end

local function _paint()
	if _label == nil then
		return
	end
	pcall(function()
		-- The BottomLeft chain must be up or the paint is invisible.
		-- (EnsureChainVisible returns the flip count — without the
		-- semicolon Lua would parse the next line as a call on it.)
		HudTree.EnsureChainVisible(_label);
		(_label :: TextLabel).Text = ServerLuckController._TestFormatLuck(_readLuck())
	end)
end

-- Resolve Players.LocalPlayer.PlayerGui.HUD.ServerLuck once
-- (non-blocking; spawned by Init). Missing nodes degrade to a
-- warn + a ChildAdded re-try — the label appears late rather
-- than never, and a missing HUD never blocks boot.
local function _resolve(): boolean
	local player = Players.LocalPlayer
	if player == nil then
		_warnOnce('no-player', '[ServerLuck] LocalPlayer missing; luck HUD unavailable')
		return false
	end
	local playerGui: Instance? = nil
	pcall(function()
		playerGui = player:WaitForChild('PlayerGui', 10)
	end)
	if playerGui == nil then
		_warnOnce('no-playergui', '[ServerLuck] PlayerGui missing; luck HUD unavailable')
		return false
	end
	local hud: Instance? = nil
	pcall(function()
		hud = (playerGui :: Instance):WaitForChild('HUD', 10)
	end)
	if hud == nil then
		_warnOnce('no-hud', '[ServerLuck] HUD missing under PlayerGui; luck HUD unavailable')
		pcall(function()
			(playerGui :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name == 'HUD' and not _resolved then
					task.spawn(function()
						if _resolve() then
							_paint()
						end
					end)
				end
			end)
		end)
		return false
	end
	local label: TextLabel? = nil
	-- Canonical Studio path HUD.BottomLeft.ServerLuckCounter(.Text);
	-- legacy HUD.ServerLuckCounter / HUD.ServerLuck accepted.
	pcall(function()
		label = HudTree.LuckText(playerGui)
	end)
	if label == nil then
		_warnOnce('no-label', '[ServerLuck] ServerLuckCounter label missing under HUD.BottomLeft; luck HUD unavailable')
		pcall(function()
			(hud :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name == 'BottomLeft' and not _resolved then
					task.spawn(function()
						if _resolve() then
							_paint()
						end
					end)
				end
			end)
		end)
		return false
	end
	_label = label
	_resolved = true
	return true
end

function ServerLuckController.Init()
	task.spawn(function()
		if _resolve() then
			_paint()
		end
		-- Live updates: the server rewrites the attribute on
		-- every luck change. One connection, event-driven.
		pcall(function()
			if _attrConn == nil then
				_attrConn = ReplicatedStorage:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
					_paint()
				end)
			end
		end)
	end)
end

return table.freeze(ServerLuckController)
