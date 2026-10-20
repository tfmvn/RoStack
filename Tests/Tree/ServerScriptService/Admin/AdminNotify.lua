--!strict
--!native
--[[
	AdminNotify
	===========
	The ONE place admin commands build player-facing text and
	deliver target notifications.

	Channel policy (no new framework invented):
	  * Target notifications reuse PlayerService.Notify, the same
	    server -> client toast remote every gameplay system uses.
	    The server builds the text; the client only renders it.
	    Category is 'Admin' so the toast styling marks the
	    administrative origin.
	  * Admin confirmations are the Cmdr Run return string (shown
	    to the executor in chat). This module formats those too.
	  * Broadcasts (/announce, existing) keep category 'System'.
	    Private admin rewards NEVER use the announcement path.

	Ordering rule: notify ONLY after the authoritative operation
	succeeds. Failed targets get a failure explanation, never a
	false success toast.

	All free text is RichText-escaped (player names can contain
	markup characters; toasts render RichText).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)

local PlayerService = require(ServerScriptService.PlayerService)

local AdminNotify = {}

function AdminNotify.Escape(text: string): string
	local ok, safe = pcall(RichTextFormatter.Escape, text)
	if ok and type(safe) == 'string' then
		return safe
	end
	return tostring(text)
end

-- Private admin toast to one player (post-commit only).
function AdminNotify.Tell(player: Player, text: string)
	pcall(PlayerService.Notify, player, 'Admin', text)
end

-- Private admin toast to many players. textFn receives the
-- player and returns that player's personal message.
function AdminNotify.TellAll(players: { Player }, textFn: (Player) -> string)
	for _, p in ipairs(players) do
		local ok, text = pcall(textFn, p)
		if ok and type(text) == 'string' then
			AdminNotify.Tell(p, text)
		end
	end
end

function AdminNotify.FormatMoney(amount: string): string
	local ok, text = pcall(BigNumber.Format, amount)
	if ok and type(text) == 'string' and text ~= '' then
		return '$' .. text
	end
	return '$' .. tostring(amount)
end

function AdminNotify.EggLabel(rarity: string): string
	local display = RarityConfig.RarityDisplayName[rarity]
	if type(display) == 'string' then
		return display
	end
	return tostring(rarity) .. ' Egg'
end

-- "Legendary Egg", "Legendary Egg — Gold",
-- "Legendary Egg — Gold — Frost, Galactic".
function AdminNotify.DescribeEgg(rarity: string, trait: string?, mutations: { string }?): string
	local parts: { string } = { AdminNotify.EggLabel(rarity) }
	if type(trait) == 'string' and trait ~= '' then
		parts[#parts + 1] = trait
	end
	if type(mutations) == 'table' and #mutations > 0 then
		parts[#parts + 1] = table.concat(mutations, ', ')
	end
	return table.concat(parts, ' — ')
end

-- "Dragon", "Dragon — Gold", "Dragon — Gold — Galactic",
-- "Dragon — Gold — Galactic — Lv.25".
function AdminNotify.DescribeAnimal(displayName: string, trait: string?, mutations: { string }?, level: number?): string
	local parts: { string } = { displayName }
	if type(trait) == 'string' and trait ~= '' then
		parts[#parts + 1] = trait
	end
	if type(mutations) == 'table' and #mutations > 0 then
		parts[#parts + 1] = table.concat(mutations, ', ')
	end
	if type(level) == 'number' then
		parts[#parts + 1] = ('Lv.%d'):format(level)
	end
	return table.concat(parts, ' — ')
end

return table.freeze(AdminNotify)
