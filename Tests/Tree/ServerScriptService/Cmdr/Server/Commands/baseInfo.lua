--!strict
--!native
--[[
	/baseinfo <target>
	Read-only base report per player: base id, lock state +
	remaining lock time, slot occupancy. Changes nothing.
]]

return {
	Name = 'baseinfo',
	Aliases = {},
	Description = 'Show base state read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
