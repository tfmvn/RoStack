--!strict
--!native
--[[
	RebirthController
	=================
	Client owner of the authored `PlayerGui.Main.Rebirth` GUI.
	Renders server snapshots verbatim; the server owns validation,
	numbers, and outcomes. Requests are minimal ({Action='State'}
	for a snapshot, {Action='Rebirth'} to attempt); the client never
	selects a Rebirth number.

	Assumptions about the authored GUI (all resolved defensively —
	missing nodes degrade, never error; see log lines):
	  * Rebirth.{TopBar:{CloseButton,Title}, Contents:{Warning,
	    Requirements:{Items:{Template:{Name,Number,ImageLabel,
	    ViewportFrame}}, Bars:{Money:{ProgressBar,Text},
	    ArenaLVL:{ProgressBar,Text}}}}, Button}
	  * ProgressBar fill is X.Scale of its authored Size.
	  * Template is hidden and cloned per animal requirement.
	  * UnlockItems.Template is the unlock card template (same
	    Name/Number/ImageLabel/ViewportFrame shape, under
	    Contents.UnlockItems): hidden and cloned once per unlock
	    the previewed Rebirth grants (stand deltas +
	    newly-gated gears, server-derived). The card ImageLabel
	    mirrors the authored Requirement Template's ImageLabel
	    (same Studio asset the animal cards use — no second
	    effect); Name is white (canonical gold for Arena Stands),
	    Number is hidden for Gear cards.
	Requirement card viewports reuse the shared AnimalViewport
	renderer when the server ships a live preview model (same
	live-clone pattern as the sell preview); cards without a
	preview hide their viewport.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- Shared exact-model showcase (same clone/strip/camera/outline
-- pipeline the sell preview renders through — no second system).
local AnimalShowcase = require(ReplicatedStorage.Utility.AnimalShowcase)
-- Generic unlock presentation (stands + Tools) over the same
-- AnimalShowcase pipeline. Animal requirement cards above keep
-- calling AnimalShowcase directly and are untouched.
local StandShowcase = require(ReplicatedStorage.Utility.StandShowcase)
-- Pure unlock text/shape helpers (CountText/Signature/Kind).
-- The server derives WHAT unlocks; this only formats it.
local RebirthUnlocks = require(ReplicatedStorage.Utility.RebirthUnlocks)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)

local RebirthController = {}

local localPlayer = Players.LocalPlayer

local function warnUi(message: string)
	Debug.Warn('Rebirth', message)
end

local function logUi(message: string)
	Debug.Log('Rebirth', message)
end

local wired = false
local actionRemote: RemoteEvent? = nil
local attemptInFlight = false
local buttonsWired = false

-- Bounded waits for OUR template paths only (never MainGui,
-- never another controller). Non-blocking (spawned).
local EAGER_MAIN_WAIT_S = 5
local EAGER_REBIRTH_WAIT_S = 3
local EAGER_HUD_WAIT_S = 3

local frame: Frame? = nil
local hudButton: GuiButton? = nil
local titleLabel: TextLabel? = nil
local warningLabel: TextLabel? = nil
local closeButton: GuiButton? = nil
local rebirthButton: GuiButton? = nil
local itemsContainer: Instance? = nil
local itemTemplate: GuiObject? = nil
local unlockContainer: Instance? = nil
local unlockTemplate: GuiObject? = nil
local moneyBar: GuiObject? = nil
local moneyText: TextLabel? = nil
local arenaBar: GuiObject? = nil
local arenaText: TextLabel? = nil

local lastState: any = nil
-- Card paint generation + pending rows: card shells build
-- synchronously on state receipt, but viewport rendering waits
-- for real layout (cards are often built while hidden).
local paintGeneration = 0
local needsRender = false
local pendingRows: any = nil
-- Unlock cards run their own generation (independent of the
-- requirement cards above: rebuilding one side must never
-- invalidate the other side's in-flight renders).
local unlockGeneration = 0
local needsUnlockRender = false
local pendingUnlocks: any = nil
local lastUnlockSignature: string? = nil

local COMPLETE_COLOR = Color3.fromRGB(80, 220, 120)
local INCOMPLETE_COLOR = Color3.fromRGB(230, 90, 90)

-- Tutorial-adjacent eligibility badge: a code-made "!" dot on
-- the HUD RebirthButton while the server says CanRebirth.
-- Display only (never decides eligibility); hidden when
-- ineligible, maxed, or the button is missing. Independent of
-- tutorial completion — it observes the canonical
-- RebirthState snapshot this controller already paints.
local eligibilityBadge: TextLabel? = nil

local function paintEligibilityBadge(canRebirth: boolean)
	pcall(function()
		if hudButton == nil or (hudButton :: GuiObject).Parent == nil then
			if eligibilityBadge ~= nil then
				pcall(function()
					(eligibilityBadge :: TextLabel):Destroy()
				end)
				eligibilityBadge = nil
			end
			return
		end
		if eligibilityBadge == nil or (eligibilityBadge :: TextLabel).Parent == nil then
			local badge = Instance.new('TextLabel')
			badge.Name = 'RebirthEligibilityBadge'
			badge.AnchorPoint = Vector2.new(1, 0)
			badge.Position = UDim2.new(1, 4, 0, -6)
			badge.Size = UDim2.new(0, 22, 0, 22)
			badge.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
			badge.TextColor3 = Color3.new(1, 1, 1)
			badge.Font = Enum.Font.GothamBold
			badge.TextSize = 16
			badge.Text = '!'
			badge.Visible = false
			local corner = Instance.new('UICorner')
			corner.CornerRadius = UDim.new(1, 0)
			corner.Parent = badge
			badge.Parent = hudButton
			eligibilityBadge = badge
		end
		(eligibilityBadge :: TextLabel).Visible = canRebirth == true
	end)
end

local function playerGui(): PlayerGui?
	local ok, gui = pcall(function()
		if localPlayer == nil then
			return nil
		end
		return localPlayer:FindFirstChildOfClass('PlayerGui')
	end)
	if ok and gui ~= nil then
		return gui
	end
	return nil
end

local function childOf(parent: Instance?, name: string): Instance?
	if parent == nil then
		return nil
	end
	local found: Instance? = nil
	pcall(function()
		found = parent:FindFirstChild(name)
	end)
	return found
end

local function ensureGui(): boolean
	if frame ~= nil and (frame :: Frame).Parent ~= nil then
		return true
	end
	buttonsWired = false
	local resolved = false
	pcall(function()
		local gui = playerGui()
		local main = if gui ~= nil then gui:FindFirstChild('Main') else nil
		local root = if main ~= nil then main:FindFirstChild('Rebirth') else nil
		if root == nil or not root:IsA('Frame') then
			return
		end
		frame = root :: Frame
		logUi('UI found path=PlayerGui.Main.Rebirth')
		local topBar = childOf(root, 'TopBar')
		local contents = childOf(root, 'Contents')
		titleLabel = childOf(topBar, 'Title') :: TextLabel?
		if titleLabel ~= nil and not (titleLabel :: Instance):IsA('TextLabel') then
			titleLabel = nil
		end
		local close = childOf(topBar, 'CloseButton')
		closeButton = if close ~= nil and close:IsA('GuiButton') then close :: GuiButton else nil
		warningLabel = childOf(contents, 'Warning') :: TextLabel?
		if warningLabel ~= nil and not (warningLabel :: Instance):IsA('TextLabel') then
			warningLabel = nil
		end
		local requirements = childOf(contents, 'Requirements')
		local items = if requirements ~= nil then childOf(requirements, 'Items') else nil
		itemsContainer = items
		local template = if items ~= nil then childOf(items, 'Template') else nil
		itemTemplate = if template ~= nil and template:IsA('GuiObject') then template :: GuiObject else nil
		if itemTemplate ~= nil then
			(itemTemplate :: GuiObject).Visible = false
		end
		-- Unlock preview cards (Contents.UnlockItems.Template, same
		-- Name/Number/ImageLabel/ViewportFrame shape). Resolved
		-- defensively: a missing node degrades to no unlock cards,
		-- never an error; the requirement side above is untouched.
		local unlocks = childOf(contents, 'UnlockItems')
		unlockContainer = unlocks
		local unlockTpl = if unlocks ~= nil then childOf(unlocks, 'Template') else nil
		unlockTemplate = if unlockTpl ~= nil and unlockTpl:IsA('GuiObject') then unlockTpl :: GuiObject else nil
		if unlockTemplate ~= nil then
			(unlockTemplate :: GuiObject).Visible = false
		end
		if unlockContainer ~= nil then
			logUi('UnlockItems found path=PlayerGui.Main.Rebirth.Contents.UnlockItems')
		else
			warnUi('Contents.UnlockItems missing; unlock preview unavailable')
		end
		local bars = if requirements ~= nil then childOf(requirements, 'Bars') else nil
		local money = if bars ~= nil then childOf(bars, 'Money') else nil
		moneyBar = childOf(money, 'ProgressBar') :: GuiObject?
		moneyText = childOf(money, 'Text') :: TextLabel?
		local arena = if bars ~= nil then childOf(bars, 'ArenaLVL') else nil
		arenaBar = childOf(arena, 'ProgressBar') :: GuiObject?
		arenaText = childOf(arena, 'Text') :: TextLabel?
		local button = childOf(root, 'Button')
		rebirthButton = if button ~= nil and button:IsA('GuiButton') then button :: GuiButton else nil
		-- HUD toggle (PlayerGui.HUD.Left.RebirthButton; legacy flat
		-- HUD.RebirthButton accepted): flips the same frame the
		-- CloseButton closes. Opening via the existing Visible
		-- signal below refreshes state, so both controls always
		-- agree.
		local hud = if gui ~= nil then gui:FindFirstChild('HUD') else nil
		local toggle = if hud ~= nil then HudTree.RebirthButton(gui) else nil
		hudButton = if toggle ~= nil and toggle:IsA('GuiButton') then toggle :: GuiButton else nil
		if hudButton ~= nil then
			logUi('RebirthButton found under PlayerGui.HUD')
			-- Normal gameplay owns the Left chain: make sure the
			-- button can actually appear (tracked flips only).
			HudTree.EnsureChainVisible(hudButton)
		else
			warnUi('HUD.Left.RebirthButton missing; toggle unavailable')
		end
		do
			local cb = if topBar ~= nil then childOf(topBar, 'CloseButton') else nil
			if cb ~= nil then
				logUi('CloseButton found path=PlayerGui.Main.Rebirth.TopBar.CloseButton')
			end
		end
		resolved = true
	end)
	if not resolved then
		return false
	end
	-- Initial visibility: start closed, exactly once per resolve
	-- (never re-forced by paints, states, or results).
	pcall(function()
		if frame ~= nil then
			MenuPresentation.Close(frame :: Frame)
		end
	end)
	pcall(function()
		if buttonsWired then
			return
		end
		buttonsWired = true
		if closeButton ~= nil then
			(closeButton :: GuiButton).Activated:Connect(function()
				logUi('CloseButton clicked')
				if frame ~= nil then
					MenuPresentation.Close(frame :: Frame)
				end
			end)
			logUi('CloseButton bound')
		end
		if rebirthButton ~= nil then
			(rebirthButton :: GuiButton).Activated:Connect(function()
				RebirthController.Attempt()
			end)
		end
		if hudButton ~= nil then
			local toggle = function()
				local fr: Frame? = frame
				if fr ~= nil then
					local old: boolean = fr.Visible
					local newVisible: boolean = not old
					MenuPresentation.SetVisible(fr, newVisible)
					logUi(
						('RebirthButton clicked oldVisible=%s newVisible=%s'):format(
							tostring(old),
							tostring(newVisible)
						)
					)
				end
			end
			local hudBtn = hudButton :: GuiButton
			-- Activated ONLY: connecting MouseButton1Click too would
			-- fire the toggle twice per physical click (net no-op).
			hudBtn.Activated:Connect(toggle)
			logUi('RebirthButton bound')
		end
		-- Snapshot refresh whenever the panel opens (event-driven,
		-- never polled).
		if frame ~= nil then
			(frame :: Frame):GetPropertyChangedSignal('Visible'):Connect(function()
				if (frame :: Frame).Visible then
					RebirthController.RequestState()
				end
			end)
		end
	end)
	return true
end

local function setText(label: TextLabel?, text: string)
	if label == nil then
		return
	end
	pcall(function()
		(label :: TextLabel).Text = text
	end)
end

local function paintBar(bar: GuiObject?, frac: number)
	if bar == nil then
		return
	end
	pcall(function()
		local clamped = math.clamp(frac, 0, 1)
		local target = bar :: GuiObject
		target.Size = UDim2.new(clamped, 0, target.Size.Y.Scale, target.Size.Y.Offset)
	end)
end

local function moneyFormat(raw: any): string
	local text: string? = nil
	pcall(function()
		if type(raw) == 'string' then
			text = BigNumber.Format(raw)
		end
	end)
	return text or '?'
end

local function clearCards()
	if itemsContainer == nil or itemTemplate == nil then
		return
	end
	pcall(function()
		for _, child in ipairs((itemsContainer :: Instance):GetChildren()) do
			if child ~= itemTemplate and child:IsA('GuiObject') then
				child:Destroy()
			end
		end
	end)
end

-- Card shells build here (moved below maybeRenderCards:
-- lexical order matters for locals).

local function outlineColorForRarity(rarity: any): Color3
	local found: Color3? = nil
	pcall(function()
		local table_ = RarityConfig.RarityColor
		if type(table_) == 'table' and type(rarity) == 'string' then
			found = table_[rarity]
		end
	end)
	if typeof(found) == 'Color3' then
		return found
	end
	return Color3.fromRGB(255, 255, 255)
end

-- Render every card viewport for one paint generation: wait for
-- real layout, then render through the shared showcase (template
-- clone + overhead strip + locked silhouette when unmatched +
-- camera-only fit + 8-direction outline). Outlines parent inside
-- the card subtree, so card rebuilds clean them automatically.
-- Generation-guarded per card; failures hide the viewport and log.
local function renderCardViewports(gen: number)
	if itemsContainer == nil then
		return
	end
	local container = itemsContainer :: Instance
	local complete = true
	for _, card in ipairs(container:GetChildren()) do
		if gen ~= paintGeneration then
			return
		end
		local idx: number? = nil
		pcall(function()
			local v = card:GetAttribute('RowIndex')
			if type(v) == 'number' then
				idx = v
			end
		end)
		if idx == nil then
			continue
		end
		local row: any = nil
		if type(pendingRows) == 'table' then
			row = pendingRows[idx :: number]
		end
		if type(row) ~= 'table' then
			continue
		end
		local vp = childOf(card, 'ViewportFrame')
		if vp == nil or not vp:IsA('ViewportFrame') then
			continue
		end
		local src = row.TemplateModel
		if typeof(src) ~= 'Instance' or not (src :: Instance):IsA('Model') then
			Debug.Log('RebirthViewport', ('requirement=%s trait=%s level=%s state=%s template=MISSING (text-only)'):format(
					tostring(row.DefId),
					tostring(row.Trait),
					tostring(row.MinimumLevel),
					if row.Matched then 'Unlocked' else 'Locked'
				))
			pcall(function()
				(vp :: ViewportFrame).Visible = false
			end)
			continue
		end
		local function live(): boolean
			return gen == paintGeneration
		end
		if not AnimalShowcase.WaitForSize(vp :: ViewportFrame, live, 60) then
			complete = false
			continue
		end
		local locked = row.Matched ~= true
		local color = outlineColorForRarity(row.Rarity)
		local shown, dist = AnimalShowcase.Render(vp :: ViewportFrame, {
			Source = src,
			Silhouette = locked,
			Outline = true,
			OutlineColor = color,
			ThicknessPx = 2,
			YawDeg = 25,
			Zoom = 0.7,
			Margin = 1.1,
			Elevation = 0.12,
			MinDistance = 0.3,
			IsValid = live,
		})
		if shown == nil then
						Debug.Log('RebirthViewport', ('requirement=%s trait=%s level=%s state=%s'):format(
				tostring(row.DefId),
				tostring(row.Trait),
				tostring(row.MinimumLevel),
				if locked then 'Locked' else 'Unlocked'
			))
			pcall(function()
				(vp :: ViewportFrame).Visible = false
			end)
			complete = false
			continue
		end
		local srcFull = 'unknown'
		pcall(function()
			srcFull = (src :: Instance):GetFullName()
		end)
		Debug.Log('RebirthViewport', ('requirement=%s trait=%s level=%s state=%s'):format(
				tostring(row.DefId),
				tostring(row.Trait),
				tostring(row.MinimumLevel),
				if locked then 'Locked' else 'Unlocked'
			))
		Debug.Log('RebirthViewport', ('template=%s'):format(srcFull))
				Debug.Log('RebirthViewport', ('camera initialized dist=%.2f outline initialized layers=8'):format(tonumber(dist) or -1))
	end
	if complete and gen == paintGeneration then
		needsRender = false
	end
end

-- Kick deferred viewport rendering when the panel is actually
-- visible (layout-valid). Called after card builds and on open.
-- Declared after renderCardViewports (lexical order matters).
local function maybeRenderCards(gen: number)
	if gen ~= paintGeneration then
		return
	end
	local fr = frame
	if fr == nil or not (fr :: Frame).Visible then
		return
	end
	if not needsRender then
		return
	end
	task.spawn(function()
		renderCardViewports(gen)
	end)
end

local function paintCards(rows: any)
	clearCards()
	if itemsContainer == nil or itemTemplate == nil then
		return
	end
	if type(rows) ~= 'table' then
		return
	end
	pendingRows = rows
	paintGeneration += 1
	local gen = paintGeneration
	needsRender = true
	for index, row in ipairs(rows) do
		if type(row) ~= 'table' then
			continue
		end
		pcall(function()
			local card = ((itemTemplate :: GuiObject):Clone()) :: GuiObject
			card.Name = 'RequirementCard'
			card.Visible = true
			card:SetAttribute('RowIndex', index)
			local nameLabel = childOf(card, 'Name')
			if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
				(nameLabel :: TextLabel).Text = tostring(row.DisplayName or row.DefId or 'Animal');
				(nameLabel :: TextLabel).TextColor3 = if row.Matched then COMPLETE_COLOR else INCOMPLETE_COLOR
			end
			local numberLabel = childOf(card, 'Number')
			if numberLabel ~= nil and numberLabel:IsA('TextLabel') then
				local levelText = 'Lv. ' .. tostring(row.MinimumLevel or '?')
				if type(row.BestLevel) == 'number' then
					levelText ..= ' (best ' .. tostring(row.BestLevel) .. ')'
				end
				(numberLabel :: TextLabel).Text = levelText;
				(numberLabel :: TextLabel).TextColor3 = if row.Matched then COMPLETE_COLOR else INCOMPLETE_COLOR
			end
			card.Parent = itemsContainer
		end)
	end
	maybeRenderCards(gen)
end

-- --- Unlock cards (Contents.UnlockItems) -------------------------

-- Canonical Gear Shop preview shells (published once at boot by
-- GearShopService): the ONLY gear visual source. Never
-- ServerStorage, never a reconstruction.
local GEAR_PREVIEW_FOLDER = 'GearShopPreviews'

local function clearUnlockCards()
	if unlockContainer == nil or unlockTemplate == nil then
		return
	end
	pcall(function()
		for _, child in ipairs((unlockContainer :: Instance):GetChildren()) do
			if child ~= unlockTemplate and child:IsA('GuiObject') then
				child:Destroy()
			end
		end
	end)
end

local function resolveGearPreview(gearId: any): Instance?
	local shell: Instance? = nil
	pcall(function()
		local folder = ReplicatedStorage:FindFirstChild(GEAR_PREVIEW_FOLDER)
		local node = folder and folder:FindFirstChild(tostring(gearId)) or nil
		if node ~= nil then
			shell = node
		end
	end)
	return shell
end

-- Render every unlock card viewport for one paint generation: wait
-- for real layout, then render through StandShowcase (the shared
-- AnimalShowcase clone/strip/camera/8-direction-outline pipeline
-- with stand Button-side facing and Tool wrapping). Outlines parent
-- inside the card subtree, so card rebuilds clean them
-- automatically; re-renders without a rebuild clear stale outline
-- siblings first. Generation-guarded per card; failures hide the
-- viewport and log.
local function renderUnlockViewports(gen: number)
	if unlockContainer == nil then
		return
	end
	local container = unlockContainer :: Instance
	local complete = true
	for _, card in ipairs(container:GetChildren()) do
		if gen ~= unlockGeneration then
			return
		end
		local idx: number? = nil
		pcall(function()
			local v = card:GetAttribute('UnlockIndex')
			if type(v) == 'number' then
				idx = v
			end
		end)
		if idx == nil then
			continue
		end
		local entry: any = nil
		if type(pendingUnlocks) == 'table' then
			entry = pendingUnlocks[idx :: number]
		end
		if type(entry) ~= 'table' then
			continue
		end
		local vp = childOf(card, 'ViewportFrame')
		if vp == nil or not vp:IsA('ViewportFrame') then
			continue
		end
		StandShowcase.ClearOutlines(card)
		local function live(): boolean
			return gen == unlockGeneration
		end
		if not AnimalShowcase.WaitForSize(vp :: ViewportFrame, live, 60) then
			complete = false
			continue
		end
		local rendered = false
		local distText = '?'
		if entry.Kind == RebirthUnlocks.Kind.Gear then
			local shell = resolveGearPreview(entry.GearId)
			if shell ~= nil then
				local result = StandShowcase.RenderTool(vp :: ViewportFrame, shell, live)
				if result.Mounted ~= nil then
					rendered = true
					distText = ('%.2f'):format(tonumber(result.Distance) or -1)
				end
			end
			if rendered then
								Debug.Log('RebirthUnlock', ('kind=Gear gearId=%s name=%s amount=%s'):format(
						tostring(entry.GearId),
						tostring(entry.Name),
						tostring(entry.Amount)
					))
								Debug.Log('RebirthUnlock', ('source=GearShopPreviews/%s'):format(tostring(entry.GearId)))
			else
				Debug.Log('RebirthUnlock', tostring(entry.GearId))
			end
		else
			local src = entry.TemplateModel
			if typeof(src) == 'Instance' and ((src :: Instance):IsA('Model') or (src :: Instance):IsA('BasePart')) then
				local result = StandShowcase.RenderStand(vp :: ViewportFrame, src :: Instance, live)
				if result.Mounted ~= nil then
					rendered = true
					distText = ('%.2f'):format(tonumber(result.Distance) or -1)
				end
			end
			if rendered then
								Debug.Log('RebirthUnlock', ('kind=%s name=%s amount=%s'):format(
						tostring(entry.Kind),
						tostring(entry.Name),
						tostring(entry.Amount)
					))
			else
				Debug.Log('RebirthUnlock', ('kind=%s template=MISSING (text-only)'):format(tostring(entry.Kind)))
			end
		end
		if rendered then
			Debug.Log('RebirthUnlock', ('camera initialized dist=%s outline initialized layers=8'):format(distText))
		else
			pcall(function()
				(vp :: ViewportFrame).Visible = false
			end)
			complete = false
		end
	end
	if complete and gen == unlockGeneration then
		needsUnlockRender = false
	end
end

-- Kick deferred unlock viewport rendering when the panel is
-- actually visible (layout-valid). Called after unlock card builds
-- and on open.
local function maybeRenderUnlocks(gen: number)
	if gen ~= unlockGeneration then
		return
	end
	local fr = frame
	if fr == nil or not (fr :: Frame).Visible then
		return
	end
	if not needsUnlockRender then
		return
	end
	task.spawn(function()
		renderUnlockViewports(gen)
	end)
end

local function paintUnlockCards(unlocks: any)
	clearUnlockCards()
	if unlockContainer == nil or unlockTemplate == nil then
		return
	end
	if type(unlocks) ~= 'table' then
		pendingUnlocks = nil
		return
	end
	pendingUnlocks = unlocks
	unlockGeneration += 1
	local gen = unlockGeneration
	needsUnlockRender = true
	for index, entry in ipairs(unlocks) do
		if type(entry) ~= 'table' then
			continue
		end
		pcall(function()
			local card = ((unlockTemplate :: GuiObject):Clone()) :: GuiObject
			card.Name = 'UnlockCard'
			card.Visible = true
			card:SetAttribute('UnlockIndex', index)
			local nameLabel = childOf(card, 'Name')
			if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
				local title: string = tostring((entry :: any).Name or '?')
				if title == '?' or title == '' then
					title = RebirthUnlocks.DisplayName(entry)
				end
				(nameLabel :: TextLabel).Text = title;
				-- Name color is presentation-only: white everywhere,
				-- canonical gold for Arena Stands (single source:
				-- RebirthUnlocks.NameColor). Font/size/position and
				-- any authored stroke stay exactly as authored.
				(nameLabel :: TextLabel).TextColor3 = RebirthUnlocks.NameColor(entry)
			end
			local numberLabel = childOf(card, 'Number')
			if numberLabel ~= nil and numberLabel:IsA('TextLabel') then
				if RebirthUnlocks.NumberVisible(entry) then
					(numberLabel :: TextLabel).Text = RebirthUnlocks.CountText((entry :: any).Amount);
					(numberLabel :: TextLabel).Visible = true
				else
					-- Gear/Tool cards hide Number (Visible only —
					-- the object stays, the shared Template is
					-- untouched, stand cards still show +N).
					(numberLabel :: TextLabel).Visible = false
				end
				(numberLabel :: TextLabel).TextColor3 = RebirthUnlocks.NameColor(entry)
			end
			-- Angel/Studio presentation reuse: the unlock card's
			-- ImageLabel mirrors the authored Requirement
			-- Template's ImageLabel — the SAME Studio asset and
			-- approach the animal cards use. No second effect, no
			-- invented ImageIds, presentation-only (properties on
			-- the card, cleaned with it, no connections). When the
			-- requirement template carries no image, the unlock
			-- card keeps its own authored look.
			local imageLabel = childOf(card, 'ImageLabel')
			if imageLabel ~= nil and imageLabel:IsA('ImageLabel') then
				pcall(function()
					local srcTemplate = itemTemplate
					local srcImage = if srcTemplate ~= nil
						then (srcTemplate :: GuiObject):FindFirstChild('ImageLabel')
						else nil
					if srcImage ~= nil and (srcImage :: Instance):IsA('ImageLabel') then
						local src = srcImage :: ImageLabel
						if type(src.Image) == 'string' and src.Image ~= '' then
							local dst = imageLabel :: ImageLabel
							dst.Image = src.Image
							dst.ImageColor3 = src.ImageColor3
							dst.ImageTransparency = src.ImageTransparency
							dst.ImageRectOffset = src.ImageRectOffset
							dst.ImageRectSize = src.ImageRectSize
							dst.ScaleType = src.ScaleType
							dst.SliceCenter = src.SliceCenter
							dst.SliceScale = src.SliceScale
							dst.BackgroundTransparency = src.BackgroundTransparency
							dst.Visible = (src :: ImageLabel).Visible
						end
					end
				end)
			end
			card.Parent = unlockContainer
		end)
	end
	maybeRenderUnlocks(gen)
end

local function rowSignature(rows: any): string
	if type(rows) ~= 'table' then
		return 'none'
	end
	local parts: { string } = {}
	for _, row in ipairs(rows) do
		if type(row) == 'table' then
			parts[#parts + 1] = ('%s|%s|%s|%s'):format(
				tostring(row.DefId),
				tostring(row.Trait),
				tostring(row.MinimumLevel),
				tostring(row.Matched)
			)
		end
	end
	return table.concat(parts, ';')
end

local lastRowSignature: string? = nil

local function paint(state: any)
	if type(state) ~= 'table' then
		return
	end
	lastState = state
	if state.Maxed then
		setText(titleLabel, 'MAX REBIRTH')
		setText(warningLabel, 'Maximum Rebirth reached.')
	else
		setText(titleLabel, ('Rebirth %d → %d'):format(tonumber(state.Current) or 0, tonumber(state.Next) or 0))
		setText(warningLabel, if state.CanRebirth then 'Ready to Rebirth!' else 'Requirements not met.')
	end
	setText(moneyText, ('$%s / $%s'):format(moneyFormat(state.Money), moneyFormat(state.MoneyRequired)))
	do
		-- Display-only fraction via BigNumber division (money can
		-- exceed float range; the quotient here is small).
		-- Satisfied requirements pin to full.
		local frac = 0
		if state.MoneySatisfied then
			frac = 1
		else
			pcall(function()
				local q = BigNumber.Divide(state.Money, state.MoneyRequired)
				frac = math.clamp(tonumber(q) or 0, 0, 1)
			end)
		end
		paintBar(moneyBar, frac)
	end
	setText(
		arenaText,
		('Level %s / %s'):format(tostring(state.ArenaLevel or '?'), tostring(state.ArenaRequired or '?'))
	)
	do
		local have = tonumber(state.ArenaLevel) or 0
		local need = tonumber(state.ArenaRequired) or 1
		if need <= 0 then
			need = 1
		end
		paintBar(arenaBar, have / need)
	end
	-- Card shells rebuild ONLY when the requirement set or any
	-- matched flag flips (level-ups, new rebirth). Text/bars above
	-- repaint every state; viewports re-render only on rebuild or
	-- when the panel opens with pending work.
	local sig = rowSignature(state.Animals)
	if sig ~= lastRowSignature then
		lastRowSignature = sig
		paintCards(state.Animals)
	elseif needsRender then
		maybeRenderCards(paintGeneration)
	end
	-- Unlock shells rebuild ONLY when the previewed Rebirth's
	-- unlock set changes (new rebirth available, purchase ladder
	-- moved). Text above repaints every state; unlock viewports
	-- re-render only on rebuild or when the panel opens with
	-- pending work. Server owns WHAT unlocks; this only displays.
	local unlockSig = RebirthUnlocks.Signature(state.Next, state.Unlocks)
	if unlockSig ~= lastUnlockSignature then
		lastUnlockSignature = unlockSig
		paintUnlockCards(state.Unlocks)
	elseif needsUnlockRender then
		maybeRenderUnlocks(unlockGeneration)
	end
	if rebirthButton ~= nil then
		pcall(function()
			(rebirthButton :: GuiButton).Selectable = state.CanRebirth == true and not attemptInFlight;
			(rebirthButton :: GuiButton).Active = state.CanRebirth == true and not attemptInFlight
		end)
	end
	paintEligibilityBadge(state.CanRebirth == true and state.Maxed ~= true)
	logUi(
		('state current=%s next=%s can=%s'):format(
			tostring(state.Current),
			tostring(state.Next),
			tostring(state.CanRebirth)
		)
	)
end

function RebirthController.RequestState()
	if not ensureGui() then
		return
	end
	if actionRemote == nil then
		return
	end
	pcall(function()
		(actionRemote :: RemoteEvent):FireServer({ Action = 'State' })
	end)
end

function RebirthController.Attempt()
	if not ensureGui() then
		return
	end
	if actionRemote == nil or attemptInFlight then
		return
	end
	attemptInFlight = true
	pcall(function()
		(actionRemote :: RemoteEvent):FireServer({ Action = 'Rebirth' })
	end)
end

function RebirthController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnUi('no LocalPlayer; controller disabled')
		return
	end
	local t0 = os.clock()
	logUi('controller start')
	-- UI FIRST: bind open/close from PlayerGui alone. This never
	-- waits on remotes, profile, base, or any server system — the
	-- panel must open even while data is still loading.
	pcall(function()
		ensureGui()
	end)
	logUi(('UI ready attempt t=%.2fs'):format(os.clock() - t0))
	-- Eager, INDEPENDENT readiness: one bounded wait on OUR paths
	-- only (PlayerGui.Main.Rebirth + PlayerGui.HUD.RebirthButton)
	-- so the toggle is armed even if Main/HUD replicate after
	-- startup. Non-blocking (spawned), single-shot. The lazy
	-- ensureGui on open covers anything this misses.
	task.spawn(function()
		pcall(function()
			local gui = playerGui()
			if gui == nil then
				return
			end
			local main = gui:WaitForChild('Main', EAGER_MAIN_WAIT_S)
			if main == nil then
				return
			end
			if main:WaitForChild('Rebirth', EAGER_REBIRTH_WAIT_S) == nil then
				return
			end
			local hud = gui:WaitForChild('HUD', EAGER_HUD_WAIT_S)
			if hud == nil then
				return
			end
			-- Nested HUD.Left.RebirthButton (legacy flat fallback
			-- inside the resolver); eager wait only warms the tree.
			local left = hud:WaitForChild('Left', EAGER_HUD_WAIT_S)
			if left ~= nil then
				left:WaitForChild('RebirthButton', EAGER_HUD_WAIT_S)
			else
				hud:WaitForChild('RebirthButton', EAGER_HUD_WAIT_S)
			end
			if ensureGui() then
				logUi(('eager UI ready t=%.2fs'):format(os.clock() - t0))
			end
		end)
	end)
	-- DATA SECOND: remote subscriptions only feed content (cards,
	-- bars, results). A slow server delays DATA, never the button.
	local folder = Remotes.WaitForReady()
	local ok, event = pcall(function()
		return folder:WaitForChild(Remotes.Names.RebirthAction, 10)
	end)
	if ok and event ~= nil and (event :: Instance):IsA('RemoteEvent') then
		actionRemote = event :: RemoteEvent
	else
		warnUi('RebirthAction remote missing; rebirths disabled')
	end
	local okState, stateEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.RebirthState, 10)
	end)
	if okState and stateEvent ~= nil and (stateEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(stateEvent :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				paint(payload)
			end)
		end)
	end
	-- Live refresh: authoritative pushes (level-ups, collections,
	-- sales) re-query state; paint() rebuilds cards ONLY when a
	-- matched flag flips, so steady-state pushes cost one cheap
	-- snapshot and zero viewport rebuilds. Event-driven, no loops.
	local okPush, pushEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.PlayerState, 10)
	end)
	if okPush and pushEvent ~= nil and (pushEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(pushEvent :: RemoteEvent).OnClientEvent:Connect(function()
				RebirthController.RequestState()
			end)
		end)
	end
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.RebirthResult, 10)
	end)
	if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(resultEvent :: RemoteEvent).OnClientEvent:Connect(function(payload: any)
				attemptInFlight = false
				if type(payload) == 'table' then
					if payload.Success == true then
						setText(warningLabel, ('Rebirth %s complete!'):format(tostring(payload.Rebirth or '')))
					else
						setText(warningLabel, 'Rebirth failed: ' .. tostring(payload.Error or 'unknown'))
					end
				end
				RebirthController.RequestState()
			end)
		end)
	end
	pcall(function()
		ensureGui()
	end)
	logUi('controller ready')
end

return table.freeze(RebirthController)
