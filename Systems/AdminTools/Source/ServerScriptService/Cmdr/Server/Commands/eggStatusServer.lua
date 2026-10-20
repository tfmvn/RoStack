--!strict
--!native
--[[
	eggStatusServer
	Server-side Run for /eggstatus. Pure read path over
	SpawnService counts. No mutation, so no
	target notifications; the report goes to the admin only.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local CenterSpawn = require(ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn

return function(context)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'eggstatus', nil, false, rateErr)
		return rateErr
	end
	local lines: { string } = {}
	local available = 0
	pcall(function()
		available = SpawnService.CountByState('Available')
	end)
	local cap = CenterSpawn.CenterMax
	lines[#lines + 1] = ('Center eggs: %d / %d active (spawn every %ds)'):format(
		available,
		cap,
		CenterSpawn.Interval
	)
	pcall(function()
		for _, state in ipairs({ 'Traveling', 'Placed', 'Opening' }) do
			lines[#lines + 1] = ('  %s: %d'):format(state, SpawnService.CountByState(state))
		end
	end)
	local summary = table.concat(lines, '\n')
	AdminAudit.Log(context.Executor.UserId, 'eggstatus', nil, true, 'reported')
	return summary
end
