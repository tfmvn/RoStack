--!strict
--!native
--[[
	StandShowcase
	=============
	Client-side generic Model/Tool viewport presentation for Rebirth
	UnlockItems cards. Thin adapter over the proven AnimalShowcase
	pipeline (clone + overhead strip + WorldModel + camera-only fit
	+ 8-direction outline) — NOT a second viewport system, and
	AnimalShowcase itself is never modified.

	Two gaps AnimalShowcase cannot cover for unlocks (kept here so
	the animal path stays byte-identical):

	  * Source kinds: stand templates are Models (or single
	    BaseParts) while Gear previews are Tools. A Tool is not a
	    Model, so it is carried inside a plain Model wrapper before
	    AnimalShowcase ever sees it. Geometry is untouched; only
	    the container changes, on a clone.
	  * Stand UI noise: AnimalShowcase strips only OverheadGui /
	    OverheadTemplate GUIs. Stands carry interaction UI of their
	    own (Amount SurfaceGuis, MenuGui, prompts, click detectors)
	    that must never appear in a showcase card, so working
	    copies get StripInteractiveOnly (GUIs + prompts +
	    detectors, clone-only).
	  * Stand facing: the camera must look at the MEANINGFUL side
	    (the Button/Base cash side animals face). The offset is
	    MEASURED from the template via StandResolver (same
	    Button.Base -> PressPart convention DynamicSlotService
	    builds from) and applied as extra camera yaw — the model
	    itself is never rotated.

	Tool framing reuses the existing Gear Shop presentation angle:
	YawDeg/Elevation are derived from GearConfig.Viewport.Direction
	(never a second magic angle), while distance still comes from
	the model's own bounding box via AnimalShowcase.
]]

local AnimalShowcase = require(script.Parent.AnimalShowcase)
local StandResolver = require(script.Parent.StandResolver)
local GearConfig = require(script.Parent.Parent.Config.Economy.Gear)

local StandShowcase = {}

export type RenderResult = {
	Mounted: Model?,
	Distance: number?,
	Outlines: { ViewportFrame }?,
}

-- Clone-only strip of everything that makes a stand/tool
-- interactive or UI-noisy in the world: every BillboardGui /
-- SurfaceGui (Amount labels, MenuGui, overheads), prompts, click
-- detectors. Geometry, colors, materials, and transforms are
-- untouched. The source template is never passed here — callers
-- prepare a disposable working copy.
function StandShowcase.StripInteractiveOnly(model: Instance)
	pcall(function()
		for _, desc in ipairs((model :: Model):GetDescendants()) do
			if
				desc:IsA('BillboardGui')
				or desc:IsA('SurfaceGui')
				or desc:IsA('ProximityPrompt')
				or desc:IsA('ClickDetector')
			then
				desc:Destroy()
			end
		end
	end)
end

-- Extra camera yaw (degrees) that turns the showcase camera toward
-- the stand's measured front: the Button.Base side (PressPart
-- fallback), i.e. the exact parts animals face per
-- StandResolver.GetStandFacingTarget and the exact convention
-- DynamicSlotService orients runtime stands from. Translation-
-- invariant (template-local XZ offset), nil when the model carries
-- no resolvable button (caller keeps its default yaw).
function StandShowcase.FrontYawOffset(model: Instance): number?
	local yaw: number? = nil
	pcall(function()
		local pivot: CFrame? = nil
		if (model :: Instance):IsA('Model') then
			pivot = ((model :: Instance) :: Model):GetPivot()
		elseif (model :: Instance):IsA('BasePart') then
			pivot = ((model :: Instance) :: BasePart).CFrame
		end
		if typeof(pivot) ~= 'CFrame' then
			return
		end
		local target = StandResolver.GetStandFacingTarget(model)
		if target == nil then
			return
		end
		local rel = ((pivot :: CFrame):ToObjectSpace(CFrame.new((target :: BasePart).Position))).Position
		local flat = Vector3.new(rel.X, 0, rel.Z)
		if flat.Magnitude < 1e-3 then
			return
		end
		local look = (pivot :: CFrame).LookVector
		local pivotYaw = math.atan2(look.X, look.Z)
		local frontAngle = math.atan2(flat.X, flat.Z)
		yaw = math.deg(frontAngle - pivotYaw)
	end)
	return yaw
end

-- Destroy stale 8-direction outline siblings from a previous render
-- of the same card. AnimalShowcase.BuildOutline parents outlines
-- beside the main viewport (inside the card), so a re-render
-- without a card rebuild would otherwise stack duplicates.
function StandShowcase.ClearOutlines(card: Instance?)
	if typeof(card) ~= 'Instance' then
		return
	end
	pcall(function()
		for _, child in ipairs((card :: Instance):GetChildren()) do
			if child:IsA('ViewportFrame') and string.sub(child.Name, 1, 15) == 'ShowcaseOutline' then
				child:Destroy()
			end
		end
	end)
end

-- Carry any source kind (Model, Tool, BasePart) inside a plain
-- Model working copy. Returns the working Model (caller destroys
-- it after AnimalShowcase.Render clones it again) or nil.
local function workingCopy(source: Instance): Model?
	local clone: Instance? = nil
	pcall(function()
		clone = (source :: Instance):Clone()
	end)
	if clone == nil then
		return nil
	end
	if (clone :: Instance):IsA('Model') then
		return clone :: Model
	end
	local wrapper: Model? = nil
	pcall(function()
		local holder = Instance.new('Model')
		holder.Name = 'UnlockPreview'
		local inner: Instance = clone :: Instance
		inner.Parent = holder
		wrapper = holder
	end)
	if wrapper == nil then
		pcall(function()
			(clone :: Instance):Destroy()
		end)
		return nil
	end
	return wrapper
end

local function renderThrough(
	vp: ViewportFrame,
	source: Instance,
	yawDeg: number,
	elevation: number,
	isValid: (() -> boolean)?
): RenderResult
	local result: RenderResult = { Mounted = nil, Distance = nil, Outlines = nil }
	local working = workingCopy(source)
	if working == nil then
		return result
	end
	StandShowcase.StripInteractiveOnly(working)
	local mounted: Model? = nil
	local dist: number? = nil
	local outlines: { ViewportFrame }? = nil
	pcall(function()
		mounted, dist, outlines = AnimalShowcase.Render(vp, {
			Source = working :: Model,
			Silhouette = false,
			Outline = true,
			-- ALWAYS white: never rarity/tool/stand/arena colored.
			-- The central model keeps its normal appearance; only
			-- the silhouette layers are white.
			OutlineColor = Color3.fromRGB(255, 255, 255),
			ThicknessPx = 2,
			YawDeg = yawDeg,
			Zoom = 1.0,
			Margin = 1.2,
			Elevation = elevation,
			MinDistance = 1,
			IsValid = isValid,
		})
	end)
	pcall(function()
		(working :: Model):Destroy()
	end)
	result.Mounted = mounted
	result.Distance = dist
	result.Outlines = outlines
	return result
end

-- Gear presentation angle, derived from the existing Gear Shop
-- viewport tuning (same source GearShopController frames shop
-- tools from). Computed once: yaw about Y + elevation fraction.
local function gearAngle(): (number, number)
	local yaw = 32
	local elevation = 0.3
	pcall(function()
		local dir = GearConfig.Viewport.Direction
		if typeof(dir) == 'Vector3' and dir.Magnitude > 1e-3 then
			yaw = math.deg(math.atan2(dir.X, dir.Z))
			local unit = dir.Unit
			elevation = unit.Y
		end
	end)
	return yaw, elevation
end

-- Render a stand template (StandTemplate / ArenaStandTemplate) with
-- the Button side facing the camera, then a 3/4 turn on top.
function StandShowcase.RenderStand(vp: ViewportFrame, source: Instance, isValid: (() -> boolean)?): RenderResult
	local frontYaw = 0
	pcall(function()
		frontYaw = StandShowcase.FrontYawOffset(source) or 0
	end)
	return renderThrough(vp, source, frontYaw + 25, 0.18, isValid)
end

-- Render a Gear Shop tool (ReplicatedStorage.GearShopPreviews clone
-- or any Tool/Model) from the shop's own presentation angle.
function StandShowcase.RenderTool(vp: ViewportFrame, source: Instance, isValid: (() -> boolean)?): RenderResult
	local yaw, elevation = gearAngle()
	return renderThrough(vp, source, yaw, elevation, isValid)
end

return table.freeze(StandShowcase)
