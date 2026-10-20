--!strict
--!native
--[[
	removeAdminServer
	Server-side Run for /removeAdmin. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared removeAdmin.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, userId: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminConfig = require(ServerScriptService.Admin.AdminConfig)
	AdminService.AssertCanRun(context.Executor.UserId, AdminConfig.SuperadminGroup)
	if type(userId) ~= 'number' or userId < 0 then
		return 'userId must be a non-negative integer.'
	end
	if not AdminService.RemoveAdmin(userId) then
		return ('%d was not an admin.'):format(userId)
	end
	Debug.Warn('CMDR', 'removeadmin', { userId = userId, by = context.Executor.UserId })
	return ('Removed admin %d.'):format(userId)
end
