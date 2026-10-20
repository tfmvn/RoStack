--!strict
--!native
--[[
	AdminTargetResolver
	===================
	The single centralized player-target resolver for every admin
	command. Server-authoritative: the client never decides who a
	command affects.

	Supported target text (case-insensitive, surrounding quotes
	already stripped by Cmdr):

	  me            -> the executing admin only
	  all | server  -> every active player in THIS server
	  <username>    -> exact username match (case-insensitive)
	  <display>     -> display-name match (ambiguity-safe)

	`all` and `server` NEVER cross servers. There is no
	cross-server fan-out in this framework (no MessagingService
	path); a future /globalannounce would be an explicitly
	separate system.

	Ambiguous display names NEVER silently pick a player: when two
	or more active players match and none is an exact username
	match, resolution fails with the candidate list so the admin
	can disambiguate.

	Returns:
	  { ok = true, players = { Player }, scope = 'Single' | 'Server', label = string }
	  { ok = false, error = string }
]]

local Players = game:GetService('Players')

local AdminTargetResolver = {}

export type TargetResult = {
	ok: boolean,
	players: { Player }?,
	scope: string?,
	label: string?,
	error: string?,
}

local function _livePlayers(): { Player }
	local out: { Player } = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p and p.Parent then
			out[#out + 1] = p
		end
	end
	return out
end

local function _trim(text: string): string
	return (string.gsub(string.gsub(text, '^%s+', ''), '%s+$', ''))
end

-- Resolve raw target text against the CURRENT live player list.
-- executor is the Player running the command (needed for `me`).
function AdminTargetResolver.Resolve(rawText: any, executor: Player?): TargetResult
	if type(rawText) ~= 'string' then
		return { ok = false, error = 'Target must be text (me, all, server, or a player name).' }
	end
	local text = _trim(rawText)
	if text == '' then
		return { ok = false, error = 'Target must be text (me, all, server, or a player name).' }
	end
	local lowered = string.lower(text)
	if lowered == 'me' then
		if executor == nil or executor.Parent == nil then
			return { ok = false, error = '"me" needs a live executor; use a player name instead.' }
		end
		return { ok = true, players = { executor }, scope = 'Single', label = executor.Name }
	end
	if lowered == 'all' or lowered == 'server' then
		local everyone = _livePlayers()
		if #everyone == 0 then
			return { ok = false, error = 'No players are currently in this server.' }
		end
		return { ok = true, players = everyone, scope = 'Server', label = 'all players' }
	end
	-- Exact username match wins over everything (usernames are
	-- unique per server, so this branch is never ambiguous).
	for _, p in ipairs(_livePlayers()) do
		if string.lower(p.Name) == lowered then
			return { ok = true, players = { p }, scope = 'Single', label = p.Name }
		end
	end
	-- Display-name match: collect ALL candidates first.
	local candidates: { Player } = {}
	for _, p in ipairs(_livePlayers()) do
		local display = ''
		pcall(function()
			display = p.DisplayName
		end)
		if type(display) == 'string' and display ~= '' and string.lower(display) == lowered then
			candidates[#candidates + 1] = p
		end
	end
	if #candidates == 1 then
		return { ok = true, players = { candidates[1] }, scope = 'Single', label = candidates[1].Name }
	end
	if #candidates > 1 then
		local names: { string } = {}
		for _, p in ipairs(candidates) do
			names[#names + 1] = p.Name
		end
		return {
			ok = false,
			error = ('Ambiguous target "%s" matches %d players (%s); use the exact username.'):format(
				text,
				#candidates,
				table.concat(names, ', ')
			),
		}
	end
	return { ok = false, error = ('No player "%s" is in this server.'):format(text) }
end

-- Human-readable aggregate label for admin confirmations.
function AdminTargetResolver.Describe(players: { Player }, scope: string?): string
	if scope == 'Server' then
		return ('%d players'):format(#players)
	end
	if #players == 1 then
		return players[1].Name
	end
	return ('%d players'):format(#players)
end

return table.freeze(AdminTargetResolver)
