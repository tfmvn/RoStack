--!strict
--!native
--[[
	/speed <value>
	Set the executor's WalkSpeed. Default is 16 (set in
	bootstrap on character spawn). 0 freezes the character
	on the spot; 200 is the practical upper bound before
	movement becomes uncontrollable. The Humanoid's Run
	property is left at its default — WalkSpeed is the
	canonical control.
]]

return {
	Name = 'speed',
	Aliases = {},
	Description = 'Set your WalkSpeed (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'number', Name = 'value', Description = 'WalkSpeed (0..200).' },
	},
}
