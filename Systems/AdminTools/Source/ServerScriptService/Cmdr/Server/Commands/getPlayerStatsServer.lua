--!strict
--!native
--[[
	getPlayerStatsServer
	Server-side Run for /getPlayerStats. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared getPlayerStats.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, player: Player)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local BaseService = require(ServerScriptService.BaseService)
	local PlayerService = require(ServerScriptService.PlayerService)
	local EconomyService = require(ServerScriptService.EconomyService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	local userId = player.UserId
	local money = EconomyService.GetMoney(userId)
	local snap = BaseService.Snapshot(userId)
	-- Phase 2: single 6-slot pool, split by OccupantKind.
	local eggCount = 0
	local animalCount = 0
	if snap and snap.slots then
		for _, s in ipairs(snap.slots) do
			if s.State == 'Occupied' then
				if s.OccupantKind == 'egg' then
					eggCount = eggCount + 1
				elseif s.OccupantKind == 'animal' then
					animalCount = animalCount + 1
				end
			end
		end
	end
	local baseId = PlayerService.GetBaseId(userId) or '<none>'
	return table.concat({
		('Player: %s (%d)'):format(player.Name, userId),
		('Money: $%s'):format(money),
		('Base: %s'):format(tostring(baseId)),
		('Eggs: %d'):format(eggCount),
		('Animals: %d'):format(animalCount),
	}, '\n')
end
