--!strict
--!native
--[[
	giveCashServer
	Server-side Run for /givecash. Multi-target money grant
	through the canonical EconomyService.AddMoney (AdminGive)
	per player, with per-target private toasts and an aggregate
	admin confirmation. Notifies only after commit.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Validation = require(game.ReplicatedStorage.Utility.Validation)
local BigNumber = require(game.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(game.ReplicatedStorage.Types.TransactionReason)

return function(context, target: string, amount: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local EconomyService = require(ServerScriptService.EconomyService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'givecash', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'givecash', { target = target }, false, err)
		return err
	end
	if not Validation.BigNumberString(amount) then
		local err = 'amount must be a valid BigNumber string (e.g. "1000", "5e12").'
		AdminAudit.Log(context.Executor.UserId, 'givecash', { target = target }, false, err)
		return err
	end
	local sanitized = BigNumber.sanitize(amount) or '0'
	if BigNumber.IsZero(sanitized) then
		local err = 'amount must be positive (a zero grant is a no-op).'
		AdminAudit.Log(context.Executor.UserId, 'givecash', { target = target }, false, err)
		return err
	end
	local players = resolved.players
	local scope = resolved.scope
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local result: any = nil
		local okCall = pcall(function()
			result = EconomyService.AddMoney(player.UserId, sanitized, TransactionReason.AdminGive)
		end)
		if okCall and type(result) == 'table' and result.Success == true then
			succeeded += 1
			pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
			AdminNotify.Tell(
				player,
				('You received %s.'):format(AdminNotify.Escape(AdminNotify.FormatMoney(sanitized)))
			)
		else
			local reason = 'grant failed'
			if type(result) == 'table' and result.Reason ~= nil then
				reason = tostring(result.Reason)
			end
			failures[#failures + 1] = ('%s (%s)'):format(player.Name, reason)
		end
	end
	local summary: string
	if #players == 1 then
		if succeeded == 1 then
			summary = ('Added %s to %s.'):format(AdminNotify.FormatMoney(sanitized), players[1].Name)
		else
			summary = ('Failed to add %s to %s: %s.'):format(
				AdminNotify.FormatMoney(sanitized),
				players[1].Name,
				table.concat(failures, '; ')
			)
		end
	else
		summary = ('Added %s to %d of %d players.'):format(AdminNotify.FormatMoney(sanitized), succeeded, #players)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	_ = scope
	AdminAudit.Log(context.Executor.UserId, 'givecash', {
		target = target,
		amount = sanitized,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
