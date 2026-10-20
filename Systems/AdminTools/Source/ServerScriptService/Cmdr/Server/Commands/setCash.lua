--!strict
--!native
--[[
	/setcash <target> <amount>
	Set every targeted player's Money to an absolute value. The
	server diffs the current balance and applies the delta through
	EconomyService (AdminSet), so caps and audit reasons behave
	exactly like /setmoney. Targets are told their new balance.
]]

return {
	Name = 'setcash',
	Aliases = {},
	Description = "Set one or more players' money to an absolute value (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'string',
			Name = 'amount',
			Description = 'New absolute balance (BigNumber string, e.g. "100000").',
		},
	},
}
