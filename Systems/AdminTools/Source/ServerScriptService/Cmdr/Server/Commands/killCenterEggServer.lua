--!strict
--!native
--[[
	killCenterBlockServer
	Server-side Run for /killCenterEgg. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared killCenterEgg.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, uniqueId: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local egg = SpawnService.GetEgg(uniqueId)
	if not egg then
		return ('No egg with uniqueId %q.'):format(uniqueId)
	end
	if egg.model then
		egg.model:Destroy()
	end
	SpawnService.DropEgg(uniqueId)
	Debug.Log('CMDR', 'killcenteregg', { uniqueId = uniqueId, by = context.Executor.UserId })
	return ('Killed egg %q.'):format(uniqueId)
end
