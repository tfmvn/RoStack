--!strict
--!native
--[[
	/setlevel <player> <rarity> <level>
	Placeholder. Sets a player's *level cap* for the given rarity
	(no per-animal level system exists yet). The intended end
	state is a per-defId level; for now this stores the value in
	the player's profile under a Reserved field so future code can
	read it without a schema migration.

	Designed as a no-op stub: the command is wired so designers
	can discover it, but the meaningful implementation lives
	once the animal-level system is built.
]]

return {
	Name = 'setlevel',
	Aliases = {},
	Description = 'Set an animal level (placeholder; no-op until level system is built).',
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Target.' },
		{ Type = 'string', Name = 'rarity', Description = 'Common, Uncommon, ...' },
		{ Type = 'number', Name = 'level', Description = 'Level value (1-99).' },
	},
}
