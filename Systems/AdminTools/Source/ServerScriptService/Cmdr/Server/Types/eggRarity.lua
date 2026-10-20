--[[
	eggRarity type
	==============
	Canonical egg rarity argument. Source of truth: EggConfig.Price
	keys (server) / RarityConfig.Order (display order). New
	rarities appear automatically on both sides.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)

	local function rarities(): { string }
		local out: { string } = {}
		for _, rarity in ipairs(RarityConfig.Order) do
			if EggConfig.Price[rarity] ~= nil then
				out[#out + 1] = rarity
			end
		end
		return out
	end

	cmdr:RegisterType('eggRarity', {
		Transform = function(text)
			local list = rarities()
			local exact = TypeUtil.ExactMatch(list, TypeUtil.Trimmed(text))
			if exact ~= nil then
				return exact
			end
			return TypeUtil.BestMatch(list, TypeUtil.Trimmed(text)) or TypeUtil.Trimmed(text)
		end,
		Validate = function(value)
			if type(value) == 'string' and EggConfig.Price[value] ~= nil then
				return true
			end
			return false, 'Unknown egg rarity. Pick one of: ' .. table.concat(rarities(), ', ') .. '.'
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(rarities(), text)
		end,
		Parse = function(value)
			return value
		end,
	})
end
