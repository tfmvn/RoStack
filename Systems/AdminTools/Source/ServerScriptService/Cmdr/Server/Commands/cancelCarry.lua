--!strict
--!native
--[[
	/cancelcarry <target>
	Return the target's carried animal or egg to its original
	slot (or the authoritative fallback) using the same dispatch
	as death/disconnect recovery: steal-carries roll back via
	StealService, animals via AnimalService.RecoverCarriedAnimal,
	eggs via EggService.RecoverCarriedEgg. Fails loudly when the
	target carries nothing.
]]

return {
	Name = 'cancelcarry',
	Aliases = {},
	Description = 'Return a carried animal/egg to its slot (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
