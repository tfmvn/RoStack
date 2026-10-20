--!strict
--!native
--[[
	removeAnimalServer
	Server-side Run for /removeanimal. Destroys the runtime model,
	removes the persistence record (settling its cash pool first,
	per PlayerService.RemoveAnimal), and releases the slot.
	Refuses carried / stolen / arena-locked animals loudly.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local SlotType = require(ReplicatedStorage.Types.SlotType)

return function(context, target: string, animalId: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local AnimalService = require(ServerScriptService.AnimalService)
	AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
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
		local err = ('No live animal "%s". Use /listanimals to find the BR_ id.'):format(tostring(animalId))
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
		return err
	end
	if not inScope[animal.ownerUserId] then
		local err = 'That animal is not owned by the targeted player(s).'
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
		return err
	end
	local ownerId = animal.ownerUserId
	local slotId = animal.slotId
	local displayName = animal.displayName or animal.definitionId or tostring(animalId)
	-- Live-state guards: never tear an animal out from under an
	-- active carry, steal, or arena raid.
	local carrying = false
	pcall(function()
		carrying = AnimalService.IsCarryingAnimal({ UserId = ownerId } :: any) == true
	end)
	if carrying then
		local entry: any = nil
		pcall(function()
			entry = AnimalService.GetCarriedAnimalByUserId(ownerId)
		end)
		if type(entry) == 'table' and entry.uniqueId == animalId then
			local err = 'That animal is currently being carried; cancel the carry first.'
			AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
			return err
		end
	end
	local stolen = false
	pcall(function()
		local StealService = require(ServerScriptService.Steal.StealService)
		stolen = StealService.IsStolenRecord(SlotType.OccupantKind.Animal, animalId) == true
	end)
	if stolen then
		local err = 'That animal is part of an active steal; cancel the steal first.'
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
		return err
	end
	local raidLocked = false
	pcall(function()
		local ArenaService = require(ServerScriptService.Arena.ArenaService)
		raidLocked = ArenaService.IsAnimalRaidLocked(animalId) == true
	end)
	if raidLocked then
		local err = 'That animal is locked in an active arena raid; end the raid first.'
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
		return err
	end
	local destroyed = false
	pcall(function()
		destroyed = AnimalService.DestroyRuntimeAnimal(animalId) == true
	end)
	if not destroyed then
		local err = 'Could not destroy the live animal (it may have despawned).'
		AdminAudit.Log(context.Executor.UserId, 'removeanimal', { target = target }, false, err)
		return err
	end
	pcall(PlayerService.RemoveAnimal, ownerId, animalId)
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
				('An administrator removed %s from your base.'):format(AdminNotify.Escape(displayName))
			)
		end
	end)
	local summary = ('Removed %s (%s) from %s.'):format(displayName, tostring(animalId), tostring(ownerId))
	AdminAudit.Log(context.Executor.UserId, 'removeanimal', {
		target = target,
		animalId = tostring(animalId),
		owner = tostring(ownerId),
	}, true, summary)
	return summary
end
