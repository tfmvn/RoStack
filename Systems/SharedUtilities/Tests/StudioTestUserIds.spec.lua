--!strict
--!native
--[[
	StudioTestUserIds.spec
	======================
	Dev-only Studio multi-instance UserIds (0, -1, -2, ...).

	Locks the safety contract:

	  * Debug.AllowStudioTestUserIds defaults to true (harmless at publish: IsStudio gate).
	  * Dev mode OFF: 0 and negatives are INVALID (production
	    behavior); positive ids valid.
	  * Dev mode ON (StudioTestMode.Enabled = true — mutable
	    precisely so specs and the Studio command bar can flip
	    it; Systems.Debug itself is frozen): 0 and small negatives
	    (-1, -2) are accepted as Player UserIds. This runs in
	    Studio, so IsStudio() holds here, exercising the real
	    gate (flag AND IsStudio).
	  * Non-ids (fractions, NaN, infinities, non-numbers) and
	    out-of-range negatives are ALWAYS invalid, mode or not.
	  * Unrelated numeric schemas (PositiveInteger, SlotIndex)
	    ignore dev mode: 0 stays invalid for them.
	  * SlotType.BuildId mints p7:-1:slot:n only in dev mode
	    (live: still asserts); ParseId/Validation.SlotId parse
	    such ids structurally anywhere (ownership validation
	    still rejects them live via IsValidPlayerUserId).
	  * Live-server safety (IsStudio() == false) holds by
	    inspection: IsEnabled() requires IsStudio() AND the
	    opt-in — a published server rejects 0/negatives even
	    with a flag accidentally left on.

	Every dev-mode test restores Enabled = false so no other
	spec observes dev mode.
]]

return function()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Debug = require(ReplicatedStorage.Config.Systems.Debug)
	local Validation = require(ReplicatedStorage.Utility.Validation)
	local StudioTestMode = require(ReplicatedStorage.Utility.StudioTestMode)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('AllowStudioTestUserIds', function()
		it('defaults to true (declared + runtime; harmless at publish: IsStudio gate)', function()
			expect(Debug.AllowStudioTestUserIds).to.equal(true)
			StudioTestMode.Enabled = false
			expect(StudioTestMode.IsEnabled()).to.equal(false)
		end)

		it('dev mode OFF: 0 and negatives invalid (production behavior)', function()
			StudioTestMode.Enabled = false
			expect(Validation.IsValidPlayerUserId(0)).to.equal(false)
			expect(Validation.IsValidPlayerUserId(-1)).to.equal(false)
			expect(Validation.IsValidPlayerUserId(-2)).to.equal(false)
			expect(Validation.IsValidPlayerUserId(1)).to.equal(true)
			expect(Validation.IsValidPlayerUserId(2)).to.equal(true)
			expect(Validation.IsValidPlayerUserId(9007199)).to.equal(true)
		end)

		it('dev mode ON (in Studio): 0/-1/-2 accepted as Player UserIds', function()
			StudioTestMode.Enabled = true
			expect(StudioTestMode.IsEnabled()).to.equal(true)
			expect(Validation.IsValidPlayerUserId(0)).to.equal(true)
			expect(Validation.IsValidPlayerUserId(-1)).to.equal(true)
			expect(Validation.IsValidPlayerUserId(-2)).to.equal(true)
			expect(Validation.IsValidPlayerUserId(1)).to.equal(true)
			StudioTestMode.Enabled = false
		end)

		it('always rejects non-ids, whatever the mode', function()
			for _, enabled in ipairs({ false, true }) do
				StudioTestMode.Enabled = enabled
				expect(Validation.IsValidPlayerUserId(-101)).to.equal(false)
				expect(Validation.IsValidPlayerUserId(-0.5)).to.equal(false)
				expect(Validation.IsValidPlayerUserId(1.5)).to.equal(false)
				expect(Validation.IsValidPlayerUserId(0 / 0)).to.equal(false)
				expect(Validation.IsValidPlayerUserId(math.huge)).to.equal(false)
				expect(Validation.IsValidPlayerUserId(-math.huge)).to.equal(false)
				expect(Validation.IsValidPlayerUserId('0')).to.equal(false)
				expect(Validation.IsValidPlayerUserId('-1')).to.equal(false)
				expect(Validation.IsValidPlayerUserId(nil)).to.equal(false)
				expect(Validation.IsValidPlayerUserId({})).to.equal(false)
				expect(Validation.IsValidPlayerUserId(true)).to.equal(false)
			end
			StudioTestMode.Enabled = false
		end)

		it('unrelated numeric schemas ignore dev mode', function()
			StudioTestMode.Enabled = true
			expect(Validation.PositiveInteger(0)).to.equal(false)
			expect(Validation.PositiveInteger(1)).to.equal(true)
			expect(Validation.SlotIndex(0)).to.equal(false)
			expect(Validation.SlotIndex(1)).to.equal(true)
			StudioTestMode.Enabled = false
		end)

		it('slot ids: BuildId mints negatives only in dev mode; parsing is structural', function()
			StudioTestMode.Enabled = false
			local okLive = pcall(SlotType.BuildId, -1, 'slot', 1)
			expect(okLive).to.equal(false)
			expect(SlotType.BuildId(7, 'slot', 1)).to.equal('p7:7:slot:1')
			StudioTestMode.Enabled = true
			expect(SlotType.BuildId(-1, 'slot', 3)).to.equal('p7:-1:slot:3')
			expect(SlotType.BuildId(0, 'slot', 3)).to.equal('p7:0:slot:3')
			StudioTestMode.Enabled = false
			-- Structural parsing works regardless (validation
			-- of the parsed userId stays with callers).
			local parsed = SlotType.ParseId('p7:-1:slot:3')
			expect(parsed ~= nil).to.equal(true)
			assert(parsed ~= nil, 'negative slot id parses')
			expect(parsed.userId).to.equal(-1)
			expect(parsed.index).to.equal(3)
			expect(Validation.SlotId('p7:-1:slot:3')).to.equal(true)
			expect(Validation.SlotId('p7:0:slot:3')).to.equal(true)
			expect(Validation.SlotId('p7:7:slot:1')).to.equal(true)
			expect(Validation.SlotId('p7:-1:slot:x')).to.equal(false)
		end)
	end)
end
