--!strict
--!native
--[[
	UiSoundController
	=================
	Client-ONLY personal UI sounds (UiHover / UiClick / UiOpen).

	Source templates live at ReplicatedStorage.Assets.Sfx
	(mirrored once at server boot from ServerStorage — the
	ONLY SFX mirror; LocalScripts can never read
	ServerStorage). Every play clones the template into the
	LOCAL PlayerGui and plays the clone, so each player hears
	ONLY their own UI: nothing here ever touches Workspace,
	nothing is FireAllClients, and the server never plays
	these sounds.

	Button wiring is automatic and additive: every GuiButton
	under PlayerGui (all menus, HUD, late-streamed UI) gets
	exactly one MouseEnter -> UiHover and one Activated ->
	UiClick listener. Existing Activated/MouseButton1Click
	connections are untouched. Wiring dedupes via the
	UiSoundWired attribute (dies with the instance, so
	respawn re-clones rewire cleanly through DescendantAdded).
]]

local Players = game:GetService('Players')
local Debris = game:GetService('Debris')

local ReplicatedStorage = game:GetService('ReplicatedStorage')

local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)
local Debug = require(ReplicatedStorage.Utility.Debug)

local UiSoundController = {}

local localPlayer = Players.LocalPlayer
assert(localPlayer, 'UiSoundController must run on the client')

local _started = false
local _warned: { [string]: boolean } = {}

local WIRED_ATTRIBUTE = 'UiSoundWired'

local function _log(...: any)
	local parts: { string } = {}
	for _, v in ipairs({ ... }) do
		parts[#parts + 1] = tostring(v)
	end
	Debug.Log('UiSound', table.concat(parts, ' '))
end

-- Client-visible template only (never ServerStorage).
local function _resolveTemplate(name: string): Sound?
	local found: Sound? = nil
	pcall(function()
		if type(name) ~= 'string' or name == '' then
			return
		end
		local assets = ReplicatedStorage:FindFirstChild('Assets')
		local sfx = assets and (assets :: Instance):FindFirstChild('Sfx') or nil
		local node = sfx and (sfx :: Instance):FindFirstChild(name) or nil
		if node ~= nil and (node :: Instance):IsA('Sound') then
			local sound = node :: Sound
			if sound.SoundId ~= '' then
				found = sound
			end
		end
	end)
	if found == nil then
		local key = 'sfx:' .. tostring(name)
		if not _warned[key] then
			_warned[key] = true
			Debug.Warn('UiSound', 'UI sound template missing; silent', { sound = tostring(name) })
		end
	end
	return found
end

-- Play one named UI sting locally (2D, this client only).
-- Never throws; silent no-op when the template or PlayerGui
-- is missing. No delays: hover -> MouseEnter, click/open ->
-- Activated/Open call straight through.
function UiSoundController.Play(name: string)
	pcall(function()
		local template = _resolveTemplate(name)
		if template == nil then
			return
		end
		if localPlayer == nil then
			return
		end
		local playerGui = localPlayer:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local clone = (template :: Sound):Clone()
		clone.Name = 'Ui' .. tostring(name) .. 'Sfx'
		clone.Looped = false
		clone.PlayOnRemove = false
		AudioGroups.AssignSfx(clone)
		clone.Parent = playerGui
		clone:Play()
		local length = 2
		pcall(function()
			local t = (clone :: Sound).TimeLength
			if type(t) == 'number' and t == t and t > 0 then
				length = t + 0.5
			end
		end)
		Debris:AddItem(clone, length)
	end)
end

-- Usable right now: own flags plus every GuiObject
-- ancestor visible. (The engine already suppresses
-- MouseEnter/Activated on invisible/inactive buttons; this
-- guard covers programmatic edges.)
local function _isUsable(button: GuiButton): boolean
	local ok = false
	pcall(function()
		if not button.Visible or not button.Active then
			return
		end
		local node: Instance? = button.Parent
		while node ~= nil do
			if node:IsA('GuiObject') and not (node :: GuiObject).Visible then
				return
			end
			node = node.Parent
		end
		ok = true
	end)
	return ok
end

local function _wire(button: GuiButton)
	local inst = button :: Instance
	local already = false
	pcall(function()
		already = inst:GetAttribute(WIRED_ATTRIBUTE) == true
	end)
	if already then
		return
	end
	pcall(function()
		inst:SetAttribute(WIRED_ATTRIBUTE, true)
	end)
	button.MouseEnter:Connect(function()
		if _isUsable(button) then
			UiSoundController.Play('UiHover')
		end
	end)
	button.Activated:Connect(function()
		if _isUsable(button) then
			UiSoundController.Play('UiClick')
		end
	end)
end

local function _scan(root: Instance)
	pcall(function()
		if typeof(root) ~= 'Instance' then
			return
		end
		if (root :: Instance):IsA('GuiButton') then
			_wire(root :: GuiButton)
		end
		for _, descendant in ipairs((root :: Instance):GetDescendants()) do
			if descendant:IsA('GuiButton') then
				_wire(descendant)
			end
		end
	end)
end

function UiSoundController.Init()
	if _started then
		return
	end
	_started = true
	task.spawn(function()
		local ok, err = pcall(function()
			if localPlayer == nil then
				return
			end
			local playerGui = localPlayer:WaitForChild('PlayerGui', 10)
			if playerGui == nil then
				Debug.Warn('UiSound', 'PlayerGui missing; button sounds disabled', {})
				return
			end
			-- Existing UI (one pass, attribute-deduped) plus
			-- everything that streams in later (respawn
			-- re-clones included — fresh instances carry no
			-- attribute, so they wire exactly once here).
			_scan(playerGui)
			local gui = playerGui :: PlayerGui
			gui.DescendantAdded:Connect(function(descendant: Instance)
				if descendant:IsA('GuiButton') then
					_wire(descendant)
				elseif descendant:IsA('GuiObject') or descendant:IsA('LayerCollector') then
					_scan(descendant)
				end
			end)
			_log('init')
		end)
		if not ok then
			Debug.Warn('UiSound', 'init failed', { error = tostring(err) })
		end
	end)
end

return UiSoundController
