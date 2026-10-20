--!strict
--!native
--[[
	/sellanimal <target> <animalId>
	Force-sell a live animal through the canonical
	SellService.SellAnimal transaction (same validation, same
	payout math, same pool settlement as the Sell prompt). The
	payout goes to the owner, who also keeps the standard
	Sell_Success toast from the service. Cannot sell carried,
	stolen, or arena-locked animals.
]]

return {
	Name = 'sellanimal',
	Aliases = {},
	Description = 'Force-sell a live animal at canonical price (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'Owner scope: me, all, server, or a player name.',
		},
		{
			Type = 'string',
			Name = 'animalId',
			Description = 'The BR_ UniqueId (see /listanimals).',
		},
	},
}
