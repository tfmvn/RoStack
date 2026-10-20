--!strict
--!native
--[[
	codeInfoServer
	Server-side Run for /codeinfo. Pure read path over
	CodesConfig.FindById. Never mutates.
]]

local ServerScriptService = game:GetService('ServerScriptService')

return function(context, code: string)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
	local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
	local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)
	AdminService.AssertAdmin(context.Executor.UserId)
	local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
	if not rateOk then
		AdminAudit.Log(context.Executor.UserId, 'codeinfo', nil, false, rateErr)
		return rateErr
	end
	local okCode, codeId, entry = AdminArgs.ResolveCode(code)
	if not okCode then
		AdminAudit.Log(context.Executor.UserId, 'codeinfo', nil, false, codeId)
		return codeId
	end
	local lines: { string } = { ('== %s =='):format(codeId) }
	if type(entry) == 'table' then
		lines[#lines + 1] = ('enabled: %s'):format(tostring(entry.Enabled ~= false))
		lines[#lines + 1] = ('expires: %s'):format(
			if entry.ExpiresAt ~= nil then tostring(entry.ExpiresAt) else 'never'
		)
		lines[#lines + 1] = ('max per player: %s'):format(tostring(entry.MaxPerPlayer or 1))
		lines[#lines + 1] = ('max global: %s'):format(
			if entry.MaxGlobalRedemptions ~= nil then tostring(entry.MaxGlobalRedemptions) else 'uncapped'
		)
		if type(entry.Rewards) == 'table' then
			if entry.Rewards.Cash ~= nil then
				lines[#lines + 1] = ('cash: %s'):format(tostring(entry.Rewards.Cash))
			end
			if type(entry.Rewards.Eggs) == 'table' then
				for _, egg in ipairs(entry.Rewards.Eggs) do
					if type(egg) == 'table' then
						lines[#lines + 1] = ('egg: %dx %s'):format(tonumber(egg.Amount) or 1, tostring(egg.Rarity))
					end
				end
			end
			if type(entry.Rewards.Animals) == 'table' then
				for _, animal in ipairs(entry.Rewards.Animals) do
					if type(animal) == 'table' then
						lines[#lines + 1] = ('animal: %dx %s trait=%s level=%s'):format(
							tonumber(animal.Amount) or 1,
							tostring(animal.DefId),
							tostring(animal.Trait),
							tostring(animal.Level or 1)
						)
					end
				end
			end
			if type(entry.Rewards.Tools) == 'table' then
				for _, tool in ipairs(entry.Rewards.Tools) do
					if type(tool) == 'table' then
						lines[#lines + 1] = ('gear: %s'):format(tostring(tool.Id))
					end
				end
			end
		end
	end
	AdminAudit.Log(context.Executor.UserId, 'codeinfo', { code = codeId }, true, 'inspected')
	return table.concat(lines, '\n')
end
