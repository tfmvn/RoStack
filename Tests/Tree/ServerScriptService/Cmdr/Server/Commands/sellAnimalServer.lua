--!strict
--!native
--[[
	sellAnimalServer
	Server-side Run for /sellanimal. Delegates wholesale to
	SellService.SellAnimal with the OWNER's Player object, so
	ownership checks, payout math, pool settlement, teardown,
	and the owner's Sell_Success toast are identical to a
	prompt sale. The admin only triggers it.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local Players = game:GetService('Players')

return function(context, target: string, animalId: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local AnimalService = require(ServerScriptService.AnimalService)
	local SellService = require(ServerScriptService.SellService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, err)
		return err
	end
	local inScope: { [number]: boolean } = {}
	for _, p in ipairs(resolved.players) do
		inScope[p.UserId] = true
	end
	local animal: any = nil
	pcall(function()
		animal = AnimalService.Get(animalId)
	end)
	if type(animal) ~= 'table' then
		local err = ('No live animal "%s".'):format(tostring(animalId))
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, err)
		return err
	end
	if not inScope[animal.ownerUserId] then
		local err = 'That animal is not owned by the targeted player(s).'
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, err)
		return err
	end
	local owner = Players:GetPlayerByUserId(animal.ownerUserId)
	if owner == nil then
		local err = 'The owner is not in this server.'
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, err)
		return err
	end
	local displayName = animal.displayName or animal.definitionId or tostring(animalId)
	local result: any = nil
	pcall(function()
		result = SellService.SellAnimal(owner, animalId)
	end)
	if type(result) ~= 'table' or result.success ~= true then
		local errText = 'sale rejected'
		if type(result) == 'table' and result.error ~= nil then
			errText = tostring(result.error)
		end
		local err = ('Could not sell %s: %s.'):format(displayName, errText)
		AdminAudit.Log(context.Executor.UserId, 'sellanimal', { target = target }, false, err)
		return err
	end
	local summary = ('Sold %s (%s) for %s.'):format(
		displayName,
		tostring(animalId),
		AdminNotify.FormatMoney(tostring(result.payout or result.Payout or '0'))
	)
	AdminAudit.Log(context.Executor.UserId, 'sellanimal', {
		target = target,
		animalId = tostring(animalId),
	}, true, summary)
	return summary
end
