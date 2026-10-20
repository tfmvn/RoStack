--!strict
--!native
--[[
	/clearmoneymultiplier <target>
	Drop the target's 'AdminOverride' money source through the
	canonical ModifierService.RemoveModifier, returning income
	to its non-admin value. Targets are told their multiplier
	was cleared.
]]

return {
	Name = 'clearmoneymultiplier',
	Aliases = {},
	Description = "Clear a player's admin money multiplier (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
