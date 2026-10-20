# Upgrades — MEMORY

Dense engineering notes for a future agent. Everything here was read
out of the source; nothing is assumed.

---

## Purpose in one line

Sell one extra level for one owned animal, at a cost the server
derives exactly, with the wallet debited atomically.

---

## How it actually works

### Two modules, one growth number

| Module | Owns |
|---|---|
| `ServerScriptService/UpgradeService.lua` | The **money** curve and the transaction. |
| `ReplicatedStorage/Config/Creatures/Progression.lua` | The **XP** curve, the level ceiling, the points formula, and `Normalize`. |

Both curves use the same `1.12` growth. `UpgradeService` asserts it
at load (`UpgradeService.lua:69-72`):

```lua
assert(
    LevelConfig.XP.GrowthRate == 1.12,
    'Progression.XP.GrowthRate drifted from 1.12: update UpgradeService exact math'
)
```

This is a **hard require-time crash**, not a warning. If you retune
the growth rate you must update the integer math at the same time.

### The cost formula

```
UpgradeCost(L -> L+1) = AnimalBasePrice × 1.12^(L-1)
AnimalBasePrice       = AnimalConfig.SellBaseValue[rarity]
```

`AnimalBasePrice` is the **configured base price of the definition**
— not the sale value, not the pool, not the income, not the player's
money. `GetBasePrice` (`UpgradeService.lua:131-144`) reads
`AnimalConfig.Get(definitionId)` to get the rarity, then
`AnimalConfig.SellBaseValue[rarity]`, and validates that it is a
finite positive integer before `BigNumber.sanitize`-ing it to a
string.

`level >= MaxLevel` → `nil`. **There is no price for 100 -> 101.**

### The exact-decimal engine (`GetUpgradeCost`, `UpgradeService.lua:151-213`)

This is the cleverest part of the system. `1.12 = 28/25`, so with
`k = level - 1`:

```
cost = base × 28^k / 25^k
```

The implementation, in order:

1. `num = base`, multiplied by `28` exactly `k` times.
2. `den = '1'`, multiplied by `25` exactly `k` times.
3. `scaled = num`, multiplied by `10` exactly `2k` times.
4. `quotient = BigNumber.Divide(scaled, den)` — an **exact integer
   division** (BigNumber.Divide throws on a fractional divisor or a
   zero divisor; here the divisor is `25^k` and the dividend is
   `10^2k × num`, and `25^k = 5^2k` divides `10^2k` exactly, so the
   division is exact).
5. The decimal point is inserted by **string slicing**: `2k` digits
   from the right. The quotient is zero-padded until it is longer
   than `2k` digits.
6. `BigNumber.sanitize(intPart .. '.' .. fracPart)`.

**Zero floating point anywhere.** Every step is a BigNumber integer
multiply or an exact division. The result is the exact terminating
decimal — `'1254.4'`, never `'1254.4000000001'`.

Why the `10^(2k)` scaling works: `25^k = 5^(2k)`, and `5^(2k)`
divides `10^(2k)` exactly. So `10^(2k) / 25^k` is an integer, and
the quotient is exactly `value × 10^(2k)` — the decimal expansion
shifted.

**The generalization trap:** this only works because 25 is a product
of 2s and 5s. If you change the growth rate to, say, 1.15 (23/20),
you need `10^(2k)` to become `10^(2k)` still (20 = 2²×5, so
`20^k = 2^(2k) × 5^k` divides `10^(2k)`) — but for a denominator with
a prime factor other than 2 or 5 the terminating-decimal trick
breaks and you need a different approach.

**Cost of the computation:** `O(k)` BigNumber multiplies. At level
99, `k = 98`, so ~300 multiplies per call. `StandDisplayService`
calls it per stand per refresh. It is exact but not free.

### `_validLevel`

```lua
type(level) == 'number' and level == math.floor(level) and level >= 1 and level <= LevelConfig.MaxLevel
```

`GetUpgradeCost` returns `nil` for a level outside `1..MaxLevel`.
Note the contrast: `Progression.GetXPRequired` **throws** for the
same class of input.

### The transaction (`UpgradeAnimal`, `UpgradeService.lua:259-432`)

The order is exact, and every step is a `return` (no fallthrough):

1. `Validation.LivePlayer(player)` → `invalid-player`.
2. `animalId` is a non-empty string → `invalid-id`.
3. All five service refs are set (`_wired()`) → `service-unavailable`.
4. `animalServiceRef.Get(animalId)` → `not-found`.
5. `animal.ownerUserId == userId` → `not-owner`.
6. `animal._mutex` is not set → `busy`. **Then it IS set.**
7. `animal.state` is not `Consumed` / `Destroyed` / `Carried` →
   `invalid-state`.
8. `ArenaService.IsAnimalRaidLocked(animalId)` → `busy` (the same
   code as the mutex; a raid-locked animal reports as busy).
9. `animal.definitionId` is a non-empty string → `invalid-definition`.
10. `AnimalConfig.Get(definitionId)` resolves a rarity →
    `invalid-definition`.
11. `animal.Level` passes `_validLevel` → `invalid-level`.
12. `animal.Level < MaxLevel` → `max-level`.
13. **Live slot match**: `slotServiceRef.FindSlotByOccupant(animalId)`
    returns a slot whose `state == 'Occupied'`, whose
    `occupantId == animalId`, and whose `ownerUserId == userId` →
    `slot-state`. This rejects walking/released/cross-base animals.
    Arena stands are first-class slots and upgrade through this path.
14. **Base ownership** (defense in depth): if `baseServiceRef.GetBaseById`
    exists, the base's `ownerUserId` must be the buyer → `not-owner`.
15. `GetUpgradeCost(definitionId, level)` → `no-cost`.
16. **The debit**: `economyServiceRef.TrySpendMoney(userId, cost, TransactionReason.AnimalUpgrade)`.
    - `spent.Code == 'insufficient'` → `insufficient` (with the
      server-calculated shortfall for the message).
    - Any other failure → `grant-failed`.
    - **Nothing is mutated on failure.**
17. **The mutation**: `animalServiceRef.ApplyLevelUpgrade(animalId)`.
    - If it fails, the code **cannot un-spend the money** (there is
      no "set" or "refund" API on `EconomyService`), so it warns
      loudly (`'UPGRADE PAID BUT LEVEL NOT APPLIED — manual review
      required'`) and returns `grant-failed`. It does **not** silently
      swallow the money.
18. `animal._mutex = false`.
19. **Push**: `baseServiceRef.Snapshot(userId)` → `playerServiceRef.PushState(player, snap)`.
20. **Success toast**: `NotificationService.NotifySuccess(player, 'Upgrade_Success', { AnimalName, Level, Rarity })`.
21. `playerServiceRef.BumpStat(userId, 'UpgradesApplied')` — the
    lifetime counter, **once per committed upgrade**.
22. `TutorialSignals.Fire('AnimalUpgraded', { UserId, AnimalId, NewLevel })`.
23. Funnel analytics: `FirstAnimalUpgraded` (once per session, under
    both `'Progression'` and `'Upgrade'` funnels) and
    `UpgradeSucceeded` (every success), with a `level_band` from
    `FunnelService.LevelBand(newLevel)`.
24. Return `{ success = true, animalId, oldLevel, newLevel, upgradeCost, remainingMoney }`.

### The mutex

`animal._mutex` lives on the **AnimalService runtime record**, not on
the profile record. It is set at step 6 and cleared on every exit
path (the `abort` closure clears it; the success path clears it
explicitly; the "paid but not applied" path clears it explicitly
before returning).

The spec's double-click test proves the important property: two
rapid calls charge the **current-level** cost each time (`'100'` then
`'112'`), because the cost is recalculated per request from the
animal's *current* level — not from a stale snapshot.

### The spend-then-mutate order

The header calls this out explicitly (§21): it mirrors the sale
pattern. The debit is atomic (`TrySpendMoney` is a compare-then-debit
with no yield in the critical section), and the level mutation is
infallible after the pre-validation. **There are no yields in the
critical section.**

### The shortfall

`_upgradeShortfall(userId, cost)` computes
`BigNumber.Subtract(cost, money)` — the server-calculated difference,
never a client value. It is passed to the notification as
`{ Amount = shortfall }`.

### `ApplyLevelUpgrade` (in `AnimalService`)

The service-side mutation. It:

- rejects a `Consumed` / `Destroyed` animal → `{ success = false, error = 'invalid-state' }`;
- rejects a level outside `1..MaxLevel-1` → `'invalid-level'`;
- sets `animal.Level = level + 1`;
- **mirrors the level into the profile record** — it walks
  `profileData.Brainrots` and writes `rec.Level = newLevel` on the
  record whose `Id` matches;
- fires the level-up presentation (`LevelUpPresentation.NotifyLevelUp`)
  in a `pcall` — a presentation failure logs and does not break the
  mutation;
- refreshes the overhead;
- refreshes the slot display (so the stand's cost readout updates).

Note the calling convention: `ApplyLevelUpgrade` is a **dot**
function (`AnimalService.ApplyLevelUpgrade(id)`), while `GetLevel`,
`GetXP`, and `AddXP` are **colon** functions
(`AnimalService:GetLevel(id)`). Easy to get wrong.

### `Progression.Normalize(level, xp)`

The single level-up drain loop. `(level, xp) -> (level, xp, levelsGained)`.

1. **Repairs the level**: a non-number, NaN, infinite, fractional, or
   `< 1` value becomes `1`. A level `> MaxLevel` is **clamped** to
   `MaxLevel` (the data is preserved, not reset).
2. **Repairs the XP**: a non-number, NaN, infinite, fractional, or
   negative value becomes `0`.
3. **Drains thresholds** while `level < MaxLevel` and
   `xp >= GetXPRequired(level)`. Each drain subtracts the threshold,
   increments the level, and counts a level gained.
4. **At `MaxLevel`** the XP is capped at `GetXPRequired(MaxLevel)` —
   the "bank" for a possible future cap raise. Grants beyond the
   ceiling are deterministically discarded.

Never throws, never yields. The loop is bounded by `MaxLevel`, so a
malformed config cannot create an infinite loop.

**XP is current progress, not lifetime XP.** Crossing a threshold
consumes it and carries the overflow: Level 1 with 340 XP and a 200
threshold becomes Level 2 with 140 XP.

### `Progression.GetXPRequired(level)`

`floor(200 × 1.12^(level-1) + 0.5)` — **round-half-up, applied
exactly once**, at the config boundary. The thresholds are
`200, 224, 251, 281, 315, ...`.

**Throws** (`error(...)`, level 0) for a level that is not an integer
in `1..MaxLevel`. The comment says: "callers passing a bad level is a
programming error, not runtime data."

### `Progression.GetPointsForLevel(level)`

`3 × (level - 1)`. L1 = 0, L2 = 3, L100 = 297. **Throws** for an
out-of-domain level, same as `GetXPRequired`.

### `Progression.GetMaxPoints()`

`3 × (100 - 1) = 297`. Never throws.

### The `Progression` require-time validation

`validate()` (`Progression.lua:99-140`) runs **once at require time**
and `error()`s on:

- a missing `XP` table;
- a non-finite or non-positive `XP.BaseRequired`;
- a non-finite or `< 1` `XP.GrowthRate`;
- a non-integer or `< 1` `MaxLevel`;
- a non-integer or negative `PointsPerLevel`;
- **an XP curve that overflows the exact-integer range** — it walks
  all 100 levels and errors if any threshold is NaN, infinite, or
  `>= 2^53`.

This is the **opposite convention** from every other config in the
library, which returns a list of issues from a non-throwing
`Validate()`.

### `Progression.AdminLevelCap = 99`

The `/setlevel` admin ceiling — deliberately **one below**
`MaxLevel`. The comment says it "stays one below by explicit design
(was MaxAnimalLevel = 99)".

---

## Public API surface (exact)

### `UpgradeService`

```lua
UpgradeService.Error: { [string]: string }   -- 15 codes
UpgradeService.SetPlayerService(ps: any): ()
UpgradeService.SetSlotService(ss: any): ()
UpgradeService.SetBaseService(bs: any): ()
UpgradeService.SetAnimalService(svc: any): ()
UpgradeService.SetEconomyService(es: any): ()
UpgradeService.GetBasePrice(definitionId: string): string?
UpgradeService.GetUpgradeCost(definitionId: string, level: number): string?
UpgradeService.UpgradeAnimal(player: Player, animalId: string): { [string]: any }
```

`UpgradeService.Error` values:
`'invalid-player'`, `'invalid-id'`, `'not-found'`, `'not-owner'`,
`'busy'`, `'invalid-state'`, `'not-animal'`, `'invalid-definition'`,
`'invalid-level'`, `'max-level'`, `'no-cost'`, `'slot-state'`,
`'insufficient'`, `'grant-failed'`, `'service-unavailable'`.

Note: `'not-animal'` is declared but **never returned** by any code
path. `'insufficient'` and `'grant-failed'` both surface as
`grant-failed` at the `TrySpendMoney` layer — the service maps the
`insufficient` code explicitly and everything else to `grant-failed`.

### `Progression` (`ReplicatedStorage/Config/Creatures/Progression`)

```lua
Progression.MaxLevel: number            -- 100
Progression.XP: { BaseRequired: number, GrowthRate: number }  -- frozen
Progression.PointsPerLevel: number      -- 3
Progression.AdminLevelCap: number       -- 99
Progression.GetXPRequired(level: number): number       -- THROWS
Progression.GetPointsForLevel(level: number): number   -- THROWS
Progression.GetMaxPoints(): number
Progression.Normalize(level: any, xp: any): (number, number, number)
```

---

## Invariants the code enforces

1. **The client never supplies a cost or a level.** Both are
   re-derived server-side on every request.
2. **The cost is exact.** Zero floating point, and the same inputs
   always produce the same string.
3. **The cost at `MaxLevel` does not exist.** `GetUpgradeCost` returns
   `nil` for `level >= MaxLevel`.
4. **The cost is monotonically increasing** in the level.
5. **The growth rate is pinned to 1.12** by a require-time `assert`.
6. **All five service refs are required.** Otherwise every upgrade is
   `service-unavailable`.
7. **The animal must exist, be owned, and be in a valid state.**
8. **The animal must be on a live `Occupied` slot owned by the
   buyer.** Walking / released / cross-base animals are rejected.
9. **The base must be owned by the buyer** (defense in depth).
10. **A raid-locked animal cannot be upgraded** — the raid fights on
    a frozen snapshot.
11. **The debit happens before the mutation**, and the debit is
    atomic: a failed debit mutates nothing.
12. **The level is the only thing that changes.** XP, CashPool, Id,
    DefId, SlotId, mutations, and traits are all preserved.
13. **The cost is never persisted.** It is re-derived from `Level`.
14. **The cost is recalculated per request** from the animal's
    *current* level — a double click charges the second level's price.
15. **A money multiplier never changes the cost.** `ModifierService`
    is never consulted.
16. **The `UpgradesApplied` counter increments exactly once per
    committed upgrade** — after both the debit and the mutation.
17. **The success toast fires only after the level commit.**
18. **The max level is a hard stop in `Normalize`** — the drain loop
    cannot pass `MaxLevel`.
19. **XP at `MaxLevel` is banked, not discarded** — capped at
    `GetXPRequired(MaxLevel)`.
20. **A malformed `(level, xp)` pair is repaired, not rejected** —
    `Normalize` always returns a valid state.

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| A dead player | `{ success = false, error = 'invalid-player' }` |
| An empty / non-string `animalId` | `'invalid-id'` |
| A service not wired | `'service-unavailable'` |
| An unknown animal id | `'not-found'` |
| Someone else's animal | `'not-owner'` |
| An upgrade already in flight | `'busy'` |
| A `Consumed` / `Destroyed` / `Carried` animal | `'invalid-state'` |
| A raid-locked animal | `'busy'` |
| A missing or unknown definition | `'invalid-definition'` |
| A malformed level on the record | `'invalid-level'` |
| Level 100 | `'max-level'` |
| No live owned slot | `'slot-state'` |
| The cost cannot be derived | `'no-cost'` |
| Not enough money | `'insufficient'` — nothing mutated |
| A non-insufficient spend failure | `'grant-failed'` |
| The level mutation failed after a successful debit | `'grant-failed'` **plus a loud warning** — the money is spent and lost |
| `GetUpgradeCost` with a bad definition / level | `nil` |
| `GetBasePrice` with a bad definition | `nil` |
| `GetXPRequired` with a bad level | **throws** |
| `GetPointsForLevel` with a bad level | **throws** |
| `Normalize` with anything | Never throws; always returns a valid triple |

**Error strings returned by `UpgradeAnimal`:**
`'invalid-player'`, `'invalid-id'`, `'service-unavailable'`,
`'not-found'`, `'not-owner'`, `'busy'`, `'invalid-state'`,
`'invalid-definition'`, `'invalid-level'`, `'max-level'`,
`'slot-state'`, `'no-cost'`, `'insufficient'`, `'grant-failed'`.

---

## Gotchas that would bite you

1. **`GetXPRequired` throws; `GetUpgradeCost` returns nil.** The
   same bad input, two different conventions, in the same system.
   Never call `Progression.GetXPRequired` from a client script
   without a `pcall`.

2. **`Progression` errors at require time.** A bad config is a hard
   server boot failure, not a returned issue list. This is the only
   config in the library that behaves this way.

3. **The `assert` on `GrowthRate == 1.12` is also a boot failure.**
   Retuning the XP curve without retuning the upgrade curve takes the
   whole server down.

4. **`GetUpgradeCost` is `O(level)` BigNumber multiplies.** At level
   99 that is ~300 multiplies per call, and the stand display calls
   it per stand per refresh. If you profile and it shows up, cache it
   — but never persist it (the spec asserts `rec.UpgradeCost` must be
   nil).

5. **The `10^(2k)` scaling only works for 2/5-smooth denominators.**
   25 = 5². If you change the growth rate, re-derive the scaling
   factor.

6. **`ApplyLevelUpgrade` is a dot function; `GetLevel` / `GetXP` /
   `AddXP` are colon functions.** `AnimalService.ApplyLevelUpgrade(id)`
   vs `AnimalService:GetLevel(id)`.

7. **The profile record's `Level` is written by `AnimalService`, not
   by `UpgradeService`.** `UpgradeService` never touches the profile
   directly — it calls `ApplyLevelUpgrade`, which mirrors the level
   into the record. If you replace `ApplyLevelUpgrade`, you must keep
   the mirroring.

8. **The `_mutex` is on the runtime record.** If the runtime animal
   is destroyed mid-transaction, the lock goes with it. The debit is
   atomic, so the worst case is "money spent, level not applied",
   which the code warns about rather than hides.

9. **A raid lock reports as `busy`,** not as a distinct code, and the
   player sees the "Busy" message. Do not write UI that expects a
   raid-specific code.

10. **An upgrade does not touch the `CashPool` or the XP.** The spec
    asserts both explicitly. If you add a side effect (say, resetting
    XP), you break the "the paid level survives an XP grant" test.

11. **`EconomyService` has no refund / set API.** Only `AddMoney`
    (a grant) and `TrySpendMoney` (a debit). A refund is a grant.

12. **`TrySpendMoney` needs the `TransactionReason` to be in the
    closed enum.** `TransactionReason.AnimalUpgrade` exists. If you
    add a reason you must add it to **both** the table and the `_ALL`
    list in `ReplicatedStorage/Types/TransactionReason.lua`, or the
    spend is rejected with `'invalid-reason'`.

13. **The notification ids are catalog keys.**
    `Upgrade_Success`, `Upgrade_InsufficientCash`, `Upgrade_MaxLevel`,
    `Upgrade_NotOwner`, `Upgrade_InvalidTarget`, `Upgrade_Busy`,
    `Upgrade_InvalidRequest`, `Upgrade_Unavailable`, `Upgrade_Failed`,
    `Upgrade_Dead` — they live in
    `ReplicatedStorage/Config/Presentation/Messages.lua`. A missing
    key means the toast does not show (the notify is `pcall`-guarded,
    so the transaction still succeeds).

14. **`_wired()` requires all five refs, including `baseServiceRef`**
    — even though the base check is written as "if
    `baseServiceRef.GetBaseById` exists". You cannot omit the base
    service and still have upgrades work.

15. **The upgrade cost and the sale value share a base.**
    `AnimalConfig.SellBaseValue[rarity]` is used by both. Retuning
    the price table moves both curves.

16. **The Level-1 cost is always exactly the base** (`1.12^0 = 1`).
    The config comment calls this the "early-game pacing anchor" and
    notes it is "growth-independent".

---

## What to change to reuse it

- **The price table:** change `UpgradeService.lua:139`
  (`AnimalConfig.SellBaseValue[rarity]`) to point at your own table.
  Nothing else in the engine needs to know what the number means.
- **The growth rate:** change `Progression.XP.GrowthRate` **and**
  `UpgradeService`'s integer math **and** the `assert` — all three,
  together. The general form is `base × g_num^k / g_den^k` scaled by
  `10^(d×k)` where `d` is the number of decimal places in `g_num/g_den`
  and `g_den` is 2/5-smooth.
- **The level ceiling:** `Progression.MaxLevel`. The overflow check
  re-runs at require time. Remember `UpgradeService.GetUpgradeCost`
  returns nil at `MaxLevel`, so the last purchasable level is
  `MaxLevel - 1`.
- **No XP track:** delete `Progression.Normalize`, `GetXPRequired`,
  and the `XP` table (but `AnimalService` also reads them).
- **No points:** `PointsPerLevel = 0`.
- **No arena:** delete the `ArenaService` require and the raid-lock
  check.
- **No tutorial layer:** delete the `TutorialSignals` require and the
  `Fire` call.
- **No funnel:** delete the `FunnelService` require and its `pcall`
  block.
- **A different request path:** the service has no remote of its
  own. Call `UpgradeService.UpgradeAnimal(player, animalId)` from
  wherever you want and fire the result back.
- **A refund path:** there is none. Add one after the mutation:
  `EconomyService.AddMoney(userId, cost, TransactionReason.AdminGive)`.
