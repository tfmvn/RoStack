--!strict
--!native
--[[
	listCenterBlocksServer
	Server-side Run for /listCenterEggs. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared listCenterEggs.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(_context)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local EggService = require(ServerScriptService.EggService)
	AdminService.AssertAdmin(_context.Executor.UserId)
	local eggs = EggService.ListCenterEggs()
	if #eggs == 0 then
		return 'No active center eggs.'
	end
	local lines = { ('%d center egg(s):'):format(#eggs) }
	for _, b in ipairs(eggs) do
		table.insert(lines, ('  - %s | %s | $%d'):format(tostring(b.UniqueId), tostring(b.Rarity), b.Price))
	end
	return table.concat(lines, '\n')
end
