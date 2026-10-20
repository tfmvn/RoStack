--!strict
--!native
--[[
	BaseService.spec
	================
	Covers: RegisterBases, AssignBaseForPlayer, slot reservation,
	slot occupation, slot release, snapshot, ownership lookup.

	Phase 2: a single 6-slot pool per base replaces the prior
	lucky/animal split. The kind parameter on GetFreeSlot is
	gone — any free slot can hold either kind.
]]

return function()
	local Helpers = require(script.Parent._Helpers)
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local SlotType = require(ReplicatedStorage.Types.SlotType)

	describe('BaseService', function()
		beforeEach(function()
			Helpers.StubRemotes()
		end)

		it('registers bases with a single unified 6-slot pool', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local all = services.BaseService.GetAllBases()
			local count = 0
			for _ in pairs(all) do
				count = count + 1
			end
			expect(count).to.equal(Bases.Count)
			for _, b in pairs(all) do
				expect(b.slots).to.be.a('table')
				expect(b.slots[1]).to.be.ok()
				expect(b.slots[Bases.Slots.Count]).to.be.ok()
				-- Phase 2: no more dual pools.
				expect(b.luckyBlockSlots).to.equal(nil)
				expect(b.animalSlots).to.equal(nil)
			end
		end)

		it('AssignBaseForPlayer returns nil when called for an unknown user with no bases', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			-- All bases pre-assigned.
			for i = 1, Bases.Count do
				services.BaseService.AssignBaseForPlayer(200 + i)
			end
			local extra = services.BaseService.AssignBaseForPlayer(9999)
			expect(extra).to.equal(nil)
		end)

		it('ReleaseBase clears ownership and reverts slot states', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local b = services.BaseService.AssignBaseForPlayer(301)
			expect(b).to.be.ok()
			-- Reserve + occupy one slot to make sure Release resets it.
			local slot = services.BaseService.GetFreeSlot(301)
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'X', SlotType.OccupantKind.Egg)
			services.BaseService.ReleaseBase(b.id)
			expect(services.BaseService.GetBaseByOwner(301)).to.equal(nil)
			local fresh = services.BaseService.GetBaseById(b.id)
			expect(fresh.state).to.equal('Available')
			expect(services.BaseService._findSlotById(slot.id).state).to.equal('Empty')
		end)

		it('ReserveSlot -> OccupySlot -> ReleaseSlot transitions', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local b = services.BaseService.AssignBaseForPlayer(401)
			expect(b).to.be.ok()
			-- Phase 2: GetFreeSlot takes only userId, no kind.
			local slot = services.BaseService.GetFreeSlot(401)
			expect(slot).to.be.ok()
			expect(slot.state).to.equal('Empty')
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Reserved')
			expect(services.BaseService.OccupySlot(slot.id, 'LB_X', SlotType.OccupantKind.Egg)).to.equal(true)
			expect(slot.state).to.equal('Occupied')
			expect(slot.occupantId).to.equal('LB_X')
			expect(slot.occupantKind).to.equal(SlotType.OccupantKind.Egg)
			expect(services.BaseService.ReleaseSlot(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Empty')
			expect(slot.occupantId).to.equal(nil)
		end)

		it('ReserveSlot on a non-Empty slot fails', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(501)
			local slot = services.BaseService.GetFreeSlot(501)
			services.BaseService.ReserveSlot(slot.id)
			expect(services.BaseService.ReserveSlot(slot.id)).to.equal(false)
		end)

		it('FindSlotByOccupant round-trips', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(601)
			local slot = services.BaseService.GetFreeSlot(601)
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'OCC1', SlotType.OccupantKind.Animal)
			local found = services.BaseService.FindSlotByOccupant('OCC1')
			expect(found).to.be.ok()
			expect(found.id).to.equal(slot.id)
		end)

		it('DemoteSlotToReserved flips Occupied -> Reserved', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(701)
			local slot = services.BaseService.GetFreeSlot(701)
			services.BaseService.ReserveSlot(slot.id)
			services.BaseService.OccupySlot(slot.id, 'OCC2', SlotType.OccupantKind.Egg)
			expect(services.BaseService.DemoteSlotToReserved(slot.id)).to.equal(true)
			expect(slot.state).to.equal('Reserved')
			expect(slot.occupantId).to.equal('OCC2')
		end)

		it('DemoteSlotToReserved is a no-op on non-Occupied slots', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(702)
			local slot = services.BaseService.GetFreeSlot(702)
			expect(services.BaseService.DemoteSlotToReserved(slot.id)).to.equal(false)
		end)

		it('Snapshot returns a wire-shaped table with one slots array', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(801)
			local snap = services.BaseService.Snapshot(801)
			expect(snap).to.be.ok()
			expect(snap.slots).to.be.a('table')
			expect(#snap.slots).to.equal(Bases.Slots.Count)
			expect(snap._occupiedCount).to.equal(0)
			expect(snap.luckyBlockSlots).to.equal(nil)
			expect(snap.animalSlots).to.equal(nil)
		end)

		it('GetFreeSlot returns nil when all 6 slots are occupied', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			services.BaseService.AssignBaseForPlayer(901)
			for i = 1, Bases.Slots.Count do
				local slot = services.BaseService.GetFreeSlot(901)
				expect(slot).to.be.ok()
				services.BaseService.ReserveSlot(slot.id)
				services.BaseService.OccupySlot(slot.id, 'OCC' .. tostring(i), SlotType.OccupantKind.Egg)
			end
			expect(services.BaseService.GetFreeSlot(901)).to.equal(nil)
		end)
	end)

	describe('BaseService MoneyMultPart label', function()
		local ServerScriptService = game:GetService('ServerScriptService')
		local RebirthService = require(ServerScriptService.Rebirth.RebirthService)
		local ModifierService = require(ServerScriptService.ModifierService)

		local U1 = 51101
		local U2 = 51102

		-- Stage the Studio-authored hierarchy every test reads:
		-- Base/MoneyMultPart/SurfaceGui/TextLabel (hidden).
		local function stageLabel(baseFolder: Instance): TextLabel
			local part = Instance.new('Part')
			part.Name = 'MoneyMultPart'
			part.Anchored = true
			part.Parent = baseFolder
			local surface = Instance.new('SurfaceGui')
			surface.Parent = part
			local label = Instance.new('TextLabel')
			label.Visible = false
			label.Text = ''
			label.Parent = surface
			return label
		end

		local function stageAll(baseService: any): { [string]: TextLabel }
			local labels: { [string]: TextLabel } = {}
			for _, base in pairs(baseService.GetAllBases()) do
				if type(base) == 'table' and typeof((base :: any).folder) == 'Instance' then
					labels[(base :: any).id] = stageLabel((base :: any).folder)
				end
			end
			return labels
		end

		local function labelFor(baseService: any, userId: number): TextLabel
			local base = baseService.GetBaseByOwner(userId)
			assert(base ~= nil, 'base assigned')
			local folder = (base :: any).folder
			local part = (folder :: Instance):FindFirstChild('MoneyMultPart')
			assert(part ~= nil, 'MoneyMultPart staged')
			local surface = (part :: Instance):FindFirstChild('SurfaceGui')
			assert(surface ~= nil, 'SurfaceGui staged')
			local label = (surface :: Instance):FindFirstChild('TextLabel')
			assert(label ~= nil and label:IsA('TextLabel'), 'TextLabel staged')
			return label :: TextLabel
		end

		afterEach(function()
			ModifierService.ClearModifiers(U1)
			ModifierService.ClearModifiers(U2)
		end)

		it('assign shows the label with the current multiplier', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			stageAll(services.BaseService)
			local base = services.BaseService.AssignBaseForPlayer(U1)
			expect(base).to.be.ok()
			local label = labelFor(services.BaseService, U1)
			expect(label.Visible).to.equal(true)
			expect(label.Text).to.equal('Mult: 1x')
			services.BaseService.CleanupPlayer(U1)
		end)

		it('multiplier changes repaint the same label', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			stageAll(services.BaseService)
			expect(services.BaseService.AssignBaseForPlayer(U1)).to.be.ok()
			ModifierService.AddModifier(U1, 'Spec2x', ModifierService.ModifierType.MoneyMultiplier, 2)
			RebirthService.RefreshBaseMultiplier(U1)
			expect(labelFor(services.BaseService, U1).Text).to.equal('Mult: 2x')
			ModifierService.AddModifier(U1, 'SpecHalf', ModifierService.ModifierType.MoneyMultiplier, 1.25)
			RebirthService.RefreshBaseMultiplier(U1)
			expect(labelFor(services.BaseService, U1).Text).to.equal('Mult: 2.5x')
			services.BaseService.CleanupPlayer(U1)
		end)

		it('release hides the label', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			stageAll(services.BaseService)
			local base = services.BaseService.AssignBaseForPlayer(U1)
			expect(base).to.be.ok()
			expect(labelFor(services.BaseService, U1).Visible).to.equal(true)
			services.BaseService.ReleaseBase((base :: any).id)
			local folder = (base :: any).folder
			local part = (folder :: Instance):FindFirstChild('MoneyMultPart') :: Instance
			local surface = part:FindFirstChild('SurfaceGui') :: Instance
			local text = surface:FindFirstChild('TextLabel') :: TextLabel
			expect(text.Visible).to.equal(false)
		end)

		it('cleanup hides the label', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			stageAll(services.BaseService)
			expect(services.BaseService.AssignBaseForPlayer(U1)).to.be.ok()
			local label = labelFor(services.BaseService, U1)
			expect(label.Visible).to.equal(true)
			services.BaseService.CleanupPlayer(U1)
			expect(services.BaseService.GetBaseByOwner(U1)).to.equal(nil)
			expect(label.Visible).to.equal(false)
		end)

		it('reassign shows the new owner value, never the previous one', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			stageAll(services.BaseService)
			local first = services.BaseService.AssignBaseForPlayer(U1)
			expect(first).to.be.ok()
			local baseId = (first :: any).id
			expect(labelFor(services.BaseService, U1).Text).to.equal('Mult: 1x')
			services.BaseService.ReleaseBase(baseId)
			ModifierService.AddModifier(U2, 'Spec3x', ModifierService.ModifierType.MoneyMultiplier, 3)
			expect(services.BaseService.AssignBaseById(U2, baseId)).to.be.ok()
			local label = labelFor(services.BaseService, U2)
			expect(label.Visible).to.equal(true)
			expect(label.Text).to.equal('Mult: 3x')
			services.BaseService.CleanupPlayer(U2)
		end)

		it('unowned refresh/hide are safe no-ops and HideAll conceals everything', function()
			local services = Helpers.WireServices()
			Helpers.EnsureCollectors()
			services.BaseService.RegisterBases(game:GetService('Workspace'))
			local labels = stageAll(services.BaseService)
			for _, label in pairs(labels) do
				label.Visible = true
			end
			RebirthService.RefreshBaseMultiplier(59999)
			RebirthService.HideBaseMultiplier(59999)
			RebirthService.HideAllBaseMultipliers()
			for _, label in pairs(labels) do
				expect(label.Visible).to.equal(false)
			end
		end)

		describe('base spawn ownership', function()
			it('RegisterBases ensures one SpawnLocation per base at the Spawn part CFrame', function()
				local services = Helpers.WireServices()
				Helpers.EnsureCollectors()
				services.BaseService.RegisterBases(game:GetService('Workspace'))
				local all = services.BaseService.GetAllBases()
				for _, b in pairs(all) do
					expect(b.spawnLocation).to.be.ok()
					expect((b.spawnLocation :: Instance):IsA('SpawnLocation')).to.equal(true)
					expect((b.spawnLocation :: Instance).Parent).to.equal(b.folder)
					expect(((b.spawnLocation :: SpawnLocation).CFrame.Position - b.spawnCFrame.Position).Magnitude).to.be.near(
						0,
						0.001
					)
				end
			end)

			it('PointPlayerToBaseSpawn refuses invalid input without touching RespawnLocation', function()
				local services = Helpers.WireServices()
				Helpers.EnsureCollectors()
				services.BaseService.RegisterBases(game:GetService('Workspace'))
				local b = services.BaseService.AssignBaseForPlayer(701)
				expect(b).to.be.ok()
				-- Not a player.
				expect(services.BaseService.PointPlayerToBaseSpawn(nil :: any, b)).to.equal(false)
				expect(services.BaseService.PointPlayerToBaseSpawn(({}) :: any, b)).to.equal(false)
				-- Bad base shapes (a real Player cannot be faked in
				-- specs, so the success path is covered by the
				-- Studio playtest, not here).
				local fakePlayer = Helpers.FakePlayer(701, 'SpawnTest')
				expect(services.BaseService.PointPlayerToBaseSpawn(fakePlayer :: any, nil)).to.equal(false)
				expect(services.BaseService.PointPlayerToBaseSpawn(fakePlayer :: any, {})).to.equal(false)
				expect(services.BaseService.PointPlayerToBaseSpawn(fakePlayer :: any, { id = 123 })).to.equal(false)
				expect(
					services.BaseService.PointPlayerToBaseSpawn(fakePlayer :: any, { id = b.id, spawnLocation = nil })
				).to.equal(false)
			end)
		end)
	end)
end
