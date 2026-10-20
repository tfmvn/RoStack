--!strict
--!native
--[[
	EventService.spec
	=================
	Tests for the generic world-event engine
	(ServerScriptService/Event/EventService.lua) + EventConfig.

	Covers headlessly:
	  * EventConfig.Validate() is clean (single source of truth).
	  * Base/Galaxy/Snowfall settings (durations, chances,
	    mutation ids + chances, asset folders, time overrides,
	    Snowfall map targets).
	  * Base is never scheduled/started.
	  * Weighted scheduler picks (deterministic rollOverride):
	    20/20/60 split -> Galaxy / Snowfall / normal cycle.
	  * Mutation chance gate boundaries.
	  * Countdown formatting (M:SS).
	  * Lifecycle guards: unknown + Base ids rejected, double
	    EndEvent is a safe no-op, starting the active event is
	    rejected, replace-rule ends the previous event first.
  * Real one-time mutation flow: StartEvent(Galaxy) ->
    TryMutateEgg stamps Galactic once (re-roll refused,
    already-mutated egg protected) -> EndEvent keeps the
    mutation (persistence, not temp state).
  * Client text states (ACTIVE / IN countdown / NORMAL).
  * Start/stop transition broadcast: ONE Prepare + ONE Reveal
    per genuine transition (server-wide cinematic signaling),
    replace rides a single Start transition (never an End
    flash), duplicates rejected without extra broadcasts,
    TransitionIds increment, idle after every path.

	No threads are started here (never Start()); the scheduler
	loop itself is production-wired in bootstrap.server.
	Studio-only paths (asset clone into Workspace, real map
	recolor, BillboardGui paint) are fail-safe reviewed, not
	live-run — the test place has no Map/CenterPart/Event
	asset folders.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local StarterPlayer = game:GetService('StarterPlayer')
	local Workspace = game:GetService('Workspace')
	local Lighting = game:GetService('Lighting')

	local EventService = require(ServerScriptService.Event.EventService)
	local EnvironmentModifier = require(ServerScriptService.Event.EnvironmentModifier)
	local EventLights = require(ServerScriptService.Event.EventLights)
	local EventConfig = require(ReplicatedStorage.Config.World.Events)
	local MutationConfig = require(ReplicatedStorage.Config.Creatures.Mutations)
	local TraitService = require(ServerScriptService.TraitService)
	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local CenterPartBillboards = require(ReplicatedStorage.Utility.CenterPartBillboards)
	local EventController = require(StarterPlayer.StarterPlayerScripts.EventController)

	-- Same convention as EggLifecycle.spec: the SpawnService
	-- registry is shared module state, so StartEvent sweeps
	-- (real RNG) must see an empty registry here — otherwise
	-- a leftover egg could gain a test mutation.
	local function cleanSlate()
		EventService._TestReset()
		-- Lifecycle tests assert sequencing, not wall-clock
		-- cover: skip the transition gate (broadcasts still
		-- fire in order).
		EventService._TestSetTransitionCover(0)
		for _, b in ipairs(SpawnService.AllEggs()) do
			if b.model then
				pcall(function()
					(b.model :: Model):Destroy()
				end)
			end
			SpawnService.DropEgg(b.uniqueId)
		end
	end

	describe('EventConfig', function()
		it('validates clean (single source of truth)', function()
			local issues = EventConfig.Validate()
			expect(#issues).to.equal(0)
		end)

		it('Base is the non-startable normal baseline', function()
			local base = EventConfig.Events.Base
			expect(base.Id).to.equal('Base')
			expect(base.Scheduling.Enabled).to.equal(false)
			expect(base.Scheduling.Weight).to.equal(0)
			expect(EventService.IsStartable('Base')).to.equal(false)
		end)

		it('Galaxy settings (duration, chance, mutation, assets, night)', function()
			local galaxy = EventConfig.Events.Galaxy
			expect(galaxy.DurationSeconds).to.equal(180)
			expect(galaxy.MutationIntervalSeconds).to.equal(30)
			expect(galaxy.Scheduling.Enabled).to.equal(true)
			expect(galaxy.Scheduling.Weight).to.equal(20)
			expect(galaxy.Mutations.Galactic.MutationId).to.equal('Galactic')
			-- Chance is designer-tuned (assert contract, not value).
			expect(galaxy.Mutations.Galactic.Chance > 0).to.equal(true)
			expect(galaxy.Mutations.Galactic.Chance <= 1).to.equal(true)
			expect(galaxy.Assets.FolderName).to.equal('Galaxy')
			expect(galaxy.Time.Override).to.equal(true)
			expect(galaxy.Time.ClockTime).to.equal(0)
			expect(MutationConfig.Get('Galactic') ~= nil).to.equal(true)
		end)

		it('Snowfall settings (duration, chance, mutation, assets, day, map targets)', function()
			local snowfall = EventConfig.Events.Snowfall
			expect(snowfall.DurationSeconds).to.equal(180)
			expect(snowfall.MutationIntervalSeconds).to.equal(30)
			expect(snowfall.Scheduling.Enabled).to.equal(true)
			expect(snowfall.Scheduling.Weight).to.equal(20)
			expect(snowfall.Mutations.Frost.MutationId).to.equal('Frost')
			expect(snowfall.Mutations.Frost.Chance > 0).to.equal(true)
			expect(snowfall.Mutations.Frost.Chance <= 1).to.equal(true)
			expect(snowfall.Assets.FolderName).to.equal('Snowfall')
			expect(snowfall.Time.Override).to.equal(true)
			expect(MutationConfig.Get('Frost') ~= nil).to.equal(true)
			local colors = snowfall.Environment.Colors
			expect(type(colors.Gray)).to.equal('table')
			expect(type(colors.White)).to.equal('table')
			local function has(targets: { string }, want: string): boolean
				for _, t in ipairs(targets) do
					if t == want then
						return true
					end
				end
				return false
			end
			expect(has(colors.Gray.Targets, 'Map.MainIsland.Paths')).to.equal(true)
			expect(has(colors.Gray.Targets, 'Base.Build.Paths')).to.equal(true)
			expect(has(colors.White.Targets, 'Map.MainIsland.Island.Grass')).to.equal(true)
			expect(has(colors.White.Targets, 'Map.MainIsland.Decor.Grass')).to.equal(true)
			expect(has(colors.White.Targets, 'Base.Build.Island.Grass')).to.equal(true)
			-- Wildcard: Bush under EVERY Lamp (never a Lamp literal).
			expect(has(colors.White.Targets, 'Base.Build.Lamps.*.Bush')).to.equal(true)
			expect(has(colors.White.Targets, 'Base.Build.Lamps.Lamp.Bush')).to.equal(false)
		end)

		it('Transition cinematic settings (single source for server gate + client animation)', function()
			local transition = EventConfig.Transition
			expect(type(transition)).to.equal('table')
			expect(transition.FovMultiplier).to.equal(0.83)
			expect(transition.FovSeconds).to.equal(0.35)
			expect(transition.FlashDelaySeconds).to.equal(0.05)
			expect(transition.FlashInSeconds).to.equal(0.3)
			expect(transition.HoldSeconds).to.equal(0.3)
			expect(transition.FadeOutSeconds).to.equal(1)
			expect(transition.CoverSeconds).to.equal(0.65)
			-- The gate covers flash-delay + flash-in + hold.
			expect(
				transition.CoverSeconds
					>= transition.FlashDelaySeconds + transition.FlashInSeconds + transition.HoldSeconds
			).to.equal(true)
		end)
	end)

	describe('EventService.PickNextEventId', function()
		it('splits 20/20/60 across Galaxy/Snowfall/normal', function()
			-- Total weight 100: [0,20) Galaxy, [20,40) Snowfall, else normal.
			expect(EventService.PickNextEventId(0)).to.equal('Galaxy')
			expect(EventService.PickNextEventId(0.19)).to.equal('Galaxy')
			expect(EventService.PickNextEventId(0.2)).to.equal('Snowfall')
			expect(EventService.PickNextEventId(0.39)).to.equal('Snowfall')
			expect(EventService.PickNextEventId(0.4)).to.equal(nil)
			expect(EventService.PickNextEventId(0.99)).to.equal(nil)
		end)
	end)

	describe('EventService.RollMutationChance', function()
		it('gates on boundaries (0 never, 1 always)', function()
			expect(EventService.RollMutationChance(0, 0)).to.equal(false)
			expect(EventService.RollMutationChance(1, 0.999)).to.equal(true)
			expect(EventService.RollMutationChance(0.05, 0)).to.equal(true)
			expect(EventService.RollMutationChance(0.05, 0.5)).to.equal(false)
			expect(EventService.RollMutationChance('nope', 0)).to.equal(false)
		end)
	end)

	describe('EventService.FormatCountdown', function()
		it('formats M:SS like the UI examples', function()
			expect(EventService.FormatCountdown(300)).to.equal('5:00')
			expect(EventService.FormatCountdown(65)).to.equal('1:05')
			expect(EventService.FormatCountdown(0)).to.equal('0:00')
			expect(EventService.FormatCountdown(-9)).to.equal('0:00')
		end)
	end)

	describe('EventService lifecycle guards', function()
		it('rejects unknown and Base ids, double-end is a safe no-op', function()
			EventService._TestReset()
			local ok, reason = EventService.StartEvent('Volcano', 'test')
			expect(ok).to.equal(false)
			expect(type(reason)).to.equal('string')
			local okBase, _ = EventService.StartEvent('Base', 'test')
			expect(okBase).to.equal(false)
			expect(EventService.GetCurrentEvent()).to.equal(nil)
			expect(EventService.EndEvent('test')).to.equal(true)
			expect(EventService.EndEvent('test')).to.equal(true)
		end)

		it('progressive mutation: nothing at start, cycles roll, retries allowed, protection holds', function()
			cleanSlate()
			local clockBefore = Lighting.ClockTime
			local ok, reason = EventService.StartEvent('Galaxy', 'test')
			expect(ok).to.equal(true)
			local current = EventService.GetCurrentEvent()
			expect(current ~= nil and current.Id).to.equal('Galaxy')
			-- Galaxy forces night while active.
			expect(Lighting.ClockTime).to.equal(0)
			-- Start does NOT mutate: a fresh egg is still plain.
			local egg: any = { uniqueId = 'evt-test-1', state = 'Available', Mutations = {} }
			expect(#egg.Mutations).to.equal(0)
			-- A failing cycle changes nothing but stays eligible.
			expect(EventService.TryMutateEgg(egg, 1)).to.equal(false)
			expect(#egg.Mutations).to.equal(0)
			-- A later cycle succeeds (progressive, not start-burst).
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(true)
			expect(#egg.Mutations).to.equal(1)
			expect(egg.Mutations[1]).to.equal('Galactic')
			-- Fresh eligible BASE egg (Placed): same cycle path.
			local stored: any = { uniqueId = 'evt-test-4', state = 'Placed', Mutations = {} }
			expect(EventService.TryMutateEgg(stored, 0)).to.equal(true)
			expect(stored.Mutations[1]).to.equal('Galactic')
			-- Mutated eggs are protected from overwrite forever.
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(false)
			expect(egg.Mutations[1]).to.equal('Galactic')
			-- Already-mutated eggs are protected from overwrite.
			local frosted: any = { uniqueId = 'evt-test-2', state = 'Placed', Mutations = { 'Frost' } }
			expect(EventService.TryMutateEgg(frosted, 0)).to.equal(false)
			expect(frosted.Mutations[1]).to.equal('Frost')
			-- Consumed eggs never roll.
			local gone: any = { uniqueId = 'evt-test-3', state = 'Consumed', Mutations = {} }
			expect(EventService.TryMutateEgg(gone, 0)).to.equal(false)
			-- End keeps the persistent mutation (temp state only clears).
			expect(EventService.EndEvent('test')).to.equal(true)
			expect(EventService.GetCurrentEvent()).to.equal(nil)
			expect(egg.Mutations[1]).to.equal('Galactic')
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(false)
			-- Time restored to the pre-event value.
			expect(Lighting.ClockTime).to.equal(clockBefore)
			EventService._TestReset()
		end)

		it('mutated eggs inherit 100% through the canonical hatch pipeline', function()
			-- The open path copies via TraitService.ResolveInheritance
			-- (HatchEgg + CreateFromEgg) — the new event ids must
			-- survive sanitizing, never roll again at hatch.
			local inheritance = TraitService.ResolveInheritance(nil, { 'Galactic' }, 0)
			expect(#inheritance.Mutations).to.equal(1)
			expect(inheritance.Mutations[1]).to.equal('Galactic')
			local frost = TraitService.ResolveInheritance(nil, { 'Frost' }, 0)
			expect(frost.Mutations[1]).to.equal('Frost')
		end)

		it('environment: recursive apply, config-driven pickup, exact restore', function()
			-- Fully UNPARENTED fake map (zero Workspace
			-- pollution): nested parts prove depth-independent
			-- resolution through the injected map root.
			local fakeMap = Instance.new('Folder')
			fakeMap.Name = 'Map'
			local root = Instance.new('Folder')
			root.Name = 'EventSpecProbe'
			root.Parent = fakeMap
			local mid = Instance.new('Model')
			mid.Name = 'Mid'
			mid.Parent = root
			local inner = Instance.new('Folder')
			inner.Name = 'Inner'
			inner.Parent = mid
			local part = Instance.new('Part')
			part.Color = Color3.fromRGB(10, 20, 30)
			part.Parent = inner
			local part2 = Instance.new('Part')
			part2.Color = Color3.fromRGB(40, 50, 60)
			part2.Parent = root
			local opts = { mapRoot = fakeMap, baseRoots = {} }
			local function cleanup()
				pcall(function()
					fakeMap:Destroy()
				end)
			end
			-- Invalid targets must not crash nor block valid ones.
			local snap = EnvironmentModifier.ApplyColors({
				Probe = {
					Color = Color3.fromRGB(255, 0, 0),
					Targets = { 'Map.EventSpecProbe', 'Map.NoSuchThing', 'Bogus.Scope' },
				},
			}, opts)
			expect(part.Color).to.equal(Color3.fromRGB(255, 0, 0))
			expect(part2.Color).to.equal(Color3.fromRGB(255, 0, 0))
			-- Config-driven pickup: a second category with a NEW
			-- path applies with zero engine changes.
			local probe2 = Instance.new('Part')
			probe2.Color = Color3.fromRGB(1, 2, 3)
			probe2.Name = 'ExtraProbe'
			probe2.Parent = fakeMap
			local snap2 = EnvironmentModifier.ApplyColors({
				Extra = {
					Color = Color3.fromRGB(0, 255, 0),
					Targets = { 'Map.ExtraProbe' },
				},
			}, opts)
			expect(probe2.Color).to.equal(Color3.fromRGB(0, 255, 0))
			-- Exact restore (originals, not assumed defaults).
			EnvironmentModifier.Restore(snap)
			expect(part.Color).to.equal(Color3.fromRGB(10, 20, 30))
			expect(part2.Color).to.equal(Color3.fromRGB(40, 50, 60))
			-- Idempotent: second restore is a no-op, never throws.
			EnvironmentModifier.Restore(snap)
			expect(part.Color).to.equal(Color3.fromRGB(10, 20, 30))
			EnvironmentModifier.Restore(snap2)
			expect(probe2.Color).to.equal(Color3.fromRGB(1, 2, 3))
			cleanup()
		end)

		it('one-at-a-time: starting Snowfall replaces Galaxy through cleanup', function()
			cleanSlate()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			expect(EventService.StartEvent('Snowfall', 'test')).to.equal(true)
			local current = EventService.GetCurrentEvent()
			expect(current ~= nil and current.Id).to.equal('Snowfall')
			expect(EventService.EndEvent('test')).to.equal(true)
			EventService._TestReset()
		end)
	end)

	describe('EnvironmentModifier recursive roots', function()
		-- Mirrors the required example trees 1:1 (unparented —
		-- zero Workspace pollution). Every count below is
		-- derived from the built tree, not hardcoded.
		local function mkPart(parent: Instance, color: Color3): BasePart
			local p = Instance.new('Part')
			p.Color = color
			p.Parent = parent
			return p
		end
		local function mkMesh(parent: Instance): BasePart
			local m = Instance.new('MeshPart')
			m.Color = Color3.fromRGB(20, 20, 20)
			m.Parent = parent
			return m
		end
		local function mkUnion(parent: Instance): BasePart
			local ok, made = pcall(Instance.new, 'UnionOperation')
			local inst: BasePart
			if ok and typeof(made) == 'Instance' and (made :: Instance):IsA('BasePart') then
				inst = made :: BasePart
			else
				inst = Instance.new('Part')
			end
			inst.Color = Color3.fromRGB(30, 30, 30)
			inst.Parent = parent
			return inst
		end
		local function mkFolder(parent: Instance?, name: string): Instance
			local f = Instance.new('Folder')
			f.Name = name
			f.Parent = parent
			return f
		end
		local function mkModel(parent: Instance?, name: string): Instance
			local m = Instance.new('Model')
			m.Name = name
			m.Parent = parent
			return m
		end

		it('Paths collects every nested BasePart; Grass works as Part-root and container', function()
			local all: { BasePart } = {}
			local fakeMap = mkFolder(nil, 'Map')
			local island = mkFolder(nil, 'MainIsland')
			island.Parent = fakeMap
			local paths = mkFolder(island, 'Paths')
			all[#all + 1] = mkPart(paths, Color3.fromRGB(1, 1, 1))
			all[#all + 1] = mkPart(paths, Color3.fromRGB(2, 2, 2))
			local folder = mkFolder(paths, 'Folder')
			all[#all + 1] = mkPart(folder, Color3.fromRGB(3, 3, 3))
			all[#all + 1] = mkPart(folder, Color3.fromRGB(4, 4, 4))
			local model = mkModel(paths, 'Model')
			all[#all + 1] = mkMesh(model)
			all[#all + 1] = mkPart(model, Color3.fromRGB(5, 5, 5))
			local another = mkFolder(paths, 'AnotherFolder')
			local innerModel = mkModel(another, 'Model')
			all[#all + 1] = mkUnion(innerModel)
			local islandInner = mkFolder(island, 'Island')
			-- Grass-as-Part: the ROOT itself is renderable.
			local grassPart = mkPart(islandInner, Color3.fromRGB(10, 200, 10))
			grassPart.Name = 'Grass'
			local decor = mkFolder(island, 'Decor')
			-- Grass-as-container: renderables underneath.
			local grassFolder = mkFolder(decor, 'Grass')
			all[#all + 1] = mkPart(grassFolder, Color3.fromRGB(11, 201, 11))
			all[#all + 1] = mkMesh(grassFolder)
			local opts = { mapRoot = fakeMap, baseRoots = {} }
			local function cleanup()
				pcall(function()
					fakeMap:Destroy()
				end)
			end
			-- 7 renderables under Paths at mixed depths/classes.
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.Paths', fakeMap, {})).to.equal(7)
			-- Part-root: root itself counts (GetDescendants alone
			-- would find 0).
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.Island.Grass', fakeMap, {})).to.equal(1)
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.Decor.Grass', fakeMap, {})).to.equal(2)
			-- Same generic path paints all three targets (no
			-- per-path branches anywhere in the module).
			local snap = EnvironmentModifier.ApplyColors({
				Gray = { Color = Color3.fromRGB(170, 170, 170), Targets = { 'Map.MainIsland.Paths' } },
				White = {
					Color = Color3.fromRGB(255, 255, 255),
					Targets = { 'Map.MainIsland.Island.Grass', 'Map.MainIsland.Decor.Grass' },
				},
			}, opts)
			expect(#snap.entries).to.equal(7 + 1 + 2)
			for _, p in ipairs(all) do
				expect(p.Color).to.equal(Color3.fromRGB(170, 170, 170))
			end
			-- The Grass Part-root itself was painted (not skipped).
			expect(grassPart.Color).to.equal(Color3.fromRGB(255, 255, 255))
			EnvironmentModifier.Restore(snap)
			expect(grassPart.Color).to.equal(Color3.fromRGB(10, 200, 10))
			local i = 0
			for _, p in ipairs(all) do
				i += 1
				expect(p.Color == Color3.fromRGB(170, 170, 170)).to.equal(false)
			end
			expect(i).to.equal(#all)
			cleanup()
		end)

		it('Base fan-out hits every base; future paths resolve with zero engine changes', function()
			local fakeBases: { Instance } = {}
			local originals: { { part: BasePart, color: Color3 } } = {}
			local function track(part: BasePart)
				originals[#originals + 1] = { part = part, color = part.Color }
			end
			-- Base_1: Paths{ Part, Folder{ MeshPart } }.
			local b1 = mkFolder(nil, 'Base_1')
			local build1 = mkFolder(b1, 'Build')
			local paths1 = mkFolder(build1, 'Paths')
			track(mkPart(paths1, Color3.fromRGB(51, 1, 1)))
			local sub1 = mkFolder(paths1, 'Folder')
			track(mkMesh(sub1))
			-- Base_2: Paths{ Part, Model{ Union } }.
			local b2 = mkFolder(nil, 'Base_2')
			local paths2 = mkFolder(mkFolder(b2, 'Build'), 'Paths')
			track(mkPart(paths2, Color3.fromRGB(52, 2, 2)))
			track(mkUnion(mkModel(paths2, 'Model')))
			-- Base_3: Paths{ Model{ Part } } + Lamps.Lamp.Bush{ Part, MeshPart }.
			local b3 = mkFolder(nil, 'Base_3')
			local build3 = mkFolder(b3, 'Build')
			track(mkPart(mkModel(mkFolder(build3, 'Paths'), 'Model'), Color3.fromRGB(53, 3, 3)))
			local lamp = mkModel(mkFolder(build3, 'Lamps'), 'Lamp')
			local bush = mkFolder(lamp, 'Bush')
			track(mkPart(bush, Color3.fromRGB(54, 4, 4)))
			track(mkMesh(bush))
			-- Only Base_1 carries Island.Grass (partial coverage
			-- must not crash the others).
			local islandGrass = mkPart(mkFolder(build1, 'Island'), Color3.fromRGB(55, 5, 5))
			islandGrass.Name = 'Grass'
			track(islandGrass)
			fakeBases = { b1, b2, b3 }
			local opts = { mapRoot = nil, baseRoots = fakeBases }
			local function cleanup()
				for _, b in ipairs(fakeBases) do
					pcall(function()
						(b :: Instance):Destroy()
					end)
				end
			end
			-- 2 + 2 + 1 across three bases, one generic target.
			expect(EnvironmentModifier._TestResolveCount('Base.Build.Paths', nil, fakeBases)).to.equal(5)
			expect(EnvironmentModifier._TestResolveCount('Base.Build.Island.Grass', nil, fakeBases)).to.equal(1)
			expect(EnvironmentModifier._TestResolveCount('Base.Build.Lamps.Lamp.Bush', nil, fakeBases)).to.equal(2)
			local snap = EnvironmentModifier.ApplyColors({
				Gray = { Color = Color3.fromRGB(170, 170, 170), Targets = { 'Base.Build.Paths' } },
				White = {
					Color = Color3.fromRGB(255, 255, 255),
					Targets = { 'Base.Build.Island.Grass', 'Base.Build.Lamps.Lamp.Bush' },
				},
			}, opts)
			expect(#snap.entries).to.equal(5 + 1 + 2)
			for _, row in ipairs(originals) do
				local c = row.part.Color
				local painted = c == Color3.fromRGB(170, 170, 170) or c == Color3.fromRGB(255, 255, 255)
				expect(painted).to.equal(true)
			end
			EnvironmentModifier.Restore(snap)
			for _, row in ipairs(originals) do
				expect(row.part.Color).to.equal(row.color)
			end
			cleanup()
		end)

		it('wildcard fans out across siblings, levels, and trailing position', function()
			-- Lamps layer: ONE exact 'Lamp', one 'LampA', one
			-- Bush-less 'Sign' (proves plain names do NOT fan
			-- out while '*' matches every child).
			local base = mkFolder(nil, 'Base_9')
			local lamps = mkFolder(mkFolder(base, 'Build'), 'Lamps')
			local lamp = mkFolder(lamps, 'Lamp')
			local bush = mkFolder(lamp, 'Bush')
			mkPart(bush, Color3.fromRGB(61, 1, 1))
			local lampA = mkFolder(lamps, 'LampA')
			local bushA = mkFolder(lampA, 'Bush')
			mkPart(bushA, Color3.fromRGB(62, 2, 2))
			mkMesh(bushA)
			mkFolder(lamps, 'Sign')
			local broots = { base }
			local fakeMap2 = mkFolder(nil, 'Map')
			local mi2 = mkFolder(fakeMap2, 'MainIsland')
			local island2 = mkFolder(mi2, 'Island')
			local grass2 = mkFolder(island2, 'Grass')
			mkPart(grass2, Color3.fromRGB(63, 3, 3))
			local decor2 = mkFolder(mi2, 'Decor')
			local treeA = mkFolder(decor2, 'TreeA')
			local leafA = mkFolder(treeA, 'Leaf')
			mkPart(leafA, Color3.fromRGB(64, 4, 4))
			local treeB = mkFolder(decor2, 'TreeB')
			local leafB = mkFolder(treeB, 'Leaf')
			mkMesh(leafB)
			local function cleanup()
				pcall(function()
					base:Destroy()
				end)
				pcall(function()
					fakeMap2:Destroy()
				end)
			end
			-- Plain name: only the exact 'Lamp' child (1 part).
			expect(EnvironmentModifier._TestResolveCount('Base.Build.Lamps.Lamp.Bush', nil, broots)).to.equal(1)
			-- Explicit wildcard: Bush under EVERY Lamp-like child.
			expect(EnvironmentModifier._TestResolveCount('Base.Build.Lamps.*.Bush', nil, broots)).to.equal(3)
			-- Multi-wildcard + future-style path, same generic walk.
			expect(EnvironmentModifier._TestResolveCount('Map.*.*.Grass', fakeMap2, {})).to.equal(1)
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.Decor.*.Leaf', fakeMap2, {})).to.equal(2)
			-- Trailing wildcard: every child becomes a root.
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.*', fakeMap2, {})).to.equal(1 + 2)
			cleanup()
		end)

		it('a brand-new path resolves with no engine edits', function()
			local fakeMap = mkFolder(nil, 'Map')
			local bush = mkFolder(mkFolder(mkFolder(fakeMap, 'MainIsland'), 'Island'), 'Bush')
			local leaf = mkPart(bush, Color3.fromRGB(9, 9, 9))
			-- 'Island.Bush' appears NOWHERE in EventConfig and no
			-- branch names it in the module — yet it resolves.
			expect(EnvironmentModifier._TestResolveCount('Map.MainIsland.Island.Bush', fakeMap, {})).to.equal(1)
			local snap = EnvironmentModifier.ApplyColors(
				{ New = { Color = Color3.fromRGB(1, 2, 3), Targets = { 'Map.MainIsland.Island.Bush' } } },
				{
					mapRoot = fakeMap,
					baseRoots = {},
				}
			)
			expect(leaf.Color).to.equal(Color3.fromRGB(1, 2, 3))
			EnvironmentModifier.Restore(snap)
			expect(leaf.Color).to.equal(Color3.fromRGB(9, 9, 9))
			pcall(function()
				fakeMap:Destroy()
			end)
		end)
	end)

	describe('EventController text states', function()
		it('renders ACTIVE / IN countdown / NORMAL', function()
			expect(EventController._TestText('Galaxy', '', 0)).to.equal('GALAXY EVENT ACTIVE')
			expect(EventController._TestText('', 'Snowfall', 480)).to.equal('SNOWFALL EVENT IN 8:00')
			expect(EventController._TestText('', '', 0)).to.equal('NORMAL')
		end)
	end)

	describe('EventLights galaxy night lights', function()
		-- Staged (unparented, zero Workspace pollution) trees
		-- mirroring the configured containers:
		--   Map.MainIsland.PointLights (2 PointLights + a
		--     nested SpotLight), Base.PointLights per base.
		local function stageTrees(): any
			local map = Instance.new('Folder')
			map.Name = 'Map'
			local island = Instance.new('Folder')
			island.Name = 'MainIsland'
			island.Parent = map
			local pl = Instance.new('Folder')
			pl.Name = 'PointLights'
			pl.Parent = island
			local a = Instance.new('PointLight')
			a.Enabled = false
			a.Parent = pl
			local b = Instance.new('PointLight')
			b.Enabled = true
			b.Parent = pl
			local nest = Instance.new('Model')
			nest.Parent = pl
			local spot = Instance.new('SpotLight')
			spot.Enabled = false
			spot.Parent = nest
			local bases: { Instance } = {}
			local baseLights: { Light } = {}
			for i = 1, 2 do
				local folder = Instance.new('Folder')
				folder.Name = 'Base_' .. tostring(i)
				local container = Instance.new('Folder')
				container.Name = 'PointLights'
				container.Parent = folder
				local light = Instance.new('PointLight')
				light.Enabled = false
				light.Parent = container
				baseLights[#baseLights + 1] = light
				bases[#bases + 1] = folder
			end
			return {
				map = map,
				bases = bases,
				mapA = a,
				mapB = b,
				spot = spot,
				baseLights = baseLights,
			}
		end

		local function cleanup(staged: any)
			pcall(function()
				if type(staged) == 'table' then
					if staged.map ~= nil then
						(staged.map :: Instance):Destroy()
					end
					for _, folder in ipairs(staged.bases) do
						(folder :: Instance):Destroy()
					end
				end
			end)
		end

		it('collects every Light under each container, per base', function()
			local staged = stageTrees()
			expect(EventLights._TestCollectCount('Map.MainIsland.PointLights', staged.map, {})).to.equal(3)
			expect(EventLights._TestCollectCount('Base.PointLights', nil, staged.bases)).to.equal(2)
			expect(EventLights._TestCollectCount('Map.NoSuchThing', staged.map, {})).to.equal(0)
			cleanup(staged)
		end)

		it('Apply turns everything ON and Restore returns exact originals', function()
			local staged = stageTrees()
			local opts = { mapRoot = staged.map, baseRoots = staged.bases }
			local snap =
				EventLights.ApplyLights({ Containers = { 'Map.MainIsland.PointLights', 'Base.PointLights' } }, opts)
			expect(#snap.entries).to.equal(5)
			expect(staged.mapA.Enabled).to.equal(true)
			expect(staged.mapB.Enabled).to.equal(true)
			expect(staged.spot.Enabled).to.equal(true)
			for _, light in ipairs(staged.baseLights) do
				expect((light :: Light).Enabled).to.equal(true)
			end
			EventLights.Restore(snap)
			expect(staged.mapA.Enabled).to.equal(false)
			expect(staged.mapB.Enabled).to.equal(true)
			expect(staged.spot.Enabled).to.equal(false)
			for _, light in ipairs(staged.baseLights) do
				expect((light :: Light).Enabled).to.equal(false)
			end
			-- Idempotent: second restore is a no-op.
			EventLights.Restore(snap)
			expect(staged.mapA.Enabled).to.equal(false)
			cleanup(staged)
		end)

		it('missing containers and bad config degrade to empty snapshots', function()
			local staged = stageTrees()
			local opts = { mapRoot = staged.map, baseRoots = staged.bases }
			local empty = EventLights.ApplyLights({ Containers = { 'Map.NoSuchThing', '', 42 } }, opts)
			expect(#empty.entries).to.equal(0)
			EventLights.Restore(empty)
			local nilCfg = EventLights.ApplyLights(nil, opts)
			expect(#nilCfg.entries).to.equal(0)
			cleanup(staged)
		end)

		it('Galaxy def carries the two light containers; others carry none', function()
			local galaxy = EventConfig.Events.Galaxy
			expect(type(galaxy.Lights)).to.equal('table')
			expect(#galaxy.Lights.Containers).to.equal(2)
			expect(galaxy.Lights.Containers[1]).to.equal('Map.MainIsland.PointLights')
			expect(galaxy.Lights.Containers[2]).to.equal('Base.PointLights')
			expect((EventConfig.Events.Snowfall :: any).Lights).to.equal(nil)
			expect((EventConfig.Events.Base :: any).Lights).to.equal(nil)
		end)

		it('Galaxy start turns staged lights ON; end restores them', function()
			local staged = stageTrees()
			cleanSlate()
			EventService._TestSetLightsRootsOverride(staged.map, staged.bases)
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			expect(staged.mapA.Enabled).to.equal(true)
			expect(staged.spot.Enabled).to.equal(true)
			for _, light in ipairs(staged.baseLights) do
				expect((light :: Light).Enabled).to.equal(true)
			end
			expect(EventService.EndEvent('test')).to.equal(true)
			expect(staged.mapA.Enabled).to.equal(false)
			expect(staged.mapB.Enabled).to.equal(true)
			expect(staged.spot.Enabled).to.equal(false)
			for _, light in ipairs(staged.baseLights) do
				expect((light :: Light).Enabled).to.equal(false)
			end
			EventService._TestSetLightsRootsOverride(nil, nil)
			EventService._TestReset()
			cleanup(staged)
		end)

		it('Snowfall touches no lights', function()
			local staged = stageTrees()
			cleanSlate()
			EventService._TestSetLightsRootsOverride(staged.map, staged.bases)
			expect(EventService.StartEvent('Snowfall', 'test')).to.equal(true)
			expect(staged.mapA.Enabled).to.equal(false)
			expect(staged.spot.Enabled).to.equal(false)
			for _, light in ipairs(staged.baseLights) do
				expect((light :: Light).Enabled).to.equal(false)
			end
			expect(EventService.EndEvent('test')).to.equal(true)
			EventService._TestSetLightsRootsOverride(nil, nil)
			EventService._TestReset()
			cleanup(staged)
		end)
	end)

	describe('CenterPartBillboards sibling disambiguation', function()
		it('resolves Egg vs Event BillboardGuis by child marker, never by order', function()
			-- Fake UNPARENTED hierarchy (no Workspace pollution):
			-- the Event gui is added FIRST so a positional
			-- FindFirstChild('BillboardGui') would return the
			-- WRONG sibling — the resolver must still pick
			-- correctly by marker.
			local map = Instance.new('Folder')
			map.Name = 'Map'
			local center = Instance.new('Part')
			center.Name = 'CenterPart'
			center.Parent = map
			local eventGui = Instance.new('BillboardGui')
			eventGui.Name = 'BillboardGui'
			eventGui.Parent = center
			local eventFolder = Instance.new('Folder')
			eventFolder.Name = 'Event'
			eventFolder.Parent = eventGui
			local eventLabel = Instance.new('TextLabel')
			eventLabel.Name = 'TextLabel'
			eventLabel.Parent = eventFolder
			local eggGui = Instance.new('BillboardGui')
			eggGui.Name = 'BillboardGui'
			eggGui.Parent = center
			local eggFolder = Instance.new('Folder')
			eggFolder.Name = 'Egg'
			eggFolder.Parent = eggGui
			local mythic = Instance.new('TextLabel')
			mythic.Name = 'Mythic'
			mythic.Parent = eggFolder
			local legendary = Instance.new('TextLabel')
			legendary.Name = 'Legendary'
			legendary.Parent = eggFolder
			expect(eggGui ~= eventGui).to.equal(true)
			-- Marker resolution ignores sibling order.
			expect(CenterPartBillboards.FindBillboardWithChild(center, 'Egg')).to.equal(eggGui)
			expect(CenterPartBillboards.FindBillboardWithChild(center, 'Event')).to.equal(eventGui)
			-- Egg timer node is the EGG container (never the Event gui).
			local eggNode = CenterPartBillboards.FindEggTimerNode(map)
			expect(eggNode).to.equal(eggFolder)
			-- Event label is the EVENT TextLabel (never Mythic/Legendary).
			local label = CenterPartBillboards.FindEventLabel(map)
			expect(label).to.equal(eventLabel)
			-- Missing markers / missing CenterPart degrade to nil.
			expect(CenterPartBillboards.FindBillboardWithChild(center, 'Nope')).to.equal(nil)
			expect(CenterPartBillboards.FindBillboardWithChild(nil, 'Egg')).to.equal(nil)
			local bare = Instance.new('Folder')
			expect(CenterPartBillboards.FindEggTimerNode(bare)).to.equal(nil)
			expect(CenterPartBillboards.FindEventLabel(bare)).to.equal(nil)
			expect(CenterPartBillboards.FindEggTimerNode(nil)).to.equal(nil)
			pcall(function()
				bare:Destroy()
			end)
			pcall(function()
				map:Destroy()
			end)
		end)
	end)

	describe('EventService transition broadcast', function()
		it('start broadcasts Prepare then Reveal with one shared TransitionId', function()
			cleanSlate()
			expect(EventService._TestIsTransitioning()).to.equal(false)
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			local calls = EventService._TestBroadcasts()
			expect(#calls).to.equal(2)
			expect(calls[1].Phase).to.equal('Prepare')
			expect(calls[1].Kind).to.equal('Start')
			expect(calls[1].EventId).to.equal('Galaxy')
			expect(type(calls[1].TransitionId)).to.equal('number')
			-- Server carries the animation timings (clients
			-- never invent them).
			expect(calls[1].FovMultiplier).to.equal(0.83)
			expect(calls[1].FovSeconds).to.equal(0.35)
			expect(calls[1].FlashDelaySeconds).to.equal(0.05)
			expect(calls[1].FlashInSeconds).to.equal(0.3)
			expect(calls[1].FadeOutSeconds).to.equal(1)
			expect(calls[2].Phase).to.equal('Reveal')
			expect(calls[2].Kind).to.equal('Start')
			expect(calls[2].EventId).to.equal('Galaxy')
			expect(calls[2].TransitionId).to.equal(calls[1].TransitionId)
			-- Idle afterward: no stuck transition.
			expect(EventService._TestIsTransitioning()).to.equal(false)
			expect(EventService.GetCurrentEvent() ~= nil and EventService.GetCurrentEvent().Id).to.equal('Galaxy')
			EventService._TestReset()
		end)

		it('end broadcasts Prepare then Reveal and clears the event', function()
			cleanSlate()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			expect(EventService.EndEvent('test')).to.equal(true)
			local calls = EventService._TestBroadcasts()
			expect(#calls).to.equal(4)
			expect(calls[3].Phase).to.equal('Prepare')
			expect(calls[3].Kind).to.equal('End')
			expect(calls[3].EventId).to.equal('Galaxy')
			expect(calls[4].Phase).to.equal('Reveal')
			expect(calls[4].Kind).to.equal('End')
			expect(calls[4].TransitionId).to.equal(calls[3].TransitionId)
			expect(calls[4].TransitionId == calls[1].TransitionId).to.equal(false)
			expect(EventService._TestIsTransitioning()).to.equal(false)
			expect(EventService.GetCurrentEvent()).to.equal(nil)
			EventService._TestReset()
		end)

		it('replace rides ONE Start transition (never an End flash)', function()
			cleanSlate()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			expect(EventService.StartEvent('Snowfall', 'test')).to.equal(true)
			local calls = EventService._TestBroadcasts()
			-- Galaxy start pair + Snowfall start pair: the
			-- inner replace-end broadcasts nothing.
			expect(#calls).to.equal(4)
			expect(calls[3].Phase).to.equal('Prepare')
			expect(calls[3].Kind).to.equal('Start')
			expect(calls[3].EventId).to.equal('Snowfall')
			expect(calls[4].Phase).to.equal('Reveal')
			expect(calls[4].TransitionId).to.equal(calls[3].TransitionId)
			expect(EventService.GetCurrentEvent() ~= nil and EventService.GetCurrentEvent().Id).to.equal('Snowfall')
			expect(EventService.EndEvent('test')).to.equal(true)
			EventService._TestReset()
		end)

		it('duplicate starts broadcast nothing extra and stay rejected', function()
			cleanSlate()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			expect(#EventService._TestBroadcasts()).to.equal(2)
			local ok, _ = EventService.StartEvent('Galaxy', 'test')
			expect(ok).to.equal(false)
			expect(#EventService._TestBroadcasts()).to.equal(2)
			expect(EventService._TestIsTransitioning()).to.equal(false)
			EventService._TestReset()
		end)

		it('rejected/empty calls broadcast nothing', function()
			cleanSlate()
			local ok, _ = EventService.StartEvent('Volcano', 'test')
			expect(ok).to.equal(false)
			expect(EventService.EndEvent('test')).to.equal(true)
			expect(#EventService._TestBroadcasts()).to.equal(0)
			expect(EventService._TestIsTransitioning()).to.equal(false)
			EventService._TestReset()
		end)
	end)
end
