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
	Money
	=============
	Single source of truth for every ECONOMY tunable: starting money,
	money caps, income cadence, offline earnings, collector behavior,
	and the documented price/sell ladder invariants.

	WHAT THIS CONTROLS
	------------------
	The shape of the whole economy: how much players start with, how
	fast pools fill, how much offline time pays, how collection feels,
	and the guarantees binding egg prices to animal sell values.

	WHAT THIS DOES NOT CONTROL
	--------------------------
	* Per-rarity prices (EggConfig.Price) and sell values
	  (AnimalConfig.SellBaseValue). Those live in their own catalogs;
	  THIS module documents the invariant binding them.
	* Gear prices (GearConfig.ENTRIES) and arena cash rewards
	  (ArenaConfig.Rewards). Same: owned elsewhere, referenced here.
	* Grant/spend VALIDATION and anti-exploit clamping. Server rules
	  owned by EconomyService; it READS these tunables.
	* Upgrade costs (UpgradeService + animal level math) and sell
	  multipliers (MutationConfig/TraitConfig folds).

	SERVER AUTHORITY
	---------------
	ALL money movement is server-authoritative via EconomyService.
	Clients may read these values for display (labels, formatting) but
	must never be trusted for grants, spends, rewards, or validation.
	Changing StartingMoney changes first-join seeds only — never
	existing balances. Changing MaxMoney changes the clamp ceiling.

	CANONICAL HOME
	-------------
	Money is the single source of truth (the legacy GameConfig economy
	mirror was deleted in the unified-config migration). New code reads
	Money.

	Money convention: string-backed BigNumber decimal strings for
	ANY persisted/granted amount ('100000', never 100000), so values
	survive past 2^53. Durations are numbers in seconds.
]]

local Money = {}

-- --- First-join + caps ---------------------------------------------------

-- Currency granted on first join. String-backed BigNumber.
-- Type: string (decimal). Required: yes.
-- Server authoritative: YES (seed only; never touches live balances).
-- Safe to change: YES — affects new players only.
-- Tuned for a fast, exciting start: 5,000 buys the first eggs
-- plus the first upgrades immediately, so the opening minutes
-- are action, not waiting. Six figures would skip the entire
-- early game, so do NOT raise this without re-solving early
-- progression.
Money.StartingMoney = '5000'

-- Per-player Money cap. String-backed BigNumber. Anti-exploit
-- ceiling for EconomyService.AddMoney: any grant that would push
-- the balance above this is clamped with Code = 'cap-exceeded'.
-- Type: string (decimal). Required: yes.
-- Safe to change: YES, but lowering it does NOT take money away —
-- it only clamps future grants.
Money.MaxMoney = '1000000000000000'

-- --- Income tick ----------------------------------------------------------

-- Seconds between IncomeService accumulation ticks. The tick uses
-- a monotonic os.clock() delta, so this is a CADENCE, not an assumed
-- tick length — a slow server still credits exact real-elapsed time.
-- Type: number. Required: yes. Valid range: > 0. Unit: seconds.
-- Increase: choppier pool growth, fewer wakeups. Decrease: smoother
-- growth, more wakeups. Never changes the RATE (per-second income
-- is owned by animal stats), only the update granularity.
-- Server authoritative: YES.
Money.IncomeTickSeconds = 1

-- Maximum offline earnings window, in seconds (3 hours). Offline
-- time beyond this is simply not paid. Applied per-Animal into its
-- CashPool at rejoin.
-- Type: number. Required: yes. Valid range: >= 0. Unit: seconds.
-- Server authoritative: YES.
Money.MaxOfflineSeconds = 3 * 60 * 60

-- Offline effectiveness: fraction of the player's live wallet
-- multiplier applied to offline earnings (balance pass: offline
-- should be useful for returning players at ~50% of equivalent
-- online income, never a replacement for active play). The live
-- tick earns rate x moneyMult; offline earns
-- rate x moneyMult x OfflineEffectiveness. Fractional remainders
-- are still dropped per animal (floor), as before.
-- Type: number. Required: yes. Valid range: 0..1. Unit: scalar.
-- Server authoritative: YES.
Money.OfflineEffectiveness = 0.5

-- How often (seconds) the income tick refreshes the player's
-- LastSeen stamp while online. Bounds staleness after a server
-- crash (worst case: lose at most this much offline credit).
-- Type: number. Required: yes. Valid range: > 0. Unit: seconds.
Money.OfflineHeartbeatSeconds = 60

-- --- Collection ------------------------------------------------------------

-- Minimum seconds between successful CashCollector touches from
-- the same player. Multi-body-part touches land in the same
-- instant; this debounce collapses them into one collection.
-- Type: number. Required: yes. Valid range: >= 0. Unit: seconds.
-- Gameplay-adjacent (feel), NOT a security boundary.
Money.CollectorDebounceSeconds = 0.25

-- Minimum seconds between replicated CashPool attribute updates
-- on a collector part. Display-only throttle (accumulation runs on
-- the income tick with real-elapsed math); collection and offline
-- application force an immediate publish regardless.
-- Type: number. Required: yes. Valid range: >= 0. Unit: seconds.
-- Presentation only: safe to tune freely.
Money.CashPoolAttributeThrottleSeconds = 1

-- --- Cross-catalog invariants (DOCUMENTED, owned elsewhere) ---------------

-- INVARIANT 1 — egg price vs L1 sell value: EggConfig.Price[rarity]
-- MUST equal AnimalConfig.SellBaseValue[rarity] for every rarity
-- (100/500/1000/5000/25500/50000/100000/50000). Design: a level-1
-- animal liquidates for 75% of its egg cost (the uniform
-- Animals.SellMultiplier haircut — a deliberate loss so
-- hatch-and-sell can never print money; per-egg expected
-- recovery simulates at 70-85% — see the balance report).
-- Retune price table, sell bases, sell factor, trait-sell, and
-- hatch weights TOGETHER or the recovery band silently breaks.
-- Enforced by the consistency spec.
--
-- INVARIANT 2 — income ladder: AnimalConfig.Stats.Income.Base is a
-- third parallel ladder over the same rarities. It is NOT pegged to
-- prices (income is per-second flow, price is stock), but keep the
-- ordering monotonic or rarity progression feels broken.
--
-- INVARIANT 3 — arena cash: ArenaConfig LEVELS Rewards.FirstClearCash
-- / RepeatCash are BigNumber decimal STRINGS (never numbers) and are
-- ACCUMULATED per cleared stage, settling ONCE at raid end. Never
-- pay stages out directly.

-- --- Validation -------------------------------------------------------------

function Money.Validate(): { string }
	local issues: { string } = {}
	local function money(name: string, v: any)
		if type(v) ~= 'string' or v == '' or tonumber(v) == nil then
			issues[#issues + 1] = name .. ' must be a BigNumber decimal string'
		end
	end
	money('StartingMoney', Money.StartingMoney)
	money('MaxMoney', Money.MaxMoney)
	local function positiveSeconds(name: string, v: any, allowZero: boolean)
		if type(v) ~= 'number' or v ~= v or v < 0 or (not allowZero and v <= 0) then
			issues[#issues + 1] = name .. ' must be a number ' .. (if allowZero then '>= 0' else '> 0')
		end
	end
	positiveSeconds('IncomeTickSeconds', Money.IncomeTickSeconds, false)
	positiveSeconds('MaxOfflineSeconds', Money.MaxOfflineSeconds, true)
	positiveSeconds('OfflineHeartbeatSeconds', Money.OfflineHeartbeatSeconds, false)
	positiveSeconds('CollectorDebounceSeconds', Money.CollectorDebounceSeconds, true)
	positiveSeconds('CashPoolAttributeThrottleSeconds', Money.CashPoolAttributeThrottleSeconds, true)
	return issues
end

return table.freeze(Money)
