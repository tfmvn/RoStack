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
	Vfx
	=========
	Single source of truth for VFX TUNABLES: lifetimes, cleanup caps,
	and presentation throttles for level-up, egg roll, ambient eggs,
	and stand idle motion.

	WHAT THIS CONTROLS
	------------------
	How long celebratory effects live and how often idle motion ticks.
	Arena hit VFX lives in ArenaPresentationConfig.Vfx (canonical
	there). Asset NAMES live in AudioConfig (LevelUp) / EggConfig
	(roll tuning) — this module owns GENERIC lifetime/cleanup policy
	plus the level-up specifics below.

	RUNTIME RULE: effects are Debris-backed clones. Tuners change
	durations here; the clone-per-event mechanism stays code-owned.
]]

local Vfx = {}

-- --- Level-up celebration (LevelUpPresentation) ----------------------------------------------

Vfx.LevelUp = {
	-- Fallback VFX cleanup delay. CURRENT: 2.0s.
	Lifetime = 2.0,
	-- Cleanup cap: task.delay(math.min(Lifetime, Cap)).
	-- CURRENT: 1.2s. Lower = snappier cleanup; higher keeps
	-- long-tail particles (never above Lifetime's intent).
	CleanupCap = 1.2,
	-- Clone debris: longest emitter lifetime + Padding, clamped
	-- to [CloneMin, Lifetime + CloneMaxPad]. CURRENT: +0.75s,
	-- [1.0, Lifetime+1.0].
	CloneCleanupPadding = 0.75,
	CloneCleanupMin = 1.0,
	CloneCleanupMaxPad = 1.0,
	-- Asset names under ServerStorage.Assets.Vfx / Sfx.
	-- Canonical: AudioConfig.LevelUp mirrors these names.
	VfxAssetName = 'Upgrade',
	SfxAssetName = 'LevelUp',
	-- Default celebration rise height. CURRENT: 2 studs, clamped
	-- per-model to [MinBurst, MaxBurst] via extents*0.5+0.5.
	-- Tuning the clamp changes per-species feel — preserve.
	BurstDefault = 2,
	BurstMin = 1,
	BurstMax = 4,
	-- Scale-frame epsilon + min interval (perf throttle: frames
	-- re-scale on meaningful change AND at most 30/s).
	-- ALGORITHM constants (regression-tested behavior) — exposed
	-- for visibility, change with care. CURRENT: 0.004 / 1/30.
	ScaleEpsilon = 0.004,
	ScaleMinInterval = 1 / 30,
	-- RollOffMaxDistance on celebration sounds is an audio
	-- PASSTHROUGH (authored value preserved). Not tuned here.
	--
	-- BOP choreography (total ~0.68s: quick + punchy + satisfying).
	-- Growth overlaps the bop instead of preceding it: the baseline
	-- scale eases start->target over the first GrowOverlap seconds
	-- while squash/stretch multiplies around it. CURRENT: 0.6
	-- (no 0.45s "thinking pause").
	Bop = {
		GrowOverlap = 0.6,
		AnticipationDuration = 0.10,
		AnticipationSquash = 0.94,
		AnticipationDip = 0.12,
		LaunchDuration = 0.16,
		LaunchStretch = 1.06,
		ApexDuration = 0.06,
		FallDuration = 0.18,
		LandingDuration = 0.08,
		LandingSquash = 0.95,
		SettleDuration = 0.10,
	},
	-- Micro-tilt personality (degrees, Z-axis, relative to rest).
	Tilt = {
		Takeoff = -2,
		Apex = 2,
		Landing = -1,
	},
}

-- --- Egg roll reveal (RollController) ------------------------------------------------------------

Vfx.EggRoll = {
	-- Placeholder reveal sizes. CURRENT: 1x1x1 / 2x2x2.
	PlaceholderSize = Vector3.new(1, 1, 1),
	RevealSize = Vector3.new(2, 2, 2),
	-- Fallback label colors. CURRENT: gray (200,200,200) /
	-- white / black stroke. Presentation fallbacks only.
	FallbackColor = Color3.fromRGB(200, 200, 200),
	FallbackText = Color3.fromRGB(255, 255, 255),
	FallbackStroke = Color3.fromRGB(0, 0, 0),
	-- Silhouette concealment. CURRENT: black on black.
	SilhouetteText = Color3.fromRGB(0, 0, 0),
	SilhouetteStroke = Color3.fromRGB(255, 255, 255),
	-- Celebration rise. Same contract as LevelUp burst.
	-- CURRENT: default 2, clamp [1, 4].
	BurstDefault = 2,
	BurstMin = 1,
	BurstMax = 4,
	-- Cleanup cap. CURRENT: min(2.0, 1.2).
	Lifetime = 2.0,
	CleanupCap = 1.2,
}

-- --- Generic VFX hygiene ------------------------------------------------------------------------------

Vfx.Hygiene = {
	-- Egg flight debug path color. CURRENT: (128,200,255) /
	-- (80,160,220). Diagnostic only (never in production paths).
	DebugPathColor = Color3.fromRGB(128, 200, 255),
	DebugPathColorAlt = Color3.fromRGB(80, 160, 220),
	-- Debug waypoint marker size + lift. CURRENT: 0.4 / +0.25y.
	DebugMarkerSize = 0.4,
	DebugMarkerLift = 0.25,
}

function Vfx.Validate(): { string }
	local issues: { string } = {}
	if type(Vfx.LevelUp.Lifetime) ~= 'number' or Vfx.LevelUp.Lifetime <= 0 then
		issues[#issues + 1] = 'LevelUp.Lifetime must be a number > 0'
	end
	if type(Vfx.LevelUp.CleanupCap) ~= 'number' or Vfx.LevelUp.CleanupCap <= 0 then
		issues[#issues + 1] = 'LevelUp.CleanupCap must be a number > 0'
	end
	return issues
end

return table.freeze(Vfx)
