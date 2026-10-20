--!strict
--!native
--[[
	/tptobase <player>
	Teleport the executor to the target player's base. If the
	target has no base, returns a clear error. Uses the base's
	spawnCFrame + 4y so the character doesn't spawn in the floor.
]]

return {
	Name = 'tptobase',
	Aliases = { 'tpb' },
	Description = "Teleport yourself to a player's base (admin-only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Whose base to teleport to.' },
	},
}
