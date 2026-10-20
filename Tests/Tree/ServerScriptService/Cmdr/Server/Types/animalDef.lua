--[[
	animalDef type
	==============
	Canonical animal definition argument. Source of truth:
	AnimalConfig.Catalog (defIds). Display names also resolve.
	New animals appear automatically on both sides.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)

	local function defIds(): { string }
		local out: { string } = {}
		for _, bucket in pairs(AnimalConfig.Catalog) do
			for defId in pairs(bucket) do
				out[#out + 1] = defId
			end
		end
		table.sort(out)
		return out
	end

	local function resolveDisplayName(text: string): string?
		local lowered = string.lower(text)
		for _, bucket in pairs(AnimalConfig.Catalog) do
			for defId, entry in pairs(bucket) do
				if type(entry.displayName) == 'string' and string.lower(entry.displayName) == lowered then
					return defId
				end
			end
		end
		return nil
	end

	cmdr:RegisterType('animalDef', {
		Transform = function(text)
			local trimmed = TypeUtil.Trimmed(text)
			local ids = defIds()
			local exact = TypeUtil.ExactMatch(ids, trimmed)
			if exact ~= nil then
				return exact
			end
			local byDisplay = resolveDisplayName(trimmed)
			if byDisplay ~= nil then
				return byDisplay
			end
			return TypeUtil.BestMatch(ids, trimmed) or trimmed
		end,
		Validate = function(value)
			if type(value) == 'string' then
				local rarity = AnimalConfig.Get(value)
				if rarity ~= nil then
					return true
				end
			end
			return false, 'Unknown animal. Use an animal definition id.'
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(defIds(), text)
		end,
		Parse = function(value)
			return value
		end,
	})
end
