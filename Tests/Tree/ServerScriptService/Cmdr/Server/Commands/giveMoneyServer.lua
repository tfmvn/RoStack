--!strict
--!native
--[[
	giveMoneyServer
	Server-side Run for /giveMoney. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared giveMoney.lua carries the
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
	-- The amount is already a string. EconomyService
	-- sanitizes once on the way in; we pass the
	-- canonical form so the audit log is consistent.
	local sanitized = BigNumber.sanitize(amount) or '0'
	if BigNumber.IsZero(sanitized) then
		return 'amount must be positive (a zero grant is a no-op).'
	end
	local result = EconomyService.AddMoney(player.UserId, sanitized, TransactionReason.AdminGive)
	if not result.Success then
		return ('givemoney failed: %s (code=%s)'):format(tostring(result.Reason), tostring(result.Code))
	end
	local snap = BaseService.Snapshot(player.UserId)
	PlayerService.PushState(player, snap)
	Debug.Log('CMDR', 'givemoney', {
		target = player.UserId,
		amount = sanitized,
		newBalance = tostring(result.NewMoney),
		by = context.Executor.UserId,
	})
	return ('Gave $%s to %s (new balance: $%s).'):format(sanitized, player.Name, tostring(result.NewMoney))
end
