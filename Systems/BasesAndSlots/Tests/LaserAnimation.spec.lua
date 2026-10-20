--!strict
--!native
--[[
	LaserAnimation.spec
	===================
	Instant Base Lock laser state application.

	Covers the safety-critical math (all synchronous, no tween
	— timing asserts exist by design):
	  * Register captures the authored Size/CFrame once and snaps
	    retracted.
	  * Snap(locked=true) restores the EXACT authored Size and
	    position/rotation.
	  * Snap(locked=false) retracts while keeping the ground
	    (bottom) point anchored, including for rotated Parts.
	  * Repeated lock/unlock cycles never drift Size or CFrame
	    (originals are never derived from animated state).
	  * SetLocked fires without error and applies the final state immediately (instant-path smoke test).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local LaserAnimation = require(ServerScriptService.Base.LaserAnimation)

	local function makeLaser(size: Vector3, cf: CFrame): BasePart
		local part = Instance.new('Part')
		part.Name = 'Part'
		part.Size = size
		part.CFrame = cf
		part.Anchored = true
		part.Parent = workspace
		return part
	end

	local function bottomOf(part: BasePart): Vector3
		return part.CFrame.Position - part.CFrame.YVector * (part.Size.Y * 0.5)
	end

	beforeEach(function()
		LaserAnimation._TestReset()
	end)

	describe('LaserAnimation', function()
		it('snaps retracted on register and restores exact authored state on lock', function()
			local size = Vector3.new(1, 10, 1)
			local cf = CFrame.new(0, 5, 0)
			local part = makeLaser(size, cf)
			LaserAnimation.Register('Base_1', { part })
			-- Retracted: bottom anchored at y=0, tiny height.
			expect(part.Size.Y < 1).to.equal(true)
			expect(math.abs(bottomOf(part).Y - 0) < 0.01).to.equal(true)
			LaserAnimation.Snap('Base_1', { part }, true)
			expect(part.Size.X).to.equal(size.X)
			expect(part.Size.Y).to.equal(size.Y)
			expect(part.Size.Z).to.equal(size.Z)
			expect((part.CFrame.Position - cf.Position).Magnitude < 0.001).to.equal(true)
			part:Destroy()
		end)

		it('keeps the ground point anchored for rotated lasers', function()
			local size = Vector3.new(2, 8, 2)
			local cf = CFrame.new(10, 4, 0) * CFrame.Angles(0, 0, math.rad(15))
			local part = makeLaser(size, cf)
			local authoredBottom = part.CFrame.Position - part.CFrame.YVector * (size.Y * 0.5)
			LaserAnimation.Register('Base_2', { part })
			local retractedBottom = bottomOf(part)
			expect((retractedBottom - authoredBottom).Magnitude < 0.01).to.equal(true)
			-- Rotation preserved while retracted.
			expect(part.CFrame.YVector:Dot(cf.YVector) > 0.999).to.equal(true)
			LaserAnimation.Snap('Base_2', { part }, true)
			expect(part.Size.Y).to.equal(size.Y)
			expect((bottomOf(part) - authoredBottom).Magnitude < 0.01).to.equal(true)
			part:Destroy()
		end)

		it('never drifts across repeated lock/unlock cycles', function()
			local size = Vector3.new(1.5, 12, 1.5)
			local cf = CFrame.new(3, 6, 7)
			local part = makeLaser(size, cf)
			LaserAnimation.Register('Base_3', { part })
			for _ = 1, 5 do
				LaserAnimation.Snap('Base_3', { part }, true)
				expect(part.Size.Y).to.equal(size.Y)
				LaserAnimation.Snap('Base_3', { part }, false)
			end
			LaserAnimation.Snap('Base_3', { part }, true)
			expect(part.Size.X).to.equal(size.X)
			expect(part.Size.Y).to.equal(size.Y)
			expect(part.Size.Z).to.equal(size.Z)
			expect((part.CFrame.Position - cf.Position).Magnitude < 0.001).to.equal(true)
			part:Destroy()
		end)

		it('SetLocked fires without error and keeps bases independent', function()
			local a = makeLaser(Vector3.new(1, 6, 1), CFrame.new(0, 3, 0))
			local b = makeLaser(Vector3.new(1, 6, 1), CFrame.new(20, 3, 0))
			LaserAnimation.Register('Base_A', { a })
			LaserAnimation.Register('Base_B', { b })
			LaserAnimation.SetLocked('Base_A', { a }, true)
			-- B untouched: still retracted while A extends.
			expect(b.Size.Y < 1).to.equal(true)
			LaserAnimation.SetLocked('Base_A', { a }, false)
			a:Destroy()
			b:Destroy()
		end)
	end)
end
