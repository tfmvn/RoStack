--!strict
--!native
--[[
	ResetProtection.spec
	====================
	Server-authoritative reset gate (ResetProtectionService +
	CarryRegistry.OnChanged).

	Coverage (no Player objects needed — Refresh degrades to
	cache-only without one; push delivery is a Studio playtest
	item):
	  1. Default state is unprotected (join parity).
	  2. Animal Set -> protected; Clear -> unprotected.
	  3. Egg Set -> protected (same transient transaction shape).
	  4. Steal-flagged item -> protected.
	  5. Rapid Set->Clear->Set ends protected (no stale flip).
	  6. Per-player isolation (A protected, B normal, then both,
	     then only B).
	  7. OnChanged fires on committed Set / effective Clear only
	     (rejected Set and no-op Clear are silent).
	  8. Init resets subscribers (spec isolation).
	  9. ForgetPlayer clears the push cache without touching the
	     registry.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local ResetProtectionService = require(ServerScriptService.Carry.ResetProtectionService)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local function animalItem(uid: string): any
		return {
			kind = SlotType.OccupantKind.Animal,
			record = { uniqueId = uid },
			originalSlotId = 'p7:1:slot:1',
			startedAt = os.clock(),
		}
	end

	local function eggItem(uid: string): any
		return {
			kind = SlotType.OccupantKind.Egg,
			record = { uniqueId = uid },
			originalSlotId = 'p7:1:slot:2',
			startedAt = os.clock(),
		}
	end

	local function stealItem(uid: string): any
		local item = animalItem(uid)
		item.steal = { originalOwnerUserId = 1 }
		return item
	end

	describe('ResetProtection', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
			ResetProtectionService._TestReset()
			ResetProtectionService.Init()
		end)

		it('defaults to unprotected', function()
			expect(ResetProtectionService.IsProtected(9101)).to.equal(false)
		end)

		it('protects on animal grab and releases on place', function()
			local ok, _ = CarryRegistry.Set(9102, animalItem('AN_a'))
			expect(ok).to.equal(true)
			expect(ResetProtectionService.IsProtected(9102)).to.equal(true)
			CarryRegistry.Clear(9102)
			expect(ResetProtectionService.IsProtected(9102)).to.equal(false)
		end)

		it('protects egg carries identically', function()
			local ok, _ = CarryRegistry.Set(9103, eggItem('EG_a'))
			expect(ok).to.equal(true)
			expect(ResetProtectionService.IsProtected(9103)).to.equal(true)
			CarryRegistry.Clear(9103)
			expect(ResetProtectionService.IsProtected(9103)).to.equal(false)
		end)

		it('protects steal-flagged carries', function()
			local ok, _ = CarryRegistry.Set(9104, stealItem('AN_s'))
			expect(ok).to.equal(true)
			expect(ResetProtectionService.IsProtected(9104)).to.equal(true)
			CarryRegistry.Clear(9104)
			expect(ResetProtectionService.IsProtected(9104)).to.equal(false)
		end)

		it('rapid pickup/place/pickup ends protected', function()
			CarryRegistry.Set(9105, animalItem('AN_1'))
			CarryRegistry.Clear(9105)
			expect(ResetProtectionService.IsProtected(9105)).to.equal(false)
			CarryRegistry.Set(9105, animalItem('AN_2'))
			expect(ResetProtectionService.IsProtected(9105)).to.equal(true)
		end)

		it('isolates players independently', function()
			CarryRegistry.Set(9106, animalItem('AN_x'))
			expect(ResetProtectionService.IsProtected(9106)).to.equal(true)
			expect(ResetProtectionService.IsProtected(9107)).to.equal(false)
			CarryRegistry.Set(9107, animalItem('AN_y'))
			expect(ResetProtectionService.IsProtected(9107)).to.equal(true)
			CarryRegistry.Clear(9106)
			expect(ResetProtectionService.IsProtected(9106)).to.equal(false)
			expect(ResetProtectionService.IsProtected(9107)).to.equal(true)
		end)

		it('notifies only on committed changes', function()
			local calls: { number } = {}
			local unsubscribe = CarryRegistry.OnChanged(function(userId: number)
				calls[#calls + 1] = userId
			end)
			CarryRegistry.Set(9108, animalItem('AN_n'))
			expect(#calls).to.equal(1)
			-- Rejected Set (already carrying): silent.
			CarryRegistry.Set(9108, animalItem('AN_n2'))
			expect(#calls).to.equal(1)
			-- No-op Clear (not carrying): silent.
			CarryRegistry.Clear(9109)
			expect(#calls).to.equal(1)
			-- Effective Clear: notifies.
			CarryRegistry.Clear(9108)
			expect(#calls).to.equal(2)
			unsubscribe()
		end)

		it('Init resets subscribers', function()
			local calls = 0
			CarryRegistry.OnChanged(function(_: number)
				calls += 1
			end)
			CarryRegistry.Init()
			CarryRegistry.Set(9110, animalItem('AN_z'))
			expect(calls).to.equal(0)
		end)

		it('ForgetPlayer clears cache without touching the registry', function()
			CarryRegistry.Set(9111, animalItem('AN_f'))
			ResetProtectionService.Refresh(9111)
			ResetProtectionService.ForgetPlayer(9111)
			-- Registry untouched: still carrying -> still protected.
			expect(CarryRegistry.IsCarrying(9111)).to.equal(true)
			expect(ResetProtectionService.IsProtected(9111)).to.equal(true)
		end)
	end)
end
