--!strict
--!native
--[[
	setCashServer
	Server-side Run for /setcash. Absolute balance set via the
	delta-derive path (read GetMoney, Compare, then AddMoney /
	TrySpendMoney with AdminSet) — the same transaction shape as
	the existing /setmoney, extended to multi-target.
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
		AdminAudit.Log(context.Executor.UserId, 'setcash', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'setcash', { target = target }, false, err)
		return err
	end
	if not Validation.BigNumberString(amount) then
		local err = 'amount must be a valid BigNumber string (e.g. "100000").'
		AdminAudit.Log(context.Executor.UserId, 'setcash', { target = target }, false, err)
		return err
	end
	local goal = BigNumber.sanitize(amount) or '0'
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local current = EconomyService.GetMoney(player.UserId)
		local cmp = BigNumber.Compare(current, goal)
		local result: any = nil
		local okCall = false
		if cmp == nil then
			failures[#failures + 1] = ('%s (balance unreadable)'):format(player.Name)
		elseif cmp == 0 then
			succeeded += 1
			AdminNotify.Tell(
				player,
				('An administrator set your balance to %s.'):format(AdminNotify.Escape(AdminNotify.FormatMoney(goal)))
			)
		elseif cmp < 0 then
			local delta = BigNumber.Subtract(goal, current)
			okCall = pcall(function()
				result = EconomyService.AddMoney(player.UserId, delta, TransactionReason.AdminSet)
			end)
			if okCall and type(result) == 'table' and result.Success == true then
				succeeded += 1
				pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
				AdminNotify.Tell(
					player,
					('An administrator set your balance to %s.'):format(
						AdminNotify.Escape(AdminNotify.FormatMoney(goal))
					)
				)
			else
				failures[#failures + 1] = ('%s (credit failed)'):format(player.Name)
			end
		else
			local delta = BigNumber.Subtract(current, goal)
			okCall = pcall(function()
				result = EconomyService.TrySpendMoney(player.UserId, delta, TransactionReason.AdminSet)
			end)
			if okCall and type(result) == 'table' and result.Success == true then
				succeeded += 1
				pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
				AdminNotify.Tell(
					player,
					('An administrator set your balance to %s.'):format(
						AdminNotify.Escape(AdminNotify.FormatMoney(goal))
					)
				)
			else
				failures[#failures + 1] = ('%s (debit failed)'):format(player.Name)
			end
		end
	end
	local summary: string
	if #players == 1 then
		if succeeded == 1 then
			summary = ('Set %s balance to %s.'):format(players[1].Name, AdminNotify.FormatMoney(goal))
		else
			summary = ('Could not set %s balance: %s.'):format(players[1].Name, table.concat(failures, '; '))
		end
	else
		summary = ('Set %d of %d players to %s.'):format(succeeded, #players, AdminNotify.FormatMoney(goal))
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'setcash', {
		target = target,
		amount = goal,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
