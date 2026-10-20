--!strict
--!native
--[[
	/takecash <target> <amount>
	Remove <amount> from every targeted player's Money (fails per
	target on insufficient funds — never drives a balance
	negative). Uses EconomyService.TrySpendMoney (AdminSet).
	Alias: removecash
]]

return {
	Name = 'takecash',
	Aliases = { 'removecash' },
	Description = 'Remove money from one or more players (admin-only).',
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
			Description = 'Amount to remove (BigNumber string, e.g. "1000").',
		},
	},
}
