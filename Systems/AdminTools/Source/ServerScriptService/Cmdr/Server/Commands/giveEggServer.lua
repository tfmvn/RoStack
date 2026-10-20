--!strict
--!native
--[[
	giveEggServer
	Server-side Run for /giveegg. Revalidates rarity, single
	trait, mutation list, and quantity server-side, then grants
	through AdminDelivery.GiveEgg per player per unit. Notifies
	each target only for units actually delivered; full bases get
	a queued explanation and the admin gets the aggregate.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string, egg: string, trait: string?, mutations: { string }?, quantity: number?)
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
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, err)
		return err
	end
	local okRarity, rarity = AdminArgs.ResolveRarity(egg)
	if not okRarity then
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, rarity)
		return rarity
	end
	local okTrait, cleanTrait = AdminArgs.ResolveTrait(trait)
	if not okTrait then
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, cleanTrait)
		return cleanTrait
	end
	local okMuts, cleanMuts = AdminArgs.ResolveMutations(mutations)
	if not okMuts then
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, cleanMuts)
		return cleanMuts
	end
	local okQty, qty = AdminArgs.ResolveQuantity(quantity, 10)
	if not okQty then
		AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, qty)
		return qty
	end
	-- The notification shows ONLY what was actually applied.
	local label = AdminNotify.DescribeEgg(rarity, cleanTrait, cleanMuts)
	local players = resolved.players
	local delivered = 0
	local queued = 0
	local failures: { string } = {}
	for _, player in ipairs(players) do
		local playerDelivered = 0
		local playerQueued = false
		for _ = 1, qty do
			local r = AdminDelivery.GiveEgg(player.UserId, rarity, cleanTrait, cleanMuts)
			if r.ok == true then
				delivered += 1
				playerDelivered += 1
			elseif r.queued == true then
				queued += 1
				playerQueued = true
			else
				failures[#failures + 1] = ('%s (%s)'):format(player.Name, tostring(r.error or 'delivery failed'))
				break
			end
		end
		if playerDelivered == 1 then
			AdminNotify.Tell(player, ('You received a %s!'):format(AdminNotify.Escape(label)))
		elseif playerDelivered > 1 then
			AdminNotify.Tell(player, (('You received %d x %s!'):format(playerDelivered, AdminNotify.Escape(label))))
		end
		if playerQueued then
			AdminNotify.Tell(
				player,
				'An administrator tried to grant you an egg, but your storage is full (reward queued — free a slot!).'
			)
		end
	end
	local summary: string
	if #players == 1 then
		if delivered == qty then
			summary = ('Gave %s%s to %s.'):format(
				if qty > 1 then tostring(qty) .. ' x ' else '',
				label,
				players[1].Name
			)
		elseif queued > 0 and delivered == 0 then
			summary = ('%s has no free egg storage; reward queued as pending.'):format(players[1].Name)
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
	AdminAudit.Log(context.Executor.UserId, 'giveegg', {
		target = target,
		egg = rarity,
		trait = tostring(cleanTrait),
		mutations = table.concat(cleanMuts, ','),
		delivered = tostring(delivered),
		queued = tostring(queued),
	}, delivered > 0 or queued > 0, summary)
	return summary
end
