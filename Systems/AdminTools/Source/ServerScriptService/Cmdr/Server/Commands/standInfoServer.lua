--!strict
--!native
--[[
	standInfoServer
	Server-side Run for /standinfo. Pure read path:
	DynamicSlotService desired counts (rebirth-driven) vs the
	live slot snapshot. Never mutates stands.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	local BaseService = require(ServerScriptService.BaseService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'standinfo', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'standinfo', { target = target }, false, err)
		return err
	end
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local base: any = nil
		pcall(function()
			base = BaseService.GetPlayerBase(player.UserId)
		end)
		if type(base) ~= 'table' then
			blocks[#blocks + 1] = ('== %s: no base assigned =='):format(player.Name)
		else
			local desiredAnimal = 0
			local desiredArena = 0
			pcall(function()
				local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
				desiredAnimal = DynamicSlotService.GetDesiredSlotCount(base.folder, player.UserId)
				desiredArena = DynamicSlotService.GetDesiredArenaStandCount(base.folder, player.UserId)
			end)
			local actualAnimal = 0
			local actualArena = 0
			local occupied = 0
			pcall(function()
				local snap = BaseService.Snapshot(player.UserId)
				if type(snap) == 'table' then
					occupied = tonumber(snap._occupiedCount) or 0
					if type(snap.slots) == 'table' then
						for _, slot in ipairs(snap.slots) do
							if type(slot) == 'table' then
								if tonumber(slot.arenaIndex) ~= nil or slot.isArena == true then
									actualArena += 1
								else
									actualAnimal += 1
								end
							end
						end
					end
				end
			end)
			local rebirth = 0
			pcall(function()
				local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
				rebirth = RebirthService.GetRebirth(player.UserId)
			end)
			blocks[#blocks + 1] = ('== %s: base %s (rebirth %d) =='):format(player.Name, tostring(base.id), rebirth)
			blocks[#blocks + 1] = ('  animal stands: %d live / %d desired, arena stands: %d live / %d desired, occupied: %d'):format(
				actualAnimal,
				desiredAnimal,
				actualArena,
				desiredArena,
				occupied
			)
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'standinfo', { target = target }, true, 'inspected')
	return summary
end
