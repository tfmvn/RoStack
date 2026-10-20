--!strict
--!native
--[[
	/spawnegg <rarity> [mutations] [trait] [count]
	Spawn one or more Eggs of the given rarity at the
	center. Bypasses the price check (admin-spawned eggs are
	free) but DOES respect the 10-egg cap. If the cap is full
	the command returns a clear error rather than silently
	dropping the request.

	Phase 2.11: optional mutations + hidden preassigned trait.
	Mutations ride the egg into opening inheritance; the trait
	transfers 100% (no roll). Cmdr has no array arg type, so
	mutations travel as one comma-separated string
	(`Galactic,Frost` — brackets/quotes/spaces tolerated) and
	the trait as one id string. `-`, `none`, `[]` (or omission)
	mean "none". All validated server-side against
	MutationConfig / TraitConfig with loud errors.

	Alias: slb
]]

return {
	Name = 'spawnegg',
	Aliases = { 'slb' },
	Description = 'Spawn an Egg of <rarity> at the center (admin-only). Optional mutations (Galactic,Frost) + hidden trait.',
	Group = 'Admin',
	Args = {
		{
			Type = 'string',
			Name = 'rarity',
			Description = 'Common, Uncommon, Rare, Epic, Mythic, Legendary, Divine, Secret.',
		},
		{
			Type = 'string',
			Name = 'mutations',
			Description = 'Optional comma-separated mutations, e.g. Galactic,Frost. Use - for none.',
			Optional = true,
		},
		{
			Type = 'string',
			Name = 'trait',
			Description = 'Optional hidden preassigned trait, e.g. Rainbow. Omit for a normal roll.',
			Optional = true,
		},
		{
			Type = 'number',
			Name = 'count',
			Description = 'How many to spawn (default 1, max 10).',
			Optional = true,
			Default = 1,
		},
	},
}
