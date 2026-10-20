--!strict
--!native
--[[
	/adminlog [count]
	Show the newest server-side admin audit entries (actor,
	command, success). Read-only; the trail itself is written by
	every admin command through AdminAudit. Default 10, max 100.
]]

return {
	Name = 'adminlog',
	Aliases = {},
	Description = 'Show recent admin audit entries (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'number',
			Name = 'count',
			Description = 'How many entries (default 10, max 100).',
			Optional = true,
		},
	},
}
