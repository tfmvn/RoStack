--!strict
--!native
--[[
	startArenaServer
	Server-side Run for /startarena. Delegates to
	ArenaService.StartArena per target with the validated
	option. Normal start validation applies (team, raid lock,
	carry/steal, funds for paid options).
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, option: string?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ArenaService = require(ServerScriptService.Arena.ArenaService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'startarena', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'startarena', { target = target }, false, err)
		return err
	end
	local useOption = option or 'Buy3'
	if useOption ~= 'Buy1' and useOption ~= 'Buy2' and useOption ~= 'Buy3' then
		local err = 'Unknown arena option. Pick one of: Buy1, Buy2, Buy3.'
		AdminAudit.Log(context.Executor.UserId, 'startarena', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		pcall(function()
			result = ArenaService.StartArena(player, useOption)
		end)
		if type(result) == 'table' and result.success == true then
			succeeded += 1
			AdminNotify.Tell(
				player,
				(
					('An administrator started your expedition (stage %s)!'):format(
						tostring(if type(result) == 'table' then result.startLevel else '?')
					)
				)
			)
		else
			local reason = 'start rejected'
			if type(result) == 'table' and result.error ~= nil then
				reason = tostring(result.error)
			end
			failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Started arena expedition for %s (%s).'):format(players[1].Name, useOption)
			else ('Could not start arena for %s: %s.'):format(players[1].Name, table.concat(failures, '; '))
	else
		summary = ('Started arena for %d of %d players (%s).'):format(succeeded, #players, useOption)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'startarena', {
		target = target,
		option = useOption,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
