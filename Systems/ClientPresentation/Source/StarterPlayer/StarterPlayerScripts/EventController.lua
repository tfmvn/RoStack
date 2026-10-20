--!strict
--!native
--[[
	EventController
	=================
	Client presentation for the server-authoritative Event
	system. Label (shared CenterPartBillboards resolver — the
	Event BillboardGui sibling is found by its `Event` child
	marker, never positionally):
	  Map.CenterPart.BillboardGui.Event.TextLabel

	This is a DIFFERENT BillboardGui sibling from the Egg
	timer system (Map.CenterPart.BillboardGui.Egg.
	Mythic/Legendary, owned by EggTimerController). The two
	systems never share labels — an event countdown can never
	overwrite a guaranteed-egg timer and vice versa.

	Authority model (display-only client):
	  Server (EventService) publishes on ReplicatedStorage:
	    Event_CurrentId  (string, '' when none)
	    Event_EndAt      (absolute server timestamp)
	    Event_NextId     (string, '' when the next cycle is normal)
	    Event_NextAt     (absolute server timestamp)
	    Event_Revision   (bump guard)
	  ...only when they CHANGE (schedule, start, end). Zero
	  remote traffic, zero per-second pushes. Attributes
	  replicate + persist, so late joiners read current values.

	  This controller snapshots the attributes and repaints at
	  4Hz from the shared server clock:
	    remaining = max(0, target - workspace:GetServerTimeNow())

	States:
	  active special event -> "GALAXY EVENT ACTIVE"
	  upcoming special     -> "GALAXY EVENT IN 5:00"
	  normal cycle / none  -> "NORMAL" (never stale text)

	The client NEVER decides events, mutations, or time — it
	only renders. All Studio lookups are defensive and
	non-blocking: a missing CenterPart degrades to a warn + a
	ChildAdded re-try, never an error, never a boot block.
]]

local Workspace = game:GetService('Workspace')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local EventConfig = require(ReplicatedStorage.Config.World.Events)
local Debug = require(ReplicatedStorage.Utility.Debug)
local CenterPartBillboards = require(ReplicatedStorage.Utility.CenterPartBillboards)

local EventController = {}

local REPAINT_INTERVAL = 0.25

local _resolved = false
local _label: TextLabel? = nil
local _accum = 0
local _conn: RBXScriptConnection? = nil
local _warned: { [string]: boolean } = {}

local function _warnOnce(key: string, message: string)
	if _warned[key] then
		return
	end
	_warned[key] = true
	Debug.Warn('EV', message, {})
end

local function _displayName(eventId: string): string
	local name = eventId
	pcall(function()
		local events: any = EventConfig.Events
		local def: any = events and events[eventId] or nil
		if type(def) == 'table' and type(def.DisplayName) == 'string' and def.DisplayName ~= '' then
			name = def.DisplayName
		end
	end)
	return string.upper(name)
end

-- TEST seam: label text for (currentId, nextId, remaining).
function EventController._TestText(currentId: string, nextId: string, remaining: number): string
	if type(currentId) == 'string' and currentId ~= '' then
		return _displayName(currentId) .. ' EVENT ACTIVE'
	end
	if type(nextId) == 'string' and nextId ~= '' then
		return _displayName(nextId) .. ' EVENT IN ' .. EventController._TestFormatTime(remaining)
	end
	return _displayName('Base')
end

function EventController._TestFormatTime(totalSeconds: number): string
	local s = math.max(0, math.floor(totalSeconds or 0))
	return string.format('%d:%02d', math.floor(s / 60), s % 60)
end

local function _readState(): (string, number, string, number)
	local currentId = ''
	local endAt = 0
	local nextId = ''
	local nextAt = 0
	pcall(function()
		local v = ReplicatedStorage:GetAttribute('Event_CurrentId')
		if type(v) == 'string' then
			currentId = v
		end
		v = ReplicatedStorage:GetAttribute('Event_EndAt')
		if type(v) == 'number' then
			endAt = v
		end
		v = ReplicatedStorage:GetAttribute('Event_NextId')
		if type(v) == 'string' then
			nextId = v
		end
		v = ReplicatedStorage:GetAttribute('Event_NextAt')
		if type(v) == 'number' then
			nextAt = v
		end
	end)
	return currentId, endAt, nextId, nextAt
end

local function _repaint()
	if _label == nil then
		return
	end
	local serverNow: number? = nil
	pcall(function()
		serverNow = Workspace:GetServerTimeNow()
	end)
	if type(serverNow) ~= 'number' then
		serverNow = os.time()
	end
	local currentId, endAt, nextId, nextAt = _readState()
	local text: string
	if currentId ~= '' then
		text = EventController._TestText(currentId, '', math.max(0, endAt - (serverNow :: number)))
	elseif nextId ~= '' then
		text = EventController._TestText('', nextId, math.max(0, nextAt - (serverNow :: number)))
	else
		text = EventController._TestText('', '', 0)
	end
	pcall(function()
		local target = _label :: TextLabel
		if target.Parent ~= nil and target.Text ~= text then
			target.Text = text
		end
	end)
end

-- Resolve the Studio label once (non-blocking, spawned by
-- Init). The label comes from the shared CenterPartBillboards
-- resolver (Event BillboardGui sibling by `Event` child
-- marker). Missing nodes degrade to a warn + a ChildAdded
-- re-try — the countdown appears late rather than never.
local function _resolve(): boolean
	local map: Instance? = nil
	pcall(function()
		map = Workspace:WaitForChild('Map', 10)
	end)
	if map == nil then
		_warnOnce('no-map', '[Event] Workspace.Map missing; event countdown unavailable')
		return false
	end
	-- CenterPart first (the Event BillboardGui lives under
	-- it); the resolver itself never waits, so give streaming
	-- a bounded chance before retrying later.
	pcall(function()
		(map :: Instance):WaitForChild('CenterPart', 10)
	end)
	local label: TextLabel? = nil
	pcall(function()
		label = CenterPartBillboards.FindEventLabel(map)
	end)
	if label == nil then
		_warnOnce(
			'no-label',
			'[Event] Map.CenterPart.BillboardGui.Event.TextLabel missing; event countdown unavailable'
		)
		pcall(function()
			(map :: Instance).ChildAdded:Connect(function(child: Instance)
				if child.Name == 'CenterPart' and not _resolved then
					task.spawn(function()
						if _resolve() then
							_repaint()
						end
					end)
				end
			end)
		end)
		return false
	end
	_label = label
	_resolved = true
	return true
end

function EventController.Init()
	if _conn ~= nil then
		return
	end
	task.spawn(function()
		pcall(_resolve)
	end)
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < REPAINT_INTERVAL then
			return
		end
		_accum = 0
		pcall(_repaint)
	end)
	Debug.Log('EV', 'EventController started', {})
end

return EventController
