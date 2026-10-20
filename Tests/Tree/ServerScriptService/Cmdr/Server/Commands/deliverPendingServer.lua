--!strict
--!native
--[[
	deliverPendingServer
	Server-side Run for /deliverpending. Canonical
	CodesService.TryDeliverPending per target. The service
	toasts delivered targets itself (Codes_PendingDelivered).
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local CodesService = require(ServerScriptService.Codes.CodesService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'deliverpending', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'deliverpending', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	for _, player in ipairs(players) do
		local delivered = false
		pcall(function()
			delivered = CodesService.TryDeliverPending(player.UserId) == true
		end)
		if delivered then
			succeeded += 1
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Delivered queued rewards to %s.'):format(players[1].Name)
			else ('No queued rewards could be delivered to %s (none pending or still no free slot).'):format(
				players[1].Name
			)
	else
		summary = ('Delivered queued rewards for %d of %d players.'):format(succeeded, #players)
	end
	AdminAudit.Log(context.Executor.UserId, 'deliverpending', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, true, summary)
	return summary
end
