--!strict
--!native
--[[
	/wipeplayer <player>
	Reset the target player's data to defaults. Uses the
	existing BaseService.WipePlayerData path so the wipe is
	identical to a Studio-cmd-bar wipe: cash reset, animal +
	lucky-egg inventories cleared, base released. If the
	player is currently in-game, a fresh base is assigned and
	the new state is pushed immediately.
]]

return {
	Name = 'wipeplayer',
	Aliases = {},
	Description = "Wipe a player's data to defaults (admin-only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'The target player.' },
	},
}
