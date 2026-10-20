--!strict
--[[
	NumberUtils
	===========
	Small helpers for numbers used across services and UI.
]]

local NumberUtils = {}

function NumberUtils.Clamp(value: number, min: number, max: number): number
	if value < min then
		return min
	end
	if value > max then
		return max
	end
	return value
end

function NumberUtils.Round(value: number, places: number?): number
	local p = places or 0
	local mult = 10 ^ p
	return math.floor(value * mult + 0.5) / mult
end

-- Compress large numbers to short strings for HUD display: 1.2K, 3.4M, 5.6B.
function NumberUtils.Abbreviate(value: number): string
	local abs = math.abs(value)
	if abs < 1000 then
		return tostring(math.floor(value))
	end
	local suffixes = { '', 'K', 'M', 'B', 'T' }
	local tier = 1
	while abs >= 1000 and tier < #suffixes do
		abs = abs / 1000
		tier = tier + 1
	end
	-- Preserve sign.
	local sign = value < 0 and '-' or ''
	return string.format('%s%s%s', sign, NumberUtils.Round(abs, 1), suffixes[tier])
end

return table.freeze(NumberUtils)
