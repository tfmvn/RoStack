--!strict
--!native
--[[
	MutationService
	===============
	Phase 2.11 — the ONE authority for Egg / Animal
	mutations. A mutation list is N UNIQUE valid ids (possibly
	empty); duplicates and unknown ids are rejected at every
	boundary and never stored. Pure functions + config reads only
	— no service refs, no state — so persistence audit, specs,
	spawning, and the open pipeline all share this one path.

	API:
	  SanitizeList(list) -> { string }  (copy, validated, deduped,
	      sorted — deterministic regardless of insertion order)
	  IsValidMutation(id) -> boolean
	  GetGenerationMultiplier(list) -> number (multiplicative
	      fold, float rate math; empty = 1)
	  GetSellMultiplier(list) -> string (multiplicative fold,
	      EXACT BigNumber decimals; empty = '1')
	  ParseListInput(input) -> (ok, list|error) — admin command
	      parsing for comma/bracket/quote/space-separated text.

	Stacking is ALWAYS multiplicative over sorted ids (§10): no
	first-only, no max-only, no additive paths anywhere.
]]

local MutationConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)

local MutationService = {}

function MutationService.Init()
	-- No-op: stateless.
end

-- Is this a real mutation id?
function MutationService.IsValidMutation(mutationId: any): boolean
	if type(mutationId) ~= 'string' or mutationId == '' then
		return false
	end
	return MutationConfig.Get(mutationId) ~= nil
end

-- Canonicalize any mutation-list-shaped value: FRESH sorted
-- array of unique valid ids. Delegates to the single config
-- fold — never reimplemented.
function MutationService.SanitizeList(list: any): { string }
	return MutationConfig.SanitizeIds(list)
end

-- Multiplicative generation fold (float; empty = 1). Delegates
-- to the single config fold — never reimplemented.
function MutationService.GetGenerationMultiplier(list: any): number
	return MutationConfig.GenerationFold(list)
end

-- Multiplicative sell fold (EXACT BigNumber decimals; empty =
-- '1'). Delegates to the single config fold — never
-- reimplemented.
function MutationService.GetSellMultiplier(list: any): string
	return MutationConfig.SellFold(list)
end

-- Parse admin-command mutation text into ids. Accepts comma
-- and/or whitespace separation with optional surrounding
-- brackets/quotes (so `Galactic,Frost`, `["Galactic", "Frost"]`,
-- and `[]` all work). Returns (true, sanitizedList) or
-- (false, code + detail) with the EXACT spec error vocabulary:
-- invalid mutation / duplicate mutation. Empty/none-markers
-- ('', '-', 'none', '[]') yield an empty list.
function MutationService.ParseListInput(input: any): (boolean, any)
	if input == nil then
		return true, {}
	end
	if type(input) ~= 'string' then
		return false, 'invalid-mutations'
	end
	local text = string.gsub(input, '[%[%]%"]', '')
	text = string.gsub(text, '^%s+', '')
	text = string.gsub(text, '%s+$', '')
	if text == '' or text == '-' or string.lower(text) == 'none' then
		return true, {}
	end
	local raw: { string } = {}
	for token in string.gmatch(text, '[^,%s]+') do
		raw[#raw + 1] = token
	end
	if #raw == 0 then
		return true, {}
	end
	local seen: { [string]: boolean } = {}
	local out: { string } = {}
	for _, id in ipairs(raw) do
		if not MutationService.IsValidMutation(id) then
			return false, ('Invalid mutation: "%s"'):format(id)
		end
		if seen[id] then
			return false, ('Duplicate mutation: "%s"'):format(id)
		end
		seen[id] = true
		out[#out + 1] = id
	end
	table.sort(out)
	return true, out
end

return table.freeze(MutationService)
