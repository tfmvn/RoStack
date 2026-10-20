--!strict
--!native
--[[
	/luck [value]
	Get or set the server-wide Luck multiplier for normal Egg
	rarity rolls. Omit the value to show current luck;
	`reset` returns to 1.0x; any finite positive number sets
	it (fractionals like 0.5 allowed, high test values like
	100/1000 allowed). Luck shapes normal rolls only —
	guarantees, admin-forced rarities, lifetimes, and prices
	are untouched.
]]

return {
	Name = 'luck',
	Aliases = {},
	Description = 'Show or set server-wide Egg rarity Luck (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'string',
			Name = 'value',
			Description = 'New multiplier, "reset", or omit to show current.',
			Optional = true,
		},
	},
}
