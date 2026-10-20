--!strict
--!native
--[[
	baseInfoServer
	Server-side Run for /baseinfo. Pure read path over
	BaseService + BaseLockService. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local BaseService = require(ServerScriptService.BaseService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'baseinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'baseinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local base: any = nil
		pcall(function()
			base = BaseService.GetPlayerBase(player.UserId)
		end)
		if type(base) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: no base assigned =='):format(player.Name)
		else
			local baseId = tostring(base.id)
			local locked = false
			local remaining = 0
			pcall(function()
				local BaseLockService = require(ServerScriptService.Base.BaseLockService)
				locked = BaseLockService.IsLocked(baseId) == true
				remaining = BaseLockService.GetRemainingTime(baseId)
			end)
			local occupied = 0
			local slotCount = 0
			pcall(function()
				local snap = BaseService.Snapshot(player.UserId)
				if type(snap) == 'table' then
					occupied = tonumber(snap._occupiedCount) or 0
					if type(snap.slots) == 'table' then
						slotCount = #snap.slots
					end
				end
			end)
			blocks[#blocks + 1] = ('== %s: base %s =='):format(player.Name, baseId)
			blocks[#blocks + 1] = ('  slots: %d occupied / %d total'):format(occupied, slotCount)
			blocks[#blocks + 1] = ('  lock: %s%s'):format(
				if locked then 'LOCKED' else 'unlocked',
				if locked then (' (%ds left)'):format(math.floor(remaining)) else ''
			)
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'baseinfo', { target = target }, true, 'inspected')
	return summary
end
