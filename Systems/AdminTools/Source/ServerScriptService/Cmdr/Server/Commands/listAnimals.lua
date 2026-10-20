--!strict
--!native
--[[
	/listanimals <target>
	Read-only inspection of a player's persisted animals: BR_
	UniqueId, definition, trait, mutations, level, slot, and
	live state. The ids printed here are the /removeanimal,
	/setanimallevel, and /sellanimal handles. Changes nothing.
]]

return {
	Name = 'listanimals',
	Aliases = {},
	Description = "Inspect a player's animals read-only (admin-only).",
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
