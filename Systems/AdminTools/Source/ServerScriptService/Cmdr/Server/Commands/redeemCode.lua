--!strict
--!native
--[[
	/redeemcode <target> <code>
	Redeem a code FOR the target through the canonical
	CodesService.Redeem (same validation, caps, reward pipeline,
	and pending queue as the Codes UI). Per-player and global
	caps still apply — an exhausted code fails loudly instead of
	double-granting.
]]

return {
	Name = 'redeemcode',
	Aliases = {},
	Description = 'Redeem a code for one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'codeId',
			Name = 'code',
			Description = 'Code id (autocomplete from the live catalog).',
		},
	},
}
