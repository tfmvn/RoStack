--!strict
--!native
--[[
	/standinfo <target>
	Read-only stand report per player: desired vs actual animal
	stands and arena stands (DynamicSlotService desired counts
	from the live rebirth unlocks vs the live base). There is no
	manual stand-count setter — counts derive from Rebirth, so
	this command reports drift without inventing a second
	unlock authority. Changes nothing.
]]

return {
	Name = 'standinfo',
	Aliases = {},
	Description = 'Show stand counts read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
