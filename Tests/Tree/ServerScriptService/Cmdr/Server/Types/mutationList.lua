--[[
	mutationList type (Listable)
	============================
	Comma-separated mutation list argument. Source of truth:
	MutationConfig.Catalog. List separator is the comma; argument
	separator stays whitespace; quoted multi-word values keep
	working through Cmdr's own quoting.

	Per-segment behavior (Cmdr splits on commas first):
	  * Transform resolves each segment to its canonical id.
	  * Validate rejects unknown ids loudly per segment.
  * Autocomplete filters on the in-progress segment, so
    "Galactic,F" suggests Frost and "Galactic," suggests
    every mutation. Selecting a suggestion appends it to the
    existing list (Cmdr listable behavior preserves prefix).
	  * Parse returns { canonicalId } per segment; Cmdr unions
	    segments into the final array. Identical duplicates
	    collapse in that union (documented, benign: the outcome
	    is the single mutation, never a wrong value). Unknown
	    ids can never reach Run (Validate rejects them first)
	    and the server re-resolves every id anyway.
]]

return function(cmdr)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
	local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)

	local function mutationIds(): { string }
		local out: { string } = {}
		for id in pairs(MutationConfig.Catalog) do
			out[#out + 1] = id
		end
		table.sort(out)
		return out
	end

	cmdr:RegisterType('mutationList', {
		Listable = true,
		Transform = function(text)
			local trimmed = TypeUtil.Trimmed(text)
			if trimmed == '' or trimmed == '-' or string.lower(trimmed) == 'none' then
				return ''
			end
			local ids = mutationIds()
			local exact = TypeUtil.ExactMatch(ids, trimmed)
			if exact ~= nil then
				return exact
			end
			return TypeUtil.BestMatch(ids, trimmed) or trimmed
		end,
		Validate = function(value)
			if value == '' then
				return true
			end
			if type(value) == 'string' and MutationConfig.Get(value) ~= nil then
				return true
			end
			return false,
				('Invalid mutation: "%s". Pick from: %s.'):format(tostring(value), table.concat(mutationIds(), ', '))
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(mutationIds(), text)
		end,
		Parse = function(value)
			if value == '' then
				return {}
			end
			return { value }
		end,
	})
end
