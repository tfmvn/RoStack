--!strict
--!native
--[[
	PlayerService
	=============
	Owns:
	  * PlayerData lifecycle (loaded from / saved to ProfileService)
	  * Base ownership reference (read-through to BaseService)
	  * Persisted animal + lucky egg inventory (rejoin restores
	    the player's base from this data)
	  * Profile shape for the new string-backed Money field
	    (`profile.Data.Money` + the dormant `Multipliers` table)

	Does NOT own:
	  * Money mutations (EconomyService is the sole mutator of
	    `profile.Data.Money`; this service only reads + reconciles
	    it on profile load and on WipeUser)
	  * Egg runtime state (EggService)
	  * Animal runtime state (AnimalService)
	  * Slot reservation (BaseService)

	Concurrency model:
	  * `Loaded` signal fires once per player when their profile is
	    fully loaded and their base is assigned.
	  * Cleanup runs on PlayerRemoving; ProfileService releases the
	    session lock so future joins can re-load. Persisted
	    animals and lucky eggs stay in the profile and are
	    re-spawned on rejoin by BaseService.RestorePlayerBase.

 	Persistence shape (Phase 2.5.1 + 2.6):
 	  profile.Data.Money  = '0'                     (BigNumber string)
 	  profile.Data.Multipliers = { Money = 1 }      (DEPRECATED compat
 	                               data, Phase 2.7.1: always 1, never
 	                               written by gameplay, retained so old
 	                               profiles reconcile; ModifierService
 	                               is the live modifier authority)
	  profile.Data.Brainrots  = { {Type, SlotId, DefId, Id, Level, XP,
	                               CashPool, Trait, Mutations}, ... }  (CashPool = BigNumber
	                               string; the uncollected cash riding
	                               with that Animal — Phase 2.6)
	  profile.Data.LuckyBlocks = { {Type, SlotId, Rarity, Id, Mutations, Trait}, ... }
	                               (Trait = hidden pending-trait payload, nil normally)
	  profile.Data.LastSeen = 0                     (unix seconds; the
	                               offline-earnings anchor, stamped at
	                               load/leave and heartbeat-refreshed
	                               while online — Phase 2.6)
	These are append/remove lists; ordering is not significant.
	Each record carries a canonical `Id` (the OwnedObjectIdentity
	generated at creation time). The Id is the persistence key:
	it survives slot movement, pickup/carry, same-slot return,
	and leave/rejoin. The `Cash = number` field is GONE — the
	store name below changed and the old store is left in
	DataStore untouched per the user's standing instruction
	("don't delete the old DataStore itself, just change the
	active store name").
]]

local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')

local ProfileService = require(ServerScriptService.Packages.ProfileService)
local Janitor = require(ServerScriptService.Packages.Janitor)

local EconomyConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
local DebugConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local OwnedObjectIdentity = require(script.Parent.Parent.ReplicatedStorage.Utility.OwnedObjectIdentity)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local PersistenceAudit = require(script.Parent.Base.PersistenceAudit)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
local MutationService = require(script.Parent.MutationService)

local PlayerService = {}

-- Per-player state. Keyed by UserId.
type Entry = {
	janitor: any,
	profile: any,
	data: any,
	baseId: string?,
	loadedSignal: any,
	-- Phase 2.6: the PREVIOUS session's LastSeen value, captured at
	-- load and consumed exactly once by ConsumeOfflineTimestamp
	-- (offline earnings). nil after consumption.
	lastSeenAtLoad: number?,
}

local store: { [number]: Entry } = {}

-- --- Profile template --------------------------------------------

-- Profile store name.
--
-- Format:
--
--     p7_<DataType>_v<SchemaVersion>_<Env>
--
-- Phase 2.1 changes the store name from the v2_r3 series
-- (which held the old Cash = number schema) to a new
-- Money_v1 series (which holds the BigNumber-string schema).
-- The old store is left in DataStore per the user's standing
-- instruction: don't delete the old DataStore, just change
-- the active store name. The old dev/test/prod data is
-- abandoned, not migrated. Players on the new store start
-- with a fresh profile.
--
-- ProfileService keys profiles by (StoreName, Key). Changing
-- StoreName creates a completely separate profile namespace,
-- so players joining through the new StoreName receive new
-- profiles instead of accessing data from the previous store.
-- This is the standard ProfileService hard-reset pattern.
local PROFILE_NAME = 'p7_PlayerData_Money_v1_dev_1'
local PROFILE_STORE = ProfileService.GetProfileStore(PROFILE_NAME, {
	UserId = 0,
	-- Phase 2.1: string-backed BigNumber. Zero by default;
	-- reconcile pass in LoadPlayerData seeds StartingMoney
	-- on first join. The Cash = number field is gone.
	Money = '0',
	BaseId = nil,
	Loaded = false,
	-- Rebirth progression (server-authoritative, owned by
	-- RebirthService): count of completed rebirths, 0 = none.
	-- Reconciled in LoadPlayerData for older saves.
	Rebirth = 0,
	-- Tutorial progress (server-authoritative, owned by
	-- TutorialService): Completed gates first-time onboarding,
	-- Step/EggId/AnimalId resume it after rejoin. Reconciled
	-- in LoadPlayerData for older saves.
	Tutorial = { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil },
	-- DEPRECATED multiplier compat field (Phase 2.7.1). Always 1;
	-- no gameplay system writes any other value, and the live
	-- modifier authority is ModifierService (per-player sources,
	-- never persisted). Kept in the template + reconcile + wipe
	-- so profiles with or without the field behave identically.
	Multipliers = { Money = 1 },
	-- Lifetime generation counters (server-authoritative).
	-- Incremented EXACTLY ONCE per successful commit by the
	-- owning service (EggService.Purchase/HatchEgg,
	-- PlayerService.AddAnimal/ConsumeEggIntoAnimal appends,
	-- UpgradeService.UpgradeAnimal) via BumpStat — never on
	-- validation failures, retries, duplicate remotes, or
	-- receipt replays. Survives rebirth (lifetime history is
	-- not progression); resets on WipeUser (fresh start).
	-- Absent on older saves: reconcile seeds zeros and the
	-- bot reports 'Historical total unavailable' rather than
	-- pretending the new counters cover pre-deploy history.
	Stats = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 },
	-- Phase 1 persistence: animals + lucky eggs respawn from
	-- these lists on rejoin. Each entry is keyed by slotId so
	-- removal is idempotent.
	Brainrots = {},
	LuckyBlocks = {},
	-- Gear Shop AutoBuy preferences: [gearId] = true. Session
	-- ownership is NOT persisted (GearShopService owns that);
	-- only the autobuy preference survives rejoin.
	GearAutoBuy = {},
	-- Robux gear entitlements: [gearId] = true for Shop
	-- Developer Product grants (Galaxy Bat). Unlike session
	-- ownership, entitlements persist and re-grant on join.
	OwnedRobuxGear = {},
	-- Client presentation settings (BGM/SFX volumes 0..1,
	-- FastMode toggle). Owned by SettingsService; only the
	-- shape default lives here. Never read for gameplay.
	Settings = { Bgm = 1, Sfx = 1, FastMode = false },
	-- Arena expedition progression (server-authoritative,
	-- owned by ArenaProgressionService): Level/XP/Wins plus
	-- the Phase 3 pending-egg escrow (reserved now so the
	-- persistence shape is final).
	Arena = { Level = 1, XP = 0, Wins = 0, HighestCompleted = 0, PendingEggs = {} },
	-- Redeem codes (server-authoritative, owned by
	-- CodesService): RedeemedCodes maps normalized code Id ->
	-- redemption count; PendingCodeRewards is the FIFO queue of
	-- slot-bound rewards (eggs/animals) that could not be
	-- delivered for lack of a free base slot. Both persist
	-- across rejoins through this same profile.
	RedeemedCodes = {},
	PendingCodeRewards = {},
	-- Daily streak state (server-authoritative, owned by
	-- DailyRewardsService): WeekId keys progress to the
	-- current GLOBAL weekly pool (a new WeekId starts a fresh
	-- 1..7 course), Day is the NEXT claimable day (8 = week
	-- complete), LastClaimAt the unix seconds of the last
	-- committed claim (0 = never).
	DailyRewards = { WeekId = '', Day = 1, LastClaimAt = 0 },
	-- Playtime course progress (server-authoritative, owned by
	-- PlaytimeRewardsService): DayId keys progress to the IST
	-- day it was earned under, PoolId names the session course
	-- pool, Claimed maps milestone index -> true for explicitly
	-- completed claims, Completed marks a fully-claimed course
	-- (next session then picks a fresh pool). Raw session
	-- playtime is NEVER persisted (it resets on leave).
	PlaytimeRewards = { DayId = '', PoolId = '', Claimed = {}, Completed = false },
	-- Phase 2.6: unix seconds of the last confirmed presence
	-- (leave, crash-bounded heartbeat, or load). The NEXT load
	-- computes offline duration as now - captured value; 0 (or
	-- malformed) means "no usable anchor" and pays nothing.
	LastSeen = 0,
})

-- Studio playtest seed. Used when DebugConfig.SkipPersistence
-- is true. Mirrors the PROFILE_STORE template above so every
-- field PlayerService reads/writes has a sane default.
local STUDIO_PROFILE_TEMPLATE = {
	UserId = 0,
	Money = '0',
	BaseId = nil,
	Loaded = false,
	Rebirth = 0,
	Tutorial = { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil },
	Multipliers = { Money = 1 },
	Stats = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 },
	Brainrots = {},
	LuckyBlocks = {},
	GearAutoBuy = {},
	OwnedRobuxGear = {},
	Settings = { Bgm = 1, Sfx = 1, FastMode = false },
	Arena = { Level = 1, XP = 0, Wins = 0, HighestCompleted = 0, PendingEggs = {} },
	RedeemedCodes = {},
	PendingCodeRewards = {},
	DailyRewards = { WeekId = '', Day = 1, LastClaimAt = 0 },
	PlaytimeRewards = { DayId = '', PoolId = '', Claimed = {}, Completed = false },
	LastSeen = 0,
}

-- --- Singleton API ------------------------------------------------

function PlayerService.Init()
	-- No-op: nothing to pre-warm. ProfileService auto-creates the
	-- store. We just expose entry points.
end

-- Phase 2.7: the active profile store name (schema identity) for
-- the developer debug snapshot. Read-only; the store itself is
-- never exposed.
function PlayerService.GetDataVersion(): string
	return PROFILE_NAME
end

-- --- Lifecycle ----------------------------------------------------

function PlayerService.LoadPlayerData(player: Player): boolean
	Validation.LivePlayer(player)
	local userId = player.UserId
	if store[userId] then
		-- Already loaded (re-entrant call). Idempotent.
		return true
	end

	local janitor = Janitor.new()

	-- Phase 2 / Studio playtest escape hatch: when
	-- DebugConfig.SkipPersistence is true (developer sets it from the
	-- Studio command bar), bypass ProfileService entirely and
	-- seed a deterministic in-memory profile. The player gets
	-- StartingMoney and empty animal + lucky-egg lists on
	-- every join, which is fine for playtest. Production code
	-- always hits ProfileService.
	local profile
	if DebugConfig.SkipPersistence then
		Debug.Log(
			'PS',
			'LoadPlayerData: DebugSkipPersistence=true, using in-memory profile',
			{ userId = tostring(userId) }
		)
		-- DEEP copy: table.clone is shallow, so a bare clone would
		-- hand every skip-persistence player the SAME Multipliers /
		-- Animals / Eggs tables — one player's Animal
		-- (and its CashPool) would appear in another's inventory.
		-- Lists start empty anyway; Multipliers is copied per player.
		local data = table.clone(STUDIO_PROFILE_TEMPLATE)
		data.Multipliers = table.clone(STUDIO_PROFILE_TEMPLATE.Multipliers)
		data.Tutorial = table.clone(STUDIO_PROFILE_TEMPLATE.Tutorial)
		data.Brainrots = {}
		data.LuckyBlocks = {}
		data.GearAutoBuy = {}
		data.OwnedRobuxGear = {}
		profile = { Data = data }
	else
		profile = PROFILE_STORE:LoadProfileAsync('Player_' .. tostring(userId), 'ForceLoad')
		if not profile then
			player:Kick('Could not load your saved data. Please rejoin.')
			return false
		end
		profile:AddUserId(userId)
		profile:Reconcile()
	end

	profile.Data.UserId = userId
	-- Seed StartingMoney on a brand-new wallet. A returning
	-- player who already has Money (e.g. from a previous
	-- game session) keeps their existing balance. The
	-- BigNumber.IsZero check accepts "0", "0.0", "00",
	-- ""-after-sanitize, etc.
	if type(profile.Data.Money) ~= 'string' or BigNumber.IsZero(profile.Data.Money) then
		profile.Data.Money = BigNumber.sanitize(EconomyConfig.StartingMoney) or '0'
	end
	profile.Data.Loaded = true
	-- Reconcile the DEPRECATED Multipliers compat field for older
	-- profiles (Phase 2.7.1: the field is always 1 and never
	-- gameplay. A missing or wrong-typed table is filled with 1;
	-- a present numeric value is preserved untouched — the live
	-- modifier authority is ModifierService, which never reads
	-- this field, so preservation here cannot affect income/XP.)
	if type(profile.Data.Multipliers) ~= 'table' then
		profile.Data.Multipliers = { Money = 1 }
	elseif type(profile.Data.Multipliers.Money) ~= 'number' then
		profile.Data.Multipliers.Money = 1
	end
	-- Reconcile lists for older profiles (Animals/Eggs
	-- were added in Phase 1 — older saves may not have them).
	if type(profile.Data.Brainrots) ~= 'table' then
		profile.Data.Brainrots = {}
	end
	if type(profile.Data.LuckyBlocks) ~= 'table' then
		profile.Data.LuckyBlocks = {}
	end
	-- Gear Shop AutoBuy preferences (older saves lack the key;
	-- wrong-typed values are discarded, never migrated).
	if type(profile.Data.GearAutoBuy) ~= 'table' then
		profile.Data.GearAutoBuy = {}
	end
	-- Robux gear entitlements (older saves lack the key;
	-- wrong-typed values are discarded, never migrated).
	if type(profile.Data.OwnedRobuxGear) ~= 'table' then
		profile.Data.OwnedRobuxGear = {}
	end
	-- Lifetime generation counters (older saves lack the key
	-- entirely — seeded to zero, never backfilled; valid
	-- non-negative counts are preserved untouched).
	do
		local defaults = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 }
		if type(profile.Data.Stats) ~= 'table' then
			profile.Data.Stats = table.clone(defaults)
		else
			for key, zero in pairs(defaults) do
				local v = (profile.Data.Stats :: any)[key]
				if type(v) ~= 'number' or v ~= v or v < 0 then
					(profile.Data.Stats :: any)[key] = zero
				else
					(profile.Data.Stats :: any)[key] = math.floor(v)
				end
			end
		end
	end
	-- Arena progression (older saves lack the key entirely).
	-- Shape repair lives in ArenaProgressionService
	-- (NormalizeArena); here we only ensure a table exists.
	if type(profile.Data.Arena) ~= 'table' then
		profile.Data.Arena = { Level = 1, XP = 0, Wins = 0, HighestCompleted = 0, PendingEggs = {} }
	end
	-- Redeem codes (older saves lack the keys entirely).
	-- RedeemedCodes maps normalized code Id -> count (wrong
	-- types discarded, never migrated). PendingCodeRewards only
	-- needs a table here; entry-shape repair lives in
	-- CodesService.NormalizePlayer (bootstrap, mirroring
	-- ArenaProgressionService.NormalizeArena) plus defensive
	-- skips inside TryDeliverPending.
	if type(profile.Data.RedeemedCodes) ~= 'table' then
		profile.Data.RedeemedCodes = {}
	else
		for key, count in pairs(profile.Data.RedeemedCodes) do
			if type(key) ~= 'string' or type(count) ~= 'number' or count < 1 then
				(profile.Data.RedeemedCodes :: any)[key] = nil
			else
				(profile.Data.RedeemedCodes :: any)[key] = math.floor(count)
			end
		end
	end
	if type(profile.Data.PendingCodeRewards) ~= 'table' then
		profile.Data.PendingCodeRewards = {}
	end
	-- Daily streak slice (older saves lack the key entirely;
	-- malformed fields fall back, never migrated).
	do
		local d = profile.Data.DailyRewards
		if type(d) ~= 'table' then
			d = {}
			profile.Data.DailyRewards = d
		end
		if type(d.WeekId) ~= 'string' then
			d.WeekId = ''
		end
		if type(d.Day) ~= 'number' or d.Day ~= math.floor(d.Day) or d.Day < 1 then
			d.Day = 1
		end
		if type(d.LastClaimAt) ~= 'number' or d.LastClaimAt < 0 then
			d.LastClaimAt = 0
		end
	end
	-- Playtime course progress (older saves lack the key
	-- entirely). Claimed maps milestone index -> true;
	-- wrong-typed entries are discarded, never migrated.
	-- Per-milestone truth is re-derived by the service from
	-- thresholds at runtime; this only guarantees shape.
	do
		local p = profile.Data.PlaytimeRewards
		if type(p) ~= 'table' then
			p = {}
			profile.Data.PlaytimeRewards = p
		end
		if type(p.DayId) ~= 'string' then
			p.DayId = ''
		end
		if type(p.PoolId) ~= 'string' then
			p.PoolId = ''
		end
		if type(p.Claimed) ~= 'table' then
			p.Claimed = {}
		else
			for key, value in pairs(p.Claimed) do
				if type(key) ~= 'number' or value ~= true then
					(p.Claimed :: any)[key] = nil
				end
			end
		end
		if type(p.Completed) ~= 'boolean' then
			p.Completed = false
		end
	end
	-- Rebirth count (older saves predate the system).
	if
		type(profile.Data.Rebirth) ~= 'number'
		or profile.Data.Rebirth ~= math.floor(profile.Data.Rebirth)
		or profile.Data.Rebirth < 0
	then
		profile.Data.Rebirth = 0
	end
	-- Tutorial progress (older saves predate the system;
	-- malformed fields fall back individually, never migrated).
	do
		local t = profile.Data.Tutorial
		if type(t) ~= 'table' then
			t = {}
			profile.Data.Tutorial = t
		end
		if type(t.Completed) ~= 'boolean' then
			t.Completed = false
		end
		if type(t.Step) ~= 'string' or t.Step == '' then
			t.Step = 'BuyEgg'
		end
		if type(t.EggId) ~= 'string' then
			t.EggId = nil
		end
		if type(t.AnimalId) ~= 'string' then
			t.AnimalId = nil
		end
	end
	-- Client presentation settings (older saves lack the key;
	-- malformed fields fall back individually, never migrated).
	do
		local s = profile.Data.Settings
		if type(s) ~= 'table' then
			s = {}
			profile.Data.Settings = s
		end
		if type(s.Bgm) ~= 'number' or s.Bgm ~= s.Bgm then
			s.Bgm = 1
		end
		s.Bgm = math.clamp(s.Bgm, 0, 1)
		if type(s.Sfx) ~= 'number' or s.Sfx ~= s.Sfx then
			s.Sfx = 1
		end
		s.Sfx = math.clamp(s.Sfx, 0, 1)
		if type(s.FastMode) ~= 'boolean' then
			s.FastMode = false
		end
	end
	-- Phase 2.5.1: ONE validation layer for the persisted
	-- inventory, run here — before any runtime reconstruction —
	-- on every load. PersistenceAudit repairs in place (identity,
	-- Level/XP normalization, the explicit `Type` stamp),
	-- quarantines (duplicate Ids/SlotIds, cross-kind slot
	-- collisions — the phantom-record shape behind the
	-- rejoin-conversion bug), and reports every anomaly. It never
	-- converts a record's type and never drops a reconstructible
	-- one. The cleaned lists replace the raw ones, so
	-- reconstruction only ever sees audited records.
	local audit = PersistenceAudit.Audit(profile.Data)
	profile.Data.Brainrots = audit.Brainrots
	profile.Data.LuckyBlocks = audit.LuckyBlocks
	if #audit.Issues > 0 then
		Debug.Warn('PS', ('PersistenceAudit: %d issue(s) on load'):format(#audit.Issues), {
			userId = tostring(userId),
			quarantined = tostring(audit.Quarantined),
			repaired = tostring(audit.Repaired),
		})
		for _, issue in ipairs(audit.Issues) do
			Debug.Warn('PS', issue, { userId = tostring(userId) })
		end
	end
	Debug.Log('PS', 'PersistenceAudit summary', {
		userId = tostring(userId),
		animals = tostring(#audit.Brainrots),
		eggs = tostring(#audit.LuckyBlocks),
		issues = tostring(#audit.Issues),
		quarantined = tostring(audit.Quarantined),
		repaired = tostring(audit.Repaired),
	})

	-- Phase 2.6: offline-earnings timestamp, CAPTURE-THEN-STAMP.
	-- The previous session's stamp is captured into the entry
	-- (IncomeService consumes it exactly once via
	-- ConsumeOfflineTimestamp to compute the offline window), then
	-- LastSeen is stamped with NOW. The ordering is the crash-safety
	-- guarantee: a crash between this stamp and the offline payout
	-- LOSES this session's offline credit (bounded by the heartbeat
	-- refresh) — it can never pay the same offline window twice.
	-- A malformed or absent stamp captures 0, which the consumer
	-- must treat as "no anchor: pay nothing" (a fresh profile or a
	-- DebugSkipPersistence session otherwise would compute a
	-- full-window payout against unix epoch 0).
	local lastSeen = profile.Data.LastSeen
	if type(lastSeen) ~= 'number' or lastSeen ~= lastSeen or lastSeen == math.huge or lastSeen == -math.huge then
		lastSeen = 0
	end
	profile.Data.LastSeen = os.time()

	local entry: Entry = {
		janitor = janitor,
		profile = profile,
		data = profile.Data,
		baseId = nil,
		loadedSignal = nil,
		lastSeenAtLoad = lastSeen,
	}
	store[userId] = entry

	janitor:Add(function()
		store[userId] = nil
	end, true)

	-- In DebugConfig.SkipPersistence mode there's no real profile
	-- object to Release, so skip the janitor Add. In normal
	-- mode, ProfileService owns the release.
	if not DebugConfig.SkipPersistence then
		janitor:Add(profile, 'Release')
	end

	janitor:Add(Players.PlayerRemoving:Connect(function(plr: Player)
		if plr.UserId == userId then
			janitor:Cleanup()
		end
	end))

	return true
end

function PlayerService.CleanupPlayer(userId: number)
	local entry = store[userId]
	if entry then
		-- Phase 2.6: stamp the leave time BEFORE releasing the
		-- profile, so the next session's offline window starts
		-- from this leave. (The janitor's own PlayerRemoving
		-- connection can also release without this stamp — that
		-- path keeps the heartbeat-refreshed value, which is at
		-- most OfflineHeartbeatSeconds stale: credit may be
		-- slightly short, never duplicated.)
		entry.data.LastSeen = os.time()
		entry.janitor:Cleanup()
	end
end

-- Phase 2.6: return and CLEAR the offline timestamp captured at
-- load. Exactly-once semantics: the value handed back here can
-- never be handed back again this session, so an offline window
-- can never be paid twice even if the caller retries. A return of
-- 0 means "no usable anchor" (fresh profile, DebugSkipPersistence
-- session, malformed stamp, or already consumed) — callers must
-- treat it as a zero-duration offline window.
function PlayerService.ConsumeOfflineTimestamp(userId: number): number
	local entry = store[userId]
	if not entry then
		return 0
	end
	local captured = entry.lastSeenAtLoad or 0
	entry.lastSeenAtLoad = nil
	return captured
end

-- --- Reads --------------------------------------------------------

function PlayerService.GetPlayerData(userId: number): any?
	local entry = store[userId]
	return entry and entry.data or nil
end

-- --- Tutorial progress (owned by TutorialService) ----------------------

-- Read the persisted tutorial record (never nil for a loaded
-- player; shape-repaired on the spot for older saves).
function PlayerService.GetTutorial(userId: number): any
	Validation.PositiveInteger(userId)
	local entry = store[userId]
	if not entry then
		return { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil }
	end
	local data = entry.data
	if type(data.Tutorial) ~= 'table' then
		data.Tutorial = { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil }
	end
	return data.Tutorial
end

-- Merge tutorial fields (Completed/Step/EggId/AnimalId).
-- Scalars only; unknown keys ignored. Never throws.
function PlayerService.SetTutorial(userId: number, patch: any): boolean
	local updated = false
	pcall(function()
		Validation.PositiveInteger(userId)
		if type(patch) ~= 'table' then
			return
		end
		local entry = store[userId]
		if not entry then
			return
		end
		local record = PlayerService.GetTutorial(userId)
		if type(patch.Completed) == 'boolean' then
			record.Completed = patch.Completed
		end
		if type(patch.Step) == 'string' and patch.Step ~= '' then
			record.Step = patch.Step
		end
		if patch.EggId == nil or type(patch.EggId) == 'string' then
			record.EggId = patch.EggId
		end
		if patch.AnimalId == nil or type(patch.AnimalId) == 'string' then
			record.AnimalId = patch.AnimalId
		end
		updated = true
	end)
	if updated then
		Debug.Log('PS', '> SetTutorial', { userId = tostring(userId) })
	end
	return updated
end

-- --- Base ownership reference ------------------------------------

-- --- Persistence API (animals + lucky eggs) -----------------
--
-- These are read/written directly off profile.Data. The lucky
-- egg + animal services call Add*/Remove*/Consume* on
-- lifecycle events (open, place, force-release) and read the
-- lists on rejoin. The record `Id` is the persistence key;
-- every record also carries its explicit `Type` stamp so no
-- reader ever has to infer kind from field shapes (Phase 2.5.1
-- §4).

-- Helper: locate an entry in a list by SlotId. Returns the
-- index, or nil.
local function _findIndexById(list: { any }, id: string): number?
	for i = 1, #list do
		local entry = list[i]
		if entry and entry.Id == id then
			return i
		end
	end
	return nil
end

local function _findIndexBySlot(list: { any }, slotId: string): number?
	for i = 1, #list do
		local entry = list[i]
		if entry and entry.SlotId == slotId then
			return i
		end
	end
	return nil
end

-- Build the set of Ids currently in a persisted list, for
-- collision-checked minting (GenerateUnique takes a set keyed by
-- Id, not the array itself).
local function _idSet(list: { any }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, record in ipairs(list) do
		if type(record) == 'table' and type(record.Id) == 'string' then
			set[record.Id] = true
		end
	end
	return set
end

-- Phase 2.6: pool settlement injection. PlayerService cannot
-- require EconomyService (the Phase 2.1 boundary: this service
-- never mutates Money) or IncomeService (which reads through this
-- service — a require would be a cycle). Bootstrap injects the
-- settlement function here; every Animal-record removal below
-- calls it BEFORE the record leaves the list, so a removed
-- Animal never silently deletes its accumulated-but-uncollected
-- cash (spec §45). The handler receives (userId, record) and is
-- expected to transfer record.CashPool to the owner's Money.
-- WipeUser deliberately does NOT settle: it is the admin
-- fresh-start nuke, not a gameplay removal.
local _poolSettlementHandler: ((number, any) -> ())? = nil

function PlayerService.SetAnimalPoolSettlementHandler(fn: ((number, any) -> ())?)
	_poolSettlementHandler = fn
end

local function _settlePoolBeforeRemove(userId: number, record: any)
	if not _poolSettlementHandler then
		return
	end
	local ok, err = pcall(_poolSettlementHandler, userId, record)
	if not ok then
		Debug.Warn('PS', 'Pool settlement handler errored during Animal removal', {
			userId = tostring(userId),
			animalId = tostring(record and record.Id),
			error = tostring(err),
		})
	end
end

function PlayerService.GetAnimals(userId: number): { any }
	local entry = store[userId]
	if not entry then
		return {}
	end
	-- Shallow copy so callers can iterate without mutating
	-- the live list.
	return table.clone(entry.data.Brainrots)
end

function PlayerService.GetEggs(userId: number): { any }
	local entry = store[userId]
	if not entry then
		return {}
	end
	return table.clone(entry.data.LuckyBlocks)
end

-- Lifetime generation counters: the single increment point.
-- Only the four canonical keys are accepted; unknown keys are
-- rejected (never create ad-hoc counters). Safe on missing
-- profiles/records (returns false, never throws past the
-- userId validation). Callers invoke this AFTER their commit
-- is durable, exactly once per success.
local STAT_KEYS = { EggsPurchased = true, EggsHatched = true, AnimalsObtained = true, UpgradesApplied = true }

function PlayerService.BumpStat(userId: number, key: string): boolean
	Validation.PositiveInteger(userId)
	if not STAT_KEYS[key] then
		return false
	end
	local entry = store[userId]
	if not entry then
		return false
	end
	if type(entry.data.Stats) ~= 'table' then
		entry.data.Stats = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 }
	end
	local stats: any = entry.data.Stats
	local cur = stats[key]
	if type(cur) ~= 'number' or cur ~= cur or cur < 0 then
		cur = 0
	end
	stats[key] = math.floor(cur) + 1
	return true
end

function PlayerService.AddAnimal(
	userId: number,
	slotId: string,
	defId: string,
	id: string?,
	opts: {
		Level: number?,
		XP: number?,
		CashPool: string?,
		Trait: string?,
		Mutations: { string }?,
	}?
): boolean
	Debug.Log('PS', '> AddAnimal', { userId = tostring(userId), slotId = slotId, defId = defId, id = tostring(id) })
	Validation.PositiveInteger(userId)
	Validation.SlotId(slotId)
	Validation.ShortString(defId)
	local entry = store[userId]
	if not entry then
		return false
	end
	-- Phase 2.2: the Id is the persistence key. The runtime
	-- service mints it (via OwnedObjectIdentity) and passes it
	-- in; this function just persists it. If a caller forgets,
	-- mint one here rather than persisting a record with no
	-- identity — a record without an Id is unrecoverable on
	-- rejoin (spec §10).
	if not id or not OwnedObjectIdentity.IsValid(id, OwnedObjectIdentity.Kind.Animal) then
		id = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, _idSet(entry.data.Brainrots))
	end
	if _findIndexById(entry.data.Brainrots, id) then
		-- Already there: idempotent.
		return true
	end
	-- Phase 2.4/2.5.1: canonical schema. Level/XP default to 1/0
	-- for a NEW animal, but opts preserves progression when a
	-- record is re-added (re-slot fallbacks) — a cross-slot move
	-- must never wipe it. Normalized through the one canonical
	-- path. `Type` is the explicit discriminator (Phase 2.5.1
	-- §4): the record always states its own kind.
	-- Phase 2.6: opts.CashPool preserves the accumulated pool on a
	-- re-add fallback (same rule as Level/XP — the pool travels
	-- with the Animal); it defaults to '0' and is sanitized
	-- through the one BigNumber path.
	local o = opts or {}
	local level, xp = LevelConfig.Normalize(o.Level or 1, o.XP or 0)
	-- Phase 2.11: Trait (singular string|nil) + Mutations (unique
	-- array) ride the record. Sanitized through the one canonical
	-- path (TraitService/MutationService); legacy rows without the
	-- fields audit to nil/{} at load.
	local trait: string? = nil
	if type(o.Trait) == 'string' and o.Trait ~= '' then
		trait = o.Trait
	end
	entry.data.Brainrots[#entry.data.Brainrots + 1] = {
		Type = 'Brainrot',
		SlotId = slotId,
		DefId = defId,
		Id = id,
		Level = level,
		XP = xp,
		CashPool = BigNumber.sanitize(o.CashPool or '0') or '0',
		Trait = trait,
		Mutations = MutationService.SanitizeList(o.Mutations),
	}
	-- New row appended (the idempotent early-return above did
	-- not fire): exactly one lifetime animal obtained.
	PlayerService.BumpStat(userId, 'AnimalsObtained')
	return true
end

function PlayerService.RemoveAnimal(userId: number, id: string?): boolean
	Debug.Log('PS', '> RemoveAnimal', { userId = tostring(userId), id = tostring(id) })
	Validation.PositiveInteger(userId)
	if not id then
		-- Legacy fallback: a caller that only has a SlotId.
		-- Pre-2.2 saves and any path that hasn't migrated yet
		-- still resolve by SlotId. New code passes the Id.
		return false
	end
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexById(entry.data.Brainrots, id)
	if not idx then
		return false
	end
	-- Phase 2.6: settle the pool BEFORE the record leaves the
	-- list — removal must never silently delete accumulated cash.
	local record = entry.data.Brainrots[idx]
	_settlePoolBeforeRemove(userId, record)
	table.remove(entry.data.Brainrots, idx)
	return true
end

function PlayerService.AddEgg(
	userId: number,
	slotId: string,
	rarity: string,
	id: string?,
	opts: { Mutations: { string }?, Trait: string? }?
): boolean
	Debug.Log('PS', '> AddEgg', { userId = tostring(userId), slotId = slotId, rarity = rarity, id = tostring(id) })
	Validation.PositiveInteger(userId)
	Validation.SlotId(slotId)
	Validation.ShortString(rarity)
	local entry = store[userId]
	if not entry then
		return false
	end
	if not id or not OwnedObjectIdentity.IsValid(id, OwnedObjectIdentity.Kind.Egg) then
		id = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Egg, _idSet(entry.data.LuckyBlocks))
	end
	if _findIndexById(entry.data.LuckyBlocks, id) then
		return true
	end
	-- Phase 2.11: Mutations (unique array) + Trait (HIDDEN
	-- preassigned opening payload, nil normally — never a visible
	-- Egg trait). Same canonical sanitize path.
	local lbOpts = opts or {}
	local pendingTrait: string? = nil
	if type(lbOpts.Trait) == 'string' and lbOpts.Trait ~= '' then
		pendingTrait = lbOpts.Trait
	end
	entry.data.LuckyBlocks[#entry.data.LuckyBlocks + 1] = {
		Type = 'LuckyBlock',
		SlotId = slotId,
		Rarity = rarity,
		Id = id,
		Mutations = MutationService.SanitizeList(lbOpts.Mutations),
		Trait = pendingTrait,
	}
	return true
end

function PlayerService.RemoveEgg(userId: number, id: string?): boolean
	Debug.Log('PS', '> RemoveEgg', { userId = tostring(userId), id = tostring(id) })
	Validation.PositiveInteger(userId)
	if not id then
		return false
	end
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexById(entry.data.LuckyBlocks, id)
	if not idx then
		return false
	end
	table.remove(entry.data.LuckyBlocks, idx)
	return true
end

-- Move a persisted record to a new slot. The Id is the key; the
-- SlotId is the only thing that changes (the record stays the
-- same owned object). Returns false if the Id isn't found.
function PlayerService.SetAnimalSlot(userId: number, id: string, newSlotId: string): boolean
	Debug.Log('PS', '> SetAnimalSlot', { userId = tostring(userId), id = id, slotId = newSlotId })
	Validation.PositiveInteger(userId)
	Validation.SlotId(newSlotId)
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexById(entry.data.Brainrots, id)
	if not idx then
		return false
	end
	entry.data.Brainrots[idx].SlotId = newSlotId
	return true
end

function PlayerService.SetEggSlot(userId: number, id: string, newSlotId: string): boolean
	Debug.Log('PS', '> SetEggSlot', { userId = tostring(userId), id = id, slotId = newSlotId })
	Validation.PositiveInteger(userId)
	Validation.SlotId(newSlotId)
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexById(entry.data.LuckyBlocks, id)
	if not idx then
		return false
	end
	entry.data.LuckyBlocks[idx].SlotId = newSlotId
	return true
end

-- Overwrite the persisted mutation list of one owned egg. Used
-- by the Event system when an unhatched base egg gains an
-- event mutation mid-life (the runtime record is stamped
-- first; this keeps the profile row identical so rejoin +
-- hatch inherit it). Sanitized through the canonical path;
-- unknown ids can never land in a save. Returns false when the
-- player or egg row is missing. Never throws.
function PlayerService.SetEggMutations(userId: number, id: string, mutations: any): boolean
	local updated = false
	pcall(function()
		Validation.PositiveInteger(userId)
		local entry = store[userId]
		if not entry then
			return
		end
		if type(id) ~= 'string' or id == '' then
			return
		end
		local idx = _findIndexById(entry.data.LuckyBlocks, id)
		if not idx then
			return
		end
		entry.data.LuckyBlocks[idx].Mutations = MutationService.SanitizeList(mutations)
		updated = true
	end)
	if updated then
		Debug.Log('PS', '> SetEggMutations', { userId = tostring(userId), id = id })
	end
	return updated
end

-- Phase 2.5.1 §10: the ONE atomic open-transition mutation. The
-- open flow's old sequence (RemoveEgg from HatchEgg +
-- AddAnimal from CreateFromEgg) left a window where a crash
-- — or, as it happened, a mis-keyed Remove call — left the
-- profile claiming both an Egg and an Animal for one
-- slot: the phantom record that "converted" the Animal back
-- into an Egg on rejoin. This function performs the whole
-- transition as one synchronous, yield-free mutation:
--   * the Egg record identified by eggId is
--     removed from profile.Data.LuckyBlocks,
--   * the Animal record is appended to profile.Data.Brainrots
--     under the SAME identity (animalId), the same slot, and
--     fresh Level 1 / XP 0 progression.
-- If the Egg record is already gone (double open, or an
-- earlier interrupted attempt), the Animal is STILL added and
-- the anomaly is logged loudly — the egg was already consumed,
-- so failing here would destroy a legitimately created Animal.
-- It never removes anything from the Animals list and never
-- converts a type in either direction.
function PlayerService.ConsumeEggIntoAnimal(
	userId: number,
	eggId: string?,
	slotId: string,
	defId: string,
	animalId: string,
	inherit: { Trait: string?, Mutations: { string }? }?
): boolean
	Debug.Log('PS', '> ConsumeEggIntoAnimal', {
		userId = tostring(userId),
		eggId = tostring(eggId),
		slotId = slotId,
		defId = defId,
		animalId = animalId,
	})
	Validation.PositiveInteger(userId)
	Validation.SlotId(slotId)
	Validation.ShortString(defId)
	local entry = store[userId]
	if not entry then
		return false
	end

	if eggId then
		local idx = _findIndexById(entry.data.LuckyBlocks, eggId)
		if idx then
			table.remove(entry.data.LuckyBlocks, idx)
		else
			Debug.Warn('PS', 'Consume: Egg record not found (already consumed?) — adding Animal anyway', {
				userId = tostring(userId),
				eggId = eggId,
				slotId = slotId,
			})
		end
	end

	if _findIndexById(entry.data.Brainrots, animalId) then
		-- Already converted (retry after an interrupted open).
		return true
	end
	if not OwnedObjectIdentity.IsValid(animalId, OwnedObjectIdentity.Kind.Animal) then
		animalId = OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, _idSet(entry.data.Brainrots))
	end
	-- Phase 2.11: inheritance lands here atomically with the
	-- consume (same synchronous mutation): the hidden egg Trait
	-- (or nil) + a defensive copy of the egg mutations. The
	-- caller (CreateFromEgg) resolved both; this function only
	-- persists them through the canonical sanitize path.
	local inh = inherit or {}
	local inheritedTrait: string? = nil
	if type(inh.Trait) == 'string' and inh.Trait ~= '' then
		inheritedTrait = inh.Trait
	end
	local inheritedMutations = MutationService.SanitizeList(inh.Mutations)
	local freshMutations: { string } = {}
	for _, id in ipairs(inheritedMutations) do
		freshMutations[#freshMutations + 1] = id
	end
	entry.data.Brainrots[#entry.data.Brainrots + 1] = {
		Type = 'Brainrot',
		SlotId = slotId,
		DefId = defId,
		Id = animalId,
		Level = 1,
		XP = 0,
		-- Phase 2.6: a newly opened Animal starts with an empty
		-- pool; income accumulates from the first eligible tick.
		CashPool = '0',
		Trait = inheritedTrait,
		Mutations = freshMutations,
	}
	-- New row appended (the already-converted early-return above
	-- did not fire): exactly one lifetime animal obtained.
	PlayerService.BumpStat(userId, 'AnimalsObtained')
	return true
end

-- By-slot removal fallbacks (Phase 2.5.1 §8). The Id-keyed
-- Remove* functions are the primary API; these exist for the one
-- legitimate by-slot case — a record whose Id the caller can no
-- longer trust (e.g. the spawn path dropping a record whose
-- identity was re-keyed at load). They remove AT MOST ONE
-- record, ONLY from their own kind's list: an Animal slot call
-- can never delete an Egg record and vice versa, so the
-- pre-2.5.1 failure mode (passing a slot id into an Id-keyed
-- remove and silently deleting nothing) is structurally
-- impossible here — it either removes the same-kind record it
-- names, or it fails loudly at the call site.
function PlayerService.RemoveAnimalAtSlot(userId: number, slotId: string): boolean
	Debug.Log('PS', '> RemoveAnimalAtSlot', { userId = tostring(userId), slotId = slotId })
	Validation.PositiveInteger(userId)
	Validation.SlotId(slotId)
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexBySlot(entry.data.Brainrots, slotId)
	if not idx then
		return false
	end
	-- Phase 2.6: settle the pool BEFORE the record leaves the
	-- list (same rule as RemoveAnimal).
	local record = entry.data.Brainrots[idx]
	_settlePoolBeforeRemove(userId, record)
	table.remove(entry.data.Brainrots, idx)
	return true
end

function PlayerService.RemoveEggAtSlot(userId: number, slotId: string): boolean
	Debug.Log('PS', '> RemoveEggAtSlot', { userId = tostring(userId), slotId = slotId })
	Validation.PositiveInteger(userId)
	Validation.SlotId(slotId)
	local entry = store[userId]
	if not entry then
		return false
	end
	local idx = _findIndexBySlot(entry.data.LuckyBlocks, slotId)
	if not idx then
		return false
	end
	table.remove(entry.data.LuckyBlocks, idx)
	return true
end

-- --- Wipe (admin / Studio command) -------------------------------

-- Reset every persisted field on the player's profile back to its
-- default. This is the "fresh start" path: Money goes back to
-- EconomyConfig.StartingMoney, BaseId is cleared, Animals and
-- Eggs are emptied, Multipliers is reset, Loaded is
-- flipped to false so a subsequent join re-runs the first-time
-- setup.
--
-- Requires the player to be currently loaded. To wipe a player
-- who is offline, you'd have to load the profile just to wipe
-- it (ProfileService exposes the store, but it's expensive and
-- not what this command is for). The intended use is Studio:
-- join with the test account, run WipePlayer(userId) from the
-- command bar, then rejoin to start from scratch.
--
-- This is logically equivalent to changing the ProfileService
-- store name (which is the existing dev-time escape hatch) but
-- works per-player and doesn't require a Studio restart. It is
-- the right tool when the dev wants to retry the playtest with
-- a clean slate for one user without resetting everyone.
function PlayerService.WipeUser(userId: number): boolean
	Debug.Log('PS', '> WipeUser', { userId = tostring(userId) })
	Validation.PositiveInteger(userId)
	local entry = store[userId]
	if not entry then
		Debug.Warn('PS', 'WipeUser: player not loaded', { userId = tostring(userId) })
		return false
	end
	-- Reset every persisted field. The schema keys come from
	-- the PROFILE_STORE template at the top of this file; if
	-- a new field is added there, mirror it here.
	entry.data.Money = BigNumber.sanitize(EconomyConfig.StartingMoney) or '0'
	entry.data.BaseId = nil
	entry.data.Rebirth = 0
	entry.data.Tutorial = { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil }
	entry.data.Brainrots = {}
	entry.data.LuckyBlocks = {}
	entry.data.GearAutoBuy = {}
	entry.data.OwnedRobuxGear = {}
	entry.data.Arena = { Level = 1, XP = 0, Wins = 0, HighestCompleted = 0, PendingEggs = {} }
	entry.data.RedeemedCodes = {}
	entry.data.PendingCodeRewards = {}
	entry.data.DailyRewards = { WeekId = '', Day = 1, LastClaimAt = 0 }
	entry.data.PlaytimeRewards = { DayId = '', PoolId = '', Claimed = {}, Completed = false }
	entry.data.Multipliers = { Money = 1 }
	entry.data.Stats = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 }
	entry.data.Loaded = false
	-- Phase 2.6: clear the offline anchor so the next session has
	-- no capturable window (a wiped player earns nothing offline),
	-- and drop any unconsumed captured stamp from this session.
	-- Deliberately does NOT settle the removed Animals' pools:
	-- WipeUser is the admin fresh-start nuke, not a gameplay
	-- removal (see SetAnimalPoolSettlementHandler).
	entry.data.LastSeen = 0
	entry.lastSeenAtLoad = nil
	-- The in-memory baseId mirrors BaseId; clear it so a
	-- subsequent GetBaseId() returns nil until a new base is
	-- assigned.
	entry.baseId = nil
	Debug.Log('PS', '< WipeUser done', {
		userId = tostring(userId),
		money = tostring(entry.data.Money),
	})
	return true
end

-- --- Base ownership reference ------------------------------------

function PlayerService.AssignBase(userId: number, baseId: string): boolean
	Validation.ShortString(baseId)
	local entry = store[userId]
	if not entry then
		return false
	end
	entry.baseId = baseId
	entry.data.BaseId = baseId
	return true
end

function PlayerService.GetBaseId(userId: number): string?
	local entry = store[userId]
	if not entry then
		return nil
	end
	return entry.baseId
end

function PlayerService.ReleaseBase(userId: number)
	local entry = store[userId]
	if entry then
		entry.baseId = nil
		entry.data.BaseId = nil
	end
end

-- Returns the loadedSignal for a player; fires when both data is
-- loaded AND the base is assigned. Bootstrap uses this to gate
-- state pushes and to push the initial PlayerState.
function PlayerService.GetLoadedSignal(userId: number): any
	local entry = store[userId]
	if not entry then
		error('No player entry for userId ' .. tostring(userId))
	end
	if not entry.loadedSignal then
		local Signals = require(script.Parent.Parent.ReplicatedStorage.Utility.Signals)
		entry.loadedSignal = Signals.new()
	end
	return entry.loadedSignal
end

function PlayerService.IsLoaded(userId: number): boolean
	local entry = store[userId]
	return entry ~= nil and entry.data.Loaded == true
end

-- Mark a player's `loadedSignal` as fired. Called by bootstrap after
-- both LoadPlayerData AND base-assignment have succeeded.
function PlayerService.MarkLoaded(userId: number)
	local entry = store[userId]
	if not entry then
		return
	end
	if entry.loadedSignal then
		entry.loadedSignal:Fire()
	end
end

-- Push the current PlayerState to the given player. Called by
-- bootstrap when the data is ready and again whenever state changes.
function PlayerService.PushState(player: Player, baseSnapshot: any)
	Debug.Log('PS', '> PushState', { name = player.Name, hasSnapshot = tostring(baseSnapshot ~= nil) })
	Validation.LivePlayer(player)
	local data = PlayerService.GetPlayerData(player.UserId)
	if not data then
		return
	end
	-- Phase 2.1: the wire format's Cash field is replaced by
	-- `Money` (string). The HUD reads `payload.Money` and
	-- formats it with BigNumber.Format. The CarriedKind /
	-- CarriedName fields surface the "what is this player
	-- currently carrying" state for the HUD's top-line
	-- display; CarriedSteal flags a steal in progress so the
	-- thief's client suppresses conflicting prompts.
	local carry = CarryRegistry.Snapshot(player.UserId)
	Remotes.FireClient(player, Remotes.Names.PlayerState, {
		Money = data.Money,
		BaseId = data.BaseId,
		Slots = baseSnapshot and baseSnapshot.slots or {},
		CarriedKind = carry.Kind,
		CarriedName = carry.Name,
		CarriedSteal = carry.Steal == true,
	})
end

-- Notify convenience. Public so other services can use it.
function PlayerService.Notify(player: Player, category: string, text: string)
	Debug.Log('PS', '> Notify', { name = player.Name, category = category, text = text })
	Validation.LivePlayer(player)
	Validation.t.string(category)
	Validation.t.string(text)
	Remotes.FireClient(player, Remotes.Names.Notify, {
		Category = category,
		Text = text,
	})
end

return table.freeze(PlayerService)
