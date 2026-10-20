--!strict
--!native
--[[
	listCodesServer
	Server-side Run for /listcodes. Pure read path over
	CodesConfig.GetAll. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local CodesConfig = require(ReplicatedStorage.Config.Economy.Rewards).Codes

return function(context)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'listcodes', nil, false, rateErr)
		return rateErr
	end
	local lines: { string } = {}
	for _, entry in ipairs(CodesConfig.GetAll()) do
		if type(entry) == 'table' then
			local rewards: { string } = {}
			if type(entry.Rewards) == 'table' then
				if entry.Rewards.Cash ~= nil then
					rewards[#rewards + 1] = ('cash %s'):format(tostring(entry.Rewards.Cash))
				end
				if type(entry.Rewards.Eggs) == 'table' then
					for _, egg in ipairs(entry.Rewards.Eggs) do
						if type(egg) == 'table' then
							rewards[#rewards + 1] = ('%dx %s egg'):format(
								tonumber(egg.Amount) or 1,
								tostring(egg.Rarity)
							)
						end
					end
				end
				if type(entry.Rewards.Animals) == 'table' then
					for _, animal in ipairs(entry.Rewards.Animals) do
						if type(animal) == 'table' then
							rewards[#rewards + 1] = ('%dx %s'):format(
								tonumber(animal.Amount) or 1,
								tostring(animal.DefId)
							)
						end
					end
				end
				if type(entry.Rewards.Tools) == 'table' then
					for _, tool in ipairs(entry.Rewards.Tools) do
						if type(tool) == 'table' then
							rewards[#rewards + 1] = ('gear %s'):format(tostring(tool.Id))
						end
					end
				end
			end
			lines[#lines + 1] = ('%s [%s]: %s'):format(
				tostring(entry.Id),
				if entry.Enabled == false then 'DISABLED' else 'enabled',
				table.concat(rewards, ', ')
			)
		end
	end
	if #lines == 0 then
		lines[#lines + 1] = '(no codes configured)'
	end
	AdminAudit.Log(context.Executor.UserId, 'listcodes', nil, true, 'listed')
	return table.concat(lines, '\n')
end
