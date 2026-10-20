--!strict
--!native
--[[
	/givecash <target> <amount>
	Add <amount> to every targeted player's Money. Target is
	me | all | server | player name (quote names with spaces).
	<amount> is a BigNumber string ("1000", "5e12", "1.5Qa").
	Each successful target gets a private toast; the admin gets
	the aggregate result. Uses EconomyService (AdminGive).
	Alias: addcash
]]

return {
	Name = 'givecash',
	Aliases = { 'addcash' },
	Description = 'Add money to one or more players (admin-only).',
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
			Description = 'Amount to add (BigNumber string, e.g. "1000", "5e12").',
		},
	},
}
