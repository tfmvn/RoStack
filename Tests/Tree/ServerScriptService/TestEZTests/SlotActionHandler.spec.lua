--!strict
--!native
--[[
	SlotActionHandler.spec
	======================
	Phase 2.1: server-side dispatch for the custom slot action
	menu. The handler validates an inbound request and routes
	it to the right service. We test the validation surfaces
	here (the per-service grab/place/open is already covered
	by the existing service specs).
]]

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

local Helpers = require(script.Parent._Helpers)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local SlotActionHandler = require(ServerScriptService.Action.SlotActionHandler)

return function()
	beforeEach(function()
		Helpers.StubRemotes()
	end)

	describe('SlotActionHandler', function()
		local services
		beforeEach(function()
			services = Helpers.WireServices()
			-- Pre-assign a base to user 1001 so slot lookups
			-- have a real owner to test against.
			Helpers.RegisterBasesForTest(services, 1001)
		end)

		describe('input validation', function()
			it('rejects non-table request', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local r = SlotActionHandler.Handle(p, 'not-a-table')
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
			end)

			it('rejects missing action', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local r = SlotActionHandler.Handle(p, { SlotId = 'p7:1001:slot:1' })
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
			end)

			it('rejects missing slot id', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local r = SlotActionHandler.Handle(p, { Action = 'Pickup' })
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
			end)

			it('rejects unknown slot', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local r = SlotActionHandler.Handle(p, { Action = 'Pickup', SlotId = 'p7:1001:slot:99' })
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidSlot)
			end)
		end)

		describe('ownership', function()
			it("rejects action on another player's base", function()
				Helpers.RegisterBasesForTest(services, 2002)
				local p2 = Helpers.FakePlayer(2002, 'B')
				-- Use a slot id that exists (on player A's
				-- base) but the requesting player is B.
				local ownerA_base = services.BaseService.GetPlayerBase(1001)
				expect(ownerA_base).to.be.ok()
				local slotA = ownerA_base.slots[1]
				local r = SlotActionHandler.Handle(p2, {
					Action = 'Pickup',
					SlotId = slotA.id,
					OccupantId = slotA.occupantId,
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.NotOwner)
			end)
		end)

		describe('action allowlist', function()
			it('rejects action not in Actions table for empty slot when not carrying', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				local slot = base.slots[1]
				expect(slot.state).to.equal(SlotType.State.Empty)
				-- Pickup is not in the Empty action list.
				local r = SlotActionHandler.Handle(p, {
					Action = 'Pickup',
					SlotId = slot.id,
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
			end)

			it('rejects Hatch on an animal slot', function()
				-- Need an animal in a slot. This is a
				-- lightweight integration test; we don't
				-- need the full open-in-place flow, just
				-- the kind-discriminator in the action
				-- allowlist.
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				-- Simulate an animal on slot 1.
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'fake-animal-1'
				local r = SlotActionHandler.Handle(p, {
					Action = 'Hatch',
					SlotId = base.slots[1].id,
					OccupantId = 'fake-animal-1',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.WrongKind)
			end)
		end)

		describe('Sell', function()
			it('returns NotImplemented for Sell (future economy)', function()
				-- Make a slot look Egg Occupied.
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Egg
				base.slots[1].occupantId = 'fake-egg-1'
				local r = SlotActionHandler.Handle(p, {
					Action = 'Sell',
					SlotId = base.slots[1].id,
					OccupantId = 'fake-egg-1',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.NotImplemented)
			end)
		end)

		describe('carry-gate', function()
			it('rejects Place when player is not carrying', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				-- Empty slot — Place is the action, but we
				-- aren't carrying anything.
				local r = SlotActionHandler.Handle(p, {
					Action = 'Place',
					SlotId = base.slots[1].id,
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.NotCarrying)
			end)
		end)

		describe('occupant mismatch', function()
			it('rejects Pickup with wrong occupant id', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'real-id'
				local r = SlotActionHandler.Handle(p, {
					Action = 'Pickup',
					SlotId = base.slots[1].id,
					OccupantId = 'fake-id',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.NotOccupant)
			end)
		end)

		describe('Pick/Place hold + single-flight guard', function()
			it('pins the authoritative Pick/Place hold duration to 1 second', function()
				local Prompts = require(ReplicatedStorage.Config.World.Prompts)
				expect(Prompts.CarryHoldDuration).to.equal(1)
			end)

			it('releases the guard after a failed Place (sequential calls never stick at in-progress)', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				local req = {
					Action = 'Place',
					SlotId = base.slots[1].id,
				}
				local r1 = SlotActionHandler.Handle(p, req)
				expect(r1.success).to.equal(false)
				expect(r1.error).to.equal(SlotActionHandler.Error.NotCarrying)
				-- A second identical call must reach the same
				-- verdict, not a stuck single-flight rejection.
				local r2 = SlotActionHandler.Handle(p, req)
				expect(r2.success).to.equal(false)
				expect(r2.error).to.equal(SlotActionHandler.Error.NotCarrying)
			end)

			it('releases the guard after a failed Pickup (stale occupant)', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'real-id'
				local req = {
					Action = 'Pickup',
					SlotId = base.slots[1].id,
					OccupantId = 'stale-id',
				}
				local r1 = SlotActionHandler.Handle(p, req)
				expect(r1.success).to.equal(false)
				expect(r1.error).to.equal(SlotActionHandler.Error.NotOccupant)
				local r2 = SlotActionHandler.Handle(p, req)
				expect(r2.success).to.equal(false)
				expect(r2.error).to.equal(SlotActionHandler.Error.NotOccupant)
				base.slots[1].state = SlotType.State.Empty
				base.slots[1].occupantKind = nil
				base.slots[1].occupantId = nil
			end)
		end)

		describe('SellAnimal routing; SellEgg has no path', function()
			local function restore(slot: any)
				slot.state = SlotType.State.Empty
				slot.occupantKind = nil
				slot.occupantId = nil
			end

			it('rejects SellAnimal on an empty slot (not in the allowlist)', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				restore(base.slots[1])
				local r = SlotActionHandler.Handle(p, {
					Action = 'SellAnimal',
					SlotId = base.slots[1].id,
					OccupantId = 'whatever',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
			end)

			it('rejects SellAnimal with a mismatched occupant', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'real-animal'
				local r = SlotActionHandler.Handle(p, {
					Action = 'SellAnimal',
					SlotId = base.slots[1].id,
					OccupantId = 'stale-animal',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.NotOccupant)
				restore(base.slots[1])
			end)

			it('rejects SellEgg everywhere: no action, no path, even for eggs', function()
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				-- Egg slot, matching occupant: still rejected at
				-- the allowlist (eggs are not sellable).
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Egg
				base.slots[1].occupantId = 'real-egg'
				local r = SlotActionHandler.Handle(p, {
					Action = 'SellEgg',
					SlotId = base.slots[1].id,
					OccupantId = 'real-egg',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.InvalidAction)
				-- Animal slot: likewise rejected (not WrongKind —
				-- the action itself does not exist).
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'real-animal'
				local r2 = SlotActionHandler.Handle(p, {
					Action = 'SellEgg',
					SlotId = base.slots[1].id,
					OccupantId = 'real-animal',
				})
				expect(r2.success).to.equal(false)
				expect(r2.error).to.equal(SlotActionHandler.Error.InvalidAction)
				restore(base.slots[1])
			end)

			it('routes a matching SellAnimal to the service layer', function()
				-- No animal record exists for 'fake-animal-2', so the
				-- live SellService answers 'not-found' — which the
				-- handler normalises to ServiceError. Reaching
				-- ServiceError (and not InvalidAction/WrongKind/
				-- NotImplemented) proves the dispatch path.
				local p = Helpers.FakePlayer(1001, 'A')
				local base = services.BaseService.GetPlayerBase(1001)
				base.slots[1].state = SlotType.State.Occupied
				base.slots[1].occupantKind = SlotType.OccupantKind.Animal
				base.slots[1].occupantId = 'fake-animal-2'
				local r = SlotActionHandler.Handle(p, {
					Action = 'SellAnimal',
					SlotId = base.slots[1].id,
					OccupantId = 'fake-animal-2',
				})
				expect(r.success).to.equal(false)
				expect(r.error).to.equal(SlotActionHandler.Error.ServiceError)
				restore(base.slots[1])
			end)
		end)
	end)
end
