--!strict
--!native
--[[
	unragdollServer
	Server-side Run for /unragdoll. Canonical
	RagdollService.Unragdoll per target (nil token: the manual
	admin recovery path, distinct from the timed auto-call).
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local RagdollService = require(ServerScriptService.Combat.RagdollService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'unragdoll', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'unragdoll', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local recovered = false
		pcall(function()
			recovered = RagdollService.Unragdoll(player) == true
		end)
		if recovered then
			succeeded += 1
			AdminNotify.Tell(player, 'An administrator stood you back up.')
		else
			failures[#failures + 1] = ('%s (not ragdolled)'):format(player.Name)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Stood %s back up.'):format(players[1].Name)
			else ('Could not unragdoll %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Stood up %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'unragdoll', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
