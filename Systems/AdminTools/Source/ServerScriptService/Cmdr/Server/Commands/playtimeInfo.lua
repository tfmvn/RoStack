--!strict
--!native
--[[
	/playtimeinfo <target>
	Read-only playtime snapshot per player: session playtime so
	far and per-milestone states. Changes nothing.
]]

return {
	Name = 'playtimeinfo',
	Aliases = {},
	Description = 'Show playtime reward state read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
