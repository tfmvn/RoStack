--!strict
--!native
--[[
	arenaInfoServer
	Server-side Run for /arenainfo. Pure read path over
	ArenaProgressionService + ArenaService session state.
	Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ArenaProgressionService = require(ServerScriptService.Arena.ArenaProgressionService)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'arenainfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'arenainfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local state: any = nil
		pcall(function()
			state = ArenaProgressionService.GetArenaState(player.UserId)
		end)
		local active = false
		pcall(function()
			active = ArenaService.HasActiveRaid(player.UserId) == true
		end)
		if type(state) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: no arena state =='):format(player.Name)
		else
			blocks[#blocks + 1] = ('== %s: arena Lv.%s (%s/%s XP), wins %s, best %s, raid=%s =='):format(
				player.Name,
				tostring(state.Level),
				tostring(state.XP),
				tostring(state.XPRequired),
				tostring(state.Wins),
				tostring(state.HighestCompleted),
				if active then 'ACTIVE' else 'idle'
			)
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'arenainfo', { target = target }, true, 'inspected')
	return summary
end
