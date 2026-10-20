--!strict
--!native
--[[
	StandDisplayService
	====================
	Server-side publisher for the per-stand menu readout AND
	the MenuGui action-button reconciliation:

	Stand.Slot.MenuPart.MenuGui
	└── UpgradeButton (animal slots, fills the whole MenuGui)
	    ├── Level         (TextLabel) — `"<L> >> <L+1>"` / `"MAX"`
	    └── UpgradeAmount (TextLabel) — `"$<formatted cost>"` / max state

	Exactly ONE action button. No UIListLayout, no LayoutOrder,
	no half-height splits: the button always covers its MenuGui
	100%. Normal and arena stands share this pipeline (same
	template, same code) — only the occupant data differs.

	No SellButton anywhere: selling lives on the animal's
	Sell prompt (eggs are not sellable).

	Buttons are cloned from the authored template
	(`ServerStorage.Assets.Map.Bases.Base.Ui.Stand.
	UpgradeButtonTemplate`) — never rebuilt in code. Authored
	direct buttons already living in a MenuGui are reused
	in place (never destroyed); a missing UpgradeButton is
	cloned, tagged `StandMenuManaged`, and reused across
	refreshes. Desired set per state — IDENTICAL on normal
	and arena stands: animal → Upgrade only, egg/empty/other
	→ none (managed clones destroyed, authored SellButtons
	hidden — never destroyed).

	Display ONLY: every value is derived here from
	authoritative state (runtime records + `UpgradeService`
	cost calc + `BigNumber` formatting — the same sources the
	real transactions use). The client never submits values,
	and the server recalculates everything at transaction
	time, so labels can never diverge into authority.

	Refresh triggers (all event-driven, no loops, no scans):
	  * SlotService stand-display callback on Occupy / Demote /
	    Release and on RebaseSlotIds (assignment re-stamp).
	  * SlotMenuService upgrade-confirm success path.
	  * Steal/rollback paths via RefreshDisplays.
	Each refresh touches exactly one stand. RefreshSlot never
	throws: transitions must never break because of display
	code, so the reconcile body is guarded end to end.

	In-world SellAmount is best-effort cached (refreshed on
	the triggers above); the menu-confirm path always shows
	live values on demand. Pool growth between refreshes
	does not repaint labels (no per-tick churn by design).
]]

local LevelConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)

local StandDisplayService = {}

-- --- Injected service refs (wired by bootstrap) -------------------

local animalServiceRef: any = nil
local upgradeServiceRef: any = nil

function StandDisplayService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function StandDisplayService.SetUpgradeService(svc: any)
	upgradeServiceRef = svc
end

function StandDisplayService.SetSellService(_svc: any)
	-- Compat shim: the menu no longer paints sale totals
	-- (selling lives on the Sell prompt). Kept so bootstrap
	-- wiring is untouched.
end

function StandDisplayService.SetEggService(_svc: any)
	-- Compat shim: egg occupants need no menu service.
	-- Kept so bootstrap wiring is untouched.
end

function StandDisplayService.SetPlayerService(_svc: any)
	-- Compat shim: the menu paints no player-scoped sale
	-- data anymore. Kept so bootstrap wiring is untouched.
end

-- --- Internal state -------------------------------------------------

-- Empty-state handling: a stand that holds no upgradeable
-- Animal (empty / reserved / egg / owner-mismatch) is painted
-- to an EXPLICIT empty state (both labels cleared, maxed
-- cleared). Studio-authored label defaults are NEVER restored:
-- they are placeholder values (e.g. a default cost) that must
-- never leak into a live stand's readout after a
-- steal/pickup/place transition.
local function _writeLabels(parts: any, levelText: string?, costText: string?, maxed: boolean)
	if parts.levelLabel then
		local label = parts.levelLabel :: TextLabel
		label.Text = levelText or ''
	end
	if parts.costLabel then
		local label = parts.costLabel :: TextLabel
		label.Text = costText or ''
	end
	if parts.upgradeButton then
		-- The client direct-upgrade binding reads this to skip
		-- pointless maxed-out requests locally. The server
		-- still validates MaxLevel on every request.
		(parts.upgradeButton :: Instance):SetAttribute('maxed', maxed)
	end
end

-- Resolve the upgradeable Animal for a slot, or nil. Display
-- only: an occupant that fails any check renders as empty.
local function _resolveAnimal(slot: any): any?
	if type(slot) ~= 'table' then
		return nil
	end
	if slot.state ~= 'Occupied' or slot.occupantKind ~= 'animal' then
		return nil
	end
	if type(slot.occupantId) ~= 'string' then
		return nil
	end
	if not animalServiceRef or not animalServiceRef.Get then
		return nil
	end
	local ok, animal = pcall(animalServiceRef.Get, slot.occupantId)
	if not ok or type(animal) ~= 'table' then
		return nil
	end
	if animal.ownerUserId ~= slot.ownerUserId then
		return nil
	end
	-- Arena deployment: a parked animal's stand renders as empty
	-- (no Upgrade affordance) until it is restored. Slot
	-- ownership is untouched — only this menu readout changes.
	-- Guarded for test doubles that only stub Get.
	if animalServiceRef.IsArenaDeployed then
		local deployedOk, deployed = pcall(animalServiceRef.IsArenaDeployed, slot.occupantId)
		if deployedOk and deployed == true then
			return nil
		end
	end
	return animal
end

-- --- Template resolution --------------------------------------------

local MANAGED_ATTR = 'StandMenuManaged'

local upgradeTemplateCache: Instance? = nil
local warnedKeys: { [string]: boolean } = {}

local function warnOnce(key: string, message: string)
	if warnedKeys[key] then
		return
	end
	warnedKeys[key] = true
	Debug.Warn('StandMenu', message)
end

local function templateRoot(): Instance?
	local ServerStorage = game:GetService('ServerStorage')
	local assets = ServerStorage:FindFirstChild('Assets')
	local map = assets and assets:FindFirstChild('Map') or nil
	local bases = map and map:FindFirstChild('Bases') or nil
	local base = bases and bases:FindFirstChild('Base') or nil
	local ui = base and base:FindFirstChild('Ui') or nil
	return ui and ui:FindFirstChild('Stand') or nil
end

-- Resolve a button template by name. Cached with
-- Parent-validity recheck (mirrors the stand-template
-- pattern). Returns nil + one warn on any gap — callers
-- skip that button, never the whole refresh.
local function resolveTemplate(name: string): Instance?
	local cache = upgradeTemplateCache
	if cache ~= nil and cache.Parent ~= nil then
		return cache
	end
	local root = templateRoot()
	local found: Instance? = nil
	if root ~= nil then
		local node = root:FindFirstChild(name)
		if node ~= nil and node:IsA('TextButton') then
			found = node
		elseif node ~= nil then
			warnOnce('template-class-' .. name, name .. ' is not a TextButton (got ' .. node.ClassName .. ')')
		end
	end
	if found == nil then
		warnOnce(
			'template-missing-' .. name,
			'Missing ' .. name .. ' at ServerStorage.Assets.Map.Bases.Base.Ui.Stand.' .. name
		)
	else
		upgradeTemplateCache = found
	end
	return found
end

-- --- Managed-button reconciliation -------------------------------------

-- Direct children of a MenuGui carrying our managed tag, by
-- button name. Authored instances are never included here.
-- Only UpgradeButton is managed now: selling lives on the
-- animal's Sell prompt, never in the menu.
local function managedButtons(menuGui: Instance): { [string]: Instance }
	local out: { [string]: Instance } = {}
	for _, child in ipairs(menuGui:GetChildren()) do
		if child.Name == 'UpgradeButton' and child:GetAttribute(MANAGED_ATTR) == true then
			out[child.Name] = child
		end
	end
	return out
end

-- First direct child with `name` NOT carrying our tag (i.e.
-- authored). Nil when the only instances are managed.
local function authoredButton(menuGui: Instance, name: string): Instance?
	for _, child in ipairs(menuGui:GetChildren()) do
		if child.Name == name and child:GetAttribute(MANAGED_ATTR) ~= true then
			return child
		end
	end
	return nil
end

-- Single-button geometry: the UpgradeButton ALWAYS fills its
-- MenuGui (one action only). Applied to managed clones AND
-- reused authored buttons alike, so both stand types render
-- identically regardless of template authoring.
local function fitButton(button: Instance)
	pcall(function()
		if (button :: Instance):IsA('GuiObject') then
			local guiObj = button :: GuiObject
			guiObj.AnchorPoint = Vector2.new(0, 0)
			guiObj.Position = UDim2.fromScale(0, 0)
			guiObj.Size = UDim2.fromScale(1, 1)
		end
	end)
end

-- Remove obsolete list layout left over from the old
-- multi-button arrangement. A UIListLayout would fight the
-- full-coverage geometry above (positioning/sizing the single
-- button by list rules), so direct-child layouts go. Scoped
-- to this MenuGui only — nothing elsewhere is touched.
local function removeObsoleteLayout(menuGui: Instance)
	pcall(function()
		for _, child in ipairs((menuGui :: Instance):GetChildren()) do
			if child:IsA('UIListLayout') then
				child:Destroy()
			end
		end
	end)
end

-- Clone a template into the MenuGui as a managed button.
-- Returns the clone or nil (template gap). Caller parents
-- LAST implicitly: stamp + geometry are set before the
-- Parent assignment so the client filter never observes a
-- half-installed button.
local function cloneButton(template: Instance, name: string, menuGui: Instance, slotId: string): Instance?
	local clone: Instance? = nil
	local ok = pcall(function()
		local inst = (template :: Instance):Clone()
		inst.Name = name
		inst:SetAttribute(MANAGED_ATTR, true)
		fitButton(inst)
		inst:SetAttribute('slotId', slotId)
		inst.Parent = menuGui
		clone = inst
	end)
	if not ok or clone == nil then
		warnOnce('clone-failed-' .. name, 'Failed to clone ' .. name .. ' template')
		return nil
	end
	-- Breadcrumb: proves the runtime MenuGui received its
	-- managed button (client binds off slotId next).
	Debug.Log('StandMenu', ('cloned %s into %s slot=%s'):format(name, menuGui:GetFullName(), tostring(slotId)))
	return clone
end

-- NOTE: sale helpers (sale-text painter, pool lookup,
-- trait/mutation shaping, egg resolver) were deleted here.
-- Selling lives on the animal's Sell prompt (eggs are not
-- sellable), so the menu never needs them.

-- --- Public API -----------------------------------------------------

function StandDisplayService.Init() end

-- Labels of an upgrade button (managed clone or authored):
-- Level / UpgradeAmount TextLabels when present.
local function upgradeLabelsOf(button: Instance?): { [string]: any }
	if button == nil then
		return { levelLabel = nil, costLabel = nil, upgradeButton = nil }
	end
	local level: Instance? = nil
	local cost: Instance? = nil
	pcall(function()
		local l = (button :: Instance):FindFirstChild('Level')
		if l ~= nil and l:IsA('TextLabel') then
			level = l
		end
		local c = (button :: Instance):FindFirstChild('UpgradeAmount')
		if c ~= nil and c:IsA('TextLabel') then
			cost = c
		end
	end)
	return { levelLabel = level, costLabel = cost, upgradeButton = button }
end

-- Upgrade readout paint over a label-parts table (managed
-- clone or authored button — identical logic, identical
-- sources as before).
local function paintUpgrade(paintParts: any, slot: any, animal: any?)
	if animal == nil then
		_writeLabels(paintParts, nil, nil, false)
		return
	end
	local level = animal.Level
	if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 then
		level = 1
	end
	if level > LevelConfig.MaxLevel then
		level = LevelConfig.MaxLevel
	end
	if level >= LevelConfig.MaxLevel then
		_writeLabels(paintParts, 'MAX', 'MAX', true)
		return
	end
	local definitionId = animal.definitionId
	local cost: string? = nil
	if
		type(definitionId) == 'string'
		and definitionId ~= ''
		and upgradeServiceRef
		and upgradeServiceRef.GetUpgradeCost
	then
		local ok, value = pcall(upgradeServiceRef.GetUpgradeCost, definitionId, level)
		if ok and type(value) == 'string' then
			cost = value
		end
	end
	if cost == nil then
		Debug.Warn('SD', 'StandDisplayService: no upgrade cost; showing unavailable state', {
			slotId = tostring(slot.id),
			definitionId = tostring(definitionId),
			level = tostring(level),
		})
		_writeLabels(paintParts, ('%d >> %d'):format(level, level + 1), 'Unavailable', false)
		return
	end
	_writeLabels(paintParts, ('%d >> %d'):format(level, level + 1), '$' .. BigNumber.Format(cost), false)
end

-- NOTE: sale-text painters (animal + egg) were deleted here.
-- Selling lives on the animal's Sell prompt (eggs are not
-- sellable), so the menu never paints sale text.

-- Recompute and repaint ONE slot's MenuGui + upgrade readout
-- right now. No-op on any unexpected shape, and NEVER throws,
-- so a slot transition can never break because of menu code.
--
-- Desired managed set per occupant (authored buttons are
-- reused in place and never destroyed; managed clones are
-- created/destroyed to match exactly). IDENTICAL for normal
-- and arena stands; the single button always fills its
-- MenuGui (no list, no halves, no order):
--   animal            -> Upgrade only (full coverage)
--   egg/empty/other   -> none (managed destroyed, authored hidden)
function StandDisplayService.RefreshSlot(slot: any)
	if type(slot) ~= 'table' then
		return
	end
	local ok, err = pcall(function()
		local stand = slot.stand
		if typeof(stand) ~= 'Instance' then
			return
		end
		local parts = StandResolver.GetStandParts(stand)
		local menuGui = parts.menuGui

		local animal = _resolveAnimal(slot)
		-- Identical for AnimalStands and ArenaAnimalStands:
		-- only the OCCUPANT selects the button set. The menu
		-- owns UpgradeButton ONLY (animals); selling lives on
		-- the animal's Sell prompt and eggs have no sell UI.
		local wantUpgrade = animal ~= nil

		-- Legacy fail-safe: stands without a MenuGui keep the
		-- old direct-button readout behavior exactly.
		if menuGui == nil or not (menuGui :: Instance):IsA('SurfaceGui') then
			if parts.upgradeButton == nil then
				if animal ~= nil then
					warnOnce(
						'no-menugui-' .. tostring(slot.id),
						('StandDisplayService: animal-occupied slot %s has no MenuGui; upgrade UI unavailable'):format(
							tostring(slot.id)
						)
					)
				end
				return
			end
			paintUpgrade(parts, slot, animal)
			return
		end
		local gui = menuGui :: SurfaceGui
		-- Single-button menu: drop any obsolete list layout,
		-- then reconcile exactly 0 or 1 UpgradeButtons.
		removeObsoleteLayout(gui)
		local managed = managedButtons(gui)

		-- Upgrade button: authored instance wins when present;
		-- otherwise a managed template clone fills in. BOTH
		-- paths enforce the same full-MenuGui geometry, so
		-- normal and arena stands render identically.
		local upgradeButton: Instance? = authoredButton(gui, 'UpgradeButton')
		local managedUpgrade = managed.UpgradeButton
		if wantUpgrade then
			if upgradeButton == nil then
				if managedUpgrade ~= nil then
					upgradeButton = managedUpgrade
				else
					local template = resolveTemplate('UpgradeButtonTemplate')
					if template ~= nil then
						upgradeButton = cloneButton(template, 'UpgradeButton', gui, slot.id)
					end
				end
			end
			if upgradeButton ~= nil then
				fitButton(upgradeButton)
				pcall(function()
					(upgradeButton :: GuiObject).Visible = true
				end)
				paintUpgrade(upgradeLabelsOf(upgradeButton), slot, animal)
			end
		else
			if managedUpgrade ~= nil then
				pcall(function()
					(managedUpgrade :: Instance):Destroy()
				end)
			end
			local authored = authoredButton(gui, 'UpgradeButton')
			if authored ~= nil then
				-- Clear to the explicit empty state AND hide:
				-- a sold/moved stand must never show stale
				-- level/cost text (existing empty-state rule).
				paintUpgrade(upgradeLabelsOf(authored), slot, nil)
				pcall(function()
					(authored :: GuiObject).Visible = false
				end)
			end
		end

		-- Sell button: REMOVED by design. Selling lives on
		-- the animal's Sell prompt, never in the menu — for
		-- animals and eggs alike. Any managed clone left from
		-- an older reconciliation is destroyed; an authored
		-- SellButton (legacy places) is hidden so no stale
		-- affordance remains (server rejects menu sells anyway).
		for _, child in ipairs(gui:GetChildren()) do
			if child.Name == 'SellButton' and child:GetAttribute(MANAGED_ATTR) == true then
				pcall(function()
					(child :: Instance):Destroy()
				end)
			elseif child.Name == 'SellButton' and child:IsA('GuiObject') then
				pcall(function()
					(child :: GuiObject).Visible = false
				end)
			end
		end
	end)
	if not ok then
		warn(('[StandMenu] RefreshSlot failed: %s'):format(tostring(err)))
	end
end

-- Repaint every stand slot of a base, normal AND arena
-- (assignment / bulk paths). Arena upgrade readouts paint
-- through this exact path.
function StandDisplayService.RefreshBase(base: any)
	if type(base) ~= 'table' or type(base.slots) ~= 'table' then
		return
	end
	for _, slot in pairs(base.slots) do
		StandDisplayService.RefreshSlot(slot)
	end
	if type(base.arenaSlots) == 'table' then
		for _, slot in pairs(base.arenaSlots) do
			StandDisplayService.RefreshSlot(slot)
		end
	end
end

return table.freeze(StandDisplayService)
