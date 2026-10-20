--!strict
--!native
--[[
	/givearenawin <target> <level>
	Record a stage clear at <level> through the canonical
	ArenaProgressionService.RecordLevelWin (wins, highest
	completed, first-clear logic identical to a real victory).
	Use after /givearenaxp when the target must also satisfy
	stage-gated requirements such as Rebirth.
]]

return {
	Name = 'givearenawin',
	Aliases = {},
	Description = 'Record an arena stage clear for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'level',
			Description = 'Cleared stage (1 to the arena max).',
		},
	},
}
