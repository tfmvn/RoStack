--!strict
--!native
--[[
	/setanimallevel <target> <animalId> <level>
	Set a live animal's level (1-100, the LevelConfig ceiling).
	Raises run through the canonical ApplyLevelUpgrade step by
	step (same persistence, presentation, and overhead refresh as
	a paid upgrade); lowers set the authoritative runtime +
	profile records directly and refresh the overhead. The owner
	is told the new level.
]]

return {
	Name = 'setanimallevel',
	Aliases = {},
	Description = "Set a live animal's level (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'Owner scope: me, all, server, or a player name.',
		},
		{
			Type = 'string',
			Name = 'animalId',
			Description = 'The BR_ UniqueId (see /listanimals).',
		},
		{
			Type = 'number',
			Name = 'level',
			Description = 'New level, 1-100.',
		},
	},
}
