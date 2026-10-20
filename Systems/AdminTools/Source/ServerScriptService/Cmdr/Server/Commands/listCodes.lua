--!strict
--!native
--[[
	/listcodes
	Read-only code catalog: every code id with enabled state
	and reward summary, straight from CodesConfig. Changes
	nothing. There is no runtime enable/disable API (Enabled is
	static config), so none is exposed.
]]

return {
	Name = 'listcodes',
	Aliases = {},
	Description = 'List all redeem codes read-only (admin-only).',
	Group = 'Admin',
	Args = {},
}
