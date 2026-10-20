--!strict
--!native
--[[
	SettingsService
	===============
	Server side of client presentation settings (BGM volume, SFX
	volume, FastMode toggle). These NEVER affect gameplay — they
	are persisted preferences mirrored to the owning client.

	Authority model:
	  profile.Data.Settings (shape default in PlayerService) is
	  the single source of truth. SaveSettings writes it
	  (validated/clamped); SettingsState pushes it on load so
	  the Settings UI restores. The client applies audio locally
	  (see SettingsController); the server never plays sounds
	  for settings and never reads them for gameplay.
]]

local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local Validation = require(game:GetService('ReplicatedStorage').Utility.Validation)

local PlayerService = require(script.Parent.PlayerService)

local SettingsService = {}

local _wired = false

local function sanitize(settings: any): { Bgm: number, Sfx: number, FastMode: boolean }
	local out = { Bgm = 1, Sfx = 1, FastMode = false }
	if type(settings) ~= 'table' then
		return out
	end
	if type(settings.Bgm) == 'number' and settings.Bgm == settings.Bgm then
		out.Bgm = math.clamp(settings.Bgm, 0, 1)
	end
	if type(settings.Sfx) == 'number' and settings.Sfx == settings.Sfx then
		out.Sfx = math.clamp(settings.Sfx, 0, 1)
	end
	if type(settings.FastMode) == 'boolean' then
		out.FastMode = settings.FastMode
	end
	return out
end

-- Authoritative read (sanitized copy, never the live table).
function SettingsService.GetSettings(userId: number): { Bgm: number, Sfx: number, FastMode: boolean }
	local current: any = nil
	pcall(function()
		local data = PlayerService.GetPlayerData(userId)
		if type(data) == 'table' then
			current = data.Settings
		end
	end)
	return sanitize(current)
end

function SettingsService.PushSettings(player: Player)
	if not Validation.LivePlayer(player) then
		return
	end
	local state = SettingsService.GetSettings(player.UserId)
	pcall(Remotes.FireClient, player, Remotes.Names.SettingsState, state)
end

local function onSave(player: Player, payload: any)
	if not Validation.LivePlayer(player) then
		return
	end
	if type(payload) ~= 'table' then
		return
	end
	local userId = player.UserId
	local data: any = nil
	pcall(function()
		data = PlayerService.GetPlayerData(userId)
	end)
	if type(data) ~= 'table' then
		return
	end
	local next = sanitize(payload)
	data.Settings = next
	Debug.Log('Settings', 'saved', {
		userId = tostring(userId),
		bgm = tostring(next.Bgm),
		sfx = tostring(next.Sfx),
		fast = tostring(next.FastMode),
	})
end

function SettingsService.Init()
	if _wired then
		return
	end
	_wired = true
	pcall(function()
		local folder = Remotes.GetFolder()
		local event = folder:WaitForChild(Remotes.Names.SaveSettings, 10)
		if event ~= nil and (event :: Instance):IsA('RemoteEvent') then
			(event :: RemoteEvent).OnServerEvent:Connect(onSave)
		else
			Debug.Warn('Settings', 'SaveSettings remote missing; settings will not persist', {})
		end
	end)
end

function SettingsService.ForgetPlayer(_userId: number)
	-- Stateless (no per-player caches) — nothing to drop.
	return
end

return table.freeze(SettingsService)
