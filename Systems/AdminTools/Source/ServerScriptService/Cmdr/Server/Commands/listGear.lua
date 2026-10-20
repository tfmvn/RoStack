--!strict
--!native
--[[
	/listgear <target>
	Read-only gear report per player: every Gear Shop entry with
	owned/locked state (rebirth gate from the live Rebirth count).
	Changes nothing.
]]

return {
	Name = 'listgear',
	Aliases = {},
	Description = "Inspect a player's gear ownership read-only (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
