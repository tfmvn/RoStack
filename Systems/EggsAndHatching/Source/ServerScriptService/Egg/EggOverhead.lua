--!strict
--!native
--[[
	EggOverhead
	===========
	Overhead BillboardGui for live eggs. Mirrors the proven
	AnimalOverhead architecture (same configs, same clone-and-
	paint pattern, same no-polling discipline) WITHOUT touching
	the working animal module.

	Template: ServerStorage.Assets.OverheadGui.EggOverheadGuiTemplate
	(authored BillboardGui, cloned verbatim — never rebuilt).
	Fallback: OverheadGuiTemplate (the animal template) when the
	egg-specific one is absent; the field writers below are all
	nil-safe so either tree paints without errors. Warn-once
	reports which template won.

	Attachment: the egg model's anchor part — CENTER first,
	then PrimaryPart, then the first descendant BasePart.
	(Investigation note: built egg models contain Egg /
	HumanoidRootPart (or a template Primary), never CENTER —
	CENTER-first is kept so Studio-authored egg templates with
	a CENTER part keep working.) Clone is named
	'EggOverheadGui' (distinct from the animal 'OverheadGui'
	so neither system touches the other's GUI). Because the GUI
	lives UNDER the model, pickup/carry/place/recover move it
	for free, and hatch/destroy removes it with the model —
	no per-move work, no orphan BillboardGuis.

	Data mapping (authoritative server egg record):
	  Content.Name     <- RarityConfig.RarityDisplayName[rarity]
	                      ('Common Egg'; the canonical egg
	                      display name) COLORED by
	                      RarityConfig.RarityColor[rarity] —
	                      the name itself carries the rarity
	                      (no separate Rarity label exists).
	  Content.Price    <- egg.price (the runtime record's own
	                      price — the same value the purchase
	                      debit sanitizes), EggConfig.Price
	                      fallback; rendered '$' + BigNumber
	                      like HUD money.
	  Content.Trait    <- egg.Trait; hidden when nil/'',
	                      otherwise solid OverheadConfig.
	                      TraitColors[trait] (deliberately NO
	                      rainbow ticker on eggs — one shared
	                      Heartbeat already exists for animals;
	                      a second per-egg ticker is not worth
	                      it; Rainbow-trait eggs still read
	                      correctly, just not animated).
  Content.Mutations <- MutationConfig.SanitizeIds(
                      egg.Mutations), painted by cloning
                      the template's OWN Mutation1
                      prototype (no invented ImageIds —
                      clones inherit authored visuals).
                      Fresh generic clones are additionally
                      stamped with the canonical mutation decal
                      (MutationIcon: Galactic->GalaxyIcon,
                      Frost->SnowfallIcon) so the correct icon
                      shows even when the template was never
                      customized per mutation. A Studio-authored
                      per-id icon child is never touched.
                      Stale clones destroyed; container
                      hidden when empty.

	Egg display data is immutable after spawn (rarity/Trait/
	Mutations are fixed at creation), so Refresh paints once
	per model. Refresh is total (never throws) and
	idempotent: an existing 'EggOverheadGui' is updated, never
	duplicated. Called from the three egg-model creation
	paths in SpawnService (_spawnCenter, _spawnPersistence,
	RebuildEggModel) — every live egg, including ambient
	center eggs, rejoin respawns, and reconcile rebuilds.
]]

local ServerStorage = game:GetService('ServerStorage')

local RarityConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Rarity)
local OverheadConfig = require(game:GetService('ReplicatedStorage').Config.Presentation.UI).Overhead
local MutationConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Mutations)
local EggConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Eggs)
local BigNumber = require(game:GetService('ReplicatedStorage').Utility.BigNumber)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local MutationIcon = require(script.Parent.Parent.Utility.MutationIcon)

local EggOverhead = {}

local WHITE: Color3 = OverheadConfig.FallbackColor
local TRAIT_COLORS: { [string]: Color3 } = OverheadConfig.TraitColors

local warnedTemplate = false

-- Resolve the authored template (egg-specific first, animal
-- template as fallback). Never creates UI.
local function resolveTemplate(): BillboardGui?
	local template: BillboardGui? = nil
	pcall(function()
		local assets = ServerStorage:FindFirstChild('Assets')
		local overhead = assets and assets:FindFirstChild('OverheadGui') or nil
		if overhead == nil then
			return
		end
		local egg = overhead:FindFirstChild('EggOverheadGuiTemplate')
		if egg ~= nil and egg:IsA('BillboardGui') then
			template = egg
			return
		end
		local shared = overhead:FindFirstChild('OverheadGuiTemplate')
		if shared ~= nil and shared:IsA('BillboardGui') then
			template = shared
		end
	end)
	if template == nil and not warnedTemplate then
		warnedTemplate = true
		Debug.Warn('EGOH', 'no egg overhead template (EggOverheadGuiTemplate nor OverheadGuiTemplate)', {})
	end
	return template
end

-- Anchor part for the clone: CENTER, else PrimaryPart, else
-- the first descendant BasePart.
local function anchorPart(model: Model): BasePart?
	local found: BasePart? = nil
	pcall(function()
		local center = model:FindFirstChild('CENTER')
		if center ~= nil and center:IsA('BasePart') then
			found = center
			return
		end
		local primary = model.PrimaryPart
		if primary ~= nil and primary:IsA('BasePart') then
			found = primary
			return
		end
		local deep = model:FindFirstChildWhichIsA('BasePart', true)
		if deep ~= nil then
			found = deep
		end
	end)
	return found
end

local function findGui(host: BasePart): BillboardGui?
	local found: BillboardGui? = nil
	pcall(function()
		for _, child in ipairs(host:GetChildren()) do
			if child:IsA('BillboardGui') and child.Name == 'EggOverheadGui' then
				found = child
				break
			end
		end
	end)
	return found
end

local function rarityColor(rarity: any): Color3
	local found: any = nil
	pcall(function()
		found = RarityConfig.RarityColor[rarity]
	end)
	if typeof(found) == 'Color3' then
		return found
	end
	return WHITE
end

local function sheenSequence(color: Color3): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE),
		ColorSequenceKeypoint.new(1, color),
	})
end

local function styleLabel(label: TextLabel, color: Color3)
	pcall(function()
		label.TextColor3 = color
		for _, child in ipairs(label:GetChildren()) do
			if child:IsA('UIGradient') then
				child.Color = sheenSequence(color)
				child.Enabled = true
			end
		end
	end)
end

local function paintName(content: Instance, displayName: string, rarity: string)
	local label: TextLabel? = nil
	pcall(function()
		local node = (content :: Instance):FindFirstChild('Name')
		if node ~= nil and (node :: Instance):IsA('TextLabel') then
			label = node :: TextLabel
		end
	end)
	if label == nil then
		return
	end
	local nameLabel = label :: TextLabel
	nameLabel.Text = displayName
	-- The egg NAME itself carries the rarity (§3): canonical
	-- RarityConfig color, same source as every other rarity
	-- presentation in the game. No separate Rarity label
	-- exists on this template (and none is created).
	styleLabel(nameLabel, rarityColor(rarity))
end

local function paintPrice(content: Instance, price: any)
	local label: TextLabel? = nil
	pcall(function()
		local node = (content :: Instance):FindFirstChild('Price')
		if node ~= nil and (node :: Instance):IsA('TextLabel') then
			label = node :: TextLabel
		end
	end)
	if label == nil then
		return
	end
	local text: string? = nil
	pcall(function()
		-- Same '$' + BigNumber.Format money rendering the HUD
		-- uses; tostring first because EggConfig prices are
		-- Lua numbers while the formatter takes strings.
		text = '$' .. BigNumber.Format(tostring(price))
	end)
	if type(text) ~= 'string' or text == '' then
		text = '$' .. tostring(price)
	end
	(label :: TextLabel).Text = text
end

local function paintTrait(content: Instance, trait: any)
	local label: TextLabel? = nil
	pcall(function()
		local node = (content :: Instance):FindFirstChild('Trait')
		if node ~= nil and (node :: Instance):IsA('TextLabel') then
			label = node :: TextLabel
		end
	end)
	if label == nil then
		return
	end
	if type(trait) ~= 'string' or trait == '' then
		local hidden = label :: TextLabel
		hidden.Visible = false
		return
	end
	local shown = label :: TextLabel
	shown.Text = trait
	shown.Visible = true
	styleLabel(label :: TextLabel, TRAIT_COLORS[trait] or WHITE)
end

local function paintMutations(content: Instance, mutations: any)
	local container: Instance? = nil
	pcall(function()
		local node = (content :: Instance):FindFirstChild('Mutations')
		if node ~= nil then
			container = node
		end
	end)
	if container == nil then
		return
	end
	local ids: { string } = {}
	pcall(function()
		local sanitized = MutationConfig.SanitizeIds(mutations)
		if type(sanitized) == 'table' then
			for _, id in ipairs(sanitized) do
				if type(id) == 'string' and id ~= '' then
					ids[#ids + 1] = id
				end
			end
		end
	end)
	-- Prototype: the authored Mutation1 clone source (its
	-- visuals ARE the mapping — never invented here).
	local prototype: Instance? = nil
	pcall(function()
		for _, child in ipairs((container :: Instance):GetChildren()) do
			if child:IsA('GuiObject') then
				if child.Name == 'Mutation1' then
					prototype = child
					break
				end
				if prototype == nil then
					prototype = child
				end
			end
		end
	end)
	if #ids < 1 or prototype == nil then
		pcall(function()
			for _, child in ipairs((container :: Instance):GetChildren()) do
				if child:IsA('GuiObject') then
					(child :: GuiObject).Visible = false
				end
			end
			if (container :: Instance):IsA('GuiObject') then
				((container :: Instance) :: GuiObject).Visible = false
			end
		end)
		return
	end
	pcall(function()
		if (container :: Instance):IsA('GuiObject') then
			((container :: Instance) :: GuiObject).Visible = true
		end
		local wanted: { [string]: boolean } = {}
		for _, id in ipairs(ids) do
			wanted[id] = true
			local slot = (container :: Instance):FindFirstChild(id)
			if slot == nil then
				local clone = (prototype :: Instance):Clone()
				clone.Name = id
				if clone:IsA('GuiObject') then
					(clone :: GuiObject).Visible = true
				end
				clone.Parent = container
				-- Fresh generic clone only (authored per-id
				-- children keep their art): stamp the canonical
				-- mutation decal so Galactic/Frost show the
				-- right icon with zero template edits. Missing
				-- decal = keep prototype visuals, never an error.
				pcall(MutationIcon.PaintIcon, clone, id)
			elseif (slot :: Instance):IsA('GuiObject') then
				((slot :: Instance) :: GuiObject).Visible = true
			end
		end
		-- Hide everything not wanted, including the
		-- authored prototype itself (it only shows when a
		-- real mutation is literally named the same).
		for _, child in ipairs((container :: Instance):GetChildren()) do
			if child:IsA('GuiObject') and not wanted[child.Name] then
				(child :: GuiObject).Visible = false
			end
		end
	end)
end

-- Create-or-refresh the overhead for one live egg record.
-- Total: invalid input returns false, never throws.
-- Idempotent: an existing 'EggOverheadGui' is repainted,
-- never duplicated.
function EggOverhead.Refresh(egg: any): boolean
	local ok = false
	pcall(function()
		if type(egg) ~= 'table' then
			return
		end
		local model = egg.model
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return
		end
		local host = anchorPart(model :: Model)
		if host == nil then
			Debug.Warn('EGOH', 'no anchor part for egg overhead', { egg = tostring(egg.uniqueId) })
			return
		end
		local template = resolveTemplate()
		if template == nil then
			return
		end
		local gui = findGui(host)
		if gui == nil then
			local clone = template:Clone()
			clone.Name = 'EggOverheadGui'
			clone.Enabled = true
			clone.Adornee = host
			clone.Parent = host
			gui = clone
			Debug.Log('EGOH', 'attached', { egg = tostring(egg.uniqueId) })
		end
		local content: Instance? = nil
		pcall(function()
			local container = (gui :: BillboardGui):FindFirstChild('Container')
			local inner = container and (container :: Instance):FindFirstChild('Content') or nil
			if inner ~= nil then
				content = inner
			end
		end)
		if content == nil then
			return
		end
		local rarity = egg.rarity
		if type(rarity) ~= 'string' or rarity == '' then
			rarity = 'Common'
		end
		local displayName = 'Egg'
		pcall(function()
			local named = RarityConfig.RarityDisplayName[rarity]
			if type(named) == 'string' and named ~= '' then
				displayName = named
			end
		end)
		paintName(content, displayName, rarity)
		-- Authoritative price: the runtime record's own price
		-- (the same value the purchase debit sanitizes), with
		-- EggConfig as fallback. Never calculated here.
		local price: any = egg.price
		if type(price) ~= 'number' and type(price) ~= 'string' then
			price = EggConfig.Price[rarity]
		end
		paintPrice(content, price)
		paintTrait(content, egg.Trait)
		paintMutations(content, egg.Mutations)
		ok = true
	end)
	return ok
end

return table.freeze(EggOverhead)
