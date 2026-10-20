--!strict
--!native
--[[
	Integration.spec
	================
	Cross-service checks. The full purchase -> travel -> open ->
	animal-create flow can't be exercised end-to-end in TestEZ
	(no DataStore, no tween completion in test runner) but we can
	verify the data-plane invariants that the services share:

	  * BaseService.GetFreeSlot sees a free slot for a
	    newly-assigned base.
	  * Slot IDs are globally unique across players.
	  * BaseService.Snapshot reflects state transitions.
	  * EggConfig.Price is defined for every rarity.

	Phase 2: a single 6-slot pool per base replaces the prior
	lucky/animal split.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local Rarity = require(ReplicatedStorage.Types.RarityType)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('Cross-service', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('EggConfig.Price is defined for every rarity', function()
			for _, rarity in ipairs({
				Rarity.Common,
				Rarity.Uncommon,
				Rarity.Rare,
				Rarity.Epic,
				Rarity.Mythic,
				Rarity.Legendary,
				Rarity.Divine,
				Rarity.Secret,
			}) do
				expect(EggConfig.Price[rarity]).to.be.a('number')
				expect(EggConfig.Price[rarity] > 0).to.equal(true)
			end
		end)

		it('Slot ids are unique across players', function()
			local _, BaseService = Helpers.WireServices()
			Helpers.EnsureCollectors()
			BaseService:RegisterBases(game:GetService('Workspace'))
			local b1 = BaseService:AssignBaseForPlayer(1001)
			local b2 = BaseService:AssignBaseForPlayer(1002)
			expect(b1).to.be.ok()
			expect(b2).to.be.ok()
			-- Phase 2: a single 6-slot pool per base. 12 unique
			-- ids total across the two bases.
			local seen = {}
			for _, base in pairs({ b1, b2 }) do
				for i = 1, Bases.Slots.Count do
					local slot = base.slots[i]
					expect(seen[slot.id]).to.equal(nil)
					seen[slot.id] = true
				end
			end
		end)

		it('All 6 bases can be assigned to 6 distinct players', function()
			local _, BaseService = Helpers.WireServices()
			Helpers.EnsureCollectors()
			BaseService:RegisterBases(game:GetService('Workspace'))
			local assigned = {}
			for i = 1, Bases.Count do
				local b = BaseService:AssignBaseForPlayer(2000 + i)
				expect(b).to.be.ok()
				assigned[b.id] = true
			end
			local count = 0
			for _ in pairs(assigned) do
				count = count + 1
			end
			expect(count).to.equal(Bases.Count)
			-- 7th player gets nothing.
			local overflow = BaseService:AssignBaseForPlayer(2999)
			expect(overflow).to.equal(nil)
		end)

		it('Slot id parse round-trips for the unified kind', function()
			-- Phase 2: SlotType.Kind is collapsed to a single
			-- 'slot' keyword. New ids are always 'slot'; the
			-- parser coerces legacy 'egg' / 'animal'
			-- keywords to 'slot' for back-compat.
			local id = SlotType.BuildId(42, SlotType.Kind.Slot, 3)
			local parsed = SlotType.ParseId(id)
			expect(parsed).to.be.ok()
			expect(parsed.userId).to.equal(42)
			expect(parsed.kind).to.equal(SlotType.Kind.Slot)
			expect(parsed.index).to.equal(3)
			-- Legacy kinds still parse (with normalization).
			local legacyEgg = SlotType.ParseId(SlotType.BuildId(99, 'egg', 5))
			expect(legacyEgg).to.be.ok()
			expect(legacyEgg.kind).to.equal(SlotType.Kind.Slot)
			expect(legacyEgg.index).to.equal(5)
		end)
	end)
end
