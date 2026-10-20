--!strict
--!native
--[[
	listPlayersServer
	Server-side Run for /listPlayers. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared listPlayers.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local Players = game:GetService('Players')

local ServerScriptService = game:GetService('ServerScriptService')

return function(context)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local list = Players:GetPlayers()
	if #list == 0 then
		return 'No players in the server.'
	end
	local lines = { ('%d player(s):'):format(#list) }
	for _, p in ipairs(list) do
		table.insert(lines, ('  - %s (%d) | display=%s | age=%d'):format(p.Name, p.UserId, p.DisplayName, p.AccountAge))
	end
	return table.concat(lines, '\n')
end
