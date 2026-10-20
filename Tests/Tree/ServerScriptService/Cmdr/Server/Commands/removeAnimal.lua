--!strict
--!native
--[[
	/removeanimal <target> <animalId>
	Permanently delete one live animal (by its BR_ UniqueId — see
	/listanimals) owned by the target. Carried, stolen, or
	arena-locked animals are refused, never force-torn. The slot
	is released and the profile record removed. Superadmin-only.
]]

return {
	Name = 'removeanimal',
	Aliases = {},
	Description = 'Permanently delete a live animal (superadmin-only).',
	Group = 'Superadmin',
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
	},
}
