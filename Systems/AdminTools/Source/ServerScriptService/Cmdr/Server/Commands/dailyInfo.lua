--!strict
--!native
--[[
	/dailyinfo <target>
	Read-only daily streak snapshot per player: current day,
	claimable day, and per-day states. Changes nothing.
]]

return {
	Name = 'dailyinfo',
	Aliases = {},
	Description = 'Show daily streak state read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
