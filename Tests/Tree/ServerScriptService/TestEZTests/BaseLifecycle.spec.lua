--!strict
--!native
--[[
	BaseLifecycle.spec
	==================
	Ownership-session fencing + release/assign hygiene
	(BaseService session tokens, ValidateBaseRuntime, shared
	release sweep, SlotService warning reset, prompt-registry
	purge).

	Coverage (headless-safe, no animals/players needed):
	  1. Fresh bases start at session 0 and validate clean.
	  2. Assign bumps the session; release bumps it again.
	  3. IsCurrentSession rejects the pre-assign session after
	     release (stale-callback fencing).
	  4. Release leaves zero-stamped, Empty, mutex-free slots.
	  5. Reassign after release validates clean (no inheritance).
	  6. Dirt injected pre-assign is scrubbed, not inherited.
	  7. Rapid assign/release cycles keep sessions strictly
	     increasing with no stuck mutex.
]]

return function()
	local Helpers = require(script.Parent._Helpers)

	describe('BaseLifecycle', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		local function setup()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			return services
		end

		it('fresh bases start at session 0 and validate clean', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9301)
			expect(b).to.be.ok()
			-- Assign bumped 0 -> 1.
			expect(services.BaseService.GetSession(b.id)).to.equal(1)
			expect(services.BaseService.ValidateBaseRuntime(b.id)).to.equal(true)
			expect(services.BaseService.IsCurrentSession(b.id, 1)).to.equal(true)
			services.BaseService.CleanupPlayer(9301)
		end)

		it('release bumps the session and invalidates the old one', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9302)
			local bid = b.id
			expect(services.BaseService.GetSession(bid)).to.equal(1)
			services.BaseService.ReleaseBase(bid, 9302)
			expect(services.BaseService.GetSession(bid)).to.equal(2)
			-- Stale owner callback holding session 1 is fenced.
			expect(services.BaseService.IsCurrentSession(bid, 1)).to.equal(false)
			expect(services.BaseService.IsCurrentSession(bid, 2)).to.equal(true)
			-- Released base validates as empty/inactive.
			expect(services.BaseService.ValidateBaseRuntime(bid)).to.equal(true)
		end)

		it('release clears slots, mutexes, and owner refs', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9303)
			local bid = b.id
			local slot = services.SlotService.GetFreeSlot(9303)
			expect(slot).to.be.ok()
			services.SlotService.ReserveSlot(slot.id)
			services.SlotService.OccupySlot(slot.id, 'AN_x', 'animal')
			services.BaseService.CleanupPlayer(9303)
			local fresh = services.BaseService.GetBaseById(bid)
			expect(fresh.ownerUserId).to.equal(nil)
			expect(fresh.state).to.equal('Available')
			for _, s in pairs(fresh.slots) do
				expect(s.state).to.equal('Empty')
				expect(s.occupantId).to.equal(nil)
				expect(s.ownerUserId).to.equal(0)
				expect(s._mutex).to.equal(false)
			end
		end)

		it('reassign after release starts clean with a new session', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9304)
			local bid = b.id
			services.BaseService.CleanupPlayer(9304)
			expect(services.BaseService.GetSession(bid)).to.equal(2)
			local b2 = services.BaseService.AssignBaseById(9305, bid)
			expect(b2).to.be.ok()
			expect(services.BaseService.GetSession(bid)).to.equal(3)
			expect(services.BaseService.ValidateBaseRuntime(bid)).to.equal(true)
			for _, s in pairs(b2.slots) do
				expect(s.ownerUserId).to.equal(9305)
			end
			services.BaseService.CleanupPlayer(9305)
		end)

		it('pre-assign dirt is scrubbed, never inherited', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9306)
			local bid = b.id
			services.BaseService.ReleaseBase(bid, 9306)
			-- Simulate a previous release that left dirt behind.
			local base = services.BaseService.GetBaseById(bid)
			base.slots[1].state = 'Occupied'
			base.slots[1].occupantId = 'GHOST'
			expect(services.BaseService.ValidateBaseRuntime(bid)).to.equal(false)
			local b2 = services.BaseService.AssignBaseById(9307, bid)
			expect(b2).to.be.ok()
			expect(b2.id).to.equal(bid)
			expect(services.BaseService.ValidateBaseRuntime(bid)).to.equal(true)
			expect(base.slots[1].state).to.equal('Empty')
			expect(base.slots[1].occupantId).to.equal(nil)
			services.BaseService.CleanupPlayer(9307)
		end)

		it('rapid assign/release keeps sessions increasing, mutexes free', function()
			local services = setup()
			local b = services.BaseService.AssignBaseForPlayer(9308)
			local bid = b.id
			local last = services.BaseService.GetSession(bid)
			for _ = 1, 3 do
				services.BaseService.ReleaseBase(bid, 9308)
				local now = services.BaseService.GetSession(bid)
				expect(now > last).to.equal(true)
				last = now
				local nb = services.BaseService.AssignBaseById(9308, bid)
				expect(nb).to.be.ok()
				expect(services.BaseService.GetSession(bid) > last).to.equal(true)
				last = services.BaseService.GetSession(bid)
			end
			local final = services.BaseService.GetBaseById(bid)
			expect(final._mutex).to.equal(false)
			for _, s in pairs(final.slots) do
				expect(s._mutex).to.equal(false)
			end
			services.BaseService.CleanupPlayer(9308)
		end)
	end)
end
