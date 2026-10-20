--!strict
--!native
--[[
	giveGearServer
	Server-side Run for /givegear. Canonical grant only:
	GearShopService.EnsureGearTool (the same idempotent grant the
	shop's own purchase path ends with). Never clones tools by
	hand, never touches the purchase ledger.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, gear: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local GearShopService = require(ServerScriptService.GearShop.GearShopService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'givegear', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'givegear', { target = target }, false, err)
		return err
	end
	local okGear, gearId, entry = AdminArgs.ResolveGear(gear)
	if not okGear then
		AdminAudit.Log(context.Executor.UserId, 'givegear', { target = target }, false, gearId)
		return gearId
	end
	local gearName = gearId
	if type(entry) == 'table' and type(entry.Name) == 'string' then
		gearName = entry.Name
	end
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local granted = false
		pcall(function()
			granted = GearShopService.EnsureGearTool(player, gearId) == true
		end)
		if granted then
			succeeded += 1
			AdminNotify.Tell(player, ('You received %s!'):format(AdminNotify.Escape(gearName)))
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		if succeeded == 1 then
			summary = ('Gave %s to %s.'):format(gearName, players[1].Name)
		else
			summary = ('Could not grant %s to %s.'):format(gearName, players[1].Name)
		end
	else
		summary = ('Gave %s to %d of %d players.'):format(gearName, succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'givegear', {
		target = target,
		gear = gearId,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
