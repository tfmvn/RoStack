--!strict
--!native
--[[
	AnimalTemplate.spec
	===================
	Headless coverage for the centralized animal visual resolver
	(AnimalService.GetTemplate): trait + rarity + SPECIES hierarchy
	(ServerStorage.Animals/<Trait>/<Rarity>/<DefId>), where the
	<DefId> node IS the complete species Model (e.g.
	Animals.Normal.Rare.BurrowingOwl). Nested Models inside a
	species model are internal rig/content — the resolver returns
	the species node itself, never a child. Covers Normal
	fallback for missing trait variants, the legacy
	Animals/<Rarity>/<DefId> shape, and nil-safe misses.
	Gameplay data (Trait/Rarity/Mutations/multipliers) is
	untouched — resolution is visual only.
]]

return function()
	local ServerScriptService = game:GetService('ServerScriptService')
	local ServerStorage = game:GetService('ServerStorage')

	local AnimalService = require(ServerScriptService.AnimalService)

	-- Stage models under ServerStorage/Animals, tracking exactly
	-- what this spec created so teardown removes only our nodes
	-- (never a pre-existing Studio tree). When a node already
	-- exists (live Studio with authored assets), it is reused as
	-- the expectation — the test then verifies the REAL tree.
	local created: { Instance } = {}
	local function ensureFolder(parent: Instance, name: string): Instance
		local found = parent:FindFirstChild(name)
		if found ~= nil then
			return found
		end
		local folder = Instance.new('Folder')
		folder.Name = name
		folder.Parent = parent
		created[#created + 1] = folder
		return folder
	end
	-- Returns the species Model at
	-- Animals/<traitFolder>/<rarity>/<defId>, staging it (and
	-- any missing parents) only when absent. Second return is
	-- true when THIS spec created the model (safe to destroy in
	-- teardown / partial-tree cases); false when it pre-existed.
	local function ensureSpecies(traitFolder: string, rarity: string, defId: string): (Model, boolean)
		local animals = ensureFolder(ServerStorage, 'Animals')
		local trait = ensureFolder(animals, traitFolder)
		local rar = ensureFolder(trait, rarity)
		local found = rar:FindFirstChild(defId)
		if found ~= nil and found:IsA('Model') then
			return found, false
		end
		local model = Instance.new('Model')
		model.Name = defId
		model.Parent = rar
		created[#created + 1] = model
		return model, true
	end
	local function teardown()
		-- Reverse order: models before their folders, so every
		-- node we created is removed and nothing else is.
		for i = #created, 1, -1 do
			pcall(function()
				created[i]:Destroy()
			end)
			created[i] = nil
		end
	end

	describe('AnimalService.GetTemplate trait+rarity+species resolution', function()
		it('resolves the exact trait species model', function()
			local normalFrog, _ = ensureSpecies('Normal', 'Common', 'Frog')
			local goldCrane, _ = ensureSpecies('Gold', 'Mythic', 'Crane')
			expect(AnimalService.GetTemplate('Common', 'Frog', nil)).to.equal(normalFrog)
			expect(AnimalService.GetTemplate('Common', 'Frog', '')).to.equal(normalFrog)
			expect(AnimalService.GetTemplate('Mythic', 'Crane', 'Gold')).to.equal(goldCrane)
			teardown()
		end)

		it('falls back to Normal for a missing trait variant', function()
			local normalJerboa, _ = ensureSpecies('Normal', 'Epic', 'Jerboa')
			ensureSpecies('Diamond', 'Common', 'Chicken')
			-- Diamond+Epic/Jerboa absent -> Normal+Epic/Jerboa
			-- (warns, never nil).
			expect(AnimalService.GetTemplate('Epic', 'Jerboa', 'Diamond')).to.equal(normalJerboa)
			teardown()
		end)

		it('treats nil and invalid traits as Normal', function()
			local normalOwl, _ = ensureSpecies('Normal', 'Rare', 'BurrowingOwl')
			expect(AnimalService.GetTemplate('Rare', 'BurrowingOwl', nil)).to.equal(normalOwl)
			expect(AnimalService.GetTemplate('Rare', 'BurrowingOwl', 'Platinum')).to.equal(normalOwl)
			expect(AnimalService.GetTemplate('Rare', 'BurrowingOwl', '')).to.equal(normalOwl)
			teardown()
		end)

		it('returns the species model itself, never an inner child', function()
			local owl, _ = ensureSpecies('Normal', 'Rare', 'BurrowingOwl')
			local resolved = AnimalService.GetTemplate('Rare', 'BurrowingOwl', 'Normal')
			expect(resolved).to.equal(owl)
			-- The resolver must never descend into the species
			-- model (e.g. returning BurrowingOwl.Model).
			if resolved ~= nil then
				expect(resolved.Parent).to.equal(owl.Parent)
			end
			teardown()
		end)

		it('returns nil when nothing matches (no silent breakage)', function()
			expect(AnimalService.GetTemplate('Secret', 'NopeNoSpecies', 'Rainbow')).to.equal(nil)
			expect(AnimalService.GetTemplate('Secret', 'NopeNoSpecies', nil)).to.equal(nil)
			teardown()
		end)

		it('supports the legacy Animals/<Rarity>/<DefId> shape', function()
			local animals = ensureFolder(ServerStorage, 'Animals')
			local rar = ensureFolder(animals, 'Common')
			local legacy = rar:FindFirstChild('Dog')
			local stagedLegacy = false
			if legacy == nil or not legacy:IsA('Model') then
				legacy = Instance.new('Model')
				legacy.Name = 'Dog'
				legacy.Parent = rar
				created[#created + 1] = legacy
				stagedLegacy = true
			end
			-- No trait folders staged: legacy defId lookup wins.
			expect(AnimalService.GetTemplate('Common', 'Dog', nil)).to.equal(legacy)
			expect(AnimalService.GetTemplate('Uncommon', 'Dog', nil)).to.equal(nil)
			if stagedLegacy then
				teardown()
			end
		end)

		it('ValidateStudioCoverage flags models without config, ignores nested models', function()
			-- A bogus top-level species model is drift.
			ensureSpecies('Normal', 'Common', 'DefinitelyNotARealSpecies9999')
			-- A nested Model inside a real species is internal
			-- content, never a separate animal.
			local owl, _ = ensureSpecies('Normal', 'Rare', 'BurrowingOwl')
			local inner = Instance.new('Model')
			inner.Name = 'Model'
			inner.Parent = owl
			created[#created + 1] = inner
			local issues = AnimalService.ValidateStudioCoverage()
			local foundBogus = false
			local foundNested = false
			for _, issue in ipairs(issues) do
				if string.find(issue, 'DefinitelyNotARealSpecies9999') ~= nil then
					foundBogus = true
				end
				if string.find(issue, 'BurrowingOwl/Model') ~= nil then
					foundNested = true
				end
			end
			expect(foundBogus).to.equal(true)
			expect(foundNested).to.equal(false)
			teardown()
		end)

		it('ValidateTemplates flags missing Normal species, stays silent without a tree', function()
			-- No Animals tree at all: silent (test place / unconfigured Studio).
			expect(#AnimalService.ValidateTemplates()).to.equal(0)
			-- Stage a complete tree: clean.
			local AnimalConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Animals)
			local staged = 0
			for rarity, bucket in pairs(AnimalConfig.Catalog) do
				if type(bucket) == 'table' and next(bucket) ~= nil then
					for defId in pairs(bucket) do
						ensureSpecies('Normal', rarity, defId)
						staged += 1
					end
				end
			end
			expect(staged > 0).to.equal(true)
			expect(#AnimalService.ValidateTemplates()).to.equal(0)
			teardown()
			-- Stage a partial tree (tree exists, one species missing):
			-- exactly that species is reported — but only when the
			-- missing node is one we staged (never destroy a real
			-- authored asset in live Studio).
			for rarity, bucket in pairs(AnimalConfig.Catalog) do
				if type(bucket) == 'table' and next(bucket) ~= nil then
					for defId in pairs(bucket) do
						ensureSpecies('Normal', rarity, defId)
					end
				end
			end
			local animals = ServerStorage:FindFirstChild('Animals')
			local normal = animals and animals:FindFirstChild('Normal')
			local rare = normal and normal:FindFirstChild('Rare')
			local owl = rare and rare:FindFirstChild('BurrowingOwl')
			local owlStaged = false
			for _, inst in ipairs(created) do
				if inst == owl then
					owlStaged = true
					break
				end
			end
			if owl ~= nil and owlStaged then
				owl:Destroy()
				local issues = AnimalService.ValidateTemplates()
				expect(#issues).to.equal(1)
				expect(string.find(issues[1], 'Animals/Normal/Rare/BurrowingOwl') ~= nil).to.equal(true)
			else
				-- Live Studio with the real asset present (or a
				-- tree that was already complete): the validator
				-- must be clean, which itself proves the real
				-- Normal/Rare/BurrowingOwl node resolves.
				local issues = AnimalService.ValidateTemplates()
				expect(#issues).to.equal(0)
			end
			teardown()
		end)
	end)
end
