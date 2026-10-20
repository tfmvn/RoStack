--!strict
--!native
--[[
	TraitService
	============
	Phase 2.11 — the ONE authority for Animal Traits. An Animal
	has EXACTLY zero or one Trait (nil = none), rolled server-side
	at Egg open time (or forced 100% by the egg's hidden
	preassigned Trait). Pure functions + config reads only — no
	service refs, no state — so persistence, specs, and the open
	pipeline can all call in without cycles.

	API:
	  RollTrait(rollOverride?) -> string?  (exactly one or nil)
	  IsValidTrait(id) -> boolean
	  GetGenerationMultiplier(traitOrNil) -> number (float, rate math)
	  GetSellMultiplier(traitOrNil) -> string (exact BigNumber decimal)

	No-trait is ALWAYS nil: Get* degrade to 1 / '1' on nil (and on
	unknown ids, loudly warned once — records are audit-cleaned,
	so unknown means a bug worth hearing about, not a crash).
]]

local TraitConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Traits)
local MutationService = require(script.Parent.MutationService)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)

local TraitService = {}

function TraitService.Init()
	-- No-op: stateless.
end

-- Is this a real trait id? Nil/wrong-type/unknown -> false.
-- Note: nil is VALID data (means "no trait") but is not a
-- valid ID — callers distinguish "absent" (nil input) from
-- "bogus" (unknown string) through context.
function TraitService.IsValidTrait(traitId: any): boolean
	if type(traitId) ~= 'string' or traitId == '' then
		return false
	end
	return TraitConfig.Get(traitId) ~= nil
end

-- Authoritative server-side roll: exactly one trait id or nil.
-- Walks TraitConfig.RollOrder (FIXED order — never pairs(), so
-- table order cannot skew probabilities). `rollOverride` is the
-- documented test seam: a number in [0, 1) used instead of
-- math.random so specs are deterministic. Production passes nil.
function TraitService.RollTrait(rollOverride: number?): string?
	local roll: number
	if type(rollOverride) == 'number' and rollOverride == rollOverride and rollOverride >= 0 and rollOverride < 1 then
		roll = rollOverride
	else
		roll = math.random()
	end
	local cursor = 0
	for _, id in ipairs(TraitConfig.RollOrder) do
		local entry = TraitConfig.Get(id)
		if entry and type(entry.Chance) == 'number' and entry.Chance > 0 then
			cursor += entry.Chance / 100
			if roll < cursor then
				Debug.Log('TR', 'trait rolled', { trait = id, roll = tostring(roll) })
				return id
			end
		end
	end
	return nil
end

-- Float multiplier for generation math (rates are floats; the
-- income accumulator owns the single flooring boundary).
-- Delegates to the single config fold — never reimplemented.
function TraitService.GetGenerationMultiplier(traitId: string?): number
	return TraitConfig.GenerationMultiplierFor(traitId)
end

-- Exact decimal-string multiplier for BigNumber sell math.
-- Delegates to the single config fold — never reimplemented.
function TraitService.GetSellMultiplier(traitId: string?): string
	return TraitConfig.SellMultiplierFor(traitId)
end

-- Resolve an Egg opening into the Animal's inheritance
-- (Phase 2.11 §5/§24 — THE rule, obvious by construction):
--   * blockTrait valid -> use it, 100%, NO random roll
--   * blockTrait invalid-but-present -> warn + fall back to roll
--     (the egg survives; only the bogus payload is ignored)
--   * blockTrait nil -> RollTrait()
-- Mutations are defensively copied (fresh array, canonical order):
-- the Animal must never alias the egg's live table.
-- Pure apart from the roll + logs: specs drive it directly with
-- rollOverride; CreateFromEgg calls it with nil inside the
-- open mutex (consumed-once egg, created-once animal,
-- rolled-once trait, copied-once list).
function TraitService.ResolveInheritance(
	blockTrait: string?,
	blockMutations: any,
	rollOverride: number?
): { Trait: string?, Mutations: { string } }
	local trait: string? = nil
	if type(blockTrait) == 'string' and blockTrait ~= '' then
		if TraitService.IsValidTrait(blockTrait) then
			trait = blockTrait
			Debug.Log('TR', 'forced trait inherited', { trait = trait })
		else
			Debug.Warn('TR', 'invalid hidden egg Trait; rolling instead', { trait = tostring(blockTrait) })
			trait = TraitService.RollTrait(rollOverride)
		end
	else
		trait = TraitService.RollTrait(rollOverride)
	end
	if trait then
		Debug.Log('TR', 'opening trait resolved', { trait = trait })
	end
	local clean = MutationService.SanitizeList(blockMutations)
	local copy: { string } = {}
	for _, id in ipairs(clean) do
		copy[#copy + 1] = id
	end
	Debug.Log('TR', 'mutations inherited', { mutations = table.concat(copy, ',') })
	return { Trait = trait, Mutations = copy }
end

return table.freeze(TraitService)
