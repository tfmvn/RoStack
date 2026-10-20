--!strict
--!native
--[[
	/removeadmin <userId>
	Remove an admin. Superadmin only. Returns true if the
	userId was in the allowlist and is now gone, false if
	they weren't an admin to begin with.
]]

return {
	Name = 'removeadmin',
	Aliases = {},
	Description = 'Remove an admin by userId (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{ Type = 'number', Name = 'userId', Description = 'The Roblox userId to remove.' },
	},
}
