--!strict
--!native
--[[
	AnimalOverhead
	==============
	Presentation-only live overhead GUI for runtime Animals.

	The authored template (ServerStorage.Assets.OverheadGui.
	OverheadGuiTemplate, a BillboardGui) is the visual source
	of truth: this module clones it onto each animal's anchor
	(CENTER when present, else the model's PrimaryPart) as
	`OverheadGui` and fills its fields from AUTHORITATIVE
	runtime state. It never computes gameplay values itself:

	  * Name    <- record.displayName (name ONLY; Level owns 'Lv. N')
	  * Level   <- record.Level ('Lv. N', the only level display)
	  * Income  <- AnimalStats.Calculate(record, 'Income')
	              (the EXACT call IncomeService ticks on, incl.
	              trait/mutation folds)
	  * Rarity  <- AnimalConfig.Get(definitionId) (record fallback)
	  * Trait   <- record.Trait (nil = hidden)
	  * Health/Damage <- AnimalStats.Calculate(record, ...)
	    (Damage = Health / 10 by the combat invariant)
	  * Data.{Damage,Health,MaxHealth} <- same snapshot mirror
	  * Mutations <- MutationConfig.SanitizeIds(record.Mutations),
	    one clone of the authored Mutation1 icon per id
	  * Numbers <- BigNumber.Format (the HUD display formatter)

	No mutable combat HP pool exists yet (Arena combat is not
	implemented): Data.Health and Data.MaxHealth both carry
	the canonical Health so the UI architecture is ready for
	live changes — one snapshot feeds all three values, and
	Refresh updates them without rebuilding.

	Event-driven, zero polling: callers invoke Refresh at the
	authoritative transitions (spawn, level-up). One shared
	Heartbeat drives ALL Rainbow animations (never
	per-animal). No RenderStepped, no connections per animal
	(except the shared rainbow tick), no Workspace scans.
	Duplicate-safe: exactly one overhead per model (enforced
	by hierarchy check, not memory; legacy OverheadTemplate
	clones are destroyed on sight). The GUI never touches
	PivotTo/ScaleTo/grounding — position drift is impossible
	by construction. Missing template/fields degrade to
	warn-once + skip; presentation never breaks gameplay.
]]

local ServerStorage = game:GetService('ServerStorage')
local RunService = game:GetService('RunService')

local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local MutationConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local OverheadConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.UI).Overhead
local AnimalStats = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MutationIcon = require(script.Parent.Parent.Utility.MutationIcon)

local AnimalOverhead = {}

-- --- Template resolution (Studio-authored, cached) ------------------

local _template: BillboardGui? = nil
local _templateValid = false
local _warnedMissing = false

local function _resolveTemplate(): BillboardGui?
	if _templateValid and _template ~= nil and (_template :: Instance).Parent ~= nil then
		return _template
	end
	_template = nil
	_templateValid = true
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local overhead = assets and assets:FindFirstChild('OverheadGui') or nil
		local found = overhead and overhead:FindFirstChild('AnimalOverheadGuiTemplate') or nil
		if found and found:IsA('BillboardGui') then
			_template = found
		end
	end)
	if _template == nil and not _warnedMissing then
		_warnedMissing = true
		Debug.Warn('AO', 'ServerStorage.Assets.OverheadGui.OverheadGuiTemplate missing — overheads disabled', {})
	end
	return _template
end

-- --- Small helpers ---------------------------------------------------

local function _validModel(model: any): boolean
	return typeof(model) == 'Instance' and (model :: Instance):IsA('Model') and (model :: Instance).Parent ~= nil
end

-- Anchor: authored CENTER when present, else PrimaryPart.
-- Never a random body part.
local function _anchorPart(model: Model): BasePart?
	local center = model:FindFirstChild('CENTER')
	if center and center:IsA('BasePart') then
		return center
	end
	local primary = model.PrimaryPart
	if primary and primary:IsA('BasePart') then
		return primary
	end
	return nil
end

local function _findGui(host: BasePart): BillboardGui?
	for _, child in ipairs(host:GetChildren()) do
		if child:IsA('BillboardGui') and child.Name == 'OverheadGui' then
			return child
		end
	end
	return nil
end

-- One-time migration: a legacy OverheadTemplate clone from
-- the retired template must never coexist with (or shadow)
-- the new OverheadGui. Destroyed on sight during Refresh /
-- Remove; never re-created.
local function _destroyLegacyGui(host: BasePart)
	pcall(function()
		for _, child in ipairs(host:GetChildren()) do
			if child:IsA('BillboardGui') and child.Name == 'OverheadTemplate' then
				child:Destroy()
			end
		end
	end)
end

-- Content root of the new template: OverheadGui.Container.
-- Content. Every miss warns with identity (never silent).
-- (_diagWarn is forward-declared: defined with the
-- diagnostics below, assigned before any call runs.)
local _diagWarn: (any, string, string) -> () = nil :: any

local function _content(gui: BillboardGui, animal: any): Instance?
	local container = gui:FindFirstChild('Container')
	local content = container and container:FindFirstChild('Content') or nil
	if content == nil then
		_diagWarn(animal, 'missing-content', 'Missing Container.Content under OverheadGui')
		return nil
	end
	return content
end

-- Display-safe level: authoritative record Level clamped into
-- 1..MaxLevel (never 101+), '?' when unusable.
local function _displayLevel(animal: any): string
	local level = animal and animal.Level
	if type(level) ~= 'number' or level ~= level or level == math.huge then
		return '?'
	end
	local ok, clamped = pcall(LevelConfig.Normalize, level, 0)
	if not ok or type(clamped) ~= 'number' then
		return tostring(math.floor(level))
	end
	return tostring(clamped)
end

-- Display-safe BigNumber compression of a stat float. Floors
-- once at the display boundary (the authoritative value keeps
-- full precision); falls back to '0' on any failure.
local function _displayStat(value: number?): string
	if type(value) ~= 'number' or value ~= value or value == math.huge or value < 0 then
		return '0'
	end
	local ok, text = pcall(BigNumber.Format, tostring(math.floor(value)))
	if not ok or type(text) ~= 'string' then
		return '0'
	end
	return text
end

local function _setText(parent: Instance?, name: string, text: string)
	if parent == nil then
		return
	end
	pcall(function()
		local label = parent:FindFirstChild(name)
		if label and label:IsA('TextLabel') then
			label.Text = text
		end
	end)
end

-- --- Stats diagnostics (warn-once per animal+step) ---------------------

-- Every HP/Damage failure warns with animal identity instead of
-- returning silently. Keys clear on the next FULLY successful
-- stats update so a later regression re-warns. No polling, so
-- warnings fire at most once per failure episode.
local _diagWarned: { [string]: boolean } = {}

local function _diagId(animal: any): string
	if type(animal) == 'table' and type(animal.uniqueId) == 'string' then
		return animal.uniqueId
	end
	return 'unknown'
end

local function _diagIdentity(animal: any): string
	local id, name, defId, modelName, level, owner = '?', '?', '?', '?', '?', '?'
	if type(animal) == 'table' then
		if type(animal.uniqueId) == 'string' then
			id = animal.uniqueId
		end
		if type(animal.displayName) == 'string' then
			name = animal.displayName
		end
		local def = animal.definitionId or animal.DefId
		if type(def) == 'string' then
			defId = def
		end
		if type(animal.Level) == 'number' then
			level = tostring(animal.Level)
		end
		if type(animal.ownerUserId) == 'number' then
			owner = tostring(animal.ownerUserId)
		end
		local model = animal.model
		if typeof(model) == 'Instance' then
			modelName = (model :: Instance).Name
		end
	end
	return ('animal=%s name=%s def=%s level=%s owner=%s model=%s'):format(id, name, defId, level, owner, modelName)
end

_diagWarn = function(animal: any, step: string, message: string)
	local key = _diagId(animal) .. ':' .. step
	if _diagWarned[key] then
		return
	end
	_diagWarned[key] = true
		Debug.Warn('AnimalOverhead', ('[Stats] %s | %s'):format(message, _diagIdentity(animal)))
end

local function _diagClear(animal: any)
	local prefix = _diagId(animal) .. ':'
	for key in pairs(_diagWarned) do
		if string.sub(key, 1, #prefix) == prefix then
			_diagWarned[key] = nil
		end
	end
end

-- New-template stat paths (exact authored hierarchy — never
-- guessed, never scanned):
--   Content.Stats.Damage.Value, Content.Stats.Health.Value,
--   OverheadGui.Data.{Damage, Health, MaxHealth}. Health has
--   no bar in the new template (Icon + Value, like Damage).
local function _statsFrame(content: Instance, animal: any): Instance?
	local stats = content:FindFirstChild('Stats')
	if stats == nil then
		_diagWarn(animal, 'missing-stats', 'Missing Stats frame under Content')
		return nil
	end
	return stats
end

local function _statValueLabel(stats: Instance, frameName: string, animal: any): TextLabel?
	local frame = stats:FindFirstChild(frameName)
	if frame == nil then
		_diagWarn(animal, 'missing-' .. frameName, ('Missing %s frame under Stats'):format(frameName))
		return nil
	end
	local value = frame:FindFirstChild('Value')
	if value ~= nil and value:IsA('TextLabel') then
		return value
	end
	_diagWarn(animal, 'missing-value-' .. frameName, ('Missing Value under Stats.%s'):format(frameName))
	return nil
end

local _warnedData = false

local function _dataValues(gui: BillboardGui): { [string]: NumberValue? }
	local out: { [string]: NumberValue? } = { Damage = nil, Health = nil, MaxHealth = nil }
	local data = gui:FindFirstChild('Data')
	if data == nil then
		if not _warnedData then
			_warnedData = true
			Debug.Warn('AO', 'OverheadGui.Data folder missing — Data mirror skipped', {})
		end
		return out
	end
	for _, key in ipairs({ 'Damage', 'Health', 'MaxHealth' }) do
		local node = data:FindFirstChild(key)
		if node ~= nil and node:IsA('NumberValue') then
			out[key] = node
		elseif not _warnedData then
			_warnedData = true
			Debug.Warn('AO', ('OverheadGui.Data.%s NumberValue missing — mirror partial'):format(key), {})
		end
	end
	return out
end

-- --- Live visual styling (rarity + trait) ----------------------------

-- Trait presentation colors. Canonical source: OverheadConfig
-- (TraitConfig carries multipliers only — data vs style split).
local TRAIT_COLORS: { [string]: Color3 } = OverheadConfig.TraitColors
local WHITE = OverheadConfig.FallbackColor

local function _rarityColor(rarity: any): Color3
	local found: Color3? = nil
	pcall(function()
		local table_ = RarityConfig.RarityColor
		if type(table_) == 'table' and type(rarity) == 'string' then
			found = table_[rarity]
		end
	end)
	if typeof(found) ~= 'Color3' then
		return WHITE
	end
	return found :: Color3
end

-- Sheen gradient derived from a canonical color (white to
-- color). Reuses the existing color system — no second table.
-- Applied to the CLONE's authored UIGradient; the template's
-- own gradient is never touched.
local function _sheenSequence(color: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(1, color),
	})
end

local function _styleLabel(label: TextLabel, color: Color3)
	pcall(function()
		label.TextColor3 = color
		for _, child in ipairs(label:GetChildren()) do
			if child:IsA('UIGradient') then
				child.Color = _sheenSequence(color);
				(child :: UIGradient).Enabled = true
			end
		end
	end)
end

-- Centralized Rainbow controller: ONE shared Heartbeat for every
-- Rainbow overhead in the server (never per-animal). Each tick
-- advances the authored UIGradient.Offset on registered
-- gradients; the sequence wraps seamlessly (starts and ends on
-- red). Entries drop out lazily when destroyed; the connection
-- disconnects itself when the set empties. Purely visual.
local RAINBOW_PERIOD = OverheadConfig.Rainbow.Period
local RAINBOW_STOPS = OverheadConfig.Rainbow.Stops
local function _buildRainbowSequence(): ColorSequence
	local points: { ColorSequenceKeypoint } = {}
	for _, stop in ipairs(RAINBOW_STOPS) do
		points[#points + 1] = ColorSequenceKeypoint.new(stop.At, stop.Color)
	end
	return ColorSequence.new(points)
end
local RAINBOW_SEQUENCE = _buildRainbowSequence()
local _rainbow: { [UIGradient]: boolean } = setmetatable({}, { __mode = 'k' })
local _rainbowStrokes: { [UIStroke]: boolean } = setmetatable({}, { __mode = 'k' })
local _rainbowConn: RBXScriptConnection? = nil

local function _rainbowTick()
	local t = (os.clock() % RAINBOW_PERIOD) / RAINBOW_PERIOD
	local empty = true
	for grad in pairs(_rainbow) do
		if grad.Parent == nil then
			_rainbow[grad] = nil
		else
			empty = false
			pcall(function()
				grad.Offset = Vector2.new(-t, 0)
			end)
		end
	end
	for stroke in pairs(_rainbowStrokes) do
		if stroke.Parent == nil then
			_rainbowStrokes[stroke] = nil
		else
			empty = false
			pcall(function()
				stroke.Color =
					Color3.fromHSV(t, OverheadConfig.Rainbow.StrokeSaturation, OverheadConfig.Rainbow.StrokeValue)
			end)
		end
	end
	if empty and _rainbowConn ~= nil then
		pcall(function()
			(_rainbowConn :: RBXScriptConnection):Disconnect()
		end)
		_rainbowConn = nil
	end
end

local function _ensureRainbowLoop()
	if _rainbowConn ~= nil then
		return
	end
	pcall(function()
		_rainbowConn = RunService.Heartbeat:Connect(_rainbowTick)
	end)
end

local function _registerRainbow(grad: UIGradient)
	pcall(function()
		grad.Color = RAINBOW_SEQUENCE
	end)
	_rainbow[grad] = true
	_ensureRainbowLoop()
end

local function _unregisterRainbow(grad: UIGradient)
	_rainbow[grad] = nil
end

local function _unregisterLabelGradients(label: TextLabel)
	pcall(function()
		for _, child in ipairs(label:GetChildren()) do
			if child:IsA('UIGradient') then
				_unregisterRainbow(child)
			end
		end
	end)
end

-- Rainbow STROKE animation (new template: Trait carries a
-- Stroke but no UIGradient, so there is nothing to offset).
-- Same shared tick, same lifecycle rules as gradients: hue
-- rotates centrally, entries drop lazily when destroyed, no
-- per-animal connections. Weak keys: dead strokes vanish
-- without explicit cleanup.
local function _registerRainbowStroke(stroke: UIStroke)
	_rainbowStrokes[stroke] = true
	_ensureRainbowLoop()
end

local function _unregisterRainbowStroke(stroke: UIStroke)
	_rainbowStrokes[stroke] = nil
end

local function _unregisterLabelStrokes(label: TextLabel)
	pcall(function()
		for _, child in ipairs(label:GetChildren()) do
			if child:IsA('UIStroke') then
				_unregisterRainbowStroke(child)
			end
		end
	end)
end

-- --- Field population (authoritative reads only) ---------------------

local function _populate(gui: BillboardGui, animal: any, isInit: boolean?)
	local content = _content(gui, animal)
	if not content then
		return
	end
	do
		local definitionId = animal.definitionId or animal.DefId
		local rarity: string? = nil
		pcall(function()
			local r = AnimalConfig.Get(definitionId)
			if type(r) == 'string' then
				rarity = r
			end
		end)
		if type(rarity) ~= 'string' then
			pcall(function()
				if type(animal.rarity) == 'string' then
					rarity = animal.rarity
				end
			end)
		end
		-- Rarity: text + canonical color + derived gradient, always
		-- overwritten together so a previous rarity's styling can
		-- never linger. Unresolvable rarity leaves the label
		-- untouched (never blank a good label on a bad read).
		if type(rarity) == 'string' and rarity ~= '' then
			pcall(function()
				local label = content:FindFirstChild('Rarity')
				if label and label:IsA('TextLabel') then
					label.Text = rarity
					_styleLabel(label, _rarityColor(rarity))
				end
			end)
		end
		-- Trait: full reconcile every refresh (text + color +
		-- animation + visibility + rainbow state). Stale text,
		-- stale colors, and orphaned rainbow registrations are
		-- impossible: every branch overwrites or hides. The new
		-- template carries a Stroke (no UIGradient) under Trait,
		-- so Rainbow animates the stroke hue through the shared
		-- centralized tick; authored gradients (if ever present)
		-- keep the legacy offset animation.
		pcall(function()
			local label = content:FindFirstChild('Trait')
			if not (label and label:IsA('TextLabel')) then
				return
			end
			local typed = label :: TextLabel
			_unregisterLabelGradients(typed)
			_unregisterLabelStrokes(typed)
			local trait = animal.Trait
			if type(trait) ~= 'string' or trait == '' then
				typed.Visible = false
				return
			end
			typed.Text = trait
			typed.Visible = true
			if trait == 'Rainbow' then
				typed.TextColor3 = WHITE
				for _, child in ipairs(typed:GetChildren()) do
					if child:IsA('UIGradient') then
						_registerRainbow(child)
					elseif child:IsA('UIStroke') then
						_registerRainbowStroke(child)
					end
				end
			else
				_styleLabel(typed, TRAIT_COLORS[trait] or WHITE)
			end
		end)
		-- Name + live level. Name keeps the existing single-label
		-- format; Level gets its own label in the same convention.
		local displayName: string = 'Animal'
		pcall(function()
			if type(animal.displayName) == 'string' and animal.displayName ~= '' then
				displayName = animal.displayName
			elseif type(definitionId) == 'string' and definitionId ~= '' then
				displayName = definitionId
			end
		end)
		_setText(content, 'Name', displayName)
		_setText(content, 'Level', 'Lv. ' .. _displayLevel(animal))
		-- Income: the EXACT IncomeService rate call (trait +
		-- mutation folds included by AnimalStats).
		local incomeText = '$0/s'
		pcall(function()
			local income = AnimalStats.Calculate(animal, 'Income')
			incomeText = '$' .. _displayStat(income) .. '/s'
		end)
		_setText(content, 'Income', incomeText)
		-- Arena participation: combat overheads carry the
		-- transient `arenaDeployed` flag (set at the single
		-- Arena battle-spawn site for BOTH player and enemy
		-- combatants). While set, Generation/Income hides;
		-- every other overhead keeps it visible. Reversible
		-- by construction: non-arena records always re-show,
		-- and combat records die with the battle. Deliberately
		-- log-free: this runs on every combat HP refresh.
		local inArena = type(animal) == 'table' and (animal :: any).arenaDeployed == true
		pcall(function()
			local income = content:FindFirstChild('Income')
			if income ~= nil and income:IsA('GuiObject') then
				(income :: GuiObject).Visible = not inArena
			end
		end)
	end
	-- Health / Damage / Data: ONE canonical snapshot feeds
	-- every combat value, so partial refreshes are impossible:
	--   Content.Stats.Damage.Value <- Damage
	--   Content.Stats.Health.Value <- live Health (no bar exists)
	--   Data.{Damage, Health, MaxHealth} <- same snapshot
	-- No mutable combat HP pool exists on persistent animals:
	-- MaxHealth IS the canonical Health. Temporary arena
	-- combatants carry live CurrentHealth, shown in Value and
	-- Data.Health while MaxHealth stays canonical.
	-- animal identity (never silent); success clears the warn
	-- keys so a later regression re-warns. Formatter checked
	-- before use, with a visible fallback + warn. All Text
	-- assignment is pcall-guarded WITH a warn on error (never
	-- a silent pcall).
	local function _resolveStat(statName: string): number?
		local ok, value = pcall(AnimalStats.Calculate, animal, statName)
		if not ok then
			_diagWarn(
				animal,
				'stat-error-' .. statName,
				('Failed to resolve authoritative %s: %s | def=%s'):format(
					statName,
					tostring(value),
					tostring(animal.definitionId or animal.DefId)
				)
			)
			return nil
		end
		if type(value) ~= 'number' then
			_diagWarn(
				animal,
				'stat-type-' .. statName,
				('Could not resolve %s for %s: resolver returned non-number type=%s'):format(
					statName,
					_diagIdentity(animal),
					type(value)
				)
			)
			return nil
		end
		if value ~= value or value == math.huge or value == -math.huge or value < 0 then
			_diagWarn(
				animal,
				'stat-invalid-' .. statName,
				('Could not resolve %s for %s: invalid value=%s'):format(
					statName,
					_diagIdentity(animal),
					tostring(value)
				)
			)
			return nil
		end
		return value
	end
	local health = _resolveStat('Health')
	local damage = _resolveStat('Damage')
	if health ~= nil and damage ~= nil then
		-- Single snapshot: current and max coincide for normal
		-- animals. Temporary arena combatants carry a live
		-- `CurrentHealth` number: the Value + Data.Health mirror
		-- show it (clamped to [0, MaxHealth]) while MaxHealth
		-- stays canonical. Absent/invalid override = max.
		local maxHealth = health
		local displayHealth = health
		local override = (animal :: any).CurrentHealth
		if type(override) == 'number' and override == override and override >= 0 then
			displayHealth = math.min(override, maxHealth)
		end
		local formatterOk = type(BigNumber) == 'table' and type(BigNumber.Format) == 'function'
		if not formatterOk then
			_diagWarn(animal, 'no-formatter', 'Number formatter unavailable (BigNumber.Format)')
		end
		local function _formatStat(value: number, statName: string): string
			if formatterOk then
				local okFmt, text = pcall(BigNumber.Format, tostring(math.floor(value)))
				if okFmt and type(text) == 'string' then
					return text
				end
				_diagWarn(
					animal,
					'format-failed-' .. statName,
					('Number formatter failed for %s; using fallback'):format(statName)
				)
			end
			return tostring(math.floor(value))
		end
		local hpText = _formatStat(displayHealth, 'Health')
		local dmgText = _formatStat(damage, 'Damage')
		local stats = _statsFrame(content, animal)
		local dmgValue = stats and _statValueLabel(stats, 'Damage', animal) or nil
		local hpValue = stats and _statValueLabel(stats, 'Health', animal) or nil
		local dataValues = _dataValues(gui)
		local assignOk, assignErr = pcall(function()
			if dmgValue then
				dmgValue.Text = dmgText
			end
			if hpValue then
				hpValue.Text = hpText
			end
			if dataValues.Damage then
				local damageValue = dataValues.Damage :: NumberValue
				damageValue.Value = damage
			end
			if dataValues.Health then
				local healthValue = dataValues.Health :: NumberValue
				healthValue.Value = displayHealth
			end
			if dataValues.MaxHealth then
				local maxValue = dataValues.MaxHealth :: NumberValue
				maxValue.Value = maxHealth
			end
		end)
		if not assignOk then
			_diagWarn(animal, 'assign-failed', ('Failed to update stats: %s'):format(tostring(assignErr)))
		end
		if dmgValue and hpValue and assignOk then
			local verb = if isInit then 'Initialized' else 'Updating'
						Debug.Warn('AnimalOverhead', ('[Stats] %s %s Damage raw=%s formatted=%s | %s'):format(
					verb,
					tostring(animal.displayName),
					tostring(damage),
					dmgText,
					_diagIdentity(animal)
				))
						Debug.Warn('AnimalOverhead', ('[Stats] %s %s Health raw=%s formatted=%s | %s'):format(
					verb,
					tostring(animal.displayName),
					tostring(health),
					hpText,
					_diagIdentity(animal)
				))
			Debug.Log('AO', 'stats update', {
				name = tostring(animal.displayName),
				healthRaw = tostring(health),
				healthFmt = hpText,
				damageRaw = tostring(damage),
				damageFmt = dmgText,
			})
			_diagClear(animal)
		end
	end
end

-- Mutation icons: one child per sanitized mutation id, cloned
-- from the authored Mutation1 prototype (no invented ImageIds —
-- clones inherit authored visuals). Fresh generic clones are
-- additionally stamped with the canonical mutation decal
-- (MutationIcon: Galactic->GalaxyIcon, Frost->SnowfallIcon);
-- Studio-authored per-id icon children are never touched.
-- Layout/padding nodes are never touched; stale icons are
-- destroyed; missing prototype skips icons (warn once).
-- Idempotent: re-running with the same set creates nothing.
local _warnedNoPrototype = false

local function _reconcileMutations(content: Instance, animal: any)
	pcall(function()
		local container = content:FindFirstChild('Mutations')
		if not container then
			return
		end
		local ids: { string } = {}
		pcall(function()
			ids = MutationConfig.SanitizeIds(animal.Mutations)
		end)
		if #ids == 0 then
			pcall(function()
				(container :: Instance):SetAttribute('hasMutations', false)
			end)
			for _, child in ipairs((container :: Instance):GetChildren()) do
				if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
					child:Destroy()
				end
			end
			if (container :: GuiObject):IsA('GuiObject') then
				(container :: GuiObject).Visible = false
			end
			return
		end
		if (container :: GuiObject):IsA('GuiObject') then
			(container :: GuiObject).Visible = true
		end
		-- Prototype: the authored Mutation1 icon (or any surviving
		-- mutation icon from a previous reconcile).
		local prototype: GuiObject? = nil
		for _, child in ipairs((container :: Instance):GetChildren()) do
			if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
				if child.Name == 'Mutation1' or prototype == nil then
					prototype = child
				end
			end
		end
		if prototype == nil then
			if not _warnedNoPrototype then
				_warnedNoPrototype = true
				Debug.Warn('AO', 'Mutations container has no icon prototype — skipping icons', {})
			end
			return
		end
		local wanted: { [string]: boolean } = {}
		for _, id in ipairs(ids) do
			wanted[id] = true
			local existing = (container :: Instance):FindFirstChild(id)
			if not (existing and existing:IsA('GuiObject')) then
				local clone = (prototype :: GuiObject):Clone()
				clone.Name = id
				clone.Visible = true
				clone.Parent = container
				-- Fresh generic clone only (authored per-id
				-- children keep their art): stamp the canonical
				-- mutation decal. Missing decal = keep
				-- prototype visuals, never an error.
				pcall(MutationIcon.PaintIcon, clone, id)
			end
		end
		for _, child in ipairs((container :: Instance):GetChildren()) do
			if child:IsA('GuiObject') and not child:IsA('UIListLayout') and not child:IsA('UIPadding') then
				if not wanted[child.Name] then
					child:Destroy()
				end
			end
		end
	end)
end

-- --- Visibility diagnostics (one-shot, init only) ---------------------

-- One-time [VIS_DEBUG] dump answering "it exists in Explorer
-- but renders nothing". Compares template vs clone, prints
-- every rendering-relevant BillboardGui property, the anchor
-- world position, and per-field visibility/text/size. Fires
-- once per overhead creation — never per frame, never per
-- refresh. Never throws.
local function _debugDump(gui: BillboardGui, host: BasePart, model: Model, animal: any)
	pcall(function()
		local lines: { string } = {}
		local function add(text: string)
			lines[#lines + 1] = text
		end
		local function prop(inst: Instance, name: string): string
			local ok, value = pcall(function()
				return (inst :: any)[name]
			end)
			if not ok then
				return '<unreadable>'
			end
			if typeof(value) == 'Instance' then
				return ('%s(%s)'):format(value.Name, value.ClassName)
			end
			if typeof(value) == 'UDim2' then
				return ('(%s,%d,%s,%d)'):format(
					tostring(value.X.Scale),
					value.X.Offset,
					tostring(value.Y.Scale),
					tostring(value.Y.Offset)
				)
			end
			if typeof(value) == 'Vector3' then
				return ('(%.1f,%.1f,%.1f)'):format(value.X, value.Y, value.Z)
			end
			return tostring(value)
		end
		add('[AnimalOverhead][VIS_DEBUG] animal=' .. _diagIdentity(animal))
		add(('CENTER=%s pos=%s'):format(host:GetFullName(), prop(host, 'Position')))
		pcall(function()
			add('pivot=' .. tostring(model:GetPivot().Position))
		end)
		add(
			('gui class=%s parent=%s Enabled=%s Adornee=%s AlwaysOnTop=%s MaxDistance=%s Size=%s StudsOffset=%s WS=%s ExtentsOffset=%s WS=%s LightInfluence=%s Brightness=%s ZIndex=%s Clips=%s Active=%s'):format(
				prop(gui, 'ClassName'),
				prop(gui.Parent, 'FullName') ~= '' and prop(gui, 'Parent') or prop(host, 'FullName'),
				prop(gui, 'Enabled'),
				prop(gui, 'Adornee'),
				prop(gui, 'AlwaysOnTop'),
				prop(gui, 'MaxDistance'),
				prop(gui, 'Size'),
				prop(gui, 'StudsOffset'),
				prop(gui, 'StudsOffsetWorldSpace'),
				prop(gui, 'ExtentsOffset'),
				prop(gui, 'ExtentsOffsetWorldSpace'),
				prop(gui, 'LightInfluence'),
				prop(gui, 'Brightness'),
				prop(gui, 'ZIndexBehavior'),
				prop(gui, 'ClipsDescendants'),
				prop(gui, 'Active')
			)
		)
		local template = _resolveTemplate()
		if template ~= nil then
			add(
				('template Enabled=%s Size=%s MaxDistance=%s AlwaysOnTop=%s StudsOffset=%s'):format(
					prop(template, 'Enabled'),
					prop(template, 'Size'),
					prop(template, 'MaxDistance'),
					prop(template, 'AlwaysOnTop'),
					prop(template, 'StudsOffset')
				)
			)
		else
			add('template=<unresolved>')
		end
		local function nodeAt(path: string): Instance?
			local current: Instance? = gui
			for segment in string.gmatch(path, '[^.]+') do
				current = current and (current :: Instance):FindFirstChild(segment) or nil
			end
			return current
		end
		for _, path in ipairs({
			'Container',
			'Container.Content',
			'Container.Content.Income',
			'Container.Content.Level',
			'Container.Content.Mutations',
			'Container.Content.Name',
			'Container.Content.Rarity',
			'Container.Content.Stats',
			'Container.Content.Stats.Damage',
			'Container.Content.Stats.Health',
			'Container.Content.Trait',
			'Data',
		}) do
			local target = nodeAt(path)
			if target == nil then
				add(path .. '=<MISSING>')
			else
				local text = ''
				pcall(function()
					if (target :: Instance):IsA('TextLabel') or (target :: Instance):IsA('TextButton') then
						text = ' text=' .. string.sub((target :: TextLabel).Text, 1, 40)
					end
				end)
				add(
					('%s class=%s Visible=%s Size=%s%s'):format(
						path,
						prop(target, 'ClassName'),
						prop(target, 'Visible'),
						prop(target, 'Size'),
						text
					)
				)
			end
		end
		for _, key in ipairs({ 'Damage', 'Health', 'MaxHealth' }) do
			local data = gui:FindFirstChild('Data')
			local value = data and data:FindFirstChild(key) or nil
			add(('Data.%s=%s'):format(key, value ~= nil and prop(value, 'Value') or '<MISSING>'))
		end
		local census: { [string]: number } = {}
		for _, desc in ipairs(gui:GetDescendants()) do
			census[desc.ClassName] = (census[desc.ClassName] or 0) + 1
		end
		local parts: { string } = {}
		for className, count in pairs(census) do
			parts[#parts + 1] = className .. 'x' .. tostring(count)
		end
		table.sort(parts)
		add('census: ' .. table.concat(parts, ', '))
		Debug.Warn('AO', table.concat(lines, '\n'))
	end)
end

-- --- Public API -------------------------------------------------------

-- Create-or-refresh the overhead for an animal record. Returns
-- true when a live overhead exists afterward. Never throws,
-- never yields the caller; never touches transforms.
-- Event-driven (spawn / level-up callers); no Heartbeat, no
-- polling. Every HP/Damage pipeline gap warns with the
-- [AnimalOverhead][Stats] prefix + animal identity (never a
-- silent return); pcall errors warn instead of vanishing.
function AnimalOverhead.Refresh(animal: any): boolean
	local done = false
	local ok, err = pcall(function()
		if type(animal) ~= 'table' then
			warn('[AnimalOverhead][Stats] Missing Animal runtime (record is not a table)')
			return
		end
		local model = animal.model
		if not _validModel(model) then
			_diagWarn(animal, 'missing-model', 'Missing model for animal (model not a live Model)')
			return
		end
		local template = _resolveTemplate()
		if not template then
			_diagWarn(animal, 'missing-template', 'Missing Overhead BillboardGui template')
			return
		end
		local host = _anchorPart(model :: Model)
		if not host then
			_diagWarn(
				animal,
				'missing-center',
				('Missing CENTER for animal (no CENTER attachment and no PrimaryPart) | model=%s'):format(
					(model :: Model).Name
				)
			)
			return
		end
		local gui = _findGui(host)
		local isInit = false
		if not gui then
			local clone = template:Clone()
			clone.Name = 'OverheadGui'
			clone.Parent = host
			gui = clone
			isInit = true
		end
		if not gui then
			_diagWarn(animal, 'missing-overhead', 'Missing Overhead BillboardGui on anchor after clone')
			return
		end
		-- Explicit runtime configuration (set once at init —
		-- never per frame): the clone renders if and only if
		-- it is enabled and anchored. Adornee is set even
		-- though parenting under CENTER usually suffices;
		-- explicit is robust against template drift.
		if isInit then
			pcall(function()
				local billboard = gui :: BillboardGui
				billboard.Enabled = true
				billboard.Adornee = host
			end)
		end
		-- Migration: a legacy OverheadTemplate clone from the
		-- retired template must never coexist with the new GUI.
		_destroyLegacyGui(host)
		if isInit then
			_debugDump(gui :: BillboardGui, host, model :: Model, animal)
		end
		_populate(gui :: BillboardGui, animal, isInit)
		local content = _content(gui :: BillboardGui, animal)
		if content then
			_reconcileMutations(content, animal)
		end
		done = true
	end)
	if not ok then
		if type(animal) == 'table' then
			_diagWarn(animal, 'refresh-failed', ('Failed to update stats: %s'):format(tostring(err)))
		else
			warn(('[AnimalOverhead][Stats] Failed to update stats: %s'):format(tostring(err)))
		end
	end
	return done
end

-- Alias with lifecycle spelling (create path reads the same).
function AnimalOverhead.EnsureForAnimal(animal: any): boolean
	return AnimalOverhead.Refresh(animal)
end

-- Destroy the overhead for an animal record (model teardown
-- usually beats this — children die with the model — but
-- record-drop paths without model death stay clean).
-- Rainbow registrations under the gui are dropped first so no
-- orphaned animation survives the destroy.
function AnimalOverhead.RemoveForAnimal(animal: any)
	pcall(function()
		if type(animal) ~= 'table' then
			return
		end
		local model = animal.model
		if not _validModel(model) then
			return
		end
		local host = _anchorPart(model :: Model)
		if not host then
			return
		end
		local gui = _findGui(host)
		if gui then
			pcall(function()
				for _, desc in ipairs((gui :: BillboardGui):GetDescendants()) do
					if desc:IsA('UIGradient') then
						_unregisterRainbow(desc)
					elseif desc:IsA('UIStroke') then
						_unregisterRainbowStroke(desc)
					end
				end
			end)
			gui:Destroy()
		end
		_destroyLegacyGui(host)
	end)
end

-- TEST-ONLY seam: resolve the live overhead for assertions
-- (nil when absent). Never throws.
function AnimalOverhead._TestFind(animal: any): Instance?
	local found: Instance? = nil
	pcall(function()
		if type(animal) ~= 'table' then
			return
		end
		if not _validModel(animal.model) then
			return
		end
		local host = _anchorPart(animal.model :: Model)
		if host then
			found = _findGui(host)
		end
	end)
	return found
end

-- --- Stolen presentation (temporary steal-carry state) -----------
--
-- While an animal is steal-carried, its overhead shows ONLY the
-- name label reading STOLEN in the canonical stolen red; every
-- other overhead Label/Frame is temporarily hidden. Nothing is
-- destroyed and the record's displayName is never touched —
-- this is purely visual. Delivery/rollback restores the EXACT
-- previous state (original name, color, and each label's own
-- prior visibility — never a blind Visible = true).
--
-- State lives HERE (module-local, keyed by uniqueId), never on
-- the record (records serialize to the profile) and never
-- inferred from hierarchy. Event-driven: StealService calls
-- SetStolen at steal start (true) and at every steal exit
-- (false: complete + all rollback tiers). Idempotent: setting
-- an already-stolen animal re-applies visuals without
-- overwriting the saved originals; clearing a non-stolen
-- animal is a no-op. Never throws; returns true when the
-- requested state holds afterward.
local _stolen: { [string]: any } = {}

local function _stolenContent(animal: any): (Instance?, Instance?)
	local gui: Instance? = nil
	local content: Instance? = nil
	pcall(function()
		if type(animal) ~= 'table' or type(animal.uniqueId) ~= 'string' then
			return
		end
		if not _validModel(animal.model) then
			return
		end
		local host = _anchorPart(animal.model :: Model)
		local live = host and _findGui(host) or nil
		if live then
			gui = live
			content = _content(live, animal)
		end
	end)
	return gui, content
end

local function _applyStolenVisuals(content: Instance)
	pcall(function()
		for _, child in ipairs(content:GetChildren()) do
			if child:IsA('GuiObject') and child.Name ~= 'Name' then
				(child :: GuiObject).Visible = false
			end
		end
		local nameLabel = content:FindFirstChild('Name')
		if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
			(nameLabel :: TextLabel).Text = 'STOLEN'
			(nameLabel :: TextLabel).TextColor3 = OverheadConfig.StolenTextColor
		end
	end)
end

function AnimalOverhead.SetStolen(animal: any, stolen: boolean): boolean
	local done = false
	pcall(function()
		if type(animal) ~= 'table' or type(animal.uniqueId) ~= 'string' then
			return
		end
		local id: string = animal.uniqueId
		if stolen ~= true then
			local saved = _stolen[id]
			_stolen[id] = nil
			if type(saved) ~= 'table' then
				done = true
				return
			end
			local _, content = _stolenContent(animal)
			if content == nil then
				-- Model/gui gone (teardown beat us): the saved
				-- state dies with it; nothing left to restore.
				done = true
				return
			end
			pcall(function()
				local nameLabel = (content :: Instance):FindFirstChild('Name')
				if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
					if type(saved.nameText) == 'string' then
						(nameLabel :: TextLabel).Text = saved.nameText
					end
					if typeof(saved.nameColor) == 'Color3' then
						(nameLabel :: TextLabel).TextColor3 = saved.nameColor
					end
				end
				for child, wasVisible in pairs(saved.vis) do
					if typeof(child) == 'Instance' and (child :: Instance).Parent ~= nil then
						(child :: GuiObject).Visible = wasVisible == true
					end
				end
			end)
			done = true
			return
		end
		local _, content = _stolenContent(animal)
		if content == nil then
			return
		end
		if _stolen[id] == nil then
			-- First steal: snapshot the live look (exact
			-- visibilities — some labels may already hide).
			local saved: any = { nameText = nil, nameColor = nil, vis = {} }
			pcall(function()
				local nameLabel = (content :: Instance):FindFirstChild('Name')
				if nameLabel ~= nil and nameLabel:IsA('TextLabel') then
					saved.nameText = (nameLabel :: TextLabel).Text
					saved.nameColor = (nameLabel :: TextLabel).TextColor3
				end
				for _, child in ipairs((content :: Instance):GetChildren()) do
					if child:IsA('GuiObject') and child.Name ~= 'Name' then
						saved.vis[child] = (child :: GuiObject).Visible
					end
				end
			end)
			_stolen[id] = saved
		end
		_applyStolenVisuals(content :: Instance)
		done = true
	end)
	return done
end

-- TEST-ONLY seam: true while the stolen presentation is held
-- for this animal id (saved originals outstanding).
function AnimalOverhead._TestIsStolen(uniqueId: string): boolean
	return type(uniqueId) == 'string' and _stolen[uniqueId] ~= nil
end

-- TEST-ONLY seam: drop cached template state so specs observe
-- resolution fresh. Also clears rainbow registrations and the
-- shared loop (specs must not leak animation state).
function AnimalOverhead._TestReset()
	_template = nil
	_templateValid = false
	_warnedData = false
	for key in pairs(_stolen) do
		_stolen[key] = nil
	end
	for key in pairs(_diagWarned) do
		_diagWarned[key] = nil
	end
	for grad in pairs(_rainbow) do
		_rainbow[grad] = nil
	end
	for stroke in pairs(_rainbowStrokes) do
		_rainbowStrokes[stroke] = nil
	end
	if _rainbowConn ~= nil then
		pcall(function()
			(_rainbowConn :: RBXScriptConnection):Disconnect()
		end)
		_rainbowConn = nil
	end
end

-- TEST-ONLY seam: live rainbow registration count, gradients
-- plus strokes (specs assert one active animation per Rainbow
-- overhead, zero otherwise).
function AnimalOverhead._TestRainbowCount(): number
	local n = 0
	for grad in pairs(_rainbow) do
		if grad.Parent ~= nil then
			n += 1
		end
	end
	for stroke in pairs(_rainbowStrokes) do
		if stroke.Parent ~= nil then
			n += 1
		end
	end
	return n
end

return table.freeze(AnimalOverhead)
