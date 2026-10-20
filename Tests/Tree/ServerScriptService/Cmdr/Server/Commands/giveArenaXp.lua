--!strict
--!native
--[[
	/givearenaxp <target> <amount>
	Grant arena XP through the canonical
	ArenaProgressionService.AddArenaXP (same thresholds and
	level-ups as battle XP). There is no absolute level setter
	in the backend, so XP is the honest control; pair with
	/givearenawin to also record clears.
]]

return {
	Name = 'givearenaxp',
	Aliases = {},
	Description = 'Grant arena XP to one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'amount',
			Description = 'Whole XP amount (positive).',
		},
	},
}
