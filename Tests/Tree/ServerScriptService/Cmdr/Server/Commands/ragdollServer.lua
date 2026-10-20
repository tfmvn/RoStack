--!strict
--!native
--[[
	ragdollServer
	Server-side Run for /ragdoll. Canonical
	RagdollService.Ragdoll per target. No second ragdoll
	implementation exists in this command.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, duration: number?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local RagdollService = require(ServerScriptService.Combat.RagdollService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'ragdoll', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'ragdoll', { target = target }, false, err)
		return err
	end
	local seconds = 5
	if duration ~= nil then
		if type(duration) ~= 'number' or duration ~= math.floor(duration) or duration < 1 or duration > 30 then
			local err = 'duration must be a whole number of seconds between 1 and 30.'
			AdminAudit.Log(context.Executor.UserId, 'ragdoll', { target = target }, false, err)
			return err
		end
		seconds = duration
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local ragdolled = false
		pcall(function()
			ragdolled = RagdollService.Ragdoll(player, seconds) == true
		end)
		if ragdolled then
			succeeded += 1
			AdminNotify.Tell(player, 'An administrator ragdolled you.')
		else
			failures[#failures + 1] = ('%s (already ragdolled or unavailable)'):format(player.Name)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Ragdolled %s for %ds.'):format(players[1].Name, seconds)
			else ('Could not ragdoll %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Ragdolled %d of %d players for %ds.'):format(succeeded, #players, seconds)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'ragdoll', {
		target = target,
		duration = tostring(seconds),
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
