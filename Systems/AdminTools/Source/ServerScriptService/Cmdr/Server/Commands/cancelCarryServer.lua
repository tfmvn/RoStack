--!strict
--!native
--[[
	cancelCarryServer
	Server-side Run for /cancelcarry. Mirrors the bootstrap
	shared.RecoverCarry dispatch exactly (steal rollback first,
	then kind dispatch), plus a state push per recovered player.
	Never manipulates carried models by hand.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'cancelcarry', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'cancelcarry', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local userId = player.UserId
		local hadCarry = false
		pcall(function()
			local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
			hadCarry = CarryRegistry.Get(userId) ~= nil
		end)
		if not hadCarry then
			failures[#failures + 1] = ('%s (carrying nothing)'):format(player.Name)
		else
			pcall(function()
				local StealService = require(ServerScriptService.Steal.StealService)
				if StealService.RollbackIfStealing(userId, 'admin-cancel') then
					return
				end
				local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
				local ReplicatedStorage = game:GetService('ReplicatedStorage')
				local SlotType = require(ReplicatedStorage.Types.SlotType)
				local kind = CarryRegistry.GetKind(userId)
				if kind == SlotType.OccupantKind.Animal then
					local AnimalService = require(ServerScriptService.AnimalService)
					AnimalService.RecoverCarriedAnimal(userId, 'admin-cancel')
				elseif kind == SlotType.OccupantKind.Egg then
					local EggService = require(ServerScriptService.EggService)
					EggService.RecoverCarriedEgg(player, 'admin-cancel')
				end
			end)
			local stillCarrying = true
			pcall(function()
				local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
				stillCarrying = CarryRegistry.Get(userId) ~= nil
			end)
			if not stillCarrying then
				succeeded += 1
				pcall(PlayerService.PushState, player, BaseService.Snapshot(userId))
				AdminNotify.Tell(player, 'An administrator returned your carried item to its slot.')
			else
				failures[#failures + 1] = ('%s (recovery failed)'):format(player.Name)
			end
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Returned %s carried item.'):format(players[1].Name)
			else ('Could not cancel carry for %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Cancelled carry for %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'cancelcarry', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
