--!strict
--!native
--[[
	SellConfirmController
	======================
	Client owner of the authored `PlayerGui.Main.SellConfirmation`
	template (used as-is: no redesign, no cloned copies, one
	controlled instance). Flow is server-driven and
	server-authoritative throughout:

  Sell prompt Triggered (server)
    -> server validates (read-only) + publishes the LIVE
       stand-model reference + fires SellPreviewState (this
       controller Clone()s it locally; the live model is never
       moved)
	    -> THIS controller populates the template + shows it
	    -> Sell button fires SellConfirmAction { AnimalId }
	    -> server revalidates EVERYTHING and runs the canonical
	       SellService.SellAnimal transaction
	    -> SellConfirmResult closes the confirmation either way
	    -> Cancle closes locally with no server sale request

	The client NEVER decides owner, price, validity, or
	outcome. It renders server preview data verbatim, tracks
	a per-open pending animal + generation (stale async work
	is dropped), and cleans everything (pending, viewport
	clone, debounce, visibility) on every terminal path:
	success, cancel, reject, stale, respawn, base change,
	leave, timeout.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- Canonical display helpers (shared pure modules, also used
-- by GearShopController client-side).
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)
-- Shared exact-model showcase pipeline (clone + overhead-only
-- removal + WorldModel + camera-only fit + 8-direction outline).
-- Sell renders through it with the tuned constants below; the
-- ArenaResult card viewports use the older AnimalViewport module.
-- This controller keeps its flow, generation guards, debug proof
-- lines, and test seams.
local AnimalShowcase = require(ReplicatedStorage.Utility.AnimalShowcase)
-- Viewport hygiene only (ClearViewport on close/stale paths).
local AnimalViewport = require(ReplicatedStorage.Utility.AnimalViewport)
-- Canonical rarity color identity (same table the HUD slot rows,
-- overhead name colors, egg parts, and rich text use).
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local SellConfig = require(ReplicatedStorage.Config.Economy.Sell)

local SellConfirmController = {}

local localPlayer = Players.LocalPlayer

local function warnUi(message: string)
	Debug.Warn('SellConfirm', message)
end

local wired = false
local buttonsWired = false
local actionRemote: RemoteEvent? = nil

-- Resolved template refs (nil until the authored GUI exists).
local frame: Frame? = nil
local sellButton: TextButton? = nil
-- NOTE: the authored object is literally named `Cancle`
-- (typo). Used exactly as authored.
local cancelButton: TextButton? = nil
-- The Sell button's inner label carries the visible text
-- (SellConfirmation.Sell.TextLabel); the button Text is the
-- fallback when the label is absent.
local sellTextLabel: TextLabel? = nil
local nameLabel: TextLabel? = nil
local rarityBox: Frame? = nil
local rarityTitle: TextLabel? = nil
local levelLabel: TextLabel? = nil
local generationLabel: TextLabel? = nil
local mutationsLabel: TextLabel? = nil
local viewport: ViewportFrame? = nil

-- Per-open client state. `generation` invalidates stale async
-- work (viewport setup, late results). Never shared across
-- players (module state is per-client by construction).
local pendingAnimalId: string? = nil
local pendingGeneration = 0
local confirmInFlight = false
local lastBaseId: string? = nil

local RESULT_TIMEOUT_S = SellConfig.ResultTimeout
-- Bounded layout wait: Heartbeat iterations (NOT a fixed delay —
-- returns on the first frame with a real size). Only bounds the
-- worst case (a never-laid-out viewport aborts instead of hanging).
local MAX_LAYOUT_HEARTBEATS = 60
-- Eager, INDEPENDENT readiness: one bounded wait on OUR
-- template path only (PlayerGui.Main.SellConfirmation) so
-- the controller is armed before the first Sell prompt can
-- fire — even if Main replicates after startup. Never
-- MainGui, never SlotMenuController, never another
-- controller; non-blocking (spawned), single-shot. The
-- lazy ensureGui on preview covers anything this misses.
local EAGER_MAIN_WAIT_S = 5
local EAGER_TEMPLATE_WAIT_S = 3
-- Showcase staging/framing (yaw, margin, zoom, Origin, 1.25x
-- scale) lives in AnimalViewport (SellConfig.Viewport tunables)
-- — the single implementation shared with ArenaResult card
-- viewports. This controller keeps flow + guards + seams only.

local function logUi(message: string)
	Debug.Log('SellConfirmation', message)
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

local function findChild(parent: Instance?, name: string, className: string): Instance?
	if parent == nil then
		return nil
	end
	local ok, found = pcall(function()
		return parent:FindFirstChild(name)
	end)
	if not ok or found == nil then
		return nil
	end
	if not found:IsA(className) then
		return nil
	end
	return found
end

-- Resolve + hide the authored template. Never builds UI:
-- without the Studio-authored instance there is nothing to
-- own (selling stays fail-closed server-side). Re-resolves
-- after GUI resets (respawn): button wiring is re-armed so
-- the fresh instances get exactly one connection each.
local function ensureGui(): boolean
	if frame ~= nil and (frame :: Frame).Parent ~= nil then
		return true
	end
	buttonsWired = false
	local ok = pcall(function()
		local gui = playerGui()
		if gui == nil then
			return
		end
		local main = gui:FindFirstChild('Main')
		if main == nil then
			return
		end
		local root = main:FindFirstChild('SellConfirmation')
		if root == nil or not root:IsA('Frame') then
			return
		end
		frame = root :: Frame
		sellButton = findChild(root, 'Sell', 'TextButton') :: TextButton?
		if sellButton ~= nil then
			sellTextLabel = findChild(sellButton, 'TextLabel', 'TextLabel') :: TextLabel?
		else
			sellTextLabel = nil
		end
		cancelButton = findChild(root, 'Cancle', 'TextButton') :: TextButton?
		nameLabel = findChild(root, 'Name', 'TextLabel') :: TextLabel?
		levelLabel = findChild(root, 'Level', 'TextLabel') :: TextLabel?
		generationLabel = findChild(root, 'Generation', 'TextLabel') :: TextLabel?
		mutationsLabel = findChild(root, 'Mutations', 'TextLabel') :: TextLabel?
		rarityBox = findChild(root, 'RarityBox', 'Frame') :: Frame?
		if rarityBox ~= nil then
			rarityTitle = findChild(rarityBox, 'Title', 'TextLabel') :: TextLabel?
		end
		local item = findChild(root, 'Item', 'Frame')
		if item ~= nil then
			viewport = findChild(item, 'ViewportFrame', 'ViewportFrame') :: ViewportFrame?
		end
	end)
	if not ok then
		return false
	end
	local fr = frame
	if fr == nil then
		return false
	end
	-- Hidden until a valid preview opens it (never flash on
	-- join, respawn, or rejoin).
	pcall(function()
		MenuPresentation.Close(fr)
	end)
	return true
end

-- Tracked outline frames for the current open (destroyed on
-- close/stale-open/render-replace — never leaks across animals).
-- Declared up here (before clearViewport) so the wrapper below can
-- reference it: Luau locals are lexically scoped, forward uses
-- would resolve to a nil global at runtime.
local outlineFrames: { ViewportFrame } = {}

local function clearOutline()
	for _, ovp in ipairs(outlineFrames) do
		pcall(function()
			ovp:Destroy()
		end)
	end
	table.clear(outlineFrames)
end

local function clearViewport()
	AnimalViewport.ClearViewport(viewport)
	clearOutline()
end

local function setText(label: TextLabel?, text: string)
	local l = label
	if l == nil then
		return
	end
	pcall(function()
		l.Text = text
	end)
end

local function formatMutations(mutations: any): string
	if type(mutations) ~= 'table' or #mutations == 0 then
		return SellConfig.Labels.NoMutations
	end
	local parts: { string } = {}
	for _, id in ipairs(mutations) do
		if type(id) == 'string' and id ~= '' then
			parts[#parts + 1] = id
		end
	end
	if #parts == 0 then
		return SellConfig.Labels.NoMutations
	end
	return table.concat(parts, ', ')
end

-- Confirmation name: `[Trait] DisplayName` for canonical
-- non-normal traits (TraitConfig catalog membership decides
-- — nil/absent/'Normal'/'None' render the plain name), never
-- duplicating a prefix the display name already carries.
local function formatName(displayName: any, trait: any): string
	local name = if type(displayName) == 'string' and displayName ~= '' then displayName else 'Animal'
	if type(trait) ~= 'string' or trait == '' then
		return name
	end
	local known = false
	pcall(function()
		known = TraitConfig.Get(trait) ~= nil
	end)
	if not known then
		return name
	end
	local prefix = '[' .. trait .. '] '
	if string.sub(name, 1, #prefix) == prefix then
		return name
	end
	return prefix .. name
end

-- Sell button text from the server-canonical raw decimal
-- string, formatted with the shared BigNumber formatter
-- (same helper the shop/HUD money displays use). Missing
-- or unformattable values leave the authored text alone —
-- never a fabricated '$0'.
local function sellButtonText(raw: any): string?
	if type(raw) ~= 'string' or raw == '' then
		return nil
	end
	local text: string? = nil
	pcall(function()
		local formatted = BigNumber.Format(raw)
		if type(formatted) == 'string' and formatted ~= '' then
			text = SellConfig.Labels.SellForPrefix .. formatted
		end
	end)
	return text
end

local function paintSellButton(raw: any)
	local text = sellButtonText(raw)
	if text == nil then
		return
	end
	if sellTextLabel ~= nil then
		local label = sellTextLabel
		pcall(function()
			label.Text = text
		end)
		return
	end
	local button = sellButton
	if button ~= nil then
		pcall(function()
			button.Text = text
		end)
	end
end

-- RarityBox gradient: the visible `RarityBox.Gradient` UIGradient is
-- recolored per animal to a light→dark two-tone of the canonical
-- rarity color (RarityConfig.RarityColor — the existing project
-- identity, nothing invented). Only the gradient COLORS change:
-- authored Rotation, Offset, Transparency, and keypoint Times are
-- preserved. The named authored gradients are disabled while
-- Gradient owns the visible treatment so effects never composite.
-- Unknown/missing rarities (or a missing Gradient object) fall back
-- to the legacy enable-by-name behavior, which hides Gradient and
-- shows whatever the authoring provides — never an error, never
-- stale colors.
local LIGHTEN_T = SellConfig.RarityGradient.LightenT
local DARKEN_T = SellConfig.RarityGradient.DarkenT

-- Canonical base color for a rarity string, or nil when the rarity
-- is unknown/missing (fallback path). Never throws.
local function rarityBaseColor(rarity: any): Color3?
	local found: Color3? = nil
	pcall(function()
		if type(rarity) == 'string' then
			local table_ = RarityConfig.RarityColor
			if type(table_) == 'table' then
				found = table_[rarity]
			end
		end
	end)
	if typeof(found) ~= 'Color3' then
		return nil
	end
	return found
end

-- Lighter/brighter version of the same color (lerp toward white).
local function shadeLight(color: Color3): Color3
	return Color3.new(
		color.R + (1 - color.R) * LIGHTEN_T,
		color.G + (1 - color.G) * LIGHTEN_T,
		color.B + (1 - color.B) * LIGHTEN_T
	)
end

-- Darker/deeper version of the same color (scale toward black).
local function shadeDark(color: Color3): Color3
	return Color3.new(color.R * DARKEN_T, color.G * DARKEN_T, color.B * DARKEN_T)
end

-- Two-tone sequence over the given keypoint Times (authored Times
-- preserved, sorted): first stop light, last stop dark, interior
-- stops the canonical base. Pure — headless-testable.
local function rarityGradient(base: Color3, times: { number }): ColorSequence
	local sorted: { number } = {}
	for _, t in ipairs(times) do
		sorted[#sorted + 1] = t
	end
	table.sort(sorted)
	local light = shadeLight(base)
	local dark = shadeDark(base)
	local points: { ColorSequenceKeypoint } = {}
	if #sorted == 0 then
		points[1] = ColorSequenceKeypoint.new(0, light)
		points[2] = ColorSequenceKeypoint.new(1, dark)
	else
		for i, t in ipairs(sorted) do
			local c = if i == 1 then light elseif i == #sorted then dark else base
			points[#points + 1] = ColorSequenceKeypoint.new(t, c)
		end
	end
	return ColorSequence.new(points)
end

local function paintRarity(rarity: any)
	local name = if type(rarity) == 'string' then rarity else SellConfig.Labels.RarityUnknown
	setText(rarityTitle, name)
	local box = rarityBox
	if box == nil then
		return
	end
	pcall(function()
		local base = rarityBaseColor(rarity)
		local gradient: UIGradient? = nil
		for _, child in ipairs(box:GetChildren()) do
			if child:IsA('UIGradient') and child.Name == 'Gradient' then
				gradient = child :: UIGradient
				break
			end
		end
		local g = gradient
		-- Dynamic per-animal treatment: fresh colors every open, so
		-- rapid switching and reopening can never leave stale colors.
		if base ~= nil and g ~= nil then
			local gg = g :: UIGradient
			local times: { number } = {}
			for _, kp in ipairs(gg.Color.Keypoints) do
				times[#times + 1] = kp.Time
			end
			gg.Color = rarityGradient(base :: Color3, times)
			gg.Enabled = true
			for _, child in ipairs(box:GetChildren()) do
				if child:IsA('UIGradient') and child ~= gg then
					(child :: UIGradient).Enabled = false
				end
			end
			return
		end
		-- Fallback (unknown rarity or no Gradient object): legacy
		-- enable-by-name; Gradient hides so no stale colors remain.
		for _, child in ipairs(box:GetChildren()) do
			if child:IsA('UIGradient') then
				child.Enabled = (child.Name == name)
			end
		end
	end)
end

-- Full terminal cleanup: pending, debounce, viewport clone,
-- visibility. Every terminal path (success, cancel, reject,
-- stale, respawn, base change, leave, timeout) funnels here
-- so the next open starts clean.
local function close()
	pendingAnimalId = nil
	pendingGeneration += 1
	confirmInFlight = false
	clearViewport()
	local fr = frame
	if fr ~= nil then
		pcall(function()
			MenuPresentation.Close(fr)
		end)
	end
end

local function onCancel()
	if pendingAnimalId == nil then
		return
	end
	-- Cancel is local-only: no server request, no sale, no
	-- effects.
	close()
end

local function onSell()
	if pendingAnimalId == nil or confirmInFlight then
		return
	end
	if actionRemote == nil then
		warnUi('SellConfirmAction remote missing; cannot confirm')
		return
	end
	local animalId = pendingAnimalId :: string
	local gen = pendingGeneration
	confirmInFlight = true
	logUi(('sell requested animalId=%s'):format(animalId))
	pcall(function()
		(actionRemote :: RemoteEvent):FireServer({ AnimalId = animalId })
	end)
	-- Backstop: a lost result must never wedge the Sell
	-- button. The authoritative SellConfirmResult clears this
	-- first. The sale itself is single-shot server-side (the
	-- animal mutex), so a late result can never double-sell.
	task.delay(RESULT_TIMEOUT_S, function()
		if confirmInFlight and pendingGeneration == gen and pendingAnimalId == animalId then
			warnUi('confirm result timeout; closing')
			close()
		end
	end)
end

local function wireButtons()
	if buttonsWired then
		return
	end
	buttonsWired = true
	if sellButton ~= nil then
		local button = sellButton
		pcall(function()
			-- Both click signals: an inner covering label can
			-- swallow one of them depending on authoring. The
			-- in-flight flag makes the pair single-shot.
			button.Activated:Connect(onSell)
			button.MouseButton1Click:Connect(onSell)
		end)
	else
		warnUi('Sell button missing in template; confirms disabled')
	end
	if cancelButton ~= nil then
		local button = cancelButton
		pcall(function()
			button.Activated:Connect(onCancel)
			button.MouseButton1Click:Connect(onCancel)
		end)
	else
		warnUi('Cancle button missing in template')
	end
end

-- TEMPORARY DEBUG (remove after trace): one-line visual summary
-- of a model so the stand source and the viewport clone can be
-- compared in the Studio output (eyes/face GUIs are the suspect).
local function debugVisualSummary(model: Instance): string
	local parts, mesh, decals, surfaceAppear, guis, accessories = 0, 0, 0, 0, 0, 0
	local guiNames: { string } = {}
	pcall(function()
		for _, desc in ipairs((model :: Model):GetDescendants()) do
			if desc:IsA('BasePart') then
				parts += 1
				if desc:IsA('MeshPart') then
					mesh += 1
				end
			elseif desc:IsA('Decal') or desc:IsA('Texture') then
				decals += 1
			elseif desc:IsA('SurfaceAppearance') then
				surfaceAppear += 1
			elseif desc:IsA('BillboardGui') or desc:IsA('SurfaceGui') then
				guis += 1
				if #guiNames < 12 then
					guiNames[#guiNames + 1] = desc.ClassName .. ':' .. desc.Name
				end
			elseif desc:IsA('Accessory') then
				accessories += 1
			end
		end
	end)
	return ('parts=%d meshParts=%d decals/textures=%d surfaceAppearances=%d guis=%d[%s] accessories=%d'):format(
		parts,
		mesh,
		decals,
		surfaceAppear,
		guis,
		table.concat(guiNames, ','),
		accessories
	)
end

-- TEMPORARY DEBUG (remove after trace): dump the exact runtime
-- contents of SellConfirmation.Item.ViewportFrame (+ WorldModel
-- children with Name/Class/FullName) at a named stage. Catches
-- baked-in Studio models, second writers, and post-render
-- overwrites.
local function debugDumpViewport(stage: string, animalId: string)
	if viewport == nil then
		Debug.Log('SellConfirm', ('[SellViewport DEBUG] stage=%s animal=%s viewport=MISSING'):format(stage, animalId))
		return
	end
	local vpFull = 'unknown'
	pcall(function()
		vpFull = (viewport :: ViewportFrame):GetFullName()
	end)
	Debug.Log('SellConfirm', ('[SellViewport DEBUG] stage=%s animal=%s viewport=%s'):format(stage, animalId, vpFull))
	pcall(function()
		for _, child in ipairs((viewport :: ViewportFrame):GetChildren()) do
			if child:IsA('WorldModel') then
				for _, m in ipairs((child :: WorldModel):GetChildren()) do
					local mf = 'unknown'
					pcall(function()
						mf = m:GetFullName()
					end)
					local extra = 'non-model-leaf'
					if m:IsA('Model') then
						extra = debugVisualSummary(m)
					end
					Debug.Log('SellConfirm', ('[SellViewport DEBUG] stage=%s WorldModel child Name=%s Class=%s FullName=%s %s'):format(
							stage,
							m.Name,
							m.ClassName,
							mf,
							extra
						)
					)
				end
			else
				local cf = 'unknown'
				pcall(function()
					cf = child:GetFullName()
				end)
				Debug.Log('SellConfirm', ('[SellViewport DEBUG] stage=%s viewport-direct Name=%s Class=%s FullName=%s'):format(
						stage,
						child.Name,
						child.ClassName,
						cf
					)
				)
			end
		end
	end)
end

-- Layout-aware wait: the camera fit reads ViewportFrame.AbsoluteSize,
-- which is only valid once the frame is visible AND laid out. Polls
-- per-Heartbeat (returns on the first valid frame — never a fixed
-- delay), bounded by MAX_LAYOUT_HEARTBEATS. Returns false when the
-- generation was superseded, the GUI went away, or no layout arrived:
-- callers must abort the render. Never yields the caller (call from
-- task.spawn).
local function waitForViewportLayout(vp: ViewportFrame, gen: number): boolean
	for _ = 1, MAX_LAYOUT_HEARTBEATS do
		if pendingGeneration ~= gen then
			return false
		end
		local fr = frame
		if fr == nil or (fr :: Frame).Parent == nil then
			return false
		end
		local ready = false
		pcall(function()
			local size = (vp :: ViewportFrame).AbsoluteSize
			ready = size.X > 0 and size.Y > 0
		end)
		if ready then
			return pendingGeneration == gen
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

-- --- Sell live-model viewer (NOT the showcase renderer) ------------
--
-- Philosophy: show the EXACT live Stand animal. Clone it, remove ONLY
-- the overhead UI, mount into the WorldModel, and fit the CAMERA to
-- the model (never the reverse). No StripClone, no ApplyPresentation,
-- no part/CFrame/color/transparency edits, no showcase constants.
-- The live source is never reparented, moved, or mutated.

-- Sell-tuned showcase constants. CANONICAL: Economy.Sell (Sell.Viewport) —
-- the former forked locals (yaw 25 / zoom 0.7 / margin 1.1) were reconciled
-- into config and this controller reads them. TUNING: lower zoom = closer;
-- yaw = camera orbit. The shared renderer receives them verbatim.
local SELL_YAW_DEG = SellConfig.Viewport.ShowcaseYawDeg
local SELL_ZOOM = SellConfig.Viewport.ShowcaseZoom
local SELL_MARGIN = SellConfig.Viewport.ShowcaseMargin
local SELL_ELEVATION = SellConfig.Viewport.ShowcaseElevation
local SELL_MIN_DIST = SellConfig.Viewport.MinDistance
local SELL_OUTLINE_PX = 2

-- Fallback outline color when the animal rarity is unknown. Known
-- rarities use the canonical RarityConfig color (existing theme,
-- no duplicated palette).
local OUTLINE_FALLBACK_COLOR = Color3.fromRGB(255, 255, 255)

local function outlineColorFor(rarity: any): Color3
	local base = rarityBaseColor(rarity)
	if base ~= nil then
		return base
	end
	return OUTLINE_FALLBACK_COLOR
end

-- (Outline layers are built by AnimalShowcase.BuildOutline via
-- renderLiveAnimal below; tracked frames still clear here.)

-- Full sell render via the shared AnimalShowcase pipeline with the
-- sell-tuned constants above. Log lines and generation/cleanup
-- behavior are unchanged from the previous inline version:
-- SOURCE/LIVE prints, CLONE census, shared mount + camera-only fit
-- + 8-direction outline, tracked frames for close cleanup.
local function renderLiveAnimal(
	vp: ViewportFrame,
	gen: number,
	animalId: string,
	slotId: any,
	source: Model,
	rarity: any
): (Model?, number?)
	if pendingGeneration ~= gen then
		return nil, nil
	end
	local srcFull = 'unknown'
	pcall(function()
		srcFull = source:GetFullName()
	end)
		Debug.Log('SellViewport', ('SOURCE animal=%s stand=%s model=%s'):format(
			source.Name,
			tostring(slotId),
			srcFull
		))
		Debug.Log('SellViewport', ('LIVE %s'):format(AnimalShowcase.Census(source)))
	clearOutline()
	local color = outlineColorFor(rarity)
	local function live(): boolean
		return pendingGeneration == gen
	end
	local shown, dist, outlines = AnimalShowcase.Render(vp, {
		Source = source,
		Silhouette = false,
		Outline = true,
		OutlineColor = color,
		ThicknessPx = SELL_OUTLINE_PX,
		YawDeg = SELL_YAW_DEG,
		Zoom = SELL_ZOOM,
		Margin = SELL_MARGIN,
		Elevation = SELL_ELEVATION,
		MinDistance = SELL_MIN_DIST,
		IsValid = live,
	})
	if shown == nil then
		clearOutline()
		return nil, nil
	end
		Debug.Log('SellViewport', ('CLONE name=%s %s'):format((shown :: Model).Name, AnimalShowcase.Census(shown :: Model)))
	for _, f in ipairs(outlines or {}) do
		outlineFrames[#outlineFrames + 1] = f
	end
	do
		local mainCamCF: CFrame? = nil
		pcall(function()
			local cam = (vp :: ViewportFrame).CurrentCamera
			if cam ~= nil then
				mainCamCF = cam.CFrame
			end
		end)
		if mainCamCF ~= nil then
						Debug.Log('SellViewportOutline', ('source=%s stand=%s color=%s thickness=%d layers=8 camera=%s'):format(
					source.Name,
					tostring(slotId),
					tostring(color),
					SELL_OUTLINE_PX,
					tostring(mainCamCF)
				))
		end
	end
	return shown, dist
end

-- Viewport fill from the preview payload's live-model
-- reference: this is the ACTUAL rendered Stand animal model
-- (SellService publishes animal.model — never a reconstruction),
-- rendered through the sell live-model viewer below (clone +
-- overhead-only removal + WorldModel + camera-only fit — the live
-- model is never reparented, moved, or mutated, and the clone is
-- never resized, repivoted, or recolored).
-- Runs deferred-after-layout (openFromPayload shows the frame first,
-- then fills once AbsoluteSize is valid) but still generation-guarded:
-- the reference arrives WITH the event and the clone is taken only for
-- the still-current open, so later Stand changes cannot swap the
-- preview; stale opens (replaced/closed mid-fill) abort before touching
-- the viewport.
local function fillViewport(gen: number, animalId: string, slotId: any, source: any, rarity: any)
	if viewport == nil then
		return
	end
	logUi(('viewport setup started animalId=%s'):format(animalId))
	-- Render-input proof (one line per render): the camera fit reads
	-- AbsoluteSize, so a zero size here means a fallback aspect.
	do
		local vis, sx, sy = 'unknown', -1, -1
		pcall(function()
			local fr = frame
			vis = tostring(fr ~= nil and (fr :: Frame).Visible)
			local size = (viewport :: ViewportFrame).AbsoluteSize
			sx, sy = size.X, size.Y
		end)
				Debug.Log('SellViewport', ('PRE_RENDER animal=%s generation=%d visible=%s absoluteSize=(%.1f, %.1f)'):format(
				tostring(animalId),
				gen,
				vis,
				sx,
				sy
			))
	end
	-- TEMPORARY DEBUG: pre-fill dump (reveals baked-in Studio
	-- models or a second writer that ran before us).
	debugDumpViewport('pre-fill', animalId)
	if typeof(source) ~= 'Instance' or not (source :: Instance):IsA('Model') then
		warnUi(
			('[SellConfirmViewport] ERROR: actual stand model not found slot=%s animal=%s stand=%s'):format(
				tostring(slotId),
				tostring(animalId),
				tostring(slotId)
			)
		)
		return
	end
	logUi('viewport resolving visual model found=true (live-model clone)')
	if pendingGeneration ~= gen or pendingAnimalId ~= animalId then
		return
	end
	local shown, dist =
		renderLiveAnimal(viewport, gen, animalId, slotId, (source :: Instance) :: Model, rarity)
	if shown == nil then
		warnUi(
			('[SellConfirmViewport] ERROR viewport render failed slot=%s animal=%s stand=%s (viewport left empty)'):format(
				tostring(slotId),
				tostring(animalId),
				tostring(slotId)
			)
		)
		return
	end
	-- CAMERA proof (one line per successful render): inputs the
	-- camera-only fit observed + resulting camera.
	do
		local sx, sy, aspect = -1, -1, -1
		local bbox, targetText = 'unknown', 'unknown'
		local camPos, camFov = 'unknown', -1
		pcall(function()
			local size = (viewport :: ViewportFrame).AbsoluteSize
			sx, sy = size.X, size.Y
			aspect = if size.X > 0 and size.Y > 0 then size.X / size.Y else -1
		end)
		pcall(function()
			local _, bsize = AnimalShowcase.VisibleBounds(shown :: Model)
			bbox = ('(%.2f, %.2f, %.2f)'):format(bsize.X, bsize.Y, bsize.Z)
		end)
		pcall(function()
			local cam = (viewport :: ViewportFrame).CurrentCamera
			if cam ~= nil then
				camPos = tostring(cam.CFrame.Position)
				camFov = cam.FieldOfView
			end
		end)
				Debug.Log('SellViewport', ('CAMERA animal=%s absoluteSize=(%.1f, %.1f) aspect=%.3f bboxSize=%s cameraPosition=%s target=%s fov=%.1f dist=%.2f'):format(
				tostring(animalId),
				sx,
				sy,
				aspect,
				bbox,
				camPos,
				targetText,
				camFov,
				tonumber(dist) or -1
			))
	end
	if pendingGeneration ~= gen or pendingAnimalId ~= animalId then
		AnimalViewport.ClearViewport(viewport)
		return
	end
	logUi(('viewport clone created animalId=%s dist=%.1f'):format(animalId, tonumber(dist) or -1))
	logUi('viewport camera ready=live-view')
	-- TEMPORARY DEBUG: post-render dump + 1s-later re-dump
	-- (reveals a second writer overwriting us after we run).
	debugDumpViewport('post-render', animalId)
	task.delay(1, function()
		if pendingGeneration == gen and pendingAnimalId == animalId then
			debugDumpViewport('post-render+1s', animalId)
		end
	end)
end

-- Populate + show one confirmation from a validated
-- preview payload. Assumes close() already ran. Returns
-- true when the GUI opened.
--
-- ORDERING (layout timing): the camera fit reads
-- ViewportFrame.AbsoluteSize, which is only valid once the frame
-- is visible AND laid out. So: paint labels -> Visible = true ->
-- deferred layout-aware fill. The fill runs on a spawned thread
-- after the first valid layout frame (bounded wait, never a fixed
-- delay); generation guards abort stale fills so an old render can
-- never populate a new viewport.
local function openFromPayload(payload: any): boolean
	if not ensureGui() then
		return false
	end
	wireButtons()
	pendingGeneration += 1
	local gen = pendingGeneration
	pendingAnimalId = payload.AnimalId
	confirmInFlight = false
	logUi(('preview received animalId=%s'):format(pendingAnimalId))
	setText(nameLabel, formatName(payload.Name, payload.Trait))
	paintRarity(payload.Rarity)
	setText(levelLabel, tostring(payload.LevelText or SellConfig.Labels.LevelUnknown))
	setText(generationLabel, tostring(payload.GenerationText or SellConfig.Labels.LevelNotApplicable))
	setText(mutationsLabel, formatMutations(payload.Mutations))
	paintSellButton(payload.SellValueRaw)
	local fr = frame
	if fr ~= nil then
		pcall(function()
			MenuPresentation.Open(fr)
		end)
	end
	logUi(('opened animalId=%s'):format(pendingAnimalId))
	-- Deferred render: wait for a real viewport layout first so
	-- the camera-only fit observes the actual aspect instead of a fallback.
	-- Captured per-open; any close/reopen/base-change bumps the
	-- generation and this thread aborts before touching the viewport.
	local vp = viewport
	local animalId = payload.AnimalId
	local slotId = payload.SlotId
	local source = payload.Model
	local rarity = payload.Rarity
	task.spawn(function()
		if vp == nil then
			return
		end
		if not waitForViewportLayout(vp, gen) then
			return
		end
		if pendingGeneration ~= gen or pendingAnimalId ~= animalId then
			return
		end
		fillViewport(gen, animalId, slotId, source, rarity)
	end)
	return true
end

local function onPreviewState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	-- One controlled instance: a new preview safely
	-- closes/cleans any previous confirmation first (never
	-- stacked, never cloned twice).
	close()
	if payload.Valid ~= true or type(payload.AnimalId) ~= 'string' then
		return
	end
	if openFromPayload(payload) then
		return
	end
	-- Replication race (Main/SellConfirmation not yet
	-- replicated): ONE bounded retry on our template path
	-- only — never MainGui, never another controller. A newer
	-- preview aborts this retry via the generation check.
	warnUi('SellConfirmation template missing; single bounded retry')
	local attempt = pendingGeneration
	task.spawn(function()
		local ok = pcall(function()
			local gui = playerGui()
			if gui == nil then
				return
			end
			local main = gui:WaitForChild('Main', EAGER_MAIN_WAIT_S)
			if main == nil then
				return
			end
			if main:WaitForChild('SellConfirmation', EAGER_TEMPLATE_WAIT_S) == nil then
				return
			end
		end)
		if not ok then
			return
		end
		if pendingGeneration ~= attempt or pendingAnimalId ~= nil then
			return
		end
		openFromPayload(payload)
	end)
end

local function onConfirmResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	-- Only the pending animal's result closes this
	-- confirmation (stale results are ignored). Success and
	-- failure both close: the server already toasted the
	-- specific outcome through its canonical path.
	if pendingAnimalId == nil or payload.AnimalId ~= pendingAnimalId then
		return
	end
	close()
end

local function onPlayerState(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	-- Base change invalidates any pending sale (the slot
	-- record the preview was built from may be gone). The
	-- server rejects the stale confirm regardless; this
	-- just closes the UI promptly.
	if type(payload.BaseId) == 'string' then
		if lastBaseId ~= nil and payload.BaseId ~= lastBaseId and pendingAnimalId ~= nil then
			close()
		end
		lastBaseId = payload.BaseId
	end
end

function SellConfirmController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnUi('no LocalPlayer; controller disabled')
		return
	end
	local folder = Remotes.WaitForReady()
	local function connectRemote(name: string, fn: (any) -> ())
		local ok, event = pcall(function()
			return folder:WaitForChild(name, 10)
		end)
		if ok and event ~= nil and (event :: Instance):IsA('RemoteEvent') then
			pcall(function()
				(event :: RemoteEvent).OnClientEvent:Connect(fn)
			end)
		else
			warnUi(name .. ' remote missing')
		end
	end
	connectRemote(Remotes.Names.SellPreviewState, onPreviewState)
	connectRemote(Remotes.Names.SellConfirmResult, onConfirmResult)
	connectRemote(Remotes.Names.PlayerState, onPlayerState)
	local okAction, actionEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.SellConfirmAction, 10)
	end)
	if okAction and actionEvent ~= nil and (actionEvent :: Instance):IsA('RemoteEvent') then
		actionRemote = actionEvent
	else
		warnUi('SellConfirmAction remote missing; confirm disabled')
	end
	-- Hide the template if it is already present (never flash
	-- on join). Respawn cleanup below re-hides after resets.
	pcall(function()
		if ensureGui() then
			wireButtons()
		end
	end)
	-- Eager, INDEPENDENT readiness: one bounded wait on OUR
	-- template path only (PlayerGui.Main.SellConfirmation) so
	-- the controller is armed before the first Sell prompt can
	-- fire — even if Main replicates after startup. Never
	-- MainGui, never SlotMenuController, never another
	-- controller; non-blocking (spawned), single-shot.
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
			if main:WaitForChild('SellConfirmation', EAGER_TEMPLATE_WAIT_S) == nil then
				return
			end
			if ensureGui() then
				wireButtons()
			end
		end)
	end)
	logUi('controller ready')
	pcall(function()
		localPlayer.CharacterAdded:Connect(function()
			close()
		end)
	end)
end

-- TEST-ONLY seams (headless-verifiable without the Studio template).
function SellConfirmController._TestReset()
	pendingAnimalId = nil
	pendingGeneration = 0
	confirmInFlight = false
	lastBaseId = nil
end

function SellConfirmController._TestPending(): string?
	return pendingAnimalId
end

function SellConfirmController._TestFormatMutations(mutations: any): string
	return formatMutations(mutations)
end

function SellConfirmController._TestFormatName(displayName: any, trait: any): string
	return formatName(displayName, trait)
end

function SellConfirmController._TestSellButtonText(raw: any): string?
	return sellButtonText(raw)
end

function SellConfirmController._TestRarityBaseColor(rarity: any): Color3?
	return rarityBaseColor(rarity)
end

function SellConfirmController._TestShadeLight(color: Color3): Color3
	return shadeLight(color)
end

function SellConfirmController._TestShadeDark(color: Color3): Color3
	return shadeDark(color)
end

function SellConfirmController._TestRarityGradient(base: Color3, times: { number }): ColorSequence
	return rarityGradient(base, times)
end

return table.freeze(SellConfirmController)
