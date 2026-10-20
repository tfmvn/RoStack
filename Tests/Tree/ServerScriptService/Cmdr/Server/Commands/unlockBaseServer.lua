--!strict
--!native
--[[
	unlockBaseServer
	Server-side Run for /unlockbase. Canonical
	BaseLockService.Unlock per target base (idempotent — an
	unlocked base reports success with no state change).
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local BaseService = require(ServerScriptService.BaseService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'unlockbase', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'unlockbase', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local base: any = nil
		pcall(function()
			base = BaseService.GetPlayerBase(player.UserId)
		end)
		if type(base) ~= 'table' then
			failures[#failures + 1] = ('%s (no base)'):format(player.Name)
		else
			pcall(function()
				local BaseLockService = require(ServerScriptService.Base.BaseLockService)
				BaseLockService.Unlock(tostring(base.id))
			end)
			succeeded += 1
			AdminNotify.Tell(player, 'An administrator unlocked your base.')
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Unlocked %s base.'):format(players[1].Name)
			else ('Could not unlock %s base: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Unlocked %d of %d bases.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'unlockbase', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
