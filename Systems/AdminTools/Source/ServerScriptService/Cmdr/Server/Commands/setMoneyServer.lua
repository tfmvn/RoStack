--!strict
--!native
--[[
	setMoneyServer
	Server-side Run for /setMoney. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared setMoney.lua carries the
	definition (Name/Group/Args) and is replicated to the client,
	which forwards execution here through the Cmdr RemoteFunction.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

local Validation = require(game.ReplicatedStorage.Utility.Validation)

local BigNumber = require(game.ReplicatedStorage.Utility.BigNumber)

local TransactionReason = require(game.ReplicatedStorage.Types.TransactionReason)

return function(context, player: Player, amount: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local EconomyService = require(ServerScriptService.EconomyService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if not player or not player.Parent then
		return 'That player is not in-game.'
	end
	if not Validation.BigNumberString(amount) then
		return 'amount must be a valid BigNumber string (e.g. "1000", "5e12", "1.5Qa").'
	end
	local target = BigNumber.sanitize(amount) or '0'
	-- Compute the delta from the current balance. Admins may
	-- set ANY absolute value: a higher target grants the
	-- difference via AddMoney, a lower target claws the
	-- difference back via TrySpendMoney (cost is exactly
	-- current - target, so it can never exceed the balance).
	local current = EconomyService.GetMoney(player.UserId)
	if BigNumber.Compare(target, current) == 0 then
		return ('%s already has $%s.'):format(player.Name, target)
	end
	local result
	local delta
	if BigNumber.Compare(target, current) < 0 then
		delta = BigNumber.Subtract(current, target)
		result = EconomyService.TrySpendMoney(player.UserId, delta, TransactionReason.AdminSet)
	else
		delta = BigNumber.Subtract(target, current)
		result = EconomyService.AddMoney(player.UserId, delta, TransactionReason.AdminSet)
	end
	if not result.Success then
		return ('setmoney failed: %s (code=%s)'):format(tostring(result.Reason), tostring(result.Code))
	end
	local snap = BaseService.Snapshot(player.UserId)
	PlayerService.PushState(player, snap)
	Debug.Log('CMDR', 'setmoney', {
		target = player.UserId,
		requested = target,
		delta = delta,
		newBalance = tostring(result.NewMoney),
		capped = tostring(result.Code == 'cap-exceeded'),
		by = context.Executor.UserId,
	})
	local suffix = ''
	if result.Code == 'cap-exceeded' then
		suffix = ' (clamped to MaxMoney)'
	end
	return ('%s money is now $%s%s.'):format(player.Name, tostring(result.NewMoney), suffix)
end
