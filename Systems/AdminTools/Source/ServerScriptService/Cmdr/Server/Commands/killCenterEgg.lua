--!strict
--!native
--[[
	/killcenteregg <uniqueId>
	Destroy a specific Available center egg by uniqueId. Use
	/listcentereggs to find the id. The egg is removed from
	the registry, the model is destroyed, and the cap-filling
	auto-spawn loop will top it back up on its next tick.

	Alias: kcb
]]

return {
	Name = 'killcenteregg',
	Aliases = { 'kcb' },
	Description = 'Destroy a center Egg by its uniqueId (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'string', Name = 'uniqueId', Description = 'The egg uniqueId (use /listcentereggs).' },
	},
}
