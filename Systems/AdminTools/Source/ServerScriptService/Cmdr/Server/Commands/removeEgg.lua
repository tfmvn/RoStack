--!strict
--!native
--[[
	/removeegg <target> <eggId>
	Permanently delete one placed egg (by its EG_ UniqueId)
	owned by the target. Carried, stolen, or in-flight eggs are
	refused, never force-torn. The slot is released and the
	profile record removed. Superadmin-only.
]]

return {
	Name = 'removeegg',
	Aliases = {},
	Description = 'Permanently delete a placed egg (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'Owner scope: me, all, server, or a player name.',
		},
		{
			Type = 'string',
			Name = 'eggId',
			Description = 'The EG_ UniqueId of the placed egg.',
		},
	},
}
