--!strict
--!native
--[[
	giveArenaXpServer
	Server-side Run for /givearenaxp. Canonical AddArenaXP per
	target; the service owns thresholds, level-ups, and
	persistence. Notifies targets with their new level.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, amount: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ArenaProgressionService = require(ServerScriptService.Arena.ArenaProgressionService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'givearenaxp', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'givearenaxp', { target = target }, false, err)
		return err
	end
	if type(amount) ~= 'number' or amount ~= math.floor(amount) or amount <= 0 then
		local err = 'amount must be a positive whole number.'
		AdminAudit.Log(context.Executor.UserId, 'givearenaxp', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = ArenaProgressionService.AddArenaXP(player.UserId, amount)
		end)
		if type(result) == 'table' then
			succeeded += 1
			AdminNotify.Tell(
				player,
				(('An administrator granted you %d arena XP (now arena Lv.%s)!'):format(amount, tostring(result.Level)))
			)
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Granted %d arena XP to %s.'):format(amount, players[1].Name)
			else ('Could not grant arena XP to %s.'):format(players[1].Name)
	else
		summary = ('Granted %d arena XP to %d of %d players.'):format(amount, succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'givearenaxp', {
		target = target,
		amount = tostring(amount),
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
