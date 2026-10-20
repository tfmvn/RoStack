--!strict
--!native
--[[
	/tp <player1> <player2>
	Teleport player1 to player2's position. Use /bring if you
	want the inverse. Both players must be alive (have a
	character with a HumanoidRootPart).
]]

return {
	Name = 'tp',
	Aliases = {},
	Description = 'Teleport <player1> to <player2> (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'from', Description = 'Who to teleport.' },
		{ Type = 'player', Name = 'to', Description = 'Destination.' },
	},
}
