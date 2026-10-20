--!strict
--!native
--[[
	EggWalkAnimator
	===============
	THE single procedural egg walk-cycle implementation. Used by
	BOTH egg locomotion systems so they always look identical:

	  * Egg.AmbientService (spawn-area roaming)
	  * Egg.FlightController (purchased-egg travel to base)

	One deterministic phase per egg drives a coordinated rhythm:
	lift peaks at apex, uniform squash↔stretch follows vertical
	velocity (stretch rising / neutral apex / squash landing),
	side lean alternates per hop, forward lean scales with actual
	speed. A blend crossfades walk↔idle so starts/stops never
	snap. Tweak EggConfig.Ambient once — both systems follow.

	Contracts (perf-critical, read before touching):
	  * Pure math + per-egg state tables. The ONLY engine calls
	    in this module are the two guarded ScaleTo helpers.
	  * No Heartbeat/RenderStepped connections, no Tweens, no
	    Instance creation, no per-frame math.random() (personality
	    is rolled ONCE in New, at spawn/launch time).
	  * Pose() returns multiple values (no table alloc per tick).
	  * ScaleTo re-rigs the model: ApplyScale quantizes via
	    EggConfig.Ambient.ScaleEpsilon; RestoreScale snaps exact.
	  * Callers own the final PivotTo (one per egg per update)
	    and all grounding/steering — this module only answers
	    "how should this egg visually move".
]]

local EggConfig = require(script.Parent.Parent.Config.Creatures.Eggs)

local EggWalkAnimator = {}

local _sin = math.sin
local _cos = math.cos
local _abs = math.abs
local _clamp = math.clamp

-- Global kill-switch for ALL coded Egg animations (walk-cycle +
-- idle). Owned by EggConfig.EggAnimationsEnabled. Only an
-- explicit `false` disables; nil (pre-toggle code) and `true`
-- both mean "animate as before". Checked per call so the toggle
-- applies at runtime without touching any caller. When disabled,
-- movement/steering/grounding still run — callers just receive
-- the rest pose (zero lift/lean/offset, unit stretch).
local function _animationsEnabled(): boolean
	return EggConfig.EggAnimationsEnabled ~= false
end

export type WalkState = {
	phase: number,
	blend: number,
	idlePhase: number,
	freqMult: number,
	bobMult: number,
	swayMult: number,
}

-- New walk state with once-rolled personality (cycle speed ±8%,
-- bob ±15%, sway ±20%, scattered start/idle phases so eggs never
-- march in sync). math.random() here is spawn/launch-time only.
-- Spreads canonical: EggConfig.Ambient.{Freq,Bob,Sway}{Base,Spread}.
function EggWalkAnimator.New(): WalkState
	local cfg = EggConfig.Ambient
	return {
		phase = math.random() * math.pi * 2,
		blend = 0,
		idlePhase = math.random() * math.pi * 2,
		freqMult = cfg.FreqBase + math.random() * cfg.FreqSpread,
		bobMult = cfg.BobBase + math.random() * cfg.BobSpread,
		swayMult = cfg.SwayBase + math.random() * cfg.SwaySpread,
	}
end

-- Advance the cycle for a moving egg: blend in + speed-scaled
-- phase. speedFactor is actualSpeed / nominalSpeed clamped to
-- [0, 1] by the caller (same convention both systems use).
function EggWalkAnimator.Advance(s: any, dt: number, speedFactor: number)
	if not _animationsEnabled() then
		s.blend = 0
		return
	end
	local cfg = EggConfig.Ambient
	s.blend = math.min(1, s.blend + dt * cfg.BlendInRate)
	s.phase += dt * cfg.HopFrequency * (cfg.LowSpeedFloorBase + cfg.LowSpeedFloorGain * speedFactor) * s.freqMult
end

-- Current pose. Returns lift, leanSide, leanFwd, stretch —
-- combined by the caller with its own grounding/rotation into
-- ONE final transform. sizeFactor scales the hop to egg height
-- (AmbientService caches clamp(halfHeight, ...) per model).
function EggWalkAnimator.Pose(s: any, speedFactor: number, sizeFactor: number): (number, number, number, number)
	if not _animationsEnabled() then
		return 0, 0, 0, 1
	end
	local cfg = EggConfig.Ambient
	local hopSin = _sin(s.phase)
	local lift = _abs(hopSin) * cfg.HopAmplitude * speedFactor * s.bobMult * sizeFactor * s.blend
	local stretch = 1 + _cos(s.phase) * cfg.StretchAmplitude * s.blend
	local leanSide = hopSin * cfg.SwayAmplitude * s.swayMult * s.blend
	local leanFwd = cfg.LeanAmplitude * speedFactor * s.blend
	return lift, leanSide, leanFwd, stretch
end

-- Settle toward rest (idle / pre-arrival): blend decays, idle
-- breathing clock advances. Returns blend, idleOffset where
-- idleOffset = settleDip + breath (caller adds it to the rest
-- height). rateOverride lets landing sequences settle faster
-- than the ambient idle rate without touching config.
function EggWalkAnimator.Rest(s: any, dt: number, rateOverride: number?): (number, number)
	if not _animationsEnabled() then
		s.blend = 0
		return 0, 0
	end
	local cfg = EggConfig.Ambient
	local rate = rateOverride or cfg.BlendOutRate
	s.blend = math.max(0, s.blend - dt * rate)
	s.idlePhase += dt * cfg.IdleFrequency
	return s.blend, cfg.SettleDip * s.blend + _sin(s.idlePhase) * cfg.IdleAmplitude
end

-- Advance the stationary idle clock (stand/display occupants).
-- Separate from Rest: stands never blend (no locomotion to fade),
-- they just breathe/wobble around their rest transform.
function EggWalkAnimator.AdvanceIdle(s: any, dt: number)
	if not _animationsEnabled() then
		return
	end
	s.idlePhase += dt * EggConfig.Ambient.IdleFrequency
end

-- Stationary idle wobble for stand/display occupants: gentle side
-- lean + micro bob + faint stretch. Same clocks and constants as
-- the walk cycle (one visual language) but NO forward travel
-- lean and NO locomotion — a happy stand wobble, not walking in
-- place. Returns bobY, leanSide, stretch. Pure.
function EggWalkAnimator.IdlePose(s: any): (number, number, number)
	if not _animationsEnabled() then
		return 0, 0, 1
	end
	local cfg = EggConfig.Ambient
	local bob = _sin(s.idlePhase) * cfg.IdleAmplitude * cfg.IdleBobGain
	local lean = _sin(s.idlePhase * 0.5) * cfg.SwayAmplitude * cfg.IdleSwayGain * s.swayMult
	local stretch = 1 + _cos(s.idlePhase) * cfg.IdleStretch * s.bobMult
	return bob, lean, stretch
end

-- Quantized ScaleTo: applies target only on meaningful change
-- (ScaleEpsilon), else keeps last. Returns the scale the model
-- is now at (target or last). Never throws; nil-model safe.
function EggWalkAnimator.ApplyScale(model: Model?, target: number, last: number?): number?
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		return last
	end
	if type(target) ~= 'number' or target ~= target then
		return last
	end
	if last ~= nil and _abs(target - last) < EggConfig.Ambient.ScaleEpsilon then
		return last
	end
	local ok = pcall(function()
		(model :: Model):ScaleTo(target)
	end)
	if ok then
		return target
	end
	return last
end

-- Exact scale restore (arrival / stop / idle-settle): snaps to
-- base when drifted, else no-op. baseScale is the model's own
-- authored scale captured at spawn/launch (eggs: usually 1, but
-- never assumed). Returns the scale the model is now at. Never
-- throws; nil-model safe.
function EggWalkAnimator.RestoreScale(model: Model?, baseScale: number, last: number?): number?
	if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
		return last
	end
	if last == nil or last == baseScale then
		return last
	end
	local ok = pcall(function()
		(model :: Model):ScaleTo(baseScale)
	end)
	if ok then
		return baseScale
	end
	return last
end

-- Clamp helper re-export for callers that already clamp the
-- same way (keeps one convention; trivially cheap).
function EggWalkAnimator.ClampSpeedFactor(value: number): number
	return _clamp(value, 0, 1)
end

return table.freeze(EggWalkAnimator)
