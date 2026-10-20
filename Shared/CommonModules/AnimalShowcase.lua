--!strict
--!native
--[[
	AnimalShowcase
	==============
	Shared client-side exact-model viewport presentation (extracted
	verbatim from SellConfirmController's proven live-model viewer
	so every consumer renders identically). Philosophy: clone the
	EXACT source model, strip ONLY the overhead UI, mount into a
	fresh WorldModel, and fit the CAMERA to the model (never the
	reverse). No part/CFrame/color/transparency edits, no rescale,
	no repivot — except the locked-silhouette presentation below,
	which is clone-only and explicit.

	Covered in one place:
	  * RemoveOverheadOnly — BillboardGui/SurfaceGui named
	    OverheadGui/OverheadTemplate only.
	  * PrepareSilhouette — locked-state black presentation on a
	    clone (black parts, texture/detail overlays removed,
	    invisible helpers dropped; geometry/transforms untouched).
	  * Census — visual-content counts for LIVE vs CLONE proof.
	  * Render — clone + overhead strip + optional silhouette +
	    WorldModel mount + camera-only fit. Returns the mounted
	    clone, distance, and created outline frames (or nil).
	  * FrameCameraOnly — bounding-box fit with yaw/zoom/margin
	    parameters (callers pass the tuned showcase values).
	  * BuildOutline — 8 sibling outline ViewportFrames sharing
	    the exact main camera transform.
	  * WaitForSize — bounded Heartbeat wait for a laid-out
	    viewport (never a fixed delay).
	  * ClearViewport — destroy Camera/Model/WorldModel children.

	Generation safety stays with callers: pass IsValid() (checked
	before every commit) — stale renders abort and clean up.
]]

local RunService = game:GetService('RunService')

local Debug = require(script.Parent.Debug)

local AnimalShowcase = {}

export type RenderOptions = {
	Source: Model,
	Silhouette: boolean?,
	Outline: boolean?,
	OutlineColor: Color3?,
	ThicknessPx: number?,
	YawDeg: number?,
	Zoom: number?,
	Margin: number?,
	Elevation: number?,
	MinDistance: number?,
	IsValid: ((() -> boolean))?,
}

local OVERHEAD_NAMES: { [string]: boolean } = {
	OverheadGui = true,
	OverheadTemplate = true,
}

function AnimalShowcase.RemoveOverheadOnly(model: Model)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if (desc:IsA('BillboardGui') or desc:IsA('SurfaceGui')) and OVERHEAD_NAMES[desc.Name] then
				desc:Destroy()
			end
		end
	end)
end

-- Locked-state black presentation (clone-only): every visible part
-- goes pitch black; texture/detail overlays that could leak the
-- original look are removed; invisible helpers never join the
-- silhouette; geometry and transforms are untouched.
function AnimalShowcase.PrepareSilhouette(model: Model)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('BasePart') and desc.Transparency > 0.999 then
				desc:Destroy()
			elseif desc:IsA('Decal') or desc:IsA('Texture') then
				desc:Destroy()
			elseif desc:IsA('SurfaceAppearance') then
				desc:Destroy()
			elseif desc:IsA('ParticleEmitter') or desc:IsA('Beam') or desc:IsA('Trail') then
				desc:Destroy()
			end
		end
	end)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('MeshPart') then
				pcall(function()
					(desc :: MeshPart).TextureID = ''
				end)
			end
			if desc:IsA('BasePart') then
				(desc :: BasePart).Color = Color3.new(0, 0, 0)
			end
		end
	end)
end

-- Outline-clone preparation (shared by the sold preview outline):
-- invisible helpers dropped, texture overlays removed so the solid
-- color cannot leak through, remaining parts tinted. Geometry and
-- transforms untouched.
function AnimalShowcase.PrepareOutline(model: Model, color: Color3)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('BasePart') and desc.Transparency > 0.999 then
				desc:Destroy()
			elseif desc:IsA('Decal') or desc:IsA('Texture') then
				desc:Destroy()
			elseif desc:IsA('SurfaceAppearance') then
				desc:Destroy()
			end
		end
	end)
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('MeshPart') then
				pcall(function()
					(desc :: MeshPart).TextureID = ''
				end)
			end
			if desc:IsA('BasePart') then
				(desc :: BasePart).Color = color
			end
		end
	end)
end

function AnimalShowcase.Census(model: Instance): string
	local parts, mesh, decals, surfApp, accessories, guis, overhead = 0, 0, 0, 0, 0, 0, 0
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
				surfApp += 1
			elseif desc:IsA('Accessory') then
				accessories += 1
			elseif desc:IsA('BillboardGui') or desc:IsA('SurfaceGui') then
				guis += 1
				if OVERHEAD_NAMES[desc.Name] then
					overhead += 1
				end
			end
		end
	end)
	return ('parts=%d meshParts=%d decals=%d surfaceAppearances=%d accessories=%d guis=%d overhead=%d'):format(
		parts,
		mesh,
		decals,
		surfApp,
		accessories,
		guis,
		overhead
	)
end

function AnimalShowcase.ClearViewport(vp: ViewportFrame?)
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

-- Bounded Heartbeat wait for a laid-out viewport (AbsoluteSize > 0
-- on both axes). Returns true on the first valid frame, false on
-- timeout/invalid. Never a fixed delay.
function AnimalShowcase.WaitForSize(vp: ViewportFrame, isValid: ((() -> boolean))?, maxHeartbeats: number?): boolean
	local remaining = maxHeartbeats or 60
	if type(remaining) ~= 'number' or remaining < 1 then
		remaining = 60
	end
	for _ = 1, math.floor(remaining) do
		if isValid ~= nil and not (isValid :: () -> boolean)() then
			return false
		end
		local ready = false
		pcall(function()
			local size = (vp :: ViewportFrame).AbsoluteSize
			ready = size.X > 0 and size.Y > 0
		end)
		if ready then
			if isValid ~= nil and not (isValid :: () -> boolean)() then
				return false
			end
			return true
		end
		RunService.Heartbeat:Wait()
	end
	return false
end

-- Visible-geometry bounds: enclosing box of BaseParts with
-- Transparency <= 0.999 ONLY. Fully-invisible helper parts
-- (hitboxes, rig roots, CENTER-style anchors) are part of the
-- model and stay in it — but they must not inflate the camera
-- fit or yank its center, or the animal renders small and
-- off-center. Falls back to GetBoundingBox when nothing visible
-- exists. The model is never touched.
function AnimalShowcase.VisibleBounds(model: Model): (CFrame, Vector3)
	local fallbackCf: CFrame? = nil
	local fallbackSize: Vector3? = nil
	pcall(function()
		fallbackCf, fallbackSize = model:GetBoundingBox()
	end)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local found = false
	pcall(function()
		for _, desc in ipairs(model:GetDescendants()) do
			if desc:IsA('BasePart') and desc.Transparency <= 0.999 then
				local cf = (desc :: BasePart).CFrame
				local sz = (desc :: BasePart).Size
				local hx, hy, hz = sz.X * 0.5, sz.Y * 0.5, sz.Z * 0.5
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz2 in ipairs({ -1, 1 }) do
							local corner = cf * Vector3.new(sx * hx, sy * hy, sz2 * hz)
							if corner.X < minX then
								minX = corner.X
							end
							if corner.Y < minY then
								minY = corner.Y
							end
							if corner.Z < minZ then
								minZ = corner.Z
							end
							if corner.X > maxX then
								maxX = corner.X
							end
							if corner.Y > maxY then
								maxY = corner.Y
							end
							if corner.Z > maxZ then
								maxZ = corner.Z
							end
							found = true
						end
					end
				end
			end
		end
	end)
	if not found then
		return (fallbackCf or CFrame.new()), (fallbackSize or Vector3.new())
	end
	local center = Vector3.new((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
	return CFrame.new(center), Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
end

-- Camera-only fit over an already-mounted clone. Reads the clone's
-- bounding box + the viewport's real aspect, positions a fresh
-- camera in front of the model's facing (yaw + slight lift), and
-- touches nothing on the model. Returns camera distance or nil.
function AnimalShowcase.FrameCameraOnly(
	vp: ViewportFrame,
	model: Model,
	yawDeg: number?,
	zoom: number?,
	margin: number?,
	elevation: number?,
	minDist: number?
): number?
	local dist: number? = nil
	pcall(function()
		local yaw = yawDeg or 0
		local zm = zoom or 1
		local mg = margin or 1.1
		local el = elevation or 0.12
		local floor = minDist or 0.3
		local pivot = model:GetPivot()
		-- Visible bounds (NOT the raw model bounds): invisible
		-- helpers must not move the center or the distance.
		-- Facing still comes from the pivot (deterministic).
		local cf, size = AnimalShowcase.VisibleBounds(model)
		local target = cf.Position
		local fwd = pivot.LookVector
		local flat = Vector3.new(fwd.X, 0, fwd.Z)
		if flat.Magnitude < 1e-3 then
			flat = Vector3.new(0, 0, 1)
		end
		flat = (CFrame.Angles(0, math.rad(yaw), 0) * flat.Unit)
		local dir = flat + Vector3.new(0, el, 0)
		if dir.Magnitude < 1e-3 then
			dir = Vector3.new(0, 0, 1)
		end
		dir = dir.Unit
		local camera = Instance.new('Camera')
		camera.Parent = vp
		vp.CurrentCamera = camera
		local abs = vp.AbsoluteSize
		local aspect = 1
		if abs.X > 0 and abs.Y > 0 then
			aspect = abs.X / abs.Y
		end
		local fov = math.max(camera.FieldOfView, 1)
		local tanV = math.max(math.tan(math.rad(fov * 0.5)), 1e-3)
		local tanH = math.max(tanV * math.max(aspect, 1e-3), 1e-3)
		local view = CFrame.lookAt(target + dir, target)
		local right = view.RightVector
		local up = view.UpVector
		local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
		local need = 0
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					local corner = cf * Vector3.new(sx * hx, sy * hy, sz * hz)
					local rel = corner - target
					local axial = rel.X * dir.X + rel.Y * dir.Y + rel.Z * dir.Z
					local lx = math.abs(rel.X * right.X + rel.Y * right.Y + rel.Z * right.Z)
					local ly = math.abs(rel.X * up.X + rel.Y * up.Y + rel.Z * up.Z)
					local fit = math.max(lx / tanH + axial, ly / tanV + axial)
					if fit ~= fit then
						fit = axial
					end
					if fit > need then
						need = fit
					end
				end
			end
		end
		local d = math.max(need * mg, floor) * zm
		camera.CFrame = CFrame.lookAt(target + dir * d, target)
		dist = d
	end)
	return dist
end

-- Build 8 sibling outline layers behind the main viewport sharing
-- the exact main camera transform. Each holds a solid-color clone
-- of `source` (outline-only preparation). Returns the frames (the
-- caller owns cleanup) or nil on failure/staleness (partials
-- destroyed). The main viewport keeps its authored ZIndex + 1.
local function destroyAll(frames: { ViewportFrame })
	for _, ovp in ipairs(frames) do
		pcall(function()
			ovp:Destroy()
		end)
	end
	table.clear(frames)
end

function AnimalShowcase.BuildOutline(
	mainVp: ViewportFrame,
	source: Model,
	color: Color3,
	thicknessPx: number,
	mainCamCF: CFrame,
	mainFov: number,
	isValid: ((() -> boolean))?
): { ViewportFrame }?
	local frames: { ViewportFrame } = {}
	local function valid(): boolean
		if isValid == nil then
			return true
		end
		return (isValid :: () -> boolean)()
	end
	if not valid() then
		return nil
	end
	local okAll = false
	pcall(function()
		local parent = (mainVp :: ViewportFrame).Parent
		if parent == nil or not (parent :: Instance):IsA('GuiObject') then
			return
		end
		local mainSize = (mainVp :: ViewportFrame).Size
		local mainPos = (mainVp :: ViewportFrame).Position
		local mainAnchor = (mainVp :: ViewportFrame).AnchorPoint
		local mainRot = (mainVp :: ViewportFrame).Rotation
		local mainClip = (mainVp :: ViewportFrame).ClipsDescendants
		local mainZ = (mainVp :: ViewportFrame).ZIndex
		local mainOrder = (mainVp :: ViewportFrame).LayoutOrder
		local mainFrame = mainVp :: ViewportFrame
		mainFrame.ZIndex = mainZ + 1
		-- A layout object parenting the viewports would rearrange
		-- the 8 layers instead of overlaying them. Detect (not
		-- fixable from here) so the output names the cause.
		pcall(function()
			local layout = (parent :: Instance):FindFirstChildWhichIsA('UILayout', false)
			if layout ~= nil then
								Debug.Warn('AnimalShowcase', ('outline parent has UILayout parent=%s layout=%s â€” border layers may misalign'):format(
						(parent :: Instance):GetFullName(),
						layout.ClassName
					))
			end
		end)
		local t = thicknessPx
		local offsets = {
			Vector2.new(-t, 0),
			Vector2.new(t, 0),
			Vector2.new(0, -t),
			Vector2.new(0, t),
			Vector2.new(-t, -t),
			Vector2.new(t, -t),
			Vector2.new(-t, t),
			Vector2.new(t, t),
		}
		for i, off in ipairs(offsets) do
			if not valid() then
				return
			end
			local ovp = Instance.new('ViewportFrame')
			ovp.Name = ('ShowcaseOutline%d'):format(i)
			ovp.BackgroundTransparency = 1
			ovp.BorderSizePixel = 0
			ovp.Active = false
			ovp.Selectable = false
			ovp.Size = mainSize
			ovp.Position = mainPos + UDim2.fromOffset(off.X, off.Y)
			ovp.AnchorPoint = mainAnchor
			ovp.Rotation = mainRot
			ovp.ClipsDescendants = mainClip
			ovp.LayoutOrder = mainOrder
			ovp.ZIndex = mainZ
			ovp.Ambient = color
			ovp.LightColor = Color3.new(0, 0, 0)
			local oclone = (source :: Model):Clone()
			AnimalShowcase.PrepareOutline(oclone, color)
			local world = Instance.new('WorldModel')
			world.Parent = ovp
			local mounted = oclone :: Model
			mounted.Parent = world
			local ocam = Instance.new('Camera')
			ocam.CFrame = mainCamCF
			ocam.FieldOfView = mainFov
			ocam.Parent = ovp
			ovp.CurrentCamera = ocam
			ovp.Visible = true
			ovp.Parent = parent
			frames[#frames + 1] = ovp
		end
		okAll = #frames == 8 and valid()
	end)
	if not okAll then
		destroyAll(frames)
		return nil
	end
	return frames
end

-- Full pipeline: clone the exact source, strip overhead, apply the
-- locked silhouette when requested, mount into a fresh WorldModel,
-- fit camera-only, optionally build the outline. Generation-safe
-- via opts.IsValid (checked before every commit; stale work is
-- destroyed). Returns mounted clone + distance + outline frames,
-- or (nil, nil, nil) with the viewport left clean.
function AnimalShowcase.Render(
	vp: ViewportFrame?,
	opts: RenderOptions
): (Model?, number?, { ViewportFrame }?)
	if vp == nil then
		return nil, nil, nil
	end
	local function valid(): boolean
		if opts.IsValid == nil then
			return true
		end
		return (opts.IsValid :: () -> boolean)()
	end
	if not valid() then
		return nil, nil, nil
	end
	local clone: Model? = nil
	pcall(function()
		clone = (opts.Source :: Model):Clone()
	end)
	if clone == nil then
		return nil, nil, nil
	end
	AnimalShowcase.RemoveOverheadOnly(clone :: Model)
	if opts.Silhouette then
		AnimalShowcase.PrepareSilhouette(clone :: Model)
	end
	if not valid() then
		pcall(function()
			(clone :: Model):Destroy()
		end)
		return nil, nil, nil
	end
	AnimalShowcase.ClearViewport(vp)
	local world = Instance.new('WorldModel')
	world.Parent = vp
	local mounted = clone :: Model
	mounted.Parent = world
	if opts.Silhouette then
		-- Pitch-black guarantee: viewport lighting follows the
		-- clone (both black), so no missed texture can leak.
		pcall(function()
			local frame = vp :: ViewportFrame
			frame.Ambient = Color3.new(0, 0, 0)
			frame.LightColor = Color3.new(0, 0, 0)
		end)
	end
	local dist = AnimalShowcase.FrameCameraOnly(
		vp,
		mounted,
		opts.YawDeg,
		opts.Zoom,
		opts.Margin,
		opts.Elevation,
		opts.MinDistance
	)
	if dist == nil then
		pcall(function()
			(clone :: Model):Destroy()
		end)
		AnimalShowcase.ClearViewport(vp)
		return nil, nil, nil
	end
	local outlines: { ViewportFrame }? = nil
	if opts.Outline then
		local mainCamCF: CFrame? = nil
		local mainFov = -1
		pcall(function()
			local cam = (vp :: ViewportFrame).CurrentCamera
			if cam ~= nil then
				mainCamCF = cam.CFrame
				mainFov = cam.FieldOfView
			end
		end)
		if mainCamCF ~= nil then
			outlines = AnimalShowcase.BuildOutline(
				vp,
				opts.Source,
				opts.OutlineColor or Color3.fromRGB(255, 255, 255),
				opts.ThicknessPx or 2,
				mainCamCF :: CFrame,
				mainFov,
				opts.IsValid
			)
		end
	end
	if not valid() then
		pcall(function()
			(clone :: Model):Destroy()
		end)
		if outlines ~= nil then
			destroyAll(outlines)
		end
		AnimalShowcase.ClearViewport(vp)
		return nil, nil, nil
	end
	return clone, dist, outlines
end

return table.freeze(AnimalShowcase)
