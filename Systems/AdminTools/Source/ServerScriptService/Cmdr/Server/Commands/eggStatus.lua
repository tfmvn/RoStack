--!strict
--!native
--[[
	/eggstatus
	Read-only center-egg report: active count vs cap, per-state
	counts, and the Legendary/Mythic guarantee state (interval,
	remaining, due). Changes nothing. Uses SpawnService +
	EggConfig directly; there is no force/reset guarantee API,
	so none is exposed.
]]

return {
	Name = 'eggstatus',
	Aliases = {},
	Description = 'Show center-egg pool and guarantee status (admin-only).',
	Group = 'Admin',
	Args = {},
}
