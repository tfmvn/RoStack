--!strict
--!native
--[[
	CarryRegistry.spec
	==================
	Phase 2: CarryRegistry is the single source of truth for
	"what is this player carrying". Both EggService and
	AnimalService consume it instead of each carrying their own
	bookkeeping.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('CarryRegistry', function()
		beforeEach(function()
			Helpers.StubRemotes()
			CarryRegistry.Init()
		end)

		it('Set records a CarriedItem; Get returns it', function()
			local record = { uniqueId = 'X1' }
			local ok, err = CarryRegistry.Set(100, {
				kind = SlotType.OccupantKind.Egg,
				record = record,
				originalSlotId = 'p7:100:slot:1',
				startedAt = 0,
			})
			expect(ok).to.equal(true)
			expect(err).to.equal(nil)
			local item = CarryRegistry.Get(100)
			expect(item).to.be.ok()
			expect(item.kind).to.equal(SlotType.OccupantKind.Egg)
			expect(item.record).to.equal(record)
			expect(item.originalSlotId).to.equal('p7:100:slot:1')
		end)

		it('Set fails when the player is already carrying', function()
			CarryRegistry.Set(101, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:101:slot:1',
				startedAt = 0,
			})
			local ok, err = CarryRegistry.Set(101, {
				kind = SlotType.OccupantKind.Animal,
				record = {},
				originalSlotId = 'p7:101:slot:2',
				startedAt = 0,
			})
			expect(ok).to.equal(false)
			expect(err).to.equal(CarryRegistry.Error.PlayerAlreadyCarrying)
		end)

		it('IsCarrying flips false -> true -> false across Set/Clear', function()
			expect(CarryRegistry.IsCarrying(102)).to.equal(false)
			CarryRegistry.Set(102, {
				kind = SlotType.OccupantKind.Animal,
				record = {},
				originalSlotId = 'p7:102:slot:1',
				startedAt = 0,
			})
			expect(CarryRegistry.IsCarrying(102)).to.equal(true)
			CarryRegistry.Clear(102)
			expect(CarryRegistry.IsCarrying(102)).to.equal(false)
		end)

		it('Clear on a non-carrying player returns NotCarrying', function()
			local item, err = CarryRegistry.Clear(103)
			expect(item).to.equal(nil)
			expect(err).to.equal(CarryRegistry.Error.NotCarrying)
		end)

		it('GetKind returns the kind or nil', function()
			expect(CarryRegistry.GetKind(104)).to.equal(nil)
			CarryRegistry.Set(104, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:104:slot:1',
				startedAt = 0,
			})
			expect(CarryRegistry.GetKind(104)).to.equal(SlotType.OccupantKind.Egg)
		end)

		it('Snapshot returns Kind/Name or both nil when not carrying', function()
			local snap = CarryRegistry.Snapshot(105)
			expect(snap).to.be.a('table')
			expect(snap.Kind).to.equal(nil)
			expect(snap.Name).to.equal(nil)
			expect(snap.Steal).to.equal(nil)
		end)

		it('Snapshot flags steal carries for thief prompt suppression', function()
			CarryRegistry.Set(106, {
				kind = SlotType.OccupantKind.Egg,
				record = { rarity = 'Common' },
				originalSlotId = 'p7:106:slot:1',
				startedAt = 0,
			})
			local plain = CarryRegistry.Snapshot(106)
			expect(plain.Steal).to.equal(false)
			expect(plain.Name).to.equal('Common')
			CarryRegistry.Clear(106)
			CarryRegistry.Set(107, {
				kind = SlotType.OccupantKind.Animal,
				record = { displayName = 'Chicken' },
				originalSlotId = 'p7:107:slot:1',
				startedAt = 0,
				steal = { originalOwnerUserId = 108, originalBaseId = 'Base_1' },
			})
			local stolen = CarryRegistry.Snapshot(107)
			expect(stolen.Steal).to.equal(true)
			expect(stolen.Name).to.equal('Chicken')
			CarryRegistry.Clear(107)
		end)

		it('ForEach iterates all current carries', function()
			CarryRegistry.Set(110, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:110:slot:1',
				startedAt = 0,
			})
			CarryRegistry.Set(111, {
				kind = SlotType.OccupantKind.Animal,
				record = {},
				originalSlotId = 'p7:111:slot:1',
				startedAt = 0,
			})
			local seen = {}
			CarryRegistry.ForEach(function(userId, item)
				seen[userId] = item.kind
			end)
			expect(seen[110]).to.equal(SlotType.OccupantKind.Egg)
			expect(seen[111]).to.equal(SlotType.OccupantKind.Animal)
		end)

		it('Init clears the registry', function()
			CarryRegistry.Set(120, {
				kind = SlotType.OccupantKind.Egg,
				record = {},
				originalSlotId = 'p7:120:slot:1',
				startedAt = 0,
			})
			CarryRegistry.Init()
			expect(CarryRegistry.IsCarrying(120)).to.equal(false)
		end)
	end)
end
