--!strict
--!native
--[[
	tellServer
	Server-side Run for /tell. Private per-target toasts via
	AdminNotify (category Admin). Text is RichText-escaped like
	/announce so no markup can be injected.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, message: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'tell', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'tell', { target = target }, false, err)
		return err
	end
	if type(message) ~= 'string' or #message == 0 then
		local err = 'message must be a non-empty string.'
		AdminAudit.Log(context.Executor.UserId, 'tell', { target = target }, false, err)
		return err
	end
	if #message > 240 then
		local err = 'message is too long (max 240 characters).'
		AdminAudit.Log(context.Executor.UserId, 'tell', { target = target }, false, err)
		return err
	end
	local safe = AdminNotify.Escape(message)
	for _, player in ipairs(resolved.players) do
		AdminNotify.Tell(player, safe)
	end
	local summary = ('Sent private message to %d player(s).'):format(#resolved.players)
	AdminAudit.Log(context.Executor.UserId, 'tell', {
		target = target,
		count = tostring(#resolved.players),
	}, true, summary)
	return summary
end
