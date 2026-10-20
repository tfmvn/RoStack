--!strict
--!native
--[[
	BrainrotCarryConfig.spec
	========================
	Locks in the shape of `AnimalConfig.Carry` (Phase 1.5). All
	carry/place tunables live here so a designer can rebalance
	without touching service code. This spec verifies:
	  A. The Carry sub-table is present on the config.
	  B. MaxDistance is a positive number (server-side distance
	     check; the ProximityPrompt reuses this for the client
	     hint).
	  C. HoldDuration is a number (0 = instant activation).
	  D. GrabActionText / PlaceActionText are non-empty strings.
	  E. HeadClearanceStuds is a non-negative number (the vertical
	     gap between the top of the player's Head and the carried
	     model — 0 means "resting on the crown", larger values
	     float the model above the head).
	  F. GrabObjectText / PlaceObjectText are non-empty strings.
	  G. The legacy CarryOffset and YawSmoothing keys are no
	     longer present. The pose is derived from the Head part
	     (Motor6D + C0), and the Motor6D's joint solver drives
	     rotation through the rig — there's no per-tick yaw
	     smoothing to tune.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local AnimalConfig = require(ReplicatedStorage.Config.Creatures.Animals)

	describe('AnimalConfig.Carry', function()
		it('is present as a sub-table', function()
			expect(AnimalConfig.Carry).to.be.a('table')
		end)

		it('MaxDistance is a positive number', function()
			expect(type(AnimalConfig.Carry.MaxDistance)).to.equal('number')
			expect(AnimalConfig.Carry.MaxDistance > 0).to.equal(true)
		end)

		it('HoldDuration is a number (0 = instant activation is allowed)', function()
			expect(type(AnimalConfig.Carry.HoldDuration)).to.equal('number')
			expect(AnimalConfig.Carry.HoldDuration >= 0).to.equal(true)
		end)

		it('GrabActionText and PlaceActionText are non-empty strings', function()
			expect(type(AnimalConfig.Carry.GrabActionText)).to.equal('string')
			expect(#AnimalConfig.Carry.GrabActionText > 0).to.equal(true)
			expect(type(AnimalConfig.Carry.PlaceActionText)).to.equal('string')
			expect(#AnimalConfig.Carry.PlaceActionText > 0).to.equal(true)
		end)

		it('HeadClearanceStuds is a non-negative number', function()
			expect(type(AnimalConfig.Carry.HeadClearanceStuds)).to.equal('number')
			expect(AnimalConfig.Carry.HeadClearanceStuds >= 0).to.equal(true)
		end)

		it('GrabObjectText and PlaceObjectText are non-empty strings', function()
			expect(type(AnimalConfig.Carry.GrabObjectText)).to.equal('string')
			expect(#AnimalConfig.Carry.GrabObjectText > 0).to.equal(true)
			expect(type(AnimalConfig.Carry.PlaceObjectText)).to.equal('string')
			expect(#AnimalConfig.Carry.PlaceObjectText > 0).to.equal(true)
		end)

		it('no longer carries the legacy CarryOffset or YawSmoothing keys', function()
			-- The pose is derived from the Head part now (Motor6D
			-- + C0), so a fixed Vector3 offset is no longer a
			-- tunable. The Motor6D's joint solver drives rotation
			-- through the rig — no per-tick yaw smoothing to tune.
			expect(AnimalConfig.Carry.CarryOffset).to.equal(nil)
			expect(AnimalConfig.Carry.YawSmoothing).to.equal(nil)
		end)
	end)
end
