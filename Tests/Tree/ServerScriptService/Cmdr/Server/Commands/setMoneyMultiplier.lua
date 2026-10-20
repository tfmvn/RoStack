--!strict
--!native
--[[
	/setmoneymultiplier <target> <value>
	Set the target's money multiplier through the canonical
	ModifierService (source 'AdminOverride', Multiply). Reads
	back GetMoneyMultiplier to confirm the applied value. The
	override is session-scoped like every modifier source and is
	re-applied from persistence rules on rejoin; use
	/clearmoneymultiplier to drop it.
]]

return {
	Name = 'setmoneymultiplier',
	Aliases = {},
	Description = "Set a player's money multiplier (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'value',
			Description = 'Multiplier, 0.01 to 100 (e.g. 2 for double income).',
		},
	},
}
