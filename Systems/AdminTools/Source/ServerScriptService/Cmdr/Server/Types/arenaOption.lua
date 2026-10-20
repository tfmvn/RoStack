--[[
	arenaOption type
	================
	Canonical arena raid entry option: Buy1 (paid warmup
	restart), Buy2 (paid direct restart), Buy3 (free stage-1
	entry). The server re-resolves stage + price per request;
	this type only resolves the option name.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)

	local OPTIONS = { 'Buy1', 'Buy2', 'Buy3' }

	cmdr:RegisterType('arenaOption', {
		Transform = function(text)
			local trimmed = TypeUtil.Trimmed(text)
			local exact = TypeUtil.ExactMatch(OPTIONS, trimmed)
			if exact ~= nil then
				return exact
			end
			return TypeUtil.BestMatch(OPTIONS, trimmed) or trimmed
		end,
		Validate = function(value)
			if TypeUtil.ExactMatch(OPTIONS, value) ~= nil then
				return true
			end
			return false, 'Unknown arena option. Pick one of: Buy1, Buy2, Buy3.'
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(OPTIONS, text)
		end,
		Parse = function(value)
			return value
		end,
	})
end
