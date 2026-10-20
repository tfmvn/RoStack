--!strict
--!native
--[[
	/rebirthinfo <target>
	Read-only rebirth report per player: current rebirth, next
	requirements with satisfied flags, and unlock preview (the
	same BuildState the Rebirth UI renders). Changes nothing.
]]

return {
	Name = 'rebirthinfo',
	Aliases = {},
	Description = 'Show rebirth progress read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
