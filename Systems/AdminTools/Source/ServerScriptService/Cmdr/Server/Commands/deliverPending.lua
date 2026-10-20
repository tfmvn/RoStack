--!strict
--!native
--[[
	/deliverpending <target>
	Retry delivery of queued code/admin rewards for the target
	through the canonical CodesService.TryDeliverPending (the
	same hook join/sell run). Delivers whatever now fits;
	whatever still has no slot stays queued. Targets are told
	what arrived by the service itself.
]]

return {
	Name = 'deliverpending',
	Aliases = {},
	Description = 'Retry queued reward delivery for a player (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'adminTarget',
			Name = 'target',
			Description = 'me, all, server, or a player name (quote names with spaces).',
		},
	},
}
