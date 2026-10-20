--!strict
--!native
--[[
	SellConfirmViewport.spec
	========================
	Headless coverage for the SellConfirmation close-up front-profile showcase
	(upright Origin yaw, invisible-part strip, head-biased look target,
	fixed 1.31x dolly-in):
	yaw angle off the model's forward, look-at bbox-center,
	projected-box fit with margin, elevation,
	degenerate-input safety, the exact Origin reference
	transform, the clone-only 1.25x presentation scale, the
	dynamic RarityBox.Gradient light/dark treatment, and
	no-aura (no Highlight / silhouette seams). The
	instance-wiring half (WorldModel/Camera/ViewportFrame)
	is Studio-visual and asserted by shape in review.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local StarterPlayer = game:GetService('StarterPlayer')
	local scriptsRoot = StarterPlayer:WaitForChild('StarterPlayerScripts', 10)
	assert(scriptsRoot ~= nil, 'StarterPlayerScripts missing in test place')
	local module = scriptsRoot:WaitForChild('SellConfirmController', 10)
	assert(module ~= nil, 'SellConfirmController missing in test place')
	local SellConfirmController = require(module)
	-- Viewport-pipeline unit tests target the shared renderer
	-- directly (the same module both ArenaResult and Sell
	-- Confirmation render through): no controller-local seams.
	local AnimalViewport = require(ReplicatedStorage.Utility.AnimalViewport)

	local function horizontalAngleDeg(a: Vector3, b: Vector3): number
		local fa = Vector3.new(a.X, 0, a.Z)
		local fb = Vector3.new(b.X, 0, b.Z)
		if fa.Magnitude < 1e-6 or fb.Magnitude < 1e-6 then
			return 0
		end
		local cos = math.clamp(fa.Unit:Dot(fb.Unit), -1, 1)
		return math.deg(math.acos(cos))
	end

	describe('SellConfirmation name + sell-button text', function()
		it('prefixes canonical traits, never Normal/None/unknown', function()
			local fmt = SellConfirmController._TestFormatName
			expect(fmt('Dog', nil)).to.equal('Dog')
			expect(fmt('Dog', '')).to.equal('Dog')
			expect(fmt('Dog', 'Normal')).to.equal('Dog')
			expect(fmt('Dog', 'None')).to.equal('Dog')
			expect(fmt('Dog', 'NotATrait')).to.equal('Dog')
			expect(fmt('Dog', 'Gold')).to.equal('[Gold] Dog')
			expect(fmt('Dog', 'Diamond')).to.equal('[Diamond] Dog')
			expect(fmt('Dog', 'Rainbow')).to.equal('[Rainbow] Dog')
			-- Never duplicated when already present.
			expect(fmt('[Gold] Dog', 'Gold')).to.equal('[Gold] Dog')
			-- Empty names fall back without crashing.
			expect(fmt(nil, 'Gold')).to.equal('[Gold] Animal')
			expect(fmt('', nil)).to.equal('Animal')
		end)

		it('renders Sell for <amount> with the canonical formatter', function()
			local text = SellConfirmController._TestSellButtonText
			expect(text('500')).to.equal('Sell for $500')
			expect(text('1250000')).to.equal('Sell for $1.2M')
			-- Missing/unformattable values yield nil so the
			-- authored text stays (never a fabricated $0).
			expect(text(nil)).to.equal(nil)
			expect(text('')).to.equal(nil)
		end)
	end)

	describe('SellConfirmation showcase camera', function()
		local function lookCf(eye: Vector3, forward: Vector3): CFrame
			return CFrame.lookAt(eye, eye + forward)
		end

		-- Max projected fraction of the bbox across all 8
		-- corners (<= 1 fits; close to 1 fills the frame).
		-- Computed independently from the implementation.
		local function maxProjectedFraction(
			pos: Vector3,
			center: Vector3,
			cf: CFrame,
			size: Vector3,
			fovDeg: number,
			aspect: number
		): number
			local camCf = CFrame.lookAt(pos, center)
			local tanV = math.tan(math.rad(fovDeg * 0.5))
			local tanH = tanV * aspect
			local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
			local worst = 0
			for _, sx in ipairs({ -1, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					for _, sz in ipairs({ -1, 1 }) do
						local corner = cf * Vector3.new(sx * hx, sy * hy, sz * hz)
						local localPt = camCf:PointToObjectSpace(corner)
						local depth = -localPt.Z
						if depth > 1e-6 then
							local fx = math.abs(localPt.X) / (depth * tanH)
							local fy = math.abs(localPt.Y) / (depth * tanV)
							worst = math.max(worst, fx, fy)
						else
							return math.huge
						end
					end
				end
			end
			return worst
		end

		-- Max projected fraction over the 6 bbox face centers
		-- (snout/face proxy: the points that must never clip).
		-- Same independent camera-space projection as above; the
		-- call sites use translation-only bbox frames, so centers
		-- are center + axis half-extents.
		local function faceCenterFraction(
			pos: Vector3,
			look: Vector3,
			center: Vector3,
			size: Vector3,
			fovDeg: number,
			aspect: number
		): number
			local camCf = CFrame.lookAt(pos, look)
			local tanV = math.tan(math.rad(fovDeg * 0.5))
			local tanH = tanV * aspect
			local hx, hy, hz = size.X * 0.5, size.Y * 0.5, size.Z * 0.5
			local worst = 0
			for _, offset in ipairs({
				Vector3.new(hx, 0, 0),
				Vector3.new(-hx, 0, 0),
				Vector3.new(0, hy, 0),
				Vector3.new(0, -hy, 0),
				Vector3.new(0, 0, hz),
				Vector3.new(0, 0, -hz),
			}) do
				local point = center + offset
				local localPt = camCf:PointToObjectSpace(point)
				local depth = -localPt.Z
				if depth > 1e-6 then
					local f = math.max(math.abs(localPt.X) / (depth * tanH), math.abs(localPt.Y) / (depth * tanV))
					worst = math.max(worst, f)
				else
					return math.huge
				end
			end
			return worst
		end

		it('frames a mid-side front profile off the facing reference', function()
			local center = Vector3.new(10, 2, -4)
			local face = lookCf(center, Vector3.new(0, 0, 1))
			local bbox = CFrame.new(center)
			local pos, target, dist =
				AnimalViewport.ComputeShowcase(face, bbox, Vector3.new(2, 2, 2), 70, 1)
			-- Head-biased look target: bbox center raised 10% of height.
			expect(target).to.equal(center + Vector3.new(0, 2 * 0.10, 0))
			expect(math.abs(horizontalAngleDeg(pos - target, Vector3.new(0, 0, 1)) - 18) < 0.5).to.equal(true)
			expect(dist > 0).to.equal(true)
			-- Near eye level: slightly above, never below, never top-down.
			local lift = (pos.Y - target.Y) / dist
			expect(lift > 0).to.equal(true)
			expect(lift < 0.2).to.equal(true)
		end)

		it('follows the facing reference instead of a fixed world direction', function()
			local center = Vector3.new(0, 0, 0)
			local bbox = CFrame.new(center)
			local faceA = lookCf(center, Vector3.new(0, 0, 1))
			local faceB = lookCf(center, Vector3.new(1, 0, 0))
			local posA, targetA, distA =
				AnimalViewport.ComputeShowcase(faceA, bbox, Vector3.new(2, 2, 2), 70, 1)
			local posB, targetB, distB =
				AnimalViewport.ComputeShowcase(faceB, bbox, Vector3.new(2, 2, 2), 70, 1)
			expect(targetA).to.equal(center + Vector3.new(0, 2 * 0.10, 0))
			expect(targetB).to.equal(center + Vector3.new(0, 2 * 0.10, 0))
			-- Same ~18 deg yaw magnitude off their own facings.
			expect(math.abs(horizontalAngleDeg(posA - center, Vector3.new(0, 0, 1)) - 18) < 0.5).to.equal(true)
			expect(math.abs(horizontalAngleDeg(posB - center, Vector3.new(1, 0, 0)) - 18) < 0.5).to.equal(true)
			-- ... which are different world directions, while the fit
			-- distance is identical for identical bounds.
			expect(horizontalAngleDeg(posA - center, posB - center) > 45).to.equal(true)
			expect(distA).to.equal(distB)
		end)

		it('close-up fit on the bbox center with a small safety margin', function()
			local center = Vector3.new(0, 0, 0)
			local face = lookCf(center, Vector3.new(0, 0, 1))
			local bbox = CFrame.new(center)
			for _, size in ipairs({
				Vector3.new(1, 1, 1),
				Vector3.new(6, 1, 1),
				Vector3.new(1, 6, 1),
				Vector3.new(1, 1, 6),
				Vector3.new(4, 3, 6),
			}) do
				local pos, target, dist = AnimalViewport.ComputeShowcase(face, bbox, size, 70, 1)
				local wantTarget = center + Vector3.new(0, size.Y * 0.10, 0)
				expect(target).to.equal(wantTarget)
				-- Tight projected-box fit (1.06 margin) with the fixed
				-- 1.31x dolly-in (~12% closer than the 1.15 framing):
				-- the distance must equal the independently bisected
				-- exact-fit distance times 1.06 / 1.31, on the
				-- unchanged front-profile axis, centered.
				-- (Presentation size comes from the clone-only 1.25x
				-- scale plus this framing.)
				local axis = (wantTarget - pos).Unit
				local lo, hi = 0.01, 10000.0
				for _ = 1, 60 do
					local mid = (lo + hi) * 0.5
					local probe = wantTarget - axis * mid
					if maxProjectedFraction(probe, wantTarget, bbox, size, 70, 1) <= 1.0 then
						hi = mid
					else
						lo = mid
					end
				end
				local expected = hi * 1.06 / 1.31
				expect(math.abs(dist - expected) / expected < 0.02).to.equal(true)
				-- Close-up: bbox corners approach/exceed the frame edges
				-- (the dolly trades empty corner space for subject
				-- size; bounded overshoot, measured per proportion)...
				local frac = maxProjectedFraction(pos, wantTarget, bbox, size, 70, 1)
				expect(frac > 1.1).to.equal(true)
				expect(frac < 1.9).to.equal(true)
				-- ...while the central-80% inset box stays near the
				-- frame (bounded mid-shell overshoot)...
				local inset = maxProjectedFraction(pos, wantTarget, bbox, size * 0.8, 70, 1)
				expect(inset < 1.1).to.equal(true)
				expect(dist > 0).to.equal(true)
			end
			-- Faces (snouts, feet — the points that must never clip)
			-- stay inside for roster-like proportions. Extreme 6:1
			-- bars/poles are excluded by design: no uniform close-up
			-- can frame pathological proportions; the distance and
			-- corner assertions above still cover them.
			for _, size in ipairs({
				Vector3.new(1, 1, 1),
				Vector3.new(2, 2, 2),
				Vector3.new(4, 3, 6),
				Vector3.new(1.5, 6, 1.5),
			}) do
				local pos, _, _ = AnimalViewport.ComputeShowcase(face, bbox, size, 70, 1)
				local wantTarget = center + Vector3.new(0, size.Y * 0.10, 0)
				local faceFrac = faceCenterFraction(pos, wantTarget, center, size, 70, 1)
				expect(faceFrac < 1.1).to.equal(true)
			end
			-- Small and large/tall animals share the same
			-- centered framing (bbox center, never the pivot).
			local smallFace = lookCf(Vector3.new(5, 1, 2), Vector3.new(0, 0, 1))
			local smallBox = CFrame.new(5, 1, 2)
			local _, smallTarget, smallDist =
				AnimalViewport.ComputeShowcase(smallFace, smallBox, Vector3.new(1, 1, 1), 70, 1)
			expect(smallTarget).to.equal(Vector3.new(5, 1, 2) + Vector3.new(0, 1 * 0.10, 0))
			expect(smallDist > 0).to.equal(true)
			local tallFace = lookCf(Vector3.new(-3, 4, 1), Vector3.new(0, 0, 1))
			local tallBox = CFrame.new(-3, 4, 1)
			local _, tallTarget, tallDist =
				AnimalViewport.ComputeShowcase(tallFace, tallBox, Vector3.new(1.5, 6, 1.5), 70, 1)
			expect(tallTarget).to.equal(Vector3.new(-3, 4, 1) + Vector3.new(0, 6 * 0.10, 0))
			expect(tallDist > smallDist).to.equal(true)
			-- Microscopic models stay finite and fill (never
			-- microscopic, never collapsed).
			local _, _, distTiny =
				AnimalViewport.ComputeShowcase(face, CFrame.new(0, 0, 0), Vector3.new(0.1, 0.1, 0.1), 70, 1)
			expect(distTiny == distTiny and distTiny > 0 and distTiny < 1).to.equal(true)
		end)

		it('frames identically regardless of world position (pivot-independent)', function()
			local size = Vector3.new(3, 2, 4)
			local face = lookCf(Vector3.new(0, 0, 0), Vector3.new(0, 0, 1))
			local boxA = CFrame.new(0, 0, 0)
			local boxB = CFrame.new(40, -7, 12)
			local _, _, distA = AnimalViewport.ComputeShowcase(face, boxA, size, 70, 1)
			local _, _, distB = AnimalViewport.ComputeShowcase(face, boxB, size, 70, 1)
			expect(distA).to.equal(distB)
		end)

		it('stays finite on degenerate inputs', function()
			local center = Vector3.new(3, 1, 2)
			-- Facing straight up: fallback direction, still finite.
			local faceUp = CFrame.new(center) * CFrame.Angles(math.pi * 0.5, 0, 0)
			local faceBox = CFrame.new(center)
			local pos, target, dist =
				AnimalViewport.ComputeShowcase(faceUp, faceBox, Vector3.new(2, 2, 2), 70, 1)
			expect(target).to.equal(center + Vector3.new(0, 2 * 0.10, 0))
			expect(pos.X == pos.X and pos.Y == pos.Y and pos.Z == pos.Z).to.equal(true)
			expect(dist == dist and dist > 0).to.equal(true)
			-- Zero-size box: clamped, finite.
			local faceOk = lookCf(center, Vector3.new(0, 0, 1))
			local pos0, _, dist0 =
				AnimalViewport.ComputeShowcase(faceOk, faceBox, Vector3.new(0, 0, 0), 70, 1)
			expect(pos0.X == pos0.X).to.equal(true)
			expect(dist0 > 0).to.equal(true)
		end)
	end)

	describe('SellConfirmation preview strip', function()
		it('removes invisible hitbox parts but keeps visible geometry', function()
			local m = Instance.new('Model')
			local body = Instance.new('Part')
			body.Size = Vector3.new(2, 2, 2)
			body.Position = Vector3.new(0, 2, 0)
			body.Parent = m
			local hitbox = Instance.new('Part')
			hitbox.Name = 'Hitbox'
			hitbox.Size = Vector3.new(20, 20, 20)
			hitbox.Position = Vector3.new(50, 50, 50)
			hitbox.Transparency = 1
			hitbox.CanCollide = false
			hitbox.Parent = m
			local _, sizeBefore = m:GetBoundingBox()
			AnimalViewport.StripClone(m)
			expect(m:FindFirstChild('Hitbox')).to.equal(nil)
			expect(m:FindFirstChildOfClass('Part') ~= nil).to.equal(true)
			local _, sizeAfter = m:GetBoundingBox()
			expect(sizeAfter.X < sizeBefore.X).to.equal(true)
			expect(sizeAfter).to.equal(Vector3.new(2, 2, 2))
			m:Destroy()
		end)

		it('keeps translucent (non-invisible) parts', function()
			local m = Instance.new('Model')
			local body = Instance.new('Part')
			body.Size = Vector3.new(2, 2, 2)
			body.Position = Vector3.new(0, 2, 0)
			body.Parent = m
			local glass = Instance.new('Part')
			glass.Name = 'Glass'
			glass.Size = Vector3.new(1, 1, 1)
			glass.Position = Vector3.new(0, 5, 0)
			glass.Transparency = 0.5
			glass.Parent = m
			AnimalViewport.StripClone(m)
			expect(m:FindFirstChild('Glass') ~= nil).to.equal(true)
			expect(m:FindFirstChildOfClass('Part') ~= nil).to.equal(true)
			m:Destroy()
		end)

		it('keeps Eyes geometry and visual dress-up, strips gameplay objects', function()
			local m = Instance.new('Model')
			-- Visible geometry even though the NAME says Eyes: kept.
			local eyes = Instance.new('Part')
			eyes.Name = 'Eyes'
			eyes.Size = Vector3.new(1, 0.5, 0.5)
			eyes.Position = Vector3.new(0, 3, 1)
			eyes.Parent = m
			local mesh = Instance.new('SpecialMesh')
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = eyes
			local decal = Instance.new('Decal')
			decal.Texture = 'rbxassetid://1'
			decal.Parent = eyes
			local texture = Instance.new('Texture')
			texture.Texture = 'rbxassetid://2'
			texture.Parent = eyes
			local meshPart = Instance.new('MeshPart')
			meshPart.Size = Vector3.new(1, 1, 1)
			meshPart.Position = Vector3.new(2, 2, 0)
			meshPart.Parent = m
			local appearance = Instance.new('SurfaceAppearance')
			appearance.Parent = meshPart
			-- Face/detail GUIs are part of the authored look: kept.
			local faceGui = Instance.new('SurfaceGui')
			faceGui.Name = 'FaceGui'
			faceGui.Parent = eyes
			local faceImage = Instance.new('ImageLabel')
			faceImage.Parent = faceGui
			local dressBillboard = Instance.new('BillboardGui')
			dressBillboard.Name = 'DressUp'
			dressBillboard.Parent = eyes
			-- Gameplay/UI-only objects: stripped (prompts,
			-- clickers, debug adornments, scripts, and ONLY the
			-- two known stand overhead names).
			local prompt = Instance.new('ProximityPrompt')
			prompt.Parent = eyes
			local clicker = Instance.new('ClickDetector')
			clicker.Parent = eyes
			local overhead = Instance.new('BillboardGui')
			overhead.Name = 'OverheadGui'
			overhead.Parent = eyes
			local staleOverhead = Instance.new('BillboardGui')
			staleOverhead.Name = 'OverheadTemplate'
			staleOverhead.Parent = eyes
			local selector = Instance.new('SelectionBox')
			selector.Adornee = eyes
			selector.Parent = m
			local script = Instance.new('ModuleScript')
			script.Parent = m
			AnimalViewport.StripClone(m)
			-- Visuals intact, including by-name Eyes geometry and
			-- face/detail GUIs.
			expect(m:FindFirstChild('Eyes') ~= nil).to.equal(true)
			expect(eyes:FindFirstChildOfClass('SpecialMesh') ~= nil).to.equal(true)
			expect(eyes:FindFirstChildOfClass('Decal') ~= nil).to.equal(true)
			expect(eyes:FindFirstChildOfClass('Texture') ~= nil).to.equal(true)
			expect(meshPart:FindFirstChildOfClass('SurfaceAppearance') ~= nil).to.equal(true)
			expect(eyes:FindFirstChild('FaceGui') ~= nil).to.equal(true)
			expect(faceGui:FindFirstChildOfClass('ImageLabel') ~= nil).to.equal(true)
			expect(eyes:FindFirstChild('DressUp') ~= nil).to.equal(true)
			-- Gameplay objects + named overheads gone.
			expect(m:FindFirstChildOfClass('ProximityPrompt', true)).to.equal(nil)
			expect(m:FindFirstChildOfClass('ClickDetector', true)).to.equal(nil)
			expect(m:FindFirstChild('OverheadGui', true)).to.equal(nil)
			expect(m:FindFirstChild('OverheadTemplate', true)).to.equal(nil)
			expect(m:FindFirstChildOfClass('SelectionBox', true)).to.equal(nil)
			expect(m:FindFirstChildOfClass('LuaSourceContainer', true)).to.equal(nil)
			m:Destroy()
		end)
	end)

	describe('SellConfirmation viewport origin + 1.25x presentation', function()
		local function makeAnimal(): Model
			local m = Instance.new('Model')
			m.Name = 'AnimalPreview'
			local body = Instance.new('Part')
			body.Name = 'Body'
			body.Size = Vector3.new(2, 3, 2)
			body.Position = Vector3.new(0, 2, 0)
			body.Color = Color3.fromRGB(255, 0, 0)
			body.Parent = m
			local head = Instance.new('Part')
			head.Name = 'Head'
			head.Size = Vector3.new(1, 1, 1)
			head.Position = Vector3.new(0, 4, 0.5)
			head.Color = Color3.fromRGB(0, 0, 255)
			head.Parent = m
			local decal = Instance.new('Decal')
			decal.Name = 'Face'
			decal.Parent = head
			return m
		end

		it('uses the exact Origin position with an upright yaw-only orientation', function()
			local cf = AnimalViewport.OriginCFrame()
			expect((cf.Position - Vector3.new(20.263, 120.066, 20.066)).Magnitude < 1e-3).to.equal(true)
			-- Upright: pitch/roll zero (the specified pitch would tip
			-- the animal face-down); Origin yaw kept as stage facing.
			local rx, ry, rz = cf:ToOrientation()
			expect(math.abs(rx - 0) < 1e-3).to.equal(true)
			expect(math.abs(ry - math.rad(-31.716)) < 1e-3).to.equal(true)
			expect(math.abs(rz - 0) < 1e-3).to.equal(true)
		end)

		it('scales the clone 1.25x about its center with appearance intact', function()
			expect(AnimalViewport.PreviewScale()).to.equal(1.25)
			local m = makeAnimal()
			-- Pivot-only reference (independent path): the same rigid
			-- Origin transform with no scaling applied.
			local ref = AnimalViewport.OriginCFrame()
			local unscaled = m:Clone()
			unscaled:PivotTo(ref)
			local pivotOnlyCenter, pivotOnlySize = unscaled:GetBoundingBox()
			AnimalViewport.ApplyPresentation(m)
			-- Pivot established at the Origin reference.
			local after = m:GetPivot()
			expect((after.Position - ref.Position).Magnitude < 1e-3).to.equal(true)
			expect((after.LookVector - ref.LookVector).Magnitude < 1e-3).to.equal(true)
			-- Uniform 1.25x about the pivoted bbox center: bounds grow
			-- exactly 1.25x over the pivoted bounds, center unmoved by
			-- the scale step (the camera frames these final bounds).
			local cf1, size1 = m:GetBoundingBox()
			expect((size1 - pivotOnlySize * 1.25).Magnitude < 1e-2).to.equal(true)
			expect((cf1.Position - pivotOnlyCenter.Position).Magnitude < 1e-2).to.equal(true)
			-- Appearance intact: colors, decals, part count; no aura objects.
			expect((m:FindFirstChild('Body') :: BasePart).Color).to.equal(Color3.fromRGB(255, 0, 0))
			expect(m:FindFirstChild('Face', true) ~= nil).to.equal(true)
			expect(#m:GetDescendants()).to.equal(#unscaled:GetDescendants())
			expect(m:FindFirstChildOfClass('Highlight', true)).to.equal(nil)
			m:Destroy()
			unscaled:Destroy()
		end)
	end)

	describe('SellConfirmation rarity gradient', function()
		it('resolves the canonical project colors, nil for unknown', function()
			local base = SellConfirmController._TestRarityBaseColor
			expect(base('Rare')).to.equal(Color3.fromRGB(0, 166, 255))
			expect(base('Legendary')).to.equal(Color3.fromRGB(255, 247, 0))
			expect(base('Common')).to.equal(Color3.fromRGB(255, 255, 255))
			expect(base('Epic')).to.equal(Color3.fromRGB(191, 0, 255))
			-- Unknown/missing fall back to legacy styling, never error.
			expect(base('NotARarity')).to.equal(nil)
			expect(base(nil)).to.equal(nil)
			expect(base(123)).to.equal(nil)
		end)

		it('builds visibly distinct light/dark shades of the same hue', function()
			local lightOf = SellConfirmController._TestShadeLight
			local darkOf = SellConfirmController._TestShadeDark
			-- Rare blue stays blue on both ends.
			local rare = Color3.fromRGB(0, 166, 255)
			local light, dark = lightOf(rare), darkOf(rare)
			expect(light ~= dark).to.equal(true)
			expect(light.B >= light.R and light.B >= light.G).to.equal(true)
			expect(dark.B >= dark.R and dark.B >= dark.G).to.equal(true)
			expect(light.R >= rare.R and light.G >= rare.G and light.B >= rare.B).to.equal(true)
			expect(dark.R <= rare.R and dark.G <= rare.G and dark.B <= rare.B).to.equal(true)
			-- Legendary gold stays gold on both ends.
			local leg = Color3.fromRGB(255, 247, 0)
			local legLight, legDark = lightOf(leg), darkOf(leg)
			expect(legLight.R >= legLight.B and legLight.G >= legLight.B).to.equal(true)
			expect(legDark.R >= legDark.B and legDark.G >= legDark.B).to.equal(true)
			-- Common white: light stays white, dark turns gray.
			local white = Color3.fromRGB(255, 255, 255)
			expect(lightOf(white)).to.equal(white)
			local gray = darkOf(white)
			expect(gray.R < 1 and gray.R == gray.G and gray.G == gray.B).to.equal(true)
		end)

		it('emits a light-to-dark sequence preserving keypoint times', function()
			local grad = SellConfirmController._TestRarityGradient
			local base = Color3.fromRGB(0, 166, 255)
			local seq = grad(base, { 0, 0.5, 1 })
			local keys = seq.Keypoints
			expect(#keys).to.equal(3)
			expect(keys[1].Time).to.equal(0)
			expect(keys[2].Time).to.equal(0.5)
			expect(keys[3].Time).to.equal(1)
			expect(keys[1].Value).to.equal(SellConfirmController._TestShadeLight(base))
			expect(keys[2].Value).to.equal(base)
			expect(keys[3].Value).to.equal(SellConfirmController._TestShadeDark(base))
			-- Empty times fall back to a light→dark pair.
			local seq0 = grad(base, {})
			expect(#seq0.Keypoints).to.equal(2)
			expect(seq0.Keypoints[1].Time).to.equal(0)
			expect(seq0.Keypoints[2].Time).to.equal(1)
			expect(seq0.Keypoints[1].Value).to.equal(SellConfirmController._TestShadeLight(base))
			expect(seq0.Keypoints[2].Value).to.equal(SellConfirmController._TestShadeDark(base))
		end)

		it('resolves a fresh identity per rarity (Common/Rare/Legendary cycle)', function()
			local base = SellConfirmController._TestRarityBaseColor
			local grad = SellConfirmController._TestRarityGradient
			local function seqFor(rarity: string): ColorSequence
				local b = base(rarity)
				if b == nil then
					error('expected canonical color for ' .. rarity)
				end
				return grad(b, { 0, 1 })
			end
			local common = seqFor('Common')
			local rare = seqFor('Rare')
			local legendary = seqFor('Legendary')
			local commonAgain = seqFor('Common')
			-- Each rarity owns a distinct treatment; revisiting a
			-- rarity reproduces it exactly (no leftovers).
			expect(rare.Keypoints[1].Value ~= common.Keypoints[1].Value).to.equal(true)
			expect(legendary.Keypoints[1].Value ~= rare.Keypoints[1].Value).to.equal(true)
			expect(commonAgain.Keypoints[1].Value).to.equal(common.Keypoints[1].Value)
			expect(commonAgain.Keypoints[2].Value).to.equal(common.Keypoints[2].Value)
		end)
	end)

	describe('SellConfirmation viewport has no aura/outline', function()
		it('exposes no Highlight/silhouette builder seams', function()
			expect((SellConfirmController :: any)._TestAddOutline).to.equal(nil)
			expect((SellConfirmController :: any)._TestBuildSilhouette).to.equal(nil)
		end)
	end)
end
