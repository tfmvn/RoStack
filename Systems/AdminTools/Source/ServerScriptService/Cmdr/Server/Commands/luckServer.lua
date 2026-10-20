--!strict
--!native
--[[
	luckServer
	Server-side Run for /luck. Get/set/reset the server-wide
	Luck multiplier through the canonical ServerLuckService
	(the same state the normal Egg rarity roll reads). Luck is
	server-authoritative: validated here, published to the
	replicated attribute, and reflected in HUD.ServerLuck for
	every player. Accepts any finite positive number (0.5 …
	1000000); rejects garbage, zero/negatives, and infinities.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local function formatLuck(n: number): string
	return ('%.1fx'):format(n)
end

return function(context, value: string?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local ServerLuckService = require(ServerScriptService.ServerLuckService)
	AdminService.AssertCanRun(context.Executor.UserId, 'admin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'luck', { value = tostring(value) }, false, rateErr)
		return rateErr
	end

	if value == nil or value == '' then
		local current = ServerLuckService.GetLuck()
		local summary = ('Server Luck: %s.'):format(formatLuck(current))
		AdminAudit.Log(context.Executor.UserId, 'luck', { value = '' }, true, summary)
		return summary
	end

	if string.lower(value) == 'reset' then
		ServerLuckService.ResetLuck()
		local summary = ('Server Luck reset to %s.'):format(formatLuck(ServerLuckService.GetLuck()))
		AdminAudit.Log(context.Executor.UserId, 'luck', { value = value }, true, summary)
		return summary
	end

	local n = tonumber(value)
	if n == nil then
		local err = ('Invalid luck %q. Use a positive number (e.g. 2, 0.5, 100), "reset", or omit to show current.'):format(
			tostring(value)
		)
		AdminAudit.Log(context.Executor.UserId, 'luck', { value = tostring(value) }, false, err)
		return err
	end
	if not ServerLuckService.SetLuck(n) then
		local err = ('Invalid luck %q. Must be a finite positive number up to %s.'):format(
			tostring(value),
			tostring(ServerLuckService.MaxLuck())
		)
		AdminAudit.Log(context.Executor.UserId, 'luck', { value = tostring(value) }, false, err)
		return err
	end
	local summary = ('Server Luck = %s.'):format(formatLuck(ServerLuckService.GetLuck()))
	AdminAudit.Log(context.Executor.UserId, 'luck', { value = tostring(value) }, true, summary)
	return summary
end
