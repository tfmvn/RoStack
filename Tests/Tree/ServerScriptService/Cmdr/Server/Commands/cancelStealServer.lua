--!strict
--!native
--[[
	cancelStealServer
	Server-side Run for /cancelsteal. Canonical
	StealService.RollbackCarried per stealing target only.
	Non-stealing targets fail with a precise per-player reason;
	nothing else is touched.
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
	local StealService = require(ServerScriptService.Steal.StealService)
	AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'cancelsteal', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'cancelsteal', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		if StealService.IsStealCarry(player.UserId) ~= true then
			failures[#failures + 1] = ('%s (not stealing)'):format(player.Name)
		else
			local result: any = nil
			pcall(function()
				result = StealService.RollbackCarried(player.UserId, 'admin-cancel')
			end)
			if type(result) == 'table' and result.success == true then
				succeeded += 1
				pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
				AdminNotify.Tell(player, 'An administrator cancelled your steal; the item was returned.')
			else
				local reason = 'rollback failed'
				if type(result) == 'table' and result.error ~= nil then
					reason = tostring(result.error)
				end
				failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
			end
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Cancelled %s steal.'):format(players[1].Name)
			else ('Could not cancel steal for %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Cancelled steal for %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'cancelsteal', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
