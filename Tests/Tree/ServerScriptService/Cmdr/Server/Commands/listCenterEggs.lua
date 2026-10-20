--!strict
--!native
--[[
	/listcentereggs
	Print every active center Egg. Same shape as the
	client's ListCenterEggs consumer: uniqueId, rarity, price.
	The output is a multi-line string that Cmdr surfaces in
	chat; keep it readable.

	Alias: lcb
]]

return {
	Name = 'listcentereggs',
	Aliases = { 'lcb' },
	Description = 'List all active center Eggs (admin-only).',
	Group = 'Admin',
	Args = {},
}
