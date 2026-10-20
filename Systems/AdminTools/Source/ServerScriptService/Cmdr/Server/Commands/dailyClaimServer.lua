--!strict
--!native
--[[
	dailyClaimServer
	Server-side Run for /dailyclaim. Delegates to
	DailyRewardsService.Claim with the TARGET's Player object.
	The service toasts the target itself on success; the command
	aggregates for the admin.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, day: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local DailyRewardsService = require(ServerScriptService.Daily.DailyRewardsService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'dailyclaim', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'dailyclaim', { target = target }, false, err)
		return err
	end
	if type(day) ~= 'number' or day ~= math.floor(day) or day < 1 or day > 7 then
		local err = 'day must be a whole number between 1 and 7.'
		AdminAudit.Log(context.Executor.UserId, 'dailyclaim', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = DailyRewardsService.Claim(player, day)
		end)
		if type(result) == 'table' and result.Success == true then
			succeeded += 1
		else
			local reason = 'claim rejected'
			if type(result) == 'table' and result.Reason ~= nil then
				reason = tostring(result.Reason)
			end
			failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Claimed daily day %d for %s.'):format(day, players[1].Name)
			else ('Could not claim daily day %d for %s: %s.'):format(
				day,
				players[1].Name,
				table.concat(failures, '; ')
			)
	else
		summary = ('Claimed daily day %d for %d of %d players.'):format(day, succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'dailyclaim', {
		target = target,
		day = tostring(day),
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
