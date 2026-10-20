--!strict
--!native
--[[
	giveAllGearServer
	Server-side Run for /giveallgear. Iterates the live
	GearConfig catalog (never a hardcoded list) and grants each
	entry via GearShopService.EnsureGearTool.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local GearShopService = require(ServerScriptService.GearShop.GearShopService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'giveallgear', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'giveallgear', { target = target }, false, err)
		return err
	end
	local catalog = GearConfig.GetAll()
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local granted = 0
		for _, entry in ipairs(catalog) do
			local okOne = false
			pcall(function()
				okOne = GearShopService.EnsureGearTool(player, entry.Id) == true
			end)
			if okOne then
				granted += 1
			end
		end
		if granted > 0 then
			succeeded += 1
			AdminNotify.Tell(player, (('An administrator granted you %d gear tools!'):format(granted)))
		else
			failures[#failures + 1] = player.Name
		end
	end
	local summary: string
	if #players == 1 then
		summary = if succeeded == 1
			then ('Granted all gear (%d entries) to %s.'):format(#catalog, players[1].Name)
			else ('Could not grant gear to %s.'):format(players[1].Name)
	else
		summary = ('Granted all gear to %d of %d players.'):format(succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, ', ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'giveallgear', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
