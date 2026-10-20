--!strict
--!native
--[[
	redeemCodeServer
	Server-side Run for /redeemcode. Delegates to
	CodesService.Redeem with the TARGET's Player object, so
	existence, enabled, expiry, per-player/global caps, reward
	shape, and delivery/queueing are identical to a player
	redeeming. The service already toasts the target; the
	command only aggregates for the admin.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, code: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local CodesService = require(ServerScriptService.Codes.CodesService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'redeemcode', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'redeemcode', { target = target }, false, err)
		return err
	end
	local okCode, codeId = AdminArgs.ResolveCode(code)
	if not okCode then
		AdminAudit.Log(context.Executor.UserId, 'redeemcode', { target = target }, false, codeId)
		return codeId
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = CodesService.Redeem(player, codeId)
		end)
		if type(result) == 'table' and result.Success == true then
			succeeded += 1
		else
			local reason = 'redeem rejected'
			if type(result) == 'table' and result.Reason ~= nil then
				reason = tostring(result.Reason)
			end
			failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Redeemed %s for %s.'):format(codeId, players[1].Name)
			else ('Could not redeem %s for %s: %s.'):format(codeId, players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Redeemed %s for %d of %d players.'):format(codeId, succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'redeemcode', {
		target = target,
		code = codeId,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
