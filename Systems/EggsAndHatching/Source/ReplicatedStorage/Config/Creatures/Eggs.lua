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
	Eggs
	================
	Tunables for the Egg subsystem: hover clearance, rarity
	weights, opening weights, prices, the rarity-tier color
	override, and the rarity-specific material used for the visual
	model.

	Hover semantics (Phase 5):
	  * An Egg holds a CONSTANT `HoverClearance` studs
	    between the surface below it and its own BOTTOM FACE. It
	    does not bob, does not oscillate, and does not change
	    height during flight.
	  * The centre Y is derived, never authored:
	        centreY = localFloor + HoverClearance + blockHeight / 2
	    `Egg/HoverMath.lua` owns that arithmetic and its
	    inverse; no other module computes it inline.
	  * The local floor is the Y of the surface directly under the
	    egg: the center floor for `Available` eggs, the slot's
	    top for `Placed` eggs, and the pathfinder waypoint's Y
	    during flight — so the clearance stays constant over ramps
	    and across multiple floors.

	Spec §18-§25.
]]

local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)
local RarityDefs = require(script.Parent.Rarity)

local Eggs = {}

-- --- Hover clearance ---------------------------------------------

-- Studs of empty space kept between the surface below the egg
-- and the egg's BOTTOM FACE. This is a clearance, NOT a centre
-- offset: the centre Y is `floor + HoverClearance + height / 2`,
-- so changing `EggSize` below keeps the visible gap identical.
--
-- Designers should not go below ~1 (the egg reads as resting on
-- the floor rather than hovering) and should keep it under the
-- ceiling height of the tightest space an egg flies through.
Eggs.HoverClearance = 3

-- --- Spawn shape -------------------------------------------------

-- Per-egg visual size. A short, fat part reads as "mystery box"
-- in a low-poly arena.
Eggs.EggSize = Vector3.new(4, 4, 4)

-- --- Animation toggle -------------------------------------------------

-- Global ON/OFF switch for the coded Egg animations (the
-- EggWalkAnimator walk-cycle: hop lift, side/forward lean,
-- squash/stretch, plus the idle breathing/wobble). Read by
-- ReplicatedStorage/Utility/EggWalkAnimator.lua on every call,
-- so no animation-code edits are needed to toggle.
--   false = eggs still spawn, wander, travel, idle, expire and
--           are purchased exactly as before, but with a static
--           rest pose (no lift/lean/squash/breath/wobble).
--   true  = existing Egg animations behave exactly as before.
Eggs.EggAnimationsEnabled = false

-- --- Pricing ------------------------------------------------------

-- Base price is set per rarity. Spec §22: rarer eggs cost more.
-- Tuned so the cheapest is 100 and the rarest is 50_000.
Eggs.Price = {
	[Rarity.Common] = 100,
	[Rarity.Uncommon] = 5_00,
	[Rarity.Rare] = 1_000,
	[Rarity.Epic] = 5_000,
	[Rarity.Mythic] = 25_500,
	[Rarity.Legendary] = 50_000,
	[Rarity.Divine] = 100_000,
	[Rarity.Secret] = 50_000,
}

-- --- Rarity weights ------------------------------------------------

-- Which rarity a center-spawned egg has. Forwarded from
-- RarityDefs.SpawnWeight but kept here so designers can tune
-- the two rolls (center spawn vs. open roll) independently.
Eggs.CenterSpawnRarityWeights = RarityDefs.SpawnWeight

-- The rarer the egg, the rarer the animal inside. Spec §24.
-- Designed so opening a Common egg skews toward Common/Uncommon
-- animals, while opening a Secret egg skews toward the rarest.
-- BALANCED (hatch-and-sell recovery): weights are tuned so
-- the expected immediate-sale value of a hatch is 70-85% of
-- the egg price on EVERY tier (with the 0.75 liquidation
-- factor and ~1.05 trait-sell EV folded in — see the balance
-- report for the per-tier proof). Cheap eggs run mostly
-- same-tier (safe first buys, trait lottery intact);
-- expensive eggs carry real up-roll mass (jackpot feel).
-- Empty buckets (Uncommon/Secret have no defs) re-roll per
-- EggService, which slightly concentrates the survivors.
Eggs.HatchRollWeights = {
	[Rarity.Common] = {
		[Rarity.Common] = 98.78,
		[Rarity.Uncommon] = 1.0,
		[Rarity.Rare] = 0.2,
		[Rarity.Epic] = 0.02,
		[Rarity.Mythic] = 0,
		[Rarity.Legendary] = 0,
		[Rarity.Divine] = 0,
		[Rarity.Secret] = 0,
	},
	[Rarity.Uncommon] = {
		[Rarity.Common] = 43,
		[Rarity.Uncommon] = 48.5,
		[Rarity.Rare] = 7.75,
		[Rarity.Epic] = 1.0,
		[Rarity.Mythic] = 0.16,
		[Rarity.Legendary] = 0.06,
		[Rarity.Divine] = 0,
		[Rarity.Secret] = 0,
	},
	[Rarity.Rare] = {
		[Rarity.Common] = 23.5,
		[Rarity.Uncommon] = 36,
		[Rarity.Rare] = 37.5,
		[Rarity.Epic] = 2.6,
		[Rarity.Mythic] = 0.27,
		[Rarity.Legendary] = 0.055,
		[Rarity.Divine] = 0.017,
		[Rarity.Secret] = 0,
	},
	[Rarity.Epic] = {
		[Rarity.Common] = 0,
		[Rarity.Uncommon] = 6,
		[Rarity.Rare] = 30,
		[Rarity.Epic] = 58,
		[Rarity.Mythic] = 5,
		[Rarity.Legendary] = 0.8,
		[Rarity.Divine] = 0.15,
		[Rarity.Secret] = 0.05,
	},
	[Rarity.Mythic] = {
		[Rarity.Common] = 0,
		[Rarity.Uncommon] = 0,
		[Rarity.Rare] = 10,
		[Rarity.Epic] = 32,
		[Rarity.Mythic] = 30,
		[Rarity.Legendary] = 20,
		[Rarity.Divine] = 6,
		[Rarity.Secret] = 2,
	},
	[Rarity.Legendary] = {
		[Rarity.Common] = 0,
		[Rarity.Uncommon] = 0,
		[Rarity.Rare] = 2,
		[Rarity.Epic] = 10,
		[Rarity.Mythic] = 30,
		[Rarity.Legendary] = 30,
		[Rarity.Divine] = 20,
		[Rarity.Secret] = 8,
	},
	[Rarity.Divine] = {
		[Rarity.Common] = 0,
		[Rarity.Uncommon] = 0,
		[Rarity.Rare] = 0,
		[Rarity.Epic] = 0,
		[Rarity.Mythic] = 0,
		[Rarity.Legendary] = 5,
		[Rarity.Divine] = 78,
		[Rarity.Secret] = 17,
	},
	[Rarity.Secret] = {
		[Rarity.Common] = 0,
		[Rarity.Uncommon] = 0,
		[Rarity.Rare] = 0,
		[Rarity.Epic] = 0,
		[Rarity.Mythic] = 28,
		[Rarity.Legendary] = 46,
		[Rarity.Divine] = 19,
		[Rarity.Secret] = 7,
	},
}

-- --- Visual -------------------------------------------------------

-- Per-rarity material for the Egg's outer Part. Studio
-- assets may override; this is the procedural default.
Eggs.RarityMaterial = {
	[Rarity.Common] = Enum.Material.Plastic,
	[Rarity.Uncommon] = Enum.Material.SmoothPlastic,
	[Rarity.Rare] = Enum.Material.Neon,
	[Rarity.Epic] = Enum.Material.Metal,
	[Rarity.Mythic] = Enum.Material.ForceField,
	[Rarity.Legendary] = Enum.Material.Glass,
	[Rarity.Divine] = Enum.Material.Neon,
	[Rarity.Secret] = Enum.Material.ForceField,
}

-- --- Roll / reveal animation -----------------------------------

-- FIXED total animation duration (seconds). The roulette's
-- wall-clock time is exactly this value, independent of
-- the catalog size or preview count. 5s is the user's
-- target: long enough to feel deliberate, short enough
-- to not overstay the player's attention.
Eggs.RollTotalDurationSeconds = 5.0

-- The winner's visible dwell time (seconds), reserved at
-- the END of the total duration. The winner preview is
-- born at `total - winnerDwell` and stays at scale 1.0
-- for `winnerDwell` seconds before CreateFromEgg
-- takes over. The remaining time (total - winnerDwell)
-- is distributed across the decoy previews via the
-- linear arithmetic ramp below.
Eggs.RollWinnerDwellSeconds = 1.0

-- How many animal previews cycle before the winner reveals.
-- The LAST preview is always the winner; the prior (N-1) are
-- decoys drawn from the rolled rarity's bucket. With a sparse
-- bucket (e.g. a rarity with a single defId), the sequence
-- degenerates to { winner } and the loop runs once. 20 fits
-- comfortably in a 5s timeline: 19 decoys in 4s + 1s winner dwell.
Eggs.RollPreviewCount = 20

-- Per-preview interval ramp. Decoy intervals follow an
-- ARITHMETIC progression (linear deceleration):
--
--   interval[i] = firstInterval + (i - 1) * step
--
-- where i = 1..nDecoys (nDecoys = previewCount - 1).
-- The first decoy uses `firstInterval` (sub-frame fast
-- flash). The STEP is solved from the arithmetic
-- series so the sum of decoy intervals equals
-- (RollTotalDurationSeconds - RollWinnerDwellSeconds).
-- With the defaults below:
--   firstInterval = 0.025s, nDecoys = 19, sum = 4.0s
--   step = ~0.0208s, lastInterval = ~0.400s
-- giving a ~16:1 ratio between the first and last
-- decoy intervals -- the 'inverted linear drop in
-- speed' the user asked for.
Eggs.RollFirstDecoyIntervalSeconds = 0.025

-- Each preview scales IN at this fraction of full size, then
-- OUT at this fraction. 0.1 is a small "pop in" -- the preview
-- materializes then dissolves. The winner reveals at scale 1.0
-- and STAYS (no scale-down, no destroy).
Eggs.RollEntryScale = 0.1
Eggs.RollExitScale = 0.1

-- Vertical offset (in studs) above the egg's PrimaryPart
-- where the cycling previews appear. Slightly above the
-- winner's +2.0 landing point so previews at full scale
-- don't visually clip the egg.
Eggs.RollHeightOffset = 3.0

-- --- Rarity guarantees (EggGuaranteeService) -------------------

-- Periodic spawn guarantees layered on top of the normal
-- center-spawn roll. If `IntervalSeconds` elapse without that
-- rarity appearing in the automatic center pool, the next
-- eligible automatic spawn is FORCED to it instead of rolling.
-- Array order is precedence: when several guarantees are due,
-- the FIRST due entry wins (Legendary outranks Mythic), and a
-- due guarantee persists until its rarity actually spawns.
-- A guarantee is a SPAWN guarantee, not a purchase guarantee:
-- the clock resets when the egg spawns. Natural and forced
-- appearances both reset. Server-session scoped (os.clock);
-- no DataStores. The spawn system itself is untouched — it
-- still creates exactly one egg per spawn; only the rarity
-- choice is overridden.
Eggs.Guarantees = {
	{
		Rarity = Rarity.Legendary,
		Enabled = true,
		IntervalSeconds = 10 * 60,
	},
	{
		Rarity = Rarity.Mythic,
		Enabled = true,
		IntervalSeconds = 20 * 60,
	},
}

-- --- Guarantee timer UI (Map.CenterPart.BillboardGui.Egg; legacy Map.EggTimer) -------------------

-- Server writes NextAt/Interval/Revision attributes per
-- guarantee; the client counts down locally and interpolates
-- this color ramp by elapsed fraction (far = StartColor, due =
-- EndColor). MM:SS (H:MM:SS past the hour), clamped at 00:00,
-- never negative.
Eggs.GuaranteeTimerUI = {
	StartColor = Color3.fromRGB(255, 70, 70),
	EndColor = Color3.fromRGB(90, 230, 130),
}

-- --- Ambient egg lifetimes (universal rotation) ------------------

-- Seconds an AMBIENT (Available, center) egg lives before it
-- expires and frees its pool slot. Per final rarity: every
-- _spawnCenter egg — normal, guaranteed, admin, or special —
-- gets the lifetime of its own rarity, starting only after
-- the egg is successfully created and registered. Owned eggs
-- (Placed/Traveling: purchased, carried, hatching) never
-- expire; purchase flips state under mutex before the sweep
-- can see them. One shared sweep (ExpirySweepSeconds) reaps
-- past-deadline ambient eggs — no per-egg timers, no
-- Heartbeat connections per egg.
Eggs.EggLifetimeSeconds = {
	Common = 300,
	Uncommon = 300,
	Rare = 360,
	Epic = 420,
	Legendary = 600,
	Mythic = 900,
	Divine = 900,
	Secret = 1200,
}

-- Expiry sweep cadence: how often the single shared sweep
-- scans ambient eggs for past-deadline records, seconds.
Eggs.ExpirySweepSeconds = 5

-- --- Ambient wandering (EggAmbientService) ----------------------------

-- Tunables for the ambient NPC-style wandering of AVAILABLE
-- (center, unowned) eggs inside Workspace.EggArea.ActiveEggs.
-- Player-owned eggs never read this table. All movement is
-- server-side, PrimaryPart-pivot based, Humanoid-free.
--
-- Purchased-egg travel speed lives here too (same feel family):
-- ambient roam is a 2-4 studs/s amble; purchased travel cruises
-- slightly faster so cross-map delivery doesn't take forever,
-- but NEVER sprints. Flight duration is distance / this speed,
-- clamped below — arrival timing follows distance, not a fixed
-- clock.
Eggs.PurchasedTravelSpeed = 5
Eggs.PurchasedTravelMinDuration = 3
Eggs.PurchasedTravelMaxDuration = 15
Eggs.Ambient = {
	-- Walk speed range, studs/second. Slow NPC amble.
	MinWalkSpeed = 2,
	MaxWalkSpeed = 4,
	-- Idle pause range after reaching a destination, seconds.
	MinIdleTime = 1.5,
	MaxIdleTime = 4,
	-- Horizontal distance that counts as "arrived", studs.
	ArriveRadius = 1.5,
	-- Destinations are sampled inside Floor bounds shrunk by
	-- this margin (plus the egg's own half-extent), studs.
	EdgeMargin = 3,
	-- Minimum separation between ambient eggs, studs. Eggs
	-- inside this radius steer apart; also used as the
	-- spatial-hash cell size.
	SeparationRadius = 6,
	-- Separation push strength, studs/second at zero distance,
	-- falling linearly to 0 at SeparationRadius.
	SeparationStrength = 6,
	-- Hard clamp on combined walk + separation velocity, as a
	-- multiple of the egg's own walk speed.
	MaxSpeedFactor = 1.3,
	-- Maximum turn rate toward the movement direction, rad/s.
	TurnRate = 2.5,
	-- Destinations closer than this to the egg are rejected
	-- during sampling, studs.
	MinDestinationDistance = 6,
	-- Bounded sampling attempts for spawn points and
	-- destinations (never infinite-loop).
	SampleAttempts = 8,
	-- Procedural hop visuals (eggs have no animation assets):
	-- vertical bounce amplitude in studs and angular frequency.
	HopAmplitude = 0.15,
	HopFrequency = 6,
	-- Cute walk-cycle visuals (all procedural, composed into the
	-- single per-egg PivotTo — zero extra replication while
	-- walking). Hop-synced side lean, radians (~±6°, alternating
	-- sides per hop); forward lean into motion, radians at full
	-- speed (~3.5°).
	SwayAmplitude = 0.11,
	LeanAmplitude = 0.06,
	-- Uniform squash/stretch pulse, fraction of resting scale
	-- (±5%: stretch rising, neutral apex, squash landing — driven
	-- by hop vertical velocity, §3 of the tuning spec).
	-- NOTE: per-axis model scale (X=1.06/Y=0.90) is not
	-- supported by Model:ScaleTo (uniform only); the uniform
	-- pulse + vertical motion sells the same cartoon read.
	StretchAmplitude = 0.05,
	-- ScaleTo re-rigs the model, so it only runs when the target
	-- moved by at least this epsilon. Restores are always exact.
	ScaleEpsilon = 0.006,
	-- Idle breathing (eggs at rest): amplitude in studs and
	-- angular frequency. Written at IdleTickRate Hz with an
	-- IdleEpsilon deadband so resting eggs cost ~nothing.
	IdleAmplitude = 0.03,
	IdleFrequency = 2.8,
	IdleTickRate = 10,
	IdleEpsilon = 0.004,
	-- Walk↔idle crossfade rates, 1/s (no Tweens per egg).
	BlendInRate = 6,
	BlendOutRate = 3.5,
	-- Per-egg personality, rolled ONCE at spawn/launch (never
	-- per-frame): cycle speed ±8%, bob ±15%, sway ±20%, so eggs
	-- never march in sync. Base + spread; mult = base + rand*spread.
	FreqBase = 0.92,
	FreqSpread = 0.16,
	BobBase = 0.9,
	BobSpread = 0.2,
	SwayBase = 0.8,
	SwaySpread = 0.4,
	-- Low-speed floor: phase advances at
	-- (FloorBase + FloorGain * speedFactor), so slow eggs still
	-- cycle instead of freezing mid-hop. CURRENT: 0.4 + 0.6x.
	LowSpeedFloorBase = 0.4,
	LowSpeedFloorGain = 0.6,
	-- Settle dip: idleOffset = dip * blend + breath. CURRENT: -0.05.
	SettleDip = -0.05,
	-- Stand idle wobble gains (same clocks as the walk cycle, no
	-- travel lean): bob x1.5, sway x0.7, stretch 0.02.
	IdleBobGain = 1.5,
	IdleSwayGain = 0.7,
	IdleStretch = 0.02,
	-- Steering deadzone: velocity vectors below this (studs/s)
	-- cause rotation jitter, not motion. CURRENT: 0.05.
	SteerDeadzone = 0.05,
	-- Hop scaler from ground offset: clamp(offset / Divisor, Min,
	-- Max). Shares the flight scaler's bounds. CURRENT: /2,
	-- [0.7, 1.25].
	HopSizeDivisor = 2,
	HopSizeMin = 0.7,
	HopSizeMax = 1.25,
}

-- --- Center-spawn tuning (moved from GameConfig; values identical) ---
-- Lucky-egg spawns around the central platform. Designers balance center
-- economy HERE ( SpawnService reads via Egg.Constants ).
Eggs.CenterSpawn = {
	TravelDuration = 7, -- Spawn -> Collector float time (seconds).
	CenterMax = 10, -- target NORMAL ambient egg population.
	MinSpawnSpacing = 7, -- min XZ studs between center eggs.
	Radius = 20, -- center-area spawn ring radius (studs).
	Interval = 30, -- seconds between center lucky-egg spawns.
}
return table.freeze(Eggs)
