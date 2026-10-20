--[[
	codeId type
	===========
	Canonical redeem-code argument. Source of truth:
	CodesConfig catalog (normalized UPPER ids). New codes appear
	automatically. Redemption itself stays server-side in
	CodesService; this type only resolves the identifier.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local CodesConfig = require(ReplicatedStorage.Config.Economy.Rewards).Codes

	local function codeIds(): { string }
		local out: { string } = {}
		for _, entry in ipairs(CodesConfig.GetAll()) do
			out[#out + 1] = entry.Id
		end
		table.sort(out)
		return out
	end

	cmdr:RegisterType('codeId', {
		Transform = function(text)
			local norm = CodesConfig.NormalizeCode(text)
			if norm == nil then
				return TypeUtil.Trimmed(text)
			end
			if CodesConfig.FindById(norm) ~= nil then
				return norm
			end
			return norm
		end,
		Validate = function(value)
			if type(value) == 'string' and CodesConfig.FindById(value) ~= nil then
				return true
			end
			return false, 'Unknown code.'
		end,
		Autocomplete = function(text)
			local norm = CodesConfig.NormalizeCode(text) or ''
			return TypeUtil.FuzzyFilter(codeIds(), norm)
		end,
		Parse = function(value)
			return value
		end,
	})
end
