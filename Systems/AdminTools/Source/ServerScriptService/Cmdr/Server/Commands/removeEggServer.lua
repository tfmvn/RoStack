--!strict
--!native
--[[
	removeEggServer
	Server-side Run for /removeegg. Drops the runtime record,
	removes the persistence record, and releases the slot.
	Refuses carried / stolen / traveling eggs loudly.
	Persistence-spawned eggs reuse their profile Id as the
	runtime uniqueId, so one handle covers both stores.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, eggId: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local EggService = require(ServerScriptService.EggService)
	AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	local inScope: { [number]: boolean } = {}
	for _, p in ipairs(resolved.players) do
		inScope[p.UserId] = true
	end
	local egg: any = nil
	pcall(function()
		egg = EggService.GetEgg(eggId)
	end)
	if type(egg) ~= 'table' then
		local err = ('No live egg "%s". Only placed base eggs can be removed.'):format(tostring(eggId))
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	if not inScope[egg.ownerUserId] then
		local err = 'That egg is not owned by the targeted player(s).'
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	local ownerId = egg.ownerUserId
	local slotId = egg.slotId
	local rarity = egg.rarity or 'egg'
	if egg.state ~= 'Placed' then
		local err = ('That egg is %s; only Placed eggs can be removed.'):format(tostring(egg.state))
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	if egg.stolenBy ~= nil then
		local err = 'That egg is part of an active steal; cancel the steal first.'
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	local carried = false
	pcall(function()
		local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
		local item = CarryRegistry.Get(ownerId)
		carried = type(item) == 'table'
	end)
	if carried then
		local err = 'The owner is carrying something; cancel the carry first.'
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	local dropped = false
	-- Tear down the physical model FIRST, while the record is
	-- still live: unbind presentation, destroy the Model
	-- (overhead + prompts die with it), and clear the
	-- reference. A live model under ActiveEggs with no record
	-- is never swept and never counted, so the destroy must
	-- not be skipped.
	pcall(function()
		local StandPresentation = require(ServerScriptService.StandPresentation)
		StandPresentation.Unbind(egg.model)
	end)
	pcall(function()
		if typeof(egg.model) == 'Instance' then
			(egg.model :: Model):Destroy()
		end
	end)
	egg.model = nil
	pcall(function()
		dropped = EggService.DropEggRuntime(eggId) == true
	end)
	if not dropped then
		local err = 'Could not drop the live egg (it may have despawned).'
		AdminAudit.Log(context.Executor.UserId, 'removeegg', { target = target }, false, err)
		return err
	end
	pcall(PlayerService.RemoveEgg, ownerId, eggId)
	if type(slotId) == 'string' then
		pcall(function()
			local SlotService = require(ServerScriptService.Base.SlotService)
			SlotService.ReleaseSlot(slotId)
		end)
	end
	pcall(function()
		local Players = game:GetService('Players')
		local owner = Players:GetPlayerByUserId(ownerId)
		if owner then
			PlayerService.PushState(owner, BaseService.Snapshot(ownerId))
			AdminNotify.Tell(
				owner,
				('An administrator removed your %s.'):format(AdminNotify.Escape(AdminNotify.EggLabel(rarity)))
			)
		end
	end)
	local summary = ('Removed %s (%s) from %s.'):format(
		AdminNotify.EggLabel(rarity),
		tostring(eggId),
		tostring(ownerId)
	)
	AdminAudit.Log(context.Executor.UserId, 'removeegg', {
		target = target,
		eggId = tostring(eggId),
		owner = tostring(ownerId),
	}, true, summary)
	return summary
end
