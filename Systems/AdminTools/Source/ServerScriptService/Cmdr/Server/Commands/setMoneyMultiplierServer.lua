--!strict
--!native
--[[
	setMoneyMultiplierServer
	Server-side Run for /setmoneymultiplier. Replaces the
	'AdminOverride' money source (remove-then-add, so repeated
	sets never stack) and confirms via GetMoneyMultiplier.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local ADMIN_SOURCE = 'AdminOverride'

return function(context, target: string, value: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ModifierService = require(ServerScriptService.ModifierService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'setmoneymultiplier', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'setmoneymultiplier', { target = target }, false, err)
		return err
	end
	if type(value) ~= 'number' or value ~= value or value < 0.01 or value > 100 then
		local err = 'value must be a number between 0.01 and 100.'
		AdminAudit.Log(context.Executor.UserId, 'setmoneymultiplier', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local applied = 0
		pcall(function()
			ModifierService.RemoveModifier(player.UserId, ADMIN_SOURCE, 'Money')
			local okAdd = ModifierService.AddModifier(player.UserId, ADMIN_SOURCE, 'Money', value, 'Multiply')
			if okAdd then
				applied = ModifierService.GetMoneyMultiplier(player.UserId)
			end
		end)
		-- Live base label: the owner's MoneyMultPart shows the
		-- new multiplier immediately.
		pcall(function()
			local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
			if RebirthService and RebirthService.RefreshBaseMultiplier then
				RebirthService.RefreshBaseMultiplier(player.UserId)
			end
		end)
		if applied > 0 then
			succeeded += 1
			AdminNotify.Tell(player, (('An administrator set your money multiplier to %sx.'):format(tostring(applied))))
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Set %s money multiplier to %sx.'):format(players[1].Name, tostring(value))
			else ('Could not set multiplier for %s.'):format(players[1].Name)
	else
		summary = ('Set money multiplier to %sx for %d of %d players.'):format(tostring(value), succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'setmoneymultiplier', {
		target = target,
		value = tostring(value),
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
