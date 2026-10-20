--!strict
--!native
--[[
	giveArenaWinServer
	Server-side Run for /givearenawin. Canonical RecordLevelWin
	per target; the service owns wins/highest/first-clear
	bookkeeping. No rewards are granted by a recorded win
	(rewards only settle through real battles) — stated plainly
	in the confirmation.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, level: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ArenaProgressionService = require(ServerScriptService.Arena.ArenaProgressionService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'givearenawin', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'givearenawin', { target = target }, false, err)
		return err
	end
	local okStage, stage = AdminArgs.ResolveArenaLevel(level)
	if not okStage then
		AdminAudit.Log(context.Executor.UserId, 'givearenawin', { target = target }, false, stage)
		return stage
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = ArenaProgressionService.RecordLevelWin(player.UserId, stage)
		end)
		if type(result) == 'table' then
			succeeded += 1
			AdminNotify.Tell(player, (('An administrator recorded your clear of arena stage %d!'):format(stage)))
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Recorded arena stage %d clear for %s (no battle rewards granted).'):format(stage, players[1].Name)
			else ('Could not record arena win for %s.'):format(players[1].Name)
	else
		summary = ('Recorded stage %d clear for %d of %d players (no battle rewards granted).'):format(
			stage,
			succeeded,
			#players
		)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'givearenawin', {
		target = target,
		level = tostring(stage),
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
