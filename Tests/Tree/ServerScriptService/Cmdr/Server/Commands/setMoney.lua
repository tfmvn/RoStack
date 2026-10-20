--!strict
--!native
--[[
	/setmoney <player> <amount>
	Set the target's Money to <amount>. <amount> is a string
	parsed as a BigNumber (e.g. "1000", "5e12"). The current
	balance is read, the delta is derived, and one atomic
	call applies the difference: AddMoney when the target is
	higher, TrySpendMoney when it is lower (admins may set
	any absolute value, up or down).

	The cap is `EconomyConfig.MaxMoney` and is enforced inside
	EconomyService — we don't clamp here because the service
	emits a `cap-exceeded` code that we surface.

	Renamed from `setcash` in Phase 2.1 — the old numeric
	economy is gone.
]]

return {
	Name = 'setmoney',
	Aliases = {},
	Description = "Set a player's money to a value (admin-only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Target.' },
		{
			Type = 'string',
			Name = 'amount',
			Description = 'New money value (BigNumber string, e.g. "1000", "5e12").',
		},
	},
}
