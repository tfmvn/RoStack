--!strict
--!native
--[[
	StandPresentation
	=================
	EGG-ONLY centralized Heartbeat loop that keeps every slotted
	Egg feeling alive: a stationary idle wobble (side lean +
	micro bob + faint stretch) around each Egg's authoritative
	rest transform.

	HARD RULE — EGGS ONLY:
	  * This module animates EGGS SITTING IN EGG SLOTS. Animals
	    (opened/upgraded/carried/recovering/standing) must NEVER
	    be bound here. Animal presentation (Animator idle tracks
	    + level-up BOP) is untouched by this module.
	  * Canonical gate: SlotType.OccupantKind.Egg. Bind(model,
	    kind) only binds when kind == 'egg' (or kind == nil for
	    legacy egg call sites / tests that pass no kind). An
	    explicit 'animal' kind is a silent no-op.
	  * Callers: EggService / CollectorArrival pass
	    SlotType.OccupantKind.Egg. AnimalService must NOT call
	    Bind/Unbind/Hold/Rebase at all (its old calls are
	    removed; Hold/Rebase on unbound models are safe no-ops
	    kept only for the level-up path's defensive calls).

	Design (hard rules):
	  * Rest is CAPTURED, never derived per frame: Bind() snapshots
	    model:GetPivot() + model:GetScale() right after the owner
	    system settles the model on its stand. The loop computes
	    final = rest * wobble(t) fresh every tick — never
	    current * wobble, so rotation/Y/scale can never
	    accumulate, and a stand change just re-binds.
	  * ONE Heartbeat connection for ALL bound eggs, gated to
	    ~30Hz whole-registry (idle wobble is sub-Hz motion; 30Hz
	    sampling is visually lossless and halves replication vs
	    60Hz). No per-model connections, threads, or Tweens.
	  * Scale is always base-relative (captured baseline × idle
	    multiplier) via the quantized EggWalkAnimator.ApplyScale —
	    the level-up BOP's temporary squash can never leak in,
	    and repeated binds can never inflate. Each egg keeps its
	    OWN baseline so small/medium/large eggs never normalize.
	  * restPos/restRot are decomposed ONCE at bind (no per-tick
	    `rest - rest.Position` CFrame alloc); PivotTo writes are
	    skipped behind an epsilon deadband when the pose did not
	    meaningfully change (replication + rig cost saved).
	  * Hold(model, seconds) pauses a model (used by the level-up
	    celebration, which owns the transform for ~1.15s). Held
	    models are skipped entirely — no fighting, no jitter.
	  * Bind/Unbind are idempotent and never throw; unknown or
	    destroyed models are no-ops / auto-dropped. If the owner
	    systems forget an Unbind, the Parent == nil sweep still
	    guarantees no leak and no work.

	Visual language comes from EggWalkAnimator.IdlePose (same
	clocks/constants as roaming/travelling eggs, minus travel
	lean): roam, travel, and stand all read as the same cute
	creature, stationary on its stand.
]]

local RunService = game:GetService('RunService')

local EggWalkAnimator = require(script.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MovementConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Movement)

local StandPresentation = {}

-- Whole-registry tick rate (Hz). Idle motion is ~0.45Hz, so 30Hz
-- sampling is smooth while keeping replication bounded even
-- with a full house of slotted eggs.
-- Canonical: MovementConfig.StandIdle (values preserved exactly).
local STAND_TICK_RATE = MovementConfig.StandIdle.TickRate
-- PivotTo deadband: skip the CFrame write (and its replication)
-- when neither height nor lean moved enough to see. Bob
-- amplitude is ~0.045 studs; this epsilon skips ~1/3 of ticks
-- near motion extrema with zero visible difference.
local POSE_EPSILON = MovementConfig.StandIdle.PoseEpsilon
local LEAN_EPSILON = MovementConfig.StandIdle.LeanEpsilon

--- Canonical egg-vs-animal gate.
--- Returns true only for the egg occupant kind (or nil for
--- legacy egg call sites / unit tests that pass no kind).
--- An explicit 'animal' kind is NEVER an egg.
local function _isEggKind(kind: any): boolean
	if kind == nil then
		return true
	end
	return kind == SlotType.OccupantKind.Egg
end

--- Public canonical check (spec §20): IsEgg / IsAnimal based on
--- the authoritative SlotType occupant discriminator, never on
--- model names or container membership.
function StandPresentation.IsEggKind(kind: any): boolean
	return _isEggKind(kind)
end

function StandPresentation.IsAnimalKind(kind: any): boolean
	return kind == SlotType.OccupantKind.Animal
end

type StandEntry = {
	restPos: Vector3,
	restRot: CFrame,
	baseScale: number,
	walk: any,
	lastScale: number?,
	lastBob: number?,
	lastLean: number?,
	holdUntil: number,
	kind: string?,
}

local _bound: { [Model]: StandEntry } = {}
local _conn: RBXScriptConnection? = nil
local _lastTick = 0

-- --- Internal loop -------------------------------------------------------

local function _update()
	local now = os.clock()
	if now - _lastTick < 1 / STAND_TICK_RATE then
		return
	end
	_lastTick = now
	local dt = 1 / STAND_TICK_RATE
	for model, entry in pairs(_bound) do
		if model.Parent == nil then
			_bound[model] = nil
		elseif entry.holdUntil > now then
			continue
		else
			local ok = pcall(function()
				EggWalkAnimator.AdvanceIdle(entry.walk, dt)
				local bob, lean, stretch = EggWalkAnimator.IdlePose(entry.walk)
				-- Deadband: skip the PivotTo (CFrame write +
				-- replication) when the pose did not visibly
				-- change since last tick. Scale still goes
				-- through the quantized ApplyScale helper.
				local lastBob = entry.lastBob
				local lastLean = entry.lastLean
				local bobChanged = lastBob == nil or math.abs(bob - lastBob) >= POSE_EPSILON
				local leanChanged = lastLean == nil or math.abs(lean - lastLean) >= LEAN_EPSILON
				if bobChanged or leanChanged then
					entry.lastBob = bob
					entry.lastLean = lean
					local p = entry.restPos
					model:PivotTo(CFrame.new(p.X, p.Y + bob, p.Z) * entry.restRot * CFrame.Angles(0, 0, lean))
				end
				entry.lastScale = EggWalkAnimator.ApplyScale(model, entry.baseScale * stretch, entry.lastScale)
			end)
			if not ok then
				_bound[model] = nil
			end
		end
	end
end

-- --- Public API ----------------------------------------------------------

function StandPresentation.Init()
	if _conn then
		return
	end
	_conn = RunService.Heartbeat:Connect(function()
		local ok, err = pcall(_update)
		if not ok then
			Debug.Warn('SP', 'stand loop failed gracefully (wobble skipped this tick)', {
				error = tostring(err),
			})
		end
	end)
end

-- Bind a freshly-settled EGG: snapshots its CURRENT pivot +
-- scale as the eternal rest baseline. Call immediately after
-- every egg settle/park (arrival, place, recover, refund,
-- rejoin). Re-binding (stand change) overwrites cleanly — never
-- accumulates. Never throws; non-models are no-ops.
--
-- EGG-ONLY: `occupantKind` should be SlotType.OccupantKind.Egg
-- (all egg call sites pass it). An explicit 'animal' kind is
-- rejected (silent no-op) so animals can never enter the egg
-- idle path even if a caller mis-wires. A nil kind binds (legacy
-- egg paths + unit tests that pass no kind).
function StandPresentation.Bind(model: any, occupantKind: any?)
	pcall(function()
		if not _isEggKind(occupantKind) then
			return
		end
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return
		end
		local typed = model :: Model
		if typed.Parent == nil then
			return
		end
		local rest: CFrame = typed:GetPivot()
		local baseScale = 1
		local okScale, s = pcall(function()
			return typed:GetScale()
		end)
		if okScale and type(s) == 'number' and s == s and s > 0 then
			baseScale = s
		end
		_bound[typed] = {
			restPos = rest.Position,
			restRot = rest - rest.Position,
			baseScale = baseScale,
			walk = EggWalkAnimator.New(),
			lastScale = nil,
			lastBob = nil,
			lastLean = nil,
			holdUntil = 0,
			kind = SlotType.OccupantKind.Egg,
		}
	end)
end

-- Unbind a model leaving its stand (grab, destroy, hatch, sale,
-- cleanup). Clears any hold. Never throws; unknown models noop.
function StandPresentation.Unbind(model: any)
	pcall(function()
		if typeof(model) == 'Instance' and (model :: Instance):IsA('Model') then
			_bound[model :: Model] = nil
		end
	end)
end

-- Re-snapshot rest pivot + scale for a bound egg WITHOUT
-- resetting its wobble personality (no pose pop). Called after
-- the level-up celebration, whose overlap growth legitimately
-- moved the resting scale — without this the loop would keep
-- animating around (and scaling back toward) the pre-growth
-- baseline. No-op on unbound models. Never throws.
function StandPresentation.Rebase(model: any)
	pcall(function()
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return
		end
		local typed = model :: Model
		local entry = _bound[typed]
		if not entry or typed.Parent == nil then
			return
		end
		local rest: CFrame = typed:GetPivot()
		entry.restPos = rest.Position
		entry.restRot = rest - rest.Position
		local okScale, s = pcall(function()
			return typed:GetScale()
		end)
		if okScale and type(s) == 'number' and s == s and s > 0 then
			entry.baseScale = s
			entry.lastScale = s
		end
	end)
end

-- Pause wobble writes for `seconds` (level-up celebration owns
-- the transform meanwhile). Never throws.
function StandPresentation.Hold(model: any, seconds: number)
	pcall(function()
		if typeof(model) ~= 'Instance' or not (model :: Instance):IsA('Model') then
			return
		end
		local entry = _bound[model :: Model]
		if entry then
			entry.holdUntil = os.clock() + (seconds or 0)
		end
	end)
end

-- TEST-ONLY seam: bound-model count (specs assert bind/unbind
-- balance without running the loop).
function StandPresentation._TestCount(): number
	local n = 0
	for _ in pairs(_bound) do
		n += 1
	end
	return n
end

return table.freeze(StandPresentation)
