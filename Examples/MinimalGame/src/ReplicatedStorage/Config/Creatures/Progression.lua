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
	Progression
	===========
	Phase 2.4 — canonical Animal Level/XP progression configuration
	and the SINGLE threshold-processing implementation.

	Scope (spec §6/§7/§14):
	  * XP curve            — XPRequired(L) = BaseRequired * GrowthRate^(L-1)
	  * MaxLevel            — hard progression ceiling
	  * PointsPerLevel (q)  — level-derived progression points, P(L) = q(L-1)
	  * Normalize           — the one and only level-up drain loop

	This module is shared (ReplicatedStorage) and pure: no services,
	no instances, no remotes. AnimalService and PlayerService both
	route progression math through here — no other file may compute
	XP thresholds or drain level-ups (spec §7).

	XP SEMANTICS (spec §5)
	----------------------
	XP is CURRENT PROGRESS toward the next level, not lifetime XP.
	Crossing a threshold consumes it and carries the overflow into
	the next level:

	    Level 1, XP 90, required 100, AddXP(50)
	      -> Level 2, XP 40

	ROUNDING POLICY (spec §8)
	-------------------------
	`round-half-up` (math.floor(raw + 0.5)) applied EXACTLY ONCE,
	inside GetXPRequired, at the configuration boundary. XP and
	every threshold are integers from here on; no service, command,
	or test performs its own rounding. Intermediate math inside this
	module keeps full float precision and rounds only the returned
	requirement.

	MAXLEVEL XP BEHAVIOR (spec §11)
	-------------------------------
	At MaxLevel the level never increases. XP is retained as a
	"bank" for a possible future level-cap raise and is capped at
	GetXPRequired(MaxLevel) — the first threshold a cap raise would
	consume. Grants beyond the bank ceiling are deterministically
	discarded. The bank means: "progress toward the first level
	beyond the current cap". This holds identically across runtime,
	persistence, rejoin, GetXP and AddXP.

	DEVELOPMENT DEFAULTS
	--------------------
	BaseRequired = 100 and GrowthRate = 1.25 are the spec's examples,
	NOT final game balance — no existing project configuration defined
	them. They are labeled tunables like every other value here.
]]

local Progression = {}

-- --- Tunables --------------------------------------------------------

-- Hard level ceiling (spec §10). Compatible with the canonical
-- scaling document's 100-level example.
Progression.MaxLevel = 100

-- XP curve (spec §7): XPRequired(L) = BaseRequired * GrowthRate^(L-1).
-- BaseRequired is the XP needed to go Level 1 -> Level 2.
-- GrowthRate is PINNED at 1.12: UpgradeService implements the
-- identical 1.12 curve with exact 28/25 integer math and asserts
-- this value at load (rebalance pass: simulated 1.10-1.16,
-- 1.12 keeps every normal upgrade under ~4h payback while
-- preserving width-vs-depth tension). Do NOT retune without
-- updating UpgradeService + re-verifying the whole economy curve.
-- NOTE: the Arena player-XP track keeps its own separate 1.25
-- curve (Arena.lua) by design — arena gates are tuned to arena
-- XP supply, not to this curve.
Progression.XP = {
	BaseRequired = 200,
	GrowthRate = 1.12,
}

-- Points awarded per level (spec §14, canonical doc's q).
-- P(L) = q * (L - 1), so Level 1 = 0 points.
Progression.PointsPerLevel = 3

-- Largest double that still guarantees exact integer arithmetic.
-- Any threshold at or beyond this would make XP arithmetic lossy.
local MAX_EXACT_INTEGER = 2 ^ 53

-- --- Configuration validation (spec §9) ------------------------------

-- Validates the tunables above. Called once at require time so an
-- invalid configuration fails loudly at startup instead of silently
-- producing broken progression (NaN / infinity / negative thresholds).
local function validate()
	local cfg = Progression.XP
	if type(cfg) ~= 'table' then
		error('[Progression] XP table missing', 0)
	end
	local base, growth = cfg.BaseRequired, cfg.GrowthRate
	if type(base) ~= 'number' or base ~= base or base == math.huge or base == -math.huge or base <= 0 then
		error('[Progression] XP.BaseRequired must be a finite number > 0', 0)
	end
	if type(growth) ~= 'number' or growth ~= growth or growth == math.huge or growth == -math.huge or growth < 1 then
		error('[Progression] XP.GrowthRate must be a finite number >= 1 (1 = constant thresholds)', 0)
	end
	if
		type(Progression.MaxLevel) ~= 'number'
		or Progression.MaxLevel ~= math.floor(Progression.MaxLevel)
		or Progression.MaxLevel < 1
	then
		error('[Progression] MaxLevel must be an integer >= 1', 0)
	end
	if
		type(Progression.PointsPerLevel) ~= 'number'
		or Progression.PointsPerLevel ~= math.floor(Progression.PointsPerLevel)
		or Progression.PointsPerLevel < 0
	then
		error('[Progression] PointsPerLevel must be an integer >= 0', 0)
	end
	-- Overflow guard: every threshold across the whole curve must be
	-- finite and exact-integer representable. MaxLevel is bounded, so
	-- this is a bounded startup loop, not a runtime cost.
	for level = 1, Progression.MaxLevel do
		local raw = base * growth ^ (level - 1)
		if raw ~= raw or raw == math.huge or raw >= MAX_EXACT_INTEGER then
			error(
				('[Progression] XP curve overflows exact-integer range at level %d (raw=%s)'):format(
					level,
					tostring(raw)
				),
				0
			)
		end
	end
end

-- --- XP threshold API (spec §7/§8) -----------------------------------

-- XP required to advance FROM `level` to `level + 1`.
-- The single rounding point of the whole progression system
-- (round-half-up, spec §8). Throws on out-of-domain input: callers
-- passing a bad level is a programming error, not runtime data.
function Progression.GetXPRequired(level: number): number
	if
		type(level) ~= 'number'
		or level ~= level
		or level ~= math.floor(level)
		or level < 1
		or level > Progression.MaxLevel
	then
		error(('[Progression] GetXPRequired: level must be an integer in 1..%d'):format(Progression.MaxLevel), 0)
	end
	local raw = Progression.XP.BaseRequired * Progression.XP.GrowthRate ^ (level - 1)
	-- Round-half-up, exactly once (spec §8). raw < 2^53 is guaranteed
	-- by validate(), so the result is an exact integer.
	return math.floor(raw + 0.5)
end

-- --- Level-derived progression points (spec §14/§15) -----------------

-- Canonical formula P(L) = q(L - 1). Level 1 = 0 points. Integer.
-- PointsPerLevel = 3 -> L2 = 3, L3 = 6, ... L100 = 297.
function Progression.GetPointsForLevel(level: number): number
	if
		type(level) ~= 'number'
		or level ~= level
		or level ~= math.floor(level)
		or level < 1
		or level > Progression.MaxLevel
	then
		error(('[Progression] GetPointsForLevel: level must be an integer in 1..%d'):format(Progression.MaxLevel), 0)
	end
	return Progression.PointsPerLevel * (level - 1)
end

-- Maximum investable points across the whole progression:
-- P_max = q * (L_max - 1). With q = 3, L_max = 100 -> 297.
function Progression.GetMaxPoints(): number
	return Progression.PointsPerLevel * (Progression.MaxLevel - 1)
end

-- --- Threshold processing (spec §12/§13/§28) --------------------------

-- THE single level-up drain loop (spec §7: no other service computes
-- thresholds). Takes any (level, xp) pair — including malformed
-- persistence data — and returns a guaranteed-valid progression
-- state plus how many levels were crossed.
--
--   1. Repairs `level`: non-number / NaN / inf / fractional / < 1 -> 1;
--      > MaxLevel -> MaxLevel (clamp preserves the data, spec §27).
--   2. Repairs `xp`: non-number / NaN / inf / fractional / < 0 -> 0.
--   3. Drains thresholds iteratively while level < MaxLevel
--      (hard safety condition, spec §13 — malformed config can
--      never create an infinite loop because GetXPRequired >= 1
--      is validated and the level bound is fixed).
--   4. At MaxLevel caps XP at the bank ceiling (spec §11).
--
-- Returns (level, xp, levelsGained). Never throws, never yields.
function Progression.Normalize(level: any, xp: any): (number, number, number)
	if
		type(level) ~= 'number'
		or level ~= level
		or level == math.huge
		or level == -math.huge
		or level ~= math.floor(level)
		or level < 1
	then
		level = 1
	end
	if level > Progression.MaxLevel then
		level = Progression.MaxLevel
	end
	if type(xp) ~= 'number' or xp ~= xp or xp == math.huge or xp == -math.huge or xp ~= math.floor(xp) or xp < 0 then
		xp = 0
	end

	local levelsGained = 0
	local required = Progression.GetXPRequired(level)
	while level < Progression.MaxLevel and xp >= required do
		xp -= required
		level += 1
		levelsGained += 1
		required = Progression.GetXPRequired(level)
	end

	if level >= Progression.MaxLevel then
		local bank = Progression.GetXPRequired(Progression.MaxLevel)
		if xp > bank then
			xp = bank
		end
	end

	return level, xp, levelsGained
end

validate()
table.freeze(Progression.XP)

-- --- Admin level clamp (moved from GameConfig.MaxAnimalLevel) ---
-- /setlevel range check. The pipeline cap is XP.MaxLevel (100); the admin
-- clamp stays one below by explicit design (was MaxAnimalLevel = 99).
Progression.AdminLevelCap = 99
return table.freeze(Progression)
