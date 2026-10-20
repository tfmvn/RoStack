--!strict
--!native
--[[
	/dailyclaim <target> <day>
	Claim a daily streak day FOR the target through the canonical
	DailyRewardsService.Claim (same streak advance, reward
	pipeline, and pending queue as the Daily UI). There is no
	streak setter in the backend — only real claims — so this
	command claims, never edits. Day is the 1-7 streak day.
]]

return {
	Name = 'dailyclaim',
	Aliases = {},
	Description = 'Claim a daily reward day for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'number',
			Name = 'day',
			Description = 'Streak day to claim (1-7).',
		},
	},
}
