--!strict
--[[
	StatCalculator
	==============
	Phase 2.4 — the ONE universal logarithmic stat-scaling utility
	(canonical reference: "Universal Logarithmic Stat Scaling System").

	Normalized form (spec §18) — used when a desired maximum is known:

	    G(P) = B + (M - B) * ln(1 + P/C) / ln(1 + P_max/C)

	    G(P)    final property value
	    P       points invested into the property
	    B       base value          (G(0) = B, guaranteed)
	    M       desired maximum     (G(P_max) = M, guaranteed)
	    C       curve constant      (diminishing-returns shape; > 0)
	    P_max   maximum investable points (> 0)

	Basic (non-normalized) form for reference: G(P) = B + k * ln(1 + P/C).

	THIS MODULE IS GENERIC (spec §36): it depends on nothing — not
	AnimalService, not PlayerService, not rarity, not any definition.
	It computes G(P; B, M, C, P_max) and nothing else. Future consumers
	(HP, Damage, Defense, PassiveGeneration, Income, Energy, machines,
	weapons, ...) pass their own parameters.

	FUTURE USAGE PATTERN (spec §24 — documented, NOT implemented):
	the canonical document ties levels to points via P(L) = q(L - 1)
	(see LevelConfig.GetPointsForLevel). A future stat that scales
	automatically from Level composes:

	    G(L) = G(P(L)) = B + (M - B) * ln(1 + q(L-1)/C) / ln(1 + P_max/C)

	    with P_max = q * (L_max - 1)   (LevelConfig.GetMaxPoints)

	Model A (all level points auto-invested) vs Model B (free
	allocation) is a FUTURE decision — do not assume either here.

	ROUNDING POLICY (spec §25): full float precision in, full float
	precision out. NO rounding inside this module. A consumer that
	needs an integer game-facing value rounds ONCE, at its own
	final boundary. Intermediate round-trips would compound error.

	POINT CLAMP POLICY (spec §21): P > P_max is clamped to P_max,
	guaranteeing G never exceeds the intended maximum M.
]]

local StatCalculator = {}

-- Largest double with exact integer representation; used only to
-- reject absurd inputs early, never for rounding.
local MAX_EXACT_INTEGER = 2 ^ 53

local function isFiniteNumber(v: any): boolean
	return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

-- Calculate G(P) with the normalized logarithmic formula.
--
-- Validation (spec §21) — throws (programming/config error):
--   Base, Maximum : finite numbers (Maximum < Base allowed: a stat
--                   that decreases with investment is still valid)
--   Curve         : finite number > 0
--   MaxPoints     : finite number > 0 and <= MAX_EXACT_INTEGER
--   Points        : finite number >= 0
-- Clamp (data-driven, deterministic): Points > MaxPoints -> MaxPoints,
--   which yields exactly M.
--
-- Returns the un-rounded value. G(0) = B exactly (fast path; the
-- formula also gives this since ln(1) = 0).
function StatCalculator.Calculate(params: {
	Points: number,
	Base: number,
	Maximum: number,
	Curve: number,
	MaxPoints: number,
}): number
	local points = params and params.Points
	local base = params and params.Base
	local maximum = params and params.Maximum
	local curve = params and params.Curve
	local maxPoints = params and params.MaxPoints

	if not isFiniteNumber(base) then
		error('[StatCalculator] Base must be a finite number', 0)
	end
	if not isFiniteNumber(maximum) then
		error('[StatCalculator] Maximum must be a finite number', 0)
	end
	if not isFiniteNumber(curve) or curve <= 0 then
		error('[StatCalculator] Curve must be a finite number > 0', 0)
	end
	if not isFiniteNumber(maxPoints) or maxPoints <= 0 or maxPoints > MAX_EXACT_INTEGER then
		error('[StatCalculator] MaxPoints must be a finite number > 0', 0)
	end
	if not isFiniteNumber(points) or points < 0 then
		error('[StatCalculator] Points must be a finite number >= 0', 0)
	end

	-- Deterministic clamp (spec §21): G(P_max) = M, never beyond.
	if points > maxPoints then
		points = maxPoints
	end

	-- G(0) = B exactly.
	if points == 0 then
		return base
	end

	local value = base + (maximum - base) * math.log(1 + points / curve) / math.log(1 + maxPoints / curve)

	-- Defensive determinism guard: inputs are validated, so NaN/inf
	-- can only arise from extreme magnitudes; refuse rather than
	-- propagate a poisoned value.
	if value ~= value or value == math.huge or value == -math.huge then
		error('[StatCalculator] result overflowed to NaN/infinity; check parameter magnitudes', 0)
	end
	return value
end

return table.freeze(StatCalculator)
