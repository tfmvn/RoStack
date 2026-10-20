--!strict
--!native
--[[
	/playtimeclaim <target> <milestone>
	Claim a playtime milestone FOR the target through the
	canonical PlaytimeRewardsService.Claim (same session-clock
	validation, reward pipeline, and pending queue as the
	playtime UI). There is no playtime setter in the backend —
	only real claims — so this command claims, never edits.
]]

return {
	Name = 'playtimeclaim',
	Aliases = {},
	Description = 'Claim a playtime milestone for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'milestone',
			Description = 'Milestone index to claim.',
		},
	},
}
