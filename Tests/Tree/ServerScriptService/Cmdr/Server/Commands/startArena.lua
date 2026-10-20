--!strict
--!native
--[[
	/startarena <target> [option]
	Start an arena expedition for the target through the one
	authoritative path (ArenaService.StartArena). Option is
	Buy3 (free stage-1 entry, default), Buy1 (paid warmup
	restart), or Buy2 (paid direct restart); the server resolves
	stage + price per request. Loadout, HP, and rewards are never
	accepted from anyone. Forced starts run normal validation —
	a target with no team or an active raid fails loudly.
]]

return {
	Name = 'startarena',
	Aliases = {},
	Description = 'Start an arena expedition for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'arenaOption',
			Name = 'option',
			Description = 'Buy3 (default), Buy1, or Buy2.',
			Optional = true,
		},
	},
}
