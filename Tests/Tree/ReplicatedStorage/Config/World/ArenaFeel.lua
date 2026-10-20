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
	ArenaFeel
	=======================
	Single source of truth for every ARENA PRESENTATION tunable: combat
	motion timing, hit flash, damage numbers, camera shake, VFX/SFX
	asset keys + cleanup, death fades, and the placeholder Adventurer
	greeter's authored look.

	WHAT THIS CONTROLS
	------------------
	How arena fights LOOK and FEEL. Nothing here deals damage, moves
	authority, or pays rewards — the server sim (ArenaBattleService /
	ArenaService / ArenaConfig.AttackCooldown) stays authoritative and
	READS the timing section so motion matches feel.

	SPLIT OF RESPONSIBILITY
	-----------------------
	* Server reads: Combat.TravelDuration / ReturnDuration / HitStop,
	  HitFlash.*, AttackerCue.*, HitJolt.*, DeathFade.* — the sim plays
	  these on battle models AND broadcasts ArenaHit packets.
	* Client reads: DamageNumber.*, CameraShake.*, Vfx.*, Sfx.*,
	  Anchor.* — pure local presentation of the ArenaHit packet.
	* Either side: AdventurerPlaceholder.* (authored look of the
	  temporary code-built greeter; replaced by Studio-authored
	  content when present).

	All CURRENT values are copied exactly from the implementation
	(ArenaBattleService locals, ArenaHitPresentation locals,
	ArenaCameraImpacts locals, ArenaService greeter block). Tuning
	here rebalances feel only — never damage, never rewards.

	Units: durations seconds; distances studs; colors Color3;
	transparency 0 (opaque)..1 (invisible).
]]

local ArenaFeel = {}

-- --- Server combat motion ---------------------------------------------------

ArenaFeel.Combat = {
	-- Time the attacker spends traveling toward the target.
	-- Type: number. Unit: seconds. Required: yes. Valid: > 0.
	-- CURRENT: 0.3. Increase: heavier lunges. Decrease: snappier.
	TravelDuration = 0.3,
	-- Time to return to the canonical home transform.
	-- Type: number. Unit: seconds. Required: yes. Valid: > 0.
	-- CURRENT: 0.3. Must stay > 0 or the return tween collapses.
	ReturnDuration = 0.3,
	-- Emphasis beat frozen at impact (task.wait). Presentation-only:
	-- explicitly NOT sim time, never affects damage or scheduling.
	-- Type: number. Unit: seconds. Required: yes. Valid: >= 0.
	-- CURRENT: 0.05.
	HitStop = 0.05,
	-- Easing for travel/return tweens. Accepted: any Enum.EasingStyle
	-- name the sim can resolve; default 'Quad'. Direction 'InOut'.
	EasingStyle = 'Quad',
	-- Centralized scheduler tick: one cadence drives every active
	-- battle on the server. SIM timing (server authoritative).
	-- Type: number. Unit: seconds. Valid: > 0. CURRENT: 0.25.
	-- Decrease: more responsive turn dispatch, more wakeups.
	TickInterval = 0.25,
	-- Minimum gap between successive turns in one battle. SIM
	-- timing: gates attack order (Player/Enemy alternating).
	-- Type: number. Unit: seconds. Valid: > 0. CURRENT: 1.1.
	-- Must comfortably contain HitStop + flourish durations.
	TurnInterval = 1.1,
	-- Hard clamp on deferred battle-model destruction (ArenaService
	-- cleanupBattleModels). Gameplay cleanup: bounds the visual
	-- window after settle/cancel/leave. CURRENT: 5s.
	ModelCleanupMaxDelay = 5,
}

-- --- Attack flourish choreography --------------------------------------------------
-- Five in-place flourishes run AT the stop point (travel/return
-- tweens own the journey). Each entry: total flourish duration +
-- impact offset (when HIT_CONTACT lands inside the flourish).
-- The per-flourish pose keyframes (lunge distances, hop heights,
-- spin steps) are CHOREOGRAPHY — code-owned in
-- ArenaBattleService (animLunge/animHopSlam/animSpin/
-- animSideSwing/animBounceCharge) because tuning a single keyframe
-- without its siblings breaks the move; the total duration and
-- impact moment (the feel-relevant knobs) are tuned HERE.
-- Order MUST match the server's anim table (index = AttackIndex
-- broadcast to clients). CURRENT values preserved exactly.

ArenaFeel.AttackAnims = {
	{ Name = 'Lunge', Duration = 0.28, ImpactOffset = 0.16 },
	{ Name = 'HopSlam', Duration = 0.32, ImpactOffset = 0.22 },
	{ Name = 'Spin', Duration = 0.32, ImpactOffset = 0.24 },
	{ Name = 'SideSwing', Duration = 0.3, ImpactOffset = 0.22 },
	{ Name = 'BounceCharge', Duration = 0.32, ImpactOffset = 0.2 },
}

-- --- Server hit flash (Highlight on the victim model) ------------------------

ArenaFeel.HitFlash = {
	-- Target hit flash color. Type: Color3. Client-only visual.
	-- CURRENT: red (255, 40, 40).
	Color = Color3.fromRGB(255, 40, 40),
	-- Starting transparency of the flash. Type: number 0..1.
	-- CURRENT: 0.35. Lower = stronger flash.
	StartTransparency = 0.35,
	-- Fade duration. Type: number. Unit: seconds. Valid: > 0, max 2
	-- (the sim clamps longer values to 2s so flashes can't stick).
	-- CURRENT: 0.18.
	Duration = 0.18,
	-- Hard clamp for Duration. Code-owned safety; documented here so
	-- tuners know long values are clamped, not honored.
	MaxDuration = 2,
	-- Phase 1 impact flash color: near-white hot hit. Type: Color3.
	-- CURRENT: (255, 255, 255). Shown for FlashDuration, then the
	-- punch phase takes over in Color above. REQUIRED by the
	-- server flashHit (3-phase highlight) — do not remove.
	FlashColor = Color3.fromRGB(255, 255, 255),
	-- Phase 1 impact flash peak transparency. Type: number 0..1.
	-- CURRENT: 0.05 (almost opaque). Lower = hotter flash.
	FlashTransparency = 0.05,
	-- Phase 1 duration: white-hot impact slice. Type: number.
	-- Unit: seconds. Valid: >= 0, < Duration. CURRENT: 0.05.
	-- Keep tiny: 0.04..0.06 reads as WHAM, longer reads as
	-- "model turned white".
	FlashDuration = 0.05,
	-- Phase 2 outline punch peak transparency. Type: number 0..1.
	-- CURRENT: 0.1. The outline snaps to near-opaque on impact
	-- alongside the fill, then fades with it.
	OutlinePeakTransparency = 0.1,
}

-- --- Server attacker cue (warm tint on the attacker) ---------------------------

ArenaFeel.AttackerCue = {
	-- Subtle warm tint distinguishing "who attacked".
	-- CURRENT: (255, 240, 180).
	Color = Color3.fromRGB(255, 240, 180),
	-- CURRENT: 0.8. Fades over Duration below.
	StartTransparency = 0.8,
	-- CURRENT: 0.12s.
	Duration = 0.12,
}

-- --- Server hit jolt (tiny positional punch on the victim) -----------------------

ArenaFeel.HitJolt = {
	-- Upward lift applied at impact, in studs. CURRENT: 0.4.
	LiftStuds = 0.4,
	-- Horizontal shove away from the attacker, in studs. CURRENT: 0.5.
	ShoveStuds = 0.5,
	-- Out-tween duration (punch out). CURRENT: 0.08s.
	OutDuration = 0.08,
	-- Back-tween duration (settle). CURRENT: 0.12s.
	BackDuration = 0.12,
}

-- --- Server death fade ---------------------------------------------------------------

ArenaFeel.DeathFade = {
	-- Per-step wait between transparency steps. CURRENT: 0.08s x5.
	StepWait = 0.08,
	-- Number of fade steps. CURRENT: 5.
	Steps = 3,
	-- Clamp on any caller-supplied pre-fade delay. 0..2s.
	MaxPreDelay = 2,
}

-- --- Client damage number popup ----------------------------------------------------------

ArenaFeel.DamageNumber = {
	-- Base billboard size (scaled by the pop animation).
	-- CURRENT: UDim2.fromScale(3, 1).
	BaseSize = UDim2.fromScale(3, 1),
	-- Horizontal spawn jitter, in studs (±JitterX/2). CURRENT: 1.2.
	JitterX = 1.2,
	-- Tilt range in degrees (±TiltRange/2). CURRENT: 16.
	TiltRange = 16,
	-- Spawn height above the anchor, in studs. CURRENT: 2.6.
	RiseStart = 2.6,
	-- Height after the settle tween. CURRENT: 2.9.
	RiseEnd = 2.9,
	-- Cull distance. CURRENT: 30 studs.
	MaxDistance = 30,
	-- CURRENT: SourceSansBold, white text, black stroke.
	Font = Enum.Font.SourceSansBold,
	TextColor = Color3.new(1, 1, 1),
	StrokeColor = Color3.new(0, 0, 0),
	-- CURRENT: 0.3 text-stroke transparency, 3px UIStroke.
	TextStrokeTransparency = 0.3,
	StrokeThickness = 3,
	-- Pop 1.35x -> 0.95x -> 1.0, exit squash 1.1/0.8.
	PopScale = 1.35,
	OvershootScale = 0.95,
	ExitScaleX = 1.1,
	ExitScaleY = 0.8,
	-- Tween timings (Quad Out pop, linear settles). CURRENT:
	-- 0.08 pop, 0.1 rotate/rise/settle, 0.08 exit.
	PopDuration = 0.08,
	SettleDuration = 0.1,
	ExitDuration = 0.08,
	-- Total lifetime before Debris cleanup. CURRENT: 0.8s.
	Lifetime = 1,
}

-- --- Client camera shake --------------------------------------------------------------------

ArenaFeel.CameraShake = {
	-- 0-15 studs: full controlled micro shake. CURRENT: 15.
	FullRange = 15,
	-- 15-30: fading; 30+: no shake, no work. CURRENT: 30.
	MaxRange = 30,
	-- Impulse lifetime. CURRENT: 0.28s.
	Duration = 0.28,
	-- Position clamp, in studs. CURRENT: 0.18 ("BOOM, never earthquake").
	MaxPosition = 0.18,
	-- Rotation clamp, in radians. CURRENT: 0.012.
	MaxRotation = 0.012,
}

-- --- Client VFX / SFX --------------------------------------------------------------------------

ArenaFeel.Vfx = {
	-- Asset key under ReplicatedStorage.Assets.Vfx.HitVfx.
	-- The client clones the ENTIRE authored Attack1 hierarchy and
	-- Emit()s every ParticleEmitter recursively (EmitCount
	-- attribute else EmitFallback below).
	AssetName = 'Attack1',
	-- One-shot fallback emit count per emitter when the asset has
	-- no authored EmitCount attribute. Type: integer. Valid: >= 1.
	-- CURRENT: 10. Every emitter ALWAYS gets a positive Emit().
	-- REQUIRED by PlayArenaAttackVFX — do not remove.
	EmitFallback = 10,
	-- Debris cleanup: longest emitter lifetime + Padding, clamped
	-- to [MinCleanup, MaxCleanup]. CURRENT: +1.5s, [2, 8].
	-- Padding is the safety margin AFTER the longest authored
	-- particle dies (lets fade-out/size-out tails finish).
	-- Type: number. Unit: seconds. Recommended: 0.25..1.5.
	CleanupPadding = 1.5,
	MinCleanup = 2,
	MaxCleanup = 8,
	-- Target-part match radius: the cloned Attack1 parents to the
	-- nearest battle-model BasePart within this distance (studs)
	-- of the authoritative impact; farther (or no ArenaBattles)
	-- falls back to a temporary HitPoint at the impact.
	-- Type: number. Unit: studs. Valid: > 0. CURRENT: 25.
	TargetMatchMaxDistance = 25,
	-- Debris BACKUP margin for the fallback HitPoint (the primary
	-- cleanup is task.delay(vfxCleanup); the backup is longer so
	-- it can never win and curtail a playing burst). Type:
	-- number. Unit: seconds. CURRENT: 0.5.
	AnchorMargin = 0.5,
}

ArenaFeel.Sfx = {
	-- Sound slots under ReplicatedStorage.Assets.Arena.Sfx
	-- (Attack1..Attack3, cycled by the server's SoundIndex).
	-- Count MUST match the authored slots; the client clamps.
	SlotCount = 3,
	SlotPrefix = 'Attack',
	-- Cleanup: sound length + Padding, max MaxCleanup.
	-- CURRENT: +1s, max 12s. Fallback when length unknown: 3s.
	CleanupPadding = 1,
	MaxCleanup = 12,
	FallbackCleanup = 3,
}

-- --- Client anchor -------------------------------------------------------------------------------

ArenaFeel.Anchor = {
	-- Invisible per-hit anchor part size. CURRENT: 1x1x1.
	Size = Vector3.new(1, 1, 1),
	-- Debris lifetime for the anchor. CURRENT: 2s.
	Lifetime = 2,
}

-- --- Arena raid menu (client-built ScreenGui) -----------------------------------------------------------
-- The menu is code-built (no Studio template), so its palette,
-- fonts, and chrome live HERE — not in UIConfig, whose tokens
-- serve the HUD + Toast controllers. Values preserved exactly
-- from ArenaController's locals. Presentation only.

ArenaFeel.Menu = {
	Background = Color3.fromRGB(24, 27, 34),
	Panel = Color3.fromRGB(34, 39, 49),
	Accent = Color3.fromRGB(255, 190, 60),
	Text = Color3.fromRGB(235, 238, 245),
	Dimmed = Color3.fromRGB(150, 158, 175),
	LockedBackground = Color3.fromRGB(28, 30, 37),
	Success = Color3.fromRGB(120, 220, 130),
	Defeated = Color3.fromRGB(255, 110, 110),
	-- Chrome stroke. CURRENT: (58, 65, 82) / 1px / 0.4.
	StrokeColor = Color3.fromRGB(58, 65, 82),
	StrokeThickness = 1,
	StrokeTransparency = 0.4,
	-- Start-button label color. CURRENT: (20, 22, 28).
	StartTextColor = Color3.fromRGB(20, 22, 28),
	-- CURRENT: Gotham body / GothamBold headings (matches the
	-- menu's authored look; UIConfig.Body is GothamMedium, so
	-- these stay menu-owned rather than aliasing a token).
	Font = Enum.Font.Gotham,
	FontBold = Enum.Font.GothamBold,
	-- Corner radius default for style(). CURRENT: 8px.
	CornerRadius = 8,
}

-- --- Placeholder Adventurer greeter (code-built, temporary) -----------------------------------------
-- Only used when no Studio-authored Base/Adventurer exists.
-- Authored content takes precedence whenever present.

ArenaFeel.AdventurerPlaceholder = {
	-- CURRENT: 2x5x2, anchored, non-solid, +6x/+2.5y from spawn.
	Size = Vector3.new(2, 5, 2),
	Offset = Vector3.new(6, 2.5, 0),
	BrickColorName = 'Bright blue',
	-- Billboard label. CURRENT: 120x40, +3.5y, GothamBold white.
	BillboardSize = UDim2.fromOffset(120, 40),
	BillboardOffset = Vector3.new(0, 3.5, 0),
	Font = Enum.Font.GothamBold,
	TextColor = Color3.fromRGB(255, 255, 255),
	TextStrokeTransparency = 0.4,
	-- Start-button self-heal backstop (re-enables a stuck STARTING
	-- button). CURRENT: 5s. UX safety, not authority.
	StartButtonBackstop = 5,
}

-- --- Validation -------------------------------------------------------------------------------

function ArenaFeel.Validate(): { string }
	local issues: { string } = {}
	local function num(path: string, v: any, min: number)
		if type(v) ~= 'number' or v ~= v or v < min then
			issues[#issues + 1] = path .. ' must be a number >= ' .. tostring(min)
		end
	end
	num('Combat.TravelDuration', ArenaFeel.Combat.TravelDuration, 0.001)
	num('Combat.ReturnDuration', ArenaFeel.Combat.ReturnDuration, 0.001)
	num('Combat.HitStop', ArenaFeel.Combat.HitStop, 0)
	num('Combat.TickInterval', ArenaFeel.Combat.TickInterval, 0.001)
	num('Combat.TurnInterval', ArenaFeel.Combat.TurnInterval, 0.001)
	num('Combat.ModelCleanupMaxDelay', ArenaFeel.Combat.ModelCleanupMaxDelay, 0.001)
	num('HitFlash.StartTransparency', ArenaFeel.HitFlash.StartTransparency, 0)
	num('HitFlash.Duration', ArenaFeel.HitFlash.Duration, 0.001)
	num('HitFlash.FlashTransparency', ArenaFeel.HitFlash.FlashTransparency, 0)
	num('HitFlash.FlashDuration', ArenaFeel.HitFlash.FlashDuration, 0)
	num('HitFlash.OutlinePeakTransparency', ArenaFeel.HitFlash.OutlinePeakTransparency, 0)
	num('Vfx.CleanupPadding', ArenaFeel.Vfx.CleanupPadding, 0)
	num('Vfx.MinCleanup', ArenaFeel.Vfx.MinCleanup, 0.001)
	num('Vfx.MaxCleanup', ArenaFeel.Vfx.MaxCleanup, 0.001)
	num('Vfx.EmitFallback', ArenaFeel.Vfx.EmitFallback, 1)
	num('Vfx.TargetMatchMaxDistance', ArenaFeel.Vfx.TargetMatchMaxDistance, 0.001)
	num('Vfx.AnchorMargin', ArenaFeel.Vfx.AnchorMargin, 0)
	num('AttackerCue.Duration', ArenaFeel.AttackerCue.Duration, 0.001)
	num('HitJolt.OutDuration', ArenaFeel.HitJolt.OutDuration, 0.001)
	num('HitJolt.BackDuration', ArenaFeel.HitJolt.BackDuration, 0.001)
	num('DamageNumber.MaxDistance', ArenaFeel.DamageNumber.MaxDistance, 0)
	num('DamageNumber.Lifetime', ArenaFeel.DamageNumber.Lifetime, 0.001)
	num('CameraShake.FullRange', ArenaFeel.CameraShake.FullRange, 0)
	num('CameraShake.MaxRange', ArenaFeel.CameraShake.MaxRange, 0)
	num('CameraShake.Duration', ArenaFeel.CameraShake.Duration, 0.001)
	num('CameraShake.MaxPosition', ArenaFeel.CameraShake.MaxPosition, 0)
	num('CameraShake.MaxRotation', ArenaFeel.CameraShake.MaxRotation, 0)
	if ArenaFeel.CameraShake.MaxRange < ArenaFeel.CameraShake.FullRange then
		issues[#issues + 1] = 'CameraShake.MaxRange must be >= FullRange'
	end
	if typeof(ArenaFeel.HitFlash.Color) ~= 'Color3' then
		issues[#issues + 1] = 'HitFlash.Color must be a Color3'
	end
	if typeof(ArenaFeel.HitFlash.FlashColor) ~= 'Color3' then
		issues[#issues + 1] = 'HitFlash.FlashColor must be a Color3'
	end
	if ArenaFeel.HitFlash.FlashDuration >= ArenaFeel.HitFlash.Duration then
		issues[#issues + 1] = 'HitFlash.FlashDuration must be < HitFlash.Duration'
	end
	if ArenaFeel.Vfx.MaxCleanup < ArenaFeel.Vfx.MinCleanup then
		issues[#issues + 1] = 'Vfx.MaxCleanup must be >= MinCleanup'
	end
	if typeof(ArenaFeel.DamageNumber.BaseSize) ~= 'UDim2' then
		issues[#issues + 1] = 'DamageNumber.BaseSize must be a UDim2'
	end
	if typeof(ArenaFeel.Menu.Background) ~= 'Color3' then
		issues[#issues + 1] = 'Menu.Background must be a Color3'
	end
	num('Sfx.SlotCount', ArenaFeel.Sfx.SlotCount, 1)
	num('DeathFade.Steps', ArenaFeel.DeathFade.Steps, 1)
	return issues
end

return table.freeze(ArenaFeel)
