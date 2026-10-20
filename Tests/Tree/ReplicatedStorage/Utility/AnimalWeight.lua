--!strict
--!native
--[[
	AnimalWeight
	============
	The ONE authoritative Animal weight / physical-growth layer.

	Pipeline (server-driven):

	    Level + definition
	        ↓
	    weight range (AnimalConfig.Weight, per-definition override
	    else per-rarity row)
	        ↓
	    CurrentWeight = log growth via StatCalculator
	    (same universal formula + Level points as Health/Damage/
	    Income — L1 = Base exactly, MaxLevel = Maximum exactly,
	    capped so Weight <= Maximum ALWAYS holds)
	        ↓
	    growthAlpha = (W - Base) / (Max - Base) in [0, 1]
	        ↓
	    growth multiplier = 1 + (MaxGrowthScale - 1) * alpha
	        ↓
	    target scale = animal.baseScale * multiplier
	        ↓
	    LIVE model ScaleTo (grounded — feet stay planted)

	DERIVED, NOT PERSISTED: weight/size recompute from Level +
	definition on every spawn and every level-up. No weight field
	lives on the runtime record or the profile, so a level change
	can never leave a stale size behind and rejoin lands at the
	correct size automatically.

	SCOPE: Weight → physical size ONLY. Health/Damage/Income/Sell
	never read this module (Level still owns those through the
	existing systems).

	FAIL-SAFE: unknown def / bad config / missing model all degrade
	to nil/false — the level-up celebration (bop + VFX) always
	plays regardless. Never throws out of the public API.
]]

local AnimalConfig = require(script.Parent.Parent.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.Config.Creatures.Progression)
local StatCalculator = require(script.Parent.StatCalculator)
local Debug = require(script.Parent.Debug)

local AnimalWeight = {}

-- Maximum visual growth at MaxWeight, as a multiple of the
-- animal's own baseline model scale (per-animal base preserved —
-- a tiny Mouse and a huge Dragon both grow +30%, never to one
-- universal size).
AnimalWeight.MaxGrowthScale = 1.30

-- Curve constant for the log growth (same shape family as the
-- per-rarity Health/Damage/Income rows, which all use 100).
AnimalWeight.Curve = 100

-- Warn-once set for broken def/config (not per push).
local warned: { [string]: boolean } = {}

local function warnOnce(key: string, message: string, data: { [string]: any }?)
	if warned[key] then
		return
	end
	warned[key] = true
	Debug.Warn('WT', message, data)
end

local function isFiniteNumber(v: any): boolean
	return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

-- Resolve the {Base, Maximum} weight range for a definitionId:
-- per-definition override first, else the definition's rarity
-- row. Returns nil for unknown defs / missing config (warn-once).
function AnimalWeight.GetRange(definitionId: any): { Base: number, Maximum: number }?
	if type(definitionId) ~= 'string' or definitionId == '' then
		return nil
	end
	local override = AnimalConfig.WeightByDefinition and AnimalConfig.WeightByDefinition[definitionId]
	if type(override) == 'table' and isFiniteNumber(override.Base) and isFiniteNumber(override.Maximum) then
		if override.Base > 0 and override.Maximum >= override.Base then
			return { Base = override.Base, Maximum = override.Maximum }
		end
	end
	local rarity, _def = AnimalConfig.Get(definitionId)
	if not rarity then
		warnOnce('def:' .. definitionId, 'AnimalWeight: defId not in catalog; no growth', {
			defId = definitionId,
		})
		return nil
	end
	local row = AnimalConfig.WeightByRarity and AnimalConfig.WeightByRarity[rarity]
	if type(row) ~= 'table' or not isFiniteNumber(row.Base) or not isFiniteNumber(row.Maximum) then
		warnOnce('cfg:' .. tostring(rarity), 'AnimalWeight: no weight row for rarity; no growth', {
			rarity = tostring(rarity),
		})
		return nil
	end
	if row.Base <= 0 or row.Maximum < row.Base then
		warnOnce('cfg:' .. tostring(rarity), 'AnimalWeight: malformed weight row; no growth', {
			rarity = tostring(rarity),
		})
		return nil
	end
	return { Base = row.Base, Maximum = row.Maximum }
end

-- Canonical Level repair (same convention as AnimalStats: no
-- second normalization system — Normalize(level, 0) clamps into
-- 1..MaxLevel and never drains).
local function _repairLevel(level: any): number
	return LevelConfig.Normalize(level, 0)
end

-- Deterministic current weight for (definitionId, level).
-- L1 = Base exactly, MaxLevel = Maximum exactly, monotonic
-- log growth between, capped at Maximum beyond. Returns nil
-- when the range is unresolvable. Never throws.
function AnimalWeight.CalculateWeight(definitionId: any, level: any): number?
	local range = AnimalWeight.GetRange(definitionId)
	if not range then
		return nil
	end
	local fixed = _repairLevel(level)
	local points = LevelConfig.GetPointsForLevel(fixed)
	local maxPoints = LevelConfig.GetMaxPoints()
	local value: number
	if points >= maxPoints then
		value = range.Maximum
	else
		local ok, v = pcall(StatCalculator.Calculate, {
			Points = points,
			Base = range.Base,
			Maximum = range.Maximum,
			Curve = AnimalWeight.Curve,
			MaxPoints = maxPoints,
		})
		if not ok or not isFiniteNumber(v) then
			return nil
		end
		value = v
	end
	if value < 0 then
		return 0
	end
	if value > range.Maximum then
		return range.Maximum
	end
	return value
end

-- Normalized growth in [0, 1]: 0 at BaseWeight, 1 at Maximum.
-- Returns nil when the weight is unresolvable.
function AnimalWeight.GrowthAlpha(definitionId: any, level: any): number?
	local range = AnimalWeight.GetRange(definitionId)
	if not range then
		return nil
	end
	local w = AnimalWeight.CalculateWeight(definitionId, level)
	if not w then
		return nil
	end
	local span = range.Maximum - range.Base
	if span <= 0 then
		return 1
	end
	return math.clamp((w - range.Base) / span, 0, 1)
end

-- Visual growth multiplier for (definitionId, level): 1.00 at
-- Level 1 → MaxGrowthScale at MaxWeight. Nil when unresolvable.
function AnimalWeight.GetGrowthMultiplier(definitionId: any, level: any): number?
	local alpha = AnimalWeight.GrowthAlpha(definitionId, level)
	if alpha == nil then
		return nil
	end
	return 1 + (AnimalWeight.MaxGrowthScale - 1) * alpha
end

-- Target ABSOLUTE model scale for a runtime animal record:
-- animal.baseScale * growth multiplier. baseScale is captured
-- from the live model at spawn (the animal's own authored size
-- is the baseline — never a universal size, never compounded).
-- Nil = "no growth info" (celebration still plays). Never throws.
function AnimalWeight.GetTargetScale(animal: any): number?
	local ok, value = pcall(function(): number?
		if type(animal) ~= 'table' then
			return nil
		end
		local defId = animal.definitionId or animal.DefId
		local base = animal.baseScale
		if not isFiniteNumber(base) or base <= 0 then
			return nil
		end
		local mult = AnimalWeight.GetGrowthMultiplier(defId, animal.Level)
		if not isFiniteNumber(mult) or mult <= 0 then
			return nil
		end
		return base * mult
	end)
	if not ok or not isFiniteNumber(value) or (value :: number) <= 0 then
		return nil
	end
	return value
end

-- Apply the weight-derived scale to the animal's LIVE model.
-- SERVER-SIDE ONLY — implemented in AnimalService
-- (ApplyGrowthScale), which owns SlotMath grounding. This
-- module stays pure shared code (ReplicatedStorage modules can
-- never require ServerScriptService siblings) so both server
-- and client/test requires stay cycle-free.

return table.freeze(AnimalWeight)
