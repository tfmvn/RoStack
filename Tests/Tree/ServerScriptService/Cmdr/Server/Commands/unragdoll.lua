--!strict
--!native
--[[
	/unragdoll <target>
	Stand the target back up through the canonical
	RagdollService.Unragdoll. Fails loudly when the target is
	not ragdolled.
]]

return {
	Name = 'unragdoll',
	Aliases = {},
	Description = 'Stand a ragdolled player back up (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
