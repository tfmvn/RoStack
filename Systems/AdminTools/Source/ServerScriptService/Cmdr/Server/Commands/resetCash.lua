--!strict
--!native
--[[
	/resetcash <target>
	Reset every targeted player's Money to EconomyConfig
	StartingMoney (same delta path as /setcash, AdminSet).
	Targets are told their balance was reset.
]]

return {
	Name = 'resetcash',
	Aliases = {},
	Description = "Reset one or more players' money to the starting value (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
