--!strict
--!native
--[[
	GearShopController
	====================
	Client presentation for the server-authoritative Gear Shop.

	Architecture (instant open, no rebuild churn):
	  * Rows are built ONCE from the static GearConfig
	    (ReplicatedStorage, client-readable) plus the
	    server-provisioned runtime GearTemplate — no server
	    round trip needed to construct the UI.
	  * GearShopState snapshots PATCH existing rows (price /
	    lock / owned / AutoBuy visuals). Full rebuild happens
	    only if the gear id set itself changes.
	  * Opening is local and instant: the client connects to
	    the shop ProximityPrompt's Triggered and shows the GUI
	    immediately; the server's authoritative push (same
	    interaction) reconciles contents a moment later.
	  * The client never reads ServerStorage (server-only).
	    Tool previews come from ReplicatedStorage.GearShopPreviews.

	Server owns: prices, locks, ownership, AutoBuy, money.
	This file only displays + forwards { Action, GearId }.
	Close is purely local (Visible = false).
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace = game:GetService('Workspace')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local MenuPresentation = require(script.Parent.MenuPresentation)

local GearShopController = {}

local PREVIEW_FOLDER_NAME = 'GearShopPreviews'

local actionRemote: RemoteEvent? = nil
local connectedGui: GuiObject? = nil
local promptConnected = false
local toolTraceWired = false
local lastOwnedTrace: { [string]: boolean } = {}

type RowRefs = {
	row: GuiObject,
	buyButton: GuiButton?,
	priceLabel: TextLabel?,
	lockOverlay: GuiObject?,
	rebirthLabel: TextLabel?,
	autoImage: GuiObject?,
	autoOn: GuiObject?,
	autoOff: GuiObject?,
	viewport: ViewportFrame?,
	viewportFilled: boolean,
}

local rows: { [string]: RowRefs } = {}

local function warnUi(message: string)
	Debug.Warn('GearShop', message)
end

local function resolveGui(): Instance?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end
	local ok, gui = pcall(function()
		return player:FindFirstChildOfClass('PlayerGui')
	end)
	if not ok or gui == nil then
		return nil
	end
	return (gui :: PlayerGui):FindFirstChild('GearShop', true)
end

local function resolveScrolling(gui: Instance): Instance?
	local scrolling = gui:FindFirstChild('ScrollingFrame', true)
	return scrolling
end

local function clearRows(scrolling: Instance)
	for _, child in ipairs(scrolling:GetChildren()) do
		-- Rows always carry a GearId attribute; the runtime
		-- GearTemplate prototype must survive rebuilds (name
		-- guard covers any attribute-less straggler).
		if child.Name ~= 'GearTemplate' and child:GetAttribute('GearId') ~= nil then
			child:Destroy()
		end
	end
	for key in pairs(rows) do
		rows[key] = nil
	end
end

local function formatStaticPrice(price: string): string
	local ok, text = pcall(BigNumber.Format, price)
	if ok and type(text) == 'string' then
		return '$' .. text
	end
	return '$' .. tostring(price)
end

local function clearViewport(viewport: ViewportFrame)
	for _, child in ipairs(viewport:GetChildren()) do
		if child:IsA('Camera') or child:IsA('Model') or child:IsA('WorldModel') then
			child:Destroy()
		end
	end
end

local function fitViewport(viewport: ViewportFrame, model: Model)
	local ok, err = pcall(function()
		clearViewport(viewport)
		local world = Instance.new('WorldModel')
		world.Parent = viewport
		model.Parent = world
		local cf, size = model:GetBoundingBox()
		local camera = Instance.new('Camera')
		camera.Parent = viewport
		viewport.CurrentCamera = camera
		local dist = math.max(size.Magnitude * GearConfig.Viewport.DistanceFactor, GearConfig.Viewport.MinDistance)
		local dir = GearConfig.Viewport.Direction.Unit
		camera.CFrame = CFrame.lookAt(cf.Position + dir * dist, cf.Position)
	end)
	if not ok then
		warnUi('Viewport fit failed: ' .. tostring(err))
	end
end

local function buildPreview(gearId: string): Model?
	local ok, model = pcall(function()
		local folder = ReplicatedStorage:FindFirstChild(PREVIEW_FOLDER_NAME)
		local shell = folder and folder:FindFirstChild(gearId) or nil
		if shell == nil then
			return nil
		end
		return (shell :: Model):Clone()
	end)
	if ok and typeof(model) == 'Instance' and (model :: Instance):IsA('Model') then
		return model
	end
	return nil
end

local function sendAction(gearId: string, action: string, enabled: boolean?)
	if actionRemote == nil then
		return
	end
	pcall(function()
		(actionRemote :: RemoteEvent):FireServer({
			Action = action,
			GearId = gearId,
			Enabled = enabled,
		})
	end)
end

-- AutoBuy is an IMAGE whose visibility is the whole state.
-- The authored GearTemplate names are Studio-side, so
-- resolve robustly: prefer an exact AutoBuyImage, then the
-- legacy Toggle_ON single-image, then any ImageLabel /
-- ImageButton under the AutoBuy node. Logs the exact path
-- + class once per row. Never creates or swaps images.
local function resolveAutoBuyImage(autoBuyNode: Instance, gearId: string): GuiObject?
	local found: GuiObject? = nil
	local ok = pcall(function()
		local exact = autoBuyNode:FindFirstChild('AutoBuyImage', true)
		if exact and exact:IsA('GuiObject') then
			found = exact
		end
		if found == nil then
			local onNode = autoBuyNode:FindFirstChild('Toggle_ON', true)
			if onNode and onNode:IsA('GuiObject') then
				found = onNode
			end
		end
		if found == nil then
			for _, desc in ipairs(autoBuyNode:GetDescendants()) do
				if desc:IsA('ImageLabel') or desc:IsA('ImageButton') then
					found = desc :: GuiObject
					break
				end
			end
		end
		if found == nil and autoBuyNode:IsA('GuiObject') then
			-- Last resort: the AutoBuy node itself is the image.
			if autoBuyNode:IsA('ImageLabel') or autoBuyNode:IsA('ImageButton') then
				found = autoBuyNode :: GuiObject
			end
		end
	end)
	if not ok then
		return nil
	end
	if found ~= nil then
		warnUi(
			('[AutoBuyUI] GearId=%s image path=%s class=%s'):format(
				tostring(gearId),
				(found :: Instance):GetFullName(),
				(found :: Instance).ClassName
			)
		)
	else
		warnUi('[AutoBuyUI] GearId=' .. tostring(gearId) .. ' no AutoBuy image found under AutoBuy node')
	end
	return found
end

-- Centralized AutoBuy visual: Visible only. OFF -> false,
-- ON -> true. Legacy Toggle_ON/OFF pairs (if both exist)
-- are kept in sync so older authored templates keep
-- working; the single image is authoritative.
local function applyAutoBuyVisual(refs: RowRefs, enabled: boolean)
	local show = enabled == true
	if refs.autoImage then
		refs.autoImage.Visible = show
	end
	if refs.autoOn then
		refs.autoOn.Visible = show
	end
	if refs.autoOff then
		refs.autoOff.Visible = not show
	end
end

-- --- Post-grant Tool lifecycle trace (temporary diagnostics) ----
-- READ-ONLY: never touches Backpack/Character/Tools. Verifies
-- whether the client replicates what the server granted.
-- Event-driven (Backpack ChildAdded/ChildRemoved filtered to
-- gear ToolNames, CharacterAdded, Purchase-result) plus one
-- snapshot per false->true Owned transition. No polling.
local function traceBackpackState(reason: string)
	pcall(function()
		local player = Players.LocalPlayer
		if not player then
			warnUi('[ToolTrace][CLIENT] reason=' .. tostring(reason) .. ' localPlayer=missing')
			return
		end
		-- Hotbar proof (read-only): the default Backpack CoreGui
		-- is the only equip path in this project. If it is
		-- disabled, a replicated Tool is present yet invisible
		-- and unequippable.
		local hotbar = 'unknown'
		pcall(function()
			hotbar = tostring(game:GetService('StarterGui'):GetCoreGuiEnabled(Enum.CoreGuiType.Backpack))
		end)
		warnUi('[ToolTrace][CLIENT] reason=' .. tostring(reason) .. ' hotbarBackpackEnabled=' .. hotbar)
		local backpack = player:FindFirstChildOfClass('Backpack')
		if backpack == nil then
			warnUi('[ToolTrace][CLIENT] reason=' .. tostring(reason) .. ' backpack=missing')
			return
		end
		for _, entry in ipairs(GearConfig.GetAll()) do
			local found = (backpack :: Backpack):FindFirstChild(entry.ToolName)
			local character = player.Character
			local equipped = character and character:FindFirstChild(entry.ToolName) or nil
			warnUi(
				('[ToolTrace][CLIENT] reason=%s gearId=%s backpackFound=%s equipped=%s class=%s parent=%s'):format(
					tostring(reason),
					entry.Id,
					tostring(found ~= nil),
					tostring(equipped ~= nil),
					if found ~= nil then (found :: Instance).ClassName else 'nil',
					if found ~= nil
						then (found :: Instance):GetFullName()
						elseif equipped ~= nil then (equipped :: Instance):GetFullName()
						else 'nil'
				)
			)
		end
	end)
end

local function wireToolTrace()
	if toolTraceWired then
		return
	end
	toolTraceWired = true
	pcall(function()
		local player = Players.LocalPlayer
		if not player then
			return
		end
		local names: { [string]: string } = {}
		for _, entry in ipairs(GearConfig.GetAll()) do
			names[entry.ToolName] = entry.Id
		end
		local backpack = player:FindFirstChildOfClass('Backpack')
		if backpack ~= nil then
			(backpack :: Backpack).ChildAdded:Connect(function(child: Instance)
				if names[child.Name] ~= nil then
					warnUi(
						('[ToolTrace][CLIENT] Backpack.ChildAdded gearId=%s tool=%s class=%s'):format(
							names[child.Name],
							child.Name,
							child.ClassName
						)
					)
				end
			end);
			(backpack :: Backpack).ChildRemoved:Connect(function(child: Instance)
				if names[child.Name] ~= nil then
					warnUi(
						('[ToolTrace][CLIENT] Backpack.ChildRemoved gearId=%s tool=%s class=%s'):format(
							names[child.Name],
							child.Name,
							child.ClassName
						)
					)
				end
			end)
		end
		player.CharacterAdded:Connect(function()
			traceBackpackState('character-added')
		end)
	end)
end

local function onPurchaseResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	if payload.Action == 'Purchase' and payload.Success == true then
		traceBackpackState('purchase-success:' .. tostring(payload.GearId))
	end
end

local function fillViewport(refs: RowRefs, gearId: string)
	if refs.viewportFilled or refs.viewport == nil then
		return
	end
	local preview = buildPreview(gearId)
	if preview then
		fitViewport(refs.viewport, preview)
		refs.viewportFilled = true
	end
end

local function buildRow(scrolling: Instance, template: Instance, gear: any): RowRefs?
	local refs: RowRefs? = nil
	local ok, err = pcall(function()
		local row = (template :: GuiObject):Clone()
		row.Name = 'Gear_' .. tostring(gear.Id)
		row:SetAttribute('GearId', tostring(gear.Id))
		local built: RowRefs = {
			row = row,
			buyButton = nil,
			priceLabel = nil,
			lockOverlay = nil,
			rebirthLabel = nil,
			autoImage = nil,
			autoOn = nil,
			autoOff = nil,
			viewport = nil,
			viewportFilled = false,
		}
		local function setText(path: string, text: string)
			local node = row:FindFirstChild(path, true)
			if node and node:IsA('TextLabel') then
				node.Text = text
			end
		end
		setText('Name', tostring(gear.Name))
		setText('Description', tostring(gear.Description))
		local button = row:FindFirstChild('Button', true)
		if button and button:IsA('GuiButton') then
			built.buyButton = button
			local price = button:FindFirstChild('TextLabel')
			if price and price:IsA('TextLabel') then
				price.Text = formatStaticPrice(tostring(gear.Price))
				built.priceLabel = price
			end
			(button :: GuiButton).Activated:Connect(function()
				-- Owned rows equip (server re-validates
				-- ownership through the same EquipGear path
				-- receipts and purchases use); unowned rows
				-- purchase.
				if row:GetAttribute('OwnedState') == true then
					sendAction(tostring(gear.Id), 'Equip')
					return
				end
				sendAction(tostring(gear.Id), 'Purchase')
			end)
		else
			warnUi('Row missing Button for GearId=' .. tostring(gear.Id))
		end
		local autoBuy = row:FindFirstChild('AutoBuy', true)
		if autoBuy then
			local onNode = autoBuy:FindFirstChild('Toggle_ON')
			if onNode and onNode:IsA('GuiObject') then
				built.autoOn = onNode
			end
			local offNode = autoBuy:FindFirstChild('Toggle_OFF')
			if offNode and offNode:IsA('GuiObject') then
				built.autoOff = offNode
			end
			-- The single AutoBuy IMAGE (Visible-driven).
			built.autoImage = resolveAutoBuyImage(autoBuy, tostring(gear.Id))
			-- Initial state: hidden until authoritative
			-- GearShopState arrives and reconciles.
			row:SetAttribute('AutoBuyState', false)
			applyAutoBuyVisual(built, false)
			if autoBuy:IsA('GuiButton') then
				(autoBuy :: GuiButton).Activated:Connect(function()
					local current = row:GetAttribute('AutoBuyState') == true
					sendAction(tostring(gear.Id), 'SetAutoBuy', not current)
				end)
			end
		end
		local lock = row:FindFirstChild('LockOverlay', true)
		if lock and lock:IsA('GuiObject') then
			built.lockOverlay = lock
			local count = lock:FindFirstChild('RebirthCount')
			if count and count:IsA('TextLabel') then
				built.rebirthLabel = count
			end
		end
		local viewport = row:FindFirstChild('ViewportFrame', true)
		if viewport and viewport:IsA('ViewportFrame') then
			built.viewport = viewport
		end
		row.Visible = true
		row.Parent = scrolling
		refs = built
	end)
	if not ok then
		warnUi('row build failed: ' .. tostring(err))
		return nil
	end
	return refs
end

-- Build all rows once from static config. Returns true when
-- the row set is complete. Later calls are no-ops unless the
-- gear id set changed (then a single reconciling rebuild).
local function ensureRows(): boolean
	local ok, ready = pcall(function()
		local gui = resolveGui()
		if gui == nil then
			return false
		end
		local scrolling = resolveScrolling(gui)
		if scrolling == nil then
			return false
		end
		local template = scrolling:FindFirstChild('GearTemplate')
		if template == nil then
			return false
		end
		local wanted: { [string]: boolean } = {}
		for _, entry in ipairs(GearConfig.GetAll()) do
			wanted[entry.Id] = true
		end
		local complete = true
		for id in pairs(wanted) do
			if rows[id] == nil or rows[id].row.Parent == nil then
				complete = false
				break
			end
		end
		for id in pairs(rows) do
			if not wanted[id] then
				complete = false
				break
			end
		end
		if complete then
			return true
		end
		clearRows(scrolling)
		for _, entry in ipairs(GearConfig.GetAll()) do
			local refs = buildRow(scrolling, template, {
				Id = entry.Id,
				Name = entry.Name,
				Description = entry.Description,
				Price = entry.Price,
			})
			if refs then
				rows[entry.Id] = refs
			end
		end
		warnUi('rows built count=' .. tostring(#GearConfig.GetAll()))
		return true
	end)
	if not ok then
		warnUi('ensureRows failed: ' .. tostring(ready))
		return false
	end
	return ready == true
end

-- Patch ONE existing row from its authoritative snapshot.
-- Not owned -> authoritative price + Buy enabled.
-- Currently owned in this server -> "Owned" + button stays
-- clickable so it equips (owned clicks send Equip, never
-- Purchase). AutoBuy image Visible follows the persisted
-- boolean. Never destroys/reclones rows.
local function updateGearRow(gearId: string, gear: any)
	local refs = rows[gearId]
	if refs == nil or refs.row.Parent == nil then
		-- Id set drifted mid-session: one reconciling rebuild.
		ensureRows()
		refs = rows[gearId]
	end
	if refs == nil then
		warnUi('state update for unknown GearId=' .. tostring(gearId))
		return
	end
	local owned = gear.Owned == true
	local autoEnabled = gear.AutoBuy == true
	refs.row:SetAttribute('OwnedState', owned)
	refs.row:SetAttribute('AutoBuyState', autoEnabled)
	if refs.priceLabel then
		if owned then
			refs.priceLabel.Text = 'Owned'
		else
			refs.priceLabel.Text = tostring(gear.PriceText or '')
		end
	end
	if refs.buyButton then
		-- Always clickable: unowned sends Purchase, owned
		-- sends Equip (the click handler routes on
		-- OwnedState). The server re-validates everything.
		refs.buyButton.Active = true
	end
	if refs.lockOverlay then
		refs.lockOverlay.Visible = gear.Locked == true
	end
	if refs.rebirthLabel then
		refs.rebirthLabel.Text = 'Requires ' .. tostring(gear.RequiredRebirth) .. ' Rebirth'
	end
	applyAutoBuyVisual(refs, autoEnabled)
	fillViewport(refs, gearId)
	-- One client replication snapshot per false->true Owned
	-- transition (read-only): proves whether the granted Tool
	-- replicated to this client's Backpack/Character.
	if owned and lastOwnedTrace[gearId] ~= true then
		lastOwnedTrace[gearId] = true
		traceBackpackState('owned:' .. gearId)
	elseif not owned then
		lastOwnedTrace[gearId] = false
	end
end

-- Patch existing rows from an authoritative snapshot. Builds
-- first if needed; never rebuilds for a pure state change.
local function applyState(state: any)
	if type(state) ~= 'table' or type(state.Gears) ~= 'table' then
		return
	end
	if not ensureRows() then
		return
	end
	for _, gear in ipairs(state.Gears) do
		if type(gear) == 'table' and type(gear.Id) == 'string' then
			updateGearRow(gear.Id, gear)
		end
	end
end

local function wireClose(gui: Instance)
	if connectedGui == gui then
		return
	end
	connectedGui = gui :: GuiObject
	pcall(function()
		local close = gui:FindFirstChild('CloseButton', true)
		if close and close:IsA('GuiButton') then
			(close :: GuiButton).Activated:Connect(function()
				MenuPresentation.Close(gui :: GuiObject)
			end)
		end
	end)
end

local function openShopInstant()
	local ok, err = pcall(function()
		local gui = resolveGui()
		if gui == nil then
			warnUi('open requested but GearShop GUI missing')
			return
		end
		MenuPresentation.Open(gui :: GuiObject)
		ensureRows()
		wireClose(gui)
	end)
	if not ok then
		warnUi('open failed: ' .. tostring(err))
	end
end

local function connectShopPrompt()
	local ok, err = pcall(function()
		local map = Workspace:FindFirstChild('Map')
		local shop = map and map:FindFirstChild('Shop') or nil
		local part = shop and shop:FindFirstChild('PromptPart') or nil
		local prompt = part and (part :: BasePart):FindFirstChildOfClass('ProximityPrompt') or nil
		if prompt == nil then
			warnUi(
				'Shop ProximityPrompt missing (expected Workspace.Map.Shop.PromptPart); open falls back to server push'
			)
			return
		end
		if promptConnected then
			return
		end
		promptConnected = true
		prompt.Triggered:Connect(function()
			openShopInstant()
		end)
	end)
	if not ok then
		warnUi('prompt connect failed: ' .. tostring(err))
	end
end

local function onState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	local ok, err = pcall(applyState, payload)
	if not ok then
		warnUi('applyState failed: ' .. tostring(err))
		return
	end
	if payload.Show == true then
		local gui = resolveGui()
		if gui then
			MenuPresentation.Open(gui :: GuiObject)
			wireClose(gui)
		end
	end
end

function GearShopController.Init()
	if promptConnected then
		return
	end
	connectShopPrompt()
	wireToolTrace()
	local folder = Remotes.WaitForReady()
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.GearShopState, 10)
	end)
	if okState and stateEvent and (stateEvent :: Instance):IsA('RemoteEvent') then
		(stateEvent :: RemoteEvent).OnClientEvent:Connect(onState)
	else
		warnUi('GearShopState remote missing; shop cannot open')
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.GearShopResult, 10)
	end)
	if okResult and resultEvent and (resultEvent :: Instance):IsA('RemoteEvent') then
		(resultEvent :: RemoteEvent).OnClientEvent:Connect(onPurchaseResult)
	else
		warnUi('GearShopResult remote missing; purchase trace disabled')
	end
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.GearShopAction, 10)
	end)
	if okAction and actionEvent and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent
	else
		warnUi('GearShopAction remote missing; purchases disabled')
	end
end

return table.freeze(GearShopController)
