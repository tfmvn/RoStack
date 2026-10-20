--!strict
--!native
--[[
	EventMutation.spec
	====================
	End-to-end mutation overhead + notification tests (spec §12,
	TEST A–J). ONE authoritative mutation state drives every
	assertion: the same `egg.Mutations` list written by commands
	and by the Event engine, read by the canonical overhead
	painters, inherited through the canonical hatch pipeline,
	and persisted through PlayerService.

	Headless Studio fabrications (destroyed afterwards):
	  * ServerStorage.Assets.OverheadGui.{Egg,Animal}OverheadGuiTemplate
	    (only when absent — never clobbering real Studio assets)
	  * ServerStorage.Assets.Decals.{GalaxyIcon,SnowfallIcon}
	    ImageLabels with marker Image strings
	  * spawned egg models (real SpawnService pipeline)

	TEST A: plain egg -> no mutation icon.
	TEST B: command-pipeline spawn with Galactic -> record +
	  overhead GalaxyIcon.
	TEST C: command-pipeline spawn with Frost -> record +
	  overhead SnowfallIcon.
	TEST D: Galaxy event roll -> active egg icon updates now.
	TEST E: Snowfall event roll -> active egg icon updates now.
	TEST F: base egg roll -> record + icon + owner-only toast +
	  Approved SFX path (captured delivery, per-player).
	TEST G: toast formatting segments + colors.
	TEST H: hatch inheritance + animal overhead icon.
	TEST I: post-end persistence (egg + icon + animal).
	TEST J: protected re-roll -> no overwrite, no duplicate
	  toast/SFX. Spawn-with-mutation never notifies either.

	Not headless-testable (Studio-only, code-verified): audible
	SFX playback (no audio device; the Approved asset lookup +
	dispatch path runs with warn-once fallback) and the real
	Studio-authored template art.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local ServerStorage = game:GetService('ServerStorage')
	local Workspace = game:GetService('Workspace')

	local SpawnService = require(ServerScriptService.Egg.SpawnService)
	local Catalog = require(ServerScriptService.Egg.Catalog)
	local Constants = require(ServerScriptService.Egg.Constants)
	local EventService = require(ServerScriptService.Event.EventService)
	local MutationService = require(ServerScriptService.MutationService)
	local TraitService = require(ServerScriptService.TraitService)
	local NotificationService = require(ServerScriptService.Base.NotificationService)
	local EggOverhead = require(ServerScriptService.Egg.EggOverhead)
	local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
	local MutationIcon = require(ServerScriptService.Utility.MutationIcon)
	local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
	local OverheadConfig = require(ReplicatedStorage.Config.Presentation.UI).Overhead
	local SuccessMessages = require(ReplicatedStorage.Config.Presentation.Messages).Success
	local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)

	local GALAXY_IMAGE = 'rbxassetid://1111111'
	local SNOWFALL_IMAGE = 'rbxassetid://2222222'

	-- --- Fabrications (created-once, destroyed after) ---------------------

	local _created: { Instance } = {}
	local _spawned: { any } = {}

	local function _track(inst: Instance): Instance
		_created[#_created + 1] = inst
		return inst
	end

	local function _ensureAssets()
		local assets = ServerStorage:FindFirstChild('Assets')
		if assets == nil then
			local folder = Instance.new('Folder')
			folder.Name = 'Assets'
			folder.Parent = ServerStorage
			assets = folder
			_track(folder)
		end
		local overhead = (assets :: Instance):FindFirstChild('OverheadGui')
		if overhead == nil then
			overhead = Instance.new('Folder')
			overhead.Name = 'OverheadGui'
			overhead.Parent = assets
			_track(overhead)
		end
		local function ensureTemplate(name: string)
			local existing = (overhead :: Instance):FindFirstChild(name)
			if existing ~= nil then
				return
			end
			local template = Instance.new('BillboardGui')
			template.Name = name
			local container = Instance.new('Frame')
			container.Name = 'Container'
			container.Parent = template
			local content = Instance.new('Frame')
			content.Name = 'Content'
			content.Parent = container
			for _, field in ipairs({ 'Name', 'Price', 'Trait', 'Level', 'Income', 'Rarity' }) do
				local label = Instance.new('TextLabel')
				label.Name = field
				label.Parent = content
			end
			local mutations = Instance.new('Frame')
			mutations.Name = 'Mutations'
			mutations.Parent = content
			local proto = Instance.new('ImageLabel')
			proto.Name = 'Mutation1'
			proto.Image = ''
			proto.Parent = mutations
			template.Parent = overhead
			_track(template)
		end
		ensureTemplate('EggOverheadGuiTemplate')
		ensureTemplate('AnimalOverheadGuiTemplate')
		local decals = (assets :: Instance):FindFirstChild('Decals')
		if decals == nil then
			decals = Instance.new('Folder')
			decals.Name = 'Decals'
			decals.Parent = assets
			_track(decals)
		end
		local function ensureDecal(name: string, image: string)
			local existing = (decals :: Instance):FindFirstChild(name)
			if existing ~= nil then
				return
			end
			local label = Instance.new('ImageLabel')
			label.Name = name
			label.Image = image
			label.Parent = decals
			_track(label)
		end
		ensureDecal('GalaxyIcon', GALAXY_IMAGE)
		ensureDecal('SnowfallIcon', SNOWFALL_IMAGE)
	end

	local function _teardown()
		for _, egg in ipairs(_spawned) do
			pcall(function()
				SpawnService.DropEgg(egg.uniqueId)
			end)
			if egg.model then
				pcall(function()
					(egg.model :: Model):Destroy()
				end)
			end
		end
		table.clear(_spawned)
		for i = #_created, 1, -1 do
			pcall(function()
				(_created[i] :: Instance):Destroy()
			end)
			_created[i] = nil
		end
		EventService._TestReset()
		EventService._TestSetPlayerResolver(nil)
		-- Lifecycle coverage (not timing): skip the transition
		-- cover gate (broadcasts still fire in order).
		EventService._TestSetTransitionCover(0)
		NotificationService.SetPlayerService(nil)
		NotificationService._TestReset()
		AnimalOverhead._TestReset()
	end

	local function _spawnTestEgg(rarity: string, mutations: { string }?): any
		if not Workspace:FindFirstChild('EggArea') then
			SpawnService.RegisterCenter(Workspace)
		end
		local r = SpawnService.Request({
			definition = { rarity = rarity, price = EggConfig.Price[rarity] or 100 },
			origin = Catalog.Origin.Test,
			mutations = mutations,
		})
		assert(r.success, 'test spawn must succeed')
		local egg = r.egg
		_spawned[#_spawned + 1] = egg
		return egg
	end

	-- Egg ids are engine-minted; teardown drops exactly the
	-- records this spec spawned (tracked above).

	local function _findEggGui(egg: any): Instance?
		local found: Instance? = nil
		pcall(function()
			local model = egg.model
			if typeof(model) ~= 'Instance' then
				return
			end
			for _, desc in ipairs((model :: Model):GetDescendants()) do
				if desc:IsA('BillboardGui') and desc.Name == 'EggOverheadGui' then
					found = desc
					break
				end
			end
		end)
		return found
	end

	local function _mutationIconImage(egg: any, mutationId: string): string?
		local image: string? = nil
		pcall(function()
			local gui = _findEggGui(egg)
			local container = gui and gui:FindFirstChild('Container') or nil
			local content = container and (container :: Instance):FindFirstChild('Content') or nil
			local list = content and (content :: Instance):FindFirstChild('Mutations') or nil
			local slot = list and (list :: Instance):FindFirstChild(mutationId) or nil
			local label: ImageLabel? = nil
			if slot ~= nil and slot:IsA('ImageLabel') then
				label = slot :: ImageLabel
			elseif slot ~= nil then
				local deep = (slot :: Instance):FindFirstChildWhichIsA('ImageLabel', true)
				if deep ~= nil then
					label = deep
				end
			end
			if label ~= nil then
				image = (label :: ImageLabel).Image
			end
		end)
		return image
	end

	local function _normalizeEgg(egg: any)
		-- Reset to a pristine unmutated state so the forced
		-- roll below is deterministic; hide icons.
		egg.Mutations = {}
		pcall(EggOverhead.Refresh, egg)
	end

	describe('EventMutation overhead + notify', function()
		beforeEach(function()
			_ensureAssets()
			AnimalOverhead._TestReset()
			NotificationService._TestReset()
		end)

		afterEach(function()
			_teardown()
		end)

		it('TEST A: plain egg carries no mutation and shows no icon', function()
			local egg = _spawnTestEgg('Common', nil)
			expect(#MutationService.SanitizeList(egg.Mutations)).to.equal(0)
			local gui = _findEggGui(egg)
			expect(gui ~= nil).to.equal(true)
			local container: Instance? = nil
			pcall(function()
				local c = (gui :: Instance):FindFirstChild('Container')
				local content = c and (c :: Instance):FindFirstChild('Content') or nil
				container = content and (content :: Instance):FindFirstChild('Mutations') or nil
			end)
			expect(container ~= nil).to.equal(true)
			expect((container :: Instance):FindFirstChild('Galactic')).to.equal(nil)
			expect((container :: Instance):FindFirstChild('Frost')).to.equal(nil)
			-- Empty mutation set hides the whole container.
			if (container :: Instance):IsA('GuiObject') then
				expect(((container :: Instance) :: GuiObject).Visible).to.equal(false)
			end
		end)

		it('TEST B/C: command-pipeline spawn with Galactic/Frost stamps record + decal icon', function()
			-- The admin command validates text through this exact
			-- parser before passing the table into Request.
			local okG, parsedG = MutationService.ParseListInput('Galactic')
			expect(okG).to.equal(true)
			expect(#parsedG).to.equal(1)
			expect(parsedG[1]).to.equal('Galactic')
			local okF, parsedF = MutationService.ParseListInput('Frost')
			expect(okF).to.equal(true)
			expect(parsedF[1]).to.equal('Frost')
			-- Same canonical creation pipeline normal eggs use.
			local galactic = _spawnTestEgg('Legendary', parsedG)
			expect(#galactic.Mutations).to.equal(1)
			expect(galactic.Mutations[1]).to.equal('Galactic')
			expect(_mutationIconImage(galactic, 'Galactic')).to.equal(GALAXY_IMAGE)
			local frost = _spawnTestEgg('Rare', parsedF)
			expect(frost.Mutations[1]).to.equal('Frost')
			expect(_mutationIconImage(frost, 'Frost')).to.equal(SNOWFALL_IMAGE)
		end)

		it('TEST 3/5/7: progressive cycles — nothing at start, late eggs join, worker stops at end', function()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			local eggA = _spawnTestEgg('Common', nil)
			-- Start mutates nothing by itself (no start burst).
			expect(#eggA.Mutations).to.equal(0)
			-- Failing cycle: still unmutated, still eligible.
			expect(EventService.RunMutationCycle(1)).to.equal(0)
			expect(#eggA.Mutations).to.equal(0)
			-- New egg AFTER start joins a later cycle (TEST 5).
			local eggB = _spawnTestEgg('Common', nil)
			expect(EventService.RunMutationCycle(0)).to.equal(2)
			expect(eggA.Mutations[1]).to.equal('Galactic')
			expect(eggB.Mutations[1]).to.equal('Galactic')
			-- Next cycle: nothing new (both protected).
			expect(EventService.RunMutationCycle(0)).to.equal(0)
			-- End stops the worker: cycles are no-ops (TEST 7).
			expect(EventService.EndEvent('test')).to.equal(true)
			local eggC = _spawnTestEgg('Common', nil)
			expect(EventService.RunMutationCycle(0)).to.equal(0)
			expect(#eggC.Mutations).to.equal(0)
			-- Earlier mutations persist through the end.
			expect(eggA.Mutations[1]).to.equal('Galactic')
			expect(eggB.Mutations[1]).to.equal('Galactic')
		end)

		it('TEST D/E: event roll updates the active egg icon immediately', function()
			local egg = _spawnTestEgg('Common', nil)
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			_normalizeEgg(egg)
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(true)
			expect(egg.Mutations[1]).to.equal('Galactic')
			expect(_mutationIconImage(egg, 'Galactic')).to.equal(GALAXY_IMAGE)
			expect(EventService.EndEvent('test')).to.equal(true)
			local egg2 = _spawnTestEgg('Common', nil)
			expect(EventService.StartEvent('Snowfall', 'test')).to.equal(true)
			_normalizeEgg(egg2)
			expect(EventService.TryMutateEgg(egg2, 0)).to.equal(true)
			expect(egg2.Mutations[1]).to.equal('Frost')
			expect(_mutationIconImage(egg2, 'Frost')).to.equal(SNOWFALL_IMAGE)
			expect(EventService.EndEvent('test')).to.equal(true)
		end)

		it('TEST F/J: base egg roll notifies the owner only, once, on real change', function()
			local captured: { any } = {}
			NotificationService.SetPlayerService({
				Notify = function(_player: any, category: string, text: string)
					captured[#captured + 1] = { player = _player, category = category, text = text }
				end,
			} :: any)
			local fakeA: any = { UserId = 7001, Name = 'OwnerA' }
			EventService._TestSetPlayerResolver(function(userId: number)
				if userId == 7001 then
					return fakeA
				end
				return nil
			end)
			local egg = _spawnTestEgg('Legendary', nil)
			egg.state = Constants.State.Placed
			egg.ownerUserId = 7001
			egg.slotId = 'p7:7001:slot:1'
			expect(EventService.StartEvent('Snowfall', 'test')).to.equal(true)
			_normalizeEgg(egg)
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(true)
			expect(egg.Mutations[1]).to.equal('Frost')
			expect(_mutationIconImage(egg, 'Frost')).to.equal(SNOWFALL_IMAGE)
			-- Owner-only: exactly one toast, to the owner, Reward category.
			expect(#captured).to.equal(1)
			expect(captured[1].player).to.equal(fakeA)
			expect(captured[1].category).to.equal('Reward')
			-- Re-roll attempt: protected, no duplicate toast.
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(false)
			expect(egg.Mutations[1]).to.equal('Frost')
			expect(#captured).to.equal(1)
			-- Another owner's untouched egg: nothing sent for them.
			local other = _spawnTestEgg('Common', nil)
			other.state = Constants.State.Placed
			other.ownerUserId = 7002
			_normalizeEgg(other)
			expect(EventService.TryMutateEgg(other, 1)).to.equal(false)
			expect(#captured).to.equal(1)
			-- Spawn-with-mutation during the event: protected, silent.
			-- (No normalize here: the spawn-given mutation must
			-- survive to prove the event path refuses to touch it.)
			local premut = _spawnTestEgg('Epic', { 'Galactic' })
			expect(premut.Mutations[1]).to.equal('Galactic')
			expect(EventService.TryMutateEgg(premut, 0)).to.equal(false)
			expect(premut.Mutations[1]).to.equal('Galactic')
			expect(#captured).to.equal(1)
			expect(EventService.EndEvent('test')).to.equal(true)
		end)

		it('TEST K: slot-context eligibility — Traveling mutates on its record, Consumed never rolls', function()
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			-- Traveling egg (in-flight to a reserved slot): the
			-- roll operates on the egg RECORD (uniqueId +
			-- slot context), not on hierarchy position.
			local flying = _spawnTestEgg('Common', nil)
			flying.state = Constants.State.Traveling
			flying.ownerUserId = 7001
			flying.slotId = 'p7:7001:slot:3'
			_normalizeEgg(flying)
			expect(EventService.TryMutateEgg(flying, 0)).to.equal(true)
			expect(flying.Mutations[1]).to.equal('Galactic')
			-- Consumed (hatched/gone) eggs never roll, whatever
			-- slot context they still carry.
			local gone = _spawnTestEgg('Common', nil)
			gone.state = Constants.State.Consumed
			gone.ownerUserId = 7001
			gone.slotId = 'p7:7001:slot:3'
			_normalizeEgg(gone)
			expect(EventService.TryMutateEgg(gone, 0)).to.equal(false)
			expect(#gone.Mutations).to.equal(0)
			expect(EventService.EndEvent('test')).to.equal(true)
		end)

		it('TEST G: toast format colors only the egg and mutation names', function()
			local text = NotificationService.GetSuccessText('Event_EggMutated', {
				EggName = 'Legendary Egg',
				Rarity = 'Legendary',
				MutationName = 'Galactic',
			})
			expect(type(text)).to.equal('string')
			local eggHex = RichTextFormatter.RarityHex('Legendary')
			local mutHex = RichTextFormatter.ColorHex(OverheadConfig.MutationColors.Galactic)
			local expected = 'Your '
				.. ('<font color="%s">Legendary Egg</font>'):format(eggHex)
				.. ' got the '
				.. ('<font color="%s">Galactic</font>'):format(mutHex)
				.. ' mutation.'
			expect(text).to.equal(expected)
			-- Catalog entry carries the Approved sting.
			local found: any = nil
			for _, entry in ipairs(SuccessMessages) do
				if type(entry) == 'table' and entry.Id == 'Event_EggMutated' then
					found = entry
					break
				end
			end
			expect(found ~= nil).to.equal(true)
			expect(found.Sound).to.equal('Approved')
		end)

		it('TEST H/I: hatch inheritance + animal icon, kept after event end', function()
			local egg = _spawnTestEgg('Legendary', nil)
			expect(EventService.StartEvent('Galaxy', 'test')).to.equal(true)
			_normalizeEgg(egg)
			expect(EventService.TryMutateEgg(egg, 0)).to.equal(true)
			-- Canonical hatch pipeline copies 100% (no re-roll).
			local inheritance = TraitService.ResolveInheritance(egg.Trait, egg.Mutations, 0)
			expect(#inheritance.Mutations).to.equal(1)
			expect(inheritance.Mutations[1]).to.equal('Galactic')
			-- Animal overhead shows the decal icon for the
			-- inherited mutation.
			local model = Instance.new('Model')
			model.Name = 'TestAnimal'
			local center = Instance.new('Part')
			center.Name = 'CENTER'
			center.Parent = model
			model.PrimaryPart = center
			model.Parent = Workspace
			_track(model)
			local animal: any = {
				Mutations = inheritance.Mutations,
				Trait = inheritance.Trait,
				Level = 1,
				displayName = 'Test Animal',
				rarity = 'Legendary',
				model = model,
			}
			expect(AnimalOverhead.Refresh(animal)).to.equal(true)
			local gui = AnimalOverhead._TestFind(animal)
			expect(gui ~= nil).to.equal(true)
			local image: string? = nil
			pcall(function()
				local content = (gui :: Instance):FindFirstChild('Container')
				local inner = content and (content :: Instance):FindFirstChild('Content') or nil
				local list = inner and (inner :: Instance):FindFirstChild('Mutations') or nil
				local slot = list and (list :: Instance):FindFirstChild('Galactic') or nil
				if slot ~= nil and slot:IsA('ImageLabel') then
					image = (slot :: ImageLabel).Image
				end
			end)
			expect(image).to.equal(GALAXY_IMAGE)
			-- End the event: egg mutation + icon + animal record
			-- all persist (nothing strips persistent data).
			expect(EventService.EndEvent('test')).to.equal(true)
			expect(egg.Mutations[1]).to.equal('Galactic')
			expect(_mutationIconImage(egg, 'Galactic')).to.equal(GALAXY_IMAGE)
			expect(animal.Mutations[1]).to.equal('Galactic')
		end)

		it('MutationIcon mapping resolves decals, unknown ids stay generic', function()
			expect(MutationIcon.DecalNameFor('Galactic')).to.equal('GalaxyIcon')
			expect(MutationIcon.DecalNameFor('Frost')).to.equal('SnowfallIcon')
			expect(MutationIcon.DecalNameFor('Ancient')).to.equal(nil)
			expect(MutationIcon.ResolveImage('Galactic')).to.equal(GALAXY_IMAGE)
			expect(MutationIcon.ResolveImage('Frost')).to.equal(SNOWFALL_IMAGE)
			expect(MutationIcon.ResolveImage('Ancient')).to.equal(nil)
			-- The historical inheritance failure point: unknown
			-- ids are stripped by the sanitizer, so event ids
			-- MUST be catalog-valid to survive hatch copying.
			local kept = MutationService.SanitizeList({ 'Galactic' })
			expect(#kept).to.equal(1)
			expect(kept[1]).to.equal('Galactic')
			local keptFrost = MutationService.SanitizeList({ 'Frost' })
			expect(#keptFrost).to.equal(1)
			expect(keptFrost[1]).to.equal('Frost')
		end)
	end)
end
