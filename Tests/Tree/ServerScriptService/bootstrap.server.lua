--!strict
--!native
--[[
	bootstrap.server
	================
	Entry point. Server Script. Runs once on server start.

	Responsibilities:
	  1. Create the Remotes folder + the four RemoteEvents.
	  2. Register the BaseService with the Workspace.
	  3. Register the EggService center.
	  4. Wire services together (SetX cross-references).
	  5. Hook Players.PlayerAdded / PlayerRemoving for the full
	     join -> load -> assign-base -> push-state lifecycle.
	  6. Start the center lucky-egg spawner.

	Spec §53-§57.
]]

local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Workspace = game:GetService('Workspace')
local ServerStorage = game:GetService('ServerStorage')

local Bases = require(ReplicatedStorage.Config.World.Bases)
local CenterSpawn = require(ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn
local EconomyConfig = require(ReplicatedStorage.Config.Economy.Money)
local BaseConfig = require(ReplicatedStorage.Config.World.Bases)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local PlayerConfig = require(ReplicatedStorage.Config.World.Movement).Player
local ConfigValidator = require(ReplicatedStorage.Utility.ConfigValidator)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
local Validation = require(ReplicatedStorage.Utility.Validation)
local StudioTestMode = require(ReplicatedStorage.Utility.StudioTestMode)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

-- Canonical debug sync (Systems.Debug is the single source of truth).
Debug.SyncFromDebugConfig(DebugConfig)

-- Central config validation at boot. Studio: fail LOUDLY so a bad
-- tune surfaces immediately. Live servers: warn (a bad tune must
-- never hard-crash production).
if DebugConfig.ConfigValidation == true then
	local okValidate, validateErr = pcall(ConfigValidator.AssertValid)
	if not okValidate then
		local RunService = game:GetService('RunService')
		local inStudio = false
		pcall(function()
			inStudio = RunService:IsStudio()
		end)
		if inStudio then
			error(tostring(validateErr), 0)
		else
			warn(tostring(validateErr))
		end
	end
end

-- Studio dev-only UserIds (0, -1, -2, ...): seed the mutable
-- runtime switch from the declared DebugConfig default.
-- Developers flip StudioTestMode.Enabled from the Studio
-- command bar afterwards; DebugConfig itself stays frozen.
-- Published servers are unaffected (IsStudio() gate inside).
StudioTestMode.Enabled = DebugConfig.AllowStudioTestUserIds == true

-- Debug.DrawPaths is already synced from Systems.Debug above
-- (canonical; the legacy GameConfig mirror is deleted).
-- (validator-enforced identical) — no second sync needed.

local PlayerService = require(script.Parent.PlayerService)
local SlotService = require(script.Parent.Base.SlotService)
local BaseService = require(script.Parent.BaseService)
local EggService = require(script.Parent.EggService)
local AnimalService = require(script.Parent.AnimalService)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
-- Reset gate: server-authoritative per-player protection derived
-- from CarryRegistry (leaf requires only — cycle-free).
local ResetProtectionService = require(script.Parent.Carry.ResetProtectionService)
-- Carry tool lock: same committed feed (any carry/steal start
-- locks Tools, any release unlocks). Recomputed live — no flag.
local ToolLockService = require(script.Parent.Carry.ToolLockService)
-- Client presentation settings persistence (BGM/SFX volumes,
-- FastMode). Leaf requires only — cycle-free.
local SettingsService = require(script.Parent.SettingsService)
-- Grab pose: server-side AnimationTrack on the carrier's
-- Character, driven by the same CarryRegistry feed (no
-- per-service hooks, no drift between pickup/steal/Egg).
local PlayerGrabService = require(script.Parent.Carry.PlayerGrabService)
local SlotType = require(ReplicatedStorage.Types.SlotType)
-- Phase 2.1: EconomyService is the single authoritative
-- mutator of profile.Data.Money. Required here so the
-- init order below can call its Init + SetPlayerService.
local EconomyService = require(script.Parent.EconomyService)

-- Phase 2.6: IncomeService is the ONE central income system
-- (online accumulation, offline earnings, touch collection,
-- removal settlement). Required here so the init order below
-- can wire its five service refs and the pool-settlement hook.
local IncomeService = require(script.Parent.IncomeService)

-- Phase 2.8: SellService owns animal/lucky-egg sale
-- transactions + the single sale-value calculation API.
local SellService = require(script.Parent.SellService)

-- Stealing (multiplayer): server-authoritative take-carry-
-- deliver-transfer. Required here so Init/Start can run after
-- bases register. Top-requires the slot/base/carry/egg/animal
-- modules (one-directional: none of them require StealService
-- back at load; the two CleanupPlayer call sites resolve it
-- lazily).
local StealService = require(script.Parent.Steal.StealService)

-- Bat PvP (server-authoritative swing validation + hitbox +
-- ragdoll/knockback + steal cancel). Requires StealService only
-- for the idempotent rollback call (one-directional: nothing
-- requires BatService back).
local BatService = require(script.Parent.Combat.BatService)

-- Phase 2.9: SlotMenuService owns the slot interaction menus
-- (menu-state snapshots + sale confirm endpoint). Requires
-- SlotActionHandler at load (which needs only Base/Slot/Carry
-- at load and resolves SellService lazily) — cycle-free.
local SlotMenuService = require(script.Parent.SlotMenuService)

-- Phase 2.10: UpgradeService owns paid Animal level upgrades
-- (pure cost calc + atomic transaction). Requires only shared
-- config/utility modules at load — cycle-free.
local UpgradeService = require(script.Parent.UpgradeService)
local TraitService = require(script.Parent.TraitService)
local MutationService = require(script.Parent.MutationService)

-- Gear Shop: server-authoritative session purchases + AutoBuy.
-- Requires only shared config/utility/notification leaves —
-- cycle-free (services inject PlayerService/EconomyService).
local GearShopService = require(script.Parent.GearShop.GearShopService)

-- Rebirth progression (server-authoritative reset transaction).
-- Requires player/animal/base/slot/arena/modifier/carry/arena
-- authorities — none of them require RebirthService back except
-- GearShopService, which resolves it lazily inside
-- GetPlayerRebirth (cycle-free).
local RebirthService = require(script.Parent.Rebirth.RebirthService)

-- Global leaderboard (money-only OrderedDataStore ranking;
-- rendered on Workspace.Map.LeaderBoard.Display).
-- Leaf-shaped: only shared utility leaves at load; player /
-- economy refs inject below (cycle-free).
local LeaderboardService = require(script.Parent.Leaderboard.LeaderboardService)

-- Tab player-list leaderboard (NATIVE Roblox leaderstats:
-- player.leaderstats with Rebirths first, Money second —
-- SEPARATE ranking from the global money-only board; never
-- mixed). No custom UI, no feed remote. Leaf-shaped like above.
local TabListService = require(script.Parent.TabList.TabListService)

-- Arena expeditions (progression + menu + session shell +
-- centralized combat scheduler). Requires only shared
-- config/utility leaves — cycle-free (services inject
-- PlayerService/BaseService/AnimalService/SlotService,
-- EconomyService, and the carry/steal/notification
-- authorities).
local ArenaProgressionService = require(script.Parent.Arena.ArenaProgressionService)
local ArenaService = require(script.Parent.Arena.ArenaService)
local ArenaBattleService = require(script.Parent.Arena.ArenaBattleService)

-- Redeem codes (server-authoritative validation + grants +
-- pending slot-bound delivery). Requires only shared
-- config/utility/notification leaves — cycle-free (services
-- inject PlayerService/EconomyService/SlotService/EggService/
-- AnimalService/GearShopService).
local CodesService = require(script.Parent.Codes.CodesService)

-- Daily streak rewards (server-authoritative claim + single
-- reward pipeline reuse: cash via EconomyService, tools via
-- GearShopService, slot rewards via CodesService delivery +
-- pending queue). Cycle-free (services inject their refs).
local DailyRewardsService = require(script.Parent.Daily.DailyRewardsService)

-- Session playtime courses (server os.clock sessions +
-- global IST-day pools; slot rewards reuse the Codes pending
-- queue). Cycle-free (services inject their refs).
local PlaytimeRewardsService = require(script.Parent.Playtime.PlaytimeRewardsService)

-- Player feedback: the ONE canonical notification system
-- (warnings + successes, catalog-owned text, throttle, SFX).
-- Leaf module (ReplicatedStorage leaves only) — every gameplay
-- service requires it directly, cycle-free.
local NotificationService = require(script.Parent.Base.NotificationService)

-- Cash-collection feedback (SFX pool warm per player at join so
-- the first success never creates-and-plays in the same tick).
-- Leaf module (StandResolver + Debug only) — cycle-free.
local CollectFeedback = require(script.Parent.Base.CollectFeedback)

-- Phase 2.7: ModifierService is the ONE authoritative place for
-- modifier resolution (Money multiplier + XP modifier, both 1x by
-- default).
local ModifierService = require(script.Parent.ModifierService)

-- --- 1. Create Remotes folder + RemoteEvents ------------------

local function createRemotes()
	local folder = ReplicatedStorage:FindFirstChild('Remotes')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = 'Remotes'
		folder.Parent = ReplicatedStorage
	end
	local names = Remotes.Names
	for _, n in pairs(names) do
		if not folder:FindFirstChild(n) then
			local remote = Instance.new('RemoteEvent')
			remote.Name = n
			remote.Parent = folder
		end
	end
	Remotes.SetRemotes(folder)
	return folder
end

createRemotes()

-- Global SoundGroup architecture (AudioGroups): the server owns
-- group creation (SoundService.Music + SoundService.SFX, which
-- replicate to clients). Every runtime play site stamps its own
-- sounds; the Settings sliders drive the group masters.
AudioGroups.EnsureGroups()

-- --- 2-4. Wire services -----------------------------------------

-- Phase 2.1: EconomyService is the single authoritative
-- mutator of profile.Data.Money. It only needs PlayerService
-- as a late-bound ref (set by SetPlayerService), so we init
-- it BEFORE PlayerService so the PlayerService body can
-- safely assume the service exists by the time it is wired
-- in. (PlayerService doesn't require EconomyService itself;
-- other services require it lazily on first money op.)
EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)

PlayerService.Init()

-- Phase 3: SlotService is the single source of truth for
-- slot state transitions. Init it before BaseService so
-- `SetSlotService` can wire the occupied-count callback
-- and `RegisterBases` can hand each base's slot table over.
SlotService.Init()

BaseService.Init()
BaseService.SetPlayerService(PlayerService)
BaseService.SetSlotService(SlotService)
BaseService.SetEggService(EggService)
BaseService.SetAnimalService(AnimalService)

EggService.Init()
EggService.SetPlayerService(PlayerService)
EggService.SetBaseService(BaseService)
EggService.SetAnimalService(AnimalService)
EggService.SetSlotService(SlotService)

AnimalService.Init()
AnimalService.SetPlayerService(PlayerService)
AnimalService.SetBaseService(BaseService)
AnimalService.SetEggService(EggService)
AnimalService.SetSlotService(SlotService)
-- Root money replication: EconomyService pushes the canonical
-- PlayerState after every successful balance write (snapshot
-- provider for the post-mutation push). Every cash source —
-- codes, purchases, refunds, collects, admin — replicates
-- through the one money pipeline automatically.
EconomyService.SetBaseService(BaseService)

-- Phase 2.7: the modifier authority has no dependencies (pure
-- per-player source tables), so it inits before its readers.
-- IncomeService folds the Money multiplier into newly generated
-- online income; AnimalService folds the XP modifier into each
-- grant exactly once. Neither the offline path, collection, nor
-- settlement reads modifiers.
ModifierService.Init()
IncomeService.SetModifierService(ModifierService)
AnimalService.SetModifierService(ModifierService)

-- Stand idle wobble: the ONE centralized presentation loop for
-- slotted Eggs/Animals (no per-model connections). Bind/Unbind
-- calls live at the Egg/Animal settle/grab/destroy sites; this
-- Init only starts the loop. No service refs needed (leaf).
local StandPresentation = require(script.Parent.StandPresentation)
StandPresentation.Init()

-- Instant-death water: anything with a Humanoid touching
-- Workspace.Water dies (Health = 0), server-authoritative.
-- Leaf module (Workspace lookup + Touched only); resolves
-- defensively so a missing/late Water part never blocks boot.
local WaterHazard = require(script.Parent.Utility.WaterHazard)
WaterHazard.Init()

-- Animal sales (pure calc + atomic transaction, reached
-- from the Sell prompt via SlotActionHandler 'SellAnimal').
-- Wired after every service it reads through; none of them
-- require SellService back at load (SlotActionHandler
-- resolves it lazily; SellService itself requires the
-- handler at load for its prompt callback — one direction),
-- so the wiring is cycle-free. Init wires the Sell prompt
-- dispatch; selling lives on the animal, not in the menu.
SellService.SetPlayerService(PlayerService)
SellService.SetSlotService(SlotService)
SellService.SetBaseService(BaseService)
SellService.SetAnimalService(AnimalService)
SellService.SetEggService(EggService)
SellService.SetEconomyService(EconomyService)
SellService.SetIncomeService(IncomeService)
SellService.SetModifierService(ModifierService)
SellService.Init()
SellService.Init()

-- Phase 2.9: player-facing menu endpoints. No loops — Init only
-- connects the two request remotes (request/response traffic).
SlotMenuService.SetPlayerService(PlayerService)
SlotMenuService.SetBaseService(BaseService)
SlotMenuService.SetSlotService(SlotService)
SlotMenuService.SetAnimalService(AnimalService)
SlotMenuService.SetEggService(EggService)
SlotMenuService.SetModifierService(ModifierService)
SlotMenuService.SetSellService(SellService)
SlotMenuService.Init()

-- Phase 2.10: paid Animal upgrades (pure calc + atomic
-- transaction). No cross-requires at load; all refs below.
UpgradeService.SetPlayerService(PlayerService)
UpgradeService.SetSlotService(SlotService)
UpgradeService.SetBaseService(BaseService)
UpgradeService.SetAnimalService(AnimalService)
UpgradeService.SetEconomyService(EconomyService)
SlotMenuService.SetUpgradeService(UpgradeService)
-- MAIN GAME: per-stand direct-upgrade readout
-- (`UpgradeButton.Level` / `UpgradeAmount`, display-only).
-- StandDisplayService reads the runtime Animal + the
-- UpgradeService cost calc; it is refreshed event-by-event via
-- the SlotService hook below and the SlotMenuService confirm
-- path above. No loops, no scans.
local StandDisplayService = require(script.Parent.Base.StandDisplayService)
StandDisplayService.Init()
StandDisplayService.SetAnimalService(AnimalService)
StandDisplayService.SetUpgradeService(UpgradeService)
-- Stand menu reconciliation also paints live sell totals +
-- egg occupant lookups: same injector pattern, no cycles
-- (StandDisplayService requires only shared leaves).
StandDisplayService.SetSellService(SellService)
StandDisplayService.SetEggService(EggService)
StandDisplayService.SetPlayerService(PlayerService)
SlotMenuService.SetStandDisplayService(StandDisplayService)
-- MAIN GAME: server-authoritative Base locking (owner-only
-- button, per-base owner-exempt collision groups, server
-- timer). Requires BaseService (one-directional, cycle-free);
-- Init runs after RegisterBases below, since it registers the
-- already-discovered bases. The ownership-transition hook is
-- injected into BaseService so assign/release/leave always
-- reset lock state.
local BaseLockService = require(script.Parent.Base.BaseLockService)
BaseService.SetBaseLockService(BaseLockService)
-- Phase 2.11: stateless authorities (require-direct everywhere
-- else); Init documents lifecycle parity with the registry.
TraitService.Init()
MutationService.Init()

-- Event Engine: the generic world-event system (EventConfig
-- defines WHAT, EventService defines HOW). Inited after the
-- egg/mutation authorities exist; started after the center
-- spawner (section 7) so the first schedule sees live eggs.
local EventService = require(script.Parent.Event.EventService)
EventService.Init()

-- Tutorial guide layer (server-authoritative first-time
-- onboarding over the real systems). Leaf bus requires only;
-- inited here, started with the loops in section 7, resumed
-- per player in onPlayerAdded after restore.
local TutorialService = require(script.Parent.Tutorial.TutorialService)
TutorialService.Init()

-- Funnel analytics (central server-side Funnel Events layer).
-- Leaf module: no gameplay depends on it, and it never
-- depends on gameplay. Started with the loops in section 7.
local FunnelService = require(script.Parent.FunnelService)

-- Player monitoring (Discord embeds + all-time registry).
-- Leaf modules: never gameplay-critical, never block joins.
local PlayerLogger = require(script.Parent.PlayerLogger.PlayerLogger)

-- Canonical player-facing errors. Wired right after
-- PlayerService exists so every rejection below can notify.
NotificationService.Init()
NotificationService.SetPlayerService(PlayerService)

-- Phase 2: init the carry registry after all services
-- that depend on it are wired. The registry is the
-- single source of truth for "what is this player
-- carrying" — it dispatches the death-hook recovery
-- to either EggService or AnimalService
-- based on the carried kind.
CarryRegistry.Init()

-- Reset protection gate: subscribes to the registry's committed
-- change feed (grab/place/steal/recover all funnel through
-- CarryRegistry.Set/Clear). Protection is recomputed from live
-- state on every change — no separate flag to go stale.
ResetProtectionService.Init()

-- Carry tool lock: subscribes to the same committed feed
-- (any carry/steal start locks Tools, any release unlocks).
-- Recomputed from live registry state — no separate flag.
ToolLockService.Init()

-- Client presentation settings: remote wiring only (profile is
-- the store, sanitized on read and write).
SettingsService.Init()

-- Grab pose presentation: same committed feed (carry start ->
-- Grab ON, carry end -> Grab OFF, single track per Character).
PlayerGrabService.Init()

-- Phase 2.6: wire the income system. It needs refs to every
-- service it reads through (player data, slots, bases, carry,
-- economy) — none of them require IncomeService back, so the
-- wiring is one-directional and cycle-free. The settlement hook
-- completes the removal contract: PlayerService cannot require
-- EconomyService or IncomeService (Phase 2.1 boundary + cycle),
-- so bootstrap injects the transfer function and every Animal
-- removal calls it before the record leaves the profile.
IncomeService.Init()
IncomeService.SetPlayerService(PlayerService)
IncomeService.SetEconomyService(EconomyService)
IncomeService.SetSlotService(SlotService)
IncomeService.SetBaseService(BaseService)
IncomeService.SetAnimalService(AnimalService)
PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)
-- Phase 2.6.2: slot transitions that change what a CashCollector
-- displays (place / pickup / move / release) republish the pool
-- attribute + MoneyLabel immediately. Same injection pattern as
-- the settlement hook above: SlotService cannot require
-- IncomeService, so bootstrap hands it the publish function.
SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
-- MAIN GAME: the same slot transitions (place / pickup / move /
-- release / assignment re-stamp) repaint the stand's
-- direct-upgrade readout. Same injection pattern: SlotService
-- cannot require StandDisplayService, so bootstrap hands it the
-- refresh function.
SlotService.SetStandDisplayCallback(StandDisplayService.RefreshSlot)

-- --- 4b. Cmdr admin framework ------------------------------------

-- The Cmdr bootstrap registers every command in
-- `Cmdr/Server/Commands/`. We require it here (after the
-- services are wired) so any /command run can use the
-- already-initialized services. Requiring a server script
-- runs it; the script registers its commands as a side
-- effect and prints a diagnostic.
require(script.Parent.Cmdr.Server.CmdrBootstrap)

-- --- 5. Register Studio assets ---------------------------------

BaseService.RegisterBases(Workspace)
EggService.RegisterCenter(Workspace)

-- MAIN GAME: register the discovered bases with the lock
-- service (button touches, clean unlocked visuals, groups).
-- Must run after RegisterBases; before players join.
BaseLockService.Init()

-- Stealing (multiplayer): wire prompt callbacks + arm the
-- per-collector delivery touch routing. Must run after
-- RegisterBases (collectors must exist); before players join.
StealService.SetPlayerService(PlayerService)
StealService.Init()
StealService.Start()

-- Bat PvP (server-authoritative swing validation + hitbox +
-- ragdoll/knockback + steal cancel). Requires StealService only
-- for the idempotent rollback call (no cycle: nothing requires
-- BatService back). Before players join.
BatService.Init()

-- Gear Shop: validate config, publish viewport previews,
-- wire the Shop PromptPart prompt + action remote. Needs only
-- the Remotes folder (created above) and static Studio
-- assets; before players join.
GearShopService.SetPlayerService(PlayerService)
GearShopService.SetEconomyService(EconomyService)
GearShopService.Init()

-- Rebirth: remote wiring only (the service resolves its
-- dependencies by direct require — none require it back except
-- GearShopService, which resolves it lazily).
RebirthService.Init()

-- Global leaderboard: late-bound refs (server profile reads
-- only — the client can never submit a leaderboard value).
-- Money-only: no rebirth wiring (the Tab list ranks
-- rebirths-first separately in TabListService).
-- Start() runs in section 7 with the other loops.
LeaderboardService.SetPlayerService(PlayerService)
LeaderboardService.SetEconomyService(EconomyService)

-- Tab player list: same late-bound shape (server reads only;
-- the native CoreGui list renders, never sorts itself).
TabListService.SetPlayerService(PlayerService)
TabListService.SetEconomyService(EconomyService)
TabListService.SetRebirthService(RebirthService)

-- Stand unlocks: DynamicSlotService resolves per-player Rebirth
-- counts through RebirthService (injected function ref — no
-- require cycle: DynamicSlotService never top-requires it).
-- Unset (specs/headless) = marker/Bases counts only, no unlock cap.
do
	local DynamicSlotService = require(script.Parent.Base.DynamicSlotService)
	DynamicSlotService.SetUnlockResolver(function(userId: number): number
		return RebirthService.ResolveRebirthForStands(userId)
	end)
end

-- Arena: progression reads profiles through PlayerService;
-- the session shell reads base/slot/animal/carry/steal state
-- and notifies through the canonical notification service.
ArenaProgressionService.SetPlayerService(PlayerService)
ArenaService.SetPlayerService(PlayerService)
ArenaService.SetBaseService(BaseService)
ArenaService.SetAnimalService(AnimalService)
ArenaService.SetSlotService(SlotService)
ArenaService.SetCarryRegistry(CarryRegistry)
ArenaService.SetStealService(StealService)
ArenaService.SetNotificationService(NotificationService)
ArenaService.SetProgressionService(ArenaProgressionService)
ArenaService.SetEconomyService(EconomyService)
ArenaService.SetBattleService(ArenaBattleService)
ArenaBattleService.SetAnimalService(AnimalService)
ArenaService.Init()

-- Codes: redeem validation + canonical-service grants +
-- pending delivery. Wired like GearShop/Arena above (setter
-- injection, remote wiring in Init, before players join).
CodesService.SetPlayerService(PlayerService)
CodesService.SetEconomyService(EconomyService)
CodesService.SetSlotService(SlotService)
CodesService.SetEggService(EggService)
CodesService.SetAnimalService(AnimalService)
CodesService.SetGearShopService(GearShopService)
CodesService.Init()

-- DailyRewards: same setter-injection shape (remote wiring in
-- Init, before players join). No join/delivery hooks needed:
-- streak state is pulled on demand and slot-bound rewards
-- reuse the Codes pending queue (join/sell hooks already
-- wired above).
DailyRewardsService.SetPlayerService(PlayerService)
DailyRewardsService.SetEconomyService(EconomyService)
DailyRewardsService.SetGearShopService(GearShopService)
DailyRewardsService.SetCodesService(CodesService)
DailyRewardsService.Init()

-- PlaytimeRewards: same setter-injection shape (remote wiring
-- in Init, before players join).
PlaytimeRewardsService.SetPlayerService(PlayerService)
PlaytimeRewardsService.SetEconomyService(EconomyService)
PlaytimeRewardsService.SetGearShopService(GearShopService)
PlaytimeRewardsService.SetCodesService(CodesService)
PlaytimeRewardsService.Init()

-- Shop monetization: single ProcessReceipt router + paid door
-- prompts. All requires are direct (no cycles: none of the
-- gameplay services require ShopService back). Init after
-- every service it calls into; before players join.
local ShopService = require(script.Parent.Shop.ShopService)
local DoorService = require(script.Parent.Shop.DoorService)
ShopService.Init()
DoorService.Init()

-- --- 5b. Replicated Arena hit-presentation assets ----------------
-- LocalScripts cannot read ServerStorage: mirror the authored
-- Arena hit assets into ReplicatedStorage once at boot (same
-- move-a-copy pattern as CmdrClient above). The ServerStorage
-- originals stay authoritative; Studio-authored mirrors are
-- never overwritten (check-then-create). Missing sources
-- degrade gracefully (client damage number + camera still
-- work; VFX/sound warn once there).
--
-- Authoritative hit VFX source (Studio-authored, Attachment):
--   ServerStorage.Assets.Vfx.HitVfx.Attack1
-- Replicated deterministically (COMPLETE hierarchy, never
-- flattened) to:
--   ReplicatedStorage.Assets.Vfx.HitVfx.Attack1
local function mirrorArenaHitAssets()
	local function pass(): number
		local mirrored = 0
		local ok = pcall(function()
			local srcAssets = ServerStorage:FindFirstChild('Assets')
			if srcAssets == nil then
				return
			end
			local dstAssets = ReplicatedStorage:FindFirstChild('Assets')
			if dstAssets == nil then
				local created = Instance.new('Folder')
				created.Name = 'Assets'
				created.Parent = ReplicatedStorage
				dstAssets = created
			end
			-- Hit VFX: nested-path mirror (Vfx/HitVfx/Attack1 on
			-- both sides). Creates every folder in the chain as
			-- needed; clones the COMPLETE Attack1 hierarchy once.
			local function mirrorHitVfx(): number
				local srcVfx = (srcAssets :: Instance):FindFirstChild('Vfx')
				local srcHit = srcVfx and srcVfx:FindFirstChild('HitVfx') or nil
				local src = srcHit and srcHit:FindFirstChild('Attack1') or nil
				if src == nil then
					return 0
				end
				local dstVfx = (dstAssets :: Instance):FindFirstChild('Vfx')
				if dstVfx == nil then
					local created = Instance.new('Folder')
					created.Name = 'Vfx'
					created.Parent = dstAssets
					dstVfx = created
				end
				local dstHit = (dstVfx :: Instance):FindFirstChild('HitVfx')
				if dstHit == nil then
					local created = Instance.new('Folder')
					created.Name = 'HitVfx'
					created.Parent = dstVfx
					dstHit = created
				end
				if (dstHit :: Instance):FindFirstChild('Attack1') == nil then
					local clone = (src :: Instance):Clone()
					clone.Parent = dstHit
				end
				return 1
			end
			mirrored += mirrorHitVfx()
			local arena = (dstAssets :: Instance):FindFirstChild('Arena')
			if arena == nil then
				local created = Instance.new('Folder')
				created.Name = 'Arena'
				created.Parent = dstAssets
				arena = created
			end
			local function mirrorOne(srcParentName: string, names: { string }, dstParentName: string)
				local srcRoot = (srcAssets :: Instance):FindFirstChild(srcParentName)
				if srcRoot == nil then
					return
				end
				local dstRoot = (arena :: Instance):FindFirstChild(dstParentName)
				if dstRoot == nil then
					local created = Instance.new('Folder')
					created.Name = dstParentName
					created.Parent = arena
					dstRoot = created
				end
				for _, name in ipairs(names) do
					if (dstRoot :: Instance):FindFirstChild(name) == nil then
						local src = (srcRoot :: Instance):FindFirstChild(name)
						if src ~= nil then
							local clone = src:Clone()
							clone.Parent = dstRoot
							mirrored += 1
						end
					else
						mirrored += 1
					end
				end
			end
			mirrorOne('Sfx', { 'Attack1', 'Attack2', 'Attack3' }, 'Sfx')
		end)
		if not ok then
			warn('[ArenaHit] asset mirror failed — client hit VFX/sound degrade to number+camera')
		end
		return mirrored
	end
	-- 4 slots expected: Vfx/HitVfx/Attack1 + Sfx/Attack1..3. A
	-- single non-blocking retry covers Studio assets that
	-- replicate after boot; Studio-authored mirrors are never
	-- overwritten (check-then-create above). Missing sources
	-- degrade gracefully (client damage number + camera still
	-- work; VFX/sound warn once there).
	if pass() < 4 then
		task.delay(5, function()
			pass()
		end)
	end
end
mirrorArenaHitAssets()

-- --- 5c. Replicated music templates --------------------------------
-- Clients can NEVER see ServerStorage, so the Studio-authored
-- music tracks (ServerStorage.Assets.Sfx.Bgm / ArenaBgm) are
-- mirrored to ReplicatedStorage.Assets.Sfx once at boot (same
-- check-then-create pattern as the arena mirror above: Studio
-- mirrors never overwritten, missing sources degrade to
-- music-disabled on the client). The client clones the mirror
-- into SoundService (templates under ReplicatedStorage cannot
-- play) and plays the clone through the BgmSound group.
local function mirrorMusicAssets()
	pcall(function()
		local srcAssets = ServerStorage:FindFirstChild('Assets')
		local srcSfx = srcAssets and srcAssets:FindFirstChild('Sfx') or nil
		if srcSfx == nil then
			return
		end
		local dstAssets = ReplicatedStorage:FindFirstChild('Assets')
		if dstAssets == nil then
			local created = Instance.new('Folder')
			created.Name = 'Assets'
			created.Parent = ReplicatedStorage
			dstAssets = created
		end
		local dstSfx = (dstAssets :: Instance):FindFirstChild('Sfx')
		if dstSfx == nil then
			local created = Instance.new('Folder')
			created.Name = 'Sfx'
			created.Parent = dstAssets
			dstSfx = created
		end
		for _, name in ipairs({ 'Bgm', 'ArenaBgm' }) do
			if (dstSfx :: Instance):FindFirstChild(name) == nil then
				local src = (srcSfx :: Instance):FindFirstChild(name)
				if src ~= nil then
					local clone = src:Clone()
					clone.Parent = dstSfx
				end
			end
		end
	end)
end
	mirrorMusicAssets()

-- --- 5d. Replicated personal-SFX templates ------------------------------
-- LocalScripts can NEVER read ServerStorage, so the personal
-- feedback stings the clients play themselves
-- (typewriter Pop, tutorial Approved, upgrade LevelUp, UI
-- UiClick/UiOpen/UiHover) are mirrored to
-- ReplicatedStorage.Assets.Sfx once at boot (same
-- check-then-create pattern as above: Studio mirrors never
-- overwritten, missing sources degrade to silent on the
-- client). This is the ONE SFX mirror — services must not
-- run competing mirrors. The server never plays these
-- templates directly; UI sounds play from the client's own
-- LocalScript clones (PlayerGui-parented), so each player
-- hears ONLY their own UI, never anyone else's.
local function mirrorPersonalSfx()
	pcall(function()
		local srcAssets = ServerStorage:FindFirstChild('Assets')
		local srcSfx = srcAssets and srcAssets:FindFirstChild('Sfx') or nil
		if srcSfx == nil then
			return
		end
		local dstAssets = ReplicatedStorage:FindFirstChild('Assets')
		if dstAssets == nil then
			local created = Instance.new('Folder')
			created.Name = 'Assets'
			created.Parent = ReplicatedStorage
			dstAssets = created
		end
		local dstSfx = (dstAssets :: Instance):FindFirstChild('Sfx')
		if dstSfx == nil then
			local created = Instance.new('Folder')
			created.Name = 'Sfx'
			created.Parent = dstAssets
			dstSfx = created
		end
		for _, name in ipairs({ 'Pop', 'Approved', 'LevelUp', 'UiClick', 'UiOpen', 'UiHover' }) do
			if (dstSfx :: Instance):FindFirstChild(name) == nil then
				local src = (srcSfx :: Instance):FindFirstChild(name)
				if src ~= nil and src:IsA('Sound') then
					local clone = src:Clone()
					clone.Parent = dstSfx
				else
					Debug.Warn('BS', 'personal SFX missing — clients run silent for it', { asset = name })
				end
			end
		end
	end)
end
mirrorPersonalSfx()

-- --- 6. Player lifecycle ----------------------------------------

-- Spawn ownership: the assigned base determines the player's
-- spawn. Roblox must NOT auto-create the character on join —
-- the character may only load AFTER BaseService has assigned
-- the base AND player.RespawnLocation points at that base's
-- SpawnLocation (see PointPlayerToBaseSpawn below). Otherwise
-- the character spawns at the default SpawnLocation before
-- the base exists and visibly pops across the map on the
-- follow-up teleport. CharacterAutoLoads therefore stays
-- false for the whole session: join AND every death respawn
-- below go through the explicit LoadCharacter calls in this
-- file (never the engine), so ordering is identical on both
-- paths and RespawnLocation is always settled first.
Players.CharacterAutoLoads = false

-- Death-respawn delay (the engine's RespawnTime is inert
-- while CharacterAutoLoads is false — this constant governs
-- the manual respawn instead). Short enough to feel native,
-- long enough for death recovery (carry rollback) to settle.
local RESPAWN_DELAY_SECONDS = 5
-- userId -> respawn generation. Every death bumps the
-- generation and only the latest scheduled respawn fires:
-- simultaneous Died/Destroying edges can never double-load
-- a character, and a stale delay can never kill a fresh
-- spawn. Cleared on leave (the Parent check below already
-- guards it, but explicit cleanup leaves no residue).
local _respawnGen: { [number]: number } = {}

-- Manual death respawn (the ONLY death-respawn path — no
-- engine auto-load, no competing system). Called from the
-- Humanoid.Died / Character.Destroying hooks in
-- onCharacterAdded. Never throws, never yields the caller
-- (the delay rides a spawned thread).
local function requestRespawn(respawnPlayer: Player)
	local userId = respawnPlayer.UserId
	_respawnGen[userId] = (_respawnGen[userId] or 0) + 1
	local generation = _respawnGen[userId]
	task.delay(RESPAWN_DELAY_SECONDS, function()
		-- Stale delay (a newer death already scheduled its
		-- own respawn): do nothing.
		if _respawnGen[userId] ~= generation then
			return
		end
		-- Left during the delay: the Player instance is gone
		-- (Parent == nil after removal). Never touch it. A
		-- rejoin creates a NEW Player object, so a stale delay
		-- from the old session can never hit the new one.
		if respawnPlayer.Parent == nil then
			return
		end
		-- Already alive again (admin revive, edge-case
		-- double-fire): never destroy a live character.
		local character = respawnPlayer.Character
		if character ~= nil and character.Parent ~= nil then
			local hum = character:FindFirstChildOfClass('Humanoid')
			if hum ~= nil and hum.Health > 0 then
				return
			end
		end
		-- RespawnLocation is the spawn source of truth
		-- (re-pointed on join AND rebirth). If it is somehow
		-- gone, LoadCharacter still proceeds — the engine
		-- falls back to a default spawn and moveToBase below
		-- corrects the position on CharacterAdded.
		if respawnPlayer.RespawnLocation == nil or respawnPlayer.RespawnLocation.Parent == nil then
			Debug.Warn('BS', 'respawn without a live RespawnLocation; loading anyway (moveToBase corrects)', {
				userId = tostring(userId),
			})
		end
		Debug.Log('BS', 'respawning after death', { userId = tostring(userId) })
		-- LoadCharacter destroys the dead character first,
		-- so the corpse is always cleaned up before the new
		-- character is created. pcall: a removed/kicked
		-- player must never error the delay thread.
		pcall(function()
			respawnPlayer:LoadCharacter()
		end)
	end)
end

local function onPlayerAdded(player: Player)
	Debug.Log('BS', '> onPlayerAdded', { name = player.Name, userId = tostring(player.UserId) })
	-- Capacity check.
	if #Players:GetPlayers() > Bases.Server.MaxPlayers then
		player:Kick(
			'Server is full (max ' .. tostring(Bases.Server.MaxPlayers) .. ' players). Please try again later.'
		)
		return
	end

	Debug.Log('BS', 'onPlayerAdded: LoadPlayerData starting')
	if not PlayerService.LoadPlayerData(player) then
		Debug.Log('BS', 'onPlayerAdded: LoadPlayerData FAILED, returning')
		return
	end
	Debug.Log('BS', 'onPlayerAdded: LoadPlayerData ok, assigning base')

	-- Assign a base.
	local base = BaseService.AssignBaseForPlayer(player.UserId)
	if not base then
		player:Kick('No base available — please try again later.')
		PlayerService.CleanupPlayer(player.UserId)
		return
	end

	PlayerService.AssignBase(player.UserId, base.id)
	Debug.Log('BS', 'onPlayerAdded: base assigned', { baseId = base.id, spawnCFrame = tostring(base.spawnCFrame) })

	-- Spawn ownership: the assigned base's SpawnLocation becomes
	-- this player's RespawnLocation BEFORE the character loads.
	-- On failure (no valid SpawnLocation) do NOT load a
	-- character: release the base, clean up, and kick, mirroring
	-- the no-base path above.
	if not BaseService.PointPlayerToBaseSpawn(player, base) then
		BaseService.ReleasePlayerBase(player.UserId)
		PlayerService.CleanupPlayer(player.UserId)
		player:Kick('Base spawn unavailable — please try again later.')
		return
	end

	-- Arena: wire the base Adventurer entry point (prefers
	-- authored Base/Adventurer; creates one clearly marked
	-- temporary NPC only when absent). Idempotent per base.
	pcall(ArenaService.EnsureAdventurer, base)

	-- MAIN GAME: apply the owner's lock collision group to the
	-- live character (no-op when the base isn't locked).
	-- Respawn re-application happens in onCharacterAdded below.
	if player.Character then
		BaseLockService.RefreshCharacter(player)
	end

	-- Re-occupy any persisted animal / lucky egg slots and
	-- ask the services to re-spawn their models. This MUST
	-- happen before MarkLoaded so the initial PlayerState
	-- push reflects the restored slots.
	local profileData = PlayerService.GetPlayerData(player.UserId)
	if profileData then
		BaseService.RestorePlayerBase(player.UserId, profileData)
	end

	-- Phase 2.6: apply offline earnings into the restored
	-- Animals' CashPools BEFORE the loaded state is pushed, so
	-- the client never sees a pool that omits the offline window.
	-- Consumes the captured LastSeen exactly once.
	IncomeService.ApplyOfflineEarnings(player)

	-- Codes: normalize the redemption slice and deliver any
	-- queued code rewards (eggs/animals waiting for a free
	-- slot) BEFORE the loaded state is pushed, so the first
	-- snapshot already includes them.
	pcall(CodesService.OnPlayerReady, player)
	-- PlaytimeRewards: start the session clock + arm threshold
	-- pushes immediately so the topbar alert can turn ON
	-- without the player opening anything.
	pcall(PlaytimeRewardsService.OnPlayerReady, player)

	-- Mark the player as fully loaded (data + base assigned).
	PlayerService.GetLoadedSignal(player.UserId):Fire()
	PlayerService.MarkLoaded(player.UserId)
	Debug.Log('BS', 'onPlayerAdded: marked loaded, pushing initial state')

	-- Push initial state.
	local snap = BaseService.Snapshot(player.UserId)
	Debug.Log('BS', 'onPlayerAdded: snapshot', {
		occupied = snap and snap._occupiedCount or 0,
		slotCount = snap and #snap.slots or 0,
	})
	PlayerService.PushState(player, snap)
	-- Reset gate: explicit initial sync (transient state, never
	-- persisted — a join starts unprotected unless a live carry
	-- genuinely exists for this user).
	ResetProtectionService.Refresh(player)
	-- Gear Shop AutoBuy: profile is loaded and money seeded by
	-- now — attempt each enabled gear once, silently.
	pcall(GearShopService.OnPlayerReady, player)
	-- Shop: re-apply the 2X Money gamepass entitlement for the
	-- session (silent; entitlement re-resolves every join).
	pcall(ShopService.OnPlayerReady, player)
	-- Arena: normalize progression on the loaded profile so
	-- older saves gain { Level=1, XP=0, Wins=0 } without
	-- touching any other field.
	pcall(function()
		ArenaProgressionService.NormalizeArena(PlayerService.GetPlayerData(player.UserId))
	end)
	-- Rebirth: restore the persisted money multiplier into the
	-- session authority (ModifierService is per-session and
	-- forgets on leave). Idempotent no-op at Rebirth 0.
	pcall(RebirthService.ApplySessionModifiers, player.UserId)
	-- Client presentation settings: push saved volumes/toggle so
	-- the Settings UI restores on join.
	pcall(SettingsService.PushSettings, player)
	-- Tutorial: resume first-time onboarding from persisted
	-- state validated against live registries (fresh BuyEgg for
	-- new players; skips completed). Runs after restore so
	-- tracked eggs/animals resolve.
	pcall(TutorialService.ResumeForPlayer, player)
	-- Player monitoring: join log + registry upsert (spawned
	-- internally — never blocks the join pipeline).
	pcall(PlayerLogger.NotifyJoin, player)
	-- No join/welcome toast: notifications exist for player
	-- actions and results, not onboarding flavor. (Admin
	-- wipe/reset notices below stay — they report real state
	-- changes to the affected player.)

	-- Warm the CashClaim SFX pool BEFORE the first collect can
	-- happen: pool creation + asset download get a head start
	-- while the player walks to their collector. Non-blocking;
	-- Play self-heals if PlayerGui isn't ready yet.
	task.spawn(function()
		local okGui = pcall(function()
			return player:WaitForChild('PlayerGui', 10)
		end)
		if okGui then
			CollectFeedback.Warm(player)
		end
	end)

	-- Exact base placement on every spawn. The native spawn
	-- already lands on the player's own base (RespawnLocation
	-- points at the assigned base's SpawnLocation); this snaps
	-- the character to the exact stand height (spawnCFrame +
	-- join lift) on first spawn AND on every respawn so the
	-- player always returns to precisely their own base.
	local function moveToBase(spawnedCharacter: Model)
		if not spawnedCharacter then
			return
		end
		local hrp = spawnedCharacter:FindFirstChild('HumanoidRootPart')
		if hrp then
			-- RespawnLocation is the spawn source of truth (it
			-- is re-pointed on rebirth/base swap; the `base`
			-- upvalue above goes stale after a swap). Fall back
			-- to the join-time base only when it is missing.
			local anchor: CFrame? = nil
			pcall(function()
				local respawn = player.RespawnLocation
				if respawn ~= nil and respawn.Parent ~= nil then
					anchor = (respawn :: SpawnLocation).CFrame
				end
			end)
			if anchor == nil then
				anchor = base.spawnCFrame
			end
			hrp.CFrame = (anchor :: CFrame) + Vector3.new(0, BaseConfig.Spawn.JoinLiftStuds, 0)
		end
	end
	local function onCharacterAdded(spawnedCharacter: Model)
		Debug.Log('BS', '> onCharacterAdded')
		moveToBase(spawnedCharacter)
		-- MAIN GAME: the owner keeps the base after death, so the
		-- respawned character must rejoin the owner's lock
		-- collision group (still a no-op when unlocked).
		BaseLockService.RefreshCharacter(player)
		-- Resize character to fit the base footprint.
		-- Canonical: PlayerConfig (values preserved exactly).
		local hum = spawnedCharacter:FindFirstChildOfClass('Humanoid')
		if hum then
			hum.WalkSpeed = PlayerConfig.WalkSpeed
			hum.JumpPower = PlayerConfig.JumpPower
		end
		-- Phase 1.5: on death, recover any carried animal
		-- so the rejoin path is consistent with a
		-- disconnect-while-carrying. Roblox's Humanoid.Died
		-- fires once per character. We do NOT clean up the
		-- carry here — the death hook below handles it; the
		-- AnimalService.RecoverCarriedAnimal function
		-- is safe to call on any path that destroys the
		-- player character.
		-- `hum` is nil-guarded: a malformed character without
		-- a Humanoid must never throw inside onCharacterAdded
		-- and skip ResetProtection/gear re-grant below.
		if hum then
			hum.Died:Connect(function()
				Debug.Log('BS', '> Humanoid.Died, recovering carry', { userId = tostring(player.UserId) })
				-- Steal (multiplayer): a steal-carry rolls back to
				-- the ORIGINAL owner via StealService — never
				-- through the owner-assuming generic recover below
				-- (which would misplace the record/profile).
				if StealService.RollbackIfStealing(player.UserId, 'death') then
					requestRespawn(player)
					return
				end
				-- Phase 2: dispatch on the carried kind. A
				-- animal uses AnimalService.Recover, a
				-- lucky egg uses EggService.Recover.
				-- CarryRegistry is the single source of truth
				-- for "what is this player carrying".
				local kind = CarryRegistry.GetKind(player.UserId)
				if kind == SlotType.OccupantKind.Animal then
					AnimalService.RecoverCarriedAnimal(player.UserId, 'death')
				elseif kind == SlotType.OccupantKind.Egg then
					EggService.RecoverCarriedEgg(player, 'death')
				end
				-- Death respawn: CharacterAutoLoads is false by
				-- design (see section 6), so the engine never
				-- reloads — schedule the manual respawn AFTER
				-- recovery above settles. Generation-guarded:
				-- exactly one LoadCharacter per death, no
				-- matter how Died/Destroying interleave.
				requestRespawn(player)
			end)
		end
		-- Unexpected Character loss WITHOUT death (script destroy,
		-- server-side replacement, teleport edge): run the SAME
		-- authoritative recovery exactly once. Guarded by a live
		-- CarryRegistry entry — the Died path above already
		-- cleared genuine deaths synchronously, so no
		-- double-recovery is possible. (Reset protection blocks
		-- the intentional-reset path; this covers everything else.)
		spawnedCharacter.Destroying:Connect(function()
			-- Destroy-without-death that still leaves the player
			-- characterless: schedule the same guarded respawn
			-- so no edge can strand a player without a
			-- character. Skipped when a replacement already
			-- exists (LoadCharacter swap destroys the old
			-- character while the new one is assigned — that
			-- path must never schedule a second load), and
			-- when the destroyed character was still alive
			-- (live-swap teardown, not a death).
			local deadOrGone = player.Character == nil or player.Character == spawnedCharacter
			if deadOrGone then
				pcall(function()
					local deadHum = spawnedCharacter:FindFirstChildOfClass('Humanoid')
					if deadHum ~= nil and deadHum.Health > 0 then
						deadOrGone = false
					end
				end)
			end
			if CarryRegistry.Get(player.UserId) == nil then
				if deadOrGone then
					requestRespawn(player)
				end
				return
			end
			Debug.Log('BS', '> Character.Destroying with active carry, recovering', {
				userId = tostring(player.UserId),
			})
			if StealService.RollbackIfStealing(player.UserId, 'character-destroyed') then
				if deadOrGone then
					requestRespawn(player)
				end
				return
			end
			local kind = CarryRegistry.GetKind(player.UserId)
			if kind == SlotType.OccupantKind.Animal then
				AnimalService.RecoverCarriedAnimal(player.UserId, 'character-destroyed')
			elseif kind == SlotType.OccupantKind.Egg then
				EggService.RecoverCarriedEgg(player, 'character-destroyed')
			end
			if deadOrGone then
				requestRespawn(player)
			end
		end)
		-- Reset gate re-sync: the fresh Character must never
		-- inherit a stale disabled-reset presentation. Recovery
		-- above already cleared genuine carries (pushing DISABLE
		-- via the registry feed); this covers the no-carry case
		-- and any ordering edge with a change-only push cache.
		ResetProtectionService.Refresh(player)
		-- Gear Shop: session-owned Tools are CanBeDropped=false
		-- (death returns them to the Backpack), but an
		-- equipped-then-destroyed edge or a missed grant must
		-- never leave an owned gear unprovisioned. Re-grants,
		-- then re-equips the session choice (join-equipped bat
		-- preserved across respawns; only a fresh join resets
		-- to DefaultBat). Idempotent: existing Tools are never
		-- duplicated.
		pcall(GearShopService.OnCharacterSpawned, player)
		Debug.Log('BS', '< onCharacterAdded done')
	end
	player.CharacterAdded:Connect(onCharacterAdded)
	if player.Character then
		onCharacterAdded(player.Character)
	end

	-- First character load: RespawnLocation already points at
	-- the assigned base's SpawnLocation (set above), so the
	-- manual spawn lands on the player's own base; every
	-- later death respawns through requestRespawn (same
	-- RespawnLocation, same moveToBase correction). Skipped
	-- only when a character already exists (Studio catch-up
	-- path), which the onCharacterAdded call above already
	-- positioned.
	if player.Character == nil then
		Debug.Log('BS', 'onPlayerAdded: loading character', { baseId = base.id })
		player:LoadCharacter()
	end
	-- Global leaderboard: throttled early board refresh so a
	-- joiner sees the current global top promptly. No write
	-- here — the periodic scan picks this player up once the
	-- profile above is settled (never a zero-overwrite).
	LeaderboardService.RequestRefresh()
	-- Tab player list: include the joiner promptly (throttled
	-- refresh; stats read live profiles only).
	TabListService.RequestRefresh()
end

local function onPlayerRemoving(player: Player)
	Debug.Log('BS', '> onPlayerRemoving', { name = player.Name, userId = tostring(player.UserId) })
	local userId = player.UserId
	-- Global leaderboard: final write FIRST, while the
	-- profile is still loaded (CleanupPlayer below releases
	-- it). Non-blocking (spawned write); never fails cleanup.
	LeaderboardService.OnPlayerLeaving(player)
	-- Tab player list: refresh promptly (the leaver's
	-- leaderstats die with them; throttled).
	TabListService.RequestRefresh()
	-- Player monitoring: leave log + registry write (embed
	-- from memory instantly; DataStore write spawned — never
	-- blocks cleanup). Profile still loaded here, so the
	-- rebirth snapshot is exact.
	pcall(PlayerLogger.NotifyLeave, player)
	-- Death respawn: drop the pending generation (the delay
	-- thread's Parent check already guards it, but explicit
	-- cleanup leaves no residue for the next session).
	_respawnGen[userId] = nil
	-- Order: animals first (they reference slots), then lucky
	-- eggs, then base (which releases slots), then player data.
	AnimalService.CleanupPlayer(userId)
	EggService.CleanupPlayer(userId)
	BaseService.CleanupPlayer(userId)
	PlayerService.CleanupPlayer(userId)
	-- Spawn hygiene: the base is released above, so drop the
	-- player's pointer at its SpawnLocation. The Player object
	-- is going away, but an explicit clear guarantees no stale
	-- spawn state can ever leak across a rejoin edge.
	player.RespawnLocation = nil
	-- Phase 2.6: drop the player's per-session income state
	-- (debounce + fractional remainders). Pool value lives on the
	-- profile record, so nothing collectible is lost here.
	IncomeService.ForgetPlayer(userId)
	-- Phase 2.7: drop session modifier sources + debug throttle
	-- state. Sources are never persisted (no current source needs
	-- it), so a rejoin always starts from the deterministic 1x
	-- defaults until sources are re-added.
	ModifierService.ForgetPlayer(userId)
	-- Phase 2.9: drop menu endpoint throttle state.
	SlotMenuService.ForgetPlayer(userId)
	-- Canonical errors: drop per-player notification throttle
	-- state (reason windows, gap floor, burst stamps).
	NotificationService.ForgetPlayer(userId)
	-- Cash feedback: drop the SFX pool rotation cursor (pool
	-- instances live in PlayerGui and die with the player).
	CollectFeedback.ForgetPlayer(userId)
	-- MAIN GAME: drop lock character connections. The base
	-- itself is already unlocked by BaseService.CleanupPlayer
	-- above (via the injected HandleBaseReleased hook).
	BaseLockService.ForgetPlayer(player)
	-- Reset gate: drop the per-player push cache. Transaction
	-- cleanup above (CleanupPlayer -> recover/rollback ->
	-- CarryRegistry.Clear) already resolved any live carry; the
	-- client is gone so there is nothing to push. Transient
	-- state is never persisted — a rejoin starts unprotected.
	ResetProtectionService.ForgetPlayer(userId)
	-- Carry tool lock: drop the per-player push cache. Same
	-- reasoning — the client is gone, nothing to push.
	ToolLockService.ForgetPlayer(userId)
	-- Rebirth: drop the in-flight flag and destroy parked
	-- template previews. Live/profile state untouched.
	RebirthService.ForgetPlayer(userId)
	-- Tutorial: drop runtime step tracking (persisted progress
	-- stays; rejoin resumes from it).
	pcall(TutorialService.ForgetPlayer, userId)
	-- Gear Shop: drop session ownership + purchase mutex.
	-- AutoBuy preferences live on the profile (persisted);
	-- session gear dies with the player by design.
	GearShopService.ForgetPlayer(userId)
	-- Arena: clean any active expedition session (no rewards
	-- on leave) + drop nothing else (progression persists).
	ArenaService.ForgetPlayer(userId)
	-- Codes: drop redemption mutexes + delivery guards.
	-- Redeemed/pending state lives on the profile (persisted);
	-- only transient per-request flags die here.
	CodesService.ForgetPlayer(userId) -- DailyRewards: drop the per-player claim mutex. Streak
	-- state lives on the profile (persisted).
	DailyRewardsService.ForgetPlayer(userId)
	-- PlaytimeRewards: drop the live session (playtime is
	-- session-based by design) + claim mutex. Claimed-pool
	-- progress lives on the profile (persisted).
	PlaytimeRewardsService.ForgetPlayer(userId)
	-- Shop: drop pending door-purchase contexts + throttle
	-- stamps (receipt path revalidates regardless).
	DoorService.ForgetPlayer(userId)
	-- Shop: drop ShopAction throttle stamps.
	ShopService.ForgetPlayer(userId)
	-- Funnel analytics: end the player's session (memory-only
	-- session id + per-session dedupe; no persisted state).
	FunnelService.ForgetPlayer(userId)
	-- Global leaderboard: drop session write/diff state (the
	-- global OrderedDataStore entry persists by design).
	LeaderboardService.ForgetPlayer(userId)
	Debug.Log('BS', '< onPlayerRemoving done')
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- In case players joined before the script ran (Studio testing).
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, p)
end

-- --- 7. Start the center spawner + the income loop --------------

EggService.Start()

-- Event Engine loop (scheduler + lifecycle). Runs after the
-- center spawner so boot scheduling counts live eggs.
EventService.Start()

-- Tutorial recovery loop (validates tracked tutorial refs at
-- 1 Hz for active-tutorial players only; registries by id,
-- never Workspace scans).
TutorialService.Start()

-- Funnel analytics sessions (registers join stamps for
-- per-session milestone dedupe; no loops, no polling).
FunnelService.Start()

-- Player monitoring (reads the webhook attribute, starts the
-- async delivery worker; registry-only when unconfigured).
PlayerLogger.Init()

-- Global leaderboard loops (debounced OrderedDataStore
-- writes + 60 s board refresh + ResetTime countdown).
-- Runs after the income loop so join-time scans already see
-- settled profiles.
LeaderboardService.Start()

-- Tab player list (native leaderstats upkeep; cheap live
-- reads, no DataStores). Same placement: after profiles
-- settle.
TabListService.Start()

-- Phase 2.6: start the ONE central income loop. Must run after
-- RegisterBases (the stand Button.PressPart cash triggers must exist) — see
-- section 5 above.
IncomeService.Start()

-- --- 8. Studio-cmd-bar helpers ----------------------------------

-- Expose a small admin surface on the global env so the
-- developer can run common ops from the Studio command bar
-- without restarting the server. These functions are
-- deliberate back-doors: they mutate server state on
-- purpose, so do NOT expose them to clients.

-- selene: allow(global_usage)
--
-- WipePlayer(userId) — reset one player's data to defaults
-- (Money back to EconomyConfig.StartingMoney, BaseId cleared,
-- animal + lucky-egg inventories cleared, base
-- released). Use in Studio after a playtest to retry with
-- a clean slate for the test account.
-- Example (Studio command bar):
--   shared.WipePlayer(12345678)
shared.WipePlayer = function(userId: number)
	Debug.Log('BS', '> WipePlayer (Studio cmd)', { userId = tostring(userId) })
	if not Validation.IsValidPlayerUserId(userId) then
		error('WipePlayer: userId must be a valid Player UserId')
	end
	-- If the player is currently connected, capture the
	-- player reference before the wipe tears down the base.
	local player = Players:GetPlayerByUserId(userId)
	-- WipePlayerData handles the full chain: destroy runtime
	-- instances, release the base, and reset profile data.
	BaseService.WipePlayerData(userId)
	-- If the player is currently connected, assign a fresh
	-- base and push the new state so the HUD reflects the
	-- wipe immediately. The player does not need to rejoin.
	if player then
		local newBase = BaseService.AssignBaseForPlayer(userId)
		if newBase then
			PlayerService.AssignBase(userId, newBase.id)
			-- Spawn ownership follows the fresh base (wipe
			-- releases + reassigns; the next respawn must land
			-- on the new base, never the released one).
			BaseService.PointPlayerToBaseSpawn(player, newBase)
		end
		local snap = BaseService.Snapshot(userId)
		PlayerService.PushState(player, snap)
		PlayerService.Notify(player, 'System', 'Your data was wiped by an admin.')
	end
	Debug.Log('BS', '< WipePlayer done', { userId = tostring(userId) })
end

-- Phase 1.5: trigger the carry-recovery path manually from
-- the Studio command bar. Useful for testing the
-- "original slot invalid" fallback and the Recovering state
-- without having to physically disconnect / die.
-- Example (Studio command bar):
--   shared.RecoverCarry(12345678)
-- selene: allow(global_usage)
shared.RecoverCarry = function(userId: number)
	Debug.Log('BS', '> RecoverCarry (Studio cmd)', { userId = tostring(userId) })
	if not Validation.IsValidPlayerUserId(userId) then
		error('RecoverCarry: userId must be a valid Player UserId')
	end
	-- Phase 2: dispatch on the carried kind. A animal
	-- uses AnimalService.Recover; a lucky egg uses
	-- EggService.Recover.
	-- Steal (multiplayer): steal-carries roll back to the
	-- original owner via StealService first (its PushState
	-- happens in the shared tail below).
	local stealRolledBack = StealService.RollbackIfStealing(userId, 'studio-cmd')
	if not stealRolledBack then
		local kind = CarryRegistry.GetKind(userId)
		if kind == SlotType.OccupantKind.Animal then
			AnimalService.RecoverCarriedAnimal(userId, 'studio-cmd')
		elseif kind == SlotType.OccupantKind.Egg then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				EggService.RecoverCarriedEgg(player, 'studio-cmd')
			else
				-- No Player object — the lucky egg recovery
				-- path needs one (for prompt refresh). The
				-- registry still has the original slot info;
				-- the user can reconnect and force-recover.
				Debug.Warn('BS', 'RecoverCarry: lucky egg recovery needs a connected player; skipping')
			end
		end
	end
	-- If the player is currently connected, push the
	-- updated state so the HUD reflects the recovery.
	local player = Players:GetPlayerByUserId(userId)
	if player then
		local snap = BaseService.Snapshot(userId)
		PlayerService.PushState(player, snap)
	end
	Debug.Log('BS', '< RecoverCarry done', { userId = tostring(userId) })
end

-- --- Diagnostics for Studio output -----------------------------

print(
	'[bootstrap] Server started. Registered '
		.. tostring(Bases.Count)
		.. ' bases, center active max '
		.. tostring(CenterSpawn.CenterMax)
		.. ', starting money '
		.. tostring(EconomyConfig.StartingMoney)
		.. '.'
)
