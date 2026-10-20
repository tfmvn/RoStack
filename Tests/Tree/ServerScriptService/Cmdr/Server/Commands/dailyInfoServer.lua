--!strict
--!native
--[[
	dailyInfoServer
	Server-side Run for /dailyinfo. Pure read path over
	DailyRewardsService.GetSnapshot. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local DailyRewardsService = require(ServerScriptService.Daily.DailyRewardsService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'dailyinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'dailyinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local snap: any = nil
		pcall(function()
			snap = DailyRewardsService.GetSnapshot(player.UserId)
		end)
		if type(snap) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: no daily state =='):format(player.Name)
		else
			blocks[#blocks + 1] = ('== %s: day %s, claimable %s, canClaim=%s =='):format(
				player.Name,
				tostring(snap.Day),
				tostring(snap.ClaimableDay),
				tostring(snap.CanClaim)
			)
			if type(snap.Days) == 'table' then
				for _, entry in ipairs(snap.Days) do
					if type(entry) == 'table' then
						blocks[#blocks + 1] = ('  day %s: %s'):format(tostring(entry.Day), tostring(entry.State))
					end
				end
			end
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'dailyinfo', { target = target }, true, 'inspected')
	return summary
end
