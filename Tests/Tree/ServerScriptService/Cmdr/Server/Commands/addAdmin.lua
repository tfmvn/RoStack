--!strict
--!native
--[[
	/addadmin <userId> <rank>
	Add (or update) an admin. userId can be offline — the
	allowlist is a pure numeric table, so a brand-new Roblox
	account that has never joined is fine. Superadmin only.
]]

return {
	Name = 'addadmin',
	Aliases = {},
	Description = 'Add an admin by userId at a given rank (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{ Type = 'number', Name = 'userId', Description = 'The Roblox userId (can be offline).' },
		{ Type = 'string', Name = 'rank', Description = 'mod, admin, or superadmin.' },
	},
}
