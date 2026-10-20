--!strict
--!native
--[[
	CollectorArrival.spec
	=====================
	Tests the three REQ-015 arrival tiers and the surrounding
	contract:

  * The landing CFrame is the slot's SEATED CFrame
    (GroundedCFrameOnSlot), so a placed egg sits bottom-flush
    on the slot's top surface (zero gap — same relationship
    as an Animal on its stand), in the slot's rotation. This
    is the single source of truth for "where an egg rests",
    and the arrival path must not re-derive it.
	  * Tier 1: the launch-time reservation is still Reserved.
	    The egg lands there, the slot is Occupied, and the
	    persistence record is unchanged.
	  * Tier 2: the reservation is gone, but another slot is
	    free. The egg lands on a free slot, the SAME
	    persistence record is re-pointed to it (identity
	    preserved — never Remove+Add), and egg.slotId is
	    updated.
	  * Tier 3: no free slot. The egg is refunded, its
	    persistence record is REMOVED (no phantom egg on
	    rejoin), destroyed, removed from the spawn registry,
	    and no slot is left Reserved. The egg is NEVER
	    left orphaned over the Collector.
	  * The owner is resolved from egg.ownerUserId, with the
	    slot id parse as a fallback.
	  * When OccupySlot fails after a successful resolve, the
	    egg stays in Traveling (not Placed), so
	    ForceReleaseBase can still clean it up.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Helpers = require(ServerScriptService.TestEZTests._Helpers)
	local CollectorArrival = require(ServerScriptService['Base'].CollectorArrival)
	local HoverMath = require(ServerScriptService['Egg'].HoverMath)
	local SpawnService = require(ServerScriptService['Egg'].SpawnService)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	-- Spin up a clean registry + a base assigned to userId.
	-- Returns the wired services and the user's base record.
	local function setup(userId: number): (any, any)
		Helpers.StubRemotes()
		local services = Helpers.WireServices()
		Helpers.EnsureCollectors()
		services.BaseService.RegisterBases(game:GetService('Workspace'))
		services.EggService.RegisterCenter(game:GetService('Workspace'))
		-- Drain any leftover eggs.
		for _, b in ipairs(SpawnService.AllEggs()) do
			if b.model then
				b.model:Destroy()
			end
			SpawnService.DropEgg(b.uniqueId)
		end
		local base = services.BaseService.AssignBaseById(userId, 'Base_1')
		expect(base).to.be.ok()
		return services, base
	end

	-- Build a fake egg record the way SpawnService would
	-- shape it: model is a real Instance, state is Traveling,
	-- _refs points at the real services so the arrival path's
	-- refunds, occupancy and prompt install hit production
	-- code. `capturedOnArrived` records whether and how the
	-- consumer hook fired.
	local function fakeBlock(services: any, userId: number, rarity: string, price: number): any
		local r = SpawnService.Request({
			definition = { rarity = rarity, price = price },
			origin = 'Test',
		})
		expect(r.success).to.equal(true)
		local egg = r.egg
		egg.ownerUserId = userId
		egg.state = 'Traveling' -- matches Constants.State.Traveling
		egg._onArrived = function(_b, _slot, _slotId)
			-- consumer hook, no-op in these tests
		end
		return egg
	end

	-- Drain the spawn registry between tests.
	local function clearRegistry()
		for _, b in ipairs(SpawnService.AllEggs()) do
			if b.model then
				b.model:Destroy()
			end
			SpawnService.DropEgg(b.uniqueId)
		end
	end

	-- Phase 2.5.1: a faithful fake of the PlayerService
	-- persistence surface the arrival path touches, backed by
	-- real in-memory record lists (same shapes as profile.Data)
	-- so persistence assertions are STATE-based (one record,
	-- same Id, right SlotId) rather than call-based. The real
	-- PlayerService can't be used here because no profile is
	-- loaded in the test session.
	local function makeFakePlayerService()
		local svc = { Brainrots = {}, LuckyBlocks = {} }
		local function findIdxById(list, id)
			for i = 1, #list do
				if list[i].Id == id then
					return i
				end
			end
			return nil
		end
		function svc.AddEgg(_userId, slotId, rarity, id)
			svc.LuckyBlocks[#svc.LuckyBlocks + 1] = { SlotId = slotId, Rarity = rarity, Id = id }
			return true
		end
		function svc.SetEggSlot(_userId, id, newSlotId)
			local idx = findIdxById(svc.LuckyBlocks, id)
			if not idx then
				return false
			end
			svc.LuckyBlocks[idx].SlotId = newSlotId
			return true
		end
		function svc.RemoveEgg(_userId, id)
			local idx = findIdxById(svc.LuckyBlocks, id)
			if not idx then
				return false
			end
			table.remove(svc.LuckyBlocks, idx)
			return true
		end
		function svc.RemoveEggAtSlot(_userId, slotId)
			for i = 1, #svc.LuckyBlocks do
				if svc.LuckyBlocks[i].SlotId == slotId then
					table.remove(svc.LuckyBlocks, i)
					return true
				end
			end
			return false
		end
		return svc
	end

	-- Swap the fake playerService into the egg's _refs (the
	-- other services stay real so slot mechanics run production
	-- code).
	local function withFakePlayerService(egg: any, fake: any)
		local refs = table.clone(egg._refs)
		refs.playerService = fake
		egg._refs = refs
	end

	describe('landing CFrame', function()
		it('lands on the slot seated CFrame (bottom flush, slot rotation preserved)', function()
			local userId = 7001
			local services, _ = setup(userId)
			local egg = fakeBlock(services, userId, 'Common', 100)

			-- Reserve any free slot, then run the arrival.
			local slot = services.BaseService.GetFreeSlot(userId)
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			egg.slotId = slot.id

			local ok = CollectorArrival.OnArrival(egg, egg._refs)
			expect(ok).to.equal(true)

			-- The model pivot equals the slot's seated CFrame.
			local expectedCF = HoverMath.GroundedCFrameOnSlot(slot, egg.model)
			local pos = egg.model:GetPivot().Position
			expect(Vector3.new(pos.X, pos.Y, pos.Z)).to.be.near(expectedCF.Position, 0.0001)
			-- The bottom face sits flush on the slot's top
			-- surface (zero gap — seated like an Animal).
			local bottomY = pos.Y - HoverMath.GroundOffset(egg.model)
			expect(bottomY - HoverMath.SlotFloorY(slot)).to.be.near(0, 0.0001)
		end)
	end)

	describe('Tier 1 — reservation intact', function()
		it('lands on the reserved slot and leaves persistence alone', function()
			local userId = 7101
			local services, _ = setup(userId)
			local egg = fakeBlock(services, userId, 'Common', 100)
			local slot = services.BaseService.GetFreeSlot(userId)
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			egg.slotId = slot.id
			-- Stash the id so we can confirm it does NOT change.
			local originalSlotId = slot.id

			local fired
			egg._onArrived = function(_b, _slot, _slotId)
				fired = _slot
			end
			local ok = CollectorArrival.OnArrival(egg, egg._refs)
			expect(ok).to.equal(true)

			-- Slot is now Occupied, with the egg's uniqueId.
			local refound = services.BaseService._findSlotById(originalSlotId)
			expect(refound.state).to.equal(SlotType.State.Occupied)
			expect(refound.occupantId).to.equal(egg.uniqueId)
			expect(refound.occupantKind).to.equal(SlotType.OccupantKind.Egg)

			-- The egg is Placed and `_onArrived` fired with that
			-- slot.
			expect(egg.state).to.equal('Placed')
			expect(egg.slotId).to.equal(originalSlotId)
			expect(fired).to.equal(refound)
		end)
	end)

	describe('Tier 2 — reservation gone, another slot free', function()
		it('lands on a different free slot and re-points the SAME persistence record (identity preserved)', function()
			local userId = 7201
			local services, _ = setup(userId)
			local egg = fakeBlock(services, userId, 'Common', 100)

			-- Reserve slot A as the launch-time reservation, but
			-- release it before arrival (simulating
			-- `ReleaseReservedSlotForUser` from an admin command
			-- or a sold-out rebalance). Slot B will be picked
			-- instead.
			local slotA = services.BaseService.GetFreeSlot(userId)
			expect(services.BaseService.ReserveSlot(slotA.id)).to.equal(true)
			egg.slotId = slotA.id
			expect(services.BaseService.ReleaseSlot(slotA.id)).to.equal(true)
			-- Slot B is still free.
			local slotB = services.BaseService.GetFreeSlot(userId)
			expect(slotB).to.be.ok()
			expect(slotB.id).never.to.equal(slotA.id)

			-- Phase 2.5.1: state-based persistence contract. The
			-- record starts at slot A under the egg's OWN Id
			-- (exactly what Purchase persists); after arrival
			-- there must still be exactly ONE record, with the
			-- SAME Id, re-pointed to the landing slot. The
			-- pre-2.5.1 Remove+Add contract (which minted a new
			-- Id and left the stale record behind as a phantom)
			-- fails both assertions.
			local fakePlayerService = makeFakePlayerService()
			fakePlayerService.AddEgg(userId, slotA.id, 'Common', egg.uniqueId)
			expect(#fakePlayerService.LuckyBlocks).to.equal(1)
			withFakePlayerService(egg, fakePlayerService)

			local ok = CollectorArrival.OnArrival(egg, egg._refs)

			expect(ok).to.equal(true)
			expect(#fakePlayerService.LuckyBlocks).to.equal(1)
			local record = fakePlayerService.LuckyBlocks[1]
			expect(record.Id).to.equal(egg.uniqueId)
			expect(record.SlotId).to.equal(slotB.id)
			expect(record.Rarity).to.equal('Common')
			-- The egg's slotId is now the new one.
			expect(egg.slotId).to.equal(slotB.id)
			-- The old slot is still Empty (the reservation was
			-- released before arrival, nothing re-reserved it).
			local reA = services.BaseService._findSlotById(slotA.id)
			expect(reA.state).to.equal(SlotType.State.Empty)
		end)
	end)

	describe('Tier 3 — no free slot', function()
		it(
			'refunds the cash, releases the stale reservation, destroys the model, and drops the egg from the registry',
			function()
				local userId = 7301
				local services, _ = setup(userId)
				local egg = fakeBlock(services, userId, 'Common', 100)

				-- Reserve a slot, then OCCUPY every other slot in
				-- the base so tier 2 has nothing free.
				local reserved = services.BaseService.GetFreeSlot(userId)
				expect(services.BaseService.ReserveSlot(reserved.id)).to.equal(true)
				egg.slotId = reserved.id
				-- Phase 2.5.1: the refund must ALSO remove the
				-- persisted record — pre-2.5.1 the record survived
				-- and respawned as a free phantom egg on rejoin.
				local fakePlayerService = makeFakePlayerService()
				fakePlayerService.AddEgg(userId, reserved.id, 'Common', egg.uniqueId)
				withFakePlayerService(egg, fakePlayerService)
				for n, slot in pairs(services.BaseService.GetBaseById('Base_1').slots) do
					if slot.id ~= reserved.id then
						-- Manually flip to Occupied for this test
						-- (ReserveSlot + OccupySlot; the kind is
						-- unimportant for the bail-out path).
						expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
						expect(services.BaseService.OccupySlot(slot.id, 'test-occupant-' .. tostring(n))).to.equal(true)
					end
				end

				-- Spy on the money refund and the slot release.
				-- Phase 2.1: EconomyService.AddMoney is the new
				-- refund surface; the call takes a BigNumber
				-- string, not a number.
				local refundSeen: { [string]: boolean } = {}
				local releaseSeen: { [string]: boolean } = {}
				local EconomyService = require(game:GetService('ServerScriptService').EconomyService)
				local origAddMoney = EconomyService.AddMoney
				local slotService = services.BaseService
				local origRelease = slotService.ReleaseSlot
				EconomyService.AddMoney = function(_u, amount, reason)
					refundSeen[amount] = true
					return origAddMoney(_u, amount, reason)
				end
				slotService.ReleaseSlot = function(slotId)
					releaseSeen[slotId] = true
					return origRelease(slotId)
				end

				-- Capture a reference to the model so we can prove
				-- it was destroyed.
				local model = egg.model
				local uniqueId = egg.uniqueId

				local ok = CollectorArrival.OnArrival(egg, egg._refs)

				EconomyService.AddMoney = origAddMoney
				slotService.ReleaseSlot = origRelease

				-- Arrival returned false (the egg did not land).
				expect(ok).to.equal(false)
				-- The persisted record is gone (no phantom).
				expect(#fakePlayerService.LuckyBlocks).to.equal(0)
				-- The egg was refunded at its full price
				-- (canonical BigNumber string).
				expect(refundSeen['100']).to.equal(true)
				-- The stale reservation was released.
				expect(releaseSeen[reserved.id]).to.equal(true)
				-- The model was destroyed.
				expect(model.Parent).to.equal(nil)
				-- The egg is no longer in the spawn registry.
				expect(SpawnService.GetEgg(uniqueId)).to.equal(nil)
				-- The slot is back to Empty (not stuck Reserved).
				local reread = services.BaseService._findSlotById(reserved.id)
				expect(reread.state).to.equal(SlotType.State.Empty)
			end
		)
	end)

	describe('owner resolution', function()
		it('falls back to SlotType.ParseId(egg.slotId).userId when ownerUserId is missing', function()
			local userId = 7401
			local services, _ = setup(userId)
			local egg = fakeBlock(services, userId, 'Common', 100)
			egg.ownerUserId = nil -- simulate the missing stamp
			-- But egg.slotId has the userId encoded.
			local slot = services.BaseService.GetFreeSlot(userId)
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			egg.slotId = slot.id

			local ok = CollectorArrival.OnArrival(egg, egg._refs)
			-- The owner was resolved from the slotId; arrival
			-- succeeded.
			expect(ok).to.equal(true)
			expect(egg.state).to.equal('Placed')
		end)
	end)

	describe('OccupySlot race', function()
		it('leaves the egg Traveling (not Placed) when OccupySlot fails after a successful resolve', function()
			local userId = 7501
			local services, _ = setup(userId)
			local egg = fakeBlock(services, userId, 'Common', 100)

			local slot = services.BaseService.GetFreeSlot(userId)
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			egg.slotId = slot.id

			-- Spy: make OccupySlot return false (the slot changed
			-- under us between resolve and occupy).
			local slotService = services.BaseService
			local origOccupy = slotService.OccupySlot
			slotService.OccupySlot = function(_id, _uid, _kind)
				return false
			end

			-- Spy on _onArrived: must NOT fire.
			local fired = false
			egg._onArrived = function()
				fired = true
			end

			local ok = CollectorArrival.OnArrival(egg, egg._refs)

			slotService.OccupySlot = origOccupy

			expect(ok).to.equal(false)
			expect(egg.state).to.equal('Traveling') -- not Placed
			expect(fired).to.equal(false)
		end)
	end)
end
