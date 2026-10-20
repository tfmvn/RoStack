--!strict
--[[
	BasesAndSlots — consolidated tunables
	=====================================
	Every tunable this system reads, in ONE module, with the SAME
	field paths as the source game's canonical config:

		ReplicatedStorage.Config.World.Bases

	which is the single source of truth in Brainrot Arena and is
	shipped verbatim in this library at
	`Source/ReplicatedStorage/Config/World/Bases.lua`.

	HOW TO USE THIS FILE
	--------------------
	Two options, pick one:

	1. KEEP THE ORIGINAL (recommended). Copy
	   `Source/ReplicatedStorage/Config/World/Bases.lua` to
	   `ReplicatedStorage.Config.World.Bases` in your place and edit
	   it there. Every `require` in this system already points at
	   that path, and nothing else changes.

	2. USE THIS FILE. Copy it to `ReplicatedStorage.Config.World.Bases`
	   instead. It is a **structural drop-in**: the same field paths,
	   the same values, the same four `Validate*` functions. The only
	   differences are (a) the per-field documentation, and (b) the
	   `Layout` / `Stands` / `Collector.Feel` / `MoneyPool` sections
	   are included here even though this system does not read them
	   all, because other systems in the same game require the same
	   module. If you use this file standalone, you can delete the
	   sections marked "NOT READ BY THIS SYSTEM".

	NO CREDENTIALS
	--------------
	There is no API key, token, webhook URL or other secret in this
	file, and this system needs none. If you later add an
	integration to the base lock, keep the secret OUT of the repo
	(Studio-only `Secret` module or a server-side environment
	mechanism) and document a placeholder here.

	FIELDS THAT ARE DEAD IN THE SOURCE GAME
	---------------------------------------
	`Lock.LaserExtendSeconds` (0.4), `Lock.LaserRetractSeconds` (0.3)
	and `Lock.LaserStaggerSeconds` (0.025) are defined in the source
	config but read by NO module: `Base/LaserAnimation.lua` applies
	the laser pose INSTANTLY (no TweenService, no stagger, no waits).
	They are reproduced below, marked DEAD, so this file stays a
	faithful mirror — but do not tune them expecting an effect.

	`Collector.AmountTextColor` is read by nothing outside the
	validator. It is kept for fidelity.
]]

local Bases = {}

-- ---------------------------------------------------------------------------
-- Server sizing
-- ---------------------------------------------------------------------------

Bases.Server = {
	-- Default: 5
	-- Meaning: the server refuses further joins once this many players
	--   are present.
	-- Valid range: 1..100 (any positive integer).
	-- Safe to change: yes — a plain capacity gate.
	-- Read by: the bootstrap's server-full check. NOT read by any module
	--   in this library.
	-- Placeholder: no.
	MaxPlayers = 5,
}

-- ---------------------------------------------------------------------------
-- Base count
-- ---------------------------------------------------------------------------

-- Default: 8
-- Meaning: how many `Base_<i>` folders the server registers. MUST match
--   the authored map — the server creates a missing `Base_<i>` folder as
--   an empty Folder and then FATALS on it (no Collector).
-- Valid range: 1..99 (BaseType.BuildId asserts 1..99).
-- Safe to change: yes, but you must author the same number of bases in
--   Studio, each with a Collector.
-- Read by: BaseService.RegisterBases (the loop bound).
-- Placeholder: no.
Bases.Count = 8

-- ---------------------------------------------------------------------------
-- Slot pool
-- ---------------------------------------------------------------------------

Bases.Slots = {
	-- Default: 8
	-- Meaning: the maximum number of slots a base can hold. Eggs and
	--   animals SHARE one pool. Also the hard cap applied to the
	--   dynamic (StandPos) slot count:
	--   `GetDesiredSlotCount` returns `min(unlocked.Animal, Count)`.
	-- Valid range: 1..99 (SlotType.BuildId asserts slot index 1..99).
	-- Safe to change: yes, but it changes persistence semantics —
	--   persisted slot ids are `p7:<userId>:slot:<index>`, so raising
	--   the count is safe while lowering it can strand records.
	-- Read by: BaseService.RegisterBases (legacy path), BaseService.Snapshot
	--   (defensive fallback), DynamicSlotService.GetDesiredSlotCount.
	-- Placeholder: no.
	Count = 8,

	-- Default: Vector3.new(3.5, 0.6, 3.5)
	-- Meaning: the dimensions of a slot part the server creates when the
	--   Studio map has no authored `Slots/Slot<n>`.
	-- Valid range: any positive Vector3.
	-- Safe to change: yes — LEGACY path only. Authored slots keep their
	--   Studio size.
	-- Read by: BaseService (the legacy `Slots` branch only).
	-- Placeholder: no.
	Size = Vector3.new(3.5, 0.6, 3.5),

	-- Default: 8 points on a circle of radius 12, all at Y = 2.
	-- Meaning: where the server places auto-created legacy slot parts.
	-- Valid range: any number of Vector3s; the source fills exactly
	--   `Count` of them in a `do` block.
	-- Safe to change: yes — legacy path only. In the DYNAMIC (StandPos)
	--   path the real layout comes from `Layout` below, and these
	--   offsets are only copied onto the record as `slot.offset`
	--   (documentation, NOT placement).
	-- Read by: BaseService (legacy path and the stand-index records),
	--   DynamicSlotService.buildRecord.
	-- Placeholder: no.
	Offsets = {},
}

do
	local count = Bases.Slots.Count
	for i = 1, count do
		local angle = ((i - 1) / count) * math.pi * 2
		Bases.Slots.Offsets[i] = Vector3.new(math.cos(angle) * 12, 2, math.sin(angle) * 12)
	end
end

-- ---------------------------------------------------------------------------
-- Collector (dev-default cash trigger)
-- ---------------------------------------------------------------------------

Bases.Collector = {
	-- Default: Color3.fromRGB(85, 255, 127)
	-- Meaning: the neon tint of the auto-created touch volume.
	-- Valid range: any Color3.
	-- Safe to change: yes — LEGACY path only.
	-- Read by: BaseService._ensureCashCollector.
	-- Placeholder: no.
	PartColor = Color3.fromRGB(85, 255, 127),

	-- Default: 4
	-- Meaning: the vertical size of the auto-created touch volume on a
	--   legacy `Slot<n>` part. Authored collectors are never resized.
	-- Valid range: > 0.
	-- Safe to change: yes — LEGACY path only.
	-- Read by: BaseService._ensureCashCollector.
	-- Placeholder: no.
	Height = 4,

	-- Default: 0.6
	-- Meaning: how see-through the auto-created touch volume is.
	-- Valid range: 0..1.
	-- Safe to change: yes — LEGACY path only.
	-- Read by: BaseService._ensureCashCollector.
	-- Placeholder: no.
	Transparency = 0.6,

	-- Default: Color3.fromRGB(120, 220, 130)
	-- Meaning: the stand amount label colour.
	-- Valid range: any Color3.
	-- Safe to change: irrelevant.
	-- Read by: NOTHING except the `ValidateBase()` type check below.
	--   The live stand amount label uses `Stands.AmountLabel.TextColor`.
	-- Placeholder: no.
	AmountTextColor = Color3.fromRGB(120, 220, 130),

	-- Floating money-pool chip (the client fallback when no icon asset
	-- is configured).
	-- Read by: the client's MoneyPoolController, NOT by this system.
	-- Safe to change: yes, if you also carry the client HUD.
	-- Placeholder: no.
	PoolChip = {
		TextColor = Color3.fromRGB(85, 255, 127),
		Background = Color3.fromRGB(20, 60, 30),
		Font = Enum.Font.GothamBold,
		TextSize = 22,
	},
}

-- NOT READ BY THIS SYSTEM. Read by `Base/CollectFeedback.lua` (a
-- different system): the collector button press travel + VFX cleanup
-- feel. Included so this file stays a faithful mirror of the source
-- config.
Bases.Collector.Feel = {
	-- Default: 0.45
	-- Meaning: the fraction of the button's travel the press animation
	--   uses.
	-- Valid range: > 0.
	-- Safe to change: yes.
	-- Read by: `Base/CollectFeedback.lua`. NOT this system.
	-- Placeholder: no.
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

-- ---------------------------------------------------------------------------
-- Spawn
-- ---------------------------------------------------------------------------

Bases.Spawn = {
	-- Default: 4
	-- Meaning: how far above the base spawn CFrame the character is
	--   lifted on join/respawn.
	-- Valid range: >= 0.
	-- Safe to change: yes.
	-- Read by: the bootstrap. NOT by any module in this library.
	-- Placeholder: no.
	JoinLiftStuds = 4,
}

-- ---------------------------------------------------------------------------
-- Money pool (client HUD widget feel)
-- ---------------------------------------------------------------------------

-- NOT READ BY THIS SYSTEM. Read by the client's
-- `StarterPlayerScripts/MoneyPoolController.lua` — the icon spray, the
-- counter roll, and the arrival flight. The pool AMOUNT stays
-- server-authoritative (IncomeService). Included for fidelity.
Bases.MoneyPool = {
	IconBasePx = 34,
	IconMin = 6,
	IconTier2 = 10,
	IconTier3 = 16,
	IconMax = 24,
	ActiveIconCap = 20,
	NumberSteps = 12,
	NumberSeconds = 0.45,
	BopPeak = 1.12,
	BopPeakDense = 1.18,
	BopUpSeconds = 0.08,
	BopDownSeconds = 0.12,
	ArrivalWindow = 0.3,
	DenseThreshold = 3,
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

-- ---------------------------------------------------------------------------
-- Lock (server-authoritative base locking)
-- ---------------------------------------------------------------------------

Bases.Lock = {}
--[[
	Bases.Lock
	==============
	Tunables for the server-authoritative Base Locking system
	(`Base/BaseLockService`). The lock is runtime-only state —
	nothing here is persisted.
]]

-- Default: 60
-- Meaning: how long one owner button-press locks the base, in seconds.
--   `BaseLockService.Lock` sets `expiresAt = os.clock() + this`.
--   The single Heartbeat loop unlocks when the remaining time reaches 0.
-- Valid range: > 0 (any positive number of seconds).
-- Safe to change: yes. This value is ALSO the number painted on the
--   timer label, so the label and the timer can never disagree.
-- Read by: BaseLockService.Lock, BaseLockService.HandleButtonTouched
--   (the toast payload), BaseLockService._update (via `expiresAt`).
-- Placeholder: no.
--
-- NOTE: the source game's `Tests/BaseLockTimer.spec.lua:99` asserts this
-- equals 30, while the shipped config says 60. The spec is STALE — the
-- config is the live value.
Bases.Lock.LockDurationSeconds = 60

-- Default: 1
-- Meaning: per-button server-side debounce, in seconds. A `Touched` on
--   the lock button within this window of the last handled press is
--   ignored, so one physical contact cannot stack timers.
-- Valid range: >= 0.
-- Safe to change: yes.
-- Read by: BaseLockService.HandleButtonTouched.
-- Placeholder: no.
Bases.Lock.ButtonDebounceSeconds = 1

-- Default: false
-- Meaning: when true, an owner press while the base is ALREADY locked
--   restarts the duration (still ONE timer per base, never stacked).
--   When false, presses during an active lock are ignored: once locked,
--   the base cannot be relocked until the timer hits 0 and the lock
--   expires on its own.
-- Valid range: true / false.
-- Safe to change: yes — pure behaviour toggle, no persistence.
-- Read by: BaseLockService.Lock.
-- Placeholder: no.
Bases.Lock.RefreshOnPress = false

-- --- Laser barrier (presentation-only) -------------------------------

-- The physical lasers (Parts named exactly "Part" under
-- `LazerDoor.Lazers`) grow from the ground on lock and retract on
-- unlock. Pure presentation: collision/group behaviour stays in
-- `BaseLockService._applyGeometry`, which this never touches.
--
-- DEAD VALUES. `Base/LaserAnimation.lua` now applies the final pose
-- INSTANTLY — no TweenService, no stagger, no waits. The three
-- durations below are read by NOTHING. They are reproduced here, marked
-- DEAD, so this file stays a faithful mirror of the source config.
-- Changing them has NO effect.
-- Read by: nobody.
-- Safe to change: irrelevant (dead).
-- Placeholder: no.
Bases.Lock.LaserExtendSeconds = 0.4 -- DEAD
Bases.Lock.LaserRetractSeconds = 0.3 -- DEAD
Bases.Lock.LaserStaggerSeconds = 0.025 -- DEAD

-- Default: 0.05
-- Meaning: the retracted (unlocked) height of the laser, in studs. The
--   pose is bottom-anchored — the laser's ground point never moves, so
--   the laser grows out of the floor rather than scaling about its
--   centre.
-- Valid range: > 0 (0 is clamped away by `math.max`).
-- Safe to change: yes — but keep it small; a visible slab of laser at
--   the ground reads as a bug.
-- Read by: LaserAnimation._poseFor, LaserAnimation.Register,
--   LaserAnimation.Snap, LaserAnimation.SetLocked.
-- Placeholder: no.
Bases.Lock.LaserRetractedHeight = 0.05

-- ---------------------------------------------------------------------------
-- Stands
-- ---------------------------------------------------------------------------

Bases.Stands = {}
--[[
	Bases.Stands
	=================
	Menu labels, the upgrade readout, and the world-space amount
	label.

	HOW MANY stands exist is NOT decided here — that comes from
	`RebirthConfig` (`InitialStands` and `StandsFor(rebirth)`).
	This section only decides what they look like.
]]

-- NOT READ BY THIS SYSTEM. Read by `SlotMenuService` (a different
-- system). Included for fidelity.
Bases.Stands.Labels = {
	UpgradeButton = 'Upgrade',
	Unavailable = 'Unavailable',
	MaxLevel = 'Max Level',
	MaxLevelShort = 'Max',
	SellPrefix = 'Sell',
	RateSuffix = '/sec',
	RateMissing = 'N/A',
	EggName = 'Egg',
	LevelPrefix = 'Lv. ',
}

-- NOT READ BY THIS SYSTEM. Read by `SlotMenuService` (a different
-- system). Included for fidelity.
Bases.Stands.UpgradeReadout = {
	-- Default: 2
	-- Meaning: the decimal places for the $/sec rate (trailing zeros
	--   trimmed).
	-- Valid range: >= 0.
	-- Safe to change: yes.
	-- Read by: `SlotMenuService`. NOT this system.
	-- Placeholder: no.
	RateDecimals = 2,
}

-- The world-space stand amount label. Authored per stand at runtime by
-- `DynamicSlotService.EnsureArenaStandParts` when the arena stand
-- template does not provide one.
Bases.Stands.AmountLabel = {
	-- Default: Color3.fromRGB(120, 220, 130)
	-- Meaning: the text colour of the auto-created `SurfaceGui/Amount`
	--   TextLabel.
	-- Valid range: any Color3.
	-- Safe to change: yes — arena path only; authored labels are reused
	--   untouched.
	-- Read by: DynamicSlotService.EnsureArenaStandParts.
	-- Placeholder: no.
	TextColor = Color3.fromRGB(120, 220, 130),

	-- Default: Enum.Font.GothamBold
	-- Meaning: the font of the auto-created amount label.
	-- Valid range: any Font.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.EnsureArenaStandParts.
	-- Placeholder: no.
	Font = Enum.Font.GothamBold,

	-- Default: '$0'
	-- Meaning: the initial text of the auto-created amount label.
	-- Valid range: any string.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.EnsureArenaStandParts.
	-- Placeholder: no.
	InitialText = '$0',
}

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

Bases.Layout = {}
--[[
	Bases.Layout
	=================
	PHYSICAL arrangement of stands. This controls WHERE stands go —
	`RebirthConfig` controls HOW MANY are unlocked. Never the reverse.
]]

Bases.Layout.Animal = {
	-- Default: 30
	-- Meaning: the X radius of the animal stand ring, in studs
	--   (base-local). The horizontal half-width of the ellipse.
	-- Valid range: >= 0.
	-- Safe to change: yes — pure layout. Rotating the base rotates the
	--   whole layout with it (the ring is computed in the base's Center
	--   frame).
	-- Read by: DynamicSlotService.BuildBaseSlots.
	-- Placeholder: no.
	RadiusX = 30,

	-- Default: 30
	-- Meaning: the Z radius of the animal stand ring, in studs
	--   (base-local). Equal to RadiusX gives a circle.
	-- Valid range: >= 0.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildBaseSlots.
	-- Placeholder: no.
	RadiusZ = 30,

	-- Default: -45
	-- Meaning: the start angle of the RIGHT-hand arc, in degrees.
	--   0 degrees = straight along +X; negative goes toward -Z,
	--   positive toward +Z. The LEFT arc mirrors the right one
	--   automatically (180 - angle).
	-- Valid range: any number of degrees.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildBaseSlots -> StandLayout.AnimalLocals.
	-- Placeholder: no.
	RightStartAngle = -45,

	-- Default: 45
	-- Meaning: the end angle of the RIGHT-hand arc, in degrees. The
	--   right arc spans Start..End; a single stand is placed at the arc
	--   midpoint.
	-- Valid range: any number of degrees.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildBaseSlots -> StandLayout.AnimalLocals.
	-- Placeholder: no.
	RightEndAngle = 45,

	-- Default: 0
	-- Meaning: shifts the ENTIRE animal circle (as one unit) in
	--   Center-local +Z. The arena row sits at local -Z, so +Z moves the
	--   ring away from it (toward the base front). Use a negative value
	--   to shift toward the arena. The stands still face the shifted
	--   circle centre; radius/arc are untouched.
	-- Valid range: any number.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildBaseSlots.
	-- Placeholder: no.
	ForwardOffset = 0,

	-- Default: true
	-- Meaning: whether the stands turn to face the ring's centre.
	-- Valid range: true / false.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildBaseSlots.
	-- Placeholder: no.
	FaceCenter = true,
}

Bases.Layout.Arena = {
	-- Default: -25
	-- Meaning: the Z position of the arena stand row, in studs
	--   (base-local). How far BEHIND the base Centre the row sits. Sign
	--   matters — a positive value puts the row in FRONT.
	-- Valid range: any number.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildArenaStands -> StandLayout.ArenaLocals.
	-- Placeholder: no.
	Z = -25,

	-- Default: 10
	-- Meaning: the spacing between neighbouring arena stands, in studs.
	--   The row is always centred, so spacing only affects width.
	-- Valid range: >= 0.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildArenaStands -> StandLayout.ArenaLocals.
	-- Placeholder: no.
	Spacing = 10,

	-- Default: true
	-- Meaning: whether the arena stands turn to face the row's centre.
	-- Valid range: true / false.
	-- Safe to change: yes.
	-- Read by: DynamicSlotService.BuildArenaStands.
	-- Placeholder: no.
	FaceCenter = true,
}

-- ---------------------------------------------------------------------------
-- Validators
--
-- Copied VERBATIM from the source config so this file is a structural
-- drop-in. Each returns an array of error strings; an EMPTY array means
-- valid. The boot-time `ConfigValidator` turns a non-empty array into a
-- hard error in Studio and a warning on a live server.
-- ---------------------------------------------------------------------------

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
