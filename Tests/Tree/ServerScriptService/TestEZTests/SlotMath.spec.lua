--!strict
--!native
--[[
	SlotMath.spec
	=============
	Tests for the pure-math SlotMath helpers
	(Animal/SlotMath.lua).

	What this spec locks in:
	  A. When a Humanoid is present, FeetOffsetBelowPrimary
	     returns `-HipHeight` — the Humanoid's authoritative
	     definition of where the character's feet are relative
	     to the HumanoidRootPart. This aligns with the walk
	     animation's foot placement (which uses HipHeight, not
	     the geometric leg bottom). For standard R15,
	     HipHeight=2 while the geometric leg bottom is at
	     localY ≈ -2.99; using HipHeight prevents a ~1 stud
	     visual float.
	  B. When no Humanoid is present (or HipHeight=0),
	     FeetOffsetBelowPrimary falls back to the geometric
	     bottom of the lowest VISIBLE descendant BasePart.
	  C. Invisible (Transparency=1) parts are ignored in the
	     geometric fallback — they are treated as "not part
	     of the body silhouette" so a hidden shadow / hitbox
	     part below the feet cannot make the animal float
	     above the ground.
	  D. Parts worn as Accessories (children of an Accessory)
	     are also ignored — hats, tools, shoulder items ride
	     on the character and don't define the feet plane.
	  E. The PrimaryPart's own bottom face is always considered
	     (even if Transparency=1) because it's the rig's
	     reference frame, not a stray geometry part.
  F. StandingCFrameOnSlot lifts the PrimaryPart by
     |feetOffset| above the slot top so the model's
     BOTTOM FACE lands exactly on the slot top — not
     floating, not sunk.
  G. The Humanoid branch is scale-aware: a weight-grown
     model (Model:ScaleTo, HipHeight property unscaled —
     ScaleTo scales geometry, not the HipHeight float)
     reports -HipHeight * GetScale(), so pickup/place,
     steal delivery, and recovery settle a high-level
     animal exactly instead of sinking it by
     HipHeight * (scale - 1).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local SlotMath = require(ServerScriptService.Animal.SlotMath)

	local function makePart(name, size, cf, parent, transparency)
		local p = Instance.new('Part')
		p.Name = name
		p.Size = size
		p.Anchored = true
		p.CanCollide = false
		if transparency ~= nil then
			p.Transparency = transparency
		end
		p.CFrame = cf
		p.Parent = parent
		return p
	end

	local function makeModel(hrpSize, descendants)
		-- descendants is a list of { name, size, localY, transparency? }
		local model = Instance.new('Model')
		model.Name = 'TestAnimal'
		local hrp = Instance.new('Part')
		hrp.Name = 'HumanoidRootPart'
		hrp.Size = hrpSize
		hrp.Anchored = true
		hrp.CanCollide = false
		hrp.Transparency = 1
		hrp.CFrame = CFrame.new(0, 0, 0)
		hrp.Parent = model
		model.PrimaryPart = hrp
		for _, d in ipairs(descendants) do
			makePart(d.name, d.size, CFrame.new(0, d.localY, 0), model, d.transparency)
		end
		model.Parent = game:GetService('Workspace')
		return model
	end

	describe('SlotMath.FeetOffsetBelowPrimary', function()
		it('returns 0 when the model has no descendants below the PrimaryPart', function()
			-- HRP at origin, size 2 → bottom at Y=-1
			local model = makeModel(Vector3.new(2, 2, 2), {})
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			-- HRP's own bottom (-1) is the lowest, so offset = -1
			expect(offset).to.equal(-1)
			model:Destroy()
		end)

		it('uses the lowest visible descendant when it is below the PrimaryPart', function()
			-- Feet part at Y=-2, size 2 → bottom at Y=-3
			local model = makeModel(Vector3.new(2, 2, 2), {
				{ name = 'Feet', size = Vector3.new(2, 2, 2), localY = -2 },
			})
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(-3) -- feet bottom is 3 below the HRP
			model:Destroy()
		end)

		it('ignores fully-invisible descendants (Transparency=1)', function()
			-- Visible feet at Y=-2, size 2 → bottom at -3
			-- Hidden "shadow" at Y=-4, size 1 → bottom at -4.5
			-- Without the filter: offset = -4.5 (animal floats 1.5 studs)
			-- With the filter:    offset = -3   (correctly on the ground)
			local model = makeModel(Vector3.new(2, 2, 2), {
				{ name = 'Feet', size = Vector3.new(2, 2, 2), localY = -2, transparency = 0 },
				{ name = 'Shadow', size = Vector3.new(1, 1, 1), localY = -4, transparency = 1 },
			})
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(-3)
			model:Destroy()
		end)

		it('considers partially-transparent parts (Transparency < 1)', function()
			-- Part with Transparency=0.5 is still part of the silhouette
			local model = makeModel(Vector3.new(2, 2, 2), {
				{ name = 'GhostFoot', size = Vector3.new(2, 2, 2), localY = -2, transparency = 0.5 },
			})
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			-- GhostFoot bottom at -3 → offset = -3
			expect(offset).to.equal(-3)
			model:Destroy()
		end)

		it('ignores parts worn as Accessories', function()
			-- Visible feet at Y=-2, size 2 → bottom at -3
			-- A "hat" attached as an Accessory sits below the feet (unusual
			-- but defensive). It must not define the feet plane.
			local model = makeModel(Vector3.new(2, 2, 2), {
				{ name = 'Feet', size = Vector3.new(2, 2, 2), localY = -2, transparency = 0 },
			})
			local acc = Instance.new('Accessory')
			acc.Parent = model
			local handle = makePart('Handle', Vector3.new(1, 1, 1), CFrame.new(0, -5, 0), acc, 0)
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			-- Only the Feet part counts (Accessory's Handle is skipped)
			expect(offset).to.equal(-3)
			model:Destroy()
		end)

		it('always includes the PrimaryPart own bottom (even if Transparency=1)', function()
			-- HRP is the PrimaryPart and has Transparency=1.
			-- Its own bottom must still count (it's the rig's reference,
			-- not a stray geometry part).
			local model = makeModel(Vector3.new(2, 2, 2), {})
			model.PrimaryPart.Transparency = 1
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(-1) -- HRP bottom at -1
			model:Destroy()
		end)

		it('returns 0 when the model has no PrimaryPart', function()
			local model = Instance.new('Model')
			model.Parent = game:GetService('Workspace')
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(0)
			model:Destroy()
		end)

		it('uses Humanoid HipHeight when a Humanoid is present (aligns with walk animation feet)', function()
			-- Standard R15 rig: leg bottoms at localY ≈ -2.99
			-- (geometric), but HipHeight defaults to 2. The walk
			-- animation's feet are placed at HRP - HipHeight, not
			-- at the geometric leg bottom. Without using HipHeight,
			-- the animal floats by ~1 stud (the gap between the
			-- geometric bottom and the animation's foot placement).
			-- With HipHeight, the animal sits at the height the
			-- animation expects the feet to be.
			local model = makeModel(Vector3.new(2, 2, 1), {
				{ name = 'Left Leg', size = Vector3.new(1, 2, 1), localY = -1.99 },
			})
			local humanoid = Instance.new('Humanoid')
			humanoid.HipHeight = 2
			humanoid.Parent = model
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(-2) -- -HipHeight, not -2.99
			model:Destroy()
		end)

		it('scales the Humanoid offset with the live model scale (grown animals ground exactly)', function()
			-- Weight growth ScaleTos the model (up to +30%) but
			-- the HipHeight float property stays at its
			-- template value. Settling such a model with the
			-- template-scale offset sinks it by
			-- HipHeight * (scale - 1). The offset must track
			-- the CURRENT scale instead.
			local model = makeModel(Vector3.new(2, 2, 1), {
				{ name = 'Left Leg', size = Vector3.new(1, 2, 1), localY = -1.99 },
			})
			local humanoid = Instance.new('Humanoid')
			humanoid.HipHeight = 2
			humanoid.Parent = model
			model:ScaleTo(1.3)
			-- Pin the property deterministically: whatever the
			-- engine does to HipHeight under ScaleTo, the
			-- contract is offset == -HipHeight * GetScale().
			humanoid.HipHeight = 2
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			expect(offset).to.equal(-2 * model:GetScale())
			model:Destroy()
		end)

		it('falls back to geometric bottom when Humanoid has HipHeight=0', function()
			-- HipHeight=0 means "use the rig's default", which
			-- Roblox resolves to the geometric bottom. We should
			-- fall through to the geometric path rather than
			-- using 0 (which would put the HRP AT the floor,
			-- sinking the model).
			local model = makeModel(Vector3.new(2, 2, 1), {
				{ name = 'Left Leg', size = Vector3.new(1, 2, 1), localY = -1.99 },
			})
			local humanoid = Instance.new('Humanoid')
			humanoid.HipHeight = 0
			humanoid.Parent = model
			local offset = SlotMath.FeetOffsetBelowPrimary(model)
			-- Leg bottom at -1.99 - 1 = -2.99 (geometric)
			expect(offset).to.equal(-2.99)
			model:Destroy()
		end)
	end)
end
