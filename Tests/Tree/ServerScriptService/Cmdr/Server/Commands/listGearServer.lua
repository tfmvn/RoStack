--!strict
--!native
--[[
	listGearServer
	Server-side Run for /listgear. Pure read path: live tool
	instances (Backpack + Character) matched against the
	GearConfig catalog, plus the rebirth lock state. Never
	mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)

return function(context, target: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'listgear', { target = target }, false, rateErr)
		return rateErr
	end
	local resolved = AdminTargetResolver.Resolve(target, context.Executor)
	if not resolved.ok or resolved.players == nil then
		local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
		AdminAudit.Log(context.Executor.UserId, 'listgear', { target = target }, false, err)
		return err
	end
	local catalog = GearConfig.GetAll()
	local blocks: { string } = {}
	for _, player in ipairs(resolved.players) do
		local owned: { [string]: boolean } = {}
		pcall(function()
			local backpack = player:FindFirstChild('Backpack')
			if backpack then
				for _, tool in ipairs(backpack:GetChildren()) do
					if tool:IsA('Tool') then
						owned[tool.Name] = true
					end
				end
			end
			local character = player.Character
			if character then
				for _, tool in ipairs(character:GetChildren()) do
					if tool:IsA('Tool') then
						owned[tool.Name] = true
					end
				end
			end
		end)
		local rebirth = 0
		pcall(function()
			local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
			rebirth = RebirthService.GetRebirth(player.UserId)
		end)
		blocks[#blocks + 1] = ('== %s (rebirth %d) =='):format(player.Name, rebirth)
		for _, entry in ipairs(catalog) do
			local state = if owned[entry.ToolName] then 'OWNED' else 'missing'
			if GearConfig.IsLocked(rebirth, entry.RequiredRebirth) then
				state ..= ' (locked: rebirth ' .. tostring(entry.RequiredRebirth) .. ')'
			end
			blocks[#blocks + 1] = ('  %s [%s]: %s'):format(entry.Name, entry.Id, state)
		end
	end
	local summary = table.concat(blocks, '\n')
	AdminAudit.Log(context.Executor.UserId, 'listgear', { target = target }, true, 'inspected')
	return summary
end
