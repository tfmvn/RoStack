--!strict
--!native
--[[
	/bring <player>
	Bring the target player to the executor's position. Uses
	their character HRP. If the target is in a different base
	their character will visibly warp; this is an admin tool
	and that is the expected feel.
]]

return {
	Name = 'bring',
	Aliases = {},
	Description = 'Bring a player to your position (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Who to bring.' },
	},
}
