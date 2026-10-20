--!strict
--!native
--[[
	UpgradeService
	==============
	Phase 2.10 — the ONE authority for paid Animal level upgrades.
	Server-authoritative end to end: the client may request
	"upgrade this animal" but never a cost or a level; every
	value is derived here from authoritative state.

	Cost formula (single source of truth, §54 — never duplicated
	in client, UI, tests, or AnimalService):

    UpgradeCost(L -> L+1) = AnimalBasePrice x 1.12^(L-1)

  * AnimalBasePrice = AnimalConfig.SellBaseValue[rarity],
    the authoritative configured base price of the definition
    (NOT sale value, pool, income, or player Money).
  * 1.12 = LevelConfig.XP.GrowthRate, reused (NOT a new
    constant, NOT RarityMultipliers, NOT ModifierService).

Precision (§8-§9): ZERO floating point. 1.12 = 28/25, so the
cost is base x 28^(L-1) / 25^(L-1), computed with BigNumber
integer ops only, scaled by 10^(2(L-1)) for the exact
terminating decimal (25^k = 5^2k divides 10^2k exactly). The
result is the EXACT decimal string — deterministic across
server, preview, tests, and rejoin.
TrySpendMoney/Compare/Subtract are all fraction-safe, so
cent costs spend exactly.

	Transaction (§21): validate everything (incl. a full
	level-up pre-check) -> TrySpendMoney(AnimalUpgrade) atomic
	-> AnimalService.ApplyLevelUpgrade. Spend-then-mutate
	mirrors the sale pattern: the debit is atomic, and the level
	mutation is infallible after pre-validation. No yields in the
	critical section; _mutex + per-request cost recalculation
	make double-clicks safe (§22).

	Untouched by design: XP (kept), CashPool (kept), slot, Id,
	definition, ModifierService (never consulted), and MaxLevel
	(upgrade rejected, nothing moves).
]]

local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
-- Canonical player-facing rejections. Leaf module — cycle-free.
local NotificationService = require(script.Parent.Base.NotificationService)
-- Raid lock: upgrading mid-raid must not mutate the frozen
-- raid snapshot (nor surprise the player with a stat jump
-- that the raid intentionally ignores). Require-safe:
-- ArenaService has ReplicatedStorage deps only.
local ArenaService = require(script.Parent.Arena.ArenaService)
local TutorialSignals = require(script.Parent.Tutorial.TutorialSignals)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(script.Parent.FunnelService)

local UpgradeService = {}

-- Single source of truth: the growth factor lives in
-- Progression.XP.GrowthRate (unified-config migration). The exact
-- integer math below implements 28/25 == 1.12 with zero floats;
-- assert the config still says 1.12 so a growth retune fails
-- LOUDLY here instead of silently forking the upgrade economy
-- from the XP curve.
assert(
	LevelConfig.XP.GrowthRate == 1.12,
	'Progression.XP.GrowthRate drifted from 1.12: update UpgradeService exact math'
)

-- --- Stable error codes -------------------------------------------

UpgradeService.Error = {
	InvalidPlayer = 'invalid-player',
	InvalidId = 'invalid-id',
	NotFound = 'not-found',
	NotOwner = 'not-owner',
	Busy = 'busy',
	InvalidState = 'invalid-state',
	NotAnimal = 'not-animal',
	InvalidDefinition = 'invalid-definition',
	InvalidLevel = 'invalid-level',
	MaxLevel = 'max-level',
	NoCost = 'no-cost',
	SlotState = 'slot-state',
	Insufficient = 'insufficient',
	GrantFailed = 'grant-failed',
	ServiceUnavailable = 'service-unavailable',
}

-- --- Injected service refs (wired by bootstrap) -------------------

local playerServiceRef: any = nil
local slotServiceRef: any = nil
local baseServiceRef: any = nil
local animalServiceRef: any = nil
local economyServiceRef: any = nil

function UpgradeService.SetPlayerService(ps: any)
	playerServiceRef = ps
end

function UpgradeService.SetSlotService(ss: any)
	slotServiceRef = ss
end

function UpgradeService.SetBaseService(bs: any)
	baseServiceRef = bs
end

function UpgradeService.SetAnimalService(svc: any)
	animalServiceRef = svc
end

function UpgradeService.SetEconomyService(es: any)
	economyServiceRef = es
end

-- --- Authoritative cost (pure — no refs) ------------------------------

local function _validLevel(level: any): boolean
	return type(level) == 'number' and level == math.floor(level) and level >= 1 and level <= LevelConfig.MaxLevel
end

-- Base price for an animal definition, as a canonical BigNumber
-- integer string. Shared with the sale formula's source (same
-- configured value, different use). Nil when unknown.
function UpgradeService.GetBasePrice(definitionId: string): string?
	if type(definitionId) ~= 'string' or definitionId == '' then
		return nil
	end
	local ok, rarity = pcall(AnimalConfig.Get, definitionId)
	if not ok or type(rarity) ~= 'string' then
		return nil
	end
	local base = AnimalConfig.SellBaseValue[rarity]
	if type(base) ~= 'number' or base ~= base or base ~= math.floor(base) or base <= 0 or base == math.huge then
		return nil
	end
	return BigNumber.sanitize(tostring(base))
end

-- THE upgrade cost: base x 1.12^(level-1), exact decimal string.
-- Computed as base x 28^k / 25^k with k = level-1, scaled by
-- 10^2k for the exact terminating decimal — BigNumber integer
-- ops only, no floats at any step. Nil for bad input or
-- max-level-and-beyond (no 100 -> 101 price exists).
function UpgradeService.GetUpgradeCost(definitionId: string, level: number): string?
	if not _validLevel(level) then
		return nil
	end
	if level >= LevelConfig.MaxLevel then
		return nil
	end
	local base = UpgradeService.GetBasePrice(definitionId)
	if not base then
		return nil
	end
	local k = level - 1
	-- numerator = base x 28^k (Multiply takes small int multis).
	local num = base
	for _ = 1, k do
		local ok, scaled = pcall(BigNumber.Multiply, num, 28)
		if not ok or type(scaled) ~= 'string' then
			return nil
		end
		num = scaled
	end
	-- denominator = 25^k, as an exact string.
	local den = '1'
	for _ = 1, k do
		local ok, scaled = pcall(BigNumber.Multiply, den, 25)
		if not ok or type(scaled) ~= 'string' then
			return nil
		end
		den = scaled
	end
	-- Scale by 10^2k: 25^k = 5^2k divides 10^2k exactly, so
	-- the floored quotient below is the EXACT decimal
	-- expansion (no rounding anywhere — trailing zeros
	-- stripped after).
	local scaled = num
	for _ = 1, 2 * k do
		local ok, v = pcall(BigNumber.Multiply, scaled, 10)
		if not ok or type(v) ~= 'string' then
			return nil
		end
		scaled = v
	end
	local okQ, quotient = pcall(BigNumber.Divide, scaled, den)
	if not okQ or type(quotient) ~= 'string' then
		return nil
	end
	if k == 0 then
		return quotient
	end
	-- Insert the decimal point 2k digits from the right. The
	-- quotient is guaranteed longer than 2k digits: value >=
	-- base >= 1, so scaled/den = value x 10^2k has >= 2k+1
	-- digits... except value < 1 is impossible here (base >= 1
	-- and 5^k >= 4^k), but stay defensive for tiny bases.
	local digits = quotient
	while #digits <= 2 * k do
		digits = '0' .. digits
	end
	local intPart = string.sub(digits, 1, #digits - 2 * k)
	local fracPart = string.sub(digits, #digits - 2 * k + 1)
	local canonical = BigNumber.sanitize(intPart .. '.' .. fracPart)
	return canonical
end

-- --- Internal helpers -------------------------------------------------

local function _fail(code: string): { [string]: any }
	Debug.Log('UP', 'upgrade rejected', { error = code })
	return { success = false, error = code }
end

-- Reject + notify the acting player through the canonical
-- NotificationService (catalog text, throttle, Error SFX). A nil
-- reason stays silent (non-players, dead-character lockouts are
-- handled by the caller). Returns the stable { success = false }
-- table — notification never changes the transaction outcome.
local function _reject(player: Player?, code: string, reason: string?): { [string]: any }
	if reason ~= nil and player ~= nil then
		pcall(NotificationService.NotifyWarning, player, reason)
	end
	return _fail(code)
end

-- Server-calculated upgrade shortfall for the dynamic
-- "You need $X more to upgrade." message (never client values).
local function _upgradeShortfall(userId: number, cost: string): string?
	local shortfall: string? = nil
	pcall(function()
		local data = playerServiceRef and playerServiceRef.GetPlayerData(userId)
		local money = data and BigNumber.sanitize(data.Money) or '0'
		shortfall = BigNumber.Subtract(cost, money or '0')
	end)
	return shortfall
end

local function _wired(): boolean
	return playerServiceRef ~= nil
		and slotServiceRef ~= nil
		and baseServiceRef ~= nil
		and animalServiceRef ~= nil
		and economyServiceRef ~= nil
end

-- --- Upgrade transaction --------------------------------------------------

-- Buy one level for an owned Animal: debit the authoritative
-- cost, then Level += 1. Returns { success, animalId, oldLevel,
-- newLevel, cost, remainingMoney } or { success = false, error }.
function UpgradeService.UpgradeAnimal(player: Player, animalId: string): { [string]: any }
	if not Validation.LivePlayer(player) then
		return _fail(UpgradeService.Error.InvalidPlayer)
	end
	if type(animalId) ~= 'string' or animalId == '' then
		return _reject(player, UpgradeService.Error.InvalidId, 'Upgrade_InvalidRequest')
	end
	if not _wired() then
		return _reject(player, UpgradeService.Error.ServiceUnavailable, 'Upgrade_Unavailable')
	end
	local userId = player.UserId
	Debug.Log('UP', 'request', { player = player.Name, animal = animalId })

	local animal = animalServiceRef.Get(animalId)
	if not animal then
		Debug.Log('UP', 'REJECT', { animal = animalId, reason = 'NotFound' })
		return _reject(player, UpgradeService.Error.NotFound, 'Upgrade_InvalidTarget')
	end
	if animal.ownerUserId ~= userId then
		Debug.Log('UP', 'REJECT', { animal = animalId, reason = 'NotOwner' })
		return _reject(player, UpgradeService.Error.NotOwner, 'Upgrade_NotOwner')
	end
	if animal._mutex then
		return _reject(player, UpgradeService.Error.Busy, 'Upgrade_Busy')
	end
	animal._mutex = true

	local function abort(code: string, reason: string, notifyReason: string?, notifyArgs: any): { [string]: any }
		animal._mutex = false
		Debug.Log('UP', 'REJECT', { animal = animalId, reason = reason })
		if notifyReason ~= nil then
			pcall(NotificationService.NotifyWarning, player, notifyReason, notifyArgs)
		end
		return _fail(code)
	end

	if animal.state == 'Consumed' or animal.state == 'Destroyed' or animal.state == 'Carried' then
		return abort(UpgradeService.Error.InvalidState, 'InvalidState', 'Upgrade_InvalidTarget', nil)
	end
	-- Arena raid lock: the active raid fights on its frozen
	-- snapshot; the persistent animal waits until the raid
	-- ends (existing Busy feedback, no new UI).
	if ArenaService.IsAnimalRaidLocked(animalId) then
		return abort(UpgradeService.Error.Busy, 'RaidLocked', 'Upgrade_Busy', nil)
	end
	local definitionId = animal.definitionId
	if type(definitionId) ~= 'string' or definitionId == '' then
		return abort(UpgradeService.Error.InvalidDefinition, 'InvalidDefinition', 'Upgrade_Unavailable', nil)
	end
	local rarity, _def = AnimalConfig.Get(definitionId)
	if not rarity then
		return abort(UpgradeService.Error.InvalidDefinition, 'InvalidDefinition', 'Upgrade_Unavailable', nil)
	end
	local level = animal.Level
	if not _validLevel(level) then
		return abort(UpgradeService.Error.InvalidLevel, 'InvalidLevel', 'Upgrade_Unavailable', nil)
	end
	if level >= LevelConfig.MaxLevel then
		return abort(UpgradeService.Error.MaxLevel, 'MaxLevel', 'Upgrade_MaxLevel', nil)
	end
	-- Live slot match: the animal must sit on an Occupied slot
	-- owned by the buyer (rejects walking/released/cross-base).
	-- Arena stands are first-class slots: arena animals
	-- upgrade through this exact path.
	local slot = slotServiceRef.FindSlotByOccupant(animalId)
	if not slot or slot.state ~= 'Occupied' or slot.occupantId ~= animalId or slot.ownerUserId ~= userId then
		return abort(UpgradeService.Error.SlotState, 'StaleOccupant', 'Upgrade_InvalidTarget', nil)
	end
	-- Base ownership (defense in depth alongside the slot check).
	if baseServiceRef.GetBaseById then
		local okBase, base = pcall(baseServiceRef.GetBaseById, slot.baseId)
		if not okBase or type(base) ~= 'table' or base.ownerUserId ~= userId then
			return abort(UpgradeService.Error.NotOwner, 'NotOwner', 'Upgrade_NotOwner', nil)
		end
	end
	local cost = UpgradeService.GetUpgradeCost(definitionId, level)
	if not cost then
		return abort(UpgradeService.Error.NoCost, 'NoCost', 'Upgrade_Unavailable', nil)
	end
	Debug.Log('UP', 'validated', { animal = animalId, level = tostring(level), rarity = tostring(rarity) })
	Debug.Log('UP', 'cost', { animal = animalId, level = tostring(level), cost = cost })

	-- Atomic debit. Insufficient funds fail HERE with nothing
	-- mutated (no level change, no pool/XP touch). The shortfall
	-- is server-calculated for the dynamic message.
	local spent = economyServiceRef.TrySpendMoney(userId, cost, TransactionReason.AnimalUpgrade)
	if not spent or not spent.Success then
		if spent and spent.Code == 'insufficient' then
			return abort(
				UpgradeService.Error.Insufficient,
				'NotEnoughMoney',
				'Upgrade_InsufficientCash',
				{ Amount = _upgradeShortfall(userId, cost) }
			)
		end
		return abort(UpgradeService.Error.GrantFailed, 'SpendFailed', 'Upgrade_Failed', nil)
	end

	-- Level mutation (infallible after the pre-checks above).
	local applied = animalServiceRef.ApplyLevelUpgrade(animalId)
	if not applied or not applied.success then
		-- Practically unreachable (level was validated < Max
		-- before the debit). Money cannot be un-spent through
		-- a clean API, so this loudly preserves the evidence
		-- instead of silently swallowing paid money.
		animal._mutex = false
		Debug.Warn('UP', 'UPGRADE PAID BUT LEVEL NOT APPLIED — manual review required', {
			userId = tostring(userId),
			animalId = tostring(animalId),
			cost = cost,
		})
		pcall(NotificationService.NotifyWarning, player, 'Upgrade_Failed')
		return _fail(UpgradeService.Error.GrantFailed)
	end
	animal._mutex = false

	-- Push fresh state + success toast (same pattern as sales).
	if playerServiceRef and baseServiceRef then
		local snap
		if baseServiceRef.Snapshot then
			local okSnap, s = pcall(baseServiceRef.Snapshot, userId)
			if okSnap then
				snap = s
			end
		end
		playerServiceRef.PushState(player, snap)
		-- Success ONLY after the level commit above (debit +
		-- ApplyLevelUpgrade both succeeded).
		pcall(
			NotificationService.NotifySuccess,
			player,
			'Upgrade_Success',
			{ AnimalName = animal.displayName, Level = applied.newLevel, Rarity = rarity }
		)
	end
	Debug.Log('UP', 'SUCCESS', {
		animal = animalId,
		oldLevel = tostring(applied.oldLevel),
		newLevel = tostring(applied.newLevel),
		cost = cost,
	})
	-- Lifetime counter: exactly one upgrade event per
	-- committed upgrade (debit + ApplyLevelUpgrade above).
	pcall(function()
		if playerServiceRef and playerServiceRef.BumpStat then
			playerServiceRef.BumpStat(userId, 'UpgradesApplied')
		end
	end)
	-- Tutorial guide layer observes the committed upgrade (bus
	-- never throws; the upgrade itself is unaffected).
	pcall(TutorialSignals.Fire, 'AnimalUpgraded', { UserId = userId, AnimalId = animalId, NewLevel = applied.newLevel })
	-- Funnel: upgrade committed above (debit + level applied).
	-- FirstAnimalUpgraded is once-per-session; UpgradeSucceeded
	-- logs every success with a bounded level band. No
	-- UpgradeOpened/Attempted spam by design.
	pcall(function()
		local meta = {
			rarity = rarity,
			level_band = FunnelService.LevelBand(applied.newLevel),
			new_level = applied.newLevel,
		}
		FunnelService:LogStep(player, 'Progression', 'FirstAnimalUpgraded', meta)
		FunnelService:LogStep(player, 'Upgrade', 'FirstAnimalUpgraded', meta)
		FunnelService:LogStep(player, 'Upgrade', 'UpgradeSucceeded', meta)
	end)
	return {
		success = true,
		animalId = animalId,
		oldLevel = applied.oldLevel,
		newLevel = applied.newLevel,
		upgradeCost = cost,
		remainingMoney = spent.NewMoney,
	}
end

return table.freeze(UpgradeService)
