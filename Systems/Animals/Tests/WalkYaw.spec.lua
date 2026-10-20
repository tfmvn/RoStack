--!strict
--!native
--[[
	WalkYaw.spec
	============
	Guards the walk's final yaw against the FacingOffset
	regression.

	WalkController.Start now targets `targetCFrame`'s Yaw
	(the slot's standing CFrame, which equals the slot part's
	CFrame when there's no model-aware offset). After the
	Collector-facing change, the slot's Yaw is the
	Collector's direction, and the animal's authored front
	is local +Z. The 180° flip that was needed for the
	segDir-based yaw was removed (FacingOffset is now 0).

	If a future change accidentally re-introduces the
	math.pi offset, the animal will visibly face opposite
	to the slot — i.e. away from the Collector. This test
	fails fast in that case.

	What we test:
	  1. A direct call to WalkController's yaw math (re-
	     implemented here for unit testing) with FacingOffset
	     = 0 produces a target yaw equal to the slot's yaw.
	  2. With FacingOffset = math.pi (the pre-fix value), the
	     target yaw is OPPOSITE the slot's yaw. This is a
	     negative-control assertion to confirm the test is
	     sensitive to the change.
]]

return function()
	-- Re-implement the WalkController's yaw math so we
	-- can unit-test it without standing up a full
	-- pathfinder + animal model. Mirrors the per-tick
	-- math in WalkController.Start (after the
	-- targetCFrame change):
	--
	--   local _, targetYawRaw, _ = targetCFrame:ToEulerAnglesYXZ()
	--   local targetYaw = targetYawRaw + FacingOffset
	--
	-- (Smoothing is skipped — the final snap at t >= 1
	-- uses `targetYaw` directly.)
	local function computeTargetYaw(targetCFrame: CFrame, facingOffset: number): number
		local _, raw, _ = targetCFrame:ToEulerAnglesYXZ()
		return raw + facingOffset
	end

	describe('WalkController target yaw', function()
		it('with FacingOffset = 0, target yaw equals slot yaw (Collector direction)', function()
			-- Slot Yaw 90° (slot's +Z = +X). Animal's
			-- authored front is +Z, so it should face
			-- the same direction the slot faces: +X.
			local slotCF = CFrame.new(0, 5, 0) * CFrame.Angles(0, math.rad(90), 0)
			local targetYaw = computeTargetYaw(slotCF, 0)
			local _, slotYaw, _ = slotCF:ToEulerAnglesYXZ()
			expect(targetYaw).to.be.near(slotYaw, 0.001)
		end)

		it('with FacingOffset = 0, the animal does NOT face opposite the slot', function()
			-- Belt-and-braces: assert the target yaw
			-- is NOT the flipped yaw. If FacingOffset
			-- were re-introduced as math.pi, the
			-- target yaw would be opposite the slot.
			-- We assert this positively: the target yaw
			-- is near the slot's yaw (already covered
			-- above), and the target yaw's distance to
			-- the flipped yaw is at least 2 radians
			-- (a quarter turn), which is well outside
			-- the slot yaw.
			local slotCF = CFrame.new(0, 5, 0) * CFrame.Angles(0, math.rad(45), 0)
			local targetYaw = computeTargetYaw(slotCF, 0)
			local _, slotYaw, _ = slotCF:ToEulerAnglesYXZ()
			local flipped = slotYaw + math.pi
			-- Wrapped distance (handles +/- pi rollover):
			local dist = math.abs(((targetYaw - flipped + math.pi) % (2 * math.pi)) - math.pi)
			expect(dist).to.be.near(math.pi, 0.5)
		end)

		it('negative control: FacingOffset = math.pi DOES flip the yaw', function()
			-- If this test ever fails, the test
			-- environment is broken (e.g. ToEulerAnglesYXZ
			-- not behaving as expected) and the positive
			-- assertions above are meaningless.
			local slotCF = CFrame.new(0, 5, 0) * CFrame.Angles(0, math.rad(45), 0)
			local targetYaw = computeTargetYaw(slotCF, math.pi)
			local _, slotYaw, _ = slotCF:ToEulerAnglesYXZ()
			local flipped = slotYaw + math.pi
			expect(targetYaw).to.be.near(flipped, 0.001)
		end)

		it('WalkController.FacingOffset exported value is 0', function()
			-- The module's FacingOffset is read by the
			-- per-tick yaw math. If this drifts back
			-- to math.pi, the animal will face
			-- opposite the Collector. Lock it down
			-- with a direct module-table assertion.
			local ServerScriptService = game:GetService('ServerScriptService')
			local WalkController = require(ServerScriptService.Animal.WalkController)
			expect(WalkController.FacingOffset).to.equal(0)
		end)
	end)
end
