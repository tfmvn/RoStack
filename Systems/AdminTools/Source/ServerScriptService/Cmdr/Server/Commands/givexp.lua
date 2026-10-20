--!strict
--!native
--[[
	/givexp <player> <animalId> <amount>
	Admin-only development/test command for Phase 2.3 XP validation.
	Resolves the Animal by persistent Id through AnimalService,
	calls the authoritative AddXP boundary. Does NOT directly modify
	animal.XP or profile.Data.Brainrots[].XP.
]]

return {
	Name = 'givexp',
	Aliases = {},
	Description = "Add XP to a player's Animal (admin/dev only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Target player.' },
		{
			Type = 'string',
			Name = 'animalId',
			Description = 'Persistent Animal Id (e.g. AN_ZIIuAOl4nm).',
		},
		{
			Type = 'integer',
			Name = 'amount',
			Description = 'Non-negative integer XP amount.',
		},
	},
}
