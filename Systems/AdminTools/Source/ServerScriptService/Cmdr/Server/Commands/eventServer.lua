--!strict
--!native
--[[
	eventServer
	Server-side Run for /event. Loaded by Cmdr's
	Registry:RegisterCommand as commandObject.Run; executes only
	on the server. The shared event.lua carries the definition
	(Name/Group/Args) and is replicated to the client, which
	forwards execution here through the Cmdr RemoteFunction.

	Permission + validation happen here, inside the
	authoritative boundary. Every action delegates to the
	SAME EventService APIs the scheduler uses — never a
	duplicate event implementation.
]]

local ServerScriptService = game:GetService('ServerScriptService')

local Debug = require(game.ReplicatedStorage.Utility.Debug)

local function _normalizeId(raw: string?): string?
	if type(raw) ~= 'string' or raw == '' then
		return nil
	end
	local lowered = string.lower(raw)
	if lowered == 'galaxy' then
		return 'Galaxy'
	end
	if lowered == 'snowfall' then
		return 'Snowfall'
	end
	return nil
end

return function(context, action: string, eventId: string?)
	local AdminService = require(ServerScriptService.Admin.AdminService)
	local EventService = require(ServerScriptService.Event.EventService)
	AdminService.AssertAdmin(context.Executor.UserId)
	local verb = if type(action) == 'string' then string.lower(action) else ''
	if verb == 'status' then
		local current = EventService.GetCurrentEvent()
		local next = EventService.GetNextEvent()
		local curText = 'none'
		if current ~= nil then
			curText = ('%s (ends in %s)'):format(
				tostring(current.Id),
				EventService.FormatCountdown(math.max(0, current.EndAt - os.time()))
			)
		end
		local nextText = 'none scheduled'
		if next ~= nil then
			local id = next.Id
			if type(id) == 'string' and id ~= '' then
				nextText = ('%s in %s'):format(
					tostring(id),
					EventService.FormatCountdown(math.max(0, next.At - os.time()))
				)
			else
				nextText = ('normal cycle in %s'):format(EventService.FormatCountdown(math.max(0, next.At - os.time())))
			end
		end
		return ('Current event: %s | Next: %s'):format(curText, nextText)
	end
	if verb == 'stop' or verb == 'end' then
		local current = EventService.GetCurrentEvent()
		if current == nil then
			return 'No event is active.'
		end
		local id = tostring(current.Id)
		EventService.EndEvent('admin')
		Debug.Log('CMDR', 'event stop', { event = id, by = context.Executor.UserId })
		return ('Ended event "%s" (cleanup complete; egg mutations kept).'):format(id)
	end
	if verb == 'start' then
		local id = _normalizeId(eventId)
		if id == nil then
			return 'Usage: /event start <Galaxy|Snowfall>. (Base/normal is not startable — stop the active event instead.)'
		end
		local ok, reason = EventService.StartEvent(id, 'admin')
		if ok then
			Debug.Log('CMDR', 'event start', { event = id, by = context.Executor.UserId })
			return ('Started event "%s".'):format(id)
		end
		return ('Could not start "%s": %s'):format(id, tostring(reason))
	end
	return 'Usage: /event <status|start <Galaxy|Snowfall>|stop>.'
end
