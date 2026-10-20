--!strict
--!native
--[[
	HoverMath.spec
	==============
	The Egg's hover arithmetic is the entire
	correctness contract for the visual gap between the egg
	and the surface below it. A single wrong sign in
	`HoverY` / `FloorY` shows up on every egg on every
	base, and a single wrong direction in
	`HoverCFrameOnSlot` would mis-rotate every landing. So
	these functions are tested directly, as pure math, with no
	Roblox services or state involved.

	What we test:
	  * BlockHeight reads the PrimaryPart and falls back to
	    Constants.EggSize.Y when there is no model.
	  * HoverY(floorY, model) == floorY + HoverClearance + height/2
	    for a 4-tall egg, and the BOTTOM FACE lands at exactly
	    HoverClearance above the surface.
	  * FloorY is the exact inverse of HoverY, and the round-trip
	    holds across a representative range of floor Ys and
	    egg heights.
  * SlotFloorY returns the slot part's top surface.
  * HoverCFrameOnSlot preserves the slot's XZ + rotation and
    derives Y from the slot's top surface — so a thicker
    slot part does not sink the egg (hover contexts only:
    center spawn / flight reference).
  * GroundedCFrameOnSlot seats the egg bottom-flush on the
    slot top (zero gap, per-model pivot-to-bottom offset, no
    hardcoded shift) — the only correct slot-parking
    transform.
  * Settle parks an egg at the slot's SEATED CFrame, refreshes
    centerCFrame / _localFloor, and clears controller /
    controllerType.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local HoverMath = require(ServerScriptService['Egg'].HoverMath)
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local Constants = require(ServerScriptService['Egg'].Constants)

	-- A 4x4x4 model with a real PrimaryPart, the same shape the
	-- ModelBuilder emits in production.
	local function fakeModel(height: number?): Model
		local m = Instance.new('Model')
		local p = Instance.new('Part')
		p.Name = 'Block'
		local h = height or 4
		p.Size = Vector3.new(4, h, 4)
		p.Anchored = true
		p.Parent = m
		m.PrimaryPart = p
		return m
	end

	describe('BlockHeight', function()
		it('reads the PrimaryPart size when a model is given', function()
			local m = fakeModel(7)
			expect(HoverMath.BlockHeight(m)).to.equal(7)
			m:Destroy()
		end)

		it('falls back to Constants.EggSize.Y when no model is given', function()
			expect(HoverMath.BlockHeight(nil)).to.equal(Constants.EggSize.Y)
		end)

		it('falls back to Constants.EggSize.Y when the model has no PrimaryPart', function()
			local m = Instance.new('Model')
			expect(HoverMath.BlockHeight(m)).to.equal(Constants.EggSize.Y)
			m:Destroy()
		end)
	end)

	describe('HoverY / FloorY', function()
		it('places the centre 5 studs above the surface for a 4-tall egg', function()
			-- centreY = floorY + HoverClearance + height/2
			--         = 0 + 3 + 2 = 5
			local m = fakeModel(4)
			expect(HoverMath.HoverY(0, m)).to.equal(5)
			m:Destroy()
		end)

		it('the bottom face is exactly HoverClearance studs above the surface', function()
			local m = fakeModel(4)
			local centreY = HoverMath.HoverY(0, m)
			local bottomY = centreY - 4 / 2
			expect(bottomY).to.equal(EggConfig.HoverClearance)
			m:Destroy()
		end)

		it('clears the configured HoverClearance value (sentinel: not 0, not the old BobCenterHeight)', function()
			-- Catches the regression where a refactor silently
			-- drops the value back to 0 or to a stray literal.
			expect(EggConfig.HoverClearance).to.be.a('number')
			expect(EggConfig.HoverClearance > 0).to.equal(true)
			expect(EggConfig.HoverClearance ~= 3.5).to.equal(true)
		end)

		it('FloorY is the exact inverse of HoverY across many floors', function()
			local m = fakeModel(4)
			for _, floorY in ipairs({ -10, 0, 0.5, 1, 5.25, 17, 100 }) do
				local centreY = HoverMath.HoverY(floorY, m)
				expect(HoverMath.FloorY(centreY, m)).to.be.near(floorY, 0.0001)
			end
			m:Destroy()
		end)

		it('handles a non-default egg height', function()
			-- 6-tall egg: centreY = floorY + 3 + 3 = floorY + 6
			local m = fakeModel(6)
			expect(HoverMath.HoverY(10, m)).to.equal(16)
			expect(HoverMath.FloorY(16, m)).to.equal(10)
			m:Destroy()
		end)
	end)

	describe('SlotFloorY', function()
		it('returns the slot part top surface', function()
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 1, 6)
			part.CFrame = CFrame.new(0, 2, 0) -- centre at Y=2, top at 2.5
			part.Anchored = true
			local slot = { part = part }
			expect(HoverMath.SlotFloorY(slot)).to.equal(2.5)
			part:Destroy()
		end)

		it('returns 0 when the slot has no part', function()
			expect(HoverMath.SlotFloorY(nil)).to.equal(0)
			expect(HoverMath.SlotFloorY({})).to.equal(0)
		end)
	end)

	describe('HoverCFrameOnSlot', function()
		it('preserves the slot XZ and rotation; derives Y from the slot top', function()
			-- Slot at world (10, 2, 20), Yaw 90° (LookVector = +X).
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 1, 6)
			part.CFrame = CFrame.new(10, 2, 20) * CFrame.Angles(0, math.rad(90), 0)
			part.Anchored = true
			local slot = { part = part }
			local m = fakeModel(4)

			local cf = HoverMath.HoverCFrameOnSlot(slot, m)
			expect(cf.X).to.equal(10)
			expect(cf.Z).to.equal(20)
			-- slotTopY = 2 + 0.5 = 2.5; centreY = 2.5 + 3 + 2 = 7.5
			expect(cf.Y).to.equal(7.5)
			local _, yaw, _ = cf:ToEulerAnglesYXZ()
			local _, slotYaw, _ = part.CFrame:ToEulerAnglesYXZ()
			expect(yaw).to.be.near(slotYaw, 0.001)

			m:Destroy()
			part:Destroy()
		end)

		it('a thicker slot part does not sink the egg (Y comes from the slot top, not the centre)', function()
			-- Same slot centre, but Size = (6, 3, 6) — top is at Y = 2 + 1.5 = 3.5.
			-- The egg must be 2 studs above the new top, NOT 2 studs above the
			-- old top of a 1-tall part. With a naïve `slot.CFrame.Y + clearance`
			-- formula, the egg would land at Y=5 and clip the upper half of the
			-- slot.
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 3, 6)
			part.CFrame = CFrame.new(0, 2, 0)
			part.Anchored = true
			local slot = { part = part }
			local m = fakeModel(4)

			local cf = HoverMath.HoverCFrameOnSlot(slot, m)
			-- slotTopY = 2 + 1.5 = 3.5; centreY = 3.5 + 3 + 2 = 8.5
			expect(cf.Y).to.equal(8.5)
			expect(cf.Y - part.Size.Y / 2 - 2).to.be.near(part.CFrame.Y, 0.0001)

			m:Destroy()
			part:Destroy()
		end)
	end)

	describe('GroundedCFrameOnSlot', function()
		it('seats the egg bottom-flush on the slot top (zero gap, no hardcoded shift)', function()
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 1, 6)
			part.CFrame = CFrame.new(10, 2, 20)
			part.Anchored = true
			local slot = { part = part }
			local m = fakeModel(4)

			local cf = HoverMath.GroundedCFrameOnSlot(slot, m)
			expect(cf.X).to.equal(10)
			expect(cf.Z).to.equal(20)
			-- slotTopY = 2.5; pivot offset for a centered 4-tall
			-- part = 2 → pivot Y = 4.5, bottom face at 2.5.
			expect(cf.Y).to.equal(4.5)
			expect(cf.Y - HoverMath.GroundOffset(m)).to.equal(2.5)

			m:Destroy()
			part:Destroy()
		end)

		it('derives Y from the slot top for thicker parts and off-center pivots', function()
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 3, 6)
			part.CFrame = CFrame.new(0, 2, 0)
			part.Anchored = true
			local slot = { part = part }
			-- 6-tall egg: offset 3, top at 3.5 → pivot at 6.5.
			local m = fakeModel(6)

			local cf = HoverMath.GroundedCFrameOnSlot(slot, m)
			expect(cf.Y).to.equal(6.5)
			expect(cf.Y - HoverMath.GroundOffset(m) - part.CFrame.Y).to.be.near(part.Size.Y / 2, 0.0001)

			m:Destroy()
			part:Destroy()
		end)

		it('falls back to half EggSize without a model', function()
			expect(HoverMath.GroundOffset(nil)).to.equal(Constants.EggSize.Y / 2)
			local slot = {}
			local cf = HoverMath.GroundedCFrameOnSlot(slot, nil)
			expect(cf.Y).to.equal(Constants.EggSize.Y / 2)
		end)
	end)

	describe('Settle', function()
		it('parks the model at the slot seated CFrame, refreshes the record, and clears the controller', function()
			local part = Instance.new('Part')
			part.Size = Vector3.new(6, 1, 6)
			part.CFrame = CFrame.new(0, 2, 0)
			part.Anchored = true
			local slot = { part = part }
			local model = fakeModel(4)
			-- Park the model somewhere far away first so we can
			-- assert that Settle actually moves it.
			model:PivotTo(CFrame.new(100, 100, 100))

			local egg: any = {
				model = model,
				centerCFrame = nil,
				_localFloor = nil,
				controller = { fake = true },
				controllerType = 'Fake',
			}
			HoverMath.Settle(egg, slot)

			-- The model's pivot should equal the slot seated CFrame.
			local modelPos = model:GetPivot().Position
			local slotHoverPos = HoverMath.GroundedCFrameOnSlot(slot, model).Position
			expect(Vector3.new(modelPos.X, modelPos.Y, modelPos.Z)).to.be.near(slotHoverPos, 0.0001)

			-- The record mirrors the new state.
			expect(egg.centerCFrame).to.be.ok()
			expect(egg._localFloor).to.equal(2.5)
			expect(egg.controller).to.equal(nil)
			expect(egg.controllerType).to.equal(nil)

			part:Destroy()
			model:Destroy()
		end)
	end)
end
