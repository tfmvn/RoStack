--!strict
--!native
--[[
	announceServer
	Server-side Run for /announce. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared announce.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Players = game:GetService('Players')

local Debug = require(game.ReplicatedStorage.Utility.Debug)
local RichTextFormatter = require(game.ReplicatedStorage.Utility.RichTextFormatter)

return function(context, message: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local PlayerService = require(ServerScriptService.PlayerService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if type(message) ~= 'string' or #message == 0 then
		return 'message must be a non-empty string.'
	end
	if #message > 240 then
		return 'message is too long (max 240 characters).'
	end
	-- Announcements render through RichText-enabled toasts, so
	-- admin text is escaped first: no markup can be injected
	-- (trusted-RichText announcements are not a supported path).
	local safe = RichTextFormatter.Escape(message)
	for _, p in ipairs(Players:GetPlayers()) do
		PlayerService.Notify(p, 'System', safe)
	end
	Debug.Log('CMDR', 'announce', { len = #message, by = context.Executor.UserId })
	return ('Announced to %d player(s).'):format(#Players:GetPlayers())
end
