--!strict
--!native
--[[
	clearMoneyMultiplierServer
	Server-side Run for /clearmoneymultiplier. Canonical
	RemoveModifier per target; confirms the resolved multiplier
	afterwards.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local ADMIN_SOURCE = 'AdminOverride'

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ModifierService = require(ServerScriptService.ModifierService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'clearmoneymultiplier', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'clearmoneymultiplier', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local succeeded = 0
	for _, player in ipairs(players) do
		local now = 0
		pcall(function()
			ModifierService.RemoveModifier(player.UserId, ADMIN_SOURCE, 'Money')
			now = ModifierService.GetMoneyMultiplier(player.UserId)
		end)
		-- Live base label: the owner's MoneyMultPart shows the
		-- restored multiplier immediately.
		pcall(function()
			local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
			if RebirthService and RebirthService.RefreshBaseMultiplier then
				RebirthService.RefreshBaseMultiplier(player.UserId)
			end
		end)
		if now > 0 then
			succeeded += 1
			AdminNotify.Tell(
				player,
				(('An administrator cleared your bonus multiplier (now %sx).'):format(tostring(now)))
			)
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Cleared admin multiplier for %s.'):format(players[1].Name)
			else ('Could not clear multiplier for %s.'):format(players[1].Name)
	else
		summary = ('Cleared admin multiplier for %d of %d players.'):format(succeeded, #players)
	end
	AdminAudit.Log(context.Executor.UserId, 'clearmoneymultiplier', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
