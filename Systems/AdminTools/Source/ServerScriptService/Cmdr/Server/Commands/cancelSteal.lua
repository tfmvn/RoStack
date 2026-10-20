--!strict
--!native
--[[
	/cancelsteal <target>
	Roll back the target's in-progress steal carry through the
	canonical StealService.RollbackCarried (item returns to the
	original owner, reservations released). Fails loudly when the
	target is not mid-steal. Superadmin-only: it rewrites
	another player's in-flight multiplayer interaction.
]]

return {
	Name = 'cancelsteal',
	Aliases = {},
	Description = 'Roll back an in-progress steal (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
