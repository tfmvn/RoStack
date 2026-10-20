--!strict
--!native
--[[
	UnifiedSlot.spec
	================
	Phase 2: a single 6-slot pool per base. Egg and
	Animal share the same Slots[1..6]. This spec asserts the
	state machine end-to-end:

	  * Empty -> Reserved -> Occupied (purchase / open)
	  * Occupied -> Reserved (Demote on grab)
	  * Reserved -> Occupied (place-original)
	  * Reserved -> Empty + Empty -> Reserved -> Occupied (place-different)
	  * In-place open: the egg's slot becomes the animal's slot
	  * 6/6 full returns nil on GetFreeSlot
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('Unified slot state machine', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		local function freshBase()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local b = services.BaseService.AssignBaseForPlayer(7000)
			expect(b).to.be.ok()
			return services, b
		end

		it('every base has exactly SlotCount unified slots', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			for _, b in pairs(services.BaseService.GetAllBases()) do
				expect(#b.slots).to.equal(Bases.Slots.Count)
				-- No more dual pools.
				expect(b.luckyBlockSlots).to.equal(nil)
				expect(b.animalSlots).to.equal(nil)
			end
		end)

		it('Empty -> Reserved -> Occupied -> Empty round-trips', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local b = services.BaseService.AssignBaseForPlayer(7001)
			local slot = b.slots[1]
			expect(slot.state).to.equal('Empty')
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Reserved')
			expect(services.BaseService.OccupySlot(slot.id, 'OCC', SlotType.OccupantKind.Egg)).to.equal(true)
			expect(slot.state).to.equal('Occupied')
			expect(slot.occupantId).to.equal('OCC')
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Egg)
			expect(services.BaseService.ReleaseSlot(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Empty')
		end)

		it('Demote (Occupied -> Reserved) preserves occupantId for grab/place', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7002)
			local slot = services.BaseService.GetFreeSlot(7002)
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'BR1', SlotType.OccupantKind.Animal)
			expect(services.BaseService.DemoteSlotToReserved(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Reserved')
			expect(slot.occupantId).to.equal('BR1')
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Animal)
		end)

		it('Place-to-original: Reserved -> Occupied, no separate acquire', function()
			-- Models a player who grabbed an Egg (slot was
			-- demoted to Reserved) and walks back to the same slot.
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7003)
			local slot = services.BaseService.GetFreeSlot(7003)
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'LB1', SlotType.OccupantKind.Egg)
			services.BaseService.DemoteSlotToReserved(slot.id)
			-- Player walks back; reserve + occupy.
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			expect(services.BaseService.OccupySlot(slot.id, 'LB1', SlotType.OccupantKind.Egg)).to.equal(true)
			expect(slot.state).to.equal('Occupied')
		end)

		it('Place-to-different: release source + acquire dest', function()
			-- Models a player who grabbed an Egg from
			-- slot 1 and places it in slot 4.
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7004)
			local source = services.BaseService.GetFreeSlot(7004)
			services.BaseService.ReserveSlot(source.id)
			services.BaseService.OccupySlot(source.id, 'LB2', SlotType.OccupantKind.Egg)
			services.BaseService.DemoteSlotToReserved(source.id)
			-- Place to a different free slot.
			local b = services.BaseService.GetBaseByOwner(7004)
			local dest = b.slots[4]
			expect(dest.state).to.equal('Empty')
			expect(services.BaseService.ReleaseSlot(source.id)).to.equal(true)
			expect(source.state).to.equal('Empty')
			expect(services.BaseService.ReserveSlot(dest.id)).to.equal(true)
			expect(services.BaseService.OccupySlot(dest.id, 'LB2', SlotType.OccupantKind.Egg)).to.equal(true)
			expect(dest.occupantId).to.equal('LB2')
		end)

		it('In-place open: an Egg and a rolled Animal share the slot', function()
			-- The whole point of the rework: the egg sits in
			-- slot N, the player opens it, the egg is gone, and
			-- the resulting animal occupies slot N.
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7005)
			local b = services.BaseService.GetBaseByOwner(7005)
			local slot = b.slots[3]
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'LB3', SlotType.OccupantKind.Egg)
			-- Open sequence.
			expect(services.BaseService.DemoteSlotToReserved(slot.id)).to.equal(true)
			-- RollController produces an animal; it lands here.
			services.BaseService.OccupySlot(slot.id, 'BR3', SlotType.OccupantKind.Animal)
			expect(slot.state).to.equal('Occupied')
			expect(slot.occupantId).to.equal('BR3')
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Animal)
		end)

		it('RefundHatch leaves the slot Occupied with the original egg', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7006)
			local b = services.BaseService.GetBaseByOwner(7006)
			local slot = b.slots[2]
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'LB4', SlotType.OccupantKind.Egg)
			services.BaseService.DemoteSlotToReserved(slot.id)
			-- Roll failed; RefundHatch re-occupies with the egg.
			services.BaseService.OccupySlot(slot.id, 'LB4', SlotType.OccupantKind.Egg)
			expect(slot.state).to.equal('Occupied')
			expect(slot.occupantId).to.equal('LB4')
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Egg)
		end)

		it('6/6 full: GetFreeSlot returns nil', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7007)
			for i = 1, Bases.Slots.Count do
				local slot = services.BaseService.GetFreeSlot(7007)
				expect(slot).to.be.ok()
				services.BaseService.ReserveSlot(slot.id)
				services.BaseService.OccupySlot(slot.id, 'OCC' .. tostring(i), SlotType.OccupantKind.Egg)
			end
			expect(services.BaseService.GetFreeSlot(7007)).to.equal(nil)
		end)

		it('Mixed kinds across the same 6 slots: alternating LB / BR / Empty', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(7008)
			local b = services.BaseService.GetBaseByOwner(7008)
			-- 1: LB, 2: BR, 3: empty, 4: LB, 5: empty, 6: BR
			local layout = {
				{ id = 'L1', kind = SlotType.OccupantKind.Egg },
				{ id = 'B1', kind = SlotType.OccupantKind.Animal },
				nil,
				{ id = 'L2', kind = SlotType.OccupantKind.Egg },
				nil,
				{ id = 'B2', kind = SlotType.OccupantKind.Animal },
			}
			for i, e in ipairs(layout) do
				if e then
					services.BaseService.ReserveSlot(b.slots[i].id)
					services.BaseService.OccupySlot(b.slots[i].id, e.id, e.kind)
				end
			end
			local snap = services.BaseService.Snapshot(7008)
			expect(snap._occupiedCount).to.equal(4)
			expect(snap.slots[1].OccupantKind).to.equal('egg')
			expect(snap.slots[2].OccupantKind).to.equal('animal')
			expect(snap.slots[3].State).to.equal('Empty')
			expect(snap.slots[4].OccupantKind).to.equal('egg')
			expect(snap.slots[5].State).to.equal('Empty')
			expect(snap.slots[6].OccupantKind).to.equal('animal')
		end)
	end)
end
