--!strict
--!native
--[[
	/forcerebirth <target>
	Run the canonical RebirthService.RequestRebirth transaction
	for the target (next sequential rebirth only). Requirements
	(money, arena level, animals) are NOT bypassed — grant them
	first with /givecash, /giveanimal, /givearenaxp if needed. A
	failure names the unmet requirement instead of claiming
	success. The full commit (base rebuild, arena reset, money
	reset, multiplier, persistence, live world) is the service's
	own, never a partial admin copy.
]]

return {
	Name = 'forcerebirth',
	Aliases = {},
	Description = 'Run the canonical rebirth transaction for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
