--!strict
--!native
--[[
 	spawnEggServer
 	Server-side Run for /spawnegg. Loaded by Cmdr's
 	Registry:RegisterCommand as commandObject.Run; executes only
 	on the server. The shared spawnEgg.lua carries the
 	definition (Name/Group/Args) and is replicated to the client,
 	which forwards execution here through the Cmdr RemoteFunction.
 ]]

local ServerScriptService = game:GetService('ServerScriptService')

local Rarity = require(game.ReplicatedStorage.Types.RarityType)

local Debug = require(game.ReplicatedStorage.Utility.Debug)

return function(context, rarity: string, mutations: string?, trait: string?, count: number?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local Catalog = require(ServerScriptService.Egg.Catalog)
	local MutationService = require(ServerScriptService.MutationService)
	local TraitService = require(ServerScriptService.TraitService)
	AdminService.AssertAdmin(context.Executor.UserId)
	if
		rarity ~= Rarity.Common
		and rarity ~= Rarity.Uncommon
		and rarity ~= Rarity.Rare
		and rarity ~= Rarity.Epic
		and rarity ~= Rarity.Mythic
		and rarity ~= Rarity.Legendary
		and rarity ~= Rarity.Divine
		and rarity ~= Rarity.Secret
	then
		return 'Unknown rarity. Pick one of: Common, Uncommon, Rare, Epic, Mythic, Legendary, Divine, Secret.'
	end
	-- Phase 2.11: server-side validation of the admin payload.
	-- Cmdr parsed raw strings; the whitelist decision happens
	-- here, inside the authoritative service boundary.
	local listOk, parsedMutations = MutationService.ParseListInput(mutations)
	if not listOk then
		return parsedMutations
	end
	local pendingTrait: string? = nil
	if trait ~= nil and trait ~= '' then
		if not TraitService.IsValidTrait(trait) then
			return ('Invalid trait: "%s"'):format(trait)
		end
		pendingTrait = trait
	end
	count = count or 1
	if count < 1 or count > 10 then
		return 'count must be between 1 and 10.'
	end
	local spawned = 0
	for _ = 1, count do
		-- Canonical current price: admin eggs cost exactly
		-- what a normal egg costs right now (never 0).
		local price = SpawnService.ResolvePrice(rarity)
		local r = SpawnService.Request({
			definition = { rarity = rarity, price = price },
			origin = Catalog.Origin.Admin,
			adminUserId = context.Executor.UserId,
			mutations = parsedMutations,
			pendingTrait = pendingTrait,
		})
		if not r or not r.success then
			return ('Spawned %d, then failed: %s'):format(spawned, tostring(r and r.error))
		end
		spawned += 1
	end
	Debug.Log('CMDR', 'spawnegg', {
		rarity = rarity,
		count = spawned,
		mutations = table.concat(parsedMutations, ','),
		trait = tostring(pendingTrait),
		by = context.Executor.UserId,
	})
	return ('Spawned %d %s Egg(s).'):format(spawned, rarity)
end
