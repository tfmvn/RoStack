--!strict
--!native
--[[
	playtimeInfoServer
	Server-side Run for /playtimeinfo. Pure read path over
	PlaytimeRewardsService.GetSnapshot. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlaytimeRewardsService = require(ServerScriptService.Playtime.PlaytimeRewardsService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'playtimeinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'playtimeinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local snap: any = nil
		pcall(function()
			snap = PlaytimeRewardsService.GetSnapshot(player.UserId)
		end)
		if type(snap) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: no playtime state =='):format(player.Name)
		else
			blocks[#blocks + 1] = ('== %s: playtime %ss =='):format(player.Name, tostring(snap.Playtime))
			if type(snap.Rewards) == 'table' then
				for _, entry in ipairs(snap.Rewards) do
					if type(entry) == 'table' then
						blocks[#blocks + 1] = ('  #%s (%ss): %s'):format(
							tostring(entry.Index),
							tostring(entry.RequiredPlaytime),
							tostring(entry.State)
						)
					end
				end
			end
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'playtimeinfo', { target = target }, true, 'inspected')
	return summary
end
