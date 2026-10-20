--!strict
--!native
--[[
	/getplayerstats <player>
	Print a snapshot of the target player's stats: money, base,
	owned lucky eggs, owned animals. Pulls the values the
	same way the client HUD does (BaseService.Snapshot +
	EconomyService.GetMoney).

	Phase 2.1: `cash` is replaced by `money` (string). The HUD
	formats the string on the client; the command bar here
	prints the raw canonical BigNumber.
]]

return {
	Name = 'getplayerstats',
	Aliases = { 'gps' },
	Description = "Print a player's money, base, and inventory (admin-only).",
	Group = 'Admin',
	Args = {
		{ Type = 'player', Name = 'player', Description = 'Whose stats to print.' },
	},
}
