--!strict
--!native
--[[
	/cancelarena <target>
	End the target's active expedition through the canonical
	ArenaService.CancelArena (progressive settle: cleared stages
	pay, normal cleanup runs). Fails loudly when no session is
	active.
]]

return {
	Name = 'cancelarena',
	Aliases = {},
	Description = "End a player's active arena expedition (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
