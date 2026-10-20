--!strict
--!native
--[[
	/carryinfo <target>
	Read-only carry report per player: what (if anything) they
	are carrying, of which kind, and whether it is a steal in
	progress. Reads the CarryRegistry, the single source of
	truth. Changes nothing.
]]

return {
	Name = 'carryinfo',
	Aliases = {},
	Description = 'Show carry/steal state read-only (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
