--!strict
--!native
--[[
	_Helpers
	========
	Shared test utilities. FakeInstance, FakePlayer, deterministic
	random seed, plus a few convenience factories.

	Every test that needs to make Roblox instances (Parts, Models,
	etc.) goes through these helpers so we can keep the surface
	small and so tests work in any order.
]]

local Helpers = {}

-- Deterministic PRNG. Lehmer LCG with Park-Miller constants.
-- No bitwise operators, no global state — fully deterministic for
-- any positive seed.
function Helpers.MakeRng(seed: number)
	local state = (seed and seed > 0) and seed or 1
	return function()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

-- Minimal Player stand-in.
function Helpers.FakePlayer(userId: number, name: string?)
	local p: any = {
		UserId = userId,
		Name = name or ('Player' .. tostring(userId)),
		Parent = game:GetService('Players'),
		notifications = {},
	}
	function p:Kick(reason: string)
		p._kicked = reason
	end
	function p:IsA(className: string)
		return className == 'Player'
	end
	function p:IsDescendantOf(parent: Instance)
		return parent == game:GetService('Players')
	end
	return p
end

-- Stub the global Remotes so PlayerService doesn't error when
-- calling FireClient. Destroys any leftover folder from a prior
-- test so each test starts from a clean ReplicatedStorage.
function Helpers.StubRemotes()
	local ReplicatedStorage = game:GetService('ReplicatedStorage')
	local Remotes = require(ReplicatedStorage.Utility.Remotes)
	local existing = ReplicatedStorage:FindFirstChild('Remotes')
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new('Folder')
	folder.Name = 'Remotes'
	folder.Parent = ReplicatedStorage
	for _, name in pairs(Remotes.Names) do
		local re = Instance.new('RemoteEvent')
		re.Name = name
		re.Parent = folder
	end
	Remotes.SetRemotes(folder)
	return folder
end

-- Force-resolve the singleton services in dependency order.
function Helpers.GetServices()
	local SSS = game:GetService('ServerScriptService')
	return {
		PlayerService = require(SSS.PlayerService),
		EconomyService = require(SSS.EconomyService),
		SlotService = require(SSS.Base.SlotService),
		BaseService = require(SSS.BaseService),
		EggService = require(SSS.EggService),
		AnimalService = require(SSS.AnimalService),
	}
end

-- Wire the services the same way bootstrap does. Idempotent.
-- Phase 2.1: EconomyService is wired first (it just needs
-- a late-bound PlayerService ref) and then the other
-- services. EconomyService is also wired into the
-- EggService so the purchase path can use
-- TrySpendMoney.
function Helpers.WireServices()
	local services = Helpers.GetServices()
	services.EconomyService.Init()
	services.EconomyService.SetPlayerService(services.PlayerService)
	services.PlayerService.Init()
	services.SlotService.Init()
	services.BaseService.Init()
	services.BaseService.SetPlayerService(services.PlayerService)
	services.BaseService.SetSlotService(services.SlotService)
	services.BaseService.SetEggService(services.EggService)
	services.BaseService.SetAnimalService(services.AnimalService)
	services.EggService.Init()
	services.EggService.SetPlayerService(services.PlayerService)
	services.EggService.SetBaseService(services.BaseService)
	services.EggService.SetAnimalService(services.AnimalService)
	services.EggService.SetSlotService(services.SlotService)
	services.AnimalService.Init()
	services.AnimalService.SetPlayerService(services.PlayerService)
	services.AnimalService.SetBaseService(services.BaseService)
	services.AnimalService.SetEggService(services.EggService)
	services.AnimalService.SetSlotService(services.SlotService)
	-- Phase 2.7: the modifier authority is dependency-free; wire it
	-- into its two readers so full-stack specs observe production
	-- behavior (1x defaults when no sources are added).
	local ModifierService = require(game:GetService('ServerScriptService').ModifierService)
	ModifierService.Init()
	services.ModifierService = ModifierService
	local IncomeService = require(game:GetService('ServerScriptService').IncomeService)
	IncomeService.SetModifierService(ModifierService)
	services.AnimalService.SetModifierService(ModifierService)
	-- Phase 2.8: the sale authority (pure calc + transactions).
	-- Wired with the same refs as bootstrap so handler-level
	-- sell routing observes production behavior. The Sell
	-- prompt opens the confirmation (PreviewSell); only the
	-- GUI Sell button transacts via ConfirmSell.
	local SellService = require(game:GetService('ServerScriptService').SellService)
	SellService.SetPlayerService(services.PlayerService)
	SellService.SetSlotService(services.SlotService)
	SellService.SetBaseService(services.BaseService)
	SellService.SetAnimalService(services.AnimalService)
	SellService.SetEggService(services.EggService)
	SellService.SetEconomyService(services.EconomyService)
	SellService.SetIncomeService(IncomeService)
	SellService.SetModifierService(ModifierService)
	SellService.Init()
	services.SellService = SellService
	services.IncomeService = IncomeService
	-- Phase 2.10: paid Animal upgrades (pure calc + atomic
	-- transaction), wired with the same refs as bootstrap.
	local UpgradeService = require(game:GetService('ServerScriptService').UpgradeService)
	UpgradeService.SetPlayerService(services.PlayerService)
	UpgradeService.SetSlotService(services.SlotService)
	UpgradeService.SetBaseService(services.BaseService)
	UpgradeService.SetAnimalService(services.AnimalService)
	UpgradeService.SetEconomyService(services.EconomyService)
	services.UpgradeService = UpgradeService
	return services
end

-- Pre-create `Workspace.Bases.Base_<i>.Collector` for every base
-- `RegisterBases` will register.
--
-- MUST run before `RegisterBases`: as of Phase 5 that function
-- errors out on a base with no Collector rather than falling back
-- (the Collector's placement encodes the base's orientation, so
-- the server refuses to guess one — see
-- Docs/StudioAssets/base-collector.md). It still auto-creates
-- `Spawn`, `Slots` and `Slot<n>`, so this is the only child a
-- bare-Workspace test has to supply.
--
-- The position mirrors the conventional Studio placement: the
-- auto-created Spawn sits at `CFrame.new(i * 40, 0.5, 0)`, and the
-- Collector goes 10 studs along -Z from it (ADR-004 §D4). That
-- offset is what makes the derived facing a clean 180° yaw, which
-- the collector-facing specs assert against.
function Helpers.EnsureCollectors(): Folder
	local Bases = require(game:GetService('ReplicatedStorage').Config.World.Bases)
	local workspace = game:GetService('Workspace')
	local basesFolder = workspace:FindFirstChild('Bases')
	if not basesFolder then
		basesFolder = Instance.new('Folder')
		basesFolder.Name = 'Bases'
		basesFolder.Parent = workspace
	end
	for i = 1, Bases.Count do
		local id = 'Base_' .. tostring(i)
		local baseFolder = basesFolder:FindFirstChild(id)
		if not baseFolder then
			baseFolder = Instance.new('Folder')
			baseFolder.Name = id
			baseFolder.Parent = basesFolder
		end
		if not baseFolder:FindFirstChild('Collector') then
			local spawn = baseFolder:FindFirstChild('Spawn')
			local spawnCFrame = (spawn and spawn:IsA('BasePart') and spawn.CFrame) or CFrame.new(i * 40, 0.5, 0)
			local collector = Instance.new('Part')
			collector.Name = 'Collector'
			collector.Size = Vector3.new(6, 1, 6)
			collector.Anchored = true
			collector.CanCollide = false
			collector.CanTouch = true
			collector.CFrame = spawnCFrame + Vector3.new(0, 0, -10)
			collector.Parent = baseFolder
		end
	end
	return basesFolder :: Folder
end

-- Pre-assign a base to a test user and return both the
-- BaseService and the base record. Phase 1.5 carry tests
-- need a deterministic base assignment — relying on
-- `AssignBaseForPlayer`'s scan order made tests order-
-- dependent when more than one base existed.
function Helpers.RegisterBasesForTest(services: any, userId: number): any
	-- Ensure bases are registered with the workspace.
	if not next(services.BaseService.GetAllBases()) then
		Helpers.EnsureCollectors()
		services.BaseService.RegisterBases(game:GetService('Workspace'))
	end
	-- Pick the first available base.
	for _, base in pairs(services.BaseService.GetAllBases()) do
		if base.state == 'Available' then
			local assigned = services.BaseService.AssignBaseById(userId, base.id)
			expect(assigned).to.be.ok()
			return assigned
		end
	end
	error('RegisterBasesForTest: no available base')
end

return Helpers
