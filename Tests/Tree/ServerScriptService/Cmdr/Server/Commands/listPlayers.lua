--!strict
--!native
--[[
	/listplayers
	Print every player currently in the server: name, userId,
	display name, account age. Useful for admin intros and
	for verifying a playtest is loaded.
]]

return {
	Name = 'listplayers',
	Aliases = { 'lp' },
	Description = 'List all players currently in the server (admin-only).',
	Group = 'Admin',
	Args = {},
}
