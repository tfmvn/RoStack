--!strict
--!native
--[[
	/resetarena <target>
	Reset the target's arena progression to level 1 (XP 0, wins
	0) through the canonical ArenaProgressionService.ResetArena
	— the same reset Rebirth performs. Active raids are ended
	first via CancelArena. Superadmin-only (progression loss).
]]

return {
	Name = 'resetarena',
	Aliases = {},
	Description = 'Reset arena progression to level 1 (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
