--!strict
--!native
--[[
	/tell <target> <message>
	Send a private administrator message to the target through
	the standard toast remote (category Admin). Unlike /announce
	(which broadcasts server-wide as System), /tell is per
	target — the admin gets a delivery count, each target gets
	only their own toast, and nobody else sees anything.
]]

return {
	Name = 'tell',
	Aliases = {},
	Description = 'Send a private admin message (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'string',
			Name = 'message',
			Description = 'The message text (max 240 characters).',
		},
	},
}
