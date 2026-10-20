--!strict
--!native
--[[
	/getstats <player> <animalId>
	Admin-only development/test command for Phase 2.5 stat scaling.
	Reads the derived Health/Damage through the authoritative
	AnimalService.GetStats path (AnimalStats -> StatCalculator)
	— it never recomputes stats locally, so what it prints is what
	the game would push. An unknown/foreign Id replies with the
	target player's Animal list so the right Id can be copied.
]]

return {
	Name = 'getstats',
	Aliases = {},
	Description = "Show an Animal's Level/XP and derived Health/Damage (admin/dev only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Owner of the Animal.' },
		{
			Type = 'string',
			Name = 'animalId',
			Description = 'Persistent Animal Id (e.g. AN_MQz0fQrWbu).',
		},
	},
}
