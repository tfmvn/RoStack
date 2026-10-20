--[[
	gearId type
	===========
	Canonical gear argument. Source of truth: GearConfig entries.
	Ids and display names both resolve; Run receives the stable
	gear Id. New shop entries appear automatically.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)

	local function gearIds(): { string }
		local out: { string } = {}
		for _, entry in ipairs(GearConfig.GetAll()) do
			out[#out + 1] = entry.Id
		end
		return out
	end

	local function resolveName(text: string): string?
		local lowered = string.lower(text)
		for _, entry in ipairs(GearConfig.GetAll()) do
			if string.lower(entry.Name) == lowered then
				return entry.Id
			end
		end
		return nil
	end

	cmdr:RegisterType('gearId', {
		Transform = function(text)
			local trimmed = TypeUtil.Trimmed(text)
			local ids = gearIds()
			local exact = TypeUtil.ExactMatch(ids, trimmed)
			if exact ~= nil then
				return exact
			end
			local byName = resolveName(trimmed)
			if byName ~= nil then
				return byName
			end
			return TypeUtil.BestMatch(ids, trimmed) or trimmed
		end,
		Validate = function(value)
			if type(value) == 'string' and GearConfig.FindGear(value) ~= nil then
				return true
			end
			return false, 'Unknown gear. Use a Gear Shop id.'
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(gearIds(), text)
		end,
		Parse = function(value)
			return value
		end,
	})
end
