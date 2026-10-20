--!strict
--!native
--[[
	Egg.ModelBuilder
	=======================
	Builds the visible `Model` for an Egg. Two paths:

	  * Template path — clone the Studio-authored Model from
	    ServerStorage.EggTemplates[<rarity>]. The clone
	    has its PrimaryPart set (convention: a part named
	    "Primary" or the first descendant BasePart), every
	    BasePart is anchored, every collision is disabled,
	    and a HumanoidRootPart is ensured (welded to the
	    primary so the cluster is moved as a single CFrame
	    by model:PivotTo).

	  * Procedural fallback — a single `Part` in the rarity's
	    material and color, sized to Constants.EggSize. Used
	    when no template exists. Keeps the system functional
	    before the human has placed any assets.

	The new design does NOT attach `BodyPosition` / `BodyGyro`.
	The egg is `Anchored = true` at all times and is moved
	via `model:PivotTo()` per Heartbeat. The previous
	BodyMovers were needed because the cluster was unanchored
	for Humanoid:MoveTo; the new controllers are deterministic
	Heartbeat drivers that don't need physics. This is the
	Y-axis conflict fix from the design doc.

	`Massless` is no longer set on the HRP. Anchored parts
	don't need it; it was a Humanoid-auxiliary attribute.
]]

local ServerStorage = game:GetService('ServerStorage')
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local Constants = require(script.Parent.Constants)
local HoverMath = require(script.Parent.HoverMath)

local ModelBuilder = {}

-- --- Find template ---------------------------------------------

-- Returns the template for a rarity, or nil. The Studio asset
-- contract places these at ServerStorage.EggTemplates.<Rarity>.
local function findTemplate(rarity: string): Model?
	local templatesRoot = ServerStorage:FindFirstChild('EggTemplates')
	if not templatesRoot then
		return nil
	end
	local rarityFolder = templatesRoot:FindFirstChild(rarity)
	if not rarityFolder then
		return nil
	end
	for _, child in ipairs(rarityFolder:GetChildren()) do
		if child:IsA('Model') then
			return child
		end
	end
	return nil
end

-- --- Anchor / disable collisions --------------------------------

-- Every BasePart in the cluster must be Anchored = true. The
-- Egg movement architecture drives the egg exclusively
-- via model:PivotTo() on Heartbeat (see FlightController, and
-- HoverMath.Settle for resting eggs). If a part is left
-- unanchored, the Roblox
-- physics engine will simulate it (gravity, sleep/wake) and fight
-- the PivotTo loop, which manifests as up-down jitter when a
-- player is close enough to wake the parts.
local function anchorAll(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.Anchored = true
		end
	end
end

local function disableAllCollisions(model: Model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA('BasePart') then
			descendant.CanCollide = false
		end
	end
end

-- --- Weld HRP to primary ---------------------------------------

local function weldHRPToPrimary(hrp: BasePart, primary: BasePart)
	for _, child in ipairs(hrp:GetChildren()) do
		if child:IsA('WeldConstraint') or child:IsA('Weld') then
			child:Destroy()
		end
	end
	local weld = Instance.new('WeldConstraint')
	weld.Part0 = hrp
	weld.Part1 = primary
	weld.Parent = hrp
end

-- --- Ensure HRP ------------------------------------------------

-- If the model has a HumanoidRootPart, (re)weld it to the primary
-- so the cluster moves as a single rigid body. If not, create
-- one. The HRP is invisible and collision-disabled; the visual
-- is the primary part.
local function ensureHumanoidRootPart(model: Model, primary: BasePart): BasePart
	local hrp = model:FindFirstChild('HumanoidRootPart')
	if hrp and hrp:IsA('BasePart') then
		weldHRPToPrimary(hrp, primary)
		return hrp
	end
	local newHrp = Instance.new('Part')
	newHrp.Name = 'HumanoidRootPart'
	newHrp.Size = Vector3.new(1, 1, 1)
	newHrp.Transparency = 1
	newHrp.CanCollide = false
	newHrp.Anchored = true
	newHrp.CFrame = primary.CFrame
	newHrp.Parent = model
	weldHRPToPrimary(newHrp, primary)
	return newHrp
end

-- --- Procedural fallback ---------------------------------------

-- A single Part in the rarity's material + color. Used when no
-- template is in ServerStorage. The model is parented to `parent`
-- and returned with its PrimaryPart set.
local function buildProceduralModel(rarity: string, parent: Instance): Model
	local model = Instance.new('Model')
	model.Name = 'Egg_Procedural'
	model.Parent = parent
	local part = Instance.new('Part')
	part.Name = 'Egg'
	part.Size = Constants.EggSize
	part.Anchored = true
	part.CanCollide = false
	part.Material = Constants.RarityMaterial[rarity] or Enum.Material.Plastic
	part.Color = RarityConfig.RarityColor[rarity] or Color3.new(1, 1, 1)
	part.Parent = model
	model.PrimaryPart = part
	ensureHumanoidRootPart(model, part)
	disableAllCollisions(model)
	return model
end

-- --- Public API ------------------------------------------------

-- Build the visible Model for a new egg. The returned model
-- is parented to `parent` (typically the center's
-- ActiveEggs folder or a per-base folder), has its
-- PrimaryPart set, has collisions disabled, and has an
-- invisible HumanoidRootPart welded to the primary.
function ModelBuilder.Build(rarity: string, parent: Instance): Model
	local template = findTemplate(rarity)
	if template then
		local model = template:Clone()
		model.Parent = parent
		-- Pick a PrimaryPart. The clone's PrimaryPart reference
		-- is broken by Clone(), so we look up by name first
		-- (convention: a part literally named "Primary"), then
		-- fall back to the first descendant BasePart.
		if not model.PrimaryPart then
			local primary = model:FindFirstChild('Primary', true)
			if primary and primary:IsA('BasePart') then
				model.PrimaryPart = primary
			else
				for _, child in ipairs(model:GetDescendants()) do
					if child:IsA('BasePart') then
						model.PrimaryPart = child
						break
					end
				end
			end
		end
		anchorAll(model)
		disableAllCollisions(model)
		local primary = model.PrimaryPart or model:FindFirstChildOfClass('BasePart') :: BasePart
		ensureHumanoidRootPart(model, primary)
		return model
	end
	return buildProceduralModel(rarity, parent)
end

-- The egg's SEATED CFrame on a slot: the slot's XZ and
-- rotation, with Y set so the egg's BOTTOM FACE rests flush
-- on the slot's top surface (zero gap — same relationship as
-- an Animal on its stand). The egg sits on the slot, it does
-- not hover over it.
--
-- A thin forward to `HoverMath.GroundedCFrameOnSlot`, which owns the
-- arithmetic. Kept as a `ModelBuilder` export because callers that
-- are building or repositioning a model already have this module
-- required; delegating means the model-building path and the
-- landing path cannot disagree about the seat height.
function ModelBuilder.SlotTargetCFrame(slot: any, model: Model?): CFrame
	return HoverMath.GroundedCFrameOnSlot(slot, model)
end

return table.freeze(ModelBuilder)
