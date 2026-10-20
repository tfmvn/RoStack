--!strict
--!native
--[[
	HUDController
	=============
	Top-left HUD showing the player's money, base, and a single
	unified 6-slot list (Phase 2). Each row branches on
	OccupantKind: lucky egg / animal / empty / reserved.

	Reactive UI via direct instance mutation (no Fusion). The
	controller exposes a tiny imperative API (SetMoney, SetBase,
	SetPlayerState, SetSlotAnimal, SetSlotEgg) that the
	client bootstrap wires to remote events.

	Phase 2.1: `cash` is replaced by `money` (string). The HUD
	formats the canonical BigNumber string on the client with
	`BigNumber.Format`, which is the only place `tonumber()`
	touches money — display-only, never authoritative.
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local StarterGui = game:GetService('StarterGui')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local UIConfig = require(ReplicatedStorage.Config.Presentation.UI)
local Bases = require(ReplicatedStorage.Config.World.Bases)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)

local HUDController = {}

local screenGui: ScreenGui? = nil
local cashLabel: TextLabel? = nil
local baseLabel: TextLabel? = nil
local carryLabel: TextLabel? = nil
local slotList: Frame? = nil

-- Phase 2: single 6-slot pool. slotRows[i] is the row Frame for
-- the slot at index i (1..SlotCount). Rows are built in Init and mutated
-- in place by SetPlayerState.
local slotRows: { Frame } = {}

-- Cache of occupant display name + rarity per slot id. Animal
-- rows resolve a name + rarity from the cache; lucky egg rows
-- resolve just a rarity.
local slotNames: { [string]: string } = {}
local slotRarities: { [string]: string } = {}

-- --- Slot row builder -------------------------------------------

local function buildSlotRow(idx: number, parent: Instance): Frame
	local row = Instance.new('Frame')
	row.Name = 'Slot' .. tostring(idx)
	row.Size = UDim2.fromOffset(UIConfig.SlotRow.Width, UIConfig.SlotRow.Height)
	row.BackgroundColor3 = UIConfig.Color.Panel
	row.BorderSizePixel = 0
	row.LayoutOrder = idx
	row.Parent = parent

	local label = Instance.new('TextLabel')
	label.Name = 'Label'
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.fromOffset(8, 0)
	label.BackgroundTransparency = 1
	label.TextColor3 = UIConfig.Color.TextMuted
	label.Font = UIConfig.Font.Body
	label.TextSize = UIConfig.TextSize.Body
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = '[S' .. tostring(idx) .. '] Empty'
	label.Parent = row

	local stroke = Instance.new('UIStroke')
	stroke.Color = UIConfig.Color.PanelBorder
	stroke.Thickness = 1
	stroke.Parent = row

	return row
end

local function setSlotRow(row: Frame, text: string, color: Color3?)
	local label = row:FindFirstChild('Label')
	if label and label:IsA('TextLabel') then
		(label :: TextLabel).Text = text
	end
	if color then
		(label :: TextLabel).TextColor3 = color
	else
		(label :: TextLabel).TextColor3 = UIConfig.Color.TextMuted
	end
end

-- Render a single slot's state into its row. Dispatches on
-- OccupantKind so the row text matches what the player sees on
-- the slot in-world.
local function renderSlot(idx: number, s: any?)
	local row = slotRows[idx]
	if not row then
		return
	end
	if not s or s.State == 'Empty' then
		setSlotRow(row, '[S' .. tostring(idx) .. '] Empty')
		return
	end
	if s.State == 'Reserved' then
		-- Phase 2: a Reserved slot is either a carry reservation
		-- (the player is carrying whatever used to live there) or
		-- an in-flight purchase / open. From the HUD's perspective
		-- both look the same: "this slot is held, not yet placed".
		setSlotRow(row, '[S' .. tostring(idx) .. '] Reserving...', UIConfig.Color.Warning)
		return
	end
	-- State == 'Occupied'
	local kind = s.OccupantKind
	if kind == 'egg' then
		local rarity = s.OccupantId and slotRarities[s.OccupantId]
		if rarity then
			setSlotRow(
				row,
				'[S' .. tostring(idx) .. '] Egg - ' .. rarity,
				RarityConfig.RarityColor[rarity] or UIConfig.Color.Accent
			)
		else
			setSlotRow(row, '[S' .. tostring(idx) .. '] Egg - placed', UIConfig.Color.Accent)
		end
		return
	elseif kind == 'animal' then
		local id = s.OccupantId
		local name = id and slotNames[id]
		local rarity = id and slotRarities[id]
		if name and rarity then
			setSlotRow(
				row,
				'[S' .. tostring(idx) .. '] ' .. name,
				RarityConfig.RarityColor[rarity] or UIConfig.Color.Text
			)
		elseif name then
			setSlotRow(row, '[S' .. tostring(idx) .. '] ' .. name, UIConfig.Color.Text)
		else
			setSlotRow(row, '[S' .. tostring(idx) .. '] Animal - placed', UIConfig.Color.Success)
		end
		return
	end
	setSlotRow(row, '[S' .. tostring(idx) .. '] Occupied', UIConfig.Color.Success)
end

-- --- Public API -------------------------------------------------

function HUDController.Init()
	if screenGui then
		return
	end
	local gui = Instance.new('ScreenGui')
	gui.Name = 'AnimalHUD'
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = StarterGui
	screenGui = gui

	local root = Instance.new('Frame')
	root.Name = 'Root'
	root.AnchorPoint = Vector2.new(0, 0)
	root.Position = UIConfig.HUD.Position
	root.Size = UIConfig.HUD.Size
	root.BackgroundColor3 = UIConfig.Color.Background
	root.BorderSizePixel = 0
	root.Parent = gui

	local layout = Instance.new('UIListLayout')
	layout.Padding = UDim.new(0, UIConfig.HUD.Padding)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.Parent = root

	local stroke = Instance.new('UIStroke')
	stroke.Color = UIConfig.Color.PanelBorder
	stroke.Thickness = 1
	stroke.Parent = root

	cashLabel = Instance.new('TextLabel')
	cashLabel.Name = 'Cash'
	cashLabel.Size = UDim2.new(1, 0, 0, UIConfig.TextSize.H1 + 8)
	cashLabel.BackgroundTransparency = 1
	cashLabel.TextColor3 = UIConfig.Color.Accent
	cashLabel.Font = UIConfig.Font.Heading
	cashLabel.TextSize = UIConfig.TextSize.H1
	cashLabel.TextXAlignment = Enum.TextXAlignment.Left
	cashLabel.Text = '$0'
	cashLabel.LayoutOrder = 1
	cashLabel.Parent = root

	baseLabel = Instance.new('TextLabel')
	baseLabel.Name = 'Base'
	baseLabel.Size = UDim2.new(1, 0, 0, UIConfig.TextSize.Body + 4)
	baseLabel.BackgroundTransparency = 1
	baseLabel.TextColor3 = UIConfig.Color.Text
	baseLabel.Font = UIConfig.Font.Body
	baseLabel.TextSize = UIConfig.TextSize.Body
	baseLabel.TextXAlignment = Enum.TextXAlignment.Left
	baseLabel.Text = 'Base: -'
	baseLabel.LayoutOrder = 2
	baseLabel.Parent = root

	-- Phase 2: a single line at the top of the HUD that surfaces
	-- what the player is currently carrying. Hidden when empty.
	carryLabel = Instance.new('TextLabel')
	carryLabel.Name = 'Carrying'
	carryLabel.Size = UDim2.new(1, 0, 0, UIConfig.TextSize.Body + 2)
	carryLabel.BackgroundTransparency = 1
	carryLabel.TextColor3 = UIConfig.Color.Warning
	carryLabel.Font = UIConfig.Font.Heading
	carryLabel.TextSize = UIConfig.TextSize.Body
	carryLabel.TextXAlignment = Enum.TextXAlignment.Left
	carryLabel.Text = ''
	carryLabel.LayoutOrder = 3
	carryLabel.Visible = false
	carryLabel.Parent = root

	local slotsHeader = Instance.new('TextLabel')
	slotsHeader.Name = 'SlotsHeader'
	slotsHeader.Size = UDim2.new(1, 0, 0, UIConfig.TextSize.Body + 2)
	slotsHeader.BackgroundTransparency = 1
	slotsHeader.TextColor3 = UIConfig.Color.TextMuted
	slotsHeader.Font = UIConfig.Font.Heading
	slotsHeader.TextSize = UIConfig.TextSize.Body
	slotsHeader.TextXAlignment = Enum.TextXAlignment.Left
	slotsHeader.Text = 'Slots (' .. tostring(Bases.Slots.Count) .. ')'
	slotsHeader.LayoutOrder = 4
	slotsHeader.Parent = root

	-- Phase 2: a single SlotCount-row list. The previous version had two
	-- separate lists (3 lucky + 6 animal); unified pool means
	-- one list, one loop in SetPlayerState.
	slotList = Instance.new('Frame')
	slotList.Name = 'SlotList'
	slotList.Size = UDim2.fromScale(1, 0)
	slotList.BackgroundTransparency = 1
	slotList.LayoutOrder = 5
	slotList.AutomaticSize = Enum.AutomaticSize.Y
	slotList.Parent = root
	local slotsLayout = Instance.new('UIListLayout')
	slotsLayout.Padding = UDim.new(0, UIConfig.SlotRow.Gap)
	slotsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	slotsLayout.Parent = slotList

	for i = 1, Bases.Slots.Count do
		slotRows[i] = buildSlotRow(i, slotList)
	end

	Remotes.OnClientEvent(Remotes.Names.PlayerState):Connect(function(payload: any)
		HUDController.SetPlayerState(payload)
	end)
end

-- Last money value painted (diagnostic only): SetMoney runs
-- on every PlayerState push (slots included), so the change
-- log below stays silent unless the balance actually moved.
local lastMoneyPainted: string? = nil

function HUDController.SetMoney(money: string)
	if cashLabel then
		-- Phase 2.1: `money` is the canonical BigNumber
		-- string from the server. Format on the client;
		-- this is the only place `tonumber()` touches
		-- the value, and only for display. Defensive
		-- default to "0" if the wire field is missing
		-- (e.g. an older remote replay).
		local safe = if type(money) == 'string' and money ~= '' then money else '0'
		(cashLabel :: TextLabel).Text = '$' .. BigNumber.Format(safe)
		if safe ~= lastMoneyPainted then
						Debug.Log('MoneySync', ('HUD updated old=%s new=%s'):format(tostring(lastMoneyPainted), safe))
			lastMoneyPainted = safe
		end
	end
end

function HUDController.SetBase(baseId: string?)
	if baseLabel then
		(baseLabel :: TextLabel).Text = 'Base: ' .. (baseId or '-')
	end
end

function HUDController.SetPlayerState(payload: any)
	if not payload then
		return
	end
	HUDController.SetMoney(payload.Money or '0')
	HUDController.SetBase(payload.BaseId)

	-- Carry line. Phase 2: payload carries CarriedKind (string
	-- or nil) + CarriedName (display name or nil). The render
	-- prefixes the kind so the player sees what type of object
	-- they are holding.
	if carryLabel then
		if payload.CarriedKind and payload.CarriedName then
			local kindTag
			if payload.CarriedKind == 'animal' then
				kindTag = 'Animal'
			elseif payload.CarriedKind == 'egg' then
				kindTag = 'Egg'
			else
				kindTag = 'Item'
			end
			(carryLabel :: TextLabel).Text = 'Carrying: ' .. tostring(payload.CarriedName) .. ' (' .. kindTag .. ')'
			(carryLabel :: TextLabel).Visible = true
		else
			(carryLabel :: TextLabel).Text = ''
			(carryLabel :: TextLabel).Visible = false
		end
	end

	-- Phase 2: single Slots[1..SlotCount] array. Index by 1..SlotCount.
	-- Anything past the end of the array renders as Empty.
	if slotList then
		local slots = payload.Slots or {}
		for i = 1, Bases.Slots.Count do
			renderSlot(i, slots[i])
		end
	end
end

-- Public hooks for other client modules to update the per-slot
-- display name + rarity cache. SetSlotAnimal is fired on
-- AnimalArrived; SetSlotEgg fires on EggArrived.
function HUDController.SetSlotAnimal(slotId: string, displayName: string, rarity: string)
	slotNames[slotId] = displayName
	slotRarities[slotId] = rarity
end

function HUDController.SetSlotEgg(slotId: string, rarity: string)
	slotRarities[slotId] = rarity
end

return table.freeze(HUDController)
