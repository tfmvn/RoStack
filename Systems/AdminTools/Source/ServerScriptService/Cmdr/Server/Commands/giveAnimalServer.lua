--!strict
--!native
--[[
	giveAnimalServer
	Server-side Run for /giveanimal. Revalidates every argument
	server-side (defId, single trait, mutation list, level,
	quantity), then grants through AdminDelivery.GiveAnimal per
	player per unit. Notifies each target only for units actually
	delivered; queued units get a "free a slot" explanation.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)

return function(
	context,
	target: string,
	animal: string,
	trait: string?,
	mutations: { string }?,
	level: number?,
	quantity: number?
)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local AdminDelivery = require(ServerScriptService.Admin.AdminDelivery)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, err)
		return err
	end
	local okAnimal, defId = AdminArgs.ResolveAnimal(animal)
	if not okAnimal then
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, defId)
		return defId
	end
	local okTrait, cleanTrait = AdminArgs.ResolveTrait(trait)
	if not okTrait then
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, cleanTrait)
		return cleanTrait
	end
	local okMuts, cleanMuts = AdminArgs.ResolveMutations(mutations)
	if not okMuts then
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, cleanMuts)
		return cleanMuts
	end
	local wantLevel = 1
	if level ~= nil then
		local okLevel, cleanLevel = AdminArgs.ResolveAnimalLevel(level)
		if not okLevel then
			AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, cleanLevel)
			return cleanLevel
		end
		wantLevel = cleanLevel
	end
	local okQty, qty = AdminArgs.ResolveQuantity(quantity, 5)
	if not okQty then
		AdminAudit.Log(context.Executor.UserId, 'giveanimal', { target = target }, false, qty)
		return qty
	end
	local _, def = AnimalConfig.Get(defId)
	local displayName = defId
	if type(def) == 'table' and type(def.displayName) == 'string' then
		displayName = def.displayName
	end
	local label = AdminNotify.DescribeAnimal(displayName, cleanTrait, cleanMuts, wantLevel)
	local players = resolved.players
	local delivered = 0
	local queued = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local playerDelivered = 0
		local playerQueued = false
		for _ = 1, qty do
			local r = AdminDelivery.GiveAnimal(player.UserId, defId, cleanTrait, cleanMuts, wantLevel)
			if r.ok == true then
				delivered += 1
				playerDelivered += 1
				if qty == 1 then
					AdminNotify.Tell(player, ('You received %s!'):format(AdminNotify.Escape(label)))
				end
			elseif r.queued == true then
				queued += 1
				playerQueued = true
			else
				failures[#failures + 1] = ('%s (%s)'):format(player.Name, tostring(r.error or 'delivery failed'))
				break
			end
		end
		if qty > 1 and playerDelivered > 0 then
			-- One summary toast per player for multi-grants.
			AdminNotify.Tell(player, (('You received %d x %s!'):format(playerDelivered, AdminNotify.Escape(label))))
		end
		if playerQueued then
			AdminNotify.Tell(
				player,
				'An administrator tried to grant you an animal, but your base is full (reward queued — free a slot!).'
			)
		end
	end
	local summary: string
	if #players == 1 then
		if delivered == qty then
			summary = ('Gave %s to %s.'):format(label, players[1].Name)
		elseif queued > 0 and delivered == 0 then
			summary = ('%s has no free base slot; reward queued as pending.'):format(players[1].Name)
		else
			summary = ('Gave %d of %d %s to %s.'):format(delivered, qty, label, players[1].Name)
			if #failures > 0 then
				summary ..= ' Failed: ' .. table.concat(failures, '; ')
			end
		end
	else
		summary = ('Granted %s to %d players (%d delivered, %d queued).'):format(label, #players, delivered, queued)
		if #failures > 0 then
			summary ..= ' Failed: ' .. table.concat(failures, '; ')
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'giveanimal', {
		target = target,
		animal = defId,
		trait = tostring(cleanTrait),
		mutations = table.concat(cleanMuts, ','),
		level = tostring(wantLevel),
		delivered = tostring(delivered),
		queued = tostring(queued),
	}, delivered > 0 or queued > 0, summary)
	return summary
end
