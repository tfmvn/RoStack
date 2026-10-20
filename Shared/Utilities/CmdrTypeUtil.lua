--!strict
--!native
--[[
	CmdrTypeUtil
	============
	Tiny pure helpers shared by the custom admin Cmdr types.
	Client-safe: no service requires beyond what callers pass in,
	so the same module runs on the server (registration +
	authoritative parse) and on the client (autocomplete).

	Nothing here trusts its input: every matcher is total (never
	errors) and every lookup is case-insensitive with the
	canonical capitalization returned on success.
]]

local CmdrTypeUtil = {}

-- Case-insensitive substring filter preserving source order.
-- Empty needle matches everything.
function CmdrTypeUtil.FuzzyFilter(candidates: { string }, needle: any): { string }
	local out: { string } = {}
	if type(candidates) ~= 'table' then
		return out
	end
	local query = ''
	if type(needle) == 'string' then
		query = string.lower(needle)
	end
	for _, candidate in ipairs(candidates) do
		if type(candidate) == 'string' then
			if query == '' or string.find(string.lower(candidate), query, 1, true) ~= nil then
				out[#out + 1] = candidate
			end
		end
	end
	return out
end

-- Exact (case-insensitive) lookup. Returns the canonical entry
-- or nil.
function CmdrTypeUtil.ExactMatch(candidates: { string }, text: any): string?
	if type(text) ~= 'string' then
		return nil
	end
	local lowered = string.lower(text)
	for _, candidate in ipairs(candidates) do
		if type(candidate) == 'string' and string.lower(candidate) == lowered then
			return candidate
		end
	end
	return nil
end

-- First fuzzy hit (exact first, then substring) or nil.
function CmdrTypeUtil.BestMatch(candidates: { string }, text: any): string?
	local exact = CmdrTypeUtil.ExactMatch(candidates, text)
	if exact ~= nil then
		return exact
	end
	local filtered = CmdrTypeUtil.FuzzyFilter(candidates, text)
	return filtered[1]
end

function CmdrTypeUtil.Trimmed(text: any): string
	if type(text) ~= 'string' then
		return ''
	end
	return (string.gsub(string.gsub(text, '^%s+', ''), '%s+$', ''))
end

return table.freeze(CmdrTypeUtil)
