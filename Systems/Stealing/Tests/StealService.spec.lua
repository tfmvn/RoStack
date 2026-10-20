--!strict
--!native
--[[
	StealService.spec
	=================
	Server-authoritative multiplayer stealing. Real wired
	services + real bases/slots/models; the profile layer is
	faked (call-capturing) via StealService.SetPlayerService.

 	Coverage:
  	  * CanSteal pure validation: ok / own-object / wrong-kind /
  	    invalid-target / target-gone / already-carrying /
  	    not-stealable-state / too-far / slot-race (locked bases
  	    still allow steal-start; the lock blocks escape physically).
 	  * Atomicity: a demoted (Reserved) slot rejects a second
 	    stealer — exactly one winner.
 	  * Rollback tier-1: steal-carry returns to the ORIGINAL
 	    owner's slot with prompts restored, registry cleared.
 	  * RollbackIfStealing / IsStolenRecord routing queries.
 	  * TryComplete egg transfer: profile moves A -> B under
 	    the SAME Id, runtime ownership/slot follow, original
 	    slot released, no duplicate.
 	  * TryComplete animal transfer preserves
 	    Level/XP/CashPool/Trait/Mutations/DefId/Id exactly.
 	  * PlaceEgg rejects steal-carried eggs ('steal-in-progress').
 	  * Steal prompt is installed alongside Pickup with the
 	    inverse-visibility marker + owner attribute.
  * Touch-only completion: no Deliver prompt surface exists
    (installer removed; touch routing is the only path).
  * Victim robbery text: thief + rarity-colored animal in
    danger red, markup-escaped (no raw tags from names).

	Live-character happy paths (full TrySteal attach) stay in
	the multiplayer playtest matrix: they need real Player
	instances + network ownership, like the existing carry
	happy paths (see CarryService.spec header).
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Workspace = game:GetService('Workspace')
	local Players = game:GetService('Players')

	local Helpers = require(script.Parent._Helpers)
	local StealService = require(ServerScriptService.Steal.StealService)
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local SlotService = require(ServerScriptService.Base.SlotService)
	local SlotType = require(ReplicatedStorage.Types.SlotType)
	local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
	local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)

	local A = 7101
	local B = 7102

	local profiles: { [number]: { LuckyBlocks: { any }, Brainrots: { any } } } = {}
	local calls: { { op: string, userId: number, id: string } } = {}

	local function fakePlayerService()
		local svc: any = {}
		function svc.GetEggs(userId: number)
			local p = profiles[userId]
			if not p then
				return {}
			end
			return p.LuckyBlocks
		end
		function svc.GetAnimals(userId: number)
			local p = profiles[userId]
			if not p then
				return {}
			end
			return p.Brainrots
		end
		function svc.AddEgg(userId: number, slotId: string, rarity: string, id: string?, opts: any?)
			calls[#calls + 1] = { op = 'AddEgg', userId = userId, id = id :: string }
			local p = profiles[userId]
			if not p then
				return false
			end
			p.LuckyBlocks[#p.LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = slotId,
				Rarity = rarity,
				Id = id,
				Mutations = opts and opts.Mutations or {},
				Trait = opts and opts.Trait or nil,
			}
			return true
		end
		function svc.RemoveEgg(userId: number, id: string?)
			calls[#calls + 1] = { op = 'RemoveEgg', userId = userId, id = id :: string }
			local p = profiles[userId]
			if not p then
				return false
			end
			for i, rec in ipairs(p.LuckyBlocks) do
				if rec.Id == id then
					table.remove(p.LuckyBlocks, i)
					return true
				end
			end
			return false
		end
		function svc.SetEggSlot(userId: number, id: string, newSlotId: string)
			local p = profiles[userId]
			if not p then
				return false
			end
			for _, rec in ipairs(p.LuckyBlocks) do
				if rec.Id == id then
					rec.SlotId = newSlotId
					return true
				end
			end
			return false
		end
		function svc.AddAnimal(userId: number, slotId: string, defId: string, id: string?, opts: any?)
			calls[#calls + 1] = { op = 'AddAnimal', userId = userId, id = id :: string }
			local p = profiles[userId]
			if not p then
				return false
			end
			local o = opts or {}
			p.Brainrots[#p.Brainrots + 1] = {
				Type = 'Brainrot',
				SlotId = slotId,
				DefId = defId,
				Id = id,
				Level = o.Level or 1,
				XP = o.XP or 0,
				CashPool = o.CashPool or '0',
				Trait = o.Trait,
				Mutations = o.Mutations or {},
			}
			return true
		end
		function svc.RemoveAnimal(userId: number, id: string?)
			calls[#calls + 1] = { op = 'RemoveAnimal', userId = userId, id = id :: string }
			local p = profiles[userId]
			if not p then
				return false
			end
			for i, rec in ipairs(p.Brainrots) do
				if rec.Id == id then
					table.remove(p.Brainrots, i)
					return true
				end
			end
			return false
		end
		function svc.SetAnimalSlot(userId: number, id: string, newSlotId: string)
			local p = profiles[userId]
			if not p then
				return false
			end
			for _, rec in ipairs(p.Brainrots) do
				if rec.Id == id then
					rec.SlotId = newSlotId
					return true
				end
			end
			return false
		end
		function svc.PushState(_player: any, _snap: any)
			-- Push accounting: lets specs assert both sides
			-- are re-synced after failed transactions.
			local uid: any = nil
			pcall(function()
				uid = (_player :: any).UserId
			end)
			if type(uid) == 'number' then
				pushes[uid] = (pushes[uid] or 0) + 1
			end
		end
		function svc.Notify(_player: any, _kind: string, _text: string) end
		return svc
	end

	local services: any = nil
	local baseA: any = nil
	local baseB: any = nil
	local eggIds: { string } = {}
	local animalIds: { string } = {}
	local trash: { Instance } = {}
	local pushes: { [number]: number } = {}

	local function setup()
		Helpers.StubRemotes()
		CarryRegistry.Init()
		pushes = {}
		services = Helpers.WireServices()
		Helpers.EnsureCollectors()
		if not next(services.BaseService.GetAllBases()) then
			services.BaseService.RegisterBases(Workspace)
		end
		services.EggService.RegisterCenter(Workspace)
		if not services.BaseService.GetBaseByOwner(A) then
			baseA = services.BaseService.AssignBaseById(A, 'Base_1')
		else
			baseA = services.BaseService.GetBaseByOwner(A)
		end
		if not services.BaseService.GetBaseByOwner(B) then
			baseB = services.BaseService.AssignBaseById(B, 'Base_2')
		else
			baseB = services.BaseService.GetBaseByOwner(B)
		end
		expect(baseA).to.be.ok()
		expect(baseB).to.be.ok()
		profiles[A] = { LuckyBlocks = {}, Brainrots = {} }
		profiles[B] = { LuckyBlocks = {}, Brainrots = {} }
		calls = {}
		StealService.SetPlayerService(fakePlayerService())
		StealService.Init()
		StealService.ForgetPlayer(A)
		StealService.ForgetPlayer(B)
	end

	local function cleanup()
		CarryRegistry.Init()
		for _, id in ipairs(eggIds) do
			local egg = SpawnService.GetEgg(id)
			if egg then
				if egg.slotId then
					local slot = SlotService._findSlotById(egg.slotId)
					if slot then
						if slot.state == SlotType.State.Reserved then
							SlotService.ReleaseSlot(slot.id)
						elseif slot.state == SlotType.State.Occupied and slot.occupantId == id then
							if SlotService.DemoteSlotToReserved(slot.id) then
								SlotService.ReleaseSlot(slot.id)
							end
						end
					end
				end
				if egg.model and egg.model.Parent then
					egg.model:Destroy()
				end
				SpawnService.DropEgg(id)
			end
		end
		eggIds = {}
		for _, id in ipairs(animalIds) do
			services.AnimalService._TestUnregister(id)
		end
		animalIds = {}
		for _, inst in ipairs(trash) do
			if inst.Parent then
				inst:Destroy()
			end
		end
		trash = {}
	end

	-- A real Placed egg on owner's slot (persistence spawn path).
	local function placeEgg(ownerId: number, rarity: string): any
		local slot = services.BaseService.GetFreeSlot(ownerId)
		expect(slot).to.be.ok()
		expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
		local r = SpawnService.Request({
			definition = { rarity = rarity, price = 100 },
			origin = 'Persistence',
			targetSlot = slot,
		})
		expect(r.success).to.equal(true)
		local egg = r.egg
		expect(services.BaseService.OccupySlot(slot.id, egg.uniqueId, SlotType.OccupantKind.Egg)).to.equal(true)
		egg.ownerUserId = ownerId
		eggIds[#eggIds + 1] = egg.uniqueId
		return egg
	end

	-- A real Slotted animal on owner's slot (test registry + model).
	local function placeAnimal(ownerId: number, extra: any?): any
		local slot = services.BaseService.GetFreeSlot(ownerId)
		expect(slot).to.be.ok()
		expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
		local id = 'AN_steal' .. tostring(#animalIds + 1) .. tostring(ownerId)
		local model = Instance.new('Model')
		local root = Instance.new('Part')
		root.Name = 'HumanoidRootPart'
		root.Size = Vector3.new(2, 3, 2)
		root.Anchored = true
		root.Parent = model
		model.PrimaryPart = root
		model.Parent = Workspace
		trash[#trash + 1] = model
		local e = extra or {}
		services.AnimalService._TestRegister({
			uniqueId = id,
			definitionId = e.definitionId or 'Chicken',
			displayName = 'StealChicken',
			rarity = 'Common',
			ownerUserId = ownerId,
			slotId = slot.id,
			Level = e.Level or 5,
			XP = e.XP or 42,
			CashPool = e.CashPool or '1234',
			Trait = e.Trait or 'Swift',
			Mutations = e.Mutations or { 'Gold' },
			state = 'Slotted',
			carriedBy = nil,
			stolenBy = nil,
			originalSlotId = nil,
			model = model,
			_mutex = false,
		})
		expect(services.BaseService.OccupySlot(slot.id, id, SlotType.OccupantKind.Animal)).to.equal(true)
		animalIds[#animalIds + 1] = id
		return services.AnimalService.Get(id)
	end

	local function thiefAt(userId: number, pos: Vector3): any
		local p = Helpers.FakePlayer(userId)
		local character = Instance.new('Model')
		character.Name = 'FakeChar' .. tostring(userId)
		local hrp = Instance.new('Part')
		hrp.Name = 'HumanoidRootPart'
		hrp.Size = Vector3.new(2, 2, 1)
		hrp.Anchored = true
		hrp.CFrame = CFrame.new(pos)
		hrp.Parent = character
		character.PrimaryPart = hrp
		character.Parent = Workspace
		trash[#trash + 1] = character;
		(p :: any).Character = character
		return p
	end

	describe('StealService.CanSteal validation', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('accepts a valid non-owner steal (egg)', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(true)
			expect(check.ownerId).to.equal(A)
		end)

		it('rejects the owner (own-object)', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			local check = StealService.CanSteal(A, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(false)
			expect(check.error).to.equal('own-object')
		end)

		it('rejects bad kind / id / missing target', function()
			expect(StealService.CanSteal(B, 'EG_nope', 'egg', Vector3.new(0, 0, 0)).error).to.equal('target-gone')
			expect(StealService.CanSteal(B, 'EG_nope', 'nope' :: any, Vector3.new(0, 0, 0)).error).to.equal(
				'wrong-kind'
			)
			expect(StealService.CanSteal(B, '', 'egg', Vector3.new(0, 0, 0)).error).to.equal('invalid-target')
			expect(StealService.CanSteal(0, 'EG_x', 'egg', Vector3.new(0, 0, 0)).error).to.equal('invalid-player')
		end)

		it('rejects while the thief is already carrying', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Animal,
				record = { uniqueId = 'AN_busy' },
				originalSlotId = slot.id,
				startedAt = os.clock(),
			})
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(false)
			expect(check.error).to.equal('already-carrying')
		end)

		it('rejects non-resting states and carried flags', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			egg.state = 'Traveling'
			expect(StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position).error).to.equal(
				'not-stealable-state'
			)
			egg.state = 'Placed'
			egg.carriedBy = B
			expect(StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position).error).to.equal('already-carried')
			egg.carriedBy = nil
		end)

		it('rejects out-of-range thieves (server distance)', function()
			local egg = placeEgg(A, 'Common')
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', Vector3.new(9999, 9999, 9999))
			expect(check.ok).to.equal(false)
			expect(check.error).to.equal('too-far')
		end)

		it('allows steal-start on a locked base (lock blocks escape, not pickup)', function()
			local BaseLockService = require(ServerScriptService.Base.BaseLockService)
			BaseLockService.Init()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			expect(BaseLockService.Lock(baseA)).to.equal(true)
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(true)
			BaseLockService.Unlock(baseA.id)
		end)

		it('atomicity: a demoted slot rejects the second stealer', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			-- First stealer wins the demote...
			expect(SlotService.DemoteSlotToReserved(slot.id)).to.equal(true)
			-- ...the second sees a non-Occupied slot and loses.
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(false)
			expect(check.error).to.equal('slot-race')
			-- Restore for cleanup.
			expect(SlotService.OccupySlot(slot.id, egg.uniqueId, SlotType.OccupantKind.Egg)).to.equal(true)
		end)

		it('rejects before pickup when the thief base is full (no-destination)', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			-- Fill B's base completely with scratch occupancy.
			local scratch: { any } = {}
			for _, s in pairs(baseB.slots) do
				if s.state == SlotType.State.Empty then
					expect(SlotService.ReserveSlot(s.id)).to.equal(true)
					expect(SlotService.OccupySlot(s.id, 'EG_scratch' .. s.id, SlotType.OccupantKind.Egg)).to.equal(true)
					scratch[#scratch + 1] = s
				end
			end
			-- Pure validation rejects with zero mutation.
			local check = StealService.CanSteal(B, egg.uniqueId, 'egg', slot.part.Position)
			expect(check.ok).to.equal(false)
			expect(check.error).to.equal('no-destination')
			-- A's animal is completely untouched: owner, slot,
			-- state, occupancy all intact, nothing reserved.
			expect(egg.ownerUserId).to.equal(A)
			expect(egg.state).to.equal('Placed')
			expect(egg.carriedBy).to.equal(nil)
			expect(egg.stolenBy).to.equal(nil)
			expect(CarryRegistry.IsCarrying(B)).to.equal(false)
			local live = SlotService._findSlotById(egg.slotId)
			expect(live.state).to.equal(SlotType.State.Occupied)
			expect(live.occupantId).to.equal(egg.uniqueId)
			-- NOTE: TrySteal delegates to this same CanSteal
			-- before ANY mutation (demote/attach/registry), so
			-- a forged request from a real (live) client hits
			-- this exact rejection with zero side effects.
			-- Live-player construction belongs to the
			-- multiplayer matrix (see header).
			-- Restore scratch slots.
			for _, s in ipairs(scratch) do
				if SlotService.DemoteSlotToReserved(s.id) then
					SlotService.ReleaseSlot(s.id)
				end
			end
		end)
	end)

	describe('StealService.TrySteal gating', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('rejects a non-live player without touching state', function()
			local r = StealService.TrySteal(nil :: any, 'EG_x', 'egg')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('invalid-player')
		end)

		it('owner TrySteal is rejected with zero mutation', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			local owner = thiefAt(A, slot.part.Position)
			local r = StealService.TrySteal(owner, egg.uniqueId, 'egg')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('own-object')
			-- Zero mutation: slot, record, and carry registry
			-- are exactly as before the forged request.
			local live = SlotService._findSlotById(egg.slotId)
			expect(live.state).to.equal(SlotType.State.Occupied)
			expect(live.occupantId).to.equal(egg.uniqueId)
			expect(egg.state).to.equal('Placed')
			expect(egg.carriedBy).to.equal(nil)
			expect(egg.stolenBy).to.equal(nil)
			expect(egg._mutex).to.equal(false)
			expect(CarryRegistry.IsCarrying(A)).to.equal(false)
		end)

		it('owner animal TrySteal is rejected with zero mutation', function()
			local animal = placeAnimal(A, {})
			local slot = SlotService._findSlotById(animal.slotId)
			local owner = thiefAt(A, slot.part.Position)
			local r = StealService.TrySteal(owner, animal.uniqueId, 'animal')
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('own-object')
			local live = SlotService._findSlotById(animal.slotId)
			expect(live.state).to.equal(SlotType.State.Occupied)
			expect(live.occupantId).to.equal(animal.uniqueId)
			expect(animal.state).to.equal('Slotted')
			expect(animal.carriedBy).to.equal(nil)
			expect(animal.stolenBy).to.equal(nil)
			expect(CarryRegistry.IsCarrying(A)).to.equal(false)
		end)

		it('rapid reinstalls never expose Steal to the owner (fail-closed default)', function()
			-- Simulates rapid owner pickup/place spam: every
			-- place reinstalls Pickup + Steal via the funnel.
			-- The Steal prompt must replicate disabled on EVERY
			-- install (the client filter enables it only for
			-- eligible non-owners), so the owner observes zero
			-- Steal flash regardless of spam rate. Pickup keeps
			-- its valid default (the owner SHOULD see it).
			local animal = placeAnimal(A, {})
			local slot = SlotService._findSlotById(animal.slotId)
			local model = animal.model
			for _ = 1, 5 do
				CarryPrompts.InstallPickupPrompt(model, animal.uniqueId, 'animal', slot, A)
				local primary = model.PrimaryPart
				local pickup = primary:FindFirstChild('PickupPrompt')
				expect(pickup ~= nil).to.equal(true)
				local stealPrompt = primary:FindFirstChild('StealPrompt')
				expect(stealPrompt ~= nil).to.equal(true)
				assert(stealPrompt ~= nil, 'steal prompt installed')
				expect(stealPrompt.Enabled).to.equal(false)
				expect(stealPrompt:GetAttribute('stealPrompt')).to.equal(true)
				expect(stealPrompt:GetAttribute('ownerUserId')).to.equal(A)
			end
		end)

		it('rate-limits rapid repeat requests', function()
			local egg = placeEgg(A, 'Common')
			local slot = SlotService._findSlotById(egg.slotId)
			local thief = thiefAt(B, slot.part.Position)
			local first = StealService.TrySteal(thief, egg.uniqueId, 'egg')
			-- Either path consumes the attempt window: a second
			-- immediate request must be rate-limited. (The first
			-- may fail on fake-character attach; the window is
			-- what this locks.)
			local second = StealService.TrySteal(thief, egg.uniqueId, 'egg')
			expect(second.success).to.equal(false)
			expect(second.error).to.equal('rate-limited')
			expect(first.success).to.equal(false)
			-- Cleanup any partial attach from the first attempt.
			if CarryRegistry.IsCarrying(B) then
				StealService.RollbackCarried(B, 'test-cleanup')
			end
			if egg._mutex then
				egg._mutex = false
			end
			local live = SlotService._findSlotById(egg.slotId)
			if live and live.state == SlotType.State.Reserved then
				SlotService.OccupySlot(egg.slotId, egg.uniqueId, SlotType.OccupantKind.Egg)
			end
		end)
	end)

	describe('StealService rollback + queries', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('IsStolenRecord is false when nothing is carried', function()
			expect(StealService.IsStolenRecord('egg', 'EG_none')).to.equal(false)
			expect(StealService.RollbackIfStealing(B, 'test')).to.equal(false)
		end)

		it('rollback tier-1 restores the original slot, prompts, and clears carry', function()
			local egg = placeEgg(A, 'Common')
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			expect(StealService.IsStolenRecord('egg', egg.uniqueId)).to.equal(true)
			expect(StealService.RollbackIfStealing(B, 'test')).to.equal(true)
			expect(egg.state).to.equal('Placed')
			expect(egg.ownerUserId).to.equal(A)
			expect(egg.stolenBy).to.equal(nil)
			expect(CarryRegistry.IsCarrying(B)).to.equal(false)
			local slot = SlotService._findSlotById(egg.slotId)
			expect(slot.state).to.equal(SlotType.State.Occupied)
			expect(slot.occupantId).to.equal(egg.uniqueId)
			-- Prompts restored (Pickup + Steal via the funnel).
			local primary = egg.model.PrimaryPart
			expect(primary:FindFirstChild('PickupPrompt') ~= nil).to.equal(true)
			expect(primary:FindFirstChild('HatchPrompt') ~= nil).to.equal(true)
			local stealPrompt = primary:FindFirstChild('StealPrompt')
			expect(stealPrompt ~= nil).to.equal(true)
			assert(stealPrompt ~= nil, 'steal prompt restored')
			expect(stealPrompt:GetAttribute('stealPrompt')).to.equal(true)
			expect(stealPrompt:GetAttribute('ownerUserId')).to.equal(A)
			-- Fail-closed install: a fresh StealPrompt replicates
			-- disabled until the client filter evaluates it, so the
			-- owner can never observe it pre-tick (no Steal flash
			-- on rapid pickup/place). Eligible non-owners pick it
			-- up on the next filter tick.
			expect(stealPrompt.Enabled).to.equal(false)
		end)

		it('rollback restores a stolen animal overhead to its exact prior look', function()
			local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
			local OverheadConfig = require(ReplicatedStorage.Config.Presentation.UI).Overhead
			local animal = placeAnimal(A, {})
			-- Stage the overhead the production Refresh owns
			-- (same hierarchy contract: OverheadGui > Container
			-- > Content > named labels), with Income pre-hidden
			-- so restore-exactness is observable.
			local host = animal.model.PrimaryPart
			local gui = Instance.new('BillboardGui')
			gui.Name = 'OverheadGui'
			local container = Instance.new('Frame')
			container.Name = 'Container'
			container.Parent = gui
			local content = Instance.new('Frame')
			content.Name = 'Content'
			content.Parent = container
			local function stageLabel(labelName: string, text: string, visible: boolean): TextLabel
				local made = Instance.new('TextLabel')
				made.Name = labelName
				made.Text = text
				made.Visible = visible
				made.TextColor3 = Color3.fromRGB(255, 255, 255)
				made.Parent = content
				return made
			end
			local nameLabel = stageLabel('Name', 'StealChicken', true)
			stageLabel('Level', 'Lv. 5', true)
			stageLabel('Rarity', 'Common', true)
			local income = stageLabel('Income', '$2/s', false)
			gui.Parent = host
			-- Steal-start presentation (the exact call a
			-- successful TrySteal makes for animals).
			expect(AnimalOverhead.SetStolen(animal, true)).to.equal(true)
			expect(nameLabel.Text).to.equal('STOLEN')
			expect(nameLabel.TextColor3).to.equal(OverheadConfig.StolenTextColor)
			expect((content:FindFirstChild('Level') :: GuiObject).Visible).to.equal(false)
			-- Stage the steal carry exactly like the egg
			-- tier-1 test above.
			expect(SlotService.DemoteSlotToReserved(animal.slotId)).to.equal(true)
			animal.state = 'Carried'
			animal.carriedBy = B
			animal.originalSlotId = animal.slotId
			animal.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Animal,
				record = animal,
				originalSlotId = animal.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			-- Cancel path: the exit restores the overhead.
			local rolled = StealService.RollbackCarried(B, 'test-cancel')
			expect(rolled.success).to.equal(true)
			expect(AnimalOverhead._TestIsStolen(animal.uniqueId)).to.equal(false)
			expect(nameLabel.Text).to.equal('StealChicken')
			expect(nameLabel.TextColor3).to.equal(Color3.fromRGB(255, 255, 255))
			expect((content:FindFirstChild('Level') :: GuiObject).Visible).to.equal(true)
			-- Pre-hidden stays hidden (never blind Visible).
			expect(income.Visible).to.equal(false)
			-- The record itself was never renamed.
			expect(animal.displayName).to.equal('StealChicken')
		end)

		it('death spam after rollback: old transaction is gone, only a fresh steal may begin', function()
			-- The exploit: B dies mid-carry, the animal returns,
			-- then B spams E while dead/respawning. The dead
			-- requests must die on the liveness gate; once
			-- rolled back, NO steal residue may remain, so a
			-- later request can only ever start a NEW
			-- transaction (never continue the old one).
			local egg = placeEgg(A, 'Common')
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			-- Death hook path.
			expect(StealService.RollbackIfStealing(B, 'death')).to.equal(true)
			-- Transaction fully dissolved: registry, flags,
			-- carrier, mutex, slot — nothing steal-shaped left.
			expect(StealService.IsStealCarry(B)).to.equal(false)
			expect(StealService.IsStolenRecord('egg', egg.uniqueId)).to.equal(false)
			expect(egg.stolenBy).to.equal(nil)
			expect(egg.carriedBy).to.equal(nil)
			expect(egg.originalSlotId).to.equal(nil)
			expect(egg._mutex).to.equal(false)
			expect(egg.state).to.equal('Placed')
			expect(egg.ownerUserId).to.equal(A)
			local slot = SlotService._findSlotById(egg.slotId)
			expect(slot.state).to.equal(SlotType.State.Occupied)
			expect(slot.occupantId).to.equal(egg.uniqueId)
			-- A subsequent check is a FRESH validation (new
			-- transaction or nothing), never the old one: the
			-- record carries no steal identity anymore.
			local slotPos = slot.part.Position
			local fresh = StealService.CanSteal(B, egg.uniqueId, 'egg', slotPos)
			expect(fresh.ok).to.equal(true)
		end)

		it('rollback re-homes the egg model to ActiveEggs (no stale carried folder)', function()
			local egg = placeEgg(A, 'Common')
			-- Simulate the carry attach: model was reparented
			-- out of the canonical container.
			local scratch = Instance.new('Folder')
			scratch.Name = 'Carried_Scratch'
			scratch.Parent = Workspace
			trash[#trash + 1] = scratch
			egg.model.Parent = scratch
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			StealService.RollbackCarried(B, 'test')
			local container = SpawnService.GetActiveContainer()
			expect(container).to.be.ok()
			expect(egg.model.Parent).to.equal(container)
		end)

		it('double rollback is a safe no-op (single authoritative recovery)', function()
			local egg = placeEgg(A, 'Common')
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			local first = StealService.RollbackCarried(B, 'death')
			expect(first.success).to.equal(true)
			-- Second call (death + leave racing): nothing to
			-- recover, nothing duplicated, slot untouched.
			local second = StealService.RollbackCarried(B, 'disconnect')
			expect(second.success).to.equal(false)
			expect(second.error).to.equal('not-a-steal')
			local slot = SlotService._findSlotById(egg.slotId)
			expect(slot.state).to.equal(SlotType.State.Occupied)
			expect(slot.occupantId).to.equal(egg.uniqueId)
			expect(egg.state).to.equal('Placed')
		end)

		it('rollback releases the reserved destination slot', function()
			local egg = placeEgg(A, 'Common')
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			local dest = services.BaseService.GetFreeSlot(B)
			expect(dest).to.be.ok()
			expect(SlotService.ReserveSlot(dest.id)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id, destSlotId = dest.id },
			})
			StealService.RollbackCarried(B, 'test')
			-- Destination back to Empty (reusable); original
			-- re-occupied. No leaked reservation either way.
			local liveDest = SlotService._findSlotById(dest.id)
			expect(liveDest.state).to.equal(SlotType.State.Empty)
			local orig = SlotService._findSlotById(egg.slotId)
			expect(orig.state).to.equal(SlotType.State.Occupied)
		end)

		it('occupied original slot falls back without overwriting (tier-2)', function()
			local egg = placeEgg(A, 'Common')
			local origSlotId = egg.slotId
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = origSlotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			profiles[A].LuckyBlocks[#profiles[A].LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = origSlotId,
				Rarity = 'Common',
				Id = egg.uniqueId,
				Mutations = {},
				Trait = nil,
			}
			-- Original slot changed hands while carried: release
			-- the reservation and occupy it with a scratch id.
			-- Recovery must NOT overwrite it.
			expect(SlotService.ReleaseSlot(origSlotId)).to.equal(true)
			expect(SlotService.ReserveSlot(origSlotId)).to.equal(true)
			expect(SlotService.OccupySlot(origSlotId, 'EG_scratch', SlotType.OccupantKind.Egg)).to.equal(true)
			local r = StealService.RollbackCarried(B, 'test')
			expect(r.success).to.equal(true)
			-- Scratch occupant intact on the original slot.
			local origSlot = SlotService._findSlotById(origSlotId)
			expect(origSlot.state).to.equal(SlotType.State.Occupied)
			expect(origSlot.occupantId).to.equal('EG_scratch')
			-- Egg landed on a DIFFERENT slot of A's base with
			-- the profile re-pointed (same record, new SlotId).
			expect(egg.slotId).to.be.ok()
			expect(egg.slotId == origSlotId).to.equal(false)
			local landed = SlotService._findSlotById(egg.slotId)
			expect(landed.state).to.equal(SlotType.State.Occupied)
			expect(landed.occupantId).to.equal(egg.uniqueId)
			expect(profiles[A].LuckyBlocks[1].SlotId).to.equal(egg.slotId)
			expect(profiles[A].LuckyBlocks[1].Id).to.equal(egg.uniqueId)
			-- Restore the scratch slot for other tests.
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			expect(SlotService.ReleaseSlot(origSlotId)).to.equal(true)
		end)
	end)

	describe('StealService.TryComplete transfer', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('transfers an egg A -> B under the same Id with no duplicate', function()
			local egg = placeEgg(A, 'Common')
			profiles[A].LuckyBlocks[#profiles[A].LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = egg.slotId,
				Rarity = 'Common',
				Id = egg.uniqueId,
				Mutations = {},
				Trait = nil,
			}
			local origSlotId = egg.slotId
			-- Thief at their own collector (created first: the
			-- crafted carry records the live character, like a
			-- real attach would).
			local collector = baseB.collector
			expect(collector).to.be.ok()
			local thief = thiefAt(B, collector.Position)
			-- Reserve the destination up front, exactly like
			-- TrySteal does: completion must land HERE, not on
			-- a freshly picked slot.
			local dest = services.BaseService.GetFreeSlot(B)
			expect(dest).to.be.ok()
			expect(SlotService.ReserveSlot(dest.id)).to.equal(true)
			-- Craft the steal-carry directly (attach needs a live
			-- character; validation + attach are covered above and
			-- in the multiplayer matrix).
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = origSlotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = {
					originalOwnerUserId = A,
					originalBaseId = baseA.id,
					carryCharacter = thief.Character,
					destSlotId = dest.id,
				},
			})
			-- Simulate the carry attach: model lives outside
			-- the canonical container until completion seats it.
			local scratch = Instance.new('Folder')
			scratch.Name = 'Carried_Scratch2'
			scratch.Parent = Workspace
			trash[#trash + 1] = scratch
			egg.model.Parent = scratch
			local r = StealService.TryComplete(thief)
			expect(r.success).to.equal(true)
			-- Profile moved exactly once, same Id.
			expect(#profiles[A].LuckyBlocks).to.equal(0)
			expect(#profiles[B].LuckyBlocks).to.equal(1)
			expect(profiles[B].LuckyBlocks[1].Id).to.equal(egg.uniqueId)
			-- Runtime follows, seated in the RESERVED slot.
			expect(egg.ownerUserId).to.equal(B)
			expect(egg.state).to.equal('Placed')
			expect(egg.slotId).to.equal(dest.id)
			expect(egg.stolenBy).to.equal(nil)
			expect(CarryRegistry.IsCarrying(B)).to.equal(false)
			local freshSlot = SlotService._findSlotById(egg.slotId)
			expect(freshSlot.state).to.equal(SlotType.State.Occupied)
			expect(freshSlot.occupantId).to.equal(egg.uniqueId)
			-- Original slot released.
			local origSlot = SlotService._findSlotById(origSlotId)
			expect(origSlot.state).to.equal(SlotType.State.Empty)
			-- Model re-homed to the canonical egg container.
			expect(egg.model.Parent).to.equal(SpawnService.GetActiveContainer())
			eggIds[#eggIds + 1] = egg.uniqueId
		end)

		it('preserves animal progression exactly (Level/XP/CashPool/Trait/Mutations/Id)', function()
			local animal = placeAnimal(A, {
				Level = 7,
				XP = 123,
				CashPool = '9876',
				Trait = 'Swift',
				Mutations = { 'Gold', 'Neon' },
			})
			profiles[A].Brainrots[#profiles[A].Brainrots + 1] = {
				Type = 'Brainrot',
				SlotId = animal.slotId,
				DefId = 'Chicken',
				Id = animal.uniqueId,
				Level = 7,
				XP = 123,
				CashPool = '9876',
				Trait = 'Swift',
				Mutations = { 'Gold', 'Neon' },
			}
			expect(SlotService.DemoteSlotToReserved(animal.slotId)).to.equal(true)
			animal.state = 'Carried'
			animal.carriedBy = B
			animal.originalSlotId = animal.slotId
			animal.stolenBy = B
			local collector = baseB.collector
			local thief = thiefAt(B, collector.Position)
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Animal,
				record = animal,
				originalSlotId = animal.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id, carryCharacter = thief.Character },
			})
			local r = StealService.TryComplete(thief)
			expect(r.success).to.equal(true)
			expect(#profiles[A].Brainrots).to.equal(0)
			expect(#profiles[B].Brainrots).to.equal(1)
			local moved = profiles[B].Brainrots[1]
			expect(moved.Id).to.equal(animal.uniqueId)
			expect(moved.DefId).to.equal('Chicken')
			expect(moved.Level).to.equal(7)
			expect(moved.XP).to.equal(123)
			expect(moved.CashPool).to.equal('9876')
			expect(moved.Trait).to.equal('Swift')
			expect(#moved.Mutations).to.equal(2)
			expect(animal.ownerUserId).to.equal(B)
			expect(animal.state).to.equal('Slotted')
		end)

		it('rejects completion with no free slot and keeps the carry', function()
			local egg = placeEgg(A, 'Common')
			profiles[A].LuckyBlocks[#profiles[A].LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = egg.slotId,
				Rarity = 'Common',
				Id = egg.uniqueId,
				Mutations = {},
				Trait = nil,
			}
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			local collector = baseB.collector
			local thief = thiefAt(B, collector.Position)
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id, carryCharacter = thief.Character },
			})
			-- Fill B's base: occupy every slot with scratch eggs.
			local scratch: { any } = {}
			for _, slot in pairs(baseB.slots) do
				if slot.state == SlotType.State.Empty then
					expect(SlotService.ReserveSlot(slot.id)).to.equal(true)
					expect(SlotService.OccupySlot(slot.id, 'EG_scratch' .. slot.id, SlotType.OccupantKind.Egg)).to.equal(
						true
					)
					scratch[#scratch + 1] = slot
				end
			end
			local r = StealService.TryComplete(thief)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('no-slot')
			-- Carry kept, profile untouched.
			expect(CarryRegistry.IsCarrying(B)).to.equal(true)
			expect(#profiles[A].LuckyBlocks).to.equal(1)
			expect(#profiles[B].LuckyBlocks).to.equal(0)
			-- Restore scratch slots.
			for _, slot in ipairs(scratch) do
				if SlotService.DemoteSlotToReserved(slot.id) then
					SlotService.ReleaseSlot(slot.id)
				end
			end
			StealService.RollbackCarried(B, 'test-cleanup')
		end)

		it('rejects completion from a replaced character and rolls back (respawn safety)', function()
			-- B stole with Character_A, died, respawned as
			-- Character_B, then touches the collector: same
			-- UserId, NEW Model. The pre-death transaction must
			-- not complete — it rolls back to A instead.
			local egg = placeEgg(A, 'Common')
			profiles[A].LuckyBlocks[#profiles[A].LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = egg.slotId,
				Rarity = 'Common',
				Id = egg.uniqueId,
				Mutations = {},
				Trait = nil,
			}
			local origSlotId = egg.slotId
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = origSlotId
			egg.stolenBy = B
			local collector = baseB.collector
			local newThief = thiefAt(B, collector.Position)
			local oldCharacter = Instance.new('Model')
			oldCharacter.Name = 'DeadCharacter'
			oldCharacter.Parent = Workspace
			trash[#trash + 1] = oldCharacter
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id, carryCharacter = oldCharacter },
			})
			local r = StealService.TryComplete(newThief)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('character-changed')
			-- Rolled back, never transferred.
			expect(CarryRegistry.IsCarrying(B)).to.equal(false)
			expect(egg.ownerUserId).to.equal(A)
			expect(egg.state).to.equal('Placed')
			expect(#profiles[A].LuckyBlocks).to.equal(1)
			expect(#profiles[B].LuckyBlocks).to.equal(0)
			local origSlot = SlotService._findSlotById(origSlotId)
			expect(origSlot.state).to.equal(SlotType.State.Occupied)
		end)
	end)

	describe('StealService.TryComplete failure atomicity', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('failed destination occupy mutates nothing and stays retryable', function()
			local egg = placeEgg(A, 'Common')
			profiles[A].LuckyBlocks[#profiles[A].LuckyBlocks + 1] = {
				Type = 'LuckyBlock',
				SlotId = egg.slotId,
				Rarity = 'Common',
				Id = egg.uniqueId,
				Mutations = {},
				Trait = nil,
			}
			local origSlotId = egg.slotId
			local collector = baseB.collector
			expect(collector).to.be.ok()
			local thief = thiefAt(B, collector.Position)
			local dest = services.BaseService.GetFreeSlot(B)
			expect(dest).to.be.ok()
			expect(SlotService.ReserveSlot(dest.id)).to.equal(true)
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = origSlotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = {
					originalOwnerUserId = A,
					originalBaseId = baseA.id,
					carryCharacter = thief.Character,
					destSlotId = dest.id,
				},
			})
			-- Jam the destination so OccupySlot fails: nothing
			-- may move (profiles, source slot, record, carry).
			dest._mutex = true
			local r = StealService.TryComplete(thief)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('slot-race')
			-- Profiles untouched: no split-brain.
			expect(#profiles[A].LuckyBlocks).to.equal(1)
			expect(#profiles[B].LuckyBlocks).to.equal(0)
			-- Source slot intact (still Reserved for the egg).
			local origSlot = SlotService._findSlotById(origSlotId)
			expect(origSlot.state).to.equal(SlotType.State.Reserved)
			expect(origSlot.occupantId).to.equal(egg.uniqueId)
			-- Record untouched: still A's, carried, flagged.
			expect(egg.ownerUserId).to.equal(A)
			expect(egg.state).to.equal('Opening')
			expect(egg.carriedBy).to.equal(B)
			expect(egg.stolenBy).to.equal(B)
			expect(egg.slotId).to.equal(origSlotId)
			expect(egg._mutex).to.equal(false)
			-- Carry kept: retryable, not stranded.
			expect(StealService.IsStealCarry(B)).to.equal(true)
			-- Destination reservation preserved for the retry.
			expect(dest.state).to.equal(SlotType.State.Reserved)
			-- Thief re-synced (owner push needs a live Player,
			-- covered in the multiplayer matrix).
			expect((pushes[B] or 0) >= 1).to.equal(true)
			-- Unjam: the SAME carry now completes cleanly.
			dest._mutex = false
			local r2 = StealService.TryComplete(thief)
			expect(r2.success).to.equal(true)
			expect(#profiles[A].LuckyBlocks).to.equal(0)
			expect(#profiles[B].LuckyBlocks).to.equal(1)
			expect(egg.ownerUserId).to.equal(B)
			expect(egg.slotId).to.equal(dest.id)
			expect(StealService.IsStealCarry(B)).to.equal(false)
			local freshSlot = SlotService._findSlotById(dest.id)
			expect(freshSlot.state).to.equal(SlotType.State.Occupied)
			local releasedOrig = SlotService._findSlotById(origSlotId)
			expect(releasedOrig.state).to.equal(SlotType.State.Empty)
			eggIds[#eggIds + 1] = egg.uniqueId
		end)
	end)

	describe('StealService owner-leave recovery', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('owner leaving mid-steal recovers the animal home before the sweep', function()
			-- A owns an animal; B steals it; A leaves while B
			-- carries. Recover-first-then-sweep: the slot must
			-- end Occupied by the animal id (tier-1 re-occupy),
			-- the carry dissolved, the runtime dropped by the
			-- normal non-destructive sweep (profile kept for a
			-- clean rejoin). Under the old skip behavior the
			-- slot would be left Reserved with a live runtime.
			local animal = placeAnimal(A, { Level = 7, XP = 123 })
			local origSlotId = animal.slotId
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			animal.state = 'Carried'
			animal.carriedBy = B
			animal.originalSlotId = origSlotId
			animal.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Animal,
				record = animal,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			services.AnimalService.CleanupPlayer(A)
			expect(StealService.IsStealCarry(B)).to.equal(false)
			expect(services.AnimalService.Get(animal.uniqueId)).to.equal(nil)
			local slot = SlotService._findSlotById(origSlotId)
			expect(slot.state).to.equal(SlotType.State.Occupied)
			expect(slot.occupantId).to.equal(animal.uniqueId)
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Animal)
		end)

		it('owner leaving mid-steal recovers the egg home before teardown', function()
			local egg = placeEgg(A, 'Common')
			local origSlotId = egg.slotId
			expect(SlotService.DemoteSlotToReserved(origSlotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = origSlotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = origSlotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			services.EggService.CleanupPlayer(A)
			expect(StealService.IsStealCarry(B)).to.equal(false)
			-- Non-destructive sweep: runtime dropped, slot left
			-- Occupied for the base-level reset (same two-phase
			-- shape as a normal leave).
			expect(SpawnService.GetEgg(egg.uniqueId)).to.equal(nil)
			local slot = SlotService._findSlotById(origSlotId)
			expect(slot.state).to.equal(SlotType.State.Occupied)
			expect(slot.occupantId).to.equal(egg.uniqueId)
		end)
	end)

	describe('StealService prompt + place guards', function()
		beforeEach(function()
			setup()
		end)

		afterEach(function()
			cleanup()
		end)

		it('installs a marked Steal prompt alongside Pickup', function()
			local egg = placeEgg(A, 'Common')
			local primary = egg.model.PrimaryPart
			local stealPrompt = primary:FindFirstChild('StealPrompt')
			expect(stealPrompt ~= nil).to.equal(true)
			assert(stealPrompt ~= nil, 'steal prompt installed')
			expect(stealPrompt:GetAttribute('stealPrompt')).to.equal(true)
			expect(stealPrompt:GetAttribute('ownerUserId')).to.equal(A)
			expect(primary:FindFirstChild('PickupPrompt') ~= nil).to.equal(true)
		end)

		it('PlaceEgg rejects steal-carried eggs', function()
			local egg = placeEgg(A, 'Common')
			expect(SlotService.DemoteSlotToReserved(egg.slotId)).to.equal(true)
			egg.state = 'Opening'
			egg.carriedBy = B
			egg.originalSlotId = egg.slotId
			egg.stolenBy = B
			CarryRegistry.Set(B, {
				kind = SlotType.OccupantKind.Egg,
				record = egg,
				originalSlotId = egg.slotId,
				startedAt = os.clock(),
				steal = { originalOwnerUserId = A, originalBaseId = baseA.id },
			})
			local dest = services.BaseService.GetFreeSlot(B)
			expect(dest).to.be.ok()
			local thief = Helpers.FakePlayer(B)
			local r = services.EggService.PlaceEgg(thief, egg.uniqueId, dest.id)
			expect(r.success).to.equal(false)
			expect(r.error).to.equal('steal-in-progress')
			StealService.RollbackCarried(B, 'test-cleanup')
		end)

		it('completion is touch-only: no Deliver prompt surface exists', function()
			local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
			local Prompts = require(ReplicatedStorage.Config.World.Prompts)
			-- The installer was removed (not merely uncalled):
			-- any leftover reference fails loudly here.
			expect((CarryPrompts :: any).InstallDeliverPrompt).to.equal(nil)
			expect((CarryPrompts :: any).RemoveDeliverPrompt).to.equal(nil)
			expect((CarryPrompts :: any).SetDeliverPromptCallback).to.equal(nil)
			expect(Prompts.Carry.ActionText.Deliver).to.equal(nil)
			-- And no collector carries a stale DeliverPrompt.
			for _, base in pairs(services.BaseService.GetAllBases()) do
				local collector = base.collector
				if typeof(collector) == 'Instance' and collector:IsA('BasePart') then
					expect(collector:FindFirstChild('DeliverPrompt')).to.equal(nil)
				end
			end
		end)
	end)

	describe('StealService victim robbery text', function()
		it('includes thief + rarity-colored animal in danger red', function()
			local text = StealService._TestVictimText('Bob', 'Dragon', 'Legendary')
			expect(string.find(text, 'Bob', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, 'Dragon', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, '<font color="#FF5A5A">', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, '<font color="#F5C846">Dragon</font>', 1, true) ~= nil).to.equal(true)
		end)

		it('escapes markup in names (no raw tags)', function()
			local text = StealService._TestVictimText('<b>Bob</b>', '</font>Dragon', 'Common')
			expect(string.find(text, '<b>', 1, true)).to.equal(nil)
			expect(string.find(text, '</font>Dragon', 1, true)).to.equal(nil)
			expect(string.find(text, '&lt;b&gt;Bob&lt;/b&gt;', 1, true) ~= nil).to.equal(true)
		end)

		it('falls back cleanly for unknown rarity', function()
			local text = StealService._TestVictimText('Bob', 'Mystery', nil)
			expect(string.find(text, 'Bob', 1, true) ~= nil).to.equal(true)
			expect(string.find(text, 'Mystery', 1, true) ~= nil).to.equal(true)
		end)
	end)
end
