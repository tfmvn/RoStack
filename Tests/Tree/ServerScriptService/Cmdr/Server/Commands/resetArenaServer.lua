--!strict
--!native
--[[
	resetArenaServer
	Server-side Run for /resetarena. Ends any active raid first
	(so combat/escrow/session state is never stranded), then the
	canonical ResetArena, then pushes arena + player state.
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
	local ArenaProgressionService = require(ServerScriptService.Arena.ArenaProgressionService)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)
	AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'resetarena', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'resetarena', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		pcall(ArenaService.CancelArena, player)
		local resetOk = false
		pcall(function()
			resetOk = ArenaProgressionService.ResetArena(player.UserId) == true
		end)
		if resetOk then
			succeeded += 1
			pcall(ArenaService.PushState, player)
			pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
			AdminNotify.Tell(player, 'An administrator reset your arena progression to level 1.')
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Reset arena progression for %s.'):format(players[1].Name)
			else ('Could not reset arena for %s.'):format(players[1].Name)
	else
		summary = ('Reset arena for %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'resetarena', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
