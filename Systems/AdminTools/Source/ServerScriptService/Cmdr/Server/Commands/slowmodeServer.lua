--!strict
--!native
--[[
	slowmodeServer
	Server-side Run for /slowmode. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared slowmode.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, seconds: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if type(seconds) ~= 'number' or seconds < 0 or seconds > 60 then
		return 'seconds must be 0..60.'
	end
	-- Intentional no-op: TextChatService / TextService
	-- integration is deferred. The command exists so the
	-- surface is discoverable.
	Debug.Log('CMDR', 'slowmode (no-op placeholder)', { seconds = seconds, by = context.Executor.UserId })
	return ('slowmode is a placeholder; would set %ds.'):format(seconds)
end
