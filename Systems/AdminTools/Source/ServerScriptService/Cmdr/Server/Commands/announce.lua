--!strict
--!native
--[[
	/announce <message>
	Broadcast a server-wide message to every player. Uses the
	existing PlayerService.Notify path so the announcement
	renders as a top-of-screen toast (same shape as in-game
	rewards). The category is forced to "System" so the
	player's UI styling recognizes it as an admin announcement.
]]

return {
	Name = 'announce',
	Aliases = {},
	Description = 'Broadcast a server-wide message (admin-only).',
	Group = 'Admin',
	Args = {
		{ Type = 'string', Name = 'message', Description = 'The message text.' },
	},
}
