--!strict
--!native
--[[
	/lockbase <target>
	Engage the target's base lock through the canonical
	BaseLockService.Lock (same state, collision, visuals, and
	timer as the owner button). The owner keeps no exemption
	bypass: this is the identical lock anyone's base can hold.
]]

return {
	Name = 'lockbase',
	Aliases = {},
	Description = "Lock a player's base (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
