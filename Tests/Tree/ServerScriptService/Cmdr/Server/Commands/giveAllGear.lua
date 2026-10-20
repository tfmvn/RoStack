--!strict
--!native
--[[
	/giveallgear <target>
	Grant every Gear Shop entry through the same canonical
	EnsureGearTool path as /givegear, one entry at a time.
	Targets get one summary toast listing what is new to them.
]]

return {
	Name = 'giveallgear',
	Aliases = {},
	Description = 'Grant every gear tool to one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
