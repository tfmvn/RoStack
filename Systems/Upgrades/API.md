# Upgrades — API

Every public function of every module in the Upgrades system.
Signatures are verbatim from the source.

**Error conventions differ between the two modules and this is not a
mistake in the docs — it is in the code:**

- `UpgradeService` **never throws**. Failures are returned as
  `{ success = false, error = <code> }` or as `nil`.
- `Progression.GetXPRequired` and `Progression.GetPointsForLevel`
  **throw** on an out-of-domain level (they treat it as a
  programming error).
- `Progression.Normalize` never throws.

---

## `ServerScriptService.UpgradeService`

The ONE authority for paid animal level upgrades.

### Error codes

```lua
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
```

`'not-animal'` is declared but **never returned** by any code path.

---

### `UpgradeService.Init()`

**Does not exist.** The service has no `Init`. All wiring is through
the `Set*Service` setters.

---

### `UpgradeService.SetPlayerService(ps: any)` / `SetSlotService(ss: any)` / `SetBaseService(bs: any)` / `SetAnimalService(svc: any)` / `SetEconomyService(es: any)`

Late-bound service injection. **All five are required** — a missing
one makes every upgrade return `service-unavailable`.

| Setter | The service must provide |
|---|---|
| `SetPlayerService` | `GetPlayerData(userId)`, `PushState(player, snapshot?)`, `BumpStat(userId, stat)` |
| `SetSlotService` | `FindSlotByOccupant(occupantId)` -> the slot record |
| `SetBaseService` | `GetBaseById(baseId)` (optional — the check is skipped if absent, but the ref itself is required), `Snapshot(userId)` |
| `SetAnimalService` | `Get(uniqueId)` -> the runtime record, `ApplyLevelUpgrade(uniqueId)` -> `{ success, oldLevel, newLevel }` |
| `SetEconomyService` | `TrySpendMoney(userId, cost, reason)` -> an `EconomyResult` |

**Returns:** nothing. **Throws:** never.

---

### `UpgradeService.GetBasePrice(definitionId: string): string?`

The configured base price for an animal definition, as a canonical
BigNumber integer string.

**Parameters:** `definitionId` — a catalogue definition id.

**Returns:** the base price as a decimal string, e.g. `'100'` for a
Common animal. Returns `nil` when:

- `definitionId` is not a string, or is empty;
- `AnimalConfig.Get(definitionId)` does not resolve a rarity;
- the rarity's `SellBaseValue` is missing, is not a number, is NaN, is
  not an integer, is `<= 0`, or is `math.huge`.

**Throws:** never. The `AnimalConfig.Get` call is `pcall`-guarded.

---

### `UpgradeService.GetUpgradeCost(definitionId: string, level: number): string?`

**THE authoritative upgrade cost.** `(definitionId, current level) ->
the exact decimal price of the next level`.

**Parameters:**
- `definitionId` — the animal's definition id.
- `level` — the animal's **current** level. The price returned is for
  `level -> level + 1`.

**Returns:** the exact decimal string, e.g. `'100'` (L1 of a Common),
`'112'` (L2), `'125.44'` (L3), `'157.351936'` (L5),
`'176.23416832'` (L6), `'1254.4'` (L3 of a 1000-base), `'112000'`
(L2 of a 100000-base).

Returns `nil` when:
- `level` is not a number, is not an integer, is `< 1`, or is
  `> MaxLevel`;
- `level >= MaxLevel` — **there is no price for 100 -> 101**;
- the base price cannot be derived;
- any step of the exact arithmetic fails (a `BigNumber` overflow).

**The result is deterministic and exact.** The same inputs always
produce the same string. The computation is
`base × 28^k / 25^k` with `k = level - 1`, scaled by `10^(2k)` and
divided exactly — **zero floating point at any step**.

**Throws:** never. Every `BigNumber` call is `pcall`-guarded.

**Cost:** `O(level)` BigNumber multiplies. At level 99 that is ~300
multiplies per call.

---

### `UpgradeService.UpgradeAnimal(player: Player, animalId: string): { [string]: any }`

Buys one level for an owned animal.

**Parameters:**
- `player` — the buyer.
- `animalId` — the runtime animal's unique id.

**Returns, on success:**

```lua
{
    success = true,
    animalId = string,
    oldLevel = number,
    newLevel = number,
    upgradeCost = string,       -- the exact BigNumber cost charged
    remainingMoney = string,    -- the wallet after the debit
}
```

**Returns, on failure:** `{ success = false, error = <code> }`.

**Failure codes:**

| Code | Cause |
|---|---|
| `invalid-player` | `Validation.LivePlayer(player)` failed. |
| `invalid-id` | `animalId` is not a non-empty string. |
| `service-unavailable` | Not all five service refs are set. |
| `not-found` | `AnimalService.Get(animalId)` returned nothing. |
| `not-owner` | The animal belongs to another player, or its base does. |
| `busy` | An upgrade is already in flight (`animal._mutex`), **or** the animal is raid-locked. |
| `invalid-state` | The animal is `Consumed`, `Destroyed`, or `Carried`. |
| `invalid-definition` | The definition id is missing, empty, or not in the catalogue. |
| `invalid-level` | The animal's level is not an integer in `1..MaxLevel`. |
| `max-level` | The animal is already at `MaxLevel`. |
| `slot-state` | The animal is not on a live `Occupied` slot owned by the buyer. |
| `no-cost` | The cost could not be derived. |
| `insufficient` | Not enough money. **Nothing was mutated.** |
| `grant-failed` | The spend failed for a non-insufficient reason, **or** the debit succeeded but the level mutation failed. |

**On success** the service also: pushes the fresh `PlayerState`, fires
the `Upgrade_Success` toast, bumps `Stats.UpgradesApplied`, fires the
`AnimalUpgraded` tutorial signal, and logs the funnel steps
(`FirstAnimalUpgraded` under two funnels, `UpgradeSucceeded`).

**On a "paid but not applied" failure** (the debit succeeded and
`ApplyLevelUpgrade` then failed) the service **cannot refund** — the
money is spent and lost. It logs a loud warning
(`'UPGRADE PAID BUT LEVEL NOT APPLIED — manual review required'`)
rather than silently swallowing it, and returns `grant-failed`.

**Throws:** never.

**Concurrency:** a per-animal mutex on the runtime record makes
double-clicks safe. The cost is **recalculated per request** from the
animal's current level, so two rapid upgrades charge the Level-1 price
and then the Level-2 price — never the same price twice, and never a
skipped level.

---

## `ReplicatedStorage.Config.Creatures.Progression`

The canonical level / XP configuration. Pure: no services, no
instances, no remotes. Lives in `ReplicatedStorage`, so it is
client-safe.

### Constants

```lua
Progression.MaxLevel = 100
Progression.XP = { BaseRequired = 200, GrowthRate = 1.12 }   -- frozen
Progression.PointsPerLevel = 3
Progression.AdminLevelCap = 99
```

---

### `Progression.GetXPRequired(level: number): number`

The XP needed to advance FROM `level` TO `level + 1`.

**Parameters:** `level` — an integer in `1..MaxLevel`.

**Returns:** an integer. `XPRequired(L) = floor(BaseRequired ×
GrowthRate^(L-1) + 0.5)` — **round-half-up, applied exactly once**,
at this boundary. The shipped thresholds: L1 = 200, L2 = 224,
L3 = 251, L4 = 281, L5 = 315.

**Throws:** `error()` for a level that is not a number, is NaN, is
not an integer, is `< 1`, or is `> MaxLevel`. The message is
`'[Progression] GetXPRequired: level must be an integer in 1..100'`.

This is the **single rounding point** of the whole progression
system. No service, command, or test may round again.

---

### `Progression.GetPointsForLevel(level: number): number`

The level-derived progression points.

**Parameters:** `level` — an integer in `1..MaxLevel`.

**Returns:** `PointsPerLevel × (level - 1)`. With `q = 3`: L1 = 0,
L2 = 3, L3 = 6, L4 = 9, L100 = 297.

**Throws:** `error()` for an out-of-domain level. The message is
`'[Progression] GetPointsForLevel: level must be an integer in 1..100'`.

---

### `Progression.GetMaxPoints(): number`

The maximum investable points across the whole progression.

**Returns:** `PointsPerLevel × (MaxLevel - 1)` = `297`. Never throws.

---

### `Progression.Normalize(level: any, xp: any): (number, number, number)`

**THE single level-up drain loop.** No other service may compute
thresholds or drain level-ups.

**Parameters:** `level` and `xp` — any values, including malformed
persistence data.

**Returns:** `(level, xp, levelsGained)`.
- `level` is a repaired, valid level in `1..MaxLevel`.
- `xp` is a repaired, non-negative integer.
- `levelsGained` is how many thresholds were crossed.

**Behaviour:**
1. **Repairs the level**: a non-number, NaN, infinite, fractional, or
   `< 1` value becomes `1`. A level `> MaxLevel` is **clamped** to
   `MaxLevel` (the data is preserved, not reset).
2. **Repairs the XP**: a non-number, NaN, infinite, fractional, or
   negative value becomes `0`.
3. **Drains thresholds** while `level < MaxLevel` and
   `xp >= GetXPRequired(level)`, carrying the overflow into the next
   level. One call can cross many levels (e.g. `Normalize(1, 685)`
   -> level 4, XP 10, 3 levels gained).
4. **At `MaxLevel`** the XP is capped at `GetXPRequired(MaxLevel)` —
   the "bank" for a possible future cap raise. Grants beyond the
   ceiling are deterministically discarded.

**Throws:** never. **Yields:** never.

The loop is bounded by `MaxLevel`, so a malformed config can never
create an infinite loop.

**XP is current progress, not lifetime XP.** Crossing a threshold
consumes it.

---

## Not part of the public API

| Symbol | Why it is not public |
|---|---|
| `UpgradeService`'s `_validLevel`, `_fail`, `_reject`, `_upgradeShortfall`, `_wired` | Module-local helpers. |
| `Progression`'s `validate` and `MAX_EXACT_INTEGER` | The validation runs once at require time and is not callable afterwards. |
| `Progression.XP`'s table | It is `table.freeze`d, but the individual fields are readable tunables — change them in the source, not at runtime. |
| `UpgradeService.Error.NotAnimal` | Declared but never returned. |

---

## Related APIs you will need

These live in other systems, but the upgrade transaction calls them.

### `EconomyService.TrySpendMoney(userId, cost, reason, opts?)` — Economy system

The atomic debit. Returns an `EconomyResult`:
`{ Success, NewMoney?, Reason, Code?, TransactionId? }`. The `Code` is
`'insufficient'` when the wallet is short. **It never throws** and it
never mutates anything on failure.

### `AnimalService.ApplyLevelUpgrade(uniqueId)` — Animals system

**A dot function, not a colon function** (`AnimalService.GetLevel`
and `AnimalService.GetXP` are colon functions).

Returns `{ success = true, oldLevel, newLevel }` or
`{ success = false, error = 'no-animal' | 'invalid-state' | 'invalid-level' }`.
On success it also mirrors the new level into the profile record and
fires the level-up presentation.

### `AnimalService:GetLevel(uniqueId)` / `AnimalService:GetXP(uniqueId)` — Animals system

**Colon functions.** Return the runtime level / XP, or `nil` for an
unknown animal.
