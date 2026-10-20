--!strict
--[[
	CANONICAL CONFIG (unified architecture).
	Single source of truth for its domain. New code must require this path.
	Values preserved exactly from the pre-migration configs - do NOT rebalance
	without a gameplay review. See Docs/configuration/ for domain docs.
]]
-- Bases: counts, slots, spawn, collector, stands, layout, locks.
-- Balance base progression here. Runtime ownership stays in BaseService.
local Bases = {}

-- --- Server sizing (former GameConfig) ---
-- Cap on simultaneously-loaded players. Spec S11: 5.
Bases.Server = {
	MaxPlayers = 5,
}
-- Number of physical bases (Base_1..Base_8; must match authored map).
Bases.Count = 8
-- Unified slots per base (eggs + animals share the pool).
Bases.Slots = {
	Count = 8,
	Size = Vector3.new(3.5, 0.6, 3.5),
	Offsets = {}, -- filled below (8-stop ring, radius 12, Y 2)
}
do
	local count = Bases.Slots.Count
	for i = 1, count do
		local angle = ((i - 1) / count) * math.pi * 2
		Bases.Slots.Offsets[i] = Vector3.new(math.cos(angle) * 12, 2, math.sin(angle) * 12)
	end
end

-- --- Collector + spawn + money pool (former BaseConfig) ---
--[[
	Bases (collector / spawn / pool look)
	==========
	Single source of truth for base-world PRESENTATION tunables:
	collector colors, amount-label styling, and spawn placement.

	WHAT THIS CONTROLS
	------------------
	How bases look in the world. Lock TIMING stays canonical in
	Bases.Lock below (never duplicated); slot GEOMETRY stays
	canonical in Bases.Slots above (Count/Size/Offsets).

	WHAT THIS DOES NOT CONTROL
	--------------------------
	* Base assignment, ownership, persistence, lock state machine,
	  collision groups — code-owned (BaseService / BaseLockService).
	* Slot count/size/offsets — Bases.Slots (authored map contract).
]]

-- --- Collector -------------------------------------------------------------------

Bases.Collector = {
	-- Physical collector part color. CURRENT: (85, 255, 127).
	PartColor = Color3.fromRGB(85, 255, 127),
	-- Dev-default collector height in studs. Only applies when the
	-- service builds a missing collector (authored map parts are
	-- never resized). CURRENT: 4.
	Height = 4,
	-- Dev-default collector transparency. CURRENT: 0.6.
	Transparency = 0.6,
	-- Stand amount label color. CURRENT: (120, 220, 130).
	AmountTextColor = Color3.fromRGB(120, 220, 130),
	-- Floating money-pool chip (client fallback when no icon
	-- asset configured). CURRENT: green text on dark green.
	PoolChip = {
		TextColor = Color3.fromRGB(85, 255, 127),
		Background = Color3.fromRGB(20, 60, 30),
		Font = Enum.Font.GothamBold,
		TextSize = 22,
	},
}

-- --- Spawn placement -----------------------------------------------------------------

Bases.Spawn = {
	-- Lift above the base spawn CFrame when teleporting the
	-- character on join/respawn. CURRENT: 4 studs.
	JoinLiftStuds = 4,
}

-- --- Money-pool HUD widget (MoneyPoolController, client feel) -------------------------------
-- Icon spray + counter bop for pool arrivals. Presentation only:
-- the pool AMOUNT stays server-authoritative (IncomeService).

Bases.MoneyPool = {
	-- Icon sizing (px) + concurrency cap.
	IconBasePx = 34,
	IconMin = 6,
	IconTier2 = 10,
	IconTier3 = 16,
	IconMax = 24,
	ActiveIconCap = 20,
	-- Number-roll: steps over duration. CURRENT: 12 / 0.45s.
	NumberSteps = 12,
	NumberSeconds = 0.45,
	-- Counter bop: peak scale (dense = 3+ arrivals in window),
	-- up/down tween seconds, arrival density window.
	BopPeak = 1.12,
	BopPeakDense = 1.18,
	BopUpSeconds = 0.08,
	BopDownSeconds = 0.12,
	ArrivalWindow = 0.3,
	DenseThreshold = 3,
	-- Distributed burst spray (px radii, spread, jitter) + flight
	-- durations (seconds). CURRENT values preserved exactly.
	BurstMinRadius = 55,
	BurstMaxRadius = 135,
	BurstXSpread = 1.15,
	BurstYSpread = 1.0,
	BurstJitterPx = 18,
	FlickMin = 55,
	FlickMax = 120,
	FlickSideJitter = 45,
	FlightMinSeconds = 0.34,
	FlightMaxSeconds = 0.53,
}

function Bases.ValidateBase(): { string }
	local issues: { string } = {}
	if typeof(Bases.Collector.PartColor) ~= 'Color3' then
		issues[#issues + 1] = 'Collector.PartColor must be a Color3'
	end
	if typeof(Bases.Collector.AmountTextColor) ~= 'Color3' then
		issues[#issues + 1] = 'Collector.AmountTextColor must be a Color3'
	end
	if type(Bases.Spawn.JoinLiftStuds) ~= 'number' or Bases.Spawn.JoinLiftStuds < 0 then
		issues[#issues + 1] = 'Spawn.JoinLiftStuds must be a number >= 0'
	end
	local mp = Bases.MoneyPool
	local function mpNum(name: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = 'MoneyPool.' .. name .. ' must be a number >= ' .. tostring(min)
		end
	end
	mpNum('IconBasePx', mp.IconBasePx, 1)
	mpNum('ActiveIconCap', mp.ActiveIconCap, 1)
	mpNum('NumberSteps', mp.NumberSteps, 1)
	mpNum('NumberSeconds', mp.NumberSeconds, 0.001)
	mpNum('BopUpSeconds', mp.BopUpSeconds, 0.001)
	mpNum('BopDownSeconds', mp.BopDownSeconds, 0.001)
	mpNum('FlightMinSeconds', mp.FlightMinSeconds, 0.001)
	mpNum('FlightMaxSeconds', mp.FlightMaxSeconds, 0.001)
	if mp.FlightMaxSeconds < mp.FlightMinSeconds then
		issues[#issues + 1] = 'MoneyPool.FlightMaxSeconds must be >= FlightMinSeconds'
	end
	local feel = Bases.Collector.Feel
	local function feelNum(name: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = 'Collector.Feel.' .. name .. ' must be a number >= ' .. tostring(min)
		end
	end
	feelNum('PressFraction', feel.PressFraction, 0.001)
	feelNum('PressSeconds', feel.PressSeconds, 0.001)
	feelNum('ReleaseSeconds', feel.ReleaseSeconds, 0.001)
	return issues
end

-- --- Collector press feel (moved from AudioConfig.Collect) ---
-- Button press travel + VFX cleanup feel for cash collection.
-- The SFX pool size stays in Presentation.Audio (Audio.Collect.PoolSize).
Bases.Collector.Feel = {
	PressFraction = 0.45,
	MinPressTravel = 0.05,
	PressSeconds = 0.05,
	HoldSeconds = 0.05,
	ReleaseSeconds = 0.1,
	VfxSurfaceLift = 0.25,
	VfxCleanupPadding = 0.75,
	VfxCleanupMin = 1.0,
	VfxCleanupMax = 5.0,
}

-- --- Lock (former BaseLockConfig; runtime state stays in BaseLockService) ---
Bases.Lock = {}
--[[
	Bases.Lock
	==============
	Tunables for the server-authoritative Base Locking system
	(Base/BaseLockService). The lock is runtime-only state —
	nothing here is persisted.
]]

-- How long one owner button-press locks the Base, in seconds.
Bases.Lock.LockDurationSeconds = 60

-- Per-button server-side debounce: Touched events within this
-- window after a handled press are ignored, so one physical
-- contact can't stack timers.
Bases.Lock.ButtonDebounceSeconds = 1

-- When true, an owner press while already locked restarts the
-- duration (single timer per Base — never stacked). When
-- false, presses during an active lock are ignored: once
-- locked, the base cannot be relocked until the timer hits 0
-- and the lock expires on its own.
Bases.Lock.RefreshOnPress = false

-- --- Laser barrier animation (presentation-only) ---------------------

-- The physical lasers (Parts named "Part" under
-- LazerDoor.Lazers) grow from the ground on lock and retract on
-- unlock. Pure presentation: collision/group behavior stays in
-- BaseLockService._applyGeometry, which this never touches.
-- Durations in seconds; stagger keeps multi-laser bases feeling
-- like one barrier activating together.
Bases.Lock.LaserExtendSeconds = 0.4
Bases.Lock.LaserRetractSeconds = 0.3
Bases.Lock.LaserStaggerSeconds = 0.025
-- Retracted height in studs. Effectively hidden at the ground
-- while keeping a non-zero Size (never derive full height from
-- the animated Size — the authored original is captured once).
Bases.Lock.LaserRetractedHeight = 0.05

-- --- Stands: menu labels + layout geometry ---
Bases.Stands = {}
--[[
	Bases.Stands
	===========
	Single source of truth for stand / slot-menu PRESENTATION tunables:
	menu labels, amount formatting, level text, and UI animation timing.

	WHAT THIS CONTROLS
	------------------
	How the per-stand menu and direct-upgrade readout look. The RULES
	(animal = UpgradeButton + full MenuGui; egg = no action button;
	empty = no action button) are STRUCTURAL and stay code-owned in
	SlotMenuService / StandDisplayService / SlotMenuController — there
	is no designer use case for "eggs get an Upgrade button", and
	making it a loose setting would invite broken states.

	Server authoritative: NO (display only). The server computes
	upgrade costs and sell totals; this module formats them.
]]

-- --- Menu labels -----------------------------------------------------------------

Bases.Stands.Labels = {
	-- Direct-upgrade button text on animal stands.
	-- CURRENT: 'Upgrade'.
	UpgradeButton = 'Upgrade',
	-- Shown when the upgrade endpoint is unavailable.
	-- CURRENT: 'Unavailable'.
	Unavailable = 'Unavailable',
	-- Shown at the level cap (NewLevel display).
	-- CURRENT: 'Max Level' / 'Max'.
	MaxLevel = 'Max Level',
	MaxLevelShort = 'Max',
	-- Sell button text. CURRENT: 'Sell <Name>' / legacy 'Sell Egg'
	-- (eggs are not sellable; the label survives for legacy paths).
	SellPrefix = 'Sell',
	-- Income rate suffix. CURRENT: '$<rate>/sec'.
	RateSuffix = '/sec',
	-- Missing-rate placeholder. CURRENT: 'N/A'.
	RateMissing = 'N/A',
	-- Egg stand occupant name. CURRENT: 'Egg'.
	EggName = 'Egg',
	-- Level format. CURRENT: 'Lv. %d' style via callers; the short
	-- prefix below is the shared piece.
	LevelPrefix = 'Lv. ',
}

-- --- Upgrade readout ------------------------------------------------------------------

Bases.Stands.UpgradeReadout = {
	-- Decimal places for the $/sec rate (trailing zeros trimmed).
	-- CURRENT: 2 ('%.2f' trimmed).
	RateDecimals = 2,
}

-- --- Stand amount label (world-space collector/stand readout) ------------------------------
-- Authored per stand at runtime (DynamicSlotService arena stands).
-- CURRENT: green (120, 220, 130), GothamBold, scaled, '$0' initial.

Bases.Stands.AmountLabel = {
	TextColor = Color3.fromRGB(120, 220, 130),
	Font = Enum.Font.GothamBold,
	InitialText = '$0',
}

function Bases.ValidateStands(): { string }
	local issues: { string } = {}
	for _, key in ipairs({ 'UpgradeButton', 'Unavailable', 'MaxLevel', 'SellPrefix', 'EggName' }) do
		local v = (Bases.Stands.Labels :: any)[key]
		if type(v) ~= 'string' or v == '' then
			issues[#issues + 1] = 'Labels.' .. key .. ' must be a non-empty string'
		end
	end
	return issues
end

Bases.Layout = {}
--[[
	Bases.Layout
	=================
	PHYSICAL arrangement of stands. This controls WHERE stands go —
	RebirthConfig controls HOW MANY are unlocked. Never the reverse.

	FILE: src/ReplicatedStorage/Config/Bases.Layout.lua
	(This file — everything tunable about stand layout is here.)

	All positions are Base-LOCAL (offsets from the Base's Center
	part). The game transforms them through Center.CFrame, so
	rotated bases rotate their whole layout with them.
	No world-space coordinates anywhere in this file.

	------------------------------------------------------------------
	ANIMAL RING (normal stands)
	------------------------------------------------------------------
	Stands form an ellipse around the Base Center. The total count
	splits into a RIGHT arc and a mirrored LEFT arc on the same
	ellipse (odd counts put the extra stand on the right).

	-- RadiusX ------------------------------------------------------
	-- WHAT: horizontal size of the ellipse, in studs (X axis).
	-- BIGGER number  -> ring gets WIDER (stands spread left/right).
	-- SMALLER number -> ring gets NARROWER (stands bunch up).
	-- Example: 50 = stands sit ~50 studs left/right of Center.

	-- RadiusZ ------------------------------------------------------
	-- WHAT: depth size of the ellipse, in studs (Z axis).
	-- BIGGER number  -> ring gets DEEPER (front/back spread out).
	-- SMALLER number -> ring gets FLATTER (stands line up more).
	-- TIP: RadiusX ~= RadiusZ gives a circle; make Z smaller than
	-- X for a wide shallow arc, larger for a deep one.

	-- RightStartAngle / RightEndAngle ------------------------------
	-- WHAT: where the RIGHT-side arc begins and ends, in DEGREES.
	-- 0° = straight along +X. Negative angles go toward -Z,
	-- positive angles go toward +Z (same side).
	-- -45 to +45  -> tight cluster on the right side (current).
	-- WIDER range (e.g. -80 to +80) -> arc wraps further around,
	--   stands spread toward front AND back.
	-- NARROWER range (e.g. -20 to +20) -> stands bunch in a
	--   short row on the right side.
	-- The LEFT side automatically mirrors whatever you set here
	-- (180° - angle), so both sides always stay symmetric.
	-- Single stand  -> placed at the arc midpoint automatically.

	-- FaceCenter ---------------------------------------------------
	-- WHAT: true = every stand rotates (yaw only, never tilts) to
	-- face the Center. false is currently unused (stands always
	-- face Center) — flip only if a custom facing is ever added.

	------------------------------------------------------------------
	ARENA ROW
	------------------------------------------------------------------
	Arena stands form their own straight row, SEPARATE from the
	animal ring (never part of the arc).

	-- Z ------------------------------------------------------------
	-- WHAT: how far BEHIND the Center the row sits, in studs
	-- (Center-local -Z direction). More negative = further back.
	-- Example: -60 = row floats 60 studs behind Center.
	-- NOTE: sign matters — positive Z would put it in FRONT.

	-- Spacing ------------------------------------------------------
	-- WHAT: gap between neighboring Arena stands, in studs.
	-- BIGGER number -> stands spread apart.
	-- SMALLER number -> stands bunch together.
	-- The row is always centered (1 stand = middle, 2 = symmetric
	-- pair, 3+ = centered row), so spacing only affects width.

	-- FaceCenter ---------------------------------------------------
	-- Same as animal: stands yaw to face the Center, never tilt.

	------------------------------------------------------------------
	HEIGHT (ground Y)
	------------------------------------------------------------------
	There is NO height value in this file on purpose: ground Y
	always comes from Center.Position.Y (the transparent Center
	part you placed at the real ground center). To raise/lower
	the whole layout, move the Center part in Studio — never add
	a Y offset here.

	------------------------------------------------------------------
	COUNT (how many stands)
	------------------------------------------------------------------
	NOT in this file either: counts come from
	RebirthConfig (Stands = { Animal, Arena } per Rebirth, plus
	InitialStands for Rebirth 0). This file only arranges
	however many are unlocked.
]]

Bases.Layout.Animal = {
	RadiusX = 30,
	RadiusZ = 30,
	RightStartAngle = -45,
	RightEndAngle = 45,
	-- ForwardOffset: shifts the ENTIRE animal circle (as one unit)
	-- in Center-local +Z. The arena row sits at local -Z, so +Z
	-- moves the ring away from it (toward the base front). Use a
	-- negative value to shift toward the arena instead. Stands
	-- still face the shifted circle center; radius/arc untouched.
	ForwardOffset = 0,
	FaceCenter = true,
}

Bases.Layout.Arena = {
	Z = -25,
	Spacing = 10,
	FaceCenter = true,
}

function Bases.ValidateLayout(): { string }
	local issues: { string } = {}
	local function num(path: string, v: any, min: number?)
		if type(v) ~= 'number' or v ~= v then
			issues[#issues + 1] = path .. ' must be a number'
		elseif min ~= nil and v < min then
			issues[#issues + 1] = path .. ' must be >= ' .. tostring(min)
		end
	end
	num('Animal.RadiusX', Bases.Layout.Animal.RadiusX, 0)
	num('Animal.RadiusZ', Bases.Layout.Animal.RadiusZ, 0)
	num('Animal.RightStartAngle', Bases.Layout.Animal.RightStartAngle)
	num('Animal.RightEndAngle', Bases.Layout.Animal.RightEndAngle)
	num('Animal.ForwardOffset', Bases.Layout.Animal.ForwardOffset)
	num('Arena.Z', Bases.Layout.Arena.Z)
	num('Arena.Spacing', Bases.Layout.Arena.Spacing, 0)
	return issues
end

-- Aggregate validator: base + stands + layout (former per-module Validates).
function Bases.Validate(): { string }
	local issues: { string } = {}
	for _, issue in ipairs(Bases.ValidateBase()) do
		issues[#issues + 1] = issue
	end
	for _, issue in ipairs(Bases.ValidateStands()) do
		issues[#issues + 1] = issue
	end
	for _, issue in ipairs(Bases.ValidateLayout()) do
		issues[#issues + 1] = issue
	end
	return issues
end

table.freeze(Bases.Server)
table.freeze(Bases.Slots)
table.freeze(Bases.Collector)
table.freeze(Bases.Collector.Feel)
table.freeze(Bases.MoneyPool)
table.freeze(Bases.Spawn)
table.freeze(Bases.Lock)
table.freeze(Bases.Stands)
table.freeze(Bases.Layout)

return table.freeze(Bases)
