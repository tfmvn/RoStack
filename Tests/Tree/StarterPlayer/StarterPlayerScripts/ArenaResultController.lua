--!strict
--!native
--[[
	ArenaResultController
	=====================
	Client owner of the authored `PlayerGui.Main.ArenaResult`
	template (used as-is: no redesign, no cloned copies, one
	controlled instance). Shows the server-finalized end-of-raid
	result for THIS player only.

	INDEPENDENCE + INSTANT OPENING (hard requirements):
	  - Depends on nothing but ReplicatedStorage config/helpers
	    and its own template path. Never MainGui,
	    SlotMenuController, StandPresentation, SellConfirmation,
	    OverheadGui, or any other UI system.
	  - Init subscribes to the ArenaResult remote only; the GUI
	    is resolved lazily on receipt (never blocks Init).
	  - On RaidEnd: validate + dedupe -> resolve template ->
	    Visible = true FIRST -> paint cheap text synchronously ->
	    defer expensive viewport clones to task.defer with
	    generation guards. Viewport work can NEVER delay the
	    panel.

	The client NEVER decides outcome, rewards, XP, or validity.
	It renders the server snapshot verbatim. Rewards were granted
	server-side before the payload was sent; Continue only closes
	(it fires no remote and grants nothing).
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
-- Canonical display helpers (same shared modules the sell
-- confirmation and HUD use).
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Arena = require(ReplicatedStorage.Config.World.Arena)
-- Shared result-open flag: set while this panel owns the screen so
-- the Start menu (separate controller) stays hidden underneath.
local ArenaUIState = require(ReplicatedStorage.Utility.ArenaUIState)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- Shared Animal showcase renderer: the SAME staging/framing the
-- SellConfirmation preview uses (SellConfig.Viewport tunables).
-- Each result card viewport is an independent clone + camera.
local AnimalViewport = require(ReplicatedStorage.Utility.AnimalViewport)

local ArenaResultController = {}

local localPlayer = Players.LocalPlayer

local function warnUi(message: string)
	Debug.Warn('ArenaResult', message)
end

local function logUi(message: string)
	Debug.Log('ArenaResult', message)
end

local wired = false
local buttonsWired = false

-- Resolved template refs (nil until the authored GUI exists).
local frame: Frame? = nil
local nameLabel: TextLabel? = nil
local animalList: Instance? = nil
local waveNode: Instance? = nil
local moneyNode: Instance? = nil
local eggsNode: Instance? = nil
local eggsScrolling: ScrollingFrame? = nil
local eggsTemplate: GuiObject? = nil
local eggsNoEggs: GuiObject? = nil
local continueButton: GuiButton? = nil

type CardRefs = {
	root: Instance,
	title: TextLabel?,
	viewport: ViewportFrame?,
	rarity: TextLabel?,
	currentLevel: TextLabel?,
	newLevel: TextLabel?,
	level: TextLabel?,
	xp: TextLabel?,
}

local cards: { CardRefs } = {}

-- Per-open client state. `generation` invalidates stale deferred
-- work (viewport fills from a replaced/closed result).
-- `pendingSession` is the server completion token (SessionId);
-- repeats of the same token are ignored (one screen per raid).
local pendingSession: string? = nil
local pendingGeneration = 0

-- Bounded waits for OUR template path only (never MainGui,
-- never another controller). Non-blocking (spawned).
local EAGER_MAIN_WAIT_S = 5
local EAGER_TEMPLATE_WAIT_S = 3

-- Max result cards (matches the authored AnimalList capacity).
local CARD_CAP = Arena.ResultCardCap

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

local function setText(label: TextLabel?, text: string)
	local l = label
	if l == nil then
		return
	end
	pcall(function()
		l.Text = text
	end)
end

-- Level-box label resolution. Authored hierarchy is a CONTAINER
-- with the text child inside:
--   AnimalList.<N>.CurrentLevel.Title (TextLabel)
--   AnimalList.<N>.NewLevel.Title (TextLabel)
-- A direct TextLabel with the same name is also tolerated (flat
-- authoring variants). NEVER returns the container itself: writing
-- .Text on a Frame is a silent no-op, which is exactly how stale
-- template text ("Lvl 40"/"Lvl 43") survived previous paints.
local function findLevelTitle(cardRoot: Instance?, name: string): TextLabel?
	if cardRoot == nil then
		return nil
	end
	local container: Instance? = nil
	pcall(function()
		container = cardRoot:FindFirstChild(name)
	end)
	if container == nil then
		return nil
	end
	if (container :: Instance):IsA('TextLabel') then
		return container :: TextLabel
	end
	return findChild(container, 'Title', 'TextLabel') :: TextLabel?
end

-- Resolve + hide the authored template. Never builds UI:
-- without the Studio-authored instance there is nothing to
-- own. Re-resolves after GUI resets (respawn): Continue wiring
-- is re-armed so fresh instances get one connection each.
local function ensureGui(): boolean
	if frame ~= nil and (frame :: Frame).Parent ~= nil then
		return true
	end
	buttonsWired = false
	table.clear(cards)
	nameLabel = nil
	animalList = nil
	waveNode = nil
	moneyNode = nil
	eggsNode = nil
	eggsScrolling = nil
	eggsTemplate = nil
	eggsNoEggs = nil
	continueButton = nil
	local ok = pcall(function()
		local gui = playerGui()
		if gui == nil then
			return
		end
		local main = gui:FindFirstChild('Main')
		if main == nil then
			return
		end
		local root = main:FindFirstChild('ArenaResult')
		if root == nil or not root:IsA('Frame') then
			return
		end
		frame = root :: Frame
		nameLabel = findChild(root, 'Name', 'TextLabel') :: TextLabel?
		animalList = root:FindFirstChild('AnimalList')
		if animalList ~= nil then
			for i = 1, CARD_CAP do
				local cardRoot = animalList:FindFirstChild(tostring(i))
				if cardRoot ~= nil then
					local item = cardRoot:FindFirstChild('Item')
					local vp: ViewportFrame? = nil
					if item ~= nil then
						vp = findChild(item, 'ViewportFrame', 'ViewportFrame') :: ViewportFrame?
					end
					cards[#cards + 1] = {
						root = cardRoot,
						title = findChild(cardRoot, 'Title', 'TextLabel') :: TextLabel?,
						viewport = vp,
						rarity = findChild(cardRoot, 'Rarity', 'TextLabel') :: TextLabel?,
						currentLevel = findLevelTitle(cardRoot, 'CurrentLevel') :: TextLabel?,
						newLevel = findLevelTitle(cardRoot, 'NewLevel') :: TextLabel?,
						level = findChild(cardRoot, 'Level', 'TextLabel') :: TextLabel?,
						xp = findChild(cardRoot, 'XP', 'TextLabel') :: TextLabel?,
					}
				end
			end
		end
		local right = root:FindFirstChild('RightSide')
		if right ~= nil then
			local waveCounter = right:FindFirstChild('WaveCounter')
			if waveCounter ~= nil then
				local wave = findChild(waveCounter, 'Wave', 'TextLabel') :: Instance?
				if wave == nil then
					wave = findChild(waveCounter, 'Wave', 'TextButton') :: Instance?
				end
				waveNode = if wave ~= nil then wave else waveCounter
			end
			moneyNode = right:FindFirstChild('Money')
			eggsNode = right:FindFirstChild('Eggs')
			if eggsNode ~= nil then
				eggsScrolling = findChild(eggsNode, 'ScrollingFrame', 'ScrollingFrame') :: ScrollingFrame?
				if eggsScrolling ~= nil then
					local template = (eggsScrolling :: ScrollingFrame):FindFirstChild('Template')
					if template ~= nil and template:IsA('GuiObject') then
						eggsTemplate = template :: GuiObject?
					end
				end
				local noEggs = eggsNode:FindFirstChild('NoEggs')
				if noEggs ~= nil and noEggs:IsA('GuiObject') then
					eggsNoEggs = noEggs :: GuiObject?
				end
			end
			local cont = right:FindFirstChild('Continue')
			if cont ~= nil and cont:IsA('GuiButton') then
				continueButton = cont :: GuiButton?
			end
		end
	end)
	if not ok then
		return false
	end
	if frame == nil then
		return false
	end
	-- Hidden until a finalized result opens it.
	pcall(function()
		MenuPresentation.Close(frame :: Frame)
	end)
	return true
end

local function clearCardViewports()
	for _, card in ipairs(cards) do
		AnimalViewport.ClearViewport(card.viewport)
	end
end

-- Egg entries from the previous raid must never leak into the
-- next: destroy everything except the authored Template and the
-- NoEggs state node.
local function clearEggEntries()
	local scrolling = eggsScrolling
	if scrolling == nil then
		return
	end
	pcall(function()
		for _, child in ipairs((scrolling :: ScrollingFrame):GetChildren()) do
			if child:IsA('GuiObject') and child ~= eggsTemplate then
				child:Destroy()
			end
		end
	end)
end

local function logArenaUi(message: string)
	Debug.Log('ArenaUI', message)
end

-- Full terminal cleanup: pending session, debounce, viewports,
-- egg entries, visibility, shared result-open flag. Every
-- terminal path (Continue, replaced result, respawn) funnels here
-- so the next raid starts clean. Idempotent: Continue spam is
-- safe by construction.
local function close()
	pendingSession = nil
	pendingGeneration += 1
	ArenaUIState.SetResultOpen(false)
	clearCardViewports()
	clearEggEntries()
	local fr = frame
	if fr ~= nil then
		pcall(function()
			MenuPresentation.Close(fr)
		end)
	end
end

-- Outcome heading. Server decides victory/defeat; the client only
-- renders the finalized outcome (RaidComplete fallback).
local function outcomeMessage(outcome: any, raidComplete: any): string
	if outcome == 'Victory' or raidComplete == true then
		return 'RAID COMPLETE!'
	elseif outcome == 'Defeat' or raidComplete == false then
		return 'SQUAD DEFEATED'
	else
		return 'RAID COMPLETE!'
	end
end

local function levelText(level: any): string
	local n = tonumber(level) or 1
	if n ~= n or n < 1 then
		n = 1
	end
	return ('Lv. %d'):format(math.floor(n))
end

local function moneyText(raw: any): string
	if type(raw) ~= 'string' or raw == '' then
		return '$0'
	end
	local formatted: string? = nil
	pcall(function()
		local text = BigNumber.Format(raw)
		if type(text) == 'string' and text ~= '' then
			formatted = text
		end
	end)
	if formatted == nil then
		return '$' .. raw
	end
	return '$' .. (formatted :: string)
end

local function waveText(stage: any, maxStage: any): string?
	local s = tonumber(stage)
	if s == nil or s ~= s then
		return nil
	end
	local m = tonumber(maxStage)
	if m ~= nil and m == m and m > 0 then
		return ('%d / %d'):format(math.floor(s), math.floor(m))
	end
	return ('Wave %d'):format(math.floor(s))
end

-- Rarity label: canonical text + canonical color identity (same
-- table the HUD/overheads use). Never errors, never invents.
local function paintRarity(label: TextLabel?, rarity: any)
	if label == nil then
		return
	end
	local name = if type(rarity) == 'string' and rarity ~= '' then rarity else '?'
	setText(label, name)
	pcall(function()
		local color: Color3? = nil
		pcall(function()
			local table_ = RarityConfig.RarityColor
			if type(table_) == 'table' then
				color = table_[name]
			end
		end)
		if typeof(color) == 'Color3' then
			(label :: TextLabel).TextColor3 = color :: Color3
		end
	end)
end

-- Normalize card rows: cap at CARD_CAP, drop non-tables, fill
-- display-safe fallbacks. Pure (headless-testable).
local function pickCards(animals: any): { { [string]: any } }
	local out: { { [string]: any } } = {}
	if type(animals) ~= 'table' then
		logUi('pickCards input=0 output=0')
		return out
	end
	for _, a in ipairs(animals) do
		if #out >= CARD_CAP then
			break
		end
		if type(a) == 'table' then
			local title = if type(a.DisplayName) == 'string' and a.DisplayName ~= '' then a.DisplayName else 'Animal'
			local rarity = if type(a.Rarity) == 'string' and a.Rarity ~= '' then a.Rarity else '?'
			local lb = tonumber(a.LevelBefore) or tonumber(a.Level) or 1
			if lb ~= lb or lb < 1 then
				lb = 1
			end
			local la = tonumber(a.LevelAfter) or lb
			if la ~= la or la < 1 then
				la = lb
			end
			local xp = tonumber(a.XP) or 0
			if xp ~= xp or xp < 0 then
				xp = 0
			end
			-- Combat keepsake: pristine pre-destruction clone of the
			-- participant's ACTUAL combat model
			-- (Workspace.ArenaBattles.Battle_<N>.Arena_Player<M>),
			-- captured server-side before death-fade/cleanup and
			-- parked in
			-- ReplicatedStorage.ArenaResultModels/Session_<N>. The
			-- viewport clones THIS — the single source of truth.
			-- There is no fallback: a missing keepsake stays nil and
			-- the viewport logs an error and stays empty.
			local combatModel: Model? = nil
			if typeof(a.CombatModel) == 'Instance' and (a.CombatModel :: Instance):IsA('Model') then
				combatModel = a.CombatModel :: Model
			end
		-- Identity for viewport logging (model resolution itself
		-- is the live-model clone, same as SellConfirmation —
		-- DefId/Trait are never used as lookup keys). UniqueId
		-- pins the row to its combat participant (stable across
		-- duplicate species).
		local uniqueId = if type(a.UniqueId) == 'string' and a.UniqueId ~= '' then a.UniqueId else '?'
		local defId = if type(a.DefinitionId) == 'string' and a.DefinitionId ~= '' then a.DefinitionId else '?'
		local trait = if type(a.Trait) == 'string' and a.Trait ~= '' then a.Trait else 'Normal'
		out[#out + 1] = {
			UniqueId = uniqueId,
			Title = title,
			Rarity = rarity,
			DefinitionId = defId,
			Trait = trait,
			LevelBefore = math.floor(lb),
			LevelAfter = math.floor(la),
			XP = xp,
			CombatModel = combatModel,
		}
		end
	end
	logUi(('pickCards input=%d output=%d'):format(#animals, #out))
	for i, row in ipairs(out) do
		logUi(('pickCards card[%d] name=%s'):format(i, tostring(row.Title)))
	end
	return out
end

-- Validate + dedupe a result payload. Returns (accept, key):
-- non-RaidEnd payloads are ignored; a repeated completion token
-- (SessionId) is ignored (one screen per raid). Pure.
local function acceptResult(payload: any, lastSession: string?): (boolean, string?)
	if type(payload) ~= 'table' then
		return false, nil
	end
	if payload.Action ~= 'RaidEnd' then
		return false, nil
	end
	if payload.Success == false then
		return false, nil
	end
	local key: string? = nil
	if payload.SessionId ~= nil then
		key = tostring(payload.SessionId)
	end
	if key ~= nil and key == lastSession then
		return false, nil
	end
	return true, key
end

-- Compact integer for gain displays ("240", "10K", "1.2M").
-- Shared by the legacy XP text and the gain text below.
local function compactCount(value: any): string
	local n = tonumber(value) or 0
	if n ~= n or n < 0 then
		n = 0
	end
	local text: string? = nil
	pcall(function()
		local formatted = BigNumber.Format(tostring(math.floor(n)))
		if type(formatted) == 'string' and formatted ~= '' then
			text = formatted
		end
	end)
	if text == nil then
		text = tostring(math.floor(n))
	end
	return text :: string
end

local function formatXP(xp: any): string
	return 'XP ' .. compactCount(xp)
end

-- Level GAIN display for the card `Level` field (NOT the final
-- level): "+ 3 Levels" for 40 -> 43, "+ 0 Levels" when the level
-- did not change. levelBefore/levelAfter are the authoritative
-- snapshot values (already floored ints from pickCards).
local function levelGainText(levelBefore: any, levelAfter: any): string
	local before = math.floor(tonumber(levelBefore) or 1)
	local after = math.floor(tonumber(levelAfter) or before)
	local gain = after - before
	if gain ~= gain or gain < 0 then
		gain = 0
	end
	return ('+ %d Levels'):format(gain)
end

-- XP GAIN display for the card `XP` field (the actual XP delta
-- committed by Arena settlement for THIS run — never lifetime
-- totals): "+240 XP", "+10K XP".
local function xpGainText(xpGained: any): string
	return '+' .. compactCount(xpGained) .. ' XP'
end

-- Synchronous cheap paint (text only — never blocks opening).
local function paintText(payload: any, rows: { { [string]: any } })
	setText(nameLabel, outcomeMessage(payload.Outcome, payload.RaidComplete))
	local wave = waveText(payload.Stage, payload.MaxStage)
	if wave ~= nil then
		local node = waveNode
		if node ~= nil then
			pcall(function()
				if (node :: Instance):IsA('TextLabel') or (node :: Instance):IsA('TextButton') then
					((node :: Instance) :: TextLabel).Text = wave :: string
				end
			end)
		end
	end
	-- Canonical reward field: EarnedCash (BigNumber decimal string
	-- committed by server settlement for THIS run — never the
	-- wallet balance, never client-computed). Normalized ONCE here;
	-- every line below uses rewardCash, never payload.* variants.
	local rewardCash = payload.EarnedCash
	if type(rewardCash) ~= 'string' then
		warnUi(('missing EarnedCash in result payload (session=%s); showing $0'):format(tostring(payload.SessionId)))
		rewardCash = '0'
	end
	local money = moneyNode
	if money ~= nil then
		pcall(function()
			if (money :: Instance):IsA('TextLabel') or (money :: Instance):IsA('TextButton') then
				((money :: Instance) :: TextLabel).Text = moneyText(rewardCash)
			end
		end)
	end
	for i, card in ipairs(cards) do
		local row = rows[i]
		pcall(function()
			if row == nil then
				-- Stale guard: hide AND blank the row so a
				-- previous run's text can never resurface.
				(card.root :: GuiObject).Visible = false
				setText(card.title, '')
				setText(card.rarity, '')
				setText(card.currentLevel, '')
				setText(card.newLevel, '')
				setText(card.level, '')
				setText(card.xp, '')
				return
			end
			(card.root :: GuiObject).Visible = true
			setText(card.title, row.Title)
			paintRarity(card.rarity, row.Rarity)
			local beforeText = levelText(row.LevelBefore)
			local afterText = levelText(row.LevelAfter)
			setText(card.currentLevel, beforeText)
			setText(card.newLevel, afterText)
			logUi(('SET CurrentLevel row=%d value=%s'):format(i, beforeText))
			logUi(('SET NewLevel row=%d value=%s'):format(i, afterText))
			-- `Level` is the LEVEL GAIN ("+ 3 Levels"), never the
			-- final level. `XP` is the RUN XP DELTA ("+240 XP"),
			-- never the lifetime total. Both come straight from
			-- the committed snapshot row.
			setText(card.level, levelGainText(row.LevelBefore, row.LevelAfter))
			setText(card.xp, xpGainText(row.XP))
		end)
	end
	-- Egg entries are cheap text clones (no models exist
	-- client-side): safe to build synchronously. Missing template
	-- or entries both degrade to the NoEggs state, never an error.
	clearEggEntries()
	local count = 0
	pcall(function()
		local scrolling = eggsScrolling
		local template = eggsTemplate
		if scrolling ~= nil and template ~= nil and type(payload.Eggs) == 'table' then
			for _, entry in ipairs(payload.Eggs) do
				if type(entry) == 'table' then
					local n = tonumber(entry.Count) or 1
					if n ~= n or n < 1 then
						n = 1
					end
					local clone = ((template :: GuiObject):Clone()) :: GuiObject
					clone.Name = 'EggEntry'
					local counter = clone:FindFirstChild('Counter')
					if counter ~= nil and (counter:IsA('TextLabel') or counter:IsA('TextButton')) then
						((counter :: Instance) :: TextLabel).Text = ('x%d'):format(math.floor(n))
					end
					local vp = clone:FindFirstChild('ViewportFrame')
					if vp ~= nil and vp:IsA('ViewportFrame') then
						(vp :: ViewportFrame).Visible = false
					end
					clone.Visible = true
					clone.Parent = scrolling
					count += 1
				end
			end
			(template :: GuiObject).Visible = false
		end
	end)
	pcall(function()
		if eggsNoEggs ~= nil then
			(eggsNoEggs :: GuiObject).Visible = (count == 0)
		end
	end)
	logUi(
		('painted outcome=%s cards=%d eggs=%d Money=%s'):format(
			tostring(payload.Outcome or payload.RaidComplete),
			#rows,
			count,
			moneyText(rewardCash)
		)
	)
end

-- Deferred expensive work: per-card viewport clones via the shared
-- AnimalViewport.RenderModel entry-point (the SAME renderer the
-- Sell confirmation preview uses: clone + strip + presentation +
-- WorldModel + camera). Runs AFTER the panel is already visible.
-- Generation-guarded: a replaced or closed result aborts before
-- touching any viewport.
local function fillViewports(gen: number, rows: { { [string]: any } })
	for i, card in ipairs(cards) do
		if pendingGeneration ~= gen then
			return
		end
		local row = rows[i]
		if row == nil or card.viewport == nil then
			continue
		end
		logUi(
			('viewport slot=%d name=%s defId=%s rarity=%s trait=%s'):format(
				i,
				tostring(row.Title),
				tostring(row.DefinitionId),
				tostring(row.Rarity),
				tostring(row.Trait)
			)
		)
		if row.CombatModel == nil then
			warnUi(
				('[ArenaResultModel] ERROR missing live combat model slot=%d name=%s session-uid=%s (viewport stays empty)'):format(
					i,
					tostring(row.Title),
					tostring(row.UniqueId)
				)
			)
			continue
		end
		-- Source: the captured ACTUAL combat model — the single
		-- source of truth. There is deliberately NO stand-model
		-- fallback and NO ServerStorage/template reconstruction
		-- anywhere here: a wrong animal is worse than a visibly
		-- flagged empty viewport.
		local sourceRef = row.CombatModel
		logUi(('viewport slot=%d source=combat keepsake=FOUND'):format(i))
		if pendingGeneration ~= gen then
			return
		end
		pcall(function()
			if pendingGeneration ~= gen then
				return
			end
			local source = sourceRef :: Model
			-- Geometry proof (see header: a hierarchy without visible
			-- parts is an empty shell). Count BEFORE render.
			local preParts, preMesh, preDesc = 0, 0, 0
			pcall(function()
				preDesc = #source:GetDescendants()
				for _, desc in ipairs(source:GetDescendants()) do
					if desc:IsA('BasePart') and desc.Transparency <= 0.999 then
						preParts += 1
						if desc:IsA('MeshPart') then
							preMesh += 1
						end
					end
				end
			end)
			local sourcePath = 'unknown'
			pcall(function()
				sourcePath = source:GetFullName()
			end)
			logUi(
				('viewport slot=%d source=%s sourceClass=%s sourcePath=%s descendants=%d visibleParts=%d meshParts=%d'):format(
					i,
					source.Name,
					source.ClassName,
					sourcePath,
					preDesc,
					preParts,
					preMesh
				)
			)
			-- Shared renderer (same entry-point as the Sell
			-- preview): clone + strip + presentation + WorldModel
			-- + camera in one step. No aura/outline: the clone
			-- renders with its original appearance only.
			local shown = AnimalViewport.RenderModel(card.viewport :: ViewportFrame, source)
			if shown == nil then
				warnUi(('viewport slot=%d RENDER_FAILED (clone/fit failed, viewport left empty)'):format(i))
				return
			end
			if pendingGeneration ~= gen then
				AnimalViewport.ClearViewport(card.viewport :: ViewportFrame)
				return
			end
			-- Geometry proof AFTER render: if preParts > 0 and this
			-- is 0, the strip step ate the visible geometry (wrong
			-- source level or over-aggressive strip for this asset).
			local postParts = 0
			pcall(function()
				for _, desc in ipairs((shown :: Model):GetDescendants()) do
					if desc:IsA('BasePart') and desc.Transparency <= 0.999 then
						postParts += 1
					end
				end
			end)
			logUi(('viewport slot=%d visiblePartsAfterStrip=%d'):format(i, postParts))
			if postParts == 0 then
				if preParts > 0 then
					warnUi(('viewport slot=%d STRIP_REMOVED_ALL_GEOMETRY preParts=%d'):format(i, preParts))
				else
					warnUi(('viewport slot=%d SOURCE_HAS_NO_GEOMETRY (wrong source level?)'):format(i))
				end
			end
			logUi(('viewport slot=%d rendered=true'):format(i))
		end)
	end
end

local function onContinue()
	-- Local-only close: rewards were finalized server-side before
	-- the payload was sent. close() is idempotent, so Continue
	-- spam can never double-trigger anything. The Start menu stays
	-- hidden — only a fresh NPC interaction reopens it.
	logArenaUi('continue -> HIDDEN')
	close()
end

local function wireButtons()
	if buttonsWired then
		return
	end
	buttonsWired = true
	if continueButton ~= nil then
		local button = continueButton
		pcall(function()
			-- Both click signals: an inner covering label can
			-- swallow one of them depending on authoring.
			button.Activated:Connect(onContinue)
			button.MouseButton1Click:Connect(onContinue)
		end)
	else
		warnUi('Continue button missing in template')
	end
end

-- Populate + show one finalized result. Assumes close() already
-- ran. Visible FIRST, text sync, viewports deferred. Returns true
-- when the GUI opened.
local function openFromPayload(payload: any, key: string?): boolean
	if not ensureGui() then
		return false
	end
	wireButtons()
	pendingGeneration += 1
	local gen = pendingGeneration
	pendingSession = key
	local rows = pickCards(payload.Animals)
	paintText(payload, rows)
	local fr = frame
	if fr ~= nil then
		pcall(function()
			MenuPresentation.Open(fr)
		end)
	end
	ArenaUIState.SetResultOpen(true, key)
	logUi(('opened session=%s'):format(tostring(key)))
	-- Render proof: one line per painted slot. `cards` is the
	-- authored GUI capacity; if the payload holds MORE animals
	-- than slots, the overflow is undisplayable — warn loudly
	-- (this is the signature of a "payload correct, GUI short"
	-- single-card bug).
	if #rows > #cards then
		warnUi(
			('SLOT SHORTAGE session=%s rows=%d slots=%d — payload has more animals than GUI card slots'):format(
				tostring(key),
				#rows,
				#cards
			)
		)
	end
	for index, row in ipairs(rows) do
		-- NOTE: this client never clones card templates; it paints
		-- the authored fixed slots (`cards`). "rendered card" below
		-- means slot `index` was painted with this participant.
		if index <= #cards then
			logUi(('rendered card=%d name=%s'):format(index, tostring(row.Title)))
		else
			logUi(('DROPPED card (no GUI slot) index=%d name=%s'):format(index, tostring(row.Title)))
		end
	end
	logArenaUi(
		('result snapshot session=%s outcome=%s participants=%d'):format(
			tostring(key),
			tostring(payload.Outcome),
			#rows
		)
	)
	logArenaUi(
		('money=%s wave=%s'):format(tostring(payload.EarnedCash), tostring(waveText(payload.Stage, payload.MaxStage)))
	)
	for index, row in ipairs(rows) do
		logArenaUi(('row=%d title=%s rarity=%s'):format(tostring(index), tostring(row.Title), tostring(row.Rarity)))
		logArenaUi(
			('row=%d before=%s after=%s levelText="%s" xpText="%s"'):format(
				index,
				tostring(row.LevelBefore),
				tostring(row.LevelAfter),
				levelGainText(row.LevelBefore, row.LevelAfter),
				xpGainText(row.XP)
			)
		)
	end
	-- Expensive viewport clones happen here — strictly after the
	-- panel is visible, never gating it.
	task.defer(function()
		fillViewports(gen, rows)
	end)
	return true
end

local function onResult(payload: any)
	if type(payload) ~= 'table' then
		return
	end
	local accept, key = acceptResult(payload, pendingSession)
	if not accept then
		return
	end
	logUi(
		('received session=%s outcome=%s rewardCash=%s'):format(
			tostring(key),
			tostring(payload.Outcome),
			tostring(payload.EarnedCash)
		)
	)
	-- Receipt proof: EVERY received animal logged with identity
	-- (count alone could hide a wrong-animal bug). Compare with
	-- the server's [ArenaResultPayload] lines for the same
	-- session: mismatch here means remote/serialization loss.
	local received = if type(payload.Animals) == 'table' then payload.Animals else {}
	logUi(('client receivedAnimals=%d session=%s'):format(#received, tostring(key)))
	for i, entry in ipairs(received) do
		if type(entry) == 'table' then
			logUi(
				('client animal[%d] uid=%s name=%s session=%s'):format(
					i,
					tostring(entry.UniqueId),
					tostring(entry.DisplayName),
					tostring(key)
				)
			)
		end
	end
	logArenaUi(('result received session=%s outcome=%s'):format(tostring(key), tostring(payload.Outcome)))
	-- One controlled instance: a new result safely closes/cleans
	-- any previous screen first (never stacked, never cloned twice).
	close()
	if openFromPayload(payload, key) then
		return
	end
	-- Replication race (Main/ArenaResult not yet replicated): ONE
	-- bounded retry on our template path only — never MainGui,
	-- never another controller. A newer result aborts this retry
	-- via the pending-session check.
	warnUi('ArenaResult template missing; single bounded retry')
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
			if main:WaitForChild('ArenaResult', EAGER_TEMPLATE_WAIT_S) == nil then
				return
			end
		end)
		if not ok then
			return
		end
		if pendingSession ~= nil then
			return
		end
		close()
		openFromPayload(payload, key)
	end)
end

function ArenaResultController.Init()
	if wired then
		return
	end
	wired = true
	if localPlayer == nil then
		warnUi('no LocalPlayer; controller disabled')
		return
	end
	local folder = Remotes.WaitForReady()
	local okResult, resultEvent = pcall(function()
		return folder:WaitForChild(Remotes.Names.ArenaResult, 10)
	end)
	if okResult and resultEvent ~= nil and (resultEvent :: Instance):IsA('RemoteEvent') then
		pcall(function()
			(resultEvent :: RemoteEvent).OnClientEvent:Connect(onResult)
		end)
	else
		warnUi('ArenaResult remote missing; results disabled')
	end
	-- Hide the template if already present (never flash on join).
	-- Respawn cleanup below re-hides after resets.
	pcall(function()
		if ensureGui() then
			wireButtons()
		end
	end)
	-- Eager, INDEPENDENT readiness: one bounded wait on OUR
	-- template path only (PlayerGui.Main.ArenaResult) so the
	-- controller is armed before the first RaidEnd can fire.
	-- Never MainGui, never another controller; non-blocking
	-- (spawned), single-shot.
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
			if main:WaitForChild('ArenaResult', EAGER_TEMPLATE_WAIT_S) == nil then
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
function ArenaResultController._TestReset()
	pendingSession = nil
	pendingGeneration = 0
end

function ArenaResultController._TestOutcomeMessage(outcome: any, raidComplete: any): string
	return outcomeMessage(outcome, raidComplete)
end

function ArenaResultController._TestLevelText(level: any): string
	return levelText(level)
end

function ArenaResultController._TestMoneyText(raw: any): string
	return moneyText(raw)
end

function ArenaResultController._TestFormatXP(xp: any): string
	return formatXP(xp)
end

function ArenaResultController._TestLevelGainText(levelBefore: any, levelAfter: any): string
	return levelGainText(levelBefore, levelAfter)
end

function ArenaResultController._TestXpGainText(xpGained: any): string
	return xpGainText(xpGained)
end

function ArenaResultController._TestWaveText(stage: any, maxStage: any): string?
	return waveText(stage, maxStage)
end

function ArenaResultController._TestAcceptResult(payload: any, lastSession: string?): (boolean, string?)
	return acceptResult(payload, lastSession)
end

function ArenaResultController._TestPickCards(animals: any): { { [string]: any } }
	return pickCards(animals)
end

function ArenaResultController._TestResolveLevelLabel(cardRoot: Instance?, name: string): Instance?
	return findLevelTitle(cardRoot, name)
end

return table.freeze(ArenaResultController)
