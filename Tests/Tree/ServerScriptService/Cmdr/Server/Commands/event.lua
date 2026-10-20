--!strict
--!native
--[[
	/event <action> [eventId]
	Server-authoritative control over the generic Event Engine
 	(EventService). Actions:

 	  status            — show current + next scheduled event.
 	  start <eventId>   — run the full StartEvent lifecycle
 	                       for Galaxy/Snowfall (same path the
 	                       scheduler uses — assets, time, env,
 	                       mutation sweep, UI).
 	  stop              — run the normal EndEvent cleanup
 	                       (assets removed, env/time restored,
 	                       egg mutations KEPT).

 	No event behavior lives here: every action delegates to
 	EventService. Group: Admin.
]]

return {
	Name = 'event',
	Description = 'Control world events: status, start <Galaxy|Snowfall>, stop (admin-only).',
	Group = 'Admin',
	Args = {
		{
			Type = 'string',
			Name = 'action',
			Description = 'status, start, or stop.',
		},
		{
			Type = 'string',
			Name = 'eventId',
			Description = 'Event to start: Galaxy or Snowfall. Omit for status/stop.',
			Optional = true,
		},
	},
}
