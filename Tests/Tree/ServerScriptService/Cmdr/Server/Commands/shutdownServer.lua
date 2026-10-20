--!strict
--!native
--[[
	shutdownServer
	Server-side Run for /shutdown. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared shutdown.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, reason: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminConfig = require(ServerScriptService.Admin.AdminConfig)
	AdminService.AssertCanRun(context.Executor.UserId, AdminConfig.SuperadminGroup)
	if type(reason) ~= 'string' or #reason == 0 then
		return 'reason must be a non-empty string.'
	end
	Debug.Warn('CMDR', 'shutdown', { reason = reason, by = context.Executor.UserId })
	-- BindToClose fires for every player still connected.
	-- The reason is included so the kick message is
	-- descriptive.
	game:BindToClose(function()
		for _, p in ipairs(game:GetService('Players'):GetPlayers()) do
			p:Kick(('Server shutting down: %s'):format(reason))
		end
	end)
	-- 3s grace so the BindToClose has a chance to run
	-- cleanly. If nobody is connected, this still works.
	task.delay(3, function()
		game:Shutdown()
	end)
	return ('Server is shutting down in 3s: %s'):format(reason)
end
