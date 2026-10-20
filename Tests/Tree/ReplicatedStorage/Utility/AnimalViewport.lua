--!strict
--!native
--[[
	AnimalViewport
	==============
	Shared client-side Animal showcase renderer: the ONE
	implementation behind the SellConfirmation preview AND the
	ArenaResult card viewports. Extracted verbatim from
	SellConfirmController (computeShowcase / originCFrame /
	applyPresentation / stripClone / WorldModel + camera wiring)
	so every Animal viewport in the game stages, scales, and
	frames identically.

	Pipeline (clone-only; the live model is never touched):
	  live model -> Clone() -> StripClone -> ApplyPresentation
	  (Origin pivot + uniform scale about bbox center) ->
	  WorldModel inside the ViewportFrame + front-profile
	  showcase Camera fitted to the projected bounding box.

	All tunables come from SellConfig.Viewport (single source of
	truth for the showcase look). No RunService loops: models
	are static, set up once per paint.
]]

local SellConfig = require(script.Parent.Parent.Config.Economy.Sell)

local AnimalViewport = {}

local SHOWCASE_YAW_DEG = SellConfig.Viewport.ShowcaseYawDeg
local SHOWCASE_ELEVATION = SellConfig.Viewport.ShowcaseElevation
local SHOWCASE_MARGIN = SellConfig.Viewport.ShowcaseMargin
local SHOWCASE_ZOOM = SellConfig.Viewport.ShowcaseZoom
local SHOWCASE_TARGET_LIFT_FRAC = SellConfig.Viewport.TargetLiftFrac
local SHOWCASE_HEADROOM_FRAC = SellConfig.Viewport.HeadroomFrac
local SHOWCASE_HEADROOM_MIN = SellConfig.Viewport.HeadroomMin
local ORIGIN_POSITION = SellConfig.Viewport.OriginPosition
local ORIGIN_ORIENTATION_DEG = SellConfig.Viewport.OriginOrientationDeg
local PREVIEW_SCALE = SellConfig.Viewport.PreviewScale
local SHOWCASE_MIN_DIST = SellConfig.Viewport.MinDistance

-- Viewport hygiene: exactly one preview per viewport, no leaks
-- across opens. Destroys Camera/Model/WorldModel children only.
function AnimalViewport.ClearViewport(vp: ViewportFrame?)
	if vp == nil then
		return
	end
	pcall(function()
		for _, child in ipairs((vp :: ViewportFrame):GetChildren()) do
			if child:IsA('Camera') or child:IsA('Model') or child:IsA('WorldModel') then
				child:Destroy()
			end
		end
	end)
end

-- Pure showcase math (no instances): close-up mid-side front profile
-- derived from the model's facing direction, distance fitted to the
-- PROJECTED bounding box with margin. Returns pos, lookTarget, dist.
--
-- `faceCf` supplies the facing reference (the clone's
-- post-presentation pivot: deterministic per animal, so every
-- animal shows face + one side instead of a random world-space
-- side); `bboxCf`/`bboxSize` supply the visual center and extents.
function AnimalViewport.ComputeShowcase(
	faceCf: CFrame,
	bboxCf: CFrame,
	bboxSize: Vector3,
	fovDeg: number,
	aspect: number
): (Vector3, Vector3, number)
	local center = bboxCf.Position
	-- Look target: biased slightly above the bbox center toward the
	-- head/body presentation area (face focus), adaptive to the
	-- bounds. The fit below is computed around THIS target, so the
	-- full Animal still fits cleanly while the face sits near frame
	-- center. Never the pivot: pivots vary per animal.
	local target = center + Vector3.new(0, bboxSize.Y * SHOWCASE_TARGET_LIFT_FRAC, 0)
	-- Yaw the model's facing direction ~18 deg so the view catches
	-- the face plus one side of the body, then lift slightly to
	-- near eye level. Same side/orientation family for every animal.
	local forward = faceCf.LookVector
	local flat = Vector3.new(forward.X, 0, forward.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	end
	flat = flat.Unit
	local dir = (CFrame.Angles(0, math.rad(SHOWCASE_YAW_DEG), 0) * flat)
	-- View axis (camera -> target), independent of distance.
	local axis = -(dir + Vector3.new(0, SHOWCASE_ELEVATION, 0))
	if axis.Magnitude < 1e-3 then
		axis = Vector3.new(0, 0, -1)
	end
	axis = axis.Unit
	local axisCf = CFrame.lookAt(target - axis, target)
	local right = axisCf.RightVector
	local up = axisCf.UpVector
	local tanV = math.tan(math.rad(math.max(fovDeg, 1) * 0.5))
	local safeAspect = if aspect ~= aspect or aspect <= 0 then 1 else aspect
	local tanH = tanV * safeAspect
	tanV = math.max(tanV, 1e-3)
	tanH = math.max(tanH, 1e-3)
	-- Headroom scales with the model so the fit stays a close-up
	-- at every size; the absolute floor keeps geometry off the
	-- near plane for degenerate bounds.
	local radius = bboxSize.Magnitude * 0.5
	local headroom = math.max(radius * SHOWCASE_HEADROOM_FRAC, SHOWCASE_HEADROOM_MIN)
	-- Smallest distance fitting all 8 corners (+ headroom so
	-- nothing sits on the clip plane).
	local hx, hy, hz = bboxSize.X * 0.5, bboxSize.Y * 0.5, bboxSize.Z * 0.5
	local need = headroom
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local corner = bboxCf * Vector3.new(sx * hx, sy * hy, sz * hz)
				local rel = corner - target
				local axial = rel.X * axis.X + rel.Y * axis.Y + rel.Z * axis.Z
				local lx = math.abs(rel.X * right.X + rel.Y * right.Y + rel.Z * right.Z)
				local ly = math.abs(rel.X * up.X + rel.Y * up.Y + rel.Z * up.Z)
				local fit = math.max(lx / tanH - axial, ly / tanV - axial, headroom - axial)
				if fit ~= fit then
					fit = headroom - axial
				end
				if fit > need then
					need = fit
				end
			end
		end
	end
	local dist = math.max(need * SHOWCASE_MARGIN / SHOWCASE_ZOOM, SHOWCASE_MIN_DIST)
	local pos = target - axis * dist
	return pos, target, dist
end

-- Strips gameplay/UI-only objects from a preview clone
-- (clone-only; the live animal is never touched). The clone keeps
-- EVERYTHING visual — Decals, Textures, SurfaceAppearances,
-- MeshParts, accessories, particles, AND face/detail GUIs
-- (SurfaceGui/BillboardGui-based eyes and dress-up are part of
-- the authored look and must survive). Removed: scripts,
-- prompts, click detectors, selection/debug adornments, fully
-- invisible parts (hitboxes, rig roots — invisible geometry
-- inflates the bounding box and would shrink the animal
-- in-frame), and ONLY the two known stand overheads
-- (OverheadGui live / OverheadTemplate stale — same names the
-- Arena combat spawner strips). Any other Gui rides along, so
-- the preview shows the same animal the stand shows.
local OVERHEAD_GUI_NAMES: { [string]: boolean } = {
	OverheadGui = true,
	OverheadTemplate = true,
}

function AnimalViewport.StripClone(model: Model)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if
				desc:IsA('LuaSourceContainer')
				or desc:IsA('ProximityPrompt')
				or desc:IsA('ClickDetector')
				or desc:IsA('SelectionBox')
				or desc:IsA('SelectionSphere')
				or desc:IsA('Handles')
				or desc:IsA('ArcHandles')
				or (desc:IsA('BasePart') and desc.Transparency > 0.999)
				or (
					(desc:IsA('BillboardGui') or desc:IsA('SurfaceGui'))
					and OVERHEAD_GUI_NAMES[desc.Name] == true
				)
			then
				desc:Destroy()
			end
		end
	end)
end

-- Reference Origin CFrame for the preview clone: the exact position
-- plus the Orientation degrees converted with CFrame.fromOrientation
-- (Y-X-Z order, matching the Studio Orientation property). Only yaw
-- stages the clone (pitch would tip the animal face-down); the
-- animal stays upright.
function AnimalViewport.OriginCFrame(): CFrame
	return CFrame.new(ORIGIN_POSITION)
		* CFrame.fromOrientation(
			math.rad(ORIGIN_ORIENTATION_DEG.X),
			math.rad(ORIGIN_ORIENTATION_DEG.Y),
			math.rad(ORIGIN_ORIENTATION_DEG.Z)
		)
end

function AnimalViewport.PreviewScale(): number
	return PREVIEW_SCALE
end

function AnimalViewport.ShowcaseYawDeg(): number
	return SHOWCASE_YAW_DEG
end

-- Viewport-only presentation: establish the Origin pivot, then grow
-- the clone uniformly about its own bbox center (order matters:
-- PivotTo fixes facing/spot first; scaling offsets relative to the
-- bbox center keeps the visual center where the camera targets it).
-- The source/live model is never touched.
function AnimalViewport.ApplyPresentation(model: Model)
	pcall(function()
		model:PivotTo(AnimalViewport.OriginCFrame())
		local cf, _size = model:GetBoundingBox()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('BasePart') then
				local rel = cf:ToObjectSpace(desc.CFrame)
				desc.Size = desc.Size * PREVIEW_SCALE
				desc.CFrame = cf * CFrame.new(rel.Position * PREVIEW_SCALE) * (rel - rel.Position)
			end
		end
	end)
end

-- Single entry-point for the whole preview pipeline — the ONE
-- renderer both ArenaResult card viewports and the Sell
-- confirmation preview use (same WorldModel approach, same
-- camera/framing, same model preparation; only the SOURCE model
-- differs: a preserved Arena combat clone vs. the live stand
-- model). Takes the source model, Clone()s it (the source is
-- never reparented, moved, or mutated), strips gameplay/UI-only
-- objects, stages presentation, and fits it into the viewport.
-- Returns the displayed clone (parented in the viewport's
-- WorldModel) + camera distance, or (nil, nil) when the source
-- is unusable or the fit failed (the viewport is left empty —
-- callers log the failure, never a fallback model). Never
-- yields; never touches the source model.
function AnimalViewport.RenderModel(vp: ViewportFrame?, source: Model?): (Model?, number?)
	if vp == nil then
		return nil, nil
	end
	if typeof(source) ~= 'Instance' or not (source :: Instance):IsA('Model') then
		return nil, nil
	end
	local shown: Model? = nil
	pcall(function()
		shown = ((source :: Instance) :: Model):Clone()
	end)
	if shown == nil then
		return nil, nil
	end
	AnimalViewport.StripClone(shown :: Model)
	AnimalViewport.ApplyPresentation(shown :: Model)
	local dist = AnimalViewport.FitModel(vp, shown :: Model)
	if dist == nil then
		pcall(function()
			(shown :: Model):Destroy()
		end)
		AnimalViewport.ClearViewport(vp)
		return nil, nil
	end
	return shown, dist
end

-- Full viewport fill for one (already cloned + stripped) model:
-- WorldModel host, presentation staging, front-profile showcase
-- camera. Returns camera distance, or nil when the viewport is
-- unusable. Never yields; never touches the live model.
-- (Prefer RenderModel above: it owns clone + strip + present +
-- fit as one step. FitModel remains for callers that manage
-- their own clone lifecycle.)
function AnimalViewport.FitModel(vp: ViewportFrame?, model: Model): number?
	if vp == nil then
		return nil
	end
	local dist: number? = nil
	pcall(function()
		AnimalViewport.ClearViewport(vp)
		local world = Instance.new('WorldModel')
		world.Parent = vp
		model.Parent = world
		-- Visual bounds from the clone's ACTUAL bounding box
		-- (never the pivot); facing from the clone's
		-- post-presentation pivot (deterministic front-profile
		-- per animal).
		local faceCf = model:GetPivot()
		local cf, size = model:GetBoundingBox()
		local camera = Instance.new('Camera')
		camera.Parent = vp
		vp.CurrentCamera = camera
		local abs = vp.AbsoluteSize
		local aspect = 1
		if abs.X > 0 and abs.Y > 0 then
			aspect = abs.X / abs.Y
		end
		local pos, target, d = AnimalViewport.ComputeShowcase(faceCf, cf, size, camera.FieldOfView, aspect)
		camera.CFrame = CFrame.lookAt(pos, target)
		dist = d
	end)
	return dist
end

return table.freeze(AnimalViewport)
