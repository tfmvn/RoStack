--!strict
--!native
--[[
	setAnimalLevelServer
	Server-side Run for /setanimallevel. Up-levels reuse the
	canonical AnimalService.ApplyLevelUpgrade (+1 with full
	side effects) in a loop; down-levels write the two
	authoritative stores (runtime + profile, the same two
	ApplyLevelUpgrade keeps in lockstep) and refresh the
	overhead + push state. Presentation for lowers is a refresh,
	not a fake level-up celebration.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, animalId: string, level: number)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local BaseService = require(ServerScriptService.BaseService)
	local AnimalService = require(ServerScriptService.AnimalService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, err)
		return err
	end
	local okLevel, wantLevel = AdminArgs.ResolveAnimalLevel(level)
	if not okLevel then
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, wantLevel)
		return wantLevel
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
		local err = ('No live animal "%s". Levels can only be set on live animals.'):format(tostring(animalId))
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, err)
		return err
	end
	if not inScope[animal.ownerUserId] then
		local err = 'That animal is not owned by the targeted player(s).'
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, err)
		return err
	end
	local current = animal.Level or 1
	local displayName = animal.displayName or animal.definitionId or tostring(animalId)
	if wantLevel == current then
		local summary = ('%s is already Lv.%d.'):format(displayName, current)
		AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, true, summary)
		return summary
	end
	if wantLevel > current then
		for _ = current + 1, wantLevel do
			local r: any = nil
			pcall(function()
				r = AnimalService.ApplyLevelUpgrade(animalId)
			end)
			if type(r) ~= 'table' or r.success ~= true then
				local err = ('Raise stopped at Lv.%s (%s).'):format(
					tostring(if type(r) == 'table' then r.newLevel else current),
					tostring(if type(r) == 'table' then r.error else 'upgrade failed')
				)
				AdminAudit.Log(context.Executor.UserId, 'setanimallevel', { target = target }, false, err)
				return err
			end
			current = r.newLevel
		end
	else
		-- Lower: write the same two authoritative stores the
		-- upgrade path keeps in lockstep, then refresh.
		animal.Level = wantLevel
		pcall(function()
			local data = PlayerService.GetPlayerData(animal.ownerUserId)
			if type(data) == 'table' and type(data.Brainrots) == 'table' then
				for _, rec in ipairs(data.Brainrots) do
					if type(rec) == 'table' and rec.Id == animalId then
						rec.Level = wantLevel
						break
					end
				end
			end
		end)
		pcall(function()
			local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
			AnimalOverhead.Refresh(animal)
		end)
	end
	pcall(function()
		local Players = game:GetService('Players')
		local owner = Players:GetPlayerByUserId(animal.ownerUserId)
		if owner then
			PlayerService.PushState(owner, BaseService.Snapshot(animal.ownerUserId))
			AdminNotify.Tell(
				owner,
				('An administrator set %s to Lv.%d.'):format(AdminNotify.Escape(displayName), wantLevel)
			)
		end
	end)
	local summary = ('Set %s (%s) to Lv.%d.'):format(displayName, tostring(animalId), wantLevel)
	AdminAudit.Log(context.Executor.UserId, 'setanimallevel', {
		target = target,
		animalId = tostring(animalId),
		level = tostring(wantLevel),
	}, true, summary)
	return summary
end
