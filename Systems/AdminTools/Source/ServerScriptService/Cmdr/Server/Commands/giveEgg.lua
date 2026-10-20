--!strict
--!native
--[[
	/giveegg <target> <egg> [trait] [mutations] [quantity]
	Grant eggs straight into the targeted players' bases through
	the canonical Codes reward pipeline (slot reserve,
	persistence write, SpawnFromPersistence, state push). <egg>
	is the egg rarity (autocomplete from EggConfig). Trait is a
	SINGLE hidden preassigned id (or - for none); mutations is a
	comma-separated list (e.g. Galactic,Frost). Full bases queue the
	reward as pending instead of failing silently.
	Aliases: ge, addegg
]]

return {
	Name = 'giveegg',
	Aliases = { 'ge', 'addegg' },
	Description = 'Grant eggs to one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'eggRarity',
			Name = 'egg',
			Description = 'Egg rarity (autocomplete from the live catalog).',
		},
		{
			Type = 'traitId',
			Name = 'trait',
			Description = 'Single hidden trait id, or - for none.',
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
			Name = 'quantity',
			Description = 'How many to grant (default 1, max 10).',
			Optional = true,
		},
	},
}
