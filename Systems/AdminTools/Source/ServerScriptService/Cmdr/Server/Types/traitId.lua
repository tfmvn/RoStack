--[[
	traitId type
	============
	Canonical SINGLE trait argument. Source of truth:
	TraitConfig.Catalog. "-" / "none" / empty mean no trait and
	parse to nil. Comma-separated input is rejected: an animal
	carries at most ONE trait and silently taking the first value
	would corrupt intent.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)

	local function traitIds(): { string }
		local out: { string } = {}
		for id in pairs(TraitConfig.Catalog) do
			out[#out + 1] = id
		end
		table.sort(out)
		return out
	end

	local function isNoneMarker(text: string): boolean
		return text == '' or text == '-' or string.lower(text) == 'none'
	end

	cmdr:RegisterType('traitId', {
		Transform = function(text)
			local trimmed = TypeUtil.Trimmed(text)
			if isNoneMarker(trimmed) then
				return '-'
			end
			local ids = traitIds()
			local exact = TypeUtil.ExactMatch(ids, trimmed)
			if exact ~= nil then
				return exact
			end
			return TypeUtil.BestMatch(ids, trimmed) or trimmed
		end,
		Validate = function(value)
			if value == '-' then
				return true
			end
			if type(value) == 'string' and string.find(value, ',') ~= nil then
				return false, 'Animals support only one trait; pass a single trait, not a list.'
			end
			if type(value) == 'string' and TraitConfig.Get(value) ~= nil then
				return true
			end
			return false, 'Invalid trait. Pick one of: ' .. table.concat(traitIds(), ', ') .. ' (or - for none).'
		end,
		Autocomplete = function(text)
			local ids = traitIds()
			local out = TypeUtil.FuzzyFilter(ids, text)
			if TypeUtil.Trimmed(text) == '' then
				table.insert(out, 1, '-')
			end
			return out
		end,
		Parse = function(value)
			if value == '-' then
				return nil
			end
			return value
		end,
	})
end
