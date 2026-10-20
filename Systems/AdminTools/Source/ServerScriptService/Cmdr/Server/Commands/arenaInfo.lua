--!strict
--!native
--[[
	/arenainfo <target>
	Read-only arena report per player: level, XP, wins, highest
	completed, and whether a raid is currently active. Changes
	nothing.
]]

return {
	Name = 'arenainfo',
	Aliases = {},
	Description = 'Show arena progression read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
