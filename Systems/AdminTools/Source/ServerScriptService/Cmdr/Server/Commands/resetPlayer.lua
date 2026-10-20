--!strict
--!native
--[[
	/resetplayer <player>
	Alias of /wipeplayer. Same effect: full data reset,
	fresh base, pushed state. Kept as a separate command so
	designers who think of "reset" rather than "wipe" can find
	it without searching.
]]

return {
	Name = 'resetplayer',
	Aliases = {},
	Description = 'Full data reset (alias of /wipeplayer).',
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'The target player.' },
	},
}
