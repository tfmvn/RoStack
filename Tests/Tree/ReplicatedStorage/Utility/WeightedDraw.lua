--!strict
--[[
	WeightedDraw
	============
	Pure utility: pick a key from a `{[string] = number}` weight table.

	Used by EggService (which rarity spawns, which rarity a
	player gets when they open an egg) and could be used for any
	future weighted draw.

	Deterministic only when the caller supplies a `rng` function. The
	default uses `Random.new()` (not `math.random`) so this module
	never perturbs global RNG state.
]]

local WeightedDraw = {}

-- `weights` is a map from key to non-negative weight.
-- `rng` is an optional function returning a float in [0, 1).
function WeightedDraw.Choose(weights: { [string]: number }, rng: (() -> number)?): string?
	local total = 0
	for _, w in pairs(weights) do
		total = total + w
	end
	if total <= 0 then
		return nil
	end

	local draw = (rng and rng() or Random.new():NextNumber()) * total
	local cursor = 0
	-- Sort by key for determinism in the loop walk.
	local keys = {}
	for k in pairs(weights) do
		keys[#keys + 1] = k
	end
	table.sort(keys)

	for _, k in ipairs(keys) do
		cursor = cursor + (weights[k] :: number)
		if draw < cursor then
			return k
		end
	end
	-- Floating-point edge: the cursor hit exactly `total`. Return last.
	return keys[#keys]
end

return table.freeze(WeightedDraw)
