--!strict
--!native
--[[
	/ragdoll <target> [duration]
	Ragdoll the target through the canonical RagdollService
	(same R15 path the Bat PvP uses). Duration 1-30s, default 5.
	Already-ragdolled targets fail loudly instead of silently
	refreshing (the service does not refresh running ragdolls).
]]

return {
	Name = 'ragdoll',
	Aliases = {},
	Description = 'Ragdoll a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'duration',
			Description = 'Seconds, 1-30 (default 5).',
			Optional = true,
		},
	},
}
