--[[
	adminTarget type
	================
	One player-target argument for admin commands. The raw text is
	passed through untouched; AdminTargetResolver (server) is the
	authoritative interpreter. Keywords: me, all, server.

	Autocomplete (client): keywords + live player names, fuzzy.
	Validation is intentionally permissive here — unknown names
	fail SERVER-side with a precise message (client autocomplete
	is UX only, never the gate).
]]

return function(cmdr)
	local Players = game:GetService('Players')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)

	local function candidates(): { string }
		local out: { string } = { 'me', 'all', 'server' }
		local seen: { [string]: boolean } = { me = true, all = true, server = true }
		for _, p in ipairs(Players:GetPlayers()) do
			if p and p.Parent and not seen[p.Name] then
				seen[p.Name] = true
				out[#out + 1] = p.Name
			end
		end
		return out
	end

	cmdr:RegisterType('adminTarget', {
		Transform = function(text)
			return TypeUtil.Trimmed(text)
		end,
		Validate = function(_value)
			return true
		end,
		Autocomplete = function(text)
			return TypeUtil.FuzzyFilter(candidates(), text)
		end,
		Parse = function(value)
			return value
		end,
	})
end
