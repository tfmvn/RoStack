--!strict
--!native
--[[
	TutorialController
	====================
	Client-side presentation for the server-authoritative
	TutorialService. Display ONLY: the server owns step,
	identity chain, and persistence; this module renders:

	  * HUD.Tutorial instruction text with a typewriter effect
	    (the Studio-authored HUD element — NEVER created here,
	    only written; cleared/hidden when done)
	  * HUD.TutorialSteps quest checklist (one row per actual
	    tutorial step), built once from the Studio-authored
	    Step1 template row
	    (Title counter, checkmarks, strikethrough, animations)
	  * one tutorial beam from the player character to the
	    exact current target (asset 17476697388 when it
	    provides a Beam, else a procedural white Beam)
	  * one WHITE Highlight on the real target instance
	    (pulsed via TweenService)
	  * temporary emphasis inside EXISTING UI (a dimmer
	    Frame parented into the existing Arena root + a
	    pulsing ring/spotlight on the REAL button — the Arena
	    buttons AND the real stand UpgradeButton on the
	    upgrade step — never a separate Tutorial GUI)
	  * HUD.TutorialSkip wiring (fires the gated server Skip
	    intent; visibility follows tutorial activity)

	It never advances tutorial state itself (except reporting
	the locally-observed Arena Continue press and the Skip
	press through gated TutorialAction intents — the server
	accepts them only while IT holds a matching state).

	All Studio lookups are defensive (nil-safe); missing UI
	degrades gracefully rather than errors. On Completed (or
	Skip) every visual is destroyed, sounds/tasks stopped, and
	every connection disconnected.
]]

local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local RunService = game:GetService('RunService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local CollectionService = game:GetService('CollectionService')
local TweenService = game:GetService('TweenService')
local Debris = game:GetService('Debris')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
-- Canonical stand-shape resolver (flat runtime clones, nested
-- authored stands, legacy menu shapes). Client-safe pure
-- instance walking — the upgrade highlight resolves the REAL
-- stand button through this instead of assuming one GUI path.
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local HudTree = require(script.Parent.HudTree)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local RarityDefs = require(ReplicatedStorage.Config.Creatures.Rarity)

local TutorialController = {}

local TAG = 'TutorialTarget'

-- Per-player tag subscription: CollectionService tags replicate
-- globally, so subscribing to the shared prefix would beam at
-- OTHER players' tracked eggs/animals (last-tagged wins). Each
-- client follows ONLY its own 'TutorialTarget_<userId>' tag,
-- which the server moves between that player's models.
local function _tagNameFor(userId: number?): string
	if userId ~= nil then
		return TAG .. '_' .. tostring(userId)
	end
	return TAG
end

local function _tagName(): string
	local id: number? = nil
	pcall(function()
		local player = Players.LocalPlayer
		if player ~= nil then
			id = (player :: Player).UserId
		end
	end)
	return _tagNameFor(id)
end
local TEMPLATE_NAME = 'TutorialBeamTemplate'
local WHITE = Color3.new(1, 1, 1)

local STEP_TEXT: { [string]: string } = {
	BuyEgg = 'Go buy an egg!',
	WaitForEgg = 'Wait for your egg to reach your base!',
	HatchEgg = 'Hatch the egg!',
	PickUpAnimal = 'Pick up your animal!',
	PlaceAnimal = 'Place your animal in an Arena slot!',
	StartArena = 'Start an Arena!',
	ArenaStarted = 'Arena in progress — good luck!',
	ArenaEnded = 'Arena complete! Continue.',
	UpgradeAnimal = 'Upgrade your animal!',
	LockBase = 'Lock your base!',
}

-- Deterministic tutorial egg target (multiplayer-safe): the
-- canonical STARTER rarity from EggConfig (cheapest price, NOT
-- hardcoded, NOT the nearest/global ActiveEgg). Every player's
-- client highlights the nearest starter-rarity egg; once THEY
-- buy, the server tracks their own actual EggId per player, so
-- players never share a tutorial target. Memoized: config is
-- static per session.
local _starterRarity: string? = nil
local function _getStarterRarity(): string?
	if _starterRarity ~= nil then
		return _starterRarity
	end
	pcall(function()
		_starterRarity = EggConfig.GetStarterRarity()
	end)
	if type(_starterRarity) ~= 'string' or (_starterRarity :: string) == '' then
		_starterRarity = nil
		pcall(function()
			_starterRarity = RarityDefs.Order[1]
		end)
	end
	return _starterRarity
end

-- Player-facing display name of the starter egg
-- ('Common Egg'): the same RarityDisplayName the spawn system
-- stamps on Model.Name, so target matching is by equality.
local function _starterDisplayName(): string
	local rarity = _getStarterRarity()
	local display: string? = nil
	pcall(function()
		if rarity ~= nil then
			display = RarityDefs.RarityDisplayName[rarity]
		end
	end)
	if type(display) == 'string' and display ~= '' then
		return display
	end
	if rarity ~= nil then
		return (rarity :: string) .. ' Egg'
	end
	return 'egg'
end

local function _buyEggText(): string
	local display = _starterDisplayName()
	if display ~= 'egg' then
		return 'Go buy a ' .. display .. '!'
	end
	return STEP_TEXT.BuyEgg
end

-- Player-facing quest checklist (presentation ONLY — the
-- server state machine is untouched). One row per ACTUAL
-- tutorial step, in state-machine order: a row completes the
-- moment the authoritative step moves past it. Nothing is
-- hardcoded to a fixed count — the row count follows this
-- table, and adding a future step is a row-table edit.
local CHECKLIST_STEPS: { { Step: string, Text: string } } = {
	{ Step = 'BuyEgg', Text = 'Buy an egg' },
	{ Step = 'WaitForEgg', Text = 'Egg reaches your base' },
	{ Step = 'HatchEgg', Text = 'Hatch your egg' },
	{ Step = 'PickUpAnimal', Text = 'Pick up your animal' },
	{ Step = 'PlaceAnimal', Text = 'Place your animal' },
	{ Step = 'StartArena', Text = 'Start an arena' },
	{ Step = 'ArenaStarted', Text = 'Fight in the arena' },
	{ Step = 'ArenaEnded', Text = 'Finish the arena' },
	{ Step = 'UpgradeAnimal', Text = 'Upgrade your animal' },
	{ Step = 'LockBase', Text = 'Lock your base' },
}

-- Derive presentation state from an authoritative step.
-- Pure: returns { Count, Total, Done: {bool}, Current: number? }.
-- The current step's own row is current; earlier rows are
-- done; Completed checks everything. Unknown steps behave
-- like a fresh tutorial rather than erroring.
local function _checklistFor(step: any): any
	local total = #CHECKLIST_STEPS
	local index: number? = nil
	pcall(function()
		if type(step) == 'string' then
			for i, row in ipairs(CHECKLIST_STEPS) do
				if row.Step == step then
					index = i
					break
				end
			end
		end
	end)
	local count = total
	local done: { boolean } = {}
	if index == nil then
		if step == 'Completed' then
			for i = 1, total do
				done[i] = true
			end
			return { Count = total, Total = total, Done = done, Current = nil }
		end
		for i = 1, total do
			done[i] = false
		end
		return { Count = 0, Total = total, Done = done, Current = 1 }
	end
	count = (index :: number) - 1
	for i = 1, total do
		done[i] = i < (index :: number)
	end
	return { Count = count, Total = total, Done = done, Current = index }
end

-- Cinematic instruction phases per step: { {Text, Beam:boolean,
-- Hold:number} }. Single-phase steps type once with full
-- visuals; UpgradeAnimal breathes first (words only), then
-- guides. Never throws by construction (validated on read).
local STEP_SCRIPT: { [string]: { any } } = {
	UpgradeAnimal = {
		{ Text = "Okay, let's get your animal an upgrade!", Beam = false, Hold = 2 },
		{ Text = 'Upgrade your animal!', Beam = true, Hold = 0 },
	},
}

local _snapshot: any = nil
local _tagInstance: Instance? = nil
local _beam: Beam? = nil
local _beamPlayerAttachment: Attachment? = nil
local _beamTargetAttachment: Attachment? = nil
local _highlight: Highlight? = nil
local _dimmer: Frame? = nil
local _buttonRing: UIStroke? = nil
-- Spotlight target-button state. Everything here is
-- tutorial-owned layering state reverted on teardown: the
-- real button's persistent properties are never changed.
local _spotlightButton: GuiButton? = nil
local _spotScale: UIScale? = nil
local _spotScaleOwned = false
local _spotScaleBase = 1
local _spotZOriginal: number? = nil
-- Ancestor chain lifted above the dimmer (Sibling
-- ZIndexBehavior compares siblings only, so a nested
-- button like RightSide.Continue stays buried unless its
-- parents are lifted too). Restored on teardown.
local _spotChain: { GuiObject } = {}
local _spotChainZ: { number } = {}
-- Center-pivot state: UIScale grows from the button's
-- AnchorPoint, so an authored (0, 0) button expands toward
-- the bottom-right. We pivot to (0.5, 0.5) (position
-- compensated so nothing visibly moves) and restore both.
local _spotAnchorOriginal: Vector2? = nil
local _spotPosOriginal: UDim2? = nil
local _spotPulseTween: Tween? = nil
local _spotGlowTween: Tween? = nil
-- UI-open beat tracking (two-beat instruction timing).
local _uiBeatStep: string? = nil
local _uiBeatSince: number? = nil
local _conn: RBXScriptConnection? = nil
local _remoteConn: RBXScriptConnection? = nil
local _tagAddedConn: RBXScriptConnection? = nil
local _tagRemovedConn: RBXScriptConnection? = nil
local _charConn: RBXScriptConnection? = nil
local _shopTarget: Model? = nil
-- Last logged BuyEgg target (instance) + last logged absence
-- key: the [TutorialEgg] target line fires on acquisition
-- only, never per paint tick. (Logger defined after the
-- starter/display helpers it reads, next to _findStarterEgg.)
local _loggedShopTarget: Model? = nil
local _loggedShopAbsent = false
local _beamTargetKey: string? = nil
local _accum = 0
local _continueSent = false
local _tornDown = false
local _warned: { [string]: boolean } = {}
local _beamSourceLogged = false
-- True while the live beam is a clone of asset 17476697388
-- (false = procedural fallback). Lets a late-replicating
-- template UPGRADE a fallback beam instead of losing to it.
local _beamIsAsset = false
-- Checklist runtime (built once from the Step1 template).
local _checklistRows: { GuiObject } = {}
local _checklistClones: { [GuiObject]: boolean } = {}
local _checklistOriginals: { [GuiObject]: any } = {}
local _rowPainted: { [GuiObject]: any } = {}
local _checklistUiScale: UIScale? = nil
local _checklistUiScaleCreated = false
local _checklistLayout: UIListLayout? = nil
-- Typewriter runtime (generation-guarded single task).
local _typeGen = 0
local _typeInterval = 0.03
local _typedKey: string? = nil
local _typedLabel: GuiObject? = nil
-- Client SFX template cache (validity-stamped; warn once).
local _sfxCache: { [string]: Sound? } = {}
local _sfxCacheValid: { [string]: boolean } = {}
local _sfxWarned: { [string]: boolean } = {}
-- Highlight pulse tween (one looped tween, cancelled on move).
local _highlightTween: Tween? = nil
local _pulseKey: string? = nil
-- Cinematic phase runtime.
local _cineStep: string? = nil
local _cinePhase = 1
local _cineUntil = 0
-- Skip wiring.
local _skipConn: RBXScriptConnection? = nil
local _skipWiredButton: GuiButton? = nil
local _skipArmed = false

local function _warnOnce(key: string, message: string)
	if _warned[key] then
		return
	end
	_warned[key] = true
	Debug.Warn('TS', message, {})
end

local function _localPlayer(): Player?
	local player: Player? = nil
	pcall(function()
		player = Players.LocalPlayer
	end)
	return player
end

-- --- HUD.Tutorial text (Studio-authored, never created here) -------------

-- Resolve the Studio-authored instruction label. Canonical path
-- is HUD.Top.Tutorial.Steps (the single visible instruction);
-- legacy flat HUD.Tutorial accepted as fallback. Accepts a
-- TextLabel/TextButton/TextBox directly, or a container holding
-- one (direct child first, then deepest search). Never creates
-- anything. Never throws.
local function _findTutorialLabel(playerGuiRoot: Instance?): GuiObject?
	local found: GuiObject? = nil
	pcall(function()
		if typeof(playerGuiRoot) ~= 'Instance' then
			return
		end
		local steps = HudTree.TutorialSteps(playerGuiRoot)
		if steps ~= nil then
			found = steps
			return
		end
		local hud = (playerGuiRoot :: Instance):FindFirstChild('HUD')
		local node = hud and (hud :: Instance):FindFirstChild('Tutorial') or nil
		if node == nil then
			return
		end
		if node:IsA('TextLabel') or node:IsA('TextButton') or node:IsA('TextBox') then
			found = node :: GuiObject
			return
		end
		if node:IsA('GuiObject') then
			for _, child in ipairs((node :: Instance):GetChildren()) do
				if child:IsA('TextLabel') or child:IsA('TextButton') or child:IsA('TextBox') then
					found = child :: GuiObject
					return
				end
			end
			local deep = (node :: Instance):FindFirstChildWhichIsA('TextLabel', true)
				or (node :: Instance):FindFirstChildWhichIsA('TextButton', true)
				or (node :: Instance):FindFirstChildWhichIsA('TextBox', true)
			if deep ~= nil then
				found = deep
			end
		end
	end)
	return found
end

-- Own the full show contract for the Studio-authored label:
-- non-empty text is SHOWN (Visible=true — the authored
-- default is hidden), clearing the text hides it again.
-- Never creates anything. Never throws.
local function _setHudText(text: string?)
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local label = _findTutorialLabel(playerGui)
		if label == nil then
			_warnOnce('no-hud-tutorial', '[Tutorial] PlayerGui.HUD.Tutorial missing; instruction text unavailable')
			return
		end
		local content = text or ''
		local gui = label :: GuiObject
		if label:IsA('TextLabel') then
			(label :: TextLabel).Text = content
		elseif label:IsA('TextButton') then
			(label :: TextButton).Text = content
		elseif label:IsA('TextBox') then
			(label :: TextBox).Text = content
		else
			return
		end
		gui.Visible = content ~= ''
	end)
end

-- --- Tutorial sounds (client-readable assets only) ---------------------------

-- NOTE on naming: the request said `Assets.Sfc.Pop/Approved`,
-- but the project's real container is `Assets.Sfx.*` (all
-- Studio SFX live under ServerStorage.Assets.Sfx; bootstrap
-- section 5d mirrors the personal stings — Pop, Approved,
-- LevelUp — into ReplicatedStorage for clients at boot).
-- This resolver reads the client-visible copy only.
-- `rootOverride` is the headless-test seam (production passes
-- nil = live ReplicatedStorage). Never throws.
local function _resolveSfxTemplate(name: string, rootOverride: Instance?): Sound?
	local found: Sound? = nil
	pcall(function()
		if type(name) ~= 'string' or name == '' then
			return
		end
		local root: Instance? = rootOverride
		if root == nil then
			root = ReplicatedStorage:FindFirstChild('Assets')
		end
		local sfx = root and (root :: Instance):FindFirstChild('Sfx') or nil
		local node = sfx and (sfx :: Instance):FindFirstChild(name) or nil
		if node ~= nil and (node :: Instance):IsA('Sound') then
			local sound = node :: Sound
			if sound.SoundId ~= '' then
				found = sound
			end
		end
	end)
	if found == nil then
		local key = 'sfx:' .. tostring(name)
		if not _sfxWarned[key] then
			_sfxWarned[key] = true
			Debug.Warn('TS', 'tutorial sound template missing; silent', { sound = tostring(name) })
		end
	end
	return found
end

-- One-shot clone into PlayerGui (local-only presentation
-- sound). Never throws; silent no-op when the template or
-- PlayerGui is missing.
local function _playTutorialSound(name: string)
	pcall(function()
		local template = _resolveSfxTemplate(name, nil)
		if template == nil then
			return
		end
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local clone = (template :: Sound):Clone()
		clone.Name = 'Tutorial' .. tostring(name) .. 'Sfx'
		clone.Looped = false
		clone.PlayOnRemove = false
		clone.Parent = playerGui
		clone:Play()
		Debris:AddItem(clone, 3)
	end)
end

-- --- Beam ------------------------------------------------------------------

-- Procedural white fallback beam (used when the asset template
-- is absent or carries no Beam). Returns the Beam unparented;
-- the caller wires attachments. Never throws.
function TutorialController.BuildFallbackBeam(): Beam?
	local beam: Beam? = nil
	pcall(function()
		local made = Instance.new('Beam')
		made.Name = 'TutorialBeam'
		made.Color = ColorSequence.new(WHITE)
		made.Width0 = 0.6
		made.Width1 = 0.6
		made.FaceCamera = true
		made.LightEmission = 0.4
		beam = made
	end)
	return beam
end

-- Attachment helper: exactly one named Attachment parented to
-- `host` (reuses the live one). Never throws.
function TutorialController.EnsureAttachment(host: Instance?, name: string): Attachment?
	local attachment: Attachment? = nil
	pcall(function()
		if typeof(host) ~= 'Instance' then
			return
		end
		local existing = (host :: Instance):FindFirstChild(name)
		if existing ~= nil and existing:IsA('Attachment') then
			attachment = existing
			return
		end
		local made = Instance.new('Attachment')
		made.Name = name
		made.Parent = host
		attachment = made
	end)
	return attachment
end

-- Locate a Beam anywhere inside the replicated asset template
-- (whatever the asset's internal structure is). Never throws.
local function _findTemplateBeam(): Beam?
	local found: Beam? = nil
	pcall(function()
		local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
		if template == nil then
			return
		end
		if (template :: Instance):IsA('Beam') then
			found = template :: Beam
			return
		end
		local deep = (template :: Instance):FindFirstChildWhichIsA('Beam', true)
		if deep ~= nil then
			found = deep
		end
	end)
	return found
end

-- Character anchor for the player end of the beam (torso
-- first, root fallback). Never throws.
local function _playerAnchorPart(): BasePart?
	local part: BasePart? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local character = player.Character
		if character == nil then
			return
		end
		local torso = (character :: Instance):FindFirstChild('UpperTorso')
		if torso ~= nil and (torso :: Instance):IsA('BasePart') then
			part = torso :: BasePart
			return
		end
		local hrp = (character :: Instance):FindFirstChild('HumanoidRootPart')
		if hrp ~= nil and (hrp :: Instance):IsA('BasePart') then
			part = hrp :: BasePart
		end
	end)
	return part
end

local function _destroyBeam()
	pcall(function()
		if _beamPlayerAttachment ~= nil then
			(_beamPlayerAttachment :: Attachment):Destroy()
		end
	end)
	_beamPlayerAttachment = nil
	pcall(function()
		if _beamTargetAttachment ~= nil then
			(_beamTargetAttachment :: Attachment):Destroy()
		end
	end)
	_beamTargetAttachment = nil
	pcall(function()
		if _beam ~= nil then
			(_beam :: Beam):Destroy()
		end
	end)
	_beam = nil
	_beamIsAsset = false
	_beamTargetKey = nil
end

-- Ensure exactly one live beam exists. Prefers asset
-- 17476697388 whenever its template is available — including
-- UPGRADING a procedural fallback created before the template
-- replicated (the old code returned the fallback forever once
-- built, so late replication never took effect).
-- Reports which path was taken. Never throws.
local function _ensureBeam(): Beam?
	local current = _beam
	if current ~= nil and (current :: Instance).Parent ~= nil then
		if _beamIsAsset then
			return current
		end
		if _findTemplateBeam() == nil then
			return current
		end
		_destroyBeam()
		Debug.Log('TS', 'asset tutorial beam 17476697388 replicated late; upgrading fallback beam')
	end
	pcall(function()
		local templateBeam = _findTemplateBeam()
		local beam: Beam? = nil
		if templateBeam ~= nil then
			local clone = (templateBeam :: Beam):Clone()
			clone.Name = 'TutorialBeam'
			clone.Parent = Workspace
			beam = clone
			_beamIsAsset = true
			if not _beamSourceLogged then
				_beamSourceLogged = true
				Debug.Log('TS', 'using asset tutorial beam 17476697388')
			end
		else
			-- Loud (print, not gated Debug): a silent fallback
			-- is what hid the missing asset last time. Report
			-- what the template actually is so Studio output
			-- names the problem.
			local templateClass: string? = nil
			pcall(function()
				local template = ReplicatedStorage:FindFirstChild(TEMPLATE_NAME)
				if template ~= nil then
					templateClass = (template :: Instance).ClassName
				end
			end)
			beam = TutorialController.BuildFallbackBeam()
			local fallback = beam
			if fallback ~= nil then
				fallback.Parent = Workspace
			end
			if not _beamSourceLogged then
				_beamSourceLogged = true
				Debug.Log('TS', 
						tostring(templateClass)
					)
			end
		end
		_beam = beam
	end)
	return _beam
end

-- --- White highlight ---------------------------------------------------------

local function _ensureHighlight(): Highlight?
	local current = _highlight
	if current ~= nil and (current :: Instance).Parent ~= nil then
		return current
	end
	pcall(function()
		local highlight = Instance.new('Highlight')
		highlight.Name = 'TutorialHighlight'
		highlight.FillColor = WHITE
		highlight.FillTransparency = 0.75
		highlight.OutlineColor = WHITE
		highlight.OutlineTransparency = 0
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		_highlight = highlight
	end)
	return _highlight
end

local function _setHighlightTarget(inst: Instance?)
	pcall(function()
		local highlight = _ensureHighlight()
		if highlight == nil then
			return
		end
		local hl = highlight :: Highlight
		local usable = typeof(inst) == 'Instance'
			and (inst :: Instance).Parent ~= nil
			and ((inst :: Instance):IsA('Model') or (inst :: Instance):IsA('BasePart'))
		if usable then
			hl.Adornee = inst
			hl.Parent = inst
			hl.Enabled = true
		else
			hl.Enabled = false
		end
	end)
end

local function _destroyHighlight()
	pcall(function()
		if _highlight ~= nil then
			(_highlight :: Highlight):Destroy()
		end
	end)
	_highlight = nil
end

-- --- World target resolution (instances, not positions) -----------------------

local function _characterRoot(): Vector3?
	local pos: Vector3? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local character = player.Character
		if character == nil then
			return
		end
		local hrp = (character :: Instance):FindFirstChild('HumanoidRootPart')
		if hrp ~= nil and (hrp :: Instance):IsA('BasePart') then
			pos = ((hrp :: Instance) :: BasePart).Position
		end
	end)
	return pos
end

-- Slot-anchored classification (SAME principle as animals).
-- Verified egg runtime structure: ActiveEggs is the canonical
-- parent for ALL egg models (center, slot-placed, recovered —
-- see SpawnService.GetActiveContainer), so folder membership
-- alone can NEVER tell a global egg from a base egg. The
-- slot relationship is stamped on the prompts instead:
--   * center/global egg -> live BuyPrompt on the model
--     (Available: no purchaser; Traveling: purchaserUserId
--     stamped; arrival wipes prompts);
--   * base-placed egg -> BuyPrompt wiped, PickupPrompt +
--     HatchPrompt installed WITH ownerUserId via
--     InstallHatchPrompt(slot, ownerUserId) — that owner's
--     base Slot owns the egg;
--   * carried egg -> reparented out of ActiveEggs entirely.
-- So: BuyPrompt = global spawn-area egg; Pickup/Hatch =
-- base Slot egg (excluded); neither = transitional (excluded).
-- Scope is LOCKED to direct Model children of the passed
-- folder — a nested Base folder can never leak in.
local _scanStats = { seen = 0, starter = 0, base = 0, noprompt = 0, own = 0, disabled = 0, contested = 0 }

local function _findStarterInFolder(folder: Instance, here: Vector3?, userId: number?): Model?
	local found: Model? = nil
	local foundFree: Model? = nil
	pcall(function()
		local displayName = _starterDisplayName()
		local rarity = _getStarterRarity()
		local best = math.huge
		local bestFree = math.huge
		local stats = { seen = 0, starter = 0, base = 0, noprompt = 0, own = 0, disabled = 0, contested = 0 }
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA('Model') then
				local model = child :: Model
				stats.seen += 1
				-- Base Slot eggs first: Pickup/Hatch prompts (with
				-- ownerUserId) mean a base Slot owns this egg.
				-- NEVER a tutorial target, whatever its name.
				local baseOwned = false
				pcall(function()
					baseOwned = model:FindFirstChild('PickupPrompt', true) ~= nil
						or model:FindFirstChild('HatchPrompt', true) ~= nil
				end)
				if baseOwned then
					stats.base += 1
					continue
				end
				local allowed = false
				pcall(function()
					if model.Name == displayName then
						allowed = true
					elseif rarity ~= nil then
						local maybe = string.match(model.Name, '^(%w+) Egg$')
						allowed = maybe == rarity
					end
				end)
				if not allowed then
					continue
				end
				stats.starter += 1
				-- Purchasable right now? Needs a live BuyPrompt.
				local prompt: ProximityPrompt? = nil
				pcall(function()
					local node = model:FindFirstChild('BuyPrompt', true)
					if node ~= nil and node:IsA('ProximityPrompt') then
						prompt = node
					end
				end)
				if prompt == nil or (prompt :: ProximityPrompt).Parent == nil then
					stats.noprompt += 1
					continue
				end
				if (prompt :: ProximityPrompt).Enabled == false then
					stats.disabled += 1
					continue
				end
				local purchaser: any = nil
				pcall(function()
					purchaser = (prompt :: ProximityPrompt):GetAttribute('purchaserUserId')
				end)
				if userId ~= nil and purchaser == userId then
					stats.own += 1
					continue
				end
				local free = purchaser == nil
				if not free then
					stats.contested += 1
				end
				if here == nil then
					if free and foundFree == nil then
						foundFree = model
					end
					if found == nil then
						found = model
					end
					if found ~= nil and foundFree ~= nil then
						break
					end
				else
					local pivotOk, pivot = pcall(function()
						return model:GetPivot()
					end)
					if pivotOk and pivot ~= nil then
						local d = ((pivot :: CFrame).Position - (here :: Vector3)).Magnitude
						if d < best then
							best = d
							found = model
						end
						if free and d < bestFree then
							bestFree = d
							foundFree = model
						end
					end
				end
			end
		end
		_scanStats = stats
	end)
	if foundFree ~= nil then
		return foundFree
	end
	return found
end

local function _findStarterEgg(): Model?
	local found: Model? = nil
	pcall(function()
		local area = Workspace:FindFirstChild('EggArea')
		local folder = area and (area :: Instance):FindFirstChild('ActiveEggs') or nil
		if folder == nil then
			return
		end
		local player = _localPlayer()
		local userId: number? = nil
		if player ~= nil then
			userId = (player :: Player).UserId
		end
		found = _findStarterInFolder(folder, _characterRoot(), userId)
	end)
	return found
end

-- Team-Test trace for the BuyEgg target: player identity +
-- starter definition + the target's FULL path, so a base
-- leak (`Workspace.Map.Bases...`) is obvious in output.
-- Fires on acquisition/change only; nil targets log once.
local function _logShopTarget(target: Model?)
	pcall(function()
		if target ~= nil and target == _loggedShopTarget and target.Parent ~= nil then
			return
		end
		_loggedShopTarget = target
		local who = '?'
		local player = _localPlayer()
		if player ~= nil then
			who = (player :: Player).Name
		end
		if target == nil or target.Parent == nil then
			if not _loggedShopAbsent then
				_loggedShopAbsent = true
				local stats = _scanStats
				Debug.Log('TutorialEgg', 
						who,
						_starterDisplayName(),
						stats.seen,
						stats.starter,
						stats.base,
						stats.noprompt,
						stats.own,
						stats.disabled,
						stats.contested
					)
			end
			return
		end
		_loggedShopAbsent = false
		Debug.Log('TutorialEgg', who, _starterDisplayName(), target:GetFullName())
	end)
end

local function _playerBaseFolder(): Instance?
	local folder: Instance? = nil
	pcall(function()
		if _snapshot == nil or type(_snapshot.BaseId) ~= 'string' then
			return
		end
		local map = Workspace:FindFirstChild('Map')
		local bases = map and (map :: Instance):FindFirstChild('Bases') or nil
		if bases == nil then
			bases = Workspace:FindFirstChild('Bases')
		end
		if bases == nil then
			return
		end
		folder = (bases :: Instance):FindFirstChild(_snapshot.BaseId)
	end)
	return folder
end

-- First renderable part under an instance (itself when it is
-- one). Never throws.
local function _firstPart(inst: Instance?): BasePart?
	local part: BasePart? = nil
	pcall(function()
		if typeof(inst) ~= 'Instance' then
			return
		end
		if (inst :: Instance):IsA('BasePart') then
			part = inst :: BasePart
			return
		end
		local deep = (inst :: Instance):FindFirstChildWhichIsA('BasePart', true)
		if deep ~= nil then
			part = deep
		end
	end)
	return part
end

local function _resolveArenaStand(): Instance?
	local stand: Instance? = nil
	pcall(function()
		if _snapshot == nil or type(_snapshot.SlotId) ~= 'string' then
			return
		end
		local index = tonumber(string.match(_snapshot.SlotId, ':(%d+)$'))
		if index == nil then
			return
		end
		local baseFolder = _playerBaseFolder()
		if baseFolder == nil then
			return
		end
		if index >= 1000 then
			local arena = (baseFolder :: Instance):FindFirstChild('ArenaAnimalStands')
			if arena ~= nil then
				stand = arena:FindFirstChild('ArenaStand' .. tostring(index - 1000))
			end
			return
		end
		local normal = (baseFolder :: Instance):FindFirstChild('AnimalStands')
		if normal ~= nil then
			stand = normal:FindFirstChild('Slot' .. tostring(index))
			if stand == nil then
				-- Authored (non-dynamic) bases nest the Slot
				-- under Stand<k> (spec §3 mapping); runtime
				-- clones ARE Slot<k>. Accept both.
				stand = normal:FindFirstChild('Stand' .. tostring(index))
			end
		end
	end)
	return stand
end

local function _resolveAdventurer(): Instance?
	local adv: Instance? = nil
	pcall(function()
		local baseFolder = _playerBaseFolder()
		if baseFolder == nil then
			return
		end
		-- 'Adv' is the short authored alias for the same
		-- role (ArenaService prefers full 'Adventurer').
		adv = (baseFolder :: Instance):FindFirstChild('Adventurer')
		if adv == nil then
			adv = (baseFolder :: Instance):FindFirstChild('Adv')
		end
		if adv == nil then
			adv = (baseFolder :: Instance):FindFirstChild('Adventurer', true)
		end
		if adv == nil then
			adv = (baseFolder :: Instance):FindFirstChild('Adv', true)
		end
	end)
	return adv
end

-- Upgrade MenuPart behind the tutorial animal's stand.
-- PRIMARY: the snapshot SlotId (the server publishes the LIVE
-- slot holding the tracked animal on the UpgradeAnimal step),
-- mapped to the stand exactly like PlaceAnimal, then resolved
-- through the canonical StandResolver (flat runtime clones,
-- nested authored stands, legacy shapes). FALLBACK: the old
-- tag-ancestor climb, kept so a misbuilt hierarchy limps
-- instead of losing the beam entirely. The beam aims here;
-- the ring (below) sits on the real button.
local function _resolveUpgradeMenuPart(): Instance?
	local menuPart: Instance? = nil
	pcall(function()
		local stand = _resolveArenaStand()
		if stand ~= nil and (stand :: Instance).Parent ~= nil then
			local ok, partsAny = pcall(StandResolver.GetStandParts, stand)
			if ok and type(partsAny) == 'table' then
				local mp = (partsAny :: any).menuPart
				if typeof(mp) == 'Instance' and (mp :: Instance).Parent ~= nil then
					menuPart = mp
					return
				end
			end
		end
		if _tagInstance == nil or (_tagInstance :: Instance).Parent == nil then
			return
		end
		local node: Instance? = (_tagInstance :: Instance).Parent
		local climbStand: Instance? = nil
		local guard = 0
		while node ~= nil and guard < 8 do
			guard += 1
			local nm = node.Name
			if string.match(nm, '^Slot%d+$') ~= nil or string.match(nm, '^ArenaStand%d+$') ~= nil then
				climbStand = node
				break
			end
			node = node.Parent
		end
		if climbStand == nil then
			return
		end
		local slot = (climbStand :: Instance):FindFirstChild('Slot')
		menuPart = slot and (slot :: Instance):FindFirstChild('MenuPart') or nil
	end)
	return menuPart
end

local function _resolveLockButtonPart(): Instance?
	local press: Instance? = nil
	pcall(function()
		local baseFolder = _playerBaseFolder()
		if baseFolder == nil then
			return
		end
		local lazer = (baseFolder :: Instance):FindFirstChild('LazerButton')
		if lazer == nil then
			return
		end
		press = (lazer :: Instance):FindFirstChild('PressPart')
		if press == nil then
			press = (lazer :: Instance):FindFirstChildWhichIsA('BasePart', true)
		end
	end)
	return press
end

local function _findArenaRoot(): Instance?
	local root: Instance? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local main = (playerGui :: Instance):FindFirstChild('Main')
		root = main and (main :: Instance):FindFirstChild('Arena') or nil
	end)
	return root
end

local function _findResultRoot(): Instance?
	local root: Instance? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local main = (playerGui :: Instance):FindFirstChild('Main')
		root = main and (main :: Instance):FindFirstChild('ArenaResult') or nil
	end)
	return root
end

local function _isArenaUiOpen(): boolean
	local arena = _findArenaRoot()
	if arena ~= nil and (arena :: Instance):IsA('GuiObject') then
		local gui = arena :: GuiObject
		return gui.Visible
	end
	return false
end

local function _isResultOpen(): boolean
	local okGet, mod = pcall(require, ReplicatedStorage.Utility.ArenaUIState)
	if okGet and type(mod) == 'table' and type(mod.IsResultOpen) == 'function' then
		local okCall, open = pcall(mod.IsResultOpen)
		if okCall and open == true then
			return true
		end
	end
	local result = _findResultRoot()
	if result ~= nil and (result :: Instance):IsA('GuiObject') then
		local gui = result :: GuiObject
		return gui.Visible
	end
	return false
end

-- Free stage-1 arena Start button (Buy3 only; Buy1/Buy2 are
-- paid restarts and must never steal the tutorial spotlight).
local function _findStartButton(): GuiButton?
	local found: GuiButton? = nil
	pcall(function()
		local arena = _findArenaRoot()
		if arena == nil then
			return
		end
		local node = (arena :: Instance):FindFirstChild('Buy3', true)
		if node ~= nil and node:IsA('GuiButton') then
			local button = node :: GuiButton
			if button.Visible then
				found = button
			end
		end
	end)
	return found
end

-- ArenaResult.RightSide.Continue (explicit path first,
-- recursive fallback). Never throws.
local function _findContinueButton(): GuiButton?
	local found: GuiButton? = nil
	pcall(function()
		local result = _findResultRoot()
		if result == nil then
			return
		end
		local right = (result :: Instance):FindFirstChild('RightSide')
		local direct = right and (right :: Instance):FindFirstChild('Continue') or nil
		if direct ~= nil and direct:IsA('GuiButton') then
			found = direct :: GuiButton
			return
		end
		local node = (result :: Instance):FindFirstChild('Continue', true)
		if node ~= nil and node:IsA('GuiButton') then
			found = node :: GuiButton
		end
	end)
	return found
end

-- Upgrade button for the tutorial animal's stand (the REAL
-- runtime button, never a fake). PRIMARY: the snapshot
-- SlotId stand via the canonical StandResolver (recursive +
-- legacy shapes, so flat runtime clones and authored stands
-- both resolve). FALLBACK: the direct MenuGui child lookup
-- behind the resolved MenuPart (pre-resolver behavior).
local function _findUpgradeButton(): GuiButton?
	local found: GuiButton? = nil
	pcall(function()
		local stand = _resolveArenaStand()
		if stand ~= nil and (stand :: Instance).Parent ~= nil then
			local ok, partsAny = pcall(StandResolver.GetStandParts, stand)
			if ok and type(partsAny) == 'table' then
				local btn = (partsAny :: any).upgradeButton
				if
					typeof(btn) == 'Instance'
					and (btn :: Instance):IsA('GuiButton')
					and (btn :: Instance).Parent ~= nil
				then
					found = btn
					return
				end
			end
		end
		local menuPart = _resolveUpgradeMenuPart()
		if menuPart == nil then
			return
		end
		local menuGui = (menuPart :: Instance):FindFirstChild('MenuGui')
		local button = menuGui and (menuGui :: Instance):FindFirstChild('UpgradeButton') or nil
		if button ~= nil and (button :: Instance):IsA('GuiButton') then
			found = button
		end
	end)
	return found
end

-- Current beam/highlight target INSTANCE for the active step.
-- Tracked egg/animal models come from the server-moved tag;
-- static Studio parts resolve by path. Never throws.
local function _resolveTarget(): Instance?
	local target: Instance? = nil
	pcall(function()
		if _snapshot == nil or type(_snapshot.Step) ~= 'string' then
			return
		end
		local step = _snapshot.Step
		if step == 'BuyEgg' then
			if _shopTarget == nil or (_shopTarget :: Instance).Parent == nil then
				_shopTarget = _findStarterEgg()
				_logShopTarget(_shopTarget)
			end
			target = _shopTarget
			return
		end
		if step == 'WaitForEgg' or step == 'HatchEgg' or step == 'PickUpAnimal' then
			if _tagInstance ~= nil and (_tagInstance :: Instance).Parent ~= nil then
				target = _tagInstance
			end
			return
		end
		if step == 'PlaceAnimal' then
			target = _resolveArenaStand()
			if target == nil and _tagInstance ~= nil and (_tagInstance :: Instance).Parent ~= nil then
				target = _tagInstance
			end
			return
		end
		if step == 'StartArena' then
			if not _isArenaUiOpen() then
				target = _resolveAdventurer()
			end
			return
		end
		if step == 'UpgradeAnimal' then
			target = _resolveUpgradeMenuPart()
			if target == nil and _tagInstance ~= nil and (_tagInstance :: Instance).Parent ~= nil then
				target = _tagInstance
			end
			return
		end
		if step == 'LockBase' then
			target = _resolveLockButtonPart()
			return
		end
	end)
	return target
end

-- --- Existing-UI emphasis (local to that UI, never a Tutorial GUI) ----------

local function _clearDimmer()
	local dimmer = _dimmer
	_dimmer = nil
	if dimmer ~= nil then
		pcall(function()
			(dimmer :: Frame):Destroy()
		end)
	end
end

-- Ring on the REAL button (UIStroke parented to it; removed
-- with the emphasis). Never throws.
local function _ringButton(button: GuiButton?)
	pcall(function()
		local old = _buttonRing
		_buttonRing = nil
		if old ~= nil then
			pcall(function()
				(old :: UIStroke):Destroy()
			end)
		end
		if button == nil or (button :: Instance).Parent == nil then
			return
		end
		local stroke = Instance.new('UIStroke')
		stroke.Name = 'TutorialRing'
		stroke.Color = WHITE
		stroke.Thickness = 4
		stroke.Parent = button
		_buttonRing = stroke
	end)
end

-- Spotlight teardown: cancel loops, restore the real button's
-- ZIndex/AnchorPoint/Position/Scale, restore the lifted
-- ancestor chain, destroy the tutorial-owned UIScale (a reused
-- Studio UIScale is restored, never destroyed). Never throws.
-- Idempotent: safe on a dead button, missing pieces, or
-- repeated calls.
local function _clearSpotlight()
	if _spotPulseTween ~= nil then
		pcall(function()
			(_spotPulseTween :: Tween):Cancel()
		end)
		_spotPulseTween = nil
	end
	if _spotGlowTween ~= nil then
		pcall(function()
			(_spotGlowTween :: Tween):Cancel()
		end)
		_spotGlowTween = nil
	end
	local button = _spotlightButton
	_spotlightButton = nil
	if button ~= nil then
		pcall(function()
			local live = button :: GuiButton
			if _spotAnchorOriginal ~= nil then
				live.AnchorPoint = _spotAnchorOriginal :: Vector2
			end
			if _spotPosOriginal ~= nil then
				live.Position = _spotPosOriginal :: UDim2
			end
			if _spotZOriginal ~= nil then
				live.ZIndex = _spotZOriginal :: number
			end
		end)
	end
	_spotZOriginal = nil
	_spotAnchorOriginal = nil
	_spotPosOriginal = nil
	pcall(function()
		for i, node in ipairs(_spotChain) do
			local original = _spotChainZ[i]
			local host = node :: Instance
			if original ~= nil and host.Parent ~= nil then
				local guiNode = node :: GuiObject
				guiNode.ZIndex = original
			end
		end
	end)
	_spotChain = {}
	_spotChainZ = {}
	local scale = _spotScale
	local owned = _spotScaleOwned
	local base = _spotScaleBase
	_spotScale = nil
	_spotScaleOwned = false
	_spotScaleBase = 1
	if scale ~= nil then
		pcall(function()
			if owned then
				(scale :: UIScale):Destroy()
			else
				(scale :: UIScale).Scale = base
			end
		end)
	end
	_ringButton(nil)
end

-- Spotlight target-button emphasis: the SAME live button is a
-- no-op (loops keep running); anything else tears the old
-- spotlight down first. Raises the real button AND its ancestor
-- chain (up to uiRoot) above the dimmer with a temporary
-- ZIndex of 100 (originals restored on teardown), pivots the
-- button to its center (AnchorPoint 0.5, 0.5, position
-- compensated so it does not visibly move), then runs two
-- looped TweenService tweens that die with cleanup: an inward
-- pulse 1.00 -> 0.96 (~0.75s half-cycle, back to original)
-- and white-glow transparency 0.4 -> 0.05. The ring itself
-- still comes from _ringButton (exactly one TutorialRing).
-- uiRoot is optional (pass the dimmer's root so nested buttons
-- escape Sibling-scoped dimming). Never throws.
local function _updateSpotlight(button: GuiButton?, uiRoot: Instance?)
	local target: GuiButton? = nil
	pcall(function()
		if button ~= nil and (button :: Instance).Parent ~= nil then
			target = button
		end
	end)
	if target ~= nil and target == _spotlightButton then
		return
	end
	_clearSpotlight()
	if target == nil then
		return
	end
	pcall(function()
		local live = target :: GuiButton
		_spotlightButton = live
		_spotZOriginal = live.ZIndex
		live.ZIndex = 100
		-- Lift ancestors up to (not including) uiRoot so a nested
		-- button (ArenaResult.RightSide.Continue) paints above the
		-- dimmer under Sibling ZIndexBehavior.
		if uiRoot ~= nil then
			local node: Instance? = live.Parent
			while node ~= nil and node ~= uiRoot do
				local host = node :: Instance
				if host:IsA('GuiObject') then
					local guiNode = host :: GuiObject
					_spotChain[#_spotChain + 1] = guiNode
					_spotChainZ[#_spotChainZ + 1] = guiNode.ZIndex
					guiNode.ZIndex = 100
				end
				node = host.Parent
			end
		end
		-- Center pivot: keep the button exactly where Studio put
		-- it, but scale around its center instead of its authored
		-- corner (authored AnchorPoint 0, 0 grows bottom-right).
		_spotAnchorOriginal = live.AnchorPoint
		_spotPosOriginal = live.Position
		local anchor = live.AnchorPoint
		if anchor.X ~= 0.5 or anchor.Y ~= 0.5 then
			local size = live.Size
			local pos = live.Position
			live.AnchorPoint = Vector2.new(0.5, 0.5)
			live.Position = UDim2.new(
				pos.X.Scale + (0.5 - anchor.X) * size.X.Scale,
				pos.X.Offset + (0.5 - anchor.X) * size.X.Offset,
				pos.Y.Scale + (0.5 - anchor.Y) * size.Y.Scale,
				pos.Y.Offset + (0.5 - anchor.Y) * size.Y.Offset
			)
		end
		local scale: UIScale? = nil
		local owned = false
		local base = 1
		for _, child in ipairs(live:GetChildren()) do
			if child:IsA('UIScale') then
				scale = child
				break
			end
		end
		if scale ~= nil then
			base = (scale :: UIScale).Scale
		else
			local made = Instance.new('UIScale')
			made.Name = 'TutorialSpotScale'
			made.Scale = 1
			made.Parent = live
			scale = made
			owned = true
		end
		_spotScale = scale
		_spotScaleOwned = owned
		_spotScaleBase = base
		_ringButton(live)
		local ring = _buttonRing
		if ring ~= nil then
			(ring :: UIStroke).Transparency = 0.4
		end
		local pulseInfo = TweenInfo.new(0.75, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		local pulse = TweenService:Create(scale :: UIScale, pulseInfo, { Scale = base * 0.96 })
		_spotPulseTween = pulse
		pulse:Play()
		if ring ~= nil then
			local glow = TweenService:Create(ring, pulseInfo, { Transparency = 0.05 })
			_spotGlowTween = glow
			glow:Play()
		end
	end)
end

local function _clearUiEmphasis()
	_clearDimmer()
	_clearSpotlight()
end

-- Dimmer Frame parented INSIDE the existing UI root (not a new
-- ScreenGui): covers the panel, clicks pass through
-- (Active=false). A live dimmer is reused only when it sits
-- under the REQUESTED root; a stale one (UI rebuilt, branch
-- switched) is destroyed and recreated. Never throws.
local function _ensureDimmer(uiRoot: Instance?)
	pcall(function()
		if _dimmer ~= nil and (_dimmer :: Instance).Parent ~= nil then
			if uiRoot ~= nil and (_dimmer :: Instance).Parent == uiRoot then
				return
			end
			_clearDimmer()
		end
		if typeof(uiRoot) ~= 'Instance' or not (uiRoot :: Instance):IsA('GuiObject') then
			return
		end
		local dimmer = Instance.new('Frame')
		dimmer.Name = 'TutorialDimmer'
		dimmer.Size = UDim2.fromScale(1, 1)
		dimmer.BackgroundColor3 = Color3.new(0, 0, 0)
		dimmer.BackgroundTransparency = 0.45
		dimmer.Active = false
		-- Below the lifted spotlight chain (100) so the target
		-- button + its ancestors paint above the shade.
		dimmer.ZIndex = 80
		dimmer.Parent = uiRoot
		_dimmer = dimmer
	end)
end

-- --- Typewriter + cinematic instruction text -------------------------------

-- UTF-8 safe 1-indexed character read (nil past the end).
-- Never throws.
local function _charAt(text: string, index: number): string?
	local char: string? = nil
	pcall(function()
		if type(text) ~= 'string' then
			return
		end
		local start = utf8.offset(text, index)
		if start == nil then
			return
		end
		local stop = utf8.offset(text, index + 1)
		if stop ~= nil then
			stop -= 1
		else
			stop = #text
		end
		char = string.sub(text, start, stop)
	end)
	return char
end

-- Generation-guarded typewriter: types `text` into `label`
-- character-by-character with a Pop sting each, aborting when
-- a newer generation starts (step change / skip / teardown).
-- Never throws.
local function _typeText(label: GuiObject, text: string)
	_typeGen += 1
	local gen = _typeGen
	pcall(function()
		if label:IsA('TextLabel') then
			(label :: TextLabel).Text = ''
		elseif label:IsA('TextButton') then
			(label :: TextButton).Text = ''
		elseif label:IsA('TextBox') then
			(label :: TextBox).Text = ''
		else
			return
		end
		if text == '' then
			return
		end
		task.spawn(function()
			local total = 0
			pcall(function()
				total = utf8.len(text) or 0
			end)
			for i = 1, total do
				if gen ~= _typeGen or _tornDown then
					return
				end
				local char = _charAt(text, i)
				if char == nil then
					break
				end
				pcall(function()
					if label.Parent == nil then
						return
					end
					if label:IsA('TextLabel') then
						(label :: TextLabel).Text = (label :: TextLabel).Text .. char
					elseif label:IsA('TextButton') then
						(label :: TextButton).Text = (label :: TextButton).Text .. char
					elseif label:IsA('TextBox') then
						(label :: TextBox).Text = (label :: TextBox).Text .. char
					end
				end)
				_playTutorialSound('Pop')
				task.wait(_typeInterval)
			end
		end)
	end)
end

-- Current instruction for a step: (text, beamAllowed, key).
-- Multi-phase scripted steps (UpgradeAnimal) breathe first
-- (words only, beam suppressed) then guide; every other step
-- types its STEP_TEXT with full visuals. Never throws.
local function _instructionFor(step: string, now: number): (string?, boolean, string)
	local text: string? = nil
	local beamAllowed = true
	local key = tostring(step)
	pcall(function()
		local script = STEP_SCRIPT[step]
		if type(script) ~= 'table' or #script == 0 then
			text = if step == 'BuyEgg' then _buyEggText() else STEP_TEXT[step]
			return
		end
		if _cineStep ~= step then
			_cineStep = step
			_cinePhase = 1
			_cineUntil = now + ((script[1].Hold :: any) or 0)
		end
		while _cinePhase < #script and now >= _cineUntil do
			_cinePhase += 1
			local hold = (script[_cinePhase].Hold :: any) or 0
			_cineUntil = now + (if type(hold) == 'number' then hold else 0)
		end
		local phase = script[_cinePhase] or script[#script]
		if type(phase) == 'table' then
			text = phase.Text
			beamAllowed = phase.Beam ~= false
			key = tostring(step) .. '#' .. tostring(_cinePhase)
		else
			text = STEP_TEXT[step]
		end
	end)
	return text, beamAllowed, key
end

-- --- Quest checklist (HUD.TutorialSteps, Step1 template) ----------------------

-- Resolve the Studio-authored checklist: TutorialSteps frame,
-- its Steps container, the Step1 template row, and the Title
-- label. Never creates containers; never throws.
local function _resolveChecklist(): any
	local resolved: any = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local hud = (playerGui :: Instance):FindFirstChild('HUD')
		local steps = hud and (hud :: Instance):FindFirstChild('TutorialSteps') or nil
		if steps == nil then
			return
		end
		local list = (steps :: Instance):FindFirstChild('Steps')
		local template = list and (list :: Instance):FindFirstChild('Step1') or nil
		if list == nil or template == nil then
			return
		end
		local title = (steps :: Instance):FindFirstChild('Title')
		resolved = { Root = steps, List = list, Template = template, Title = title }
	end)
	return resolved
end

-- Snapshot a row's restorable presentation on first build.
local function _rememberRowOriginal(row: GuiObject)
	if _checklistOriginals[row] ~= nil then
		return
	end
	local saved: any = {}
	pcall(function()
		if row:IsA('TextLabel') then
			saved.Text = (row :: TextLabel).Text
		elseif row:IsA('TextButton') then
			saved.Text = (row :: TextButton).Text
		elseif row:IsA('TextBox') then
			saved.Text = (row :: TextBox).Text
		end
		if row:IsA('TextLabel') or row:IsA('TextButton') or row:IsA('TextBox') then
			local label = row :: TextLabel
			saved.TextTransparency = label.TextTransparency
			saved.Font = label.Font
			saved.TextColor3 = label.TextColor3
		end
		saved.Visible = (row :: GuiObject).Visible
	end)
	_checklistOriginals[row] = saved
end

-- Row parts: the text label itself (or first text descendant),
-- an existing circle/check indicator child when the template
-- provides one, and an existing strike line child when it
-- provides one. Never creates anything. Never throws.
local function _resolveRowParts(row: GuiObject): any
	local parts: any = { Label = nil, Indicator = nil, Strike = nil }
	pcall(function()
		if row:IsA('TextLabel') or row:IsA('TextButton') or row:IsA('TextBox') then
			parts.Label = row
		else
			local deep = (row :: Instance):FindFirstChildWhichIsA('TextLabel', true)
				or (row :: Instance):FindFirstChildWhichIsA('TextButton', true)
				or (row :: Instance):FindFirstChildWhichIsA('TextBox', true)
			parts.Label = deep
		end
		for _, child in ipairs((row :: Instance):GetChildren()) do
			local nm = child.Name
			if
				nm == 'Circle'
				or nm == 'Bullet'
				or nm == 'Check'
				or nm == 'Icon'
				or nm == 'Marker'
				or nm == 'Dot'
				or nm == 'Indicator'
				or nm == 'State'
			then
				parts.Indicator = child
			elseif nm == 'Strike' or nm == 'Strikethrough' or nm == 'StrikeThrough' or nm == 'Line' or nm == 'Bar' then
				parts.Strike = child
			end
		end
	end)
	return parts
end

local function _setRowText(row: GuiObject, prefix: string, text: string)
	pcall(function()
		local parts = _resolveRowParts(row)
		local label = parts.Label
		if label == nil then
			return
		end
		local body = prefix .. text
		if label:IsA('TextLabel') then
			(label :: TextLabel).Text = body
		elseif label:IsA('TextButton') then
			(label :: TextButton).Text = body
		elseif label:IsA('TextBox') then
			(label :: TextBox).Text = body
		end
	end)
end

-- Build one row per actual tutorial step from the Step1
-- template (Step1 IS row 1; the rest are clones, tracked for
-- teardown). Reuses surviving rows (respawn/UI reload)
-- instead of duplicating. Adds the minimum layout only when
-- rows would otherwise stack (no UIListLayout present and
-- clone positions identical). Never throws.
local function _ensureChecklist(): boolean
	local ready = false
	pcall(function()
		local resolved = _resolveChecklist()
		if resolved == nil then
			return
		end
		local list = resolved.List
		local template = resolved.Template
		-- Reuse live rows when a previous build survived.
		local live: { GuiObject } = {}
		local complete = true
		for i = 1, #CHECKLIST_STEPS do
			local name = 'Step' .. tostring(i)
			local node: Instance? = nil
			if i == 1 then
				node = template
			else
				node = (list :: Instance):FindFirstChild(name)
			end
			if node ~= nil and node:IsA('GuiObject') and (node :: Instance).Parent ~= nil then
				live[i] = node :: GuiObject
			else
				complete = false
				break
			end
		end
		if complete then
			_checklistRows = live
			ready = true
			return
		end
		-- Fresh build: row 1 is the template itself.
		_checklistRows = {}
		if not (template :: Instance):IsA('GuiObject') then
			return
		end
		_rememberRowOriginal(template :: GuiObject)
		_checklistRows[1] = template :: GuiObject
		(template :: GuiObject).Name = 'Step1'
		pcall(function()
			(template :: GuiObject).LayoutOrder = 1
		end)
		for i = 2, #CHECKLIST_STEPS do
			local clone = (template :: GuiObject):Clone()
			clone.Name = 'Step' .. tostring(i)
			pcall(function()
				(clone :: GuiObject).LayoutOrder = i
			end)
			clone.Parent = list
			_checklistRows[i] = clone :: GuiObject
			_checklistClones[clone :: GuiObject] = true
		end
		-- Minimum layout: only when rows would stack (no
		-- UIListLayout present and clone positions identical).
		local needsLayout = false
		pcall(function()
			if (list :: Instance):FindFirstChildWhichIsA('UIListLayout', false) ~= nil then
				return
			end
			local firstPos: UDim2? = nil
			local same = true
			for _, row in ipairs(_checklistRows) do
				if row:IsA('GuiObject') then
					local pos = (row :: GuiObject).Position
					if firstPos == nil then
						firstPos = pos
					elseif pos ~= firstPos then
						same = false
						break
					end
				end
			end
			needsLayout = same
		end)
		if needsLayout then
			pcall(function()
				local layout = Instance.new('UIListLayout')
				layout.Name = 'TutorialStepsLayout'
				layout.FillDirection = Enum.FillDirection.Vertical
				layout.SortOrder = Enum.SortOrder.LayoutOrder
				layout.Padding = UDim.new(0, 4)
				layout.Parent = list
				_checklistLayout = layout
			end)
		end
		for i, row in ipairs(CHECKLIST_STEPS) do
			_setRowText(_checklistRows[i], '○ ', row.Text)
		end
		ready = true
	end)
	return ready
end

-- Paint one row: check/pop for newly-done, strike grow for
-- newly-done, dim for done, emphasis for current. Animates
-- ONLY transitions (tracked per row). Never throws.
local function _popScale(target: GuiObject)
	pcall(function()
		local scale = Instance.new('UIScale')
		scale.Name = 'TutorialPopScale'
		scale.Scale = 0.7
		scale.Parent = target
		local info = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		local tween = TweenService:Create(scale, info, { Scale = 1 })
		tween:Play()
		Debris:AddItem(scale, 1)
	end)
end

-- Strike line on a label (created once, reused): thin white
-- line across the text middle, grown left -> right on
-- completion via Size tween. Never throws.
local function _ensureStrikeLine(label: GuiObject): GuiObject?
	local line: GuiObject? = nil
	pcall(function()
		local existing = (label :: Instance):FindFirstChild('TutorialStrikeLine')
		if existing ~= nil and existing:IsA('GuiObject') then
			line = existing
			return
		end
		local made = Instance.new('Frame')
		made.Name = 'TutorialStrikeLine'
		made.AnchorPoint = Vector2.new(0, 0.5)
		made.Position = UDim2.fromScale(0, 0.5)
		made.Size = UDim2.fromOffset(0, 2)
		made.BackgroundColor3 = Color3.new(1, 1, 1)
		made.BackgroundTransparency = 0.25
		made.BorderSizePixel = 0
		made.Visible = false
		made.Parent = label
		line = made
	end)
	return line
end

local function _growStrike(line: GuiObject, alreadyDone: boolean)
	pcall(function()
		local target = line :: GuiObject
		target.Visible = true
		if alreadyDone then
			target.Size = UDim2.new(1, 0, 0, 2)
			return
		end
		target.Size = UDim2.fromOffset(0, 2)
		local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(target, info, { Size = UDim2.new(1, 0, 0, 2) }):Play()
	end)
end

local function _paintRow(row: GuiObject, index: number, isDone: boolean, isCurrent: boolean)
	pcall(function()
		local parts = _resolveRowParts(row)
		local label = parts.Label
		local last = _rowPainted[row]
		local wasDone = last ~= nil and last.Done == true
		local prefix = if isDone then '✓ ' else '○ '
		if parts.Indicator ~= nil and (parts.Indicator :: Instance):IsA('TextLabel') then
			-- Template-provided text indicator: swap the mark,
			-- keep the row text clean.
			local mark = parts.Indicator :: TextLabel
			local want = if isDone then '✓' else '○'
			if mark.Text ~= want then
				mark.Text = want
				if isDone then
					_popScale(mark)
				end
			end
			_setRowText(row, '', CHECKLIST_STEPS[index].Text)
		else
			-- No dedicated indicator: the mark rides the text.
			_setRowText(row, prefix, CHECKLIST_STEPS[index].Text)
			if isDone and not wasDone and label ~= nil then
				_popScale(label)
			end
		end
		-- Strike line: existing template line preferred, else
		-- the created TutorialStrikeLine on the label.
		local strike: GuiObject? = nil
		if parts.Strike ~= nil and (parts.Strike :: Instance):IsA('GuiObject') then
			strike = parts.Strike
		end
		if isDone then
			if strike == nil and label ~= nil then
				strike = _ensureStrikeLine(label)
			end
			if strike ~= nil then
				_growStrike(strike, wasDone)
			end
		elseif strike ~= nil then
			(strike :: GuiObject).Visible = false
		end
		-- Dim done rows; emphasize the current one.
		if label ~= nil and (label:IsA('TextLabel') or label:IsA('TextButton') or label:IsA('TextBox')) then
			local target = label :: TextLabel
			local base = 0
			pcall(function()
				local saved = _checklistOriginals[row]
				if type(saved) == 'table' and type(saved.TextTransparency) == 'number' then
					base = saved.TextTransparency
				end
			end)
			if isDone then
				target.TextTransparency = math.clamp(base + 0.35, 0, 1)
				pcall(function()
					target.Font = Enum.Font.GothamMedium
				end)
			elseif isCurrent then
				target.TextTransparency = base
				pcall(function()
					target.Font = Enum.Font.GothamBold
				end)
			else
				target.TextTransparency = base
				pcall(function()
					local saved = _checklistOriginals[row]
					if type(saved) == 'table' and saved.Font ~= nil then
						target.Font = saved.Font
					end
				end)
			end
		end
		_rowPainted[row] = { Done = isDone, Current = isCurrent }
	end)
end

-- Small satisfying pop (0.7 -> 1) on a GuiObject, one-shot.
-- Never throws.

-- Title counter + pulse on change (single reused UIScale).
-- Never throws.
local function _paintTitle(count: number, total: number)
	pcall(function()
		local resolved = _resolveChecklist()
		if resolved == nil then
			return
		end
		local title = resolved.Title
		if title == nil or not (title :: Instance):IsA('GuiObject') then
			return
		end
		local label = title :: GuiObject
		local text = tostring(count) .. '/' .. tostring(total) .. ' TUTORIAL'
		local changed = false
		pcall(function()
			if label:IsA('TextLabel') and (label :: TextLabel).Text ~= text then
				(label :: TextLabel).Text = text
				changed = true
			elseif label:IsA('TextButton') and (label :: TextButton).Text ~= text then
				(label :: TextButton).Text = text
				changed = true
			elseif label:IsA('TextBox') and (label :: TextBox).Text ~= text then
				(label :: TextBox).Text = text
				changed = true
			end
		end)
		if not changed then
			return
		end
		if _checklistUiScale == nil or (_checklistUiScale :: Instance).Parent == nil then
			_checklistUiScale = nil
			pcall(function()
				for _, child in ipairs((label :: Instance):GetChildren()) do
					if child:IsA('UIScale') then
						_checklistUiScale = child
						break
					end
				end
				if _checklistUiScale == nil then
					local made = Instance.new('UIScale')
					made.Name = 'TutorialTitleScale'
					made.Scale = 1
					made.Parent = label
					_checklistUiScale = made
					_checklistUiScaleCreated = true
				end
			end)
		end
		if _checklistUiScale ~= nil then
			pcall(function()
				local scale = _checklistUiScale :: UIScale
				scale.Scale = 1
				local info = TweenInfo.new(0.125, Enum.EasingStyle.Sine, Enum.EasingDirection.Out, 0, true)
				TweenService:Create(scale, info, { Scale = 1.08 }):Play()
			end)
		end
	end)
end

-- Paint the whole checklist from an authoritative step
-- (build-once rows, transition-only animation). Never throws.
local function _paintChecklist(step: string)
	pcall(function()
		if not _ensureChecklist() then
			return
		end
		if #_checklistRows ~= #CHECKLIST_STEPS then
			return
		end
		local derived = _checklistFor(step)
		_paintTitle(derived.Count, derived.Total)
		for i = 1, #CHECKLIST_STEPS do
			_paintRow(_checklistRows[i], i, derived.Done[i] == true, derived.Current == i)
		end
	end)
end

local function _setChecklistVisible(visible: boolean)
	pcall(function()
		local resolved = _resolveChecklist()
		if resolved == nil then
			return
		end
		local root = resolved.Root
		if (root :: Instance):IsA('GuiObject') then
			(root :: GuiObject).Visible = visible
		end
	end)
end

-- Paint the HUD.Top.Tutorial container from the authoritative
-- step: Counter shows "current/total" (total follows
-- CHECKLIST_STEPS, never a hardcoded number); the Steps label
-- itself is written by the typewriter instruction path. The
-- container hides on Completed (or unknown step) so no stale
-- counter survives. Server state stays authoritative; this is
-- presentation only. Never throws.
local function _paintTutorialHud(step: string?)
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local root = HudTree.TutorialRoot(playerGui)
		if root == nil then
			return
		end
		local derived = _checklistFor(step)
		local current = derived.Current
		if current == nil then
			-- Completed (or unknown): hide only our own
			-- container and release ancestors we borrowed —
			-- shared Top stays up iff other UI still needs it.
			if (root :: Instance):IsA('GuiObject') then
				(root :: GuiObject).Visible = false
			end
			HudTree.ReleaseChain(root)
			return
		end
		-- Active: the whole chain (HUD → Top → Tutorial →
		-- Counter/Steps) must be up; a hidden Top would swallow
		-- the container no matter what we set on it.
		HudTree.EnsureChainVisible(root)
		if (root :: Instance):IsA('GuiObject') then
			(root :: GuiObject).Visible = true
		end
		local counter = HudTree.TutorialCounter(playerGui)
		if counter ~= nil then
			counter.Text = tostring(current) .. '/' .. tostring(derived.Total)
		end
	end)
end

-- Teardown: destroy OUR clones, restore Step1 originals, hide
-- the Steps root. The Studio template itself is never
-- destroyed. Never throws.
local function _teardownChecklist()
	pcall(function()
		for row, _ in pairs(_checklistClones) do
			pcall(function()
				(row :: GuiObject):Destroy()
			end)
		end
		table.clear(_checklistClones)
		table.clear(_checklistRows)
		table.clear(_rowPainted)
		if _checklistUiScaleCreated and _checklistUiScale ~= nil then
			pcall(function()
				(_checklistUiScale :: UIScale):Destroy()
			end)
		end
		_checklistUiScale = nil
		_checklistUiScaleCreated = false
		if _checklistLayout ~= nil then
			pcall(function()
				(_checklistLayout :: UIListLayout):Destroy()
			end)
			_checklistLayout = nil
		end
		-- Restore Step1 presentation from the first-build snapshot.
		pcall(function()
			local resolved = _resolveChecklist()
			if resolved == nil then
				return
			end
			local template = resolved.Template
			if template ~= nil and (template :: Instance):IsA('GuiObject') then
				local saved = _checklistOriginals[template :: GuiObject]
				if type(saved) == 'table' then
					local row = template :: GuiObject
					if saved.Text ~= nil then
						if row:IsA('TextLabel') then
							(row :: TextLabel).Text = saved.Text
						elseif row:IsA('TextButton') then
							(row :: TextButton).Text = saved.Text
						elseif row:IsA('TextBox') then
							(row :: TextBox).Text = saved.Text
						end
					end
					if row:IsA('TextLabel') or row:IsA('TextButton') or row:IsA('TextBox') then
						local label = row :: TextLabel
						if type(saved.TextTransparency) == 'number' then
							label.TextTransparency = saved.TextTransparency
						end
						if saved.Font ~= nil then
							label.Font = saved.Font
						end
					end
				end
			end
		end)
		table.clear(_checklistOriginals)
		_setChecklistVisible(false)
		-- Release ancestors borrowed by the legacy root (no-op
		-- when the new Top.Tutorial container owns visibility).
		pcall(function()
			local player = _localPlayer()
			if player == nil then
				return
			end
			local playerGui = player:FindFirstChildOfClass('PlayerGui')
			if playerGui == nil then
				return
			end
			HudTree.ReleaseChain(HudTree.TutorialRoot(playerGui))
		end)
	end)
end

-- Highlight pulse: one looped tween (fill 0.65 <-> 0.25,
-- outline 0.15 <-> 0) restarted only when the target
-- instance changes. Never throws.
local function _updateHighlightPulse(target: Instance?)
	pcall(function()
		local key: string? = nil
		if typeof(target) == 'Instance' and (target :: Instance).Parent ~= nil then
			key = target:GetFullName()
		end
		if key == _pulseKey then
			return
		end
		if _highlightTween ~= nil then
			pcall(function()
				(_highlightTween :: Tween):Cancel()
			end)
			_highlightTween = nil
		end
		_pulseKey = key
		if key == nil then
			return
		end
		local hl = _highlight
		if hl == nil or (hl :: Instance).Parent == nil then
			return
		end
		(hl :: Highlight).FillTransparency = 0.65
		(hl :: Highlight).OutlineTransparency = 0.15
		local info = TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
		local tween = TweenService:Create(hl, info, { FillTransparency = 0.25, OutlineTransparency = 0 })
		_highlightTween = tween
		tween:Play()
	end)
end

local function _stopHighlightPulse()
	if _highlightTween ~= nil then
		pcall(function()
			(_highlightTween :: Tween):Cancel()
		end)
		_highlightTween = nil
	end
	_pulseKey = nil
end

-- Skip button (Studio-authored HUD.TutorialSkip): wire once,
-- fire the gated server intent, rewire if replaced. Never
-- creates anything. Never throws.
local function _fireServerAction(action: string)
	pcall(function()
		local folder: Instance? = nil
		local okFolder, got = pcall(function()
			return ReplicatedStorage:WaitForChild('Remotes', 5)
		end)
		if okFolder then
			folder = got
		end
		local remote = folder and (folder :: Instance):FindFirstChild(Remotes.Names.TutorialAction) or nil
		if remote ~= nil and (remote :: Instance):IsA('RemoteEvent') then
			((remote :: Instance) :: RemoteEvent):FireServer({ Action = action })
		end
	end)
end

local function _findSkipButton(): GuiButton?
	local found: GuiButton? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		local hud = (playerGui :: Instance):FindFirstChild('HUD')
		local node = hud and (hud :: Instance):FindFirstChild('TutorialSkip') or nil
		if node ~= nil and node:IsA('GuiButton') then
			found = node
		end
	end)
	return found
end

local function _wireSkip()
	pcall(function()
		if _skipConn ~= nil then
			if _skipWiredButton ~= nil and (_skipWiredButton :: Instance).Parent ~= nil then
				return
			end
			pcall(function()
				(_skipConn :: RBXScriptConnection):Disconnect()
			end)
			_skipConn = nil
			_skipWiredButton = nil
		end
		local button = _findSkipButton()
		if button == nil then
			return
		end
		_skipConn = button.Activated:Connect(function()
			_skipArmed = true
			_fireServerAction('Skip')
		end)
		_skipWiredButton = button
	end)
end

local function _setSkipVisible(visible: boolean)
	pcall(function()
		local button = _findSkipButton()
		if button == nil then
			return
		end
		(button :: GuiButton).Visible = visible
	end)
end

-- --- Frame update --------------------------------------------------------------

local function _teardownVisuals()
	_typeGen += 1
	_stopHighlightPulse()
	_destroyBeam()
	_destroyHighlight()
	_clearUiEmphasis()
	_teardownChecklist()
	_setSkipVisible(false)
	_tagInstance = nil
	_shopTarget = nil
	_beamTargetKey = nil
	_typedKey = nil
	_typedLabel = nil
	_cineStep = nil
	_uiBeatStep = nil
	_uiBeatSince = nil
end

-- Resolve the live HUD instruction label (or nil). Never throws.
local function _resolveHudLabel(): GuiObject?
	local label: GuiObject? = nil
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		local playerGui = player:FindFirstChildOfClass('PlayerGui')
		if playerGui == nil then
			return
		end
		label = _findTutorialLabel(playerGui)
	end)
	return label
end

-- Two-beat UI-open instruction timing (pure except for the
-- caller's clock): beat 1 on open, beat 2 after UI_BEAT_DELAY.
-- Returns text, key, or nil when this step/UI combo has no
-- beat (caller falls back to the normal script path).
-- Never throws.
local UI_BEAT_DELAY = 2.5

local function _beatFor(step: string, uiOpen: boolean, elapsed: number): (string?, string?)
	local text: string? = nil
	local key: string? = nil
	pcall(function()
		if not uiOpen then
			return
		end
		if step == 'StartArena' then
			if elapsed < UI_BEAT_DELAY then
				text = "Let's see what your animal can do!"
				key = 'StartArena:open:1'
			else
				text = 'Press to start arena!'
				key = 'StartArena:open:2'
			end
		elseif step == 'ArenaEnded' then
			if elapsed < UI_BEAT_DELAY then
				text = 'Great job! Your arena is complete.'
				key = 'ArenaEnded:open:1'
			else
				text = 'Continue!'
				key = 'ArenaEnded:open:2'
			end
		end
	end)
	return text, key
end

-- Instruction update: typewriter (cinematic-aware) exactly once
-- per text key; instant rewrite if the label died underneath
-- (respawn/UI reload). Returns beamAllowed for this frame.
local function _updateInstruction(step: string): boolean
	local beamAllowed = true
	pcall(function()
		-- Arena-open override goes through the SAME typewriter
		-- (every HUD.Tutorial character pops, no exceptions).
		local text: string? = nil
		local allowed = true
		local key = tostring(step)
		local beatUiOpen = (step == 'StartArena' and _isArenaUiOpen()) or (step == 'ArenaEnded' and _isResultOpen())
		if beatUiOpen then
			if _uiBeatStep ~= step then
				_uiBeatStep = step
				_uiBeatSince = os.clock()
			end
			local elapsed = os.clock() - (_uiBeatSince or os.clock())
			local beatText: string? = nil
			local beatKey: string? = nil
			pcall(function()
				beatText, beatKey = _beatFor(step, true, elapsed)
			end)
			if beatText ~= nil and beatKey ~= nil then
				text = beatText
				key = beatKey
			end
		else
			_uiBeatStep = nil
			_uiBeatSince = nil
		end
		if key == tostring(step) then
			local scriptText: string? = nil
			local scriptAllowed = true
			local scriptKey = tostring(step)
			pcall(function()
				local t, a, k = _instructionFor(step, os.clock())
				scriptText = t
				scriptAllowed = a
				scriptKey = k
			end)
			text = scriptText
			allowed = scriptAllowed
			key = scriptKey
		end
		beamAllowed = allowed
		-- A dead label (respawn/UI reload) re-types instead of
		-- silently rewriting, so every shown character pops.
		if key == _typedKey and (_typedLabel == nil or (_typedLabel :: Instance).Parent == nil) then
			_typedKey = nil
		end
		if key ~= _typedKey then
			_typedKey = key
			_typedLabel = nil
			local label = _resolveHudLabel()
			if label == nil then
				_warnOnce('no-hud-tutorial', '[Tutorial] PlayerGui.HUD.Tutorial missing; instruction text unavailable')
				return
			end
			_typedLabel = label
			label.Visible = true
			_typeText(label, text or '')
			return
		end
	end)
	return beamAllowed
end

local function _paint()
	if _tornDown then
		return
	end
	local step: string? = nil
	if _snapshot ~= nil then
		step = _snapshot.Step
	end
	-- No snapshot yet: leave Studio UI exactly as authored.
	if step == nil then
		return
	end
	if step == 'Completed' then
		_setHudText('')
		_paintTutorialHud('Completed')
		_teardownVisuals()
		return
	end
	-- Tutorial UI trio visible while active.
	_setChecklistVisible(true)
	_setSkipVisible(true)
	_wireSkip()
	-- New HUD.Top.Tutorial container: Counter "current/total"
	-- from the same authoritative step (Steps text comes from
	-- the typewriter instruction path below).
	_paintTutorialHud(step)
	-- Checklist derives from the authoritative step (never resets
	-- unless the server itself goes back to BuyEgg).
	_paintChecklist(step)
	-- Instruction text (typewriter, cinematic-aware; the arena
	-- override types too so every character pops).
	local beamAllowed = _updateInstruction(step)
	local target = _resolveTarget()
	-- Beam: player torso/root -> exact target instance. The
	-- Beam auto-follows both ends (moving eggs need no polling).
	-- Suppressed during cinematic read beats.
	local anchorPart = _playerAnchorPart()
	local targetPart = _firstPart(target)
	if beamAllowed and anchorPart ~= nil and targetPart ~= nil then
		local beam = _ensureBeam()
		if beam ~= nil then
			-- Prune attachments whose host changed (target
			-- switches egg -> animal -> slot ...); the helper
			-- below recreates them on the current hosts.
			if _beamPlayerAttachment ~= nil and (_beamPlayerAttachment :: Attachment).Parent ~= anchorPart then
				pcall(function()
					(_beamPlayerAttachment :: Attachment):Destroy()
				end)
				_beamPlayerAttachment = nil
			end
			if _beamTargetAttachment ~= nil and (_beamTargetAttachment :: Attachment).Parent ~= targetPart then
				pcall(function()
					(_beamTargetAttachment :: Attachment):Destroy()
				end)
				_beamTargetAttachment = nil
			end
			local a0 = TutorialController.EnsureAttachment(anchorPart, 'TutorialBeamRoot')
			local a1 = TutorialController.EnsureAttachment(targetPart, 'TutorialBeamTarget')
			_beamPlayerAttachment = a0
			_beamTargetAttachment = a1
			if a0 ~= nil and a1 ~= nil then
				local live = beam :: Beam
				live.Attachment0 = a0
				live.Attachment1 = a1
				local key = tostring(step) .. ':' .. targetPart:GetFullName()
				if _beamTargetKey ~= key then
					_beamTargetKey = key
					Debug.Log('TS', 'beam retargeted', { step = tostring(step) })
				end
			end
		end
	else
		_destroyBeam()
	end
	-- White highlight on the real target (models and parts),
	-- pulsed; suppressed with the beam on read beats.
	if beamAllowed then
		_setHighlightTarget(target)
	else
		_setHighlightTarget(nil)
	end
	_updateHighlightPulse(if beamAllowed then target else nil)
	-- Existing-UI emphasis (arena moments + upgrade button).
	-- Spotlight state is sticky: same live button is a no-op so
	-- the pulse/glow tweens keep looping; anything else (or no
	-- branch) tears the old spotlight down. The dimmer persists
	-- via _ensureDimmer's own guard.
	if step == 'StartArena' and _isArenaUiOpen() then
		local arenaRoot = _findArenaRoot()
		_ensureDimmer(arenaRoot)
		_updateSpotlight(_findStartButton(), arenaRoot)
	elseif step == 'ArenaEnded' and _isResultOpen() then
		local resultRoot = _findResultRoot()
		_ensureDimmer(resultRoot)
		_updateSpotlight(_findContinueButton(), resultRoot)
	elseif step == 'UpgradeAnimal' and beamAllowed then
		_updateSpotlight(_findUpgradeButton())
	else
		_clearUiEmphasis()
	end
	-- Continue detection: the real local Continue close flips
	-- IsResultOpen; report once through the gated intent.
	if step == 'ArenaEnded' then
		if _isResultOpen() then
			_continueSent = false
		elseif not _continueSent then
			_continueSent = true
			_fireServerAction('Continue')
		end
	else
		_continueSent = false
	end
end

-- Full teardown on completion: destroy every visual, clear the
-- HUD text, disconnect every connection. Nothing
-- tutorial-related keeps running afterwards.
local function _teardownAll()
	if _tornDown then
		return
	end
	_tornDown = true
	_teardownVisuals()
	_setHudText('')
	_paintTutorialHud('Completed')
	local conn = _conn
	_conn = nil
	if conn ~= nil then
		pcall(function()
			(conn :: RBXScriptConnection):Disconnect()
		end)
	end
	local remoteConn = _remoteConn
	_remoteConn = nil
	if remoteConn ~= nil then
		pcall(function()
			(remoteConn :: RBXScriptConnection):Disconnect()
		end)
	end
	local added = _tagAddedConn
	_tagAddedConn = nil
	if added ~= nil then
		pcall(function()
			(added :: RBXScriptConnection):Disconnect()
		end)
	end
	local removed = _tagRemovedConn
	_tagRemovedConn = nil
	if removed ~= nil then
		pcall(function()
			(removed :: RBXScriptConnection):Disconnect()
		end)
	end
	local charConn = _charConn
	_charConn = nil
	if charConn ~= nil then
		pcall(function()
			(charConn :: RBXScriptConnection):Disconnect()
		end)
	end
end

-- --- Remote + tag wiring ---------------------------------------------------------

local function _applySnapshot(payload: any)
	pcall(function()
		if type(payload) ~= 'table' or type(payload.Step) ~= 'string' then
			return
		end
		local prev = _snapshot and _snapshot.Step or nil
		_snapshot = {
			Step = payload.Step,
			EggId = payload.EggId,
			AnimalId = payload.AnimalId,
			SlotId = payload.SlotId,
			BaseId = payload.BaseId,
		}
		if payload.Step ~= prev then
			_shopTarget = nil
			_continueSent = false
			_clearUiEmphasis()
			-- Always-visible client flow trace (matches the
			-- server [TS] advanced line, per step).
						Debug.Log('TS', ('client step=%s'):format(tostring(payload.Step)))
		-- Approved sting exactly once per real step change
		-- (never for the initial snapshot, never after a
		-- skip — skips stay silent). This client is the
		-- SINGLE source: the server plays no tutorial audio,
		-- so the sting can never double-play.
			local wasSkip = _skipArmed
			_skipArmed = false
			if prev ~= nil and not wasSkip then
				_playTutorialSound('Approved')
			end
			if payload.Step == 'Completed' then
				_teardownAll()
				return
			end
		end
		_paint()
	end)
end

local function _watchCharacter()
	pcall(function()
		local player = _localPlayer()
		if player == nil then
			return
		end
		if _charConn ~= nil then
			pcall(function()
				(_charConn :: RBXScriptConnection):Disconnect()
			end)
			_charConn = nil
		end
		-- Player attachment lives in the character: drop it on
		-- respawn so the next paint rebuilds it on the new one.
		_charConn = player.CharacterAdded:Connect(function()
			pcall(function()
				if _beamPlayerAttachment ~= nil then
					(_beamPlayerAttachment :: Attachment):Destroy()
				end
			end)
			_beamPlayerAttachment = nil
		end)
	end)
end

function TutorialController.Init()
	if _conn ~= nil then
		return
	end
	Remotes.WaitForReady()
	_watchCharacter()
	-- Server snapshots (authoritative step + target refs).
	pcall(function()
		local signal: any = nil
		pcall(function()
			signal = Remotes.OnClientEvent(Remotes.Names.TutorialState)
		end)
		if signal ~= nil then
			_remoteConn = (signal :: any):Connect(_applySnapshot)
		end
	end)
	-- Live-model tracking: the server moves each player's OWN
	-- per-player tag between their tracked egg/animal models
	-- (never another player's tag — tags replicate globally).
	local ownTag = _tagName()
	pcall(function()
		_tagAddedConn = CollectionService:GetInstanceAddedSignal(ownTag):Connect(function(inst: Instance)
			_tagInstance = inst
		end)
	end)
	pcall(function()
		_tagRemovedConn = CollectionService:GetInstanceRemovedSignal(ownTag):Connect(function(inst: Instance)
			if _tagInstance == inst then
				_tagInstance = nil
			end
		end)
	end)
	-- Adopt an already-tagged model (late init after publish).
	pcall(function()
		local tagged = CollectionService:GetTagged(ownTag)
		if #tagged > 0 then
			_tagInstance = tagged[1]
		end
	end)
	-- Ask for current state (covers late joins/resumes).
	_fireServerAction('State')
	-- Throttled visual loop (target resolution + text only —
	-- step logic is server-side; the beam itself follows its
	-- attachments with no polling).
	_conn = RunService.Heartbeat:Connect(function(dt: number)
		_accum += dt
		if _accum < 0.25 then
			return
		end
		_accum = 0
		pcall(_paint)
	end)
	Debug.Log('TS', 'TutorialController started', {})
end

-- TEST seams: pure text mapping + HUD lookup + fallback beam.
function TutorialController._TestTextFor(step: string, arenaOpen: boolean): string?
	if step == 'Completed' then
		return nil
	end
	if step == 'StartArena' and arenaOpen then
		return "Let's see what your animal can do!"
	end
	if step == 'BuyEgg' then
		return _buyEggText()
	end
	return STEP_TEXT[step]
end

function TutorialController._TestFindTutorialLabel(root: Instance?): GuiObject?
	return _findTutorialLabel(root)
end

-- Checklist derivation for an authoritative step:
-- { Count, Done: {bool x5}, Current: number? }.
function TutorialController._TestChecklistFor(step: string): any
	return _checklistFor(step)
end

-- Starter-egg folder scan for specs (hermetic: caller passes
-- any folder, never the live Workspace). Proves the BuyEgg
-- target comes from the searched ActiveEggs-style container
-- only — nested Base folders are never descended into.
function TutorialController._TestFindStarterInFolder(folder: Instance, here: Vector3?, userId: number?): Model?
	if typeof(folder) ~= 'Instance' then
		return nil
	end
	return _findStarterInFolder(folder, here, userId)
end

-- Per-player tag name for specs (specs run without a
-- LocalPlayer, so the id is injected explicitly).
function TutorialController._TestTagNameFor(userId: number?): string
	return _tagNameFor(userId)
end

-- Skip intent payload contract (server-gated 'Skip').
function TutorialController._TestSkipPayload(): any
	return { Action = 'Skip' }
end

-- Typewriter interval override for specs (production default
-- 0.03s). Never throws.
function TutorialController._TestSetTypeInterval(seconds: number)
	pcall(function()
		if type(seconds) == 'number' and seconds >= 0 then
			_typeInterval = seconds
		end
	end)
end

-- Drive the typewriter directly (specs only).
function TutorialController._TestTypeText(label: GuiObject, text: string)
	_typeText(label, text)
end

-- Sound template lookup with an injected root (production
-- passes nil = live ReplicatedStorage).
function TutorialController._TestResolveSfx(name: string, rootOverride: Instance?): string?
	local image: string? = nil
	pcall(function()
		local template = _resolveSfxTemplate(name, rootOverride)
		if template ~= nil then
			image = (template :: Sound).SoundId
		end
	end)
	return image
end

-- Drive beam resolution directly (specs only). Returns the live beam.
function TutorialController._TestEnsureBeam(): Beam?
	return _ensureBeam()
end

-- Beat timing table for UI-open instruction text (pure;
-- production passes os.clock()-derived elapsed). Returns
-- text, key, or nil when this step/UI combo has no beat.
function TutorialController._TestBeatFor(step: string, uiOpen: boolean, elapsed: number): (string?, string?)
	return _beatFor(step, uiOpen, elapsed)
end

-- Drive spotlight setup/teardown directly (specs only).
function TutorialController._TestUpdateSpotlight(button: GuiButton?, uiRoot: Instance?)
	_updateSpotlight(button, uiRoot)
end

function TutorialController._TestClearSpotlight()
	_clearSpotlight()
end

-- True while the live beam is a clone of asset 17476697388 (specs only).
function TutorialController._TestIsAssetBeam(): boolean
	return _beamIsAsset == true
end

-- Destroy the live beam and reset asset tracking (specs only).
function TutorialController._TestResetBeam()
	_destroyBeam()
end

return TutorialController
