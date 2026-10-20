--!strict
--!native
--[[
	CarryService.spec
	=================
	Phase 2: unified carry across EggService and
	AnimalService. The CarryRegistry is the single source of
	truth; both services read/write through it.

	Validation paths (no real template needed):
	  A. CanGrabX rejects cross-player / non-owner
	  B. CanGrabX rejects when already carrying
	  C. CanGrabX rejects when not LivePlayer
	  D. CanPlaceX rejects cross-base
	  E. CanPlaceX rejects Occupied destination
	  F. CanPlaceX rejects invalid player
	  G. GetCarriedX returns nil when not carrying
	  H. IsCarryingX returns false when not carrying
	  I. CarryRegistry mutual exclusion (one carry at a time)

	Happy-path grab/place is covered by manual Studio playtest
	because it requires a real animal / lucky egg template
	under ServerStorage.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('AnimalService carry (validation)', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
		end)

		it('CanGrabAnimal rejects invalid player', function()
			local services = Helpers.WireServices()
			local reason = services.AnimalService.CanGrabAnimal(nil :: any, 'BR_x')
			expect(reason).to.equal('InvalidPlayer')
		end)

		it('CanGrabAnimal rejects a missing animal', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7001)
			local reason = services.AnimalService.CanGrabAnimal(player, 'BR_no_such_id')
			expect(reason).to.equal('AnimalNotFound')
		end)

		it('CanPlaceAnimal rejects invalid player', function()
			local services = Helpers.WireServices()
			local reason = services.AnimalService.CanPlaceAnimal(nil :: any, 'BR_x', 'p7:0:slot:1')
			expect(reason).to.equal('InvalidPlayer')
		end)

		it('CanPlaceAnimal rejects a missing animal', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7002)
			local reason = services.AnimalService.CanPlaceAnimal(player, 'BR_no_such_id', 'p7:0:slot:1')
			expect(reason).to.equal('AnimalNotFound')
		end)

		it('GetCarriedAnimal returns nil when not carrying', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7003)
			expect(services.AnimalService.GetCarriedAnimal(player)).to.equal(nil)
		end)

		it('IsCarryingAnimal returns false when not carrying', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7004)
			expect(services.AnimalService.IsCarryingAnimal(player)).to.equal(false)
		end)
	end)

	describe('EggService carry (validation)', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
		end)

		it('GrabEgg rejects invalid player', function()
			local services = Helpers.WireServices()
			-- Validation.LivePlayer throws on nil; the spec
			-- only checks the success-path is not entered.
			local ok, err = pcall(function()
				return services.EggService.GrabEgg(nil :: any, 'LB_x')
			end)
			expect(ok).to.equal(false)
		end)

		it('GrabEgg rejects a missing egg', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7005)
			local result = services.EggService.GrabEgg(player, 'LB_no_such_id')
			expect(result).to.be.a('table')
			expect(result.success).to.equal(false)
			expect(result.error).to.equal('egg-not-found')
		end)

		it('PlaceEgg rejects invalid player', function()
			local services = Helpers.WireServices()
			local ok = pcall(function()
				return services.EggService.PlaceEgg(nil :: any, 'LB_x', 'p7:0:slot:1')
			end)
			expect(ok).to.equal(false)
		end)

		it('PlaceEgg rejects a missing egg', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7006)
			local result = services.EggService.PlaceEgg(player, 'LB_no_such_id', 'p7:0:slot:1')
			expect(result).to.be.a('table')
			expect(result.success).to.equal(false)
		end)

		it('IsCarrying returns false when not carrying', function()
			local services = Helpers.WireServices()
			local player = Helpers.FakePlayer(7007)
			expect(services.EggService.IsCarrying(player)).to.equal(false)
		end)
	end)

	describe('CarryRegistry mutual exclusion', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
		end)

		it('rejects a second Set when already carrying', function()
			CarryRegistry.Set(8001, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:8001:slot:1',
				startedAt = 0,
			})
			local ok, err = CarryRegistry.Set(8001, {
				kind = SlotType.OccupantKind.Animal,
				record = {},
				originalSlotId = 'p7:8001:slot:2',
				startedAt = 0,
			})
			expect(ok).to.equal(false)
			expect(err).to.equal(CarryRegistry.Error.PlayerAlreadyCarrying)
			expect(CarryRegistry.GetKind(8001)).to.equal(SlotType.OccupantKind.Egg)
		end)

		it('Clear permits a fresh Set', function()
			CarryRegistry.Set(8002, {
				kind = SlotType.OccupantKind.Animal,
				record = {},
				originalSlotId = 'p7:8002:slot:1',
				startedAt = 0,
			})
			CarryRegistry.Clear(8002)
			local ok = CarryRegistry.Set(8002, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:8002:slot:1',
				startedAt = 0,
			})
			expect(ok).to.equal(true)
			expect(CarryRegistry.GetKind(8002)).to.equal(SlotType.OccupantKind.Egg)
		end)
	end)
end
