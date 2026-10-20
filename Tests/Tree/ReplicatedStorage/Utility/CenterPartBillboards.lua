--!strict
--!native
--[[
	CenterPartBillboards
	====================
	Single source of truth for the TWO independent BillboardGui
	systems under Map.CenterPart. They are same-named SIBLINGS
	and must NEVER be mixed:

	  Map.CenterPart
	  |-- BillboardGui          (EGG timer system)
	  |     `-- Egg
	  |         |-- Mythic      (guaranteed-egg timer label)
	  |         `-- Legendary   (guaranteed-egg timer label)
	  `-- BillboardGui          (EVENT countdown system)
	        `-- Event
	            `-- TextLabel   (upcoming/active event text)

	Because both BillboardGuis share one Name, callers must
	NEVER use FindFirstChild('BillboardGui') positionally —
	the winner would depend on replication order. Every lookup
	here disambiguates by CHILD MARKER (the gui containing an
	`Egg` child vs the gui containing an `Event` child), so
	sibling order, streaming order, and which system was
	authored first are all irrelevant.

	Consumers (all three resolve through here so the hierarchy
	knowledge exists exactly once):
	  * GuaranteeService (server)  -> egg timer attribute node
	  * EggTimerController (client) -> egg timer labels
	  * EventController (client)    -> event countdown label

	Legacy fallback (bare/dev places predating CenterPart):
	  Workspace.Map.EggTimer.BillboardGui.Frame. Only used
	  when CenterPart resolution fails; never created here.

	Pure lookups, no creation, no waiting, never throws (callers
	own their WaitForChild/retry policy for streaming).
]]

local CenterPartBillboards = {}

-- The BillboardGui under `centerPart` that contains a direct
-- child named `marker` (e.g. 'Egg' or 'Event'). Order-
-- independent: every same-named sibling is inspected. Returns
-- nil when CenterPart is missing or no sibling carries the
-- marker. Never throws.
function CenterPartBillboards.FindBillboardWithChild(centerPart: Instance?, marker: string): Instance?
	local found: Instance? = nil
	pcall(function()
		if typeof(centerPart) ~= 'Instance' then
			return
		end
		if type(marker) ~= 'string' or marker == '' then
			return
		end
		for _, child in ipairs((centerPart :: Instance):GetChildren()) do
			if child:IsA('BillboardGui') and child:FindFirstChild(marker) ~= nil then
				found = child
				break
			end
		end
	end)
	return found
end

-- Egg timer attribute/label container:
--   Map.CenterPart.BillboardGui.Egg   (primary)
--   Map.EggTimer.BillboardGui.Frame   (legacy fallback)
-- `map` is Workspace.Map (already resolved by the caller).
-- Never throws.
function CenterPartBillboards.FindEggTimerNode(map: Instance?): Instance?
	local node: Instance? = nil
	pcall(function()
		if typeof(map) ~= 'Instance' then
			return
		end
		local center = (map :: Instance):FindFirstChild('CenterPart')
		local gui = CenterPartBillboards.FindBillboardWithChild(center, 'Egg')
		if gui ~= nil then
			local egg = gui:FindFirstChild('Egg')
			if egg ~= nil then
				node = egg
				return
			end
		end
		local timer = (map :: Instance):FindFirstChild('EggTimer')
		local legacyGui = timer and timer:FindFirstChild('BillboardGui') or nil
		if legacyGui ~= nil then
			local frame = legacyGui:FindFirstChild('Frame')
			node = frame or legacyGui
		end
	end)
	return node
end

-- Event countdown label:
--   Map.CenterPart.BillboardGui.Event.TextLabel
-- No legacy fallback (the Event system is new; older places
-- simply show no countdown until Studio adds the gui).
-- Never throws.
function CenterPartBillboards.FindEventLabel(map: Instance?): TextLabel?
	local label: TextLabel? = nil
	pcall(function()
		if typeof(map) ~= 'Instance' then
			return
		end
		local center = (map :: Instance):FindFirstChild('CenterPart')
		local gui = CenterPartBillboards.FindBillboardWithChild(center, 'Event')
		local event = gui and gui:FindFirstChild('Event') or nil
		local node = event and event:FindFirstChild('TextLabel') or nil
		if node ~= nil and node:IsA('TextLabel') then
			label = node
		end
	end)
	return label
end

return table.freeze(CenterPartBillboards)
