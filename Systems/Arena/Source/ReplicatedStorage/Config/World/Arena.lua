--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	This module is the single source of truth for its domain; the legacy
	flat config under ReplicatedStorage.Config is a deprecated shim.
	New code must require this canonical path.
	Values below are preserved exactly from the pre-migration configs.
	Do NOT rebalance here without a gameplay review.
]]
--[[
	Arena
	===========
	Data-driven Arena expedition catalog. Each level is display
	data + combat roster + reward rules; services never hardcode
	per-level behavior (no `if level == N` anywhere — rebalance
	or remove levels here only).

	Conventions:
	  * Level: 1-based stable integer, display order = array order.
  * Boss: every 10th level (IsBossLevel), with its own
    dialogue + boosted rewards. The per-entry `Boss` flag is
    authoritative per level; IsBossLevel is the derived
    helper — the two must agree (enforced by ValidateList).
	  * EnemyTeam: array of enemy combatant defs. Every
	    DefinitionId MUST exist in Animals (validated at
	    boot + in tests). Level >= 1. StatMultiplier defaults
	    to 1 when absent; > 0 required.
  * Rewards.ArenaXP: player Arena progression (number).
  * Rewards.FirstClearCash / RepeatCash: BigNumber decimal
    STRINGS (never numbers). A cleared stage CONTRIBUTES
    these to the raid's temporary accumulator — stages never
    pay out directly. The raid settles ONCE at its terminal
    state (progressive: victory pays the full accumulator,
    defeat pays every cleared stage and forfeits only the
    failed one; an empty accumulator settles $0). First clear
    = the stage is exactly the raid's next expected new stage
    at clear time; anything else is a repeat.
  * Raid model: every raid starts at stage 1 and the server
    advances the same session stage by stage to MaxLevel.
    There is no stage selection and no unlock gate —
    HighestCompleted is the historical best stage (plus
    first/repeat selection). Arena XP NEVER gates stages —
    XP is a separate reward value. This config only
    declares the stage catalog.
]]

export type ArenaEnemyDef = {
	DefinitionId: string,
	Level: number,
	StatMultiplier: number?,
	IsBoss: boolean?,
	DisplayName: string?,
	PositionIndex: number?,
	TargetPriority: number?,
}

export type ArenaRewards = {
	ArenaXP: number,
	FirstClearCash: string,
	RepeatCash: string,
}

export type ArenaLevelDef = {
	Level: number,
	Name: string,
	Description: string,
	Boss: boolean,
	EnemyTeam: { ArenaEnemyDef },
	Rewards: ArenaRewards,
}

local MAX_LEVEL = 10

-- NOTE: MAX_LEVEL is re-derived from the catalog length below
-- (after LEVELS), so extending the catalog never leaves a stale
-- hardcoded cap behind.

-- Minimum occupied ARENA slots required to start an
-- expedition. Config — not hardcoded in the service — so
-- later balancing touches one value.
local MIN_TEAM_SIZE = 1

-- Maximum player combatants per battle. Hard cap, not a
-- tuning knob: arenas author exactly 3 PlayerSpawns
-- markers, so a 4th combatant would have nowhere to stand.
-- StartArena trims to the first N by ArenaIndex (loud warn);
-- it never silently reorders.
local MAX_TEAM_SIZE = 3

-- Per-animal XP multiplier: each participating animal's raid XP
-- grant equals (settled raid XP total) x this multiplier, applied
-- through the canonical AnimalService:AddXP pipeline (which owns
-- multi-level draining, MaxLevel clamp, persistence, and the
-- documented per-animal XPModifier). The raid XP accumulator
-- itself is unchanged (player Arena XP uses raw totals), so this
-- multiplier applies EXACTLY ONCE at the arena layer — never
-- double-applied. Event tuning knob: change here, nowhere else.
local ANIMAL_XP_MULTIPLIER = 100

-- Base attack cooldown between combatant attacks, in seconds.
-- The centralized scheduler reads this; individual combats
-- never run their own loops.
local ATTACK_COOLDOWN = 1.5

-- Restart entry points (authored Main.Arena Buy1/Buy2/Buy3).
-- Buy3 is the free normal entry at stage 1. Buy1/Buy2 are paid
-- restarts from the SAVED previous best (LastLevel = highest
-- level reached BEFORE the current run — never the run's
-- temporary level): Buy2 (direct) starts exactly at LastLevel,
-- Buy1 (warmup, cheaper) starts at half of LastLevel so the
-- player warms back up. All three funnel into the ONE
-- authoritative StartArena path — the server re-resolves
-- levels and prices per request, never trusting the client.
-- Single place to rebalance restart pricing.
-- Prices are BigNumber decimal STRINGS (charged atomically via
-- EconomyService.TrySpendMoney).
local RESTART_WARMUP_PRICE = '25000'
local RESTART_DIRECT_PRICE = '150000'

-- Difficulty model (Step 1, mechanical completion): the
-- arena supports at most 3 combatants per side (authored
-- spawn markers), so the curve comes from enemy RARITY +
-- LEVEL + StatMultiplier — never from raw headcount. A
-- Common L1 is ~5 HP; a Divine L25 boss with x2.5 is
-- ~9,000 HP. Enemy count stays within 2-3 per level.
local LEVELS: { ArenaLevelDef } = {

	-- =========================================================
	-- LEVELS 1-10
	-- MAX ENEMY COUNT: 1
	-- COMMON -> RARE -> EPIC
	-- BOSS: LEVEL 10
	--
	-- FIRST-CLEAR TOTAL: ~300,000
	-- =========================================================

	{
		Level = 1,
		Name = 'Meadow Skirmish',
		Description = 'A gentle first expedition through the meadow edge. A young common tests your team.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Frog', Level = 1 },
		},
		Rewards = {
			ArenaXP = 2,
			FirstClearCash = '15000',
			RepeatCash = '500',
		},
	},

	{
		Level = 2,
		Name = 'Pond Crossing',
		Description = 'A small predator has claimed the pond crossing.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dog', Level = 1 },
		},
		Rewards = {
			ArenaXP = 3,
			FirstClearCash = '5000',
			RepeatCash = '600',
		},
	},

	{
		Level = 3,
		Name = 'Meadow Hunter',
		Description = 'A stronger common predator patrols the edge of the meadow.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Penguin', Level = 2 },
		},
		Rewards = {
			ArenaXP = 3,
			FirstClearCash = '5000',
			RepeatCash = '700',
		},
	},

	{
		Level = 4,
		Name = 'Raccoon Raiders',
		Description = 'A rare scavenger has wandered into the arena.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Raccoon', Level = 2 },
		},
		Rewards = {
			ArenaXP = 4,
			FirstClearCash = '5000',
			RepeatCash = '800',
		},
	},

	{
		Level = 5,
		Name = 'Thicket Hunter',
		Description = 'A cunning rare predator waits in the thicket.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Fox', Level = 1 },
		},
		Rewards = {
			ArenaXP = 5,
			FirstClearCash = '10000',
			RepeatCash = '900',
		},
	},

	{
		Level = 6,
		Name = 'Burrow Watch',
		Description = 'A hardened rare creature guards the old burrow.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'BurrowingOwl', Level = 4 },
		},
		Rewards = {
			ArenaXP = 6,
			FirstClearCash = '15000',
			RepeatCash = '1000',
		},
	},

	{
		Level = 7,
		Name = 'Webbed Hollow',
		Description = 'Something much stronger has made its home beneath the trees.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Spider', Level = 4 },
		},
		Rewards = {
			ArenaXP = 8,
			FirstClearCash = '10000',
			RepeatCash = '1100',
		},
	},

	{
		Level = 8,
		Name = 'Deep Thicket',
		Description = 'An elite spider has taken control of the deepest part of the thicket.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Spider', Level = 5 },
		},
		Rewards = {
			ArenaXP = 10,
			FirstClearCash = '15000',
			RepeatCash = '1200',
		},
	},

	{
		Level = 9,
		Name = 'Ancient Burrow',
		Description = 'The final guardian before the first arena boss is stronger than anything before it.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Turtle', Level = 9 },
		},
		Rewards = {
			ArenaXP = 12,
			FirstClearCash = '25000',
			RepeatCash = '1300',
		},
	},

	{
		Level = 10,
		Name = 'Alpha Spider',
		Description = 'BOSS — an empowered alpha spider guards the first arena gate.',
		Boss = true,
		EnemyTeam = {
			{
				DefinitionId = 'Spider',
				Level = 10,
				StatMultiplier = 1.5,
				IsBoss = true,
			},
		},
		Rewards = {
			ArenaXP = 15,
			FirstClearCash = '3000',
			RepeatCash = '2000',
		},
	},

	-- =========================================================
	-- LEVELS 11-20
	-- MAX ENEMY COUNT: 2
	-- EPIC -> MYTHIC
	-- BOSS: LEVEL 20
	-- =========================================================

	{
		Level = 11,
		Name = 'Sunken Burrows',
		Description = 'Two seasoned creatures defend the deeper burrows.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Spider', Level = 7 },
			{ DefinitionId = 'Raccoon', Level = 5 },
		},
		Rewards = {
			ArenaXP = 19,
			FirstClearCash = '3000',
			RepeatCash = '600',
		},
	},

	{
		Level = 12,
		Name = 'Frozen Hollow',
		Description = 'The temperature drops as stronger creatures emerge from the caves.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Walrus', Level = 6 },
			{ DefinitionId = 'Turtle', Level = 3 },
		},
		Rewards = {
			ArenaXP = 23,
			FirstClearCash = '3500',
			RepeatCash = '650',
		},
	},

	{
		Level = 13,
		Name = 'Crystal Thicket',
		Description = 'The forest floor is covered in strange crystals and tougher predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Axolotl', Level = 5 },
			{ DefinitionId = 'Spider', Level = 7 },
		},
		Rewards = {
			ArenaXP = 29,
			FirstClearCash = '4000',
			RepeatCash = '700',
		},
	},

	{
		Level = 14,
		Name = 'Ironwood Clash',
		Description = 'Two elite creatures battle for control of the ancient trees.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Jerboa', Level = 5 },
			{ DefinitionId = 'Walrus', Level = 8 },
		},
		Rewards = {
			ArenaXP = 36,
			FirstClearCash = '4500',
			RepeatCash = '750',
		},
	},

	{
		Level = 15,
		Name = 'Mighty Burrow',
		Description = 'The creatures here have survived countless battles.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Jerboa', Level = 1 },
			{ DefinitionId = 'Turtle', Level = 3 },
		},
		Rewards = {
			ArenaXP = 45,
			FirstClearCash = '5000',
			RepeatCash = '800',
		},
	},

	{
		Level = 16,
		Name = 'Ancient Crossing',
		Description = 'The old crossing is guarded by two powerful mythic creatures.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'SandSpider', Level = 5 },
			{ DefinitionId = 'Bear', Level = 6 },
		},
		Rewards = {
			ArenaXP = 57,
			FirstClearCash = '5500',
			RepeatCash = '850',
		},
	},

	{
		Level = 17,
		Name = 'Roaring Basin',
		Description = 'The roar of mythic predators echoes across the basin.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Bear', Level = 4 },
			{ DefinitionId = 'Tiger', Level = 6 },
		},
		Rewards = {
			ArenaXP = 71,
			FirstClearCash = '6000',
			RepeatCash = '900',
		},
	},

	{
		Level = 18,
		Name = 'Stonefang Pass',
		Description = 'A narrow pass controlled by two mythic predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Tiger', Level = 4 },
			{ DefinitionId = 'Gorilla', Level = 1 },
		},
		Rewards = {
			ArenaXP = 89,
			FirstClearCash = '6500',
			RepeatCash = '950',
		},
	},

	{
		Level = 19,
		Name = 'Bloodmoon Valley',
		Description = 'Under the bloodmoon, the strongest mythic predators become even more aggressive.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Gorilla', Level = 7 },
			{ DefinitionId = 'Tiger', Level = 8 },
		},
		Rewards = {
			ArenaXP = 111,
			FirstClearCash = '7000',
			RepeatCash = '1000',
		},
	},

	{
		Level = 20,
		Name = 'Mythic Warlord',
		Description = 'BOSS — a mythic champion commands the arena gate.',
		Boss = true,
		EnemyTeam = {
			{
				DefinitionId = 'Gorilla',
				Level = 15,
				StatMultiplier = 1.7,
				IsBoss = true,
			},
			{
				DefinitionId = 'Tiger',
				Level = 10,
			},
		},
		Rewards = {
			ArenaXP = 139,
			FirstClearCash = '10000',
			RepeatCash = '1500',
		},
	},

	-- =========================================================
	-- LEVELS 21-30
	-- MAX ENEMY COUNT: 3
	-- MYTHIC -> LEGENDARY
	-- BOSS: LEVEL 30
	-- =========================================================

	{
		Level = 21,
		Name = 'Thunder Ridge',
		Description = 'Three mythic creatures dominate the mountain ridge.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Gorilla', Level = 4 },
			{ DefinitionId = 'Tiger', Level = 6 },
			{ DefinitionId = 'Bear', Level = 7 },
		},
		Rewards = {
			ArenaXP = 173,
			FirstClearCash = '7500',
			RepeatCash = '1100',
		},
	},

	{
		Level = 22,
		Name = 'Titan Grove',
		Description = 'Massive predators have claimed the ancient grove.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Gorilla', Level = 3 },
			{ DefinitionId = 'Bear', Level = 4 },
			{ DefinitionId = 'Tiger', Level = 5 },
		},
		Rewards = {
			ArenaXP = 217,
			FirstClearCash = '8000',
			RepeatCash = '1150',
		},
	},

	{
		Level = 23,
		Name = 'Feral Summit',
		Description = 'Only the strongest mythic predators survive at the summit.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Tiger', Level = 6 },
			{ DefinitionId = 'Gorilla', Level = 4 },
			{ DefinitionId = 'SandSpider', Level = 6 },
		},
		Rewards = {
			ArenaXP = 271,
			FirstClearCash = '8500',
			RepeatCash = '1200',
		},
	},

	{
		Level = 24,
		Name = 'Warbeast Crater',
		Description = 'A crater filled with battle scars and relentless predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Gorilla', Level = 6 },
			{ DefinitionId = 'Tiger', Level = 7 },
			{ DefinitionId = 'Bear', Level = 6 },
		},
		Rewards = {
			ArenaXP = 339,
			FirstClearCash = '9000',
			RepeatCash = '1250',
		},
	},

	{
		Level = 25,
		Name = 'Fossil Valley',
		Description = 'Ancient bones cover the valley. Something legendary has begun to stir.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Triceratops', Level = 8 },
			{ DefinitionId = 'Gorilla', Level = 9 },
			{ DefinitionId = 'Tiger', Level = 9 },
		},
		Rewards = {
			ArenaXP = 424,
			FirstClearCash = '9500',
			RepeatCash = '1300',
		},
	},

	{
		Level = 26,
		Name = 'Razor Marsh',
		Description = 'The marsh is controlled by powerful legendary predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Crocodile', Level = 5 },
			{ DefinitionId = 'Scorpion', Level = 7 },
			{ DefinitionId = 'Triceratops', Level = 10 },
		},
		Rewards = {
			ArenaXP = 529,
			FirstClearCash = '10000',
			RepeatCash = '1350',
		},
	},

	{
		Level = 27,
		Name = 'Titan Bones',
		Description = 'The remains of ancient giants form a maze of legendary beasts.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Triceratops', Level = 11 },
			{ DefinitionId = 'Scorpion', Level = 11 },
			{ DefinitionId = 'Crocodile', Level = 11 },
		},
		Rewards = {
			ArenaXP = 662,
			FirstClearCash = '10500',
			RepeatCash = '1400',
		},
	},

	{
		Level = 28,
		Name = 'Deathwind Canyon',
		Description = 'Legendary hunters patrol the canyon in search of prey.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'SabertoothTiger', Level = 12 },
			{ DefinitionId = 'Crane', Level = 14 },
			{ DefinitionId = 'Scorpion', Level = 16 },
		},
		Rewards = {
			ArenaXP = 827,
			FirstClearCash = '11000',
			RepeatCash = '1450',
		},
	},

	{
		Level = 29,
		Name = 'Ancient Hunt',
		Description = 'The final legendary hunters stand between your team and the next boss.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
			{ DefinitionId = 'Crane', Level = 11 },
			{ DefinitionId = 'Crocodile', Level = 5 },
		},
		Rewards = {
			ArenaXP = 1034,
			FirstClearCash = '11500',
			RepeatCash = '1500',
		},
	},

	{
		Level = 30,
		Name = 'Primal Tyrant',
		Description = 'BOSS — an ancient legendary predator awakens beneath the canyon.',
		Boss = true,
		EnemyTeam = {
			{
				DefinitionId = 'SabertoothTiger',
				Level = 30,
				StatMultiplier = 1.85,
				IsBoss = true,
			},
			{
				DefinitionId = 'Crocodile',
				Level = 15,
			},
			{
				DefinitionId = 'Scorpion',
				Level = 15,
			},
		},
		Rewards = {
			ArenaXP = 1292,
			FirstClearCash = '12500',
			RepeatCash = '1800',
		},
	},

	-- =========================================================
	-- LEVELS 31-40
	-- MAX ENEMY COUNT: 4
	-- LEGENDARY -> DIVINE
	-- BOSS: LEVEL 40
	-- =========================================================

	{
		Level = 31,
		Name = 'Crimson Basin',
		Description = 'Four legendary creatures dominate the basin.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Crane', Level = 25 },
			{ DefinitionId = 'SabertoothTiger', Level = 19 },
			{ DefinitionId = 'Triceratops', Level = 20 },
		},
		Rewards = {
			ArenaXP = 1616,
			FirstClearCash = '13000',
			RepeatCash = '1850',
		},
	},

	{
		Level = 32,
		Name = 'Legendary Hunt',
		Description = 'Four legendary hunters track your team through ancient ruins.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'SabertoothTiger', Level = 20 },
			{ DefinitionId = 'Crane', Level = 20 },
			{ DefinitionId = 'Scorpion', Level = 5 },
			{ DefinitionId = 'Crocodile', Level = 6 },
		},
		Rewards = {
			ArenaXP = 2019,
			FirstClearCash = '14000',
			RepeatCash = '1900',
		},
	},

	{
		Level = 33,
		Name = 'Scorpion Sands',
		Description = 'The sands are alive with legendary predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Scorpion', Level = 33 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
			{ DefinitionId = 'Triceratops', Level = 15 },
		},
		Rewards = {
			ArenaXP = 2524,
			FirstClearCash = '15000',
			RepeatCash = '1950',
		},
	},

	{
		Level = 34,
		Name = 'Worldbreaker Plain',
		Description = 'Only the largest legendary beasts survive on this barren plain.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Triceratops', Level = 15 },
			{ DefinitionId = 'Crocodile', Level = 30 },
			{ DefinitionId = 'Crane', Level = 35 },
		},
		Rewards = {
			ArenaXP = 3155,
			FirstClearCash = '16000',
			RepeatCash = '2000',
		},
	},

	{
		Level = 35,
		Name = 'Ancient Titans',
		Description = 'Four legendary titans prepare for the final challenge before the divine realm.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Triceratops', Level = 15 },
			{ DefinitionId = 'SabertoothTiger', Level = 10 },
			{ DefinitionId = 'Scorpion', Level = 15 },
			{ DefinitionId = 'Crocodile', Level = 10 },
		},
		Rewards = {
			ArenaXP = 3944,
			FirstClearCash = '17000',
			RepeatCash = '2050',
		},
	},

	{
		Level = 36,
		Name = 'Celestial Gate',
		Description = 'The legendary realm ends at a gate guarded by divine creatures.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'TyrannosaurusRex', Level = 36 },
			{ DefinitionId = 'Crocodile', Level = 20 },
			{ DefinitionId = 'Crane', Level = 20 },
		},
		Rewards = {
			ArenaXP = 4930,
			FirstClearCash = '18000',
			RepeatCash = '2100',
		},
	},

	{
		Level = 37,
		Name = 'Dragonfall',
		Description = 'Something enormous has fallen from the sky. Divine guardians remain.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 37 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 6163,
			FirstClearCash = '19000',
			RepeatCash = '2150',
		},
	},

	{
		Level = 38,
		Name = 'Frozen Dominion',
		Description = 'A divine Yeti rules the frozen frontier alongside ancient predators.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 30 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 30 },
			{ DefinitionId = 'Crane', Level = 5 },
		},
		Rewards = {
			ArenaXP = 7704,
			FirstClearCash = '19500',
			RepeatCash = '2200',
		},
	},

	{
		Level = 39,
		Name = 'Dragonspire',
		Description = 'The highest peak belongs to creatures that should never have existed.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 39 },
			{ DefinitionId = 'Yeti', Level = 10 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 5 },
		},
		Rewards = {
			ArenaXP = 9630,
			FirstClearCash = '20000',
			RepeatCash = '2250',
		},
	},

	{
		Level = 40,
		Name = 'Divine Gatekeeper',
		Description = 'BOSS — a divine guardian stands between your team and the final trials.',
		Boss = true,
		EnemyTeam = {
			{
				DefinitionId = 'TyrannosaurusRex',
				Level = 40,
				StatMultiplier = 2.0,
				IsBoss = true,
			},
			{
				DefinitionId = 'Yeti',
				Level = 20,
			},
		},
		Rewards = {
			ArenaXP = 12037,
			FirstClearCash = '21000',
			RepeatCash = '2500',
		},
	},

	-- =========================================================
	-- LEVELS 41-50
	-- MAX ENEMY COUNT: 5
	-- DIVINE ENDGAME
	-- BOSS: LEVEL 50
	-- =========================================================

	{
		Level = 41,
		Name = 'Heavenfall',
		Description = 'The final realm opens. Five powerful creatures guard the path.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 41 },
			{ DefinitionId = 'Yeti', Level = 20 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
		},
		Rewards = {
			ArenaXP = 15046,
			FirstClearCash = '21500',
			RepeatCash = '2550',
		},
	},

	{
		Level = 42,
		Name = 'Eternal Roar',
		Description = 'A roar echoes across the divine realm. Five apex creatures answer.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 20 },
			{ DefinitionId = 'Dragon', Level = 20 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
			{ DefinitionId = 'Crane', Level = 5 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 18808,
			FirstClearCash = '22000',
			RepeatCash = '2600',
		},
	},

	{
		Level = 43,
		Name = 'Godbeast Sanctuary',
		Description = 'The final sanctuary contains creatures with strength beyond the natural world.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 10 },
			{ DefinitionId = 'Yeti', Level = 20 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'Crocodile', Level = 10 },
		},
		Rewards = {
			ArenaXP = 23510,
			FirstClearCash = '22500',
			RepeatCash = '2650',
		},
	},

	{
		Level = 44,
		Name = 'Endless Throne',
		Description = 'The throne has stood untouched for ages. Its divine guardians are waiting.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 15 },
			{ DefinitionId = 'Dragon', Level = 11 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 29387,
			FirstClearCash = '23000',
			RepeatCash = '2700',
		},
	},

	{
		Level = 45,
		Name = 'Divine Dominion',
		Description = 'Five apex creatures stand between your team and the final trials.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 5 },
			{ DefinitionId = 'Yeti', Level = 15 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 20 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 36734,
			FirstClearCash = '24000',
			RepeatCash = '2750',
		},
	},

	{
		Level = 46,
		Name = 'End of the World',
		Description = 'The final stretch begins. Only divine apex predators remain.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 25 },
			{ DefinitionId = 'Yeti', Level = 20 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 10 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'Crocodile', Level = 10 },
		},
		Rewards = {
			ArenaXP = 45918,
			FirstClearCash = '25000',
			RepeatCash = '2800',
		},
	},

	{
		Level = 47,
		Name = 'Apex Dominion',
		Description = 'The strongest creatures from every realm have gathered for one final battle.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 30 },
			{ DefinitionId = 'Dragon', Level = 20 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 20 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 57397,
			FirstClearCash = '26000',
			RepeatCash = '2850',
		},
	},

	{
		Level = 48,
		Name = 'Celestial War',
		Description = 'Five divine titans collide. Your team stands in the middle.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Dragon', Level = 40 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 30 },
			{ DefinitionId = 'Yeti', Level = 28},
			{ DefinitionId = 'Crane', Level = 20 },
			{ DefinitionId = 'Crocodile', Level = 20 },
		},
		Rewards = {
			ArenaXP = 71746,
			FirstClearCash = '27000',
			RepeatCash = '2900',
		},
	},

	{
		Level = 49,
		Name = 'The Last Gate',
		Description = 'One final gate remains. Beyond it waits the ruler of the arena.',
		Boss = false,
		EnemyTeam = {
			{ DefinitionId = 'Yeti', Level = 10 },
			{ DefinitionId = 'Dragon', Level = 15 },
			{ DefinitionId = 'TyrannosaurusRex', Level = 17 },
			{ DefinitionId = 'Crane', Level = 15 },
			{ DefinitionId = 'SabertoothTiger', Level = 15 },
		},
		Rewards = {
			ArenaXP = 89683,
			FirstClearCash = '28000',
			RepeatCash = '2950',
		},
	},

	{
		Level = 50,
		Name = 'Nightmare Throne',
		Description = 'FINAL BOSS — the ultimate Dragon rules the throne, empowered beyond anything encountered before.',
		Boss = true,
		EnemyTeam = {
			{
				DefinitionId = 'Dragon',
				Level = 50,
				StatMultiplier = 2.25,
				IsBoss = true,
			},
			{
				DefinitionId = 'Yeti',
				Level = 20,
			},
			{
				DefinitionId = 'TyrannosaurusRex',
				Level = 20,
			},
			{
				DefinitionId = 'Dragon',
				Level = 15,
			},
			{
				DefinitionId = 'Yeti',
				Level = 20,
			},
		},
		Rewards = {
			ArenaXP = 112104,
			FirstClearCash = '30000',
			RepeatCash = '3000',
		},
	},
}

-- Catalog length is the level cap: 50 entries => MaxLevel 50.
-- Derived (not hardcoded) so catalog growth can't desync the
-- raid-final logic, progression clamps, and XP caps below.
MAX_LEVEL = #LEVELS

local DIALOGUE: { [string]: { string } } = {
	Greeting = {
		'Ah, you made it!',
		'Got a team ready? The wilds are restless today.',
	},
	Normal = {
		'Think your animals are ready?',
		"Let's see what you've got.",
		'Good luck out there!',
	},
	High = {
		'Whoa... that level is getting dangerous.',
		'Try not to embarrass yourself.',
	},
	Boss = {
		'Hold on. You are going after the boss?',
		'Now THIS is an expedition.',
		'Get ready.',
	},
}

local Arena = {}

function Arena.MaxLevel(): number
	return MAX_LEVEL
end

function Arena.MinTeamSize(): number
	return MIN_TEAM_SIZE
end

function Arena.MaxTeamSize(): number
	return MAX_TEAM_SIZE
end

function Arena.AnimalXPMultiplier(): number
	return ANIMAL_XP_MULTIPLIER
end

function Arena.AttackCooldown(): number
	return ATTACK_COOLDOWN
end

-- Paid-restart tuning (authored Main.Arena Buy1/Buy2). Server-
-- authoritative: the client displays server-provided values and
-- the server re-validates per purchase.
function Arena.RestartWarmupPrice(): string
	return RESTART_WARMUP_PRICE
end

function Arena.RestartDirectPrice(): string
	return RESTART_DIRECT_PRICE
end

-- Buy1 warmup start stage for a SAVED LastLevel (highest level
-- reached BEFORE the current run — never the run's temporary
-- level): half of LastLevel, floored at stage 1. Pure
-- (headless-testable). Returns nil when there is no valid
-- restart progress (nothing reached yet). Callers validate the
-- result against the catalog (IsRestartAvailable) before use.
--   4 -> 2, 8 -> 4, 10 -> 5, 15 -> 7, 20 -> 10.
function Arena.RestartWarmupLevel(lastReached: any): number?
	local last = tonumber(lastReached)
	if last == nil or last ~= math.floor(last) or last < 1 then
		return nil
	end
	return math.max(1, math.floor(last / 2))
end

-- Buy2 direct start stage for a SAVED LastLevel: LastLevel
-- itself, floored at stage 1. Pure (headless-testable).
function Arena.RestartDirectLevel(lastReached: any): number
	local last = tonumber(lastReached)
	if last == nil or last ~= math.floor(last) then
		return 1
	end
	return math.max(1, math.floor(last))
end

-- Whether a paid restart option is currently meaningful:
-- requires a recorded LastReached of at least stage 2 (stage 1
-- is the free Buy3 entry — charging for it would be wrong), and
-- for Buy1 the warmup stage must actually differ from stage 1.
function Arena.IsRestartAvailable(lastReached: any, warmupOnly: boolean?): boolean
	local last = tonumber(lastReached)
	if last == nil or last ~= math.floor(last) or last < 2 or last > MAX_LEVEL then
		return false
	end
	if warmupOnly == true then
		local warmup = Arena.RestartWarmupLevel(last)
		if warmup == nil or warmup <= 1 then
			return false
		end
	end
	return true
end

function Arena.GetAll(): { ArenaLevelDef }
	return LEVELS
end

function Arena.FindLevel(level: number): ArenaLevelDef?
	if type(level) ~= 'number' or level ~= math.floor(level) then
		return nil
	end
	for _, entry in ipairs(LEVELS) do
		if entry.Level == level then
			return entry
		end
	end
	return nil
end

function Arena.IsValidLevel(level: any): boolean
	return Arena.FindLevel(level) ~= nil
end

function Arena.IsBossLevel(level: number): boolean
	if type(level) ~= 'number' or level ~= math.floor(level) or level < 1 then
		return false
	end
	-- Boss cadence follows the authored catalog (10/20/30/40/50):
	-- the per-entry `Boss` flag is authoritative and this helper
	-- mirrors it (agreement enforced by ValidateList).
	return level % 10 == 0
end

-- Pure numeric comparison helper (playerLevel >= arenaLevel
-- for a valid arena level). Display-only legacy helper: the
-- raid model has no unlock gate (every raid starts at stage
-- 1 and advances server-side). Never trust the client: the
-- server re-resolves everything at raid start.
function Arena.IsUnlocked(playerLevel: number, arenaLevel: number): boolean
	if type(playerLevel) ~= 'number' or type(arenaLevel) ~= 'number' then
		return false
	end
	if not Arena.IsValidLevel(arenaLevel) then
		return false
	end
	return playerLevel >= arenaLevel
end

-- XP to advance from `playerLevel` to the next. Nil at cap.
-- Exponential (round-half-up 5 * 1.25^L) on its OWN track,
-- deliberately separate from the animal 1.12 curve: arena
-- gates are tuned to arena XP supply, so a frontier
-- full-clear settles ~2x one threshold and rebirth arena
-- gates (5/15/25/40/45) each cost ~2 full clears. Flat
-- 100-per-level collapsed against exponential settles (one
-- full clear capped the whole track), so do NOT linearize this
-- without re-solving the settle ratios (see stage ArenaXP).
function Arena.XPRequired(playerLevel: number): number?
	if type(playerLevel) ~= 'number' or playerLevel ~= math.floor(playerLevel) then
		return nil
	end
	if playerLevel < 1 or playerLevel >= MAX_LEVEL then
		return nil
	end
	return math.floor(5 * 1.25 ^ (playerLevel - 1) + 0.5)
end

function Arena.Dialogue(category: string): { string }
	if type(category) ~= 'string' then
		return DIALOGUE.Greeting
	end
	local lines = DIALOGUE[category]
	if type(lines) ~= 'table' then
		return DIALOGUE.Greeting
	end
	return lines
end

-- Pure validation over a level list. `defProbe` resolves a
-- DefinitionId to truthy when it exists in the animal catalog
-- (ValidateLive passes Animals.Get). Returns issue
-- strings; empty = valid.
function Arena.ValidateList(levels: any, defProbe: ((string) -> any)?): { string }
	local issues: { string } = {}
	if type(levels) ~= 'table' then
		issues[#issues + 1] = 'catalog is not a table'
		return issues
	end
	local seen: { [number]: boolean } = {}
	for i, entry in ipairs(levels) do
		local where = 'entry ' .. tostring(i)
		if type(entry) ~= 'table' then
			issues[#issues + 1] = where .. ' is not a table'
			continue
		end
		if type(entry.Level) ~= 'number' or entry.Level ~= i then
			issues[#issues + 1] = where .. ' Level must equal its 1-based position'
		elseif seen[entry.Level] then
			issues[#issues + 1] = 'Duplicate Level=' .. tostring(entry.Level)
		else
			seen[entry.Level] = true
		end
		if type(entry.Name) ~= 'string' or entry.Name == '' then
			issues[#issues + 1] = where .. ' has invalid Name'
		end
		if type(entry.Description) ~= 'string' then
			issues[#issues + 1] = where .. ' has invalid Description'
		end
		if entry.Boss ~= Arena.IsBossLevel(entry.Level) then
			issues[#issues + 1] = where .. ' Boss flag disagrees with IsBossLevel'
		end
		if type(entry.EnemyTeam) ~= 'table' or #entry.EnemyTeam < 1 then
			issues[#issues + 1] = where .. ' has empty EnemyTeam'
		else
			for j, enemy in ipairs(entry.EnemyTeam) do
				local ewhere = where .. ' enemy ' .. tostring(j)
				if type(enemy) ~= 'table' then
					issues[#issues + 1] = ewhere .. ' is not a table'
				else
					if type(enemy.DefinitionId) ~= 'string' or enemy.DefinitionId == '' then
						issues[#issues + 1] = ewhere .. ' has invalid DefinitionId'
					elseif defProbe and not defProbe(enemy.DefinitionId) then
						issues[#issues + 1] = ewhere .. ' unknown DefinitionId=' .. enemy.DefinitionId
					end
					if type(enemy.Level) ~= 'number' or enemy.Level ~= math.floor(enemy.Level) or enemy.Level < 1 then
						issues[#issues + 1] = ewhere .. ' has invalid Level'
					end
					local mult = if enemy.StatMultiplier == nil then 1 else enemy.StatMultiplier
					if type(mult) ~= 'number' or mult ~= mult or mult <= 0 then
						issues[#issues + 1] = ewhere .. ' has invalid StatMultiplier'
					end
				end
			end
		end
		if type(entry.Rewards) ~= 'table' then
			issues[#issues + 1] = where .. ' has invalid Rewards'
		else
			if type(entry.Rewards.ArenaXP) ~= 'number' or entry.Rewards.ArenaXP <= 0 then
				issues[#issues + 1] = where .. ' has invalid Rewards.ArenaXP'
			end
			for _, key in ipairs({ 'FirstClearCash', 'RepeatCash' }) do
				local cash = entry.Rewards[key]
				-- BigNumber decimal strings: must parse to a
				-- positive finite amount, otherwise the win
				-- path would pay '0' or fail the grant.
				local amount = if type(cash) == 'string' then tonumber(cash) else nil
				if type(cash) ~= 'string' or cash == '' or amount == nil or amount ~= amount or amount <= 0 then
					issues[#issues + 1] = where .. ' has invalid Rewards.' .. key
				end
			end
		end
	end
	return issues
end

function Arena.ValidateLive(): { string }
	local Animals = require(script.Parent.Parent.Creatures.Animals)
	local function defProbe(defId: string): any
		local ok, rarity = pcall(Animals.Get, defId)
		if ok and type(rarity) == 'string' then
			return true
		end
		return nil
	end
	return Arena.ValidateList(LEVELS, defProbe)
end

-- --- Result card cap (moved from ArenaService/ArenaResultController) ---
-- Max combatant rows on the arena result card. The server truncates rows
-- AND the client renders rows; both read this single value.
Arena.ResultCardCap = 6
return table.freeze(Arena)
