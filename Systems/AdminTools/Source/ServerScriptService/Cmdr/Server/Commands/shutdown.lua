--!strict
--!native
--[[
	/shutdown <reason>
	Shut the server down with a reason. Superadmin only.
	Calls game:BindToClose to give players a clean kick
	message, then waits a short grace period before pulling
	the rug. The grace period is short (3s) because this is
	an emergency command, not a maintenance window — by the
	time you're running it you've already decided.
]]

return {
	Name = 'shutdown',
	Aliases = {},
	Description = 'Shut the server down (superadmin-only).',
	Group = 'Superadmin',
	Args = {
		{ Type = 'string', Name = 'reason', Description = 'Why the server is going down.' },
	},
}
