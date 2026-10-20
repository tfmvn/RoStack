--!strict
--!native
--[[
	/giveanimal <target> <animal> [trait] [mutations] [level] [quantity]
	Grant animals straight into the targeted players' bases
	through the canonical Codes reward pipeline (slot reserve,
	persistence write, SpawnFromPersistence, state push). Trait
	is a SINGLE id (or - for none); mutations is a
	comma-separated list (e.g. Galactic,Frost). Full bases queue
	the reward as pending instead of failing silently.
	Aliases: ga, addanimal
]]

return {
	Name = 'giveanimal',
	Aliases = { 'ga', 'addanimal' },
	Description = 'Grant animals to one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'animalDef',
			Name = 'animal',
			Description = 'Animal definition id (autocomplete from the live catalog).',
		},
		{
			Type = 'traitId',
			Name = 'trait',
			Description = 'Single trait id, or - for none.',
			Optional = true,
		},
		{
			Type = 'mutationList',
			Name = 'mutations',
			Description = 'Comma-separated mutations, e.g. Galactic,Frost. Omit for none.',
			Optional = true,
		},
		{
			Type = 'number',
			Name = 'level',
			Description = 'Level 1-100 (default 1).',
			Optional = true,
		},
		{
			Type = 'number',
			Name = 'quantity',
			Description = 'How many to grant (default 1, max 5).',
			Optional = true,
		},
	},
}
