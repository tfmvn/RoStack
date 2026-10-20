--!strict
--[[
	EggsAndHatching — consolidated tunables
	=========================================

	A documentation-and-consolidation module. It is NOT required by the
	implementation: the live game reads the domain config module
	directly (ReplicatedStorage/Config/Creatures/Eggs.lua).

	Copy this file into your project as a single place to read and tune
	every value this system owns, or ignore it and edit
	`Config/Creatures/Eggs.lua` in place. If you copy it, keep it in
	sync — there is no loader that keeps the two in step.

	Read-only reference. Nothing here is read at runtime by
	ReusableSystems' own code.
]]

--!native

local Config = {}

-- ============================================================================
-- 1. GEOMETRY
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.HoverMath, Egg.ModelBuilder, Egg.Constants, RollController
-- Safe to change: YES, but see the notes.
-- Placeholder:  no.

Config.Geometry = {
	-- Studs of empty space between the surface below the egg and the
	-- egg's BOTTOM FACE. This is a CLEARANCE, not a centre offset:
	-- the centre Y is `floor + HoverClearance + height / 2`, so
	-- changing EggSize keeps the visible gap identical.
	-- Range: >= 1 (below ~1 the egg reads as resting on the floor).
	-- Must stay under the ceiling height of the tightest space an egg
	-- flies through.
	HoverClearance = 3,

	-- The procedural fallback egg's size (Vector3). Used when
	-- ServerStorage.EggTemplates.<Rarity> is missing.
	-- Range: any positive size; 4x4x4 reads as a "mystery box".
	EggSize = Vector3.new(4, 4, 4),

	-- Global ON/OFF switch for the coded egg animations (the
	-- EggWalkAnimator walk cycle: hop lift, side/forward lean,
	-- squash/stretch, plus the idle breathing/wobble).
	--   false = eggs still spawn, wander, travel, idle, expire and
	--           are purchased exactly as before, but with a static
	--           rest pose.
	--   true  = the animations behave as before.
	-- Read by EggWalkAnimator on EVERY call, so no animation-code
	-- edits are needed to toggle it.
	-- Safe to change: YES. Default: false.
	EggAnimationsEnabled = false,
}

-- ============================================================================
-- 2. PRICING
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.SpawnService.ResolvePrice, EggService.Purchase,
--           EggOverhead.Refresh
-- Safe to change: YES, but it is a balance decision. The
--           hatch-and-sell EV simulation (EggService.spec.lua) assumes
--           a 70-85% recovery band on EVERY tier; a price change
--           breaks that invariant.
-- Placeholder:  the ladder is Brainrot Arena's.

Config.Price = {
	Common = 100,
	Uncommon = 500,
	Rare = 1_000,
	Epic = 5_000,
	Mythic = 25_500,
	Legendary = 50_000,
	Divine = 100_000,
	Secret = 50_000,
}

-- ============================================================================
-- 3. RARITY WEIGHTS
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  EggService.Start (the centre top-up roll)
-- Safe to change: YES, but a balance decision.
-- Placeholder:  Brainrot Arena's.

-- Which rarity a CENTRE-spawned egg has. This ALIASES
-- ReplicatedStorage.Config.Creatures.Rarity.SpawnWeight — it is not a
-- copy, so editing one edits both. (To tune the two rolls
-- independently, replace the alias with a literal table.)
--
-- Canonical values: Common 38, Uncommon 27, Rare 19, Epic 13.8,
-- Legendary 2, Mythic 0.2, Divine 0, Secret 0.
-- Divine and Secret NEVER appear in the normal roll.
Config.CenterSpawnRarityWeights = {
	Common = 38,
	Uncommon = 27,
	Rare = 19,
	Epic = 13.8,
	Legendary = 2,
	Mythic = 0.2,
	Divine = 0,
	Secret = 0,
}

-- The HATCH roll: which animal rarity an egg of each rarity hatches
-- into. Rows are the EGG rarity, columns are the ANIMAL rarity.
--
-- INVARIANT: the diagonal must be non-zero for every row — every egg
-- must have a chance of the same-tier animal. Off-diagonal zeros are
-- fine (Secret never rolls Common).
--
-- The empty buckets (Uncommon and Secret have no animal definitions)
-- are re-rolled by EggService.HatchEgg, up to 8 times, which slightly
-- concentrates the surviving rarities.
--
-- Tuned so the expected immediate-sale value of a hatch is 70-85% of
-- the egg price on EVERY tier (with the 0.75 liquidation factor and
-- ~1.05 trait-sell EV folded in). Cheap eggs run mostly same-tier;
-- expensive eggs carry real up-roll mass.
Config.HatchRollWeights = {
	Common = {
		Common = 98.78,
		Uncommon = 1.0,
		Rare = 0.2,
		Epic = 0.02,
		Mythic = 0,
		Legendary = 0,
		Divine = 0,
		Secret = 0,
	},
	Uncommon = {
		Common = 43,
		Uncommon = 48.5,
		Rare = 7.75,
		Epic = 1.0,
		Mythic = 0.16,
		Legendary = 0.06,
		Divine = 0,
		Secret = 0,
	},
	Rare = {
		Common = 23.5,
		Uncommon = 36,
		Rare = 37.5,
		Epic = 2.6,
		Mythic = 0.27,
		Legendary = 0.055,
		Divine = 0.017,
		Secret = 0,
	},
	Epic = {
		Common = 0,
		Uncommon = 6,
		Rare = 30,
		Epic = 58,
		Mythic = 5,
		Legendary = 0.8,
		Divine = 0.15,
		Secret = 0.05,
	},
	Mythic = {
		Common = 0,
		Uncommon = 0,
		Rare = 10,
		Epic = 32,
		Mythic = 30,
		Legendary = 20,
		Divine = 6,
		Secret = 2,
	},
	Legendary = {
		Common = 0,
		Uncommon = 0,
		Rare = 2,
		Epic = 10,
		Mythic = 30,
		Legendary = 30,
		Divine = 20,
		Secret = 8,
	},
	Divine = {
		Common = 0,
		Uncommon = 0,
		Rare = 0,
		Epic = 0,
		Mythic = 0,
		Legendary = 5,
		Divine = 78,
		Secret = 17,
	},
	Secret = {
		Common = 0,
		Uncommon = 0,
		Rare = 0,
		Epic = 0,
		Mythic = 28,
		Legendary = 46,
		Divine = 19,
		Secret = 7,
	},
}

-- ============================================================================
-- 4. VISUAL
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.ModelBuilder (the procedural fallback)
-- Safe to change: YES.
-- Placeholder:  Brainrot Arena's flavour.

-- Per-rarity material for the egg's outer part. Studio assets may
-- override; this is the procedural default.
Config.RarityMaterial = {
	Common = Enum.Material.Plastic,
	Uncommon = Enum.Material.SmoothPlastic,
	Rare = Enum.Material.Neon,
	Epic = Enum.Material.Metal,
	Mythic = Enum.Material.ForceField,
	Legendary = Enum.Material.Glass,
	Divine = Enum.Material.Neon,
	Secret = Enum.Material.ForceField,
}

-- ============================================================================
-- 5. ROLL / REVEAL ANIMATION
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.RollController
-- Safe to change: YES (these are timing/feel values).
-- Placeholder:  no.

Config.Roll = {
	-- The roulette's TOTAL wall-clock time, independent of the
	-- catalog size or the preview count. Range: 1..30.
	-- The winner is born at (total - dwell) and holds.
	RollTotalDurationSeconds = 5.0,

	-- How long the winner stays visible at scale 1.0 before
	-- CreateFromEgg takes over. Reserved at the END of the total.
	RollWinnerDwellSeconds = 1.0,

	-- How many animal previews cycle before the winner reveals. The
	-- LAST preview is always the winner; the prior (N-1) are decoys.
	-- With a sparse bucket the sequence degenerates to { winner }.
	-- Range: >= 1.
	RollPreviewCount = 20,

	-- The FIRST decoy's interval (sub-frame fast flash). The rest
	-- follow an arithmetic progression whose SUM is exactly
	-- (RollTotalDurationSeconds - RollWinnerDwellSeconds).
	-- With the defaults: firstInterval 0.025s, nDecoys 19, sum 4.0s,
	-- step ~0.0208s, lastInterval ~0.400s — a ~16:1 ratio between the
	-- first and last decoy intervals.
	RollFirstDecoyIntervalSeconds = 0.025,

	-- Each preview scales IN at this fraction of full size, then OUT
	-- at this fraction. 0.1 is a small "pop in". The winner reveals at
	-- scale 1.0 and STAYS (no scale-down, no destroy).
	RollEntryScale = 0.1,
	RollExitScale = 0.1,

	-- Vertical offset (studs) above the egg's PrimaryPart where the
	-- cycling previews appear. Slightly above the winner's +2.0
	-- landing point so previews at full scale do not clip the egg.
	RollHeightOffset = 3.0,
}

-- ============================================================================
-- 6. RARITY GUARANTEES
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.GuaranteeService, EggService.Start
-- Safe to change: YES.
-- Placeholder:  no.
--
-- A guarantee is a SPAWN guarantee, not a purchase guarantee: the
-- clock resets when the egg SPAWNS, whether naturally or forced.
-- ARRAY ORDER IS PRECEDENCE — when several are due, the FIRST due
-- entry wins (Legendary outranks Mythic). A due guarantee persists
-- until its rarity actually spawns.
-- Server-session scoped (os.clock); no DataStores.

Config.Guarantees = {
	{ Rarity = 'Legendary', Enabled = true, IntervalSeconds = 10 * 60 },
	{ Rarity = 'Mythic', Enabled = true, IntervalSeconds = 20 * 60 },
}

-- The client-side countdown colours. The server writes
-- NextAt/Interval/Revision attributes per guarantee; the client
-- counts down locally and interpolates this ramp by elapsed fraction
-- (far = StartColor, due = EndColor).
Config.GuaranteeTimerUI = {
	StartColor = Color3.fromRGB(255, 70, 70),
	EndColor = Color3.fromRGB(90, 230, 130),
}

-- ============================================================================
-- 7. LIFETIMES AND EXPIRY
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.SpawnService.LifetimeFor, StartExpirySweep, SweepExpired
-- Safe to change: YES.
-- Placeholder:  Brainrot Arena's ladder.
--
-- Seconds an AMBIENT (Available, centre) egg lives before it expires
-- and frees its pool slot. Every _spawnCenter egg — normal,
-- guaranteed, admin, or special — gets the lifetime of its OWN
-- rarity, starting only after the egg is created and registered.
-- OWNED eggs (Placed / Traveling) NEVER expire; purchase flips the
-- state under the mutex before the sweep can see them.
-- Range: > 0 for every rarity (the spec asserts this).

Config.EggLifetimeSeconds = {
	Common = 300,
	Uncommon = 300,
	Rare = 360,
	Epic = 420,
	Legendary = 600,
	Mythic = 900,
	Divine = 900,
	Secret = 1200,
}

-- The expiry sweep cadence (seconds). ONE shared sweep scans the
-- ambient eggs — no per-egg timers, no Heartbeat per egg.
Config.ExpirySweepSeconds = 5

-- ============================================================================
-- 8. PURCHASED-EGG TRAVEL
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.FlightController
-- Safe to change: YES.
-- Placeholder:  no.
--
-- The flight DURATION is distance-derived, not fixed:
--   duration = clamp(distance / PurchasedTravelSpeed,
--                    PurchasedTravelMinDuration,
--                    PurchasedTravelMaxDuration)
-- so arrival timing follows distance, not a clock.
-- The ambient roam is a 2-4 studs/s amble; purchased travel cruises
-- slightly faster but NEVER sprints.

Config.PurchasedTravelSpeed = 5
Config.PurchasedTravelMinDuration = 3
Config.PurchasedTravelMaxDuration = 15

-- ============================================================================
-- 9. AMBIENT WANDERING
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.AmbientService
-- Safe to change: YES — these are feel values.
-- Placeholder:  Brainrot Arena's tuning.
--
-- Tunables for the ambient NPC-style wandering of AVAILABLE (centre,
-- unowned) eggs inside Workspace.EggArea.ActiveEggs. Player-owned
-- eggs never read this table. All movement is server-side,
-- PrimaryPart-pivot based, Humanoid-free.
--
-- The visual amplitudes are composed into the single per-egg
-- PivotTo — zero extra replication while walking.

Config.Ambient = {
	-- Walk speed range, studs/second. Slow NPC amble.
	MinWalkSpeed = 2,
	MaxWalkSpeed = 4,
	-- Idle pause range after reaching a destination, seconds.
	MinIdleTime = 1.5,
	MaxIdleTime = 4,
	-- Horizontal distance that counts as "arrived", studs.
	ArriveRadius = 1.5,
	-- Destinations are sampled inside the floor bounds shrunk by this
	-- margin (plus the egg's own half-extent), studs.
	EdgeMargin = 3,
	-- Minimum separation between ambient eggs, studs. Eggs inside
	-- this radius steer apart; also used as the spatial-hash cell
	-- size.
	SeparationRadius = 6,
	-- Separation push strength, studs/second at zero distance,
	-- falling linearly to 0 at SeparationRadius.
	SeparationStrength = 6,
	-- Hard clamp on the combined walk + separation velocity, as a
	-- multiple of the egg's own walk speed.
	MaxSpeedFactor = 1.3,
	-- Maximum turn rate toward the movement direction, rad/s.
	TurnRate = 2.5,
	-- Destinations closer than this to the egg are rejected during
	-- sampling, studs.
	MinDestinationDistance = 6,
	-- Bounded sampling attempts for spawn points and destinations
	-- (never an infinite loop).
	SampleAttempts = 8,

	-- Procedural hop visuals (eggs have no animation assets):
	-- vertical bounce amplitude in studs, and angular frequency.
	HopAmplitude = 0.15,
	HopFrequency = 6,
	-- Cute walk-cycle visuals (all procedural). Hop-synced side
	-- lean, radians (~+/-6 degrees, alternating sides per hop);
	-- forward lean into motion, radians at full speed (~3.5 degrees).
	SwayAmplitude = 0.11,
	LeanAmplitude = 0.06,
	-- Uniform squash/stretch pulse, fraction of resting scale
	-- (+/-5%). NOTE: per-axis model scale is not supported by
	-- Model:ScaleTo (uniform only); the uniform pulse + vertical
	-- motion sells the same cartoon read.
	StretchAmplitude = 0.05,
	-- ScaleTo re-rigs the model, so it only runs when the target
	-- moved by at least this epsilon. Restores are always exact.
	ScaleEpsilon = 0.006,

	-- Idle breathing (eggs at rest): amplitude in studs and angular
	-- frequency. Written at IdleTickRate Hz with an IdleEpsilon
	-- deadband so resting eggs cost ~nothing.
	IdleAmplitude = 0.03,
	IdleFrequency = 2.8,
	IdleTickRate = 10,
	IdleEpsilon = 0.004,
	-- Walk <-> idle crossfade rates, 1/s (no Tweens per egg).
	BlendInRate = 6,
	BlendOutRate = 3.5,

	-- Per-egg personality, rolled ONCE at spawn/launch (never
	-- per-frame): cycle speed +/-8%, bob +/-15%, sway +/-20%, so eggs
	-- never march in sync. Base + spread; mult = base + rand*spread.
	FreqBase = 0.92,
	FreqSpread = 0.16,
	BobBase = 0.9,
	BobSpread = 0.2,
	SwayBase = 0.8,
	SwaySpread = 0.4,
	-- Low-speed floor: the phase advances at
	-- (FloorBase + FloorGain * speedFactor), so slow eggs still cycle
	-- instead of freezing mid-hop.
	LowSpeedFloorBase = 0.4,
	LowSpeedFloorGain = 0.6,
	-- Settle dip: idleOffset = dip * blend + breath.
	SettleDip = -0.05,
	-- Stand idle wobble gains (the same clocks as the walk cycle, no
	-- travel lean): bob x1.5, sway x0.7, stretch 0.02.
	IdleBobGain = 1.5,
	IdleSwayGain = 0.7,
	IdleStretch = 0.02,
	-- Steering deadzone: velocity vectors below this (studs/s) cause
	-- rotation jitter, not motion.
	SteerDeadzone = 0.05,
	-- Hop scaler from the ground offset:
	-- clamp(offset / Divisor, Min, Max). Shares the flight scaler's
	-- bounds.
	HopSizeDivisor = 2,
	HopSizeMin = 0.7,
	HopSizeMax = 1.25,
}

-- ============================================================================
-- 10. CENTRE SPAWN
-- ============================================================================
-- Lives in: ReplicatedStorage.Config.Creatures.Eggs
-- Read by:  Egg.Constants, EggService.Start, Egg.SpawnService
-- Safe to change: YES.
-- Placeholder:  no.

Config.CenterSpawn = {
	-- Spawn -> Collector float time (seconds).
	-- *** LEGACY AND UNUSED. *** The flight path is speed-derived
	-- (distance / PurchasedTravelSpeed, clamped). This value is kept
	-- for back-compat and is misleading.
	TravelDuration = 7,
	-- The target NORMAL ambient egg population. This is the cap the
	-- top-up thread works toward. The `Extra` pool (guarantees,
	-- admin spawns) BYPASSES it, so the centre can hold more than
	-- this.
	CenterMax = 10,
	-- The minimum XZ distance between two centre eggs, studs.
	MinSpawnSpacing = 7,
	-- The centre-area spawn ring radius, studs.
	Radius = 20,
	-- Seconds between centre top-up attempts.
	Interval = 30,
}

-- ============================================================================
-- 11. HARDCODED CONSTANTS (documented, not configurable)
-- ============================================================================
-- These live in the code, not in config. Listed so a new game knows
-- what to reproduce.

Config.InternalConstants = {
	-- Egg.FlightController
	FlightSegmentEpsilon = 0.01, -- consecutive path points closer than this are dropped
	-- Egg.RollController
	RollPopPoolSize = 4, -- depth of the Pop sound pool
	RollScaleEpsilon = 0.004, -- scale quantisation per controller+model
	RollBobHz = 1.5, -- preview Y bob frequency
	RollBobAmplitudeStuds = 0.15, -- preview Y bob amplitude
	RollPopInFrac = 0.35, -- per-entry scale curve phase fractions
	RollSettleFrac = 0.10,
	RollHoldFrac = 0.30,
	RollPopOutFrac = 0.25,
	RollPeakScale = 1.15, -- the peak of the pop-in ease
	-- Egg.FlightController
	FlightFacingOffset = math.pi, -- the visual front is local +Z, so yaw is flipped
	-- Egg.Service
	MaxHatchRarityRerolls = 8, -- how many times an empty animal rarity is re-rolled
}

return table.freeze(Config)
