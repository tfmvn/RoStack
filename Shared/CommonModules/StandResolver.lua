--!strict
--[[
	StandResolver
	=============
	The ONE central resolver for the MAIN GAME base/stand Studio
	hierarchy. Every service and controller that touches stands
	resolves paths through here instead of duplicating raw
	`FindFirstChild` chains.

	Authoritative Studio shape (Studio is the source of truth;
	nothing here creates, renames, or moves instances):

		Workspace.Map.Bases.Base_<n>
		├── Collector (BasePart)
		├── Spawn (BasePart)
		├── PlayerBoard
		│   └── Main
		│       └── SurfaceGui
		│           └── Frame
		│               ├── Name
		│               └── Avatar
		└── AnimalStands
		    └── Stand<k> (k = 1..8)
		        ├── Button
		        │   └── PressPart
		        │       └── SurfaceGui
		        │           └── Amount
		        └── Slot
		            ├── Root
		            └── MenuPart
		                └── MenuGui
		                    └── UpgradeButton
		                        ├── Level
		                        ├── UpgradeAmount
		                        └── UIStroke

	Mapping layer (spec §3): `Stand<k>` maps to the EXISTING
	internal slot identity with index `k`. Slot ids
	(`p7:<userId>:slot:<index>`) are persistence keys and are
	NEVER renamed because Studio calls the object a stand.

	All functions are pure instance-walking helpers: nil-safe,
	yield-free, no services, no remotes. Safe to require from
	server and client.
]]

local StandResolver = {}

-- --- Studio names -------------------------------------------------

StandResolver.Names = table.freeze({
	StandsFolder = 'AnimalStands',
	StandPrefix = 'Stand',
	Slot = 'Slot',
	Root = 'Root',
	MenuPart = 'MenuPart',
	MenuGui = 'MenuGui',
	UpgradeButton = 'UpgradeButton',
	LevelLabel = 'Level',
	CostLabel = 'UpgradeAmount',
	ButtonFolder = 'Button',
	PressPart = 'PressPart',
	-- MAIN GAME: the facing target for placed animals/eggs.
	-- Every animal/egg on a stand faces `Stand.Button.Base`
	-- (yaw-only, no tilt). When `Base` is absent (older
	-- Studio file), the facing falls back to `PressPart`.
	ButtonBase = 'Base',
	SurfaceGui = 'SurfaceGui',
	AmountLabel = 'Amount',
	PlayerBoard = 'PlayerBoard',
	-- Dynamic runtime slots: static placement markers. A
	-- `StandPos` folder holds `StandPos<k>` markers; runtime
	-- `Stand<k>` clones are positioned from them (see
	-- DynamicSlotService). Markers are never mutated.
	StandPosFolder = 'StandPos',
	StandPosPrefix = 'StandPos',
	-- Dynamic arena stands (mirrors the Slot system, fully
	-- separate scope): static `ArenaStandPos/ArenaStandPos<k>`
	-- markers position runtime `ArenaAnimalStands/ArenaStand<k>`
	-- clones. Arena clones NEVER register as Slots.
	ArenaStandsFolder = 'ArenaAnimalStands',
	ArenaStandPosFolder = 'ArenaStandPos',
	ArenaStandPrefix = 'ArenaStand',
	ArenaStandPosPrefix = 'ArenaStandPos',
	-- Legacy (pre-stand) names, kept for the bare-workspace
	-- fallback path only. Production Studio places use the
	-- names above.
	LegacySlotsFolder = 'Slots',
	LegacySlotPrefix = 'Slot',
	LegacyCashCollector = 'CashCollector',
	LegacyCollectorGui = 'CollectorGui',
	LegacyMoneyLabel = 'MoneyLabel',
})

-- --- Base container ------------------------------------------------

-- The authoritative base container is `Workspace.Map.Bases`.
-- The legacy top-level `Workspace.Bases` is accepted as a
-- fallback (bare test/dev workspaces) but NEVER created: if
-- neither exists the caller must fail loudly naming the
-- authoritative path. Centralized here so server discovery and
-- client discovery cannot drift apart.
function StandResolver.GetBasesFolder(workspace: Instance?): Instance?
	if typeof(workspace) ~= 'Instance' then
		return nil
	end
	local map = workspace:FindFirstChild('Map')
	local canonical = map and map:FindFirstChild('Bases') or nil
	if canonical then
		return canonical
	end
	return workspace:FindFirstChild('Bases')
end

-- --- Stand index ---------------------------------------------------

-- Parse `Stand<k>` -> k. Returns nil for anything else (so
-- `Standby`, `Standard`, ... never collide with real stands).
function StandResolver.ParseStandIndex(name: any): number?
	if type(name) ~= 'string' then
		return nil
	end
	local num = string.match(name, '^Stand(%d+)$')
	if not num then
		return nil
	end
	local index = tonumber(num)
	if not index or index < 1 or index ~= math.floor(index) then
		return nil
	end
	return index
end

-- All direct `Stand<k>` children of a base folder, sorted
-- NUMERICALLY (Stand10 sorts after Stand9, not after Stand1).
-- Returns an empty array when the folder is missing or holds no
-- stands — never errors, so callers can fall back cleanly.
function StandResolver.GetStandsSorted(baseFolder: Instance?): { Instance }
	local out: { Instance } = {}
	if typeof(baseFolder) ~= 'Instance' then
		return out
	end
	local container = baseFolder:FindFirstChild(StandResolver.Names.StandsFolder)
	if not container then
		return out
	end
	local indexed: { { index: number, stand: Instance } } = {}
	for _, child in ipairs(container:GetChildren()) do
		local index = StandResolver.ParseStandIndex(child.Name)
		if index ~= nil then
			indexed[#indexed + 1] = { index = index, stand = child }
		end
	end
	table.sort(indexed, function(a, b)
		return a.index < b.index
	end)
	for _, entry in ipairs(indexed) do
		out[#out + 1] = entry.stand
	end
	return out
end

-- The `Stand<k>` child whose index is `k`, or nil.
function StandResolver.GetStandByIndex(baseFolder: Instance?, index: number): Instance?
	if typeof(baseFolder) ~= 'Instance' or type(index) ~= 'number' then
		return nil
	end
	local container = baseFolder:FindFirstChild(StandResolver.Names.StandsFolder)
	if not container then
		return nil
	end
	return container:FindFirstChild(StandResolver.Names.StandPrefix .. tostring(index))
end

-- Parse `Slot<k>` -> k. Runtime dynamic clones live as
-- `AnimalStands/Slot<k>` (never inside the legacy `Slots/`
-- folder, whose `Slot<n>` parts are a different scope), so
-- this is only ever applied within an AnimalStands container.
function StandResolver.ParseSlotIndex(name: any): number?
	if type(name) ~= 'string' then
		return nil
	end
	local num = string.match(name, '^Slot(%d+)$')
	if not num then
		return nil
	end
	local index = tonumber(num)
	if not index or index < 1 or index ~= math.floor(index) then
		return nil
	end
	return index
end

-- Parse `ArenaStand<k>` -> k. Runtime arena clones live as
-- `ArenaAnimalStands/ArenaStand<k>` only.
function StandResolver.ParseArenaStandIndex(name: any): number?
	if type(name) ~= 'string' then
		return nil
	end
	local num = string.match(name, '^ArenaStand(%d+)$')
	if not num then
		return nil
	end
	local index = tonumber(num)
	if not index or index < 1 or index ~= math.floor(index) then
		return nil
	end
	return index
end

-- --- StandPos markers (dynamic runtime slots) --------------------------

-- Parse `StandPos<k>` -> k. Returns nil for anything else.
function StandResolver.ParseStandPosIndex(name: any): number?
	if type(name) ~= 'string' then
		return nil
	end
	local num = string.match(name, '^StandPos(%d+)$')
	if not num then
		return nil
	end
	local index = tonumber(num)
	if not index or index < 1 or index ~= math.floor(index) then
		return nil
	end
	return index
end

-- Parse `ArenaStandPos<k>` -> k. Returns nil for anything else.
function StandResolver.ParseArenaStandPosIndex(name: any): number?
	if type(name) ~= 'string' then
		return nil
	end
	local num = string.match(name, '^ArenaStandPos(%d+)$')
	if not num then
		return nil
	end
	local index = tonumber(num)
	if not index or index < 1 or index ~= math.floor(index) then
		return nil
	end
	return index
end

-- All direct `StandPos<k>` children of the base's `StandPos`
-- folder, sorted NUMERICALLY (StandPos10 after StandPos9).
-- Returns an empty array when the folder is missing or holds
-- no markers — never errors, so callers fall back cleanly.
function StandResolver.GetStandPosSorted(baseFolder: Instance?): { Instance }
	local out: { Instance } = {}
	if typeof(baseFolder) ~= 'Instance' then
		return out
	end
	local container = baseFolder:FindFirstChild(StandResolver.Names.StandPosFolder)
	if not container then
		return out
	end
	local indexed: { { index: number, node: Instance } } = {}
	for _, child in ipairs(container:GetChildren()) do
		local index = StandResolver.ParseStandPosIndex(child.Name)
		if index ~= nil then
			indexed[#indexed + 1] = { index = index, node = child }
		end
	end
	table.sort(indexed, function(a, b)
		return a.index < b.index
	end)
	for _, entry in ipairs(indexed) do
		out[#out + 1] = entry.node
	end
	return out
end

-- All direct `ArenaStandPos<k>` children of the base's
-- `ArenaStandPos` folder, sorted NUMERICALLY. Empty when the
-- folder is missing — never errors.
function StandResolver.GetArenaStandPosSorted(baseFolder: Instance?): { Instance }
	local out: { Instance } = {}
	if typeof(baseFolder) ~= 'Instance' then
		return out
	end
	local container = baseFolder:FindFirstChild(StandResolver.Names.ArenaStandPosFolder)
	if not container then
		return out
	end
	local indexed: { { index: number, node: Instance } } = {}
	for _, child in ipairs(container:GetChildren()) do
		local index = StandResolver.ParseArenaStandPosIndex(child.Name)
		if index ~= nil then
			indexed[#indexed + 1] = { index = index, node = child }
		end
	end
	table.sort(indexed, function(a, b)
		return a.index < b.index
	end)
	for _, entry in ipairs(indexed) do
		out[#out + 1] = entry.node
	end
	return out
end

-- --- Per-stand parts ------------------------------------------------

export type StandParts = {
	stand: Instance,
	slot: Instance?,
	root: BasePart?,
	menuPart: Instance?,
	menuGui: Instance?,
	upgradeButton: Instance?,
	levelLabel: TextLabel?,
	costLabel: TextLabel?,
	pressPart: BasePart?,
	surfaceGui: Instance?,
	amountLabel: TextLabel?,
}

local function _asBasePart(node: Instance?): BasePart?
	if node ~= nil and node:IsA('BasePart') then
		return node
	end
	return nil
end

local function _asTextLabel(node: Instance?): TextLabel?
	if node ~= nil and node:IsA('TextLabel') then
		return node
	end
	return nil
end

-- Resolve every known part under one stand. Every field except
-- `stand` is nil-able: a partially-built stand resolves to
-- what's there instead of erroring, and the callers degrade to
-- display-less / trigger-less behavior with a warn.
--
-- `root` falls back to `Slot` itself when `Slot` is a BasePart
-- but `Root` is missing (keeps a misbuilt Studio file limping
-- instead of crashing placement math). Nothing is created.
function StandResolver.GetStandParts(stand: Instance): StandParts
	local names = StandResolver.Names
	local slot = stand:FindFirstChild(names.Slot)
	if slot == nil then
		-- Flat-template fallback: the node itself is the slot
		-- (a runtime clone whose root carries MenuPart/Root
		-- directly instead of nesting them under a `Slot`
		-- child). Only applies when no `Slot` child exists,
		-- so authored Stand<k> hierarchies resolve exactly as
		-- before.
		local directMenu = stand:FindFirstChild(names.MenuPart, true)
		local directRoot = stand:FindFirstChild(names.Root)
		if directMenu ~= nil or (directRoot ~= nil and directRoot:IsA('BasePart')) or stand:IsA('BasePart') then
			slot = stand
		end
	end
	local rootNode = slot and slot:FindFirstChild(names.Root) or nil
	local root = _asBasePart(rootNode)
	if not root and slot ~= nil and slot:IsA('BasePart') then
		root = slot
	end
	local menuPart = slot and slot:FindFirstChild(names.MenuPart, true) or nil
	local menuGui = menuPart and menuPart:FindFirstChild(names.MenuGui, true) or nil
	-- New shape: UpgradeButton directly under MenuGui. Legacy
	-- shape (Frame intermediary) is also accepted so old places
	-- keep their sell/upgrade menus.
	local upgradeButton = menuGui and menuGui:FindFirstChild(names.UpgradeButton, true) or nil
	local levelLabel = upgradeButton and _asTextLabel(upgradeButton:FindFirstChild(names.LevelLabel))
	local costLabel = upgradeButton and _asTextLabel(upgradeButton:FindFirstChild(names.CostLabel))
	local buttonFolder = stand:FindFirstChild(names.ButtonFolder)
	local pressPart = _asBasePart(buttonFolder and buttonFolder:FindFirstChild(names.PressPart))
	local surfaceGui = pressPart and pressPart:FindFirstChild(names.SurfaceGui) or nil
	local amountLabel = surfaceGui and _asTextLabel(surfaceGui:FindFirstChild(names.AmountLabel))
	return {
		stand = stand,
		slot = slot,
		root = root,
		menuPart = menuPart,
		menuGui = menuGui,
		upgradeButton = upgradeButton,
		levelLabel = levelLabel,
		costLabel = costLabel,
		pressPart = pressPart,
		surfaceGui = surfaceGui,
		amountLabel = amountLabel,
	}
end

-- --- Facing (animals/eggs look at the stand button) -------------------

-- Resolve the stand's cash-collection button parts: the static
-- `Base` and the animated `PressPart` under `Stand.Button`.
-- Both nil-able; collection feedback (button press) needs the
-- pair, so callers skip the press when either is missing
-- instead of guessing a transform. Pure instance-walking:
-- nil-safe, yield-free. Safe to call from server and client.
function StandResolver.GetButtonParts(stand: Instance?): { base: BasePart?, pressPart: BasePart? }
	local empty: { base: BasePart?, pressPart: BasePart? } = { base = nil, pressPart = nil }
	if typeof(stand) ~= 'Instance' then
		return empty
	end
	local names = StandResolver.Names
	local buttonFolder = stand:FindFirstChild(names.ButtonFolder)
	if buttonFolder == nil then
		return empty
	end
	return {
		base = _asBasePart(buttonFolder:FindFirstChild(names.ButtonBase)),
		pressPart = _asBasePart(buttonFolder:FindFirstChild(names.PressPart)),
	}
end

-- Resolve the part a placed animal/egg should face: the
-- authoritative `Stand.Button.Base`, falling back to
-- `Stand.Button.PressPart` when `Base` is absent (older
-- Studio file). Returns nil when neither resolves (caller
-- keeps the slot's own rotation).
--
-- Pure instance-walking: nil-safe, yield-free. Safe to call
-- from server and client.
function StandResolver.GetStandFacingTarget(stand: Instance?): BasePart?
	if typeof(stand) ~= 'Instance' then
		return nil
	end
	local names = StandResolver.Names
	local buttonFolder = stand:FindFirstChild(names.ButtonFolder)
	if buttonFolder == nil then
		return nil
	end
	local base = _asBasePart(buttonFolder:FindFirstChild(names.ButtonBase))
	if base ~= nil then
		return base
	end
	return _asBasePart(buttonFolder:FindFirstChild(names.PressPart))
end

-- Yaw-only CFrame at `fromPos` whose forward (-Z, the
-- `LookVector` that R15-style rigs face along) points
-- horizontally at `targetPos`. The Y difference is ignored
-- so models never tilt up/down toward the button.
-- Returns nil when the two positions coincide horizontally
-- (no facing can be derived; caller keeps its fallback).
function StandResolver.YawFacingCFrame(fromPos: Vector3, targetPos: Vector3): CFrame?
	local flat = Vector3.new(targetPos.X - fromPos.X, 0, targetPos.Z - fromPos.Z)
	if flat.Magnitude < 0.001 then
		return nil
	end
	return CFrame.lookAt(fromPos, fromPos + flat)
end

-- The rotation-only CFrame a model placed on `slot` should
-- use: yaw facing from the slot's XZ toward the stand's
-- button base. Falls back to the slot part's own rotation
-- (the Collector-facing Yaw) when the stand/button cannot
-- be resolved — legacy `Slots` workspaces, tests, and
-- partially-built stands keep their previous behavior.
function StandResolver.GetSlotFacingRotation(slot: any): CFrame
	local part = slot and slot.part
	local fallback = CFrame.new()
	if part ~= nil and typeof(part) == 'Instance' and (part :: Instance):IsA('BasePart') then
		local slotCFrame = (part :: BasePart).CFrame
		fallback = slotCFrame - slotCFrame.Position
	end
	local stand = slot and slot.stand
	local target = StandResolver.GetStandFacingTarget(stand)
	if target == nil or part == nil then
		return fallback
	end
	local fromPos = (part :: BasePart).Position
	local facing = StandResolver.YawFacingCFrame(fromPos, (target :: BasePart).Position)
	if facing == nil then
		return fallback
	end
	return facing - facing.Position
end

-- --- Client helper: collector part for a menu button ----------------

-- From a pressed menu button, climb to the owning stand and
-- return its cash trigger part (`Button.PressPart`). Legacy
-- fallback: the `CashCollector` sibling of the `MenuPart`
-- container. Returns nil when neither resolves (caller treats
-- it as "pool watch unavailable").
function StandResolver.FindCollectorForMenuButton(button: Instance): BasePart?
	local names = StandResolver.Names
	local node: Instance? = button
	local menuPart: Instance? = nil
	local depth = 0
	while node ~= nil and depth < 8 do
		if node.Name == names.MenuPart then
			menuPart = node
			break
		end
		node = node.Parent
		depth += 1
	end
	if menuPart ~= nil then
		-- New shape: MenuPart -> Slot -> Stand -> Button/PressPart.
		local slotNode = menuPart.Parent
		local standNode = slotNode and slotNode.Parent or nil
		if standNode ~= nil then
			local buttonFolder = standNode:FindFirstChild(names.ButtonFolder)
			local pressPart = _asBasePart(buttonFolder and buttonFolder:FindFirstChild(names.PressPart))
			if pressPart ~= nil then
				return pressPart
			end
		end
		-- Legacy shape: CashCollector sibling of the MenuPart
		-- container.
		local container = menuPart.Parent
		if container ~= nil then
			local legacy = _asBasePart(container:FindFirstChild(names.LegacyCashCollector))
			if legacy ~= nil then
				return legacy
			end
		end
	end
	return nil
end

-- --- PlayerBoard -----------------------------------------------------

export type PlayerBoardParts = {
	board: Instance?,
	frame: Instance?,
	nameLabel: TextLabel?,
	avatarImage: ImageLabel?,
}

-- Resolve `PlayerBoard.Main.SurfaceGui.Frame` + its `Name` /
-- `Avatar` children. All nil-able; the board is display-only so
-- a missing piece degrades to a skipped write, never an error.
function StandResolver.GetPlayerBoardParts(baseFolder: Instance?): PlayerBoardParts
	local empty: PlayerBoardParts = { board = nil, frame = nil, nameLabel = nil, avatarImage = nil }
	if typeof(baseFolder) ~= 'Instance' then
		return empty
	end
	local board = baseFolder:FindFirstChild(StandResolver.Names.PlayerBoard)
	if not board then
		return empty
	end
	local main = board:FindFirstChild('Main')
	local surfaceGui = main and main:FindFirstChild(StandResolver.Names.SurfaceGui) or nil
	local frame = surfaceGui and surfaceGui:FindFirstChild('Frame') or nil
	local nameLabel = frame and _asTextLabel(frame:FindFirstChild('Name')) or nil
	local avatarNode = frame and frame:FindFirstChild('Avatar') or nil
	local avatarImage: ImageLabel? = nil
	if avatarNode ~= nil and avatarNode:IsA('ImageLabel') then
		avatarImage = avatarNode
	end
	return {
		board = board,
		frame = frame,
		nameLabel = nameLabel,
		avatarImage = avatarImage,
	}
end

return table.freeze(StandResolver)
