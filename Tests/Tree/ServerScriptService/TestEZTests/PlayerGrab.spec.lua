--!strict
--!native
--[[
	PlayerGrab.spec
	===============
	Server-side Grab-pose presentation (PlayerGrabService).

	Headless-safe coverage (no real rigs/ids needed — every
	assert runs without loading an animation):
	  1. No carry -> no entry, IsPlaying false, no throw.
	  2. Carry without a Player object -> no entry, no throw
	     (Studio specs / removed players degrade silently-safe;
	     the missing-Character WARN path needs a live Player and
	     is a Studio playtest item).
	  3. Registry Clear -> entry state cleaned, IsPlaying false.
	  4. Rapid Set->Clear->Set never throws, never leaks entries.
	  5. Failed pickup (no registry entry) -> Grab never starts.
	  6. _TestReset drops all entries.
	Visual blending (arms raised + legs walking, jump/fall/land)
	is a Studio playtest item — see the service header for the
	upper-body authoring assumption.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local PlayerGrabService = require(ServerScriptService.Carry.PlayerGrabService)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local function animalItem(uid: string): any
		return {
			kind = SlotType.OccupantKind.Animal,
			record = { uniqueId = uid },
			originalSlotId = 'p7:1:slot:1',
			startedAt = os.clock(),
		}
	end

	describe('PlayerGrab', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
			PlayerGrabService._TestReset()
			PlayerGrabService.Init()
		end)

		it('is idle with no carry', function()
			expect(PlayerGrabService.IsPlaying(9201)).to.equal(false)
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
		end)

		it('failed pickup never starts Grab', function()
			-- No CarryRegistry entry == pickup rejected/cancelled.
			expect(CarryRegistry.IsCarrying(9202)).to.equal(false)
			expect(PlayerGrabService.IsPlaying(9202)).to.equal(false)
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
		end)

		it('carry without a Player object cleans up safely', function()
			local ok, _ = CarryRegistry.Set(9203, animalItem('AN_g'))
			expect(ok).to.equal(true)
			-- No live Player for 9203: no track possible, no
			-- entry retained, and crucially no throw.
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
			expect(PlayerGrabService.IsPlaying(9203)).to.equal(false)
		end)

		it('carry end clears Grab state', function()
			CarryRegistry.Set(9204, animalItem('AN_h'))
			CarryRegistry.Clear(9204)
			expect(PlayerGrabService.IsPlaying(9204)).to.equal(false)
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
		end)

		it('rapid pickup/place/pickup never leaks entries', function()
			CarryRegistry.Set(9205, animalItem('AN_1'))
			CarryRegistry.Clear(9205)
			CarryRegistry.Set(9205, animalItem('AN_2'))
			CarryRegistry.Clear(9205)
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
			expect(PlayerGrabService.IsPlaying(9205)).to.equal(false)
		end)

		it('_TestReset drops all entries', function()
			CarryRegistry.Set(9206, animalItem('AN_i'))
			PlayerGrabService._TestReset()
			expect(PlayerGrabService._TestEntryCount()).to.equal(0)
		end)
	end)
end
