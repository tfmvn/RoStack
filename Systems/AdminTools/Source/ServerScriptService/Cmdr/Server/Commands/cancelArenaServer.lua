--!strict
--!native
--[[
	cancelArenaServer
	Server-side Run for /cancelarena. Delegates to
	ArenaService.CancelArena per target (never
	CancelBattleSilent, which skips settlement — an admin
	 Visible retreat settles like a player retreat).
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'cancelarena', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'cancelarena', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = ArenaService.CancelArena(player)
		end)
		if type(result) == 'table' and result.success == true then
			succeeded += 1
			AdminNotify.Tell(player, 'An administrator ended your arena expedition.')
		else
			local reason = 'no active session'
			if type(result) == 'table' and result.error ~= nil then
				reason = tostring(result.error)
			end
			failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Ended arena expedition for %s.'):format(players[1].Name)
			else ('Could not end arena for %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Ended arena for %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'cancelarena', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
