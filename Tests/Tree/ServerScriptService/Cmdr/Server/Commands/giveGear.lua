--!strict
--!native
--[[
	/givegear <target> <gear>
	Grant one Gear Shop tool through the canonical
	GearShopService.EnsureGearTool (idempotent, no charge, no
	rebirth bypass messaging — the entry's RequiredRebirth is
	reported when relevant). The target gets a "You received"
	toast with the canonical display name.
]]

return {
	Name = 'givegear',
	Aliases = {},
	Description = 'Grant a gear tool to one or more players (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
		{
			Type = 'gearId',
			Name = 'gear',
			Description = 'Gear id (autocomplete from the live shop catalog).',
		},
	},
}
