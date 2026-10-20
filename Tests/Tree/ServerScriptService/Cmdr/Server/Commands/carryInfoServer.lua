--!strict
--!native
--[[
	carryInfoServer
	Server-side Run for /carryinfo. Pure read path over
	CarryRegistry (+ StealService for the steal flag). Never
	mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'carryinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'carryinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local snapshot: any = nil
		pcall(function()
			snapshot = CarryRegistry.Snapshot(player.UserId)
		end)
		local kind: any = nil
		pcall(function()
			kind = CarryRegistry.GetKind(player.UserId)
		end)
		local stealing = false
		pcall(function()
			local StealService = require(ServerScriptService.Steal.StealService)
			stealing = StealService.IsStealCarry(player.UserId) == true
		end)
		if type(snapshot) ~= 'table' or snapshot.Kind == nil then
			blocks[#blocks + 1] = ('== %s: carrying nothing =='):format(player.Name)
		else
			blocks[#blocks + 1] = ('== %s: carrying %s (kind=%s, steal=%s) =='):format(
				player.Name,
				tostring(snapshot.Name),
				tostring(kind),
				tostring(stealing)
			)
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'carryinfo', { target = target }, true, 'inspected')
	return summary
end
