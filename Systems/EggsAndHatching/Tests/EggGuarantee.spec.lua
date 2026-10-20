--!strict
--!native
--[[
	EggGuarantee.spec
	=================
	GuaranteeService: the additive spawn-rarity guarantee layer
	on top of the restored 7235158 Egg system. Covers the
	contract the spawn loop relies on:

	  * nothing due at boot; full-interval remaining
	  * due after the configured interval
	  * Legendary outranks Mythic when both are due
	  * NoteSpawned resets only that rarity (natural and
	    forced appearances both satisfy)
	  * due persists until satisfied (no silent timeout)
	  * Remaining clamps at 0 (never negative)
	  * revision bumps on reset (client out-of-order guard)
	  * unknown rarities are ignored, never throw

	Time is driven deterministically through the nowOverride
	params (1s margins so real-clock noise cannot flake
	boundaries). No eggs are spawned; no Workspace needed.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')

	local GuaranteeService = require(ServerScriptService.Egg.GuaranteeService)

	-- Legendary 10min, Mythic 20min per EggConfig (margins keep
	-- real-clock noise out of boundary assertions).
	local LEGENDARY_INTERVAL = 10 * 60
	local MYTHIC_INTERVAL = 20 * 60

	describe('EggGuaranteeService', function()
		local t0: number

		beforeEach(function()
			GuaranteeService._TestReset()
			t0 = os.clock()
		end)

		afterEach(function()
			GuaranteeService._TestReset()
		end)

		it('nothing is due at boot with full intervals remaining', function()
			expect(GuaranteeService.PickDue(t0 + 1)).to.equal(nil)
			local state = GuaranteeService.GetState(t0 + 1)
			expect(#state).to.equal(2)
			expect(state[1].Rarity).to.equal('Legendary')
			expect(state[2].Rarity).to.equal('Mythic')
			for _, row in ipairs(state) do
				expect(row.Due).to.equal(false)
				expect(row.Remaining > 0).to.equal(true)
			end
		end)

		it('a rarity becomes due after its interval', function()
			expect(GuaranteeService.PickDue(t0 + LEGENDARY_INTERVAL - 1)).to.equal(nil)
			expect(GuaranteeService.PickDue(t0 + LEGENDARY_INTERVAL + 1)).to.equal('Legendary')
		end)

		it('Legendary outranks Mythic when both are due, and due persists', function()
			-- Far future: both due → Legendary first.
			expect(GuaranteeService.PickDue(t0 + MYTHIC_INTERVAL + 100)).to.equal('Legendary')
			-- Satisfy Legendary recently, Mythic long ago:
			-- only Mythic is due now.
			GuaranteeService._TestSetLastSpawn('Legendary', t0 + MYTHIC_INTERVAL)
			GuaranteeService._TestSetLastSpawn('Mythic', t0)
			expect(GuaranteeService.PickDue(t0 + MYTHIC_INTERVAL + 100)).to.equal('Mythic')
			-- Satisfy Mythic too: nothing due at that instant.
			GuaranteeService._TestSetLastSpawn('Mythic', t0 + MYTHIC_INTERVAL + 100)
			expect(GuaranteeService.PickDue(t0 + MYTHIC_INTERVAL + 101)).to.equal(nil)
		end)

		it('a successful spawn resets only its own timer', function()
			GuaranteeService.NoteSpawned('Legendary')
			-- Legendary just reset (plus Mythic nowhere near
			-- due yet): nothing due.
			expect(GuaranteeService.PickDue(os.clock() + LEGENDARY_INTERVAL - 1)).to.equal(nil)
			local state = GuaranteeService.GetState(os.clock() + 1)
			expect(state[1].Revision).to.equal(1)
		end)

		it('a natural appearance resets its timer', function()
			GuaranteeService._TestSetLastSpawn('Mythic', t0)
			GuaranteeService._TestSetLastSpawn('Legendary', t0 + 700)
			expect(GuaranteeService.PickDue(t0 + MYTHIC_INTERVAL - 1)).to.equal(nil)
			expect(GuaranteeService.PickDue(t0 + MYTHIC_INTERVAL + 1)).to.equal('Mythic')
		end)

		it('Remaining clamps at zero and never goes negative', function()
			local state = GuaranteeService.GetState(t0 + 100 * MYTHIC_INTERVAL)
			for _, row in ipairs(state) do
				expect(row.Remaining).to.equal(0)
				expect(row.Due).to.equal(true)
			end
		end)

		it('revision starts at 0 and bumps on reset', function()
			local before = GuaranteeService.GetState(t0 + 1)
			expect(before[1].Revision).to.equal(0)
			GuaranteeService.NoteSpawned('Legendary')
			local after = GuaranteeService.GetState(t0 + 1)
			expect(after[1].Revision).to.equal(1)
		end)

		it('unknown rarities are ignored without throwing', function()
			expect(function()
				GuaranteeService.NoteSpawned('Common')
				GuaranteeService.NoteSpawned('')
				GuaranteeService.NoteSpawned(nil :: any)
			end).to.never.throw()
			local state = GuaranteeService.GetState(t0 + 1)
			expect(state[1].Revision).to.equal(0)
			expect(GuaranteeService.PickDue(t0 + 1)).to.equal(nil)
		end)
	end)
end
