--!strict
--[[
	RichTextFormatter
	=================
	One centralized, safe RichText builder for player-facing
	notification text. The ONLY place markup is ever produced:
	gameplay code passes plain server-approved values, this
	module escapes + wraps them deterministically.

	Visual hierarchy (enforced by construction): surrounding
	copy stays unstyled (the HUD renders it white); exactly ONE
	entity per message gets its rarity color. Danger messages
	(robbery) use the fixed danger red for surrounding copy via
	Danger(), with the entity still rarity-colored. Never trust
	the client for rarity — callers pass the authoritative rarity
	string and it is resolved here against RarityConfig.

	Escape-then-wrap order guarantees dynamic names can never
	inject markup (<font>, <b>, ...) into the final string.
]]

local RarityConfig = require(script.Parent.Parent.Config.Creatures.Rarity)
local OverheadConfig = require(script.Parent.Parent.Config.Presentation.UI).Overhead

local RichTextFormatter = {}

-- Fixed danger red for robbery/admin-alert copy. A constant,
-- NOT a second color table: rarity colors still come only
-- from RarityConfig via RarityHex/Entity.
RichTextFormatter.DangerHex = '#FF5A5A'

-- Fixed highlight for admin names in wipe/reset notices.
-- Same rule: a constant, not a table; applied via Colored.
RichTextFormatter.AdminHex = '#A0C8FF'

-- Escape the RichText-sensitive characters. Order matters:
-- ampersand first so entity introductions are never double
-- escaped.
function RichTextFormatter.Escape(raw: any): string
	if type(raw) ~= 'string' then
		return ''
	end
	local out = string.gsub(raw, '&', '&amp;')
	out = string.gsub(out, '<', '&lt;')
	out = string.gsub(out, '>', '&gt;')
	out = string.gsub(out, '"', '&quot;')
	return out
end

-- Deterministic Color3 -> #RRGGBB (uppercase, clamped).
function RichTextFormatter.ColorHex(color: Color3): string
	local function channel(v: number): string
		local b = math.floor(math.clamp(v, 0, 1) * 255 + 0.5)
		return string.format('%02X', b)
	end
	return '#' .. channel(color.R) .. channel(color.G) .. channel(color.B)
end

-- Canonical rarity color as hex. Unknown/nil rarities fall back
-- to white so markup never breaks and nothing looks accidental.
function RichTextFormatter.RarityHex(rarity: any): string
	local color: Color3? = nil
	pcall(function()
		if type(rarity) == 'string' then
			color = (RarityConfig.RarityColor :: { [string]: any })[rarity]
		end
	end)
	if typeof(color) ~= 'Color3' then
		return '#FFFFFF'
	end
	return RichTextFormatter.ColorHex(color)
end

-- Wrap an already-safe display string in a font-color tag.
function RichTextFormatter.Colored(safeText: string, hexColor: string): string
	return ('<font color="%s">%s</font>'):format(hexColor, safeText)
end

-- Danger-styled copy: escapes the raw string, then wraps it in
-- the fixed danger red. Used for robbery victim messages (the
-- animal name inside is still Entity()/rarity-colored by the
-- caller — Danger only styles the surrounding copy).
function RichTextFormatter.Danger(raw: any): string
	return RichTextFormatter.Colored(RichTextFormatter.Escape(raw), RichTextFormatter.DangerHex)
end

-- Format an entity name: escaped always, rarity-colored when the
-- authoritative rarity resolves (fallback: escaped plain text).
-- `fallback` is the display string used when `name` is unusable.
function RichTextFormatter.Entity(name: any, rarity: any, fallback: string): string
	local clean: string = fallback
	if type(name) == 'string' then
		local trimmed = string.match(string.gsub(name, '%s+', ' '), '^%s*(.-)%s*$') or ''
		if trimmed ~= '' then
			if #trimmed > 40 then
				trimmed = string.sub(trimmed, 1, 40)
			end
			clean = trimmed
		end
	end
	local escaped = RichTextFormatter.Escape(clean)
	local known = false
	pcall(function()
		known = type(rarity) == 'string' and (RarityConfig.RarityColor :: { [string]: any })[rarity] ~= nil
	end)
	if known then
		return RichTextFormatter.Colored(escaped, RichTextFormatter.RarityHex(rarity))
	end
	return escaped
end

-- Canonical mutation color as hex. Unknown/nil ids fall back
-- to white so markup never breaks and nothing looks accidental.
function RichTextFormatter.MutationHex(mutationId: any): string
	local color: Color3? = nil
	pcall(function()
		if type(mutationId) == 'string' then
			color = (OverheadConfig.MutationColors :: { [string]: any })[mutationId]
		end
	end)
	if typeof(color) ~= 'Color3' then
		return '#FFFFFF'
	end
	return RichTextFormatter.ColorHex(color)
end

-- Format a mutation name: escaped always, mutation-colored
-- when the id resolves in OverheadConfig.MutationColors
-- (fallback: escaped plain text). Mirrors Entity().
function RichTextFormatter.Mutation(name: any, mutationId: any, fallback: string): string
	local clean: string = fallback
	if type(name) == 'string' then
		local trimmed = string.match(string.gsub(name, '%s+', ' '), '^%s*(.-)%s*$') or ''
		if trimmed ~= '' then
			if #trimmed > 40 then
				trimmed = string.sub(trimmed, 1, 40)
			end
			clean = trimmed
		end
	end
	local escaped = RichTextFormatter.Escape(clean)
	local known = false
	pcall(function()
		known = type(mutationId) == 'string' and (OverheadConfig.MutationColors :: { [string]: any })[mutationId] ~= nil
	end)
	if known then
		return RichTextFormatter.Colored(escaped, RichTextFormatter.MutationHex(mutationId))
	end
	return escaped
end

return table.freeze(RichTextFormatter)
