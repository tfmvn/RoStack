--!strict
--!native
--[[
	EggContest.spec
	===============
	Traveling-egg contestability (EggService.Purchase contest
	branch): a Traveling egg stays buyable until arrival commits.

	What this spec locks in:
	  A. A second player CAN buy a Traveling egg (success).
	  B. Ownership/slot/profile transfer atomically: new owner
	     stamped, new slot reserved, previous profile row
	     removed, previous slot released — the uniqueId never
	     lives in two profiles at once.
	  C. The owner re-buying their own traveling egg is
	     rejected before any debit (not-available).
	  D. A Placed egg is still unavailable (not-available).
	  E. Exactly one flight generation is launched per transfer
	     (stale paths can never double-drive; asserted via the
	     synchronous _flightGen bump, not the async assign).
	  F. The mutex is released on every path (no stuck egg).

	Staging: a real Persistence-spawned egg flipped to
	Traveling (same record shape Purchase produces), with fake
	ledger/profile refs injected through the production
	setters and restored afterward. Flight assignment itself
	is async (task.spawn + ComputeAsync); the spec asserts the
	synchronous transfer contract, which is this task's scope.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	local A = 9101
	local B = 9102

	local services: any = nil
	local realPlayerService: any = nil
	local realEconomyService: any = nil

	local addedRows: { [number]: { string } } = {}
	local removedRows: { [number]: { string } } = {}
	local spends: { [number]: number } = {}
	local pushes: { [number]: number } = {}

	local function fakePlayerService()
		return {
			GetPlayerData = function(userId: number)
				return { Money = '1000000', LuckyBlocks = {}, Brainrots = {} }
			end,
			AddEgg = function(userId: number, _slotId: string, _rarity: string, id: string, _opts: any)
				local list = addedRows[userId] or {}
				list[#list + 1] = id
				addedRows[userId] = list
				return true
			end,
			RemoveEgg = function(userId: number, id: string)
				local list = removedRows[userId] or {}
				list[#list + 1] = id
				removedRows[userId] = list
				return true
			end,
			PushState = function(player: any, _snap: any)
				local uid = (player :: any).UserId
				pushes[uid] = (pushes[uid] or 0) + 1
			end,
		}
	end

	local function fakeEconomyService()
		return {
			TrySpendMoney = function(userId: number, _amount: string, _reason: any)
				spends[userId] = (spends[userId] or 0) + 1
				return { Success = true }
			end,
			AddMoney = function(_userId: number, _amount: string, _reason: any)
				return { Success = true }
			end,
		}
	end

	local function setup()
		Helpers.StubRemotes()
		local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
		CarryRegistry.Init()
		services = Helpers.WireServices()
		Helpers.EnsureCollectors()
		if not next(services.BaseService.GetAllBases()) then
			services.BaseService.RegisterBases(game:GetService('Workspace'))
		end
		services.EggService.RegisterCenter(game:GetService('Workspace'))
		if not services.BaseService.GetBaseByOwner(A) then
			services.BaseService.AssignBaseById(A, 'Base_1')
		end
		if not services.BaseService.GetBaseByOwner(B) then
			services.BaseService.AssignBaseById(B, 'Base_2')
		end
		expect(services.BaseService.GetBaseByOwner(A)).to.be.ok()
		expect(services.BaseService.GetBaseByOwner(B)).to.be.ok()
		realPlayerService = services.PlayerService
		realEconomyService = require(ServerScriptService.EconomyService)
		addedRows = {}
		removedRows = {}
		spends = {}
		pushes = {}
	end

	local function teardown()
		services.EggService.SetPlayerService(realPlayerService)
		services.EggService.SetEconomyService(realEconomyService)
	end

	-- A real egg record on owner's reserved slot, flipped to
	-- the exact runtime shape a first purchase produces.
	local function stageTravelingEgg(ownerId: number): any
		local SpawnService = require(ServerScriptService.Egg.SpawnService)
		local base = services.BaseService.GetPlayerBase(ownerId)
		expect(base).to.be.ok()
		local slot = services.SlotService.GetFreeSlot(ownerId)
		expect(slot).to.be.ok()
		expect(services.SlotService.ReserveSlot(slot.id)).to.equal(true)
		local r = SpawnService.Request({
			definition = { rarity = 'Common', price = 100 },
			origin = 'Persistence',
			targetSlot = slot,
		})
		expect(r.success).to.equal(true)
		local egg = r.egg
		egg.state = 'Traveling'
		egg.ownerUserId = ownerId
		egg.slotId = slot.id
		egg._mutex = false
		-- Mirror a real first purchase: the center BuyPrompt
		-- survives into travel (contest surface). Persistence
		-- spawn installs Hatch/Pickup instead, so stage it.
		local primary = egg.model and egg.model.PrimaryPart
		if primary and (primary :: BasePart):FindFirstChild('BuyPrompt') == nil then
			local prompt = Instance.new('ProximityPrompt')
			prompt.Name = 'BuyPrompt'
			prompt.MaxActivationDistance = 12
			prompt.Parent = primary
		end
		return egg
	end

	local function cleanupEgg(egg: any)
		local SpawnService = require(ServerScriptService.Egg.SpawnService)
		if egg.controller then
			local FlightController = require(ServerScriptService.Egg.FlightController)
			pcall(FlightController.Stop, egg.controller)
			egg.controller = nil
		end
		if egg.slotId then
			local slot = services.SlotService._findSlotById(egg.slotId)
			if slot and slot.state == SlotType.State.Reserved then
				services.SlotService.ReleaseSlot(egg.slotId)
			end
		end
		if egg.model and egg.model.Parent then
			egg.model:Destroy()
		end
		SpawnService.DropEgg(egg.uniqueId)
	end

	describe('EggContest', function()
		beforeEach(setup)
		afterEach(teardown)

		it('B contests A traveling egg: ownership/slot/profile transfer atomically', function()
			local egg = stageTravelingEgg(A)
			local prevSlotId = egg.slotId
			services.EggService.SetPlayerService(fakePlayerService())
			services.EggService.SetEconomyService(fakeEconomyService())
			local fakeB = Helpers.FakePlayer(B, 'Bee')
			local r = services.EggService.Purchase(fakeB, egg.uniqueId)
			expect(r.success).to.equal(true)
			-- New owner stamped, state stays Traveling.
			expect(egg.ownerUserId).to.equal(B)
			expect(egg.state).to.equal('Traveling')
			-- New slot reserved for B (not A's slot).
			expect(egg.slotId ~= prevSlotId).to.equal(true)
			local newSlot = services.SlotService._findSlotById(egg.slotId)
			expect(newSlot.state).to.equal(SlotType.State.Reserved)
			-- A's hold released, A's profile row removed: the
			-- identity never lives twice.
			local prevSlot = services.SlotService._findSlotById(prevSlotId)
			expect(prevSlot.state).to.equal(SlotType.State.Empty)
			expect(#(removedRows[A] or {})).to.equal(1)
			expect((removedRows[A] or {})[1]).to.equal(egg.uniqueId)
			expect(#(addedRows[B] or {})).to.equal(1)
			-- B debited exactly once; mutex released; one
			-- flight generation launched (stale A path killed).
			expect(spends[B]).to.equal(1)
			expect(egg._mutex).to.equal(false)
			expect(egg._flightGen).to.equal(1)
			-- Both players got fresh snapshots.
			expect((pushes[B] or 0) >= 1).to.equal(true)
			expect((pushes[A] or 0) >= 1).to.equal(true)
			-- Buy prompt re-stamped to the current purchaser
			-- (B's filter hides Buy; A still sees it).
			local primary = egg.model and egg.model.PrimaryPart
			expect(primary).to.be.ok()
			local buyPrompt: ProximityPrompt? = nil
			for _, child in ipairs((primary :: BasePart):GetChildren()) do
				if child:IsA('ProximityPrompt') and child.Name == 'BuyPrompt' then
					buyPrompt = child
				end
			end
			expect(buyPrompt).to.be.ok()
			expect((buyPrompt :: ProximityPrompt):GetAttribute('purchaserUserId')).to.equal(B)
			cleanupEgg(egg)
		end)

		it('owner re-buying their own traveling egg is rejected before debit', function()
			local egg = stageTravelingEgg(A)
			services.EggService.SetPlayerService(fakePlayerService())
			services.EggService.SetEconomyService(fakeEconomyService())
			local fakeA = Helpers.FakePlayer(A, 'Ay')
			local r = services.EggService.Purchase(fakeA, egg.uniqueId)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('not-available')
			expect(spends[A]).to.equal(nil)
			expect(egg.ownerUserId).to.equal(A)
			expect(egg._mutex).to.equal(false)
			cleanupEgg(egg)
		end)

		it('a Placed egg is still unavailable', function()
			local egg = stageTravelingEgg(A)
			egg.state = 'Placed'
			services.EggService.SetPlayerService(fakePlayerService())
			services.EggService.SetEconomyService(fakeEconomyService())
			local fakeB = Helpers.FakePlayer(B, 'Bee')
			local r = services.EggService.Purchase(fakeB, egg.uniqueId)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('not-available')
			expect(spends[B]).to.equal(nil)
			cleanupEgg(egg)
		end)
	end)
end
