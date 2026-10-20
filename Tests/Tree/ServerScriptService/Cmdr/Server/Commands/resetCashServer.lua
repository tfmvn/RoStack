--!strict
--!native
--[[
	resetCashServer
	Server-side Run for /resetcash. Resets to the canonical
	EconomyConfig.StartingMoney via the /setcash delta path
	(AdminSet). Destructive confirmation lives with the caller;
	the transaction itself is exact and audited.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local BigNumber = require(game.ReplicatedStorage.Utility.BigNumber)
local EconomyConfig = require(game.ReplicatedStorage.Config.Economy.Money)
local TransactionReason = require(game.ReplicatedStorage.Types.TransactionReason)

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local EconomyService = require(ServerScriptService.EconomyService)
	AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'resetcash', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'resetcash', { target = target }, false, err)
		return err
	end
	local goal = EconomyConfig.StartingMoney
	local players = resolved.players
	local succeeded = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local current = EconomyService.GetMoney(player.UserId)
		local cmp = BigNumber.Compare(current, goal)
		local result: any = nil
		local okCall = false
		local playerOk = false
		if cmp == nil then
			failures[#failures + 1] = ('%s (balance unreadable)'):format(player.Name)
		elseif cmp == 0 then
			playerOk = true
		elseif cmp < 0 then
			local delta = BigNumber.Subtract(goal, current)
			okCall = pcall(function()
				result = EconomyService.AddMoney(player.UserId, delta, TransactionReason.AdminSet)
			end)
			if okCall and type(result) == 'table' and result.Success == true then
				playerOk = true
			else
				failures[#failures + 1] = ('%s (credit failed)'):format(player.Name)
			end
		else
			local delta = BigNumber.Subtract(current, goal)
			okCall = pcall(function()
				result = EconomyService.TrySpendMoney(player.UserId, delta, TransactionReason.AdminSet)
			end)
			if okCall and type(result) == 'table' and result.Success == true then
				playerOk = true
			else
				failures[#failures + 1] = ('%s (debit failed)'):format(player.Name)
			end
		end
		if okCall and type(result) == 'table' and result.Success == true then
			playerOk = true
		end
		if playerOk then
			succeeded += 1
			pcall(PlayerService.PushState, player, BaseService.Snapshot(player.UserId))
			AdminNotify.Tell(
				player,
				('An administrator reset your balance to %s.'):format(AdminNotify.Escape(AdminNotify.FormatMoney(goal)))
			)
		end
	end
	local summary: string
	if #players == 1 then
		if succeeded == 1 then
			summary = ('Reset %s balance to %s.'):format(players[1].Name, AdminNotify.FormatMoney(goal))
		else
			summary = ('Could not reset %s balance: %s.'):format(players[1].Name, table.concat(failures, '; '))
		end
	else
		summary = ('Reset %d of %d players to %s.'):format(succeeded, #players, AdminNotify.FormatMoney(goal))
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'resetcash', {
		target = target,
		succeeded = tostring(succeeded),
		total = tostring(#players),
	}, succeeded > 0, summary)
	return summary
end
