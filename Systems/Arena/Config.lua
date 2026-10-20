--!strict
--[[
	ArenaConfig (consolidated)
	==========================
	ONE consolidated view of every tunable the Arena system reads,
	derived from the two canonical config modules that actually ship
	with the system:

	  * `ReplicatedStorage.Config.World.Arena`      -> `Arena`  (gameplay)
	  * `ReplicatedStorage.Config.World.ArenaFeel`  -> `ArenaFeel` (presentation)

	WHY THIS FILE EXISTS
	--------------------
	The Arena system genuinely HAS a config of its own (the two modules
	above). This file is a flat, copy-pasteable MIRROR of those
	tunables, written for a new game that wants to drop the system in
	and edit one file instead of hunting two.

	THIS IS A SNAPSHOT, NOT THE SOURCE OF TRUTH.
	--------------------------------------------
	At runtime the services `require` the two canonical modules
	directly (`ArenaService.lua:84-85`, `ArenaBattleService.lua:83`).
	Nothing requires THIS file. If you change a value here and the
	canonical module still has the old one, THE CANONICAL MODULE WINS
	and your change does nothing.

	To use this file for real:
	  1. Copy it to your game as `ReplicatedStorage.Config.World.Arena`
	     (or split it back into `Arena` + `ArenaFeel`).
	  2. Update the `require` paths if you rename the modules.
	  3. Keep `Validate()` reachable — `ArenaConfig.ValidateLive()` is
	     called by `ArenaService.Init()` and a broken catalog is a
	     boot-time warning, not a crash.

	Every value below is copied EXACTLY from the source. Nothing here
	is invented, rounded, or "improved". Where a value is a placeholder
	in the source (it exists so the system boots, not because it is
	balanced), the comment says so.

	UNITS: durations seconds; distances studs; colors Color3;
	transparency 0 (opaque)..1 (invisible); cash is a BigNumber
	decimal STRING (never a number).
]]

local Config = {}

-- =========================================================================
-- GAMEPLAY (from `ReplicatedStorage.Config.World.Arena`)
-- =========================================================================

-- --- Catalog shape -------------------------------------------------------

-- The number of stages in the catalog. In the source this is NOT a
-- literal: it is re-derived as `#LEVELS` (50 entries). Extending the
-- catalog array extends the raid automatically; nothing else to change.
--
-- Default: 50 (derived from the length of the LEVELS array).
-- Meaning: the last stage index; also the hard ceiling for
--          `ArenaProgressionService.Level` and `HighestCompleted`.
-- Valid range: 1..(length of the catalog).
-- Safe to change: YES, but only by adding/removing catalog entries.
--                 Never hardcode it — the source comment explicitly
--                 warns that a hardcoded cap "can never leave a stale
--                 hardcoded cap behind" (Arena.lua:74-76).
-- Read by: `ArenaService.startStageBattle` (via `MaxLevel()`),
--           `ArenaProgressionService.NormalizeArena` / `RecordReachedLevel`,
--           `ArenaService.BuildState`.
-- Placeholder: no.
Config.MaxLevel = 50

-- Minimum occupied ARENA slots required to start an expedition.
-- Default: 1
-- Meaning: `ResolveArenaTeam(...).count` must be >= this or the start
--          is rejected with `no-team` and the `Arena_NoTeam` warning.
-- Valid range: >= 1. Also must be <= MaxTeamSize.
-- Safe to change: YES — a designer knob, one value to balance.
-- Read by: `ArenaService.validateStart` (`team.count < MinTeamSize()`),
--           `ArenaService.BuildState` (`Loadout.MinTeam`).
-- Placeholder: no.
Config.MinTeamSize = 1

-- Maximum player combatants per battle.
-- Default: 3
-- Meaning: hard cap on the raid team. `StartArena` TRIMS the team to
--          the first N by ascending `ArenaIndex` and warns loudly; it
--          never silently reorders.
-- Valid range: >= MinTeamSize. Must be <= the number of authored
--          `Arena/PlayerSpawns/Position<N>` markers, or the battle
--          fails to spawn with `positions-not-ready`.
-- Safe to change: NO without also re-authoring the spawn markers.
--                 The source calls this a "hard cap, not a tuning knob"
--                 because arenas author exactly 3 PlayerSpawns.
-- Read by: `ArenaService.StartArena` (trim), `ArenaService.BuildState`.
-- Placeholder: no.
Config.MaxTeamSize = 3

-- --- Rewards -------------------------------------------------------------

-- Per-animal XP multiplier applied to the SETTLED raid XP total before
-- it is split across the raid team.
-- Default: 100
-- Meaning: `pool = floor(settledRaidXP * 100)`, then the pool is split
--          across the participants in proportion to damage dealt
--          (largest-remainder distribution; equal split when nobody
--          dealt damage). Applied EXACTLY ONCE, at the arena layer.
-- Valid range: >= 0 (number). Non-integers are floored.
-- Safe to change: YES — an event tuning knob. Change it here, nowhere
--                 else; the accumulator itself is unchanged (player
--                 Arena XP uses raw totals).
-- Read by: `ArenaService.terminateRaid` (via `AnimalXPMultiplier()`).
-- Placeholder: no.
Config.AnimalXPMultiplier = 100

-- Base attack cooldown between combatant attacks, in seconds.
-- Default: 1.5
-- Meaning: passed into `ArenaBattleService.CreateBattle` as the
--          battle `cooldown` and used to stamp `NextAttackAt`.
-- Valid range: > 0. Non-positive / NaN falls back to 1.5 inside
--          `CreateBattle`.
-- Safe to change: **with care** — see Known Limitations. Turn pacing
--                 is actually gated by `ArenaFeel.Combat.TurnInterval`
--                 (1.1s), NOT by this value. Changing this alone does
--                 NOT change the attack cadence; it only moves the
--                 diagnostic `NextAttackAt` stamp.
-- Read by: `ArenaService.startStageBattle` (`ArenaConfig.AttackCooldown()`).
-- Placeholder: no.
Config.AttackCooldown = 1.5

-- Paid-restart prices, BigNumber decimal STRINGS.
-- Charged atomically through `EconomyService.TrySpendMoney` with
-- `TransactionReason.ArenaRestart`.
-- Default: '25000' (warmup) / '150000' (direct)
-- Meaning: the price of `Buy1` (warmup restart) and `Buy2` (direct
--          restart). `Buy3` is always free at stage 1.
-- Valid range: a decimal string that parses to a positive finite
--          number. `BigNumber.sanitize` rejects '0'/invalid at settle
--          time.
-- Safe to change: YES — "single place to rebalance restart pricing".
-- Read by: `ArenaService.resolveRestartStart` (charge), and
--           `ArenaService.buildRestartInfo` (display).
-- Placeholder: no.
Config.RestartWarmupPrice = '25000'
Config.RestartDirectPrice = '150000'

-- --- Progression curve ----------------------------------------------------

-- Arena XP required to advance from a given player Arena level.
-- Formula: `floor(5 * 1.25 ^ (playerLevel - 1) + 0.5)` (round half up).
-- Default: 5 at level 1; 30 at level 9; 37 at level 10; 224208 at 49.
-- Meaning: the threshold on the SEPARATE arena XP track. Deliberately
--          NOT the animal 1.12 curve.
-- Valid range: playerLevel must be an integer >= 1 and < MaxLevel;
--          returns `nil` at or above MaxLevel (and for 0 / non-numbers).
-- Safe to change: NO — the whole track is calibrated against it. The
--                 source warns that flat 100-per-level "collapsed
--                 against exponential settles (one full clear capped
--                 the whole track)" and must not be linearized without
--                 re-solving the settle ratios.
-- Read by: `ArenaProgressionService.AddXPToData`,
--           `ArenaProgressionService.GetArenaState`.
-- Placeholder: no.
Config.XPRequired = {
	-- Coefficient of the exponential curve.
	Base = 5,
	-- Growth factor per level.
	Growth = 1.25,
	-- Maximum level the curve is defined for.
	MaxLevel = 50,
}

-- =========================================================================
-- PRESENTATION (from `ReplicatedStorage.Config.World.ArenaFeel`)
-- =========================================================================

-- --- Server combat motion -------------------------------------------------

-- Time the attacker spends travelling toward the target.
-- Default: 0.3
-- Meaning: duration of the travel tween toward the stop point.
-- Valid range: > 0.
-- Safe to change: YES — pure feel. Must stay > 0 or the tween collapses.
-- Read by: `ArenaBattleService.PresentAttack` (via
--           `ArenaFeel.Combat.TravelDuration`).
-- Placeholder: no.
Config.Combat = {
	TravelDuration = 0.3,

	-- Time to return to the canonical home transform.
	-- Default: 0.3
	-- Meaning: duration of the return tween after the hit.
	-- Valid range: > 0. Must stay > 0 or the return tween collapses.
	-- Safe to change: YES.
	-- Read by: `ArenaBattleService.PresentAttack`.
	-- Placeholder: no.
	ReturnDuration = 0.3,

	-- Emphasis beat frozen at impact.
	-- Default: 0.05
	-- Meaning: a `task.wait` at the contact moment. PRESENTATION ONLY:
	--          explicitly NOT sim time, never affects damage or
	--          scheduling.
	-- Valid range: >= 0.
	-- Safe to change: YES.
	-- Read by: `ArenaBattleService.PresentAttack`.
	-- Placeholder: no.
	HitStop = 0.05,

	-- Easing for the travel/return tweens.
	-- Default: 'Quad'
	-- Meaning: the intended easing name for the tween.
	-- Valid range: any `Enum.EasingStyle` name.
	-- Safe to change: **NO — it is never read.** `tweenModelTo` hardcodes
	--                 `Enum.EasingStyle.Quad` (ArenaBattleService.lua:1514).
	--                 Setting this to 'Sine' changes nothing.
	-- Read by: NOTHING at runtime. Documented in `ArenaFeel` only.
	-- Placeholder: yes — a documented-but-unwired field.
	EasingStyle = 'Quad',

	-- Centralized scheduler tick.
	-- Default: 0.25
	-- Meaning: ONE `RunService.Heartbeat` connection drives every active
	--          battle on the server at this cadence.
	-- Valid range: > 0.
	-- Safe to change: YES — but lowering it multiplies server wakeups
	--                 for every battle.
	-- Read by: `ArenaBattleService.ensureScheduler`.
	-- Placeholder: no.
	TickInterval = 0.25,

	-- Minimum gap between successive turns in one battle.
	-- Default: 1.1
	-- Meaning: the real attack cadence. Player side and enemy side
	--          alternate, Player first, at most one attack per turn.
	-- Valid range: > 0. Must comfortably contain
	--          TravelDuration + flourish + HitStop.
	-- Safe to change: YES — this is the knob that actually changes how
	--                 fast fights feel.
	-- Read by: `ArenaBattleService.TickBattle` (via `TURN_INTERVAL`).
	-- Placeholder: no.
	TurnInterval = 1.1,

	-- Hard clamp on deferred battle-model destruction.
	-- Default: 5
	-- Meaning: upper bound on the seconds a terminal path may defer
	--          battle-model teardown.
	-- Valid range: > 0.
	-- Safe to change: YES.
	-- Read by: `ArenaService.cleanupBattleModels`.
	-- Placeholder: no.
	ModelCleanupMaxDelay = 5,
}

-- --- Attack flourish choreography -----------------------------------------
--
-- Five in-place flourishes, run AT the stop point. Each entry pairs a
-- total duration with an impact offset (when HIT_CONTACT "lands" inside
-- the flourish). The per-flourish keyframes (lunge distances, hop
-- heights, spin steps) are CODE-OWNED in `ArenaBattleService`
-- (`animLunge` / `animHopSlam` / `animSpin` / `animSideSwing` /
-- `animBounceCharge`) — tuning one keyframe without its siblings
-- breaks the move.
--
-- ORDER MUST MATCH the server's anim table; the index is broadcast to
-- clients as `AttackIndex`.
--
-- Default: Lunge 0.28/0.16, HopSlam 0.32/0.22, Spin 0.32/0.24,
--          SideSwing 0.30/0.22, BounceCharge 0.32/0.20.
-- Valid range: Duration > 0; ImpactOffset >= 0 and <= Duration.
-- Safe to change: the DURATION and IMPACT_OFFSET are feel knobs and
--                 are safe. Changing the ORDER breaks the client
--                 animation index contract.
-- Read by: `ArenaBattleService.ATTACK_ANIMS` (Duration + ImpactOffset).
-- Placeholder: no.
Config.AttackAnims = {
	{ Name = 'Lunge', Duration = 0.28, ImpactOffset = 0.16 },
	{ Name = 'HopSlam', Duration = 0.32, ImpactOffset = 0.22 },
	{ Name = 'Spin', Duration = 0.32, ImpactOffset = 0.24 },
	{ Name = 'SideSwing', Duration = 0.3, ImpactOffset = 0.22 },
	{ Name = 'BounceCharge', Duration = 0.32, ImpactOffset = 0.2 },
}

-- --- Server hit flash ------------------------------------------------------

-- Three-phase cartoon impact on the victim model: white-hot flash,
-- then the red punch, then a fade back to transparent.
-- Default: see fields.
-- Valid range: transparencies 0..1; Duration > 0 and <= MaxDuration;
--          FlashDuration < Duration (enforced by `ArenaFeel.Validate`).
-- Safe to change: YES — pure colour feedback, no CFrame is touched.
-- Read by: `ArenaBattleService.flashHit`.
-- Placeholder: no.
Config.HitFlash = {
	-- Target hit flash colour. Default: red (255, 40, 40).
	Color = Color3.fromRGB(255, 40, 40),
	-- Starting transparency of the punch phase. Default: 0.35.
	StartTransparency = 0.35,
	-- Fade duration, seconds. Default: 0.18.
	Duration = 0.18,
	-- Hard clamp for Duration. Default: 2.
	MaxDuration = 2,
	-- Phase 1 impact flash colour. Default: white (255, 255, 255).
	FlashColor = Color3.fromRGB(255, 255, 255),
	-- Phase 1 impact flash peak transparency. Default: 0.05.
	FlashTransparency = 0.05,
	-- Phase 1 duration, seconds. Default: 0.05.
	FlashDuration = 0.05,
	-- Phase 2 outline punch peak transparency. Default: 0.1.
	OutlinePeakTransparency = 0.1,
}

-- --- Server attacker cue ----------------------------------------------------

-- Subtle warm rim on the ATTACKER so spectators can see who acted.
-- Default: (255, 240, 180), start transparency 0.8, duration 0.12s.
-- Valid range: transparency 0..1; Duration > 0.
-- Safe to change: YES.
-- Read by: `ArenaBattleService.announceAttacker`.
-- Placeholder: no.
Config.AttackerCue = {
	Color = Color3.fromRGB(255, 240, 180),
	StartTransparency = 0.8,
	Duration = 0.12,
}

-- --- Server hit jolt --------------------------------------------------------

-- Tiny positional punch on the victim (up + away from the attacker).
-- Default: lift 0.4, shove 0.5, out 0.08s, back 0.12s.
-- Valid range: studs >= 0; durations > 0.
-- Safe to change: YES.
-- Read by: `ArenaBattleService.reactToHit`.
-- Placeholder: no.
Config.HitJolt = {
	LiftStuds = 0.4,
	ShoveStuds = 0.5,
	OutDuration = 0.08,
	BackDuration = 0.12,
}

-- --- Server death fade --------------------------------------------------------

-- Staged transparency fade on a dying combatant.
-- Default: StepWait 0.08, Steps 3, MaxPreDelay 2.
-- Meaning: the model fades in `Steps` steps of `StepWait` seconds, then
--          is destroyed. `MaxPreDelay` clamps any caller-supplied
--          pre-fade delay to 0..2 seconds.
-- Valid range: Steps >= 1; StepWait >= 0; MaxPreDelay 0..2.
-- Safe to change: YES.
-- Read by: `ArenaBattleService.PresentDeath`.
-- Placeholder: no.
--
-- NOTE: the source comment for `DeathFade.Steps` says "CURRENT: 5" while
-- the actual value is 3 — the value is authoritative, the comment is
-- stale. `ArenaFeel.Validate` requires Steps >= 1.
Config.DeathFade = {
	StepWait = 0.08,
	Steps = 3,
	MaxPreDelay = 2,
}

-- --- Client-side presentation (owned by the ClientPresentation system) ------
--
-- The blocks below are read ONLY by client modules that live OUTSIDE
-- this system (`StarterPlayerScripts.ArenaHitPresentation`,
-- `ArenaCameraImpacts`, `ArenaController`, `ArenaResultController`).
-- They are copied here for completeness so a new game can see the whole
-- arena feel in one place, but the Arena server modules do not read
-- them.
--
-- Placeholder: no — but they are OUT OF SCOPE for the server system.

-- Damage-number popup (client). Default: 3x1 base size, 1.2 stud jitter,
-- 16 deg tilt, 2.6 -> 2.9 rise, 30 stud cull, 1s lifetime.
-- Read by: `ArenaHitPresentation` (ClientPresentation system).
Config.DamageNumber = {
	BaseSize = UDim2.fromScale(3, 1),
	JitterX = 1.2,
	TiltRange = 16,
	RiseStart = 2.6,
	RiseEnd = 2.9,
	MaxDistance = 30,
	Font = Enum.Font.SourceSansBold,
	TextColor = Color3.new(1, 1, 1),
	StrokeColor = Color3.new(0, 0, 0),
	TextStrokeTransparency = 0.3,
	StrokeThickness = 3,
	PopScale = 1.35,
	OvershootScale = 0.95,
	ExitScaleX = 1.1,
	ExitScaleY = 0.8,
	PopDuration = 0.08,
	SettleDuration = 0.1,
	ExitDuration = 0.08,
	Lifetime = 1,
}

-- Camera shake (client). Default: full range 15 studs, max range 30,
-- 0.28s impulse, 0.18 stud position clamp, 0.012 rad rotation clamp.
-- Read by: `ArenaCameraImpacts` (ClientPresentation system).
Config.CameraShake = {
	FullRange = 15,
	MaxRange = 30,
	Duration = 0.28,
	MaxPosition = 0.18,
	MaxRotation = 0.012,
}

-- Hit VFX (client). Asset key under `ReplicatedStorage.Assets.Vfx.HitVfx`.
-- Default: 'Attack1', 10-emitter fallback, cleanup [2, 8]s, 25 stud
-- target-match radius.
-- Read by: `ArenaHitPresentation` (ClientPresentation system).
Config.Vfx = {
	AssetName = 'Attack1',
	EmitFallback = 10,
	CleanupPadding = 1.5,
	MinCleanup = 2,
	MaxCleanup = 8,
	TargetMatchMaxDistance = 25,
	AnchorMargin = 0.5,
}

-- Hit SFX (client). Slots under `ReplicatedStorage.Assets.Arena.Sfx`.
-- Default: 3 slots prefixed 'Attack', cleanup +1s capped at 12s,
-- 3s fallback when the length is unknown.
-- NOTE: `SlotCount` IS also read on the SERVER
-- (`ArenaBattleService.PresentAttack` clamps `SoundIndex` to it), so
-- changing it without authoring the matching sound slots desyncs the
-- server's 1-2-3 sound cycle from the client's slot list.
-- Read by: `ArenaBattleService.PresentAttack` (SlotCount only) and
--           `ArenaHitPresentation` (the rest).
Config.Sfx = {
	SlotCount = 3,
	SlotPrefix = 'Attack',
	CleanupPadding = 1,
	MaxCleanup = 12,
	FallbackCleanup = 3,
}

-- Invisible per-hit anchor part (client).
-- Default: 1x1x1, 2s lifetime.
-- Read by: `ArenaHitPresentation` (ClientPresentation system).
Config.Anchor = {
	Size = Vector3.new(1, 1, 1),
	Lifetime = 2,
}

-- Code-built raid menu palette (client). No Studio template.
-- Default: background (24, 27, 34), panel (34, 39, 49), accent
-- (255, 190, 60), Gotham / GothamBold, 8px corner radius.
-- Read by: `ArenaController` (ClientPresentation system).
Config.Menu = {
	Background = Color3.fromRGB(24, 27, 34),
	Panel = Color3.fromRGB(34, 39, 49),
	Accent = Color3.fromRGB(255, 190, 60),
	Text = Color3.fromRGB(235, 238, 245),
	Dimmed = Color3.fromRGB(150, 158, 175),
	LockedBackground = Color3.fromRGB(28, 30, 37),
	Success = Color3.fromRGB(120, 220, 130),
	Defeated = Color3.fromRGB(255, 110, 110),
	StrokeColor = Color3.fromRGB(58, 65, 82),
	StrokeThickness = 1,
	StrokeTransparency = 0.4,
	StartTextColor = Color3.fromRGB(20, 22, 28),
	Font = Enum.Font.Gotham,
	FontBold = Enum.Font.GothamBold,
	CornerRadius = 8,
}

-- Temporary code-built Adventurer greeter (used only when no authored
-- `Base/Adventurer` or `Base/Adv` exists).
-- Default: 2x5x2 part, offset (6, 2.5, 0), 'Bright blue' brick, a
-- 120x40 GothamBold billboard, and a 5s START-button self-heal
-- backstop.
-- Valid range: Size components > 0.
-- Safe to change: YES — this is a stopgap. Author the real NPC instead.
-- Read by: `ArenaService.EnsureAdventurer`.
-- Placeholder: YES — explicitly a temporary placeholder in the source
--              ("replaced by Studio-authored content when present").
Config.AdventurerPlaceholder = {
	Size = Vector3.new(2, 5, 2),
	Offset = Vector3.new(6, 2.5, 0),
	BrickColorName = 'Bright blue',
	BillboardSize = UDim2.fromOffset(120, 40),
	BillboardOffset = Vector3.new(0, 3.5, 0),
	Font = Enum.Font.GothamBold,
	TextColor = Color3.fromRGB(255, 255, 255),
	TextStrokeTransparency = 0.4,
	StartButtonBackstop = 5,
}

-- --- Result card cap --------------------------------------------------------

-- Maximum combatant rows on the arena result card.
-- Default: 6
-- Meaning: the server truncates the rows to this cap AND the client
--          renders at most this many. One value, both sides.
-- Valid range: >= 1.
-- Safe to change: YES, but the client UI must be able to lay out that
--                 many cards.
-- Read by: `ArenaService.buildResultAnimals` (`RESULT_CARD_CAP`).
-- Placeholder: no.
Config.ResultCardCap = 6

-- --- Prompt tuning (from `ReplicatedStorage.Config.World.Prompts`) --------
--
-- The Adventurer prompt is the Arena's ONLY player-facing entry point.
-- The values live in the Carry system's `Config/World/Prompts.lua`
-- (the Carry system owns that config module), not here.
--
-- Default: 'Open Arena' / 'Adventurer' / hold 0s / 12 studs / no LOS.
-- Valid range: HoldDuration >= 0; MaxActivationDistance > 0.
-- Safe to change: YES — server re-validates every trigger anyway.
-- Read by: `ArenaService.ensurePrompt` (which creates the prompt).
-- Placeholder: no.
Config.Prompt = {
	ActionText = 'Open Arena',
	ObjectText = 'Adventurer',
	HoldDuration = 0,
	MaxActivationDistance = 12,
	RequiresLineOfSight = false,
}

-- =========================================================================
-- Validation
-- =========================================================================

--[[
	Return a list of issue strings. An empty list means valid.

	Contract (shared with every domain config in this library):
	  * Never error from Validate(). The caller decides severity.
	  * Name the exact field path in every message.
	  * Report the expectation AND the received value.
	  * Validate RANGES, not just types.
]]
function Config.Validate(): { string }
	local issues: { string } = {}
	local function num(path: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = ('%s must be a number >= %s (got %s)'):format(path, tostring(min), tostring(v))
		end
	end
	local function positive(path: string, v: any)
		if type(v) ~= 'number' or v ~= v or v <= 0 then
			issues[#issues + 1] = ('%s must be a number > 0 (got %s)'):format(path, tostring(v))
		end
	end
	local function cashString(path: string, v: any)
		local amount = if type(v) == 'string' then tonumber(v) else nil
		if type(v) ~= 'string' or v == '' or amount == nil or amount ~= amount or amount <= 0 then
			issues[#issues + 1] = ('%s must be a positive BigNumber decimal string (got %s)'):format(path, tostring(v))
		end
	end

	-- Gameplay.
	num('MaxLevel', Config.MaxLevel, 1)
	num('MinTeamSize', Config.MinTeamSize, 1)
	num('MaxTeamSize', Config.MaxTeamSize, 1)
	if Config.MinTeamSize > Config.MaxTeamSize then
		issues[#issues + 1] = 'MinTeamSize must be <= MaxTeamSize'
	end
	num('AnimalXPMultiplier', Config.AnimalXPMultiplier, 0)
	positive('AttackCooldown', Config.AttackCooldown)
	cashString('RestartWarmupPrice', Config.RestartWarmupPrice)
	cashString('RestartDirectPrice', Config.RestartDirectPrice)
	num('XPRequired.Base', Config.XPRequired.Base, 0)
	positive('XPRequired.Growth', Config.XPRequired.Growth)

	-- Combat motion.
	positive('Combat.TravelDuration', Config.Combat.TravelDuration)
	positive('Combat.ReturnDuration', Config.Combat.ReturnDuration)
	num('Combat.HitStop', Config.Combat.HitStop, 0)
	positive('Combat.TickInterval', Config.Combat.TickInterval)
	positive('Combat.TurnInterval', Config.Combat.TurnInterval)
	positive('Combat.ModelCleanupMaxDelay', Config.Combat.ModelCleanupMaxDelay)
	if type(Config.Combat.EasingStyle) ~= 'string' then
		issues[#issues + 1] = 'Combat.EasingStyle must be a string'
	end

	-- Attack animations.
	if #Config.AttackAnims ~= 5 then
		issues[#issues + 1] = ('AttackAnims must have exactly 5 entries (got %d)'):format(#Config.AttackAnims)
	end
	for i, anim in ipairs(Config.AttackAnims) do
		positive(('AttackAnims[%d].Duration'):format(i), anim.Duration)
		num(('AttackAnims[%d].ImpactOffset'):format(i), anim.ImpactOffset, 0)
		if type(anim.Name) ~= 'string' or anim.Name == '' then
			issues[#issues + 1] = ('AttackAnims[%d].Name must be a non-empty string'):format(i)
		end
	end

	-- Hit flash.
	num('HitFlash.StartTransparency', Config.HitFlash.StartTransparency, 0)
	positive('HitFlash.Duration', Config.HitFlash.Duration)
	positive('HitFlash.MaxDuration', Config.HitFlash.MaxDuration)
	num('HitFlash.FlashTransparency', Config.HitFlash.FlashTransparency, 0)
	num('HitFlash.FlashDuration', Config.HitFlash.FlashDuration, 0)
	num('HitFlash.OutlinePeakTransparency', Config.HitFlash.OutlinePeakTransparency, 0)
	if Config.HitFlash.FlashDuration >= Config.HitFlash.Duration then
		issues[#issues + 1] = 'HitFlash.FlashDuration must be < HitFlash.Duration'
	end
	if typeof(Config.HitFlash.Color) ~= 'Color3' then
		issues[#issues + 1] = 'HitFlash.Color must be a Color3'
	end
	if typeof(Config.HitFlash.FlashColor) ~= 'Color3' then
		issues[#issues + 1] = 'HitFlash.FlashColor must be a Color3'
	end

	-- Attacker cue / hit jolt.
	num('AttackerCue.StartTransparency', Config.AttackerCue.StartTransparency, 0)
	positive('AttackerCue.Duration', Config.AttackerCue.Duration)
	num('HitJolt.LiftStuds', Config.HitJolt.LiftStuds, 0)
	num('HitJolt.ShoveStuds', Config.HitJolt.ShoveStuds, 0)
	positive('HitJolt.OutDuration', Config.HitJolt.OutDuration)
	positive('HitJolt.BackDuration', Config.HitJolt.BackDuration)

	-- Death fade.
	num('DeathFade.StepWait', Config.DeathFade.StepWait, 0)
	num('DeathFade.Steps', Config.DeathFade.Steps, 1)
	num('DeathFade.MaxPreDelay', Config.DeathFade.MaxPreDelay, 0)

	-- Client presentation (validated here so a broken feel is caught
	-- even in a headless server boot).
	num('DamageNumber.JitterX', Config.DamageNumber.JitterX, 0)
	num('DamageNumber.TiltRange', Config.DamageNumber.TiltRange, 0)
	num('DamageNumber.MaxDistance', Config.DamageNumber.MaxDistance, 0)
	positive('DamageNumber.Lifetime', Config.DamageNumber.Lifetime)
	num('CameraShake.FullRange', Config.CameraShake.FullRange, 0)
	num('CameraShake.MaxRange', Config.CameraShake.MaxRange, 0)
	positive('CameraShake.Duration', Config.CameraShake.Duration)
	num('CameraShake.MaxPosition', Config.CameraShake.MaxPosition, 0)
	num('CameraShake.MaxRotation', Config.CameraShake.MaxRotation, 0)
	if Config.CameraShake.MaxRange < Config.CameraShake.FullRange then
		issues[#issues + 1] = 'CameraShake.MaxRange must be >= FullRange'
	end
	positive('Vfx.EmitFallback', Config.Vfx.EmitFallback)
	num('Vfx.CleanupPadding', Config.Vfx.CleanupPadding, 0)
	positive('Vfx.MinCleanup', Config.Vfx.MinCleanup)
	positive('Vfx.MaxCleanup', Config.Vfx.MaxCleanup)
	positive('Vfx.TargetMatchMaxDistance', Config.Vfx.TargetMatchMaxDistance)
	num('Vfx.AnchorMargin', Config.Vfx.AnchorMargin, 0)
	if Config.Vfx.MaxCleanup < Config.Vfx.MinCleanup then
		issues[#issues + 1] = 'Vfx.MaxCleanup must be >= MinCleanup'
	end
	positive('Sfx.SlotCount', Config.Sfx.SlotCount)
	num('Sfx.CleanupPadding', Config.Sfx.CleanupPadding, 0)
	positive('Sfx.MaxCleanup', Config.Sfx.MaxCleanup)
	positive('Sfx.FallbackCleanup', Config.Sfx.FallbackCleanup)
	positive('Anchor.Lifetime', Config.Anchor.Lifetime)

	-- Menu.
	if typeof(Config.Menu.Background) ~= 'Color3' then
		issues[#issues + 1] = 'Menu.Background must be a Color3'
	end
	num('Menu.StrokeThickness', Config.Menu.StrokeThickness, 0)

	-- Adventurer placeholder.
	if typeof(Config.AdventurerPlaceholder.Size) ~= 'Vector3' then
		issues[#issues + 1] = 'AdventurerPlaceholder.Size must be a Vector3'
	end
	positive('AdventurerPlaceholder.StartButtonBackstop', Config.AdventurerPlaceholder.StartButtonBackstop)

	-- Result card cap + prompt.
	num('ResultCardCap', Config.ResultCardCap, 1)
	num('Prompt.HoldDuration', Config.Prompt.HoldDuration, 0)
	positive('Prompt.MaxActivationDistance', Config.Prompt.MaxActivationDistance)

	return issues
end

-- Freeze the top level and the nested tables so a runtime bug cannot
-- mutate a tuning value mid-session.
for _, t in ipairs({
	Config,
	Config.XPRequired,
	Config.Combat,
	Config.HitFlash,
	Config.AttackerCue,
	Config.HitJolt,
	Config.DeathFade,
	Config.DamageNumber,
	Config.CameraShake,
	Config.Vfx,
	Config.Sfx,
	Config.Anchor,
	Config.Menu,
	Config.AdventurerPlaceholder,
	Config.Prompt,
}) do
	table.freeze(t)
end
for _, anim in ipairs(Config.AttackAnims) do
	table.freeze(anim)
end

return table.freeze(Config)
