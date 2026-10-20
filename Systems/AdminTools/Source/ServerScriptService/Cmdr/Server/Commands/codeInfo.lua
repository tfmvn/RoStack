--!strict
--!native
--[[
	/codeinfo <code>
	Read-only detail for one code: enabled, expiry, per-player
	and global caps, and the full reward table. Changes nothing.
]]

return {
	Name = 'codeinfo',
	Aliases = {},
	Description = "Show one code's rules and rewards read-only (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'codeId',
			Name = 'code',
			Description = 'Code id (autocomplete from the live catalog).',
		},
	},
}
