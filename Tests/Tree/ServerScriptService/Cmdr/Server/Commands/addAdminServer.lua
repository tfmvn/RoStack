--!strict
--!native
--[[
	addAdminServer
	Server-side Run for /addAdmin. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared addAdmin.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, userId: number, rank: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminConfig = require(ServerScriptService.Admin.AdminConfig)
	AdminService.AssertCanRun(context.Executor.UserId, AdminConfig.SuperadminGroup)
	if type(userId) ~= 'number' or userId < 0 then
		return 'userId must be a non-negative integer.'
	end
	if type(rank) ~= 'string' or not AdminConfig.RankOrder[rank] then
		return 'rank must be one of: mod, admin, superadmin.'
	end
	if not AdminService.AddAdmin(userId, rank) then
		return 'AddAdmin failed (invalid input).'
	end
	Debug.Warn('CMDR', 'addadmin', { userId = userId, rank = rank, by = context.Executor.UserId })
	return ('Added admin %d at rank %q.'):format(userId, rank)
end
