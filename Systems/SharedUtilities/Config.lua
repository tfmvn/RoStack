--!strict
--[[
	SharedUtilities — consolidated tunables (REFERENCE MODULE)

	=====================================================================
	THIS FILE IS DOCUMENTATION, NOT LIVE CONFIGURATION.
	=====================================================================

		This system has FIVE live config modules, and they all ship
		inside the system's own `Source/` tree, at their original
		Roblox paths:

			ReplicatedStorage/Config/Systems/Debug.lua
			ReplicatedStorage/Config/World/Movement.lua
			ReplicatedStorage/Config/Presentation/Audio.lua
			ReplicatedStorage/Config/Presentation/UI.lua
			ReplicatedStorage/Config/Presentation/Vfx.lua

		TO CHANGE A VALUE: edit the corresponding file above.
		Editing this file changes nothing at runtime.

		Why this file exists: the five configs cover ~700 lines
		across five domains. This file is the single-screen answer
		to "what can I tune, and what breaks if I change it?" —
		every tunable is listed below with its default, meaning,
		valid range, safety, and which module reads it.

		CONFIG ARCHITECTURE
		-------------------
		Every config domain in this project is registered with the
		central validator (`ReusableSystems/Shared/Utilities/
		ConfigValidator.lua`) as one entry, and each exposes
		`Validate(): { string }` — an empty array means clean.

		The five domains of this system are registered as:
			World.Movement            (Path = World/Movement)
			World.Movement.Player     (Path = World/Movement, Sub = Player)
			Systems.Debug             (Path = Systems/Debug)
			Presentation.Audio        (Path = Presentation/Audio)
			Presentation.Vfx          (Path = Presentation/Vfx)
			Presentation.UI.Overhead  (Path = Presentation/UI, Sub = Overhead)

		Note the asymmetry: `Presentation.UI` has TWO sub-domains
		with rules. `UI.Notify` has **no** `Validate()` — the
		validator's contract exempts presentation-only domains
		without rules, and `UI.Notify` is one of them. `UI` (the
		root) has no `Validate()` either.
]]

local Config = {}

-- =====================================================================
-- 1. Systems.Debug
--    Live file: ReplicatedStorage/Config/Systems/Debug.lua
--    Reads:    the shared `Debug` module (via Debug.SyncFromDebugConfig)
-- =====================================================================

--[[
	ServerDebug

		Default:  false
		Meaning:  The master switch for SERVER-side diagnostic
		          output. `Debug.Log` / `Debug.Warn` on the server
		          print only when this is true.
		Range:    boolean.
		Safe to change:  YES. This is a developer switch, not a
		          gameplay tunable. It is entirely independent of
		          `ClientDebug` — flipping one never enables the
		          other.
		Read by:  Debug.SyncFromDebugConfig -> Debug.IsEnabled
		Placeholder:  NO
]]
Config.SERVER_DEBUG = false

--[[
	ClientDebug

		Default:  false
		Meaning:  The master switch for CLIENT-side diagnostic
		          output. The client bootstrap syncs it the same
		          way the server bootstrap does.
		Range:    boolean.
		Safe to change:  YES.
		Read by:  the client bootstrap -> Debug.SyncFromDebugConfig
		Placeholder:  NO
]]
Config.CLIENT_DEBUG = false

--[[
	Tags

		Default:  {}  (empty = all enabled tags print)
		Meaning:  An optional per-tag WHITELIST. When non-empty,
		          only tags present in the table print. The
		          whitelist is applied **only when the table is
		          non-empty** — `next(AllowedTags) ~= nil`.
		Range:    a table of `tag = true`.
		Safe to change:  YES.
		Read by:  Debug.IsEnabled
		Placeholder:  NO
]]
Config.TAGS = {}

--[[
	Tags used by THIS system

		Values:  'LUCK', 'Settings', 'IN', 'MI', 'Water'
		Meaning:  The debug tags this system's modules log under.
		          If you use a non-empty `Tags` whitelist, these
		          are the tags you need.
		Note:    the `Tags` comment in the live file lists only
		          the older tags ('BS', 'LB', 'BR', 'PS', 'RM',
		          'CL', 'AO', 'CP'). The five above are NOT in
		          that list — the comment is out of date.
		Read by:  Debug.IsEnabled
]]
Config.TAGS_THIS_SYSTEM = { 'LUCK', 'Settings', 'IN', 'MI', 'Water' }

--[[
	DrawPaths

		Default:  false
		Meaning:  When true, computed pathfinder paths are drawn
		          in the world as neon-green parts and lines.
		          Studio diagnosis only.
		Range:    boolean.
		Safe to change:  YES. It creates real Instances in the
		          Workspace, so leave it off in production.
		Read by:  Debug.DrawPaths / Debug.DrawPath / Debug.DrawLine
		Placeholder:  NO
]]
Config.DRAW_PATHS = false

--[[
	SkipPersistence

		Default:  false
		Meaning:  When true, `PlayerService.LoadPlayerData` bypasses
		          ProfileService and seeds a deterministic
		          in-memory profile. Studio only.
		Range:    boolean.
		Safe to change:  **CAREFUL.** Turning this on in a live
		          server means nothing is ever saved. The live file
		          does NOT gate it on `IsStudio()` — the gate
		          lives in `PlayerService`. Do not ship it true.
		Read by:  PlayerService.LoadPlayerData
		Placeholder:  NO
]]
Config.SKIP_PERSISTENCE = false

--[[
	AllowStudioTestUserIds

		Default:  true
		Meaning:  Whether Studio multi-instance test UserIds
		          (0, -1, -2, ...) are accepted alongside normal
		          positive ids.
		Range:    boolean.
		Safe to change:  YES — and it is harmless at publish time
		          because `StudioTestMode.IsEnabled()` ALSO
		          requires `RunService:IsStudio()`. A published
		          server rejects 0/negatives even with this flag
		          left on.
		Read by:  the bootstrap (`StudioTestMode.Enabled =
		          DebugConfig.AllowStudioTestUserIds == true`) and
		          `Validation.IsValidPlayerUserId`
		Placeholder:  NO
]]
Config.ALLOW_STUDIO_TEST_USER_IDS = true

--[[
	Subsystem (per-subsystem verbose flags)

		Default:  every flag false —
		          Arena, Combat, Rewards, Overhead, Prompts,
		          BaseLock, LevelUp, Performance, ArenaHitClient
		Meaning:  Per-subsystem verbosity switches. Each maps to
		          an existing verbose log site.
		Range:    booleans.
		Safe to change:  YES.
		Read by:  the subsystems' own `Debug.IsEnabled` checks
		          (they read the flag directly, not through a tag)
		Placeholder:  NO
]]
Config.SUBSYSTEM = {
	Arena = false,
	Combat = false,
	Rewards = false,
	Overhead = false,
	Prompts = false,
	BaseLock = false,
	LevelUp = false,
	Performance = false,
	ArenaHitClient = false,
}

--[[
	ConfigValidation

		Default:  true
		Meaning:  When true, the bootstrap runs
		          `ConfigValidator.AssertValid()` at boot. In
		          Studio a validation failure is a HARD ERROR
		          (the bootstrap re-raises it). On a live server
		          it is only a `warn` — a bad tune must never
		          hard-crash production.
		Range:    boolean.
		Safe to change:  YES, but leave it on in development. With
		          it off, a bad tune surfaces as a mysterious nil
		          much later.
		Read by:  the bootstrap (line 44)
		Placeholder:  NO
]]
Config.CONFIG_VALIDATION = true

--[[
	Audio.Enabled

		Default:  false
		Meaning:  Whether the audio systems emit verbose debug
		          logs. The field was added explicitly so the
		          intended default is discoverable — readers
		          previously compared `Debug.Audio == true`
		          against a missing field, which behaved as
		          `false` by accident.
		Range:    boolean.
		Safe to change:  YES.
		Read by:  the audio systems
		Placeholder:  NO
]]
Config.AUDIO_ENABLED = false

-- =====================================================================
-- 2. World.Movement
--    Live file: ReplicatedStorage/Config/World/Movement.lua
--    Reads:    PathfindingUtil, WalkController, FlightController,
--              StandPresentation, the player-movement bootstrap
-- =====================================================================

--[[
	YawSmoothing

		Default:  8.0
		Meaning:  The critically-damped yaw turn rate, applied as
		          `1 - exp(-8.0 * dt)`. Converges in roughly 0.4 s
		          without oscillating. It was duplicated as a
		          literal `8.0` in three places (WalkController,
		          FlightController, PathfindingUtil) and is now
		          single-sourced here.
		Range:    > 0 (the validator requires a number > 0).
		Safe to change:  YES, but retune it in ONE place only —
		          this file. Higher = snappier turn.
		Read by:  PathfindingUtil.YawSmoothing (assigned at
		          require time), WalkController, FlightController
		Placeholder:  NO
]]
Config.YAW_SMOOTHING = 8.0

--[[
	AnimalWalk.AnimationBaseSpeed

		Default:  10
		Meaning:  The movement speed the walk animation was
		          authored against. Playback scales by
		          `actualSpeed / AnimationBaseSpeed`, so 10 matches
		          `AnimalConfig.MovementSpeed` exactly (1.0x at
		          cruise).
		Range:    > 0.
		Safe to change:  **with care** — if `AnimalConfig.MovementSpeed`
		          is retuned, retune this together or the leg
		          cadence drifts from the travel rate.
		Read by:  WalkController
		Placeholder:  NO
]]
Config.ANIMAL_WALK_ANIMATION_BASE_SPEED = 10

--[[
	AnimalWalk.WallClockPadding

		Default:  2  (seconds)
		Meaning:  A safety cap on the deterministic walk. It only
		          fires if the Heartbeat connection itself is lost.
		Range:    seconds, >= 0.
		Safe to change:  YES. A safety bound, not a feel knob.
		Read by:  WalkController
		Placeholder:  NO
]]
Config.ANIMAL_WALK_WALL_CLOCK_PADDING = 2

--[[
	EggFlight.MaxClimbAboveStart

		Default:  2  (studs)
		Meaning:  A safety rail — a navmesh spike can never lift
		          an egg more than this above its launch ground.
		Range:    >= 0.
		Safe to change:  YES. A safety bound.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_MAX_CLIMB_ABOVE_START = 2

--[[
	EggFlight.WalkSizeDivisor / WalkSizeMin / WalkSizeMax

		Default:  4, 0.7, 1.25
		Meaning:  The hop scaler from model height:
		          `clamp(h / Divisor, Min, Max)`.
		Range:    Divisor > 0; Min <= Max.
		Safe to change:  YES, but keep Min <= Max or the clamp
		          inverts.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_WALK_SIZE = { Divisor = 4, Min = 0.7, Max = 1.25 }

--[[
	EggFlight.SpeedEmaKeep / SpeedEmaGain

		Default:  0.9 / 0.1
		Meaning:  The speed exponential moving average:
		          `keep * old + gain * instantaneous`.
		Range:    both >= 0; they normally sum to 1.
		Safe to change:  YES. If they stop summing to 1 the EMA
		          changes character (it becomes a leaky filter).
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_SPEED_EMA = { Keep = 0.9, Gain = 0.1 }

--[[
	EggFlight.SettleThreshold / SettleRate

		Default:  0.93 / 8
		Meaning:  The last 7% of a flight settles the blend at
		          `SettleRate`, so the arrival lands at rest
		          instead of oscillating.
		Range:    Threshold in [0, 1]; Rate > 0.
		Safe to change:  YES.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_SETTLE = { Threshold = 0.93, Rate = 8 }

--[[
	EggFlight.SampleInterval

		Default:  0.25  (a fraction of the flight)
		Meaning:  The travel-debug sample cadence. A fraction of
		          the whole flight, not seconds.
		Range:    a fraction in (0, 1].
		Safe to change:  YES. It is a DIAGNOSTIC cadence — the
		          debug path colour itself lives in
		          `Presentation.Vfx.Hygiene`.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_SAMPLE_INTERVAL = 0.25

--[[
	EggFlight agent parameters

		Default:  AgentRadius 3, AgentHeight 6,
		          AgentCanJump false, AgentCanClimb false,
		          WaypointSpacing 6
		Meaning:  The PathfindingService agent for egg flights.
		          The egg body is smaller than the animal body, so
		          these differ from `PathfindingUtil.AgentParams`
		          (4 / 5 / false / false / 6).
		Range:    as PathfindingService expects.
		Safe to change:  YES, but they must match the egg's real
		          size or the flight will clip or refuse to route.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_AGENT = {
	AgentRadius = 3,
	AgentHeight = 6,
	AgentCanJump = false,
	AgentCanClimb = false,
	WaypointSpacing = 6,
}

--[[
	EggFlight.FlightMaxTicks

		Default:  1800  (60 * 30)
		Meaning:  The Heartbeat tick cap per flight. A flight
		          running longer is considered stuck and is
		          force-stopped. At 60 Hz, 30 s = 1800 ticks.
		Range:    > 0.
		Safe to change:  YES. A safety bound — generous for
		          normal flights, tight for failures.
		Read by:  FlightController
		Placeholder:  NO
]]
Config.EGG_FLIGHT_MAX_TICKS = 1800

--[[
	StandIdle.TickRate

		Default:  30  (Hz)
		Meaning:  The whole-registry idle tick rate. The idle
		          motion itself is ~0.45 Hz, so 30 Hz sampling is
		          smooth while keeping replication bounded.
		Range:    > 0.
		Safe to change:  YES. Raising it increases replication
		          traffic for every stand in the game.
		Read by:  StandPresentation
		Placeholder:  NO
]]
Config.STAND_IDLE_TICK_RATE = 30

--[[
	StandIdle.PoseEpsilon / LeanEpsilon

		Default:  0.004 / 0.004
		Meaning:  The PivotTo deadband. The CFrame write is
		          skipped when neither the height nor the lean
		          moved enough to see (~1/3 of ticks near
		          extrema).
		Range:    >= 0.
		Safe to change:  YES. Raising it makes the idle stutter
		          visibly; lowering it burns replication for
		          nothing.
		Read by:  StandPresentation
		Placeholder:  NO
]]
Config.STAND_IDLE_EPSILON = { Pose = 0.004, Lean = 0.004 }

--[[
	Player.WalkSpeed

		Default:  20
		Meaning:  The default avatar walk speed.
		Range:    > 0.
		Safe to change:  YES.
		Read by:  the bootstrap (line 30 ->
		          `ReplicatedStorage.Config.World.Movement`.Player)
		Placeholder:  NO
		KNOWN BUG:  `Tests/ConfigArchitecture.spec.lua:183` asserts
		          `Movement.Player.WalkSpeed == 24`, but the live
		          config says `20` (the source comment even notes
		          "spec baseline; comment once said 16"). The spec
		          and the config disagree — the spec is stale.
		          See the SharedUtilities README, Known Limitations.
]]
Config.PLAYER_WALK_SPEED = 20

--[[
	Player.JumpPower

		Default:  50
		Meaning:  The default avatar jump power.
		Range:    >= 0.
		Safe to change:  YES.
		Read by:  the bootstrap (same line 30)
		Placeholder:  NO
]]
Config.PLAYER_JUMP_POWER = 50

-- =====================================================================
-- 3. Presentation.Audio
--    Live file: ReplicatedStorage/Config/Presentation/Audio.lua
--    Reads:    NotificationService, CollectFeedback, LevelUpPresentation,
--              StealService, ArenaPresentationConfig
-- =====================================================================

--[[
	Notification.SuccessCueName / ErrorCueName

		Default:  'Approved' / 'Error'
		Meaning:  The shared notification cues. Success entries
		          with `Sound = 'Approved'` play the first; warnings
		          play the second.
		Range:    non-empty asset names.
		Safe to change:  YES, but the assets must exist under
		          the replicated audio tree.
		Read by:  NotificationService
		Placeholder:  NO
]]
Config.AUDIO_NOTIFICATION = { SuccessCueName = 'Approved', ErrorCueName = 'Error' }

--[[
	StealAlertSoundName

		Default:  'Stealing'
		Meaning:  The source asset name for the steal-victim
		          alert. The authored Sound is CLONED into the
		          victim's PlayerGui.
		Range:    a non-empty string (the validator requires it).
		Safe to change:  YES, but the asset name must match.
		Read by:  StealService
		Placeholder:  NO
]]
Config.STEAL_ALERT_SOUND_NAME = 'Stealing'

--[[
	Collect.PoolSize

		Default:  4
		Meaning:  The per-player CashClaim SFX pool size, warmed
		          at join. A short sting with collections at most
		          ~1/s apart means 4 overlapping voices can never
		          exhaust; rapid legitimate claims overlap instead
		          of truncating. It is a FIXED bound — it never
		          grows and is never Debris-churned, so it replicates
		          once.
		Range:    >= 1 (the validator requires a number >= 1).
		Safe to change:  YES. Raise it if legitimate rapid
		          collecting audibly truncates.
		Read by:  CollectFeedback
		Placeholder:  NO
]]
Config.AUDIO_COLLECT_POOL_SIZE = 4

--[[
	LevelUp.VfxAssetName / SfxAssetName

		Default:  'Upgrade' / 'LevelUp'
		Meaning:  The level-up celebration asset names, resolved
		          under `ServerStorage.Assets.Vfx` / `Sfx`.
		Range:    asset names.
		Safe to change:  YES. `Presentation.Vfx.LevelUp` mirrors
		          these names — change both.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.AUDIO_LEVELUP = { VfxAssetName = 'Upgrade', SfxAssetName = 'LevelUp' }

--[[
	Arena.VfxRoot / SfxRoot / VfxAssetName / SfxSlotPrefix

		Default:  'Vfx' / 'Sfx' / 'Attack1' / 'Attack'
		Meaning:  The arena asset roots and the attack-slot naming
		          convention. The slots are `Attack1..Attack3` under
		          `ReplicatedStorage.Assets.Arena.Sfx`.
		Range:    asset names.
		Safe to change:  YES. The slot COUNT and cleanup live in
		          `ArenaPresentationConfig.Sfx`, which is canonical
		          for them.
		Read by:  the arena presentation code
		Placeholder:  NO
]]
Config.AUDIO_ARENA = {
	VfxRoot = 'Vfx',
	SfxRoot = 'Sfx',
	VfxAssetName = 'Attack1',
	SfxSlotPrefix = 'Attack',
}

-- =====================================================================
-- 4. Presentation.Vfx
--    Live file: ReplicatedStorage/Config/Presentation/Vfx.lua
--    Reads:    LevelUpPresentation, RollController, FlightController
-- =====================================================================

--[[
	LevelUp.Lifetime / CleanupCap

		Default:  2.0 / 1.2  (seconds)
		Meaning:  The fallback VFX cleanup delay and the cleanup
		          cap. The actual cleanup is
		          `task.delay(math.min(Lifetime, Cap), ...)`.
		          A lower cap = snappier cleanup; a higher cap
		          keeps long-tail particles, but never above
		          `Lifetime`'s intent.
		Range:    both > 0 (the validator requires it).
		Safe to change:  YES. Pure presentation.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_LIFETIME = { Lifetime = 2.0, CleanupCap = 1.2 }

--[[
	LevelUp.CloneCleanupPadding / CloneCleanupMin / CloneCleanupMaxPad

		Default:  0.75 / 1.0 / 1.0
		Meaning:  Clone debris: the longest emitter lifetime plus
		          `Padding`, clamped to
		          `[CloneMin, Lifetime + CloneMaxPad]`.
		Range:    Min <= Max; the clamp must not invert.
		Safe to change:  YES. Pure presentation.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_CLONE = { Padding = 0.75, Min = 1.0, MaxPad = 1.0 }

--[[
	LevelUp.BurstDefault / BurstMin / BurstMax

		Default:  2 / 1 / 4  (studs)
		Meaning:  The celebration rise height, clamped per-model
		          to `[BurstMin, BurstMax]` via
		          `extents * 0.5 + 0.5`.
		Range:    Min <= Max.
		Safe to change:  YES. Tuning the clamp changes the
		          per-species feel — preserve the relationship.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_BURST = { Default = 2, Min = 1, Max = 4 }

--[[
	LevelUp.ScaleEpsilon / ScaleMinInterval

		Default:  0.004 / 1/30
		Meaning:  The perf throttle: frames re-scale on a
		          meaningful change AND at most 30 times a second.
		Range:    epsilon >= 0; interval > 0.
		Safe to change:  **with care** — these are ALGORITHM
		          constants, regression-tested behaviour. The file
		          says so explicitly.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_SCALE = { Epsilon = 0.004, MinInterval = 1 / 30 }

--[[
	LevelUp.Bop (the celebration choreography)

		Default:
			GrowOverlap            = 0.6
			AnticipationDuration   = 0.10
			AnticipationSquash     = 0.94
			AnticipationDip        = 0.12
			LaunchDuration         = 0.16
			LaunchStretch          = 1.06
			ApexDuration           = 0.06
			FallDuration           = 0.18
			LandingDuration        = 0.08
			LandingSquash          = 0.95
			SettleDuration         = 0.10
		Meaning:  The bop choreography, total ~0.68 s — quick,
		          punchy, satisfying. The growth OVERLAPS the bop
		          instead of preceding it: the baseline scale eases
		          start->target over the first `GrowOverlap` seconds
		          while the squash/stretch multiplies around it.
		          The file notes there is deliberately **no** 0.45 s
		          "thinking pause" — `GrowOverlap` is 0.6.
		Range:    durations >= 0; scales > 0.
		Safe to change:  YES for feel, but the ORDER of the
		          phases is a contract with the animation.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_BOP = {
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
}

--[[
	LevelUp.Tilt

		Default:  Takeoff -2, Apex 2, Landing -1  (degrees, Z axis,
		          relative to rest)
		Meaning:  The micro-tilt personality of the celebration.
		Range:    any number of degrees.
		Safe to change:  YES. Pure presentation.
		Read by:  LevelUpPresentation
		Placeholder:  NO
]]
Config.VFX_LEVELUP_TILT = { Takeoff = -2, Apex = 2, Landing = -1 }

--[[
	EggRoll.PlaceholderSize / RevealSize

		Default:  (1,1,1) / (2,2,2)
		Meaning:  The placeholder and reveal sizes for the egg
		          roll animation.
		Range:    positive Vector3s.
		Safe to change:  YES.
		Read by:  RollController
		Placeholder:  NO
]]
Config.VFX_EGGROLL_SIZES = {
	PlaceholderSize = Vector3.new(1, 1, 1),
	RevealSize = Vector3.new(2, 2, 2),
}

--[[
	EggRoll fallback colours

		Default:  FallbackColor (200,200,200),
		          FallbackText (255,255,255),
		          FallbackStroke (0,0,0),
		          SilhouetteText (0,0,0),
		          SilhouetteStroke (255,255,255)
		Meaning:  Presentation fallbacks used when a rarity colour
		          lookup fails. The silhouette pair is black-on-black
		          concealment.
		Range:    Color3s.
		Safe to change:  YES.
		Read by:  RollController
		Placeholder:  NO
]]
Config.VFX_EGGROLL_COLORS = {
	FallbackColor = Color3.fromRGB(200, 200, 200),
	FallbackText = Color3.fromRGB(255, 255, 255),
	FallbackStroke = Color3.fromRGB(0, 0, 0),
	SilhouetteText = Color3.fromRGB(0, 0, 0),
	SilhouetteStroke = Color3.fromRGB(255, 255, 255),
}

--[[
	EggRoll burst + cleanup

		Default:  BurstDefault 2, BurstMin 1, BurstMax 4,
		          Lifetime 2.0, CleanupCap 1.2
		Meaning:  The same celebration-rise contract as LevelUp,
		          plus the cleanup cap.
		Range:    as LevelUp.
		Safe to change:  YES.
		Read by:  RollController
		Placeholder:  NO
]]
Config.VFX_EGGROLL = {
	BurstDefault = 2,
	BurstMin = 1,
	BurstMax = 4,
	Lifetime = 2.0,
	CleanupCap = 1.2,
}

--[[
	Hygiene.DebugPathColor / DebugPathColorAlt / DebugMarkerSize / DebugMarkerLift

		Default:  (128,200,255) / (80,160,220) / 0.4 / 0.25
		Meaning:  The egg-flight debug path colour, the alternate
		          colour, the debug waypoint marker size and its
		          lift. DIAGNOSTIC ONLY — these never appear in a
		          production path.
		Range:    Color3s; sizes > 0.
		Safe to change:  YES.
		Read by:  FlightController (debug drawing)
		Placeholder:  NO
]]
Config.VFX_HYGIENE = {
	DebugPathColor = Color3.fromRGB(128, 200, 255),
	DebugPathColorAlt = Color3.fromRGB(80, 160, 220),
	DebugMarkerSize = 0.4,
	DebugMarkerLift = 0.25,
}

-- =====================================================================
-- 5. Presentation.UI
--    Live file: ReplicatedStorage/Config/Presentation/UI.lua
--    Reads:    the client HUD + toast controllers
-- =====================================================================

--[[
	RarityColor

		Default:  `Rarity.RarityColor` (read from
		          `ReplicatedStorage.Config.Creatures.Rarity`)
		Meaning:  The rarity colour table. The UI config READS it
		          from the rarity config — it never duplicates it.
		Range:    a table of rarity -> Color3.
		Safe to change:  NO — edit `Creatures/Rarity.lua` instead.
		          This is an alias, not a copy.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.RARITY_COLOR_SOURCE = 'ReplicatedStorage.Config.Creatures.Rarity.RarityColor'

--[[
	Font tokens

		Default:  Heading = GothamBold, Body = GothamMedium,
		          Number = GothamBold
		Meaning:  The central font choices, so the same face is
		          used everywhere.
		Range:    Enum.Font values.
		Safe to change:  YES. Pure presentation.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.FONT = {
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Number = Enum.Font.GothamBold,
}

--[[
	TextSize tokens

		Default:  H1 28, H2 22, Body 16, Small 13
		Meaning:  The central text-size scale.
		Range:    > 0.
		Safe to change:  YES. Pure presentation.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.TEXT_SIZE = { H1 = 28, H2 = 22, Body = 16, Small = 13 }

--[[
	Color tokens

		Default:  Background (20,20,30), Panel (35,35,50),
		          PanelBorder (80,80,100), Text (240,240,250),
		          TextMuted (180,180,200), Accent (120,200,255),
		          Success (100,220,130), Warning (255,200,80),
		          Error (255,90,90)
		Meaning:  The background and accent palette.
		Range:    Color3s.
		Safe to change:  YES. Pure presentation.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.COLOR = {
	Background = Color3.fromRGB(20, 20, 30),
	Panel = Color3.fromRGB(35, 35, 50),
	PanelBorder = Color3.fromRGB(80, 80, 100),
	Text = Color3.fromRGB(240, 240, 250),
	TextMuted = Color3.fromRGB(180, 180, 200),
	Accent = Color3.fromRGB(120, 200, 255),
	Success = Color3.fromRGB(100, 220, 130),
	Warning = Color3.fromRGB(255, 200, 80),
	Error = Color3.fromRGB(255, 90, 90),
}

--[[
	HUD layout

		Default:  Anchor (0,0), Position (16,16),
		          Size (280,200), Padding 8
		Meaning:  The HUD layout — top-left, fixed size, padded.
		Range:    UDim2/UDim2 offsets; padding >= 0.
		Safe to change:  YES. Pure presentation.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.HUD = {
	Anchor = Vector2.new(0, 0),
	Position = UDim2.fromOffset(16, 16),
	Size = UDim2.fromOffset(280, 200),
	Padding = 8,
}

--[[
	SlotRow sizing

		Default:  Width 248, Height 28, Gap 4
		Meaning:  The slot row sizing inside the HUD. Note that
		          `248 + 16 (HUD padding * 2) == 280` — the row
		          width is derived from the HUD width, so change
		          them together.
		Range:    > 0.
		Safe to change:  YES, but keep the row inside the HUD.
		Read by:  the HUD controllers
		Placeholder:  NO
]]
Config.SLOT_ROW = { Width = 248, Height = 28, Gap = 4 }

--[[
	Toast sizing

		Default:  Width 320, Height 56, MaxVisible 3, StackGap 6,
		          Anchor (1,1), StackOrigin UDim2.new(1,-16,1,-16)
		Meaning:  The toast (notification) sizing and stacking.
		          The anchor is BOTTOM-RIGHT.
		Range:    MaxVisible >= 1.
		Safe to change:  YES. Pure presentation.
		Read by:  the ToastController
		Placeholder:  NO
]]
Config.TOAST = {
	Width = 320,
	Height = 56,
	MaxVisible = 3,
	StackGap = 6,
	Anchor = Vector2.new(1, 1),
	StackOrigin = UDim2.new(1, -16, 1, -16),
}

--[[
	Notify.DefaultDuration

		Default:  4  (seconds)
		Meaning:  How long a toast sits on screen before it
		          auto-dismisses.
		Range:    > 0.
		Safe to change:  YES.
		Read by:  the ToastController
		Placeholder:  NO
]]
Config.NOTIFY_DEFAULT_DURATION = 4

--[[
	Notify.CoalesceWindow

		Default:  1.5  (seconds)
		Meaning:  A new toast with the same `(Category, Text)`
		          arriving within this many seconds is COALESCED
		          into the existing one — its lifetime is extended
		          instead of stacking.
		Range:    >= 0.
		Safe to change:  YES. Set it to 0 to disable coalescing.
		Read by:  the ToastController
		Placeholder:  NO
]]
Config.NOTIFY_COALESCE_WINDOW = 1.5

--[[
	Notify.MaxTextLength

		Default:  120
		Meaning:  A hard cap on toast text length, so toasts do
		          not overflow. The architecture spec pins this
		          value and asserts the toast cap lives in
		          `UI.Notify` ONLY.
		Range:    > 0.
		Safe to change:  **with care** — `ConfigArchitecture.spec.lua`
		          asserts `UI.Notify.MaxTextLength == 120`. Changing
		          it breaks that spec.
		Read by:  the ToastController
		Placeholder:  NO
]]
Config.NOTIFY_MAX_TEXT_LENGTH = 120

--[[
	Notify.Category / CategoryColor

		Default:  System / Reward / Warning / Error with
		          (160,200,255) / (120,230,140) / (255,200,80) /
		          (255,90,90)
		Meaning:  The four toast categories. The server picks one
		          when calling Notify; the client uses it to choose
		          the accent colour.
		Range:    the four names are a CONTRACT — the server
		          sends these strings.
		Safe to change:  **with care** — renaming a category
		          breaks every server-side Notify call.
		Read by:  NotificationService (server), ToastController
		          (client)
		Placeholder:  NO
]]
Config.NOTIFY_CATEGORIES = { 'System', 'Reward', 'Warning', 'Error' }

--[[
	Notify.HudMotion

		Default:  DisplayDuration 2.0, EnterOffsetPx 64,
		          ExitOffsetPx 60, DropSeconds 0.25,
		          ExitSeconds 0.2, ExitCancelSeconds 0.18,
		          ExitCancelDelaySeconds 0.23,
		          RestoreBufferSeconds 0.05
		Meaning:  The HudNotificationController window motion — a
		          single ease in/out, no overshoot. Offsets are
		          Y-only pixels; durations are seconds. The two
		          `ExitCancel*` values are the interrupted-exit snap
		          back to resting. `RestoreBufferSeconds` is a
		          scheduling buffer after tween/restore delays, so
		          restores stay behind the tween that precedes them.
		Range:    offsets/durations >= 0.
		Safe to change:  YES. Pure presentation, but the BUFFER
		          ordering is a correctness property of the
		          animation — keep it positive.
		Read by:  HudNotificationController
		Placeholder:  NO
]]
Config.NOTIFY_HUD_MOTION = {
	DisplayDuration = 2.0,
	EnterOffsetPx = 64,
	ExitOffsetPx = 60,
	DropSeconds = 0.25,
	ExitSeconds = 0.2,
	ExitCancelSeconds = 0.18,
	ExitCancelDelaySeconds = 0.23,
	RestoreBufferSeconds = 0.05,
}

--[[
	Notify.ToastMotion

		Default:  EnterSeconds 0.12, ExitSeconds 0.15
		Meaning:  The ToastController enter/exit tweens (Quad Out).
		Range:    >= 0.
		Safe to change:  YES.
		Read by:  ToastController
		Placeholder:  NO
]]
Config.NOTIFY_TOAST_MOTION = { EnterSeconds = 0.12, ExitSeconds = 0.15 }

--[[
	Overhead.TraitColors

		Default:  Gold (245,200,70), Diamond (150,225,255)
		Meaning:  Trait presentation colours. Gold reuses the
		          canonical Legendary gold; Diamond is ice-cyan.
		          These live in the UI config because
		          `TraitConfig` carries MULTIPLIERS only — that is
		          the deliberate data-vs-style split.
		Range:    Color3s.
		Safe to change:  YES. Pure presentation.
		Read by:  the overhead billboards
		Placeholder:  NO
]]
Config.OVERHEAD_TRAIT_COLORS = {
	Gold = Color3.fromRGB(245, 200, 70),
	Diamond = Color3.fromRGB(150, 225, 255),
}

--[[
	Overhead.MutationColors

		Default:  Galactic (168,85,247), Frost (147,197,253)
		Meaning:  Mutation presentation colours. Same data-vs-style
		          split as traits: `MutationConfig` carries
		          multipliers only. Galactic reads cosmic purple;
		          Frost reads ice blue. Used by overhead-adjacent
		          text (the event mutation toasts) and available to
		          any future mutation-tinted UI.
		Range:    Color3s.
		Safe to change:  YES.
		Read by:  the overhead billboards, the event notification
		Placeholder:  NO
]]
Config.OVERHEAD_MUTATION_COLORS = {
	Galactic = Color3.fromRGB(168, 85, 247),
	Frost = Color3.fromRGB(147, 197, 253),
}

--[[
	Overhead.FallbackColor

		Default:  (255,255,255) — white
		Meaning:  The fallback when a rarity colour lookup fails.
		Range:    a Color3.
		Safe to change:  YES.
		Read by:  the overhead billboards
		Placeholder:  NO
]]
Config.OVERHEAD_FALLBACK_COLOR = Color3.fromRGB(255, 255, 255)

--[[
	Overhead.StolenTextColor

		Default:  (255,90,90) — the game's danger red
		Meaning:  The name colour of a stolen animal while it is
		          steal-carried. It matches
		          `RichTextFormatter.DangerHex` (#FF5A5A) so the
		          robbery copy and the overhead agree.
		Range:    a Color3.
		Safe to change:  **with care** — the architecture spec
		          asserts `UI.Overhead.StolenTextColor ==
		          Color3.fromRGB(255, 90, 90)`.
		Read by:  the overhead billboards
		Placeholder:  NO
]]
Config.OVERHEAD_STOLEN_TEXT_COLOR = Color3.fromRGB(255, 90, 90)

--[[
	Overhead.Rainbow.Period

		Default:  3  (seconds)
		Meaning:  The full rainbow cycle time. Lower = faster
		          shimmer, higher = a slow drift.
		Range:    > 0 (the validator requires a number > 0).
		Safe to change:  YES. The animation is ONE shared server
		          Heartbeat for every Rainbow overhead — never
		          per-animal. Change the period, not the sharing
		          mechanism.
		Read by:  the rainbow overhead controller
		Placeholder:  NO
]]
Config.OVERHEAD_RAINBOW_PERIOD = 3

--[[
	Overhead.Rainbow.Stops

		Default:  7 stops — red(0) -> orange(0.17) -> yellow(0.33)
		          -> green(0.5) -> blue(0.67) -> purple(0.83) ->
		          red(1)
		Meaning:  The gradient stops. The FIRST and LAST must be
		          the SAME colour so the wrap is seamless.
		Range:    a sorted list of `{ At = 0..1, Color = Color3 }`.
		Safe to change:  YES, but keep the first and last
		          identical or the animation will visibly pop.
		Read by:  the rainbow overhead controller
		Placeholder:  NO
]]
Config.OVERHEAD_RAINBOW_STOPS = {
	{ At = 0, Color = Color3.fromRGB(255, 0, 0) },
	{ At = 0.17, Color = Color3.fromRGB(255, 140, 0) },
	{ At = 0.33, Color = Color3.fromRGB(255, 235, 0) },
	{ At = 0.5, Color = Color3.fromRGB(0, 200, 80) },
	{ At = 0.67, Color = Color3.fromRGB(0, 140, 255) },
	{ At = 0.83, Color = Color3.fromRGB(150, 60, 255) },
	{ At = 1, Color = Color3.fromRGB(255, 0, 0) },
}

--[[
	Overhead.Rainbow.StrokeSaturation / StrokeValue

		Default:  0.9 / 1
		Meaning:  The UIStroke rainbow uses
		          `HSV(t, Saturation, Value)` per tick.
		Range:    0..1 each.
		Safe to change:  YES.
		Read by:  the rainbow overhead controller
		Placeholder:  NO
]]
Config.OVERHEAD_RAINBOW_STROKE = { Saturation = 0.9, Value = 1 }

-- =====================================================================
-- 6. Module-locals that are NOT in a config file
--
--    These are the tunables that live in the source modules
--    themselves. They are listed here so you know they exist.
-- =====================================================================

--[[
	ServerLuckService

		MAX_LUCK = 1000000
			The largest accepted luck multiplier. The overflow
			guard: weights scale as `luck^(5/3)` at the top tier,
			so 1e6 is already far beyond any sane value while
			keeping every intermediate in comfortable double
			range. Testing values like 10/100/1000/10000 all pass.
			`SetLuck` REJECTS anything above it (it does not clamp).
			Read by: ServerLuckService.SetLuck / ActivateBoost /
			         ApplyLuck.

		MAX_BOOST_DURATION_S = 86400  (24 hours)
			The longest boost the service will schedule. Durations
			come from `ShopConfig.ServerLuckDurations`; anything
			above this is rejected as a CONFIGURATION ERROR, not
			clamped. `ActivateBoost` requires `durationSecs >= 1`.
			Read by: ServerLuckService.ActivateBoost.

		DEFAULT_LUCK = 1
			The baseline. `luck = 1` is the IDENTITY of the
			weight transform — the canonical config weights are
			untouched at 1x.
			Read by: the whole service.

		ATTRIBUTE = 'ServerLuck'
			The ReplicatedStorage attribute the current luck is
			published to, on every change and once at Init.
			Clients read it and watch it with
			GetAttributeChangedSignal. It is the ONLY client-facing
			channel — the service adds no remotes.
			Read by: the client HUD.

		LUCK_POOL = Events.LuckPoolOrder
			The design pool order for the luck tiers:
			Common(0) … Mythic(5). It is NOT `Rarity.Order`
			(which canonically sorts Mythic below Legendary) —
			luck must favour Mythic most.
			Read by: ServerLuckService.ApplyLuck.

		`Rarity.LuckExponentDivisor` = 3
			The divisor in the curve `weight * luck^(tierIndex / 3)`.
			It lives in `Creatures/Rarity.lua`, not in this system.
			A degenerate value falls back to 3 inside ApplyLuck.
			Read by: ServerLuckService.ApplyLuck.
]]

--[[
	PathfindingUtil

		AgentParams = { AgentRadius 4, AgentHeight 5,
		                AgentCanJump false, AgentCanClimb false,
		                WaypointSpacing 6 }
			The animal pathfinder agent defaults. The animal model
			footprint is ~4x5x2 studs. `AgentRadius = 4` (was 2)
			matches the actual footprint — a 2-stud agent treats
			the animal as a thin pillar and routes it through gaps
			the model physically cannot fit through, and the walk
			visibly clips into walls. `AgentCanJump = false` (was
			true) because with jump enabled the pathfinder takes
			4-stud "jump" links to cross small Y gaps, producing
			sideways-then-up approaches. If a gap is
			non-traversable without a jump, the pathfinder should
			refuse and the walker falls through to its
			teleport-arrive path.
			Read by: Animal.WalkController.

		YawSmoothing
			Assigned AT REQUIRE TIME from
			`ReplicatedStorage.Config.World.Movement`.YawSmoothing.
			Tests may still override the field per case.
			Read by: the yaw helper.

		MaxWalkSeconds = 60
			BACKWARDS-COMPAT ONLY. The walker itself uses a
			duration-based cap now. Kept so external callers do
			not break.
			Read by: nothing in this codebase.

		ShortestAngleDelta(from, to)
			Not a tunable but the module's one helper — see
			API.md.
]]

--[[
	MoneyIcon / MutationIcon

		Neither has a config file. Both resolve their assets from
		the live instance tree, FRESH ON EVERY CALL, so
		retargeting an image in Studio takes effect on the next
		grant/paint with no code change.

		`Assets.Decals.MoneyIcon` (an ImageLabel) — the HUD
			cash-pooling icon. Read by: IncomeService, CodesService,
			DailyRewardsService.

		`Assets.Decals.GalaxyIcon` / `Assets.Decals.SnowfallIcon`
			(ImageLabels) — the canonical mutation-to-decal map:
			Galactic -> GalaxyIcon, Frost -> SnowfallIcon.
			Read by: EggOverhead, AnimalOverhead.
]]

--[[
	WaterHazard

		No config, no remotes, no state. One Touched connection per
		part, connected once at boot. `Workspace.Water` is
		Studio-authored; a BasePart gets one connection, a
		Model/Folder gets one per descendant BasePart.
]]

return table.freeze(Config)
