--!strict
--!native
--[[
	listAnimalsServer
	Server-side Run for /listanimals. Pure read path: profile
	records joined with live runtime state. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local PlayerService = require(ServerScriptService.PlayerService)
	local AnimalService = require(ServerScriptService.AnimalService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'listanimals', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'listanimals', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local records: { any } = {}
		pcall(function()
			records = PlayerService.GetAnimals(player.UserId)
		end)
		blocks[#blocks + 1] = ('== %s (%d animals) =='):format(player.Name, #records)
		local shown = 0
		for _, rec in ipairs(records) do
			if shown >= 15 then
				blocks[#blocks + 1] = ('... and %d more'):format(#records - shown)
				break
			end
			shown += 1
			local defId = tostring(rec.DefId)
			local rarity, def = AnimalConfig.Get(defId)
			local displayName = defId
			if type(def) == 'table' and type(def.displayName) == 'string' then
				displayName = def.displayName
			end
			local live: any = nil
			pcall(function()
				live = AnimalService.Get(rec.Id)
			end)
			local level = rec.Level
			local state = 'persisted'
			if type(live) == 'table' then
				level = live.Level or level
				state = tostring(live.state or 'live')
			end
			local trait = if type(rec.Trait) == 'string' then rec.Trait else '-'
			local muts = '-'
			if type(rec.Mutations) == 'table' and #rec.Mutations > 0 then
				muts = table.concat(rec.Mutations, ',')
			end
			blocks[#blocks + 1] = ('%s | %s (%s) Lv.%s trait=%s muts=%s slot=%s state=%s'):format(
				tostring(rec.Id),
				displayName,
				tostring(rarity),
				tostring(level),
				trait,
				muts,
				tostring(rec.SlotId),
				state
			)
		end
		if #records == 0 then
			blocks[#blocks + 1] = '(none)'
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(
		context.Executor.UserId,
		'listanimals',
		{ target = target },
		true,
		('inspected %d players'):format(#resolved.players)
	)
	return summary
end
