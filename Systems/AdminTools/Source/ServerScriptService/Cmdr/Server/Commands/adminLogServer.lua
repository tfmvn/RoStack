--!strict
--!native
--[[
	adminLogServer
	Server-side Run for /adminlog. Reads the AdminAudit ring
	buffer. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, count: number?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'adminlog', nil, false, rateErr)
		return rateErr
	end
	local entries = AdminAudit.Recent(count)
	if #entries == 0 then
		AdminAudit.Log(context.Executor.UserId, 'adminlog', nil, true, 'empty')
		return 'No admin commands recorded yet this server.'
	end
	AdminAudit.Log(context.Executor.UserId, 'adminlog', nil, true, 'viewed')
	return table.concat(entries, '\n')
end
