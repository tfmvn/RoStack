--!strict
--!native
--[[
	/givemoney <player> <amount>
	Add <amount> to the target's Money. <amount> is a string
	parsed as a BigNumber (e.g. "1000", "5e12", "1.5Qa")
	because the economy is string-backed arbitrary precision.
	Negative amounts are rejected by EconomyService.AddMoney
	as `invalid-amount`; `EconomyConfig.MaxMoney` is the cap and
	is enforced inside the service. Pushes the new state to
	the client so the HUD updates.

	Renamed from `givecash` in Phase 2.1 — the old numeric
	economy is gone.
]]

return {
	Name = 'givemoney',
	Aliases = {},
	Description = 'Add money to a player (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Target.' },
		{
			Type = 'string',
			Name = 'amount',
			Description = 'Amount to add (BigNumber string, e.g. "1000", "5e12", "1.5Qa").',
		},
	},
}
