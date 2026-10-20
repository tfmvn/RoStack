--!strict
--!native
--[[
	DynamicSlots.spec
	=================
	Dynamic runtime Slot lifecycle (DynamicSlotService +
	BaseService StandPos integration).

	Staged fakes (fully cleaned in afterEach so no other spec
	file can observe them): a ServerStorage
	Assets/Map/Bases/Base/StandTemplate plus StandPos1..8
	markers + empty AnimalStands on every Workspace base.

	Coverage (headless-safe):
	  1. Unassigned dynamic bases hold ZERO slots, validate clean.
	  2. Assign builds exactly 8 Slot<k> clones at the marker
	     transforms with registered p7 slot ids.
	  3. Two assigned bases stay isolated.
	  4. Release destroys every clone, empties slots, keeps
	     StandPos markers, validates clean.
	  5. Rapid assign/release never duplicates or leaks.
	  6. Stale session build/destroy calls change nothing.
	  7. Reconcile preserves live slots (no rebuild churn).
	  8. Missing template fails closed with zero slots.
	  9. StandPos numeric sort (StandPos10 after StandPos9).
]]

return function()
	local Workspace = game:GetService('Workspace')
	local ServerStorage = game:GetService('ServerStorage')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')

	local Helpers = require(script.Parent._Helpers)
	local Bases = require(ReplicatedStorage.Config.World.Bases)
	local StandResolver = require(ReplicatedStorage.Utility.StandResolver)

	local ServerScriptService = game:GetService('ServerScriptService')
	local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)

	local staged: { Instance } = {}

	local function track(inst: Instance): Instance
		staged[#staged + 1] = inst
		return inst
	end

	local function makePart(name: string, parent: Instance, cf: CFrame?): Part
		local p = Instance.new('Part')
		p.Name = name
		p.Size = Vector3.new(3, 1, 3)
		p.Anchored = true
		p.CanCollide = false
		if cf then
			p.CFrame = cf
		end
		p.Parent = parent
		return p
	end

	-- Stand-shaped template (mirrors the Studio asset at
	-- ServerStorage.Assets.Map.Bases.Base.StandTemplate):
	-- Slot{ Root, MenuPart{ MenuGui{ UpgradeButton{ Level, UpgradeAmount } } } }
	-- Button{ PressPart{ SurfaceGui{ Amount } }, Base }
	-- The arena template (Assets.Map.Bases.Base.ArenaStandTemplate)
	-- is staged alongside as a minimal pivotable Model — arena
	-- clones carry no records, so only a physical root matters.
	local function buildTemplate(): Model
		local assets = ServerStorage:FindFirstChild('Assets')
		if not assets then
			assets = track(Instance.new('Folder'))
			assets.Name = 'Assets'
			assets.Parent = ServerStorage
		end
		local map = assets:FindFirstChild('Map')
		if not map then
			map = track(Instance.new('Folder'))
			map.Name = 'Map'
			map.Parent = assets
		end
		local bases = map:FindFirstChild('Bases')
		if not bases then
			bases = track(Instance.new('Folder'))
			bases.Name = 'Bases'
			bases.Parent = map
		end
		local base = bases:FindFirstChild('Base')
		if not base then
			base = track(Instance.new('Folder'))
			base.Name = 'Base'
			base.Parent = bases
		end
		local old = base:FindFirstChild('StandTemplate')
		if old then
			old:Destroy()
		end
		local template = Instance.new('Model')
		template.Name = 'StandTemplate'
		local slotPart = makePart('Slot', template)
		makePart('Root', slotPart)
		local menuPart = makePart('MenuPart', slotPart)
		local menuGui = Instance.new('Folder')
		menuGui.Name = 'MenuGui'
		menuGui.Parent = menuPart
		local button = Instance.new('TextButton')
		button.Name = 'UpgradeButton'
		button.Parent = menuGui
		local level = Instance.new('TextLabel')
		level.Name = 'Level'
		level.Parent = button
		local cost = Instance.new('TextLabel')
		cost.Name = 'UpgradeAmount'
		cost.Parent = button
		local buttonFolder = Instance.new('Folder')
		buttonFolder.Name = 'Button'
		buttonFolder.Parent = template
		local press = makePart('PressPart', buttonFolder)
		local sg = Instance.new('SurfaceGui')
		sg.Name = 'SurfaceGui'
		sg.Parent = press
		local amount = Instance.new('TextLabel')
		amount.Name = 'Amount'
		amount.Parent = sg
		makePart('Base', buttonFolder)
		template.Parent = base
		local oldArena = base:FindFirstChild('ArenaStandTemplate')
		if oldArena then
			oldArena:Destroy()
		end
		local arenaTemplate = Instance.new('Model')
		arenaTemplate.Name = 'ArenaStandTemplate'
		makePart('ArenaRoot', arenaTemplate)
		arenaTemplate.Parent = base
		return template
	end

	local function stageBaseMarkers(baseFolder: Instance)
		local stands = baseFolder:FindFirstChild('AnimalStands')
		if not stands then
			stands = track(Instance.new('Folder'))
			stands.Name = 'AnimalStands'
			stands.Parent = baseFolder
		end
		local markers = baseFolder:FindFirstChild('StandPos')
		if not markers then
			markers = track(Instance.new('Folder'))
			markers.Name = 'StandPos'
			markers.Parent = baseFolder
		end
		for n = 1, 8 do
			local name = 'StandPos' .. tostring(n)
			if not markers:FindFirstChild(name) then
				track(makePart(name, markers, CFrame.new(n * 10, 3, n * 5) * CFrame.Angles(0, math.rad(n * 15), 0)))
			end
		end
		local arenaStands = baseFolder:FindFirstChild('ArenaAnimalStands')
		if not arenaStands then
			arenaStands = track(Instance.new('Folder'))
			arenaStands.Name = 'ArenaAnimalStands'
			arenaStands.Parent = baseFolder
		end
		local arenaMarkers = baseFolder:FindFirstChild('ArenaStandPos')
		if not arenaMarkers then
			arenaMarkers = track(Instance.new('Folder'))
			arenaMarkers.Name = 'ArenaStandPos'
			arenaMarkers.Parent = baseFolder
		end
		for n = 1, 8 do
			local name = 'ArenaStandPos' .. tostring(n)
			if not arenaMarkers:FindFirstChild(name) then
				track(
					makePart(
						name,
						arenaMarkers,
						CFrame.new(n * 10 + 100, 3, n * 5) * CFrame.Angles(0, math.rad(n * 20), 0)
					)
				)
			end
		end
	end

	local function arenaClones(baseFolder: Instance): { Instance }
		local out: { Instance } = {}
		local container = baseFolder:FindFirstChild('ArenaAnimalStands')
		if container then
			for _, child in ipairs(container:GetChildren()) do
				if StandResolver.ParseArenaStandIndex(child.Name) ~= nil then
					out[#out + 1] = child
				end
			end
		end
		return out
	end

	local function standClones(baseFolder: Instance): { Instance }
		local out: { Instance } = {}
		local stands = baseFolder:FindFirstChild('AnimalStands')
		if stands then
			for _, child in ipairs(stands:GetChildren()) do
				if StandResolver.ParseSlotIndex(child.Name) ~= nil then
					out[#out + 1] = child
				end
			end
		end
		return out
	end

	local function setup()
		local services = Helpers.WireServices()
		Helpers.EnsureCollectors()
		buildTemplate()
		local bases = Workspace:FindFirstChild('Bases')
		if bases then
			for _, baseFolder in ipairs(bases:GetChildren()) do
				if baseFolder:IsA('Folder') then
					stageBaseMarkers(baseFolder)
				end
			end
		end
		services.BaseService.RegisterBases(Workspace)
		return services
	end

	describe('DynamicSlots', function()
		beforeEach(function()
			Helpers.StubRemotes()
			DynamicSlotService._TestReset()
		end)

		afterEach(function()
			DynamicSlotService._TestReset()
			for i = #staged, 1, -1 do
				pcall(function()
					staged[i]:Destroy()
				end)
				staged[i] = nil
			end
			-- Belt-and-braces: no Slot/ArenaStand clones may leak
			-- into other spec files' RegisterBases runs.
			local bases = Workspace:FindFirstChild('Bases')
			if bases then
				for _, baseFolder in ipairs(bases:GetChildren()) do
					local stands = baseFolder:FindFirstChild('AnimalStands')
					if stands then
						for _, child in ipairs(stands:GetChildren()) do
							if StandResolver.ParseSlotIndex(child.Name) ~= nil then
								pcall(function()
									child:Destroy()
								end)
							end
						end
					end
					local arena = baseFolder:FindFirstChild('ArenaAnimalStands')
					if arena then
						for _, child in ipairs(arena:GetChildren()) do
							if StandResolver.ParseArenaStandIndex(child.Name) ~= nil then
								pcall(function()
									child:Destroy()
								end)
							end
						end
					end
				end
			end
		end)

		it('unassigned dynamic bases hold ZERO slots and validate clean', function()
			local services = setup()
			for _, base in pairs(services.BaseService.GetAllBases()) do
				if base.dynamicSlots then
					expect(#base.slots).to.equal(0)
					expect(#standClones(base.folder)).to.equal(0)
					expect(services.BaseService.ValidateBaseRuntime(base.id)).to.equal(true)
				end
			end
		end)

		it('assign builds 8 clones at marker transforms with registered ids', function()
			local services = setup()
			local userId = 9401
			local base = services.BaseService.AssignBaseForPlayer(userId)
			expect(base).to.be.ok()
			expect(base.dynamicSlots).to.equal(true)
			local clones = standClones(base.folder)
			expect(#clones).to.equal(8)
			expect(#base.slots).to.equal(8)
			local markers = StandResolver.GetStandPosSorted(base.folder)
			expect(#markers).to.equal(8)
			for n = 1, 8 do
				local clone = base.folder.AnimalStands:FindFirstChild('Slot' .. tostring(n))
				assert(clone ~= nil, 'Slot' .. tostring(n) .. ' present')
				local marker = markers[n]
				local cp = (clone :: Instance):GetPivot().Position
				local mp = (marker :: BasePart).Position
				expect((cp - mp).Magnitude < 0.01).to.equal(true)
				-- Rotation preserved: identical look vectors.
				local cl = (clone :: Instance):GetPivot().LookVector
				local ml = (marker :: BasePart).CFrame.LookVector
				expect((cl - ml).Magnitude < 0.01).to.equal(true)
				-- Slot record registered under the stable SlotId.
				local wantId = 'p7:' .. tostring(userId) .. ':slot:' .. tostring(n)
				expect(base.slots[n].id).to.equal(wantId)
				local found = services.SlotService._findSlotById(wantId)
				expect(found).to.be.ok()
				expect(found.index).to.equal(n)
				-- Consumers resolve: physical root + cash trigger.
				expect(base.slots[n].part).to.be.ok()
				expect(base.slots[n].cashCollector).to.be.ok()
			end
			services.BaseService.CleanupPlayer(userId)
		end)

		it('two assigned bases stay isolated', function()
			local services = setup()
			local a = services.BaseService.AssignBaseForPlayer(9402)
			local b = services.BaseService.AssignBaseForPlayer(9403)
			expect(a).to.be.ok()
			expect(b).to.be.ok()
			expect(a.id ~= b.id).to.equal(true)
			expect(#standClones(a.folder)).to.equal(8)
			expect(#standClones(b.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9402)
			expect(#standClones(a.folder)).to.equal(0)
			expect(#a.slots).to.equal(0)
			expect(#standClones(b.folder)).to.equal(8)
			expect(#b.slots).to.equal(8)
			expect(services.BaseService.ValidateBaseRuntime(b.id)).to.equal(true)
			services.BaseService.CleanupPlayer(9403)
		end)

		it('release destroys clones, keeps markers, validates clean', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9404)
			local folder = base.folder
			services.BaseService.ReleaseBase(base.id, 9404)
			expect(#standClones(folder)).to.equal(0)
			local fresh = services.BaseService.GetBaseById(base.id)
			expect(#fresh.slots).to.equal(0)
			-- Static markers + shell survive.
			local markers = StandResolver.GetStandPosSorted(folder)
			expect(#markers).to.equal(8)
			expect(services.BaseService.ValidateBaseRuntime(base.id)).to.equal(true)
		end)

		it('rapid assign/release never duplicates or leaks', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9405)
			local bid = base.id
			local folder = base.folder
			local last = services.BaseService.GetSession(bid)
			for _ = 1, 3 do
				services.BaseService.ReleaseBase(bid, 9405)
				expect(#standClones(folder)).to.equal(0)
				local now = services.BaseService.GetSession(bid)
				expect(now > last).to.equal(true)
				last = now
				local nb = services.BaseService.AssignBaseById(9405, bid)
				expect(nb).to.be.ok()
				expect(#standClones(folder)).to.equal(8)
				expect(services.BaseService.GetSession(bid) > last).to.equal(true)
				last = services.BaseService.GetSession(bid)
			end
			services.BaseService.CleanupPlayer(9405)
			expect(#standClones(folder)).to.equal(0)
		end)

		it('stale session build/destroy calls change nothing', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9406)
			local bid = base.id
			local live = services.BaseService.GetSession(bid)
			services.BaseService.ReleaseBase(bid, 9406)
			-- Late build from the pre-release session is refused.
			local built = DynamicSlotService.BuildBaseSlots(base, 9406, live)
			expect(built).to.equal(0)
			expect(#standClones(base.folder)).to.equal(0)
			-- Late destroy from the pre-release session is refused.
			local nb = services.BaseService.AssignBaseById(9407, bid)
			expect(nb).to.be.ok()
			local destroyed = DynamicSlotService.DestroyBaseSlots(nb, live)
			expect(destroyed).to.equal(0)
			expect(#standClones(nb.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9407)
		end)

		it('reconcile preserves live slots without churn', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9408)
			local before: { Instance } = {}
			for _, c in ipairs(standClones(base.folder)) do
				before[#before + 1] = c
			end
			expect(#before).to.equal(8)
			local count = DynamicSlotService.ReconcileBaseSlots(base, 9408, base.session)
			expect(count).to.equal(8)
			local afterClones = standClones(base.folder)
			expect(#afterClones).to.equal(8)
			for _, c in ipairs(before) do
				local still = false
				for _, d in ipairs(afterClones) do
					if c == d then
						still = true
						break
					end
				end
				expect(still).to.equal(true)
			end
			services.BaseService.CleanupPlayer(9408)
		end)

		it('missing template fails closed with zero slots', function()
			local services = setup()
			local assets = ServerStorage:FindFirstChild('Assets')
			assert(assets ~= nil, 'staged Assets present')
			assets:Destroy()
			DynamicSlotService._TestReset()
			local base = services.BaseService.AssignBaseForPlayer(9409)
			expect(base).to.be.ok()
			expect(#base.slots).to.equal(0)
			expect(#standClones(base.folder)).to.equal(0)
			services.BaseService.CleanupPlayer(9409)
		end)

		it('StandPos markers sort numerically, not alphabetically', function()
			local folder = Instance.new('Folder')
			local markers = Instance.new('Folder')
			markers.Name = 'StandPos'
			markers.Parent = folder
			for _, name in ipairs({ 'StandPos2', 'StandPos10', 'StandPos1' }) do
				local p = Instance.new('Part')
				p.Name = name
				p.Parent = markers
			end
			track(folder)
			local sorted = StandResolver.GetStandPosSorted(folder)
			expect(#sorted).to.equal(3)
			expect(sorted[1].Name).to.equal('StandPos1')
			expect(sorted[2].Name).to.equal('StandPos2')
			expect(sorted[3].Name).to.equal('StandPos10')
			expect(StandResolver.ParseStandPosIndex('StandPos7')).to.equal(7)
			expect(StandResolver.ParseStandPosIndex('Standby')).to.equal(nil)
		end)

		it('desired slot count is bounded by markers and SlotCount', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9410)
			local want = DynamicSlotService.GetDesiredSlotCount(base.folder, 9410)
			expect(want).to.equal(math.min(8, Bases.Slots.Count))
			services.BaseService.CleanupPlayer(9410)
		end)

		it('assign builds 8 arena stands at marker transforms', function()
			local services = setup()
			local userId = 9411
			local base = services.BaseService.AssignBaseForPlayer(userId)
			expect(base).to.be.ok()
			local clones = arenaClones(base.folder)
			expect(#clones).to.equal(8)
			local markers = StandResolver.GetArenaStandPosSorted(base.folder)
			expect(#markers).to.equal(8)
			for n = 1, 8 do
				local clone = base.folder.ArenaAnimalStands:FindFirstChild('ArenaStand' .. tostring(n))
				assert(clone ~= nil, 'ArenaStand' .. tostring(n) .. ' present')
				local marker = markers[n]
				local cp = (clone :: Instance):GetPivot().Position
				local mp = (marker :: BasePart).Position
				expect((cp - mp).Magnitude < 0.01).to.equal(true)
				-- Arena clones NEVER register as Slots: exactly the 8
				-- normal slot records exist for this base.
				local registered = 0
				for _, s in pairs(services.SlotService._dump()) do
					if type(s) == 'table' and s.baseId == base.id then
						registered += 1
					end
				end
				expect(registered).to.equal(8)
			end
			-- Normal slots co-exist untouched.
			expect(#standClones(base.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(userId)
		end)

		it('release empties arena stands, keeps markers, validates clean', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9412)
			local folder = base.folder
			expect(#arenaClones(folder)).to.equal(8)
			services.BaseService.ReleaseBase(base.id, 9412)
			expect(#arenaClones(folder)).to.equal(0)
			expect(#StandResolver.GetArenaStandPosSorted(folder)).to.equal(8)
			expect(services.BaseService.ValidateBaseRuntime(base.id)).to.equal(true)
		end)

		it('arena stands are isolated per base and survive slot churn', function()
			local services = setup()
			local a = services.BaseService.AssignBaseForPlayer(9413)
			local b = services.BaseService.AssignBaseForPlayer(9414)
			expect(#arenaClones(a.folder)).to.equal(8)
			expect(#arenaClones(b.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9413)
			expect(#arenaClones(a.folder)).to.equal(0)
			expect(#arenaClones(b.folder)).to.equal(8)
			-- Rapid reassign rebuilds fresh arena instances.
			local raised = services.BaseService.AssignBaseById(9415, a.id)
			expect(#arenaClones(raised.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9414)
			services.BaseService.CleanupPlayer(9415)
			expect(#arenaClones(a.folder)).to.equal(0)
			expect(#arenaClones(b.folder)).to.equal(0)
		end)

		it('stale session arena calls change nothing', function()
			local services = setup()
			local base = services.BaseService.AssignBaseForPlayer(9416)
			local bid = base.id
			local live = services.BaseService.GetSession(bid)
			services.BaseService.ReleaseBase(bid, 9416)
			expect(DynamicSlotService.BuildArenaStands(base, 9416, live)).to.equal(0)
			expect(#arenaClones(base.folder)).to.equal(0)
			local nb = services.BaseService.AssignBaseById(9417, bid)
			expect(DynamicSlotService.DestroyArenaStands(nb, live)).to.equal(0)
			expect(#arenaClones(nb.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9417)
		end)

		it('missing arena template fails closed, slots still build', function()
			local services = setup()
			local assets = ServerStorage:FindFirstChild('Assets')
			assert(assets ~= nil, 'staged Assets present')
			local map = assets:FindFirstChild('Map')
			assert(map ~= nil, 'staged Map present')
			local bases = map:FindFirstChild('Bases')
			assert(bases ~= nil, 'staged Bases present')
			local baseFolder = bases:FindFirstChild('Base')
			assert(baseFolder ~= nil, 'staged Base present')
			local arenaTemplate = baseFolder:FindFirstChild('ArenaStandTemplate')
			assert(arenaTemplate ~= nil, 'staged arena template present')
			arenaTemplate:Destroy()
			DynamicSlotService._TestReset()
			local base = services.BaseService.AssignBaseForPlayer(9418)
			expect(base).to.be.ok()
			expect(#arenaClones(base.folder)).to.equal(0)
			-- Normal slots are independent of the arena template.
			expect(#standClones(base.folder)).to.equal(8)
			services.BaseService.CleanupPlayer(9418)
		end)
	end)
end
