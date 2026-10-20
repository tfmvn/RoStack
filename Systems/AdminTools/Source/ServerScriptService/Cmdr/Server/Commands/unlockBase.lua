--!strict
--!native
--[[
	/unlockbase <target>
	Release the target's base lock through the canonical
	BaseLockService.Unlock (idempotent). Owners are told their
	base was unlocked by an administrator.
]]

return {
	Name = 'unlockbase',
	Aliases = {},
	Description = "Unlock a player's base (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
