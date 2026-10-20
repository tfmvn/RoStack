--!strict
--!native
--[[
	/slowmode <seconds>
	Placeholder. Roblox chat slowmode is set via
	TextChatService.SetChannelRateLimit (for TextChatService)
	or TextService.SetChatVersion. This command is wired so
	designers can find it; the implementation is a one-liner
	once the chat service choice is finalized. For now the
	command logs the request and returns the would-be behavior.
]]

return {
	Name = 'slowmode',
	Aliases = {},
	Description = 'Set chat slowmode (placeholder; no-op until chat service is wired).',
	Group = 'Admin',
	Args = {
		{ Type = 'number', Name = 'seconds', Description = 'Seconds between chat messages (0 = off).' },
	},
}
