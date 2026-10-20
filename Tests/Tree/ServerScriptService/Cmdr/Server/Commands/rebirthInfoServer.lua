--!strict
--!native
--[[
	rebirthInfoServer
	Server-side Run for /rebirthinfo. Pure read path over
	RebirthService.GetRebirth + BuildState. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'rebirthinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'rebirthinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local current = 0
		pcall(function()
			current = RebirthService.GetRebirth(player.UserId)
		end)
		local state: any = nil
		pcall(function()
			state = RebirthService.BuildState(player.UserId)
		end)
		if type(state) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: rebirth %d (no further state) =='):format(player.Name, current)
		elseif state.Maxed == true then
			blocks[#blocks + 1] = ('== %s: rebirth %d (MAXED) =='):format(player.Name, current)
		else
			blocks[#blocks + 1] = ('== %s: rebirth %d -> %s =='):format(player.Name, current, tostring(state.Next))
			blocks[#blocks + 1] = ('  money: %s / %s %s'):format(
				tostring(state.Money),
				tostring(state.MoneyRequired),
				if state.MoneySatisfied then '[ok]' else '[NEED]'
			)
			blocks[#blocks + 1] = ('  arena: %s / %s %s'):format(
				tostring(state.ArenaLevel),
				tostring(state.ArenaRequired),
				if state.ArenaSatisfied then '[ok]' else '[NEED]'
			)
			if type(state.Animals) == 'table' then
				for _, row in ipairs(state.Animals) do
					if type(row) == 'table' then
						blocks[#blocks + 1] = ('  animal %s trait=%s minLv=%s %s'):format(
							tostring(row.DefId),
							tostring(row.Trait),
							tostring(row.MinimumLevel),
							if row.Matched then '[ok]' else '[NEED]'
						)
					end
				end
			end
			blocks[#blocks + 1] = ('  canRebirth: %s'):format(tostring(state.CanRebirth))
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'rebirthinfo', { target = target }, true, 'inspected')
	return summary
end
