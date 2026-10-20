# Upgrades

**A server-authoritative "pay money to raise one animal's level" system, with an exact-decimal cost curve that has zero floating-point error and is guaranteed identical on the server, in the UI, and after a rejoin.**

**Portability:** Grade **A — portable core**, with a Grade B content binding. The *cost engine* — the exact `base × 1.12^(L-1)` decimal arithmetic, the spend-then-mutate transaction, the fail-closed validation ladder, and the per-animal mutex — is entirely game-agnostic. The Grade B part is the **base price source**: the cost is derived from `AnimalConfig.SellBaseValue[rarity]`, so the system is coupled to a rarity-tiered animal catalogue. Swapping the catalogue means swapping that one lookup. Nothing is platform-bound — no Robux, no HTTP, no DataStore of its own.

**Source game:** Brainrot Arena (p-7)

---

## What It Does

Buying a **level** for an animal. The client may say "upgrade this
animal"; it may never say how much it costs or what level it will
reach. The server re-derives both from authoritative state and
debits the wallet atomically.

The upgrade **keeps** everything else: the XP progress toward the
next level, the animal's uncollected `CashPool`, its slot, its id,
its definition, and its mutations. The level is the only thing that
changes.

The system is deliberately narrow. It does **not** own XP (that is
`AnimalService` + `Progression.Normalize`), it does not own stats
(those are derived by `AnimalStats.Calculate` from the level), it
does not own income or sell value (both derive from the level through
the existing calculators), and it never consults `ModifierService` —
**a money multiplier does not change what an upgrade costs.**

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `UpgradeService.UpgradeAnimal(player, animalId)` | server service | The transaction. Returns `{ success = true, animalId, oldLevel, newLevel, upgradeCost, remainingMoney }` or `{ success = false, error = <code> }`. |
| `UpgradeService.GetUpgradeCost(definitionId, level)` | server service | **The one authoritative cost.** `(DefId, current level) -> exact decimal string` or `nil`. Pure — no services, no state. |
| `UpgradeService.GetBasePrice(definitionId)` | server service | The configured base price for a definition, as a BigNumber string. `nil` when unknown. |
| `UpgradeService.SetPlayerService` / `SetSlotService` / `SetBaseService` / `SetAnimalService` / `SetEconomyService` | server service | Late-bound injection. **All five are required** — otherwise every upgrade returns `service-unavailable`. |
| `UpgradeService.Error` | server service | The stable error-code table (15 codes). |
| `Progression.GetXPRequired(level)` | config | The XP threshold for `level -> level+1`. **Throws** on an out-of-domain level. |
| `Progression.GetPointsForLevel(level)` | config | `P(L) = q(L-1)`. **Throws** on an out-of-domain level. |
| `Progression.GetMaxPoints()` | config | `q × (MaxLevel - 1)` = `297`. |
| `Progression.Normalize(level, xp)` | config | The single level-up drain loop. `(level, xp) -> (level, xp, levelsGained)`. Never throws. |
| `Progression.MaxLevel` / `.XP` / `.PointsPerLevel` / `.AdminLevelCap` | config | The tunables. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/UpgradeService.lua` | `ServerScriptService/UpgradeService.lua` | The transaction and the cost engine. 435 lines. |
| `Source/ReplicatedStorage/Config/Creatures/Progression.lua` | `ReplicatedStorage/Config/Creatures/Progression.lua` | The XP curve, the level ceiling, the points formula, and `Normalize`. 249 lines. |
| `Tests/UpgradeCost.spec.lua` | (test tree) | The exact-decimal cost engine. 8 cases. |
| `Tests/UpgradeService.spec.lua` | (test tree) | The transaction, end-to-end against the real services. 8 cases. |
| `Tests/LevelProgression.spec.lua` | (test tree) | The XP curve, points formula, and `Normalize`. 20 cases. |

Shared modules used (from `ReusableSystems/Shared/`):

| Library file | Roblox destination | Purpose |
|---|---|---|
| `Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` | The exact decimal arithmetic and the money strings. |
| `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` | `Validation.LivePlayer`. |
| `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` | The logging channel (`'UP'`). |
| `Types/TransactionReason.lua` | `ReplicatedStorage/Types/TransactionReason.lua` | `TransactionReason.AnimalUpgrade`. |

---

## Configuration

The system has **its own config**: `ReplicatedStorage/Config/Creatures/Progression.lua`.
It owns the XP curve, the level ceiling, and the points formula.

| Value | Default | Meaning |
|---|---|---|
| `MaxLevel` | `100` | The hard level ceiling. Level 100 is the last level; there is no 101. |
| `XP.BaseRequired` | `200` | The XP needed to go Level 1 -> Level 2. |
| `XP.GrowthRate` | `1.12` | `XPRequired(L) = BaseRequired × GrowthRate^(L-1)`. **Pinned** — see below. |
| `PointsPerLevel` | `3` | `P(L) = 3 × (L-1)`. Level 1 = 0 points, Level 100 = 297. |
| `AdminLevelCap` | `99` | The `/setlevel` admin ceiling — deliberately **one below** `MaxLevel`. |

### The two-module relationship

`Progression.lua` owns the **XP** curve. `UpgradeService` owns the
**money** curve. They are deliberately coupled to the same growth
number:

```
UpgradeCost(L -> L+1) = AnimalBasePrice × 1.12^(L-1)
XPRequired(L -> L+1)  = 200 × 1.12^(L-1)
```

`UpgradeService` therefore `assert`s at load time that
`Progression.XP.GrowthRate == 1.12` (`UpgradeService.lua:69-72`). If
you retune the growth rate you **must** update `UpgradeService`'s
exact integer math (28/25) at the same time, or the require will
fail loudly. That is by design — the comment says "update
UpgradeService exact math".

### The `Progression` config is the odd one out

Every other config module in this library exposes a **non-throwing**
`Validate(): { string }` (`Money.lua`, `Rebirth.lua`, `Shop.lua`).
`Progression.lua` instead calls a private `validate()` at require
time and **`error()`s** on a bad configuration. The failure mode is a
hard require-time crash, not a returned issue list. It does check
more than the others do: it walks all 100 levels and `error()`s if the
curve would overflow the exact-integer range (`2^53`).

### A consolidated, documented view of these tunables is in
[`Config.lua`](Config.lua).

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the verbatim `require`
paths, the remotes, the profile fields, and the initialization order.

Summary: `UpgradeService` **directly requires** the two config
modules, `BigNumber`, `Validation`, `Debug`, `TransactionReason`,
`NotificationService`, `ArenaService`, `TutorialSignals`, and
`FunnelService`; it **injects** `PlayerService`, `SlotService`,
`BaseService`, `AnimalService`, and `EconomyService`.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  UpgradeService.SetPlayerService(PlayerService)
3.  UpgradeService.SetSlotService(SlotService)
4.  UpgradeService.SetBaseService(BaseService)
5.  UpgradeService.SetAnimalService(AnimalService)
6.  UpgradeService.SetEconomyService(EconomyService)
7.  --- players may now join ---
```

There is no `UpgradeService.Init()`. The service has no state to
create and no remote of its own.

**Consumers** that must be wired (they read the cost, they do not
perform the upgrade):

```lua
SlotMenuService.SetUpgradeService(UpgradeService)     -- the player's UI
StandDisplayService.SetUpgradeService(UpgradeService)  -- the stand readout
```

---

## Data

### Profile fields

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `Money` | string (BigNumber) | `EconomyService` (via `TrySpendMoney`) | Debited by the exact cost. `TransactionReason.AnimalUpgrade` is the audit reason. |
| `Brainrots[].Level` | number (integer) | `AnimalService.ApplyLevelUpgrade` | The only field the upgrade changes. The cost is **not** persisted — it is re-derived from `Level` on demand. |
| `Stats.UpgradesApplied` | number | `PlayerService.BumpStat` | A lifetime counter, incremented **once per committed upgrade**. |

### Untouched by design

The upgrade preserves: `Brainrots[].XP` (current progress toward the
next level), `Brainrots[].CashPool` (uncollected money),
`Brainrots[].Id`, `Brainrots[].DefId`, `Brainrots[].SlotId`,
mutations, and traits. The spec asserts all of these explicitly.

### Session state

| State | Where | Meaning |
|---|---|---|
| `animal._mutex` | the AnimalService runtime record | The per-animal upgrade lock. Set during the transaction, cleared on every exit path. |
| `UpgradeService`'s five service refs | module-local | The injection targets. |

---

## Known Limitations

1. **The price of a 100-level animal is astronomically large.** The
   cost at Level 99 is `base × 1.12^98` — for a Common base of 100
   that is roughly `7.6 × 10^10`, and for a Divine base of 100,000 it
   is roughly `7.6 × 10^13`. BigNumber handles it exactly, but the
   `MaxMoney` cap (`1e15`) means a Divine animal cannot actually
   reach the top levels by upgrading. That is a balance problem, not
   a bug, but it is worth knowing before you ship a 100-level ladder.

2. **A paid level can be undone by a bad `Normalize` call.**
   `Normalize` clamps a level above `MaxLevel` to `MaxLevel` and
   repairs a level below 1 to 1. A corrupted `Level` in the profile
   is therefore "repaired" rather than preserved. The upgrade path
   itself never triggers this — `ApplyLevelUpgrade` writes a valid
   integer — but a bad persistence layer could.

3. **`GetXPRequired` and `GetPointsForLevel` throw**, while
   `UpgradeService.GetUpgradeCost` returns `nil` for the same class
   of bad input. The two error conventions are inconsistent within
   the same system. If you call `Progression.GetXPRequired` from
   client code, wrap it in a `pcall`.

4. **`Progression.Normalize` can loop many times.** With
   `xp = 1e15` at Level 1 it drains 99 thresholds in one call. It is
   bounded by `MaxLevel`, so it cannot hang, but it is not free.

5. **The upgrade is not refundable.** There is no "sell the level
   back" path. A mis-click is permanent.

6. **The cost is not stored on the record.** The spec asserts
   `rec.UpgradeCost == nil` after an upgrade. Every read of "what
   does the next level cost" re-derives it. This is correct (there
   is no stale state) but it means the cost is recomputed on every UI
   refresh — `StandDisplayService` calls `GetUpgradeCost` per stand
   per refresh.

7. **A raid-locked animal cannot be upgraded, but the error code is
   `busy`, not a distinct raid code.** The player sees the "Busy"
   message.

8. **The `_mutex` is on the runtime record, not on the profile
   record.** If the runtime animal is destroyed mid-transaction the
   lock is lost with it. The window is tiny and the debit is atomic,
   but the theoretical outcome is "money spent, level not applied" —
   which the code handles by **warning loudly** rather than silently
   swallowing the money.

9. **There is no upgrade remote of its own.** The client reaches the
   service through `SlotMenuService`'s `SlotMenuAction` remote. If
   you copy `UpgradeService` without `SlotMenuService`, you must
   write your own request path.

10. **`UpgradeService` has no `Init()` and no `ForgetPlayer()`.** The
    service holds no per-player state, so there is nothing to clean
    up. The `animal._mutex` lives on the AnimalService record and is
    cleaned up with it.

11. **The `assert` on `GrowthRate == 1.12` is a hard require-time
    crash.** If you retune the growth rate without updating
    `UpgradeService`, the whole server fails to load. That is
    intentional (the comment says so) but it is a sharp edge.

---

## Testing

Three spec files, all TestEZ and Studio-only (there is no headless
Luau runner in this project).

**`UpgradeCost.spec.lua`** — the cost engine:
- L1 is exactly the base (`Chicken` -> `'100'`, `Chimpanzee` ->
  `'1000'`).
- Exact decimals at L2/L3/L4 (`'1120'`, `'1254.4'`, `'1404.928'`).
- A higher base rides the same curve (`Dragon` L2 -> `'112000'`).
- `nil` for a bad definition, an empty definition, level 0, a
  negative level, a fractional level, level `MaxLevel + 1`, **and
  level `MaxLevel` itself** (there is no 100 -> 101 price).
- Deterministic across repeated calls.
- Strictly monotonic from L1 to L99.
- **BigNumber-exact at L50**: `cost × 25^49` must string-equal
  `100 × 28^49` — a float path would smear the tail and fail.

**`UpgradeService.spec.lua`** — the transaction, against the **real**
`UpgradeService` + `EconomyService` + `AnimalService` +
`ModifierService` with hand-rolled fakes:
- A successful upgrade debits exactly, increments the level, and
  keeps XP / pool / id (Common L5 -> L6 costs `'157.351936'`).
- L99 -> L100 succeeds; L100 -> L101 fails with `'max-level'` and the
  money intact.
- Insufficient money fails with the money, level, XP, and pool all
  intact.
- A rapid double upgrade charges the **current-level** cost each
  time (`'100'` then `'112'`), never skips a level, and never goes
  negative.
- An egg, a wrong owner, a stale occupant, and an invalid definition
  are all rejected with nothing moved.
- A paid level survives an XP grant (no `Normalize` undo), and the
  stats follow the new level.
- Income, sell value, and the next cost all follow the new level.
- A 5x live multiplier and a legacy `Multipliers.Money = 10` change
  **nothing** about the cost.

**`LevelProgression.spec.lua`** — the XP curve and `Normalize`:
- The exact thresholds (`200`, `224`, `251`, `281`, `315`).
- Integers across the whole curve; strictly increasing.
- `GetXPRequired` **throws** on 0, `MaxLevel + 1`, and 1.5.
- `P(L) = 3(L-1)`: L1 = 0, L2 = 3, L4 = 9, L100 = 297.
- `Normalize`: partial progress preserved, exact threshold -> L+1
  with XP 0, overflow carried, multiple levels crossed in one call,
  a hard stop at `MaxLevel` with the XP bank capped at
  `GetXPRequired(MaxLevel)`.
- Malformed data repair: nil, negative, fractional, NaN, and infinite
  levels/XP all repaired; a level above `MaxLevel` is **clamped**, not
  reset.
- A consistency sweep over 16 sample pairs asserting
  `XP < R(level)` below `MaxLevel` and `XP <= R(MaxLevel)` at it.

The specs need **no DataStore, no published place, and no Robux**.
`UpgradeService.spec.lua` needs `ReusableSystems/Tests/_Helpers.lua`
beside it and the `AnimalService._TestRegister` seam.

---

## Adapting to a New Game

1. **Keep the cost formula.** The heart of the system is
   `base × 1.12^(L-1)` computed exactly. If you change the growth
   rate, you must change the integer math: `1.12 = 28/25`, so the
   general form is `base × g_num^(L-1) / g_den^(L-1)`, scaled by
   `10^(decimals × (L-1))` where `g_den` is a product of 2s and 5s.
   The current code's `10^(2k)` scaling only works because 25 = 5².

2. **Point `GetBasePrice` at your own price table.** The one line
   that matters is `UpgradeService.lua:139`:
   ```lua
   local base = AnimalConfig.SellBaseValue[rarity]
   ```
   Replace it with your own lookup. The rest of the engine does not
   care what the number means. **Note:** the shipped table is
   `SellBaseValue` — the same value the *sale* formula uses as its
   base. That is intentional (an animal's upgrade price and its
   liquidation value are anchored to the same number) but it means
   retuning one retunes the other.

3. **Decide the level ceiling.** `Progression.MaxLevel` is read by
   both modules. Change it and the `2^53` overflow check re-runs at
   require time.

4. **If you have no XP track**, delete `Progression.Normalize`,
   `GetXPRequired`, and the `XP` table. The upgrade path does not
   use them — only `MaxLevel` and `PointsPerLevel` matter. But
   `Progression` is also read by `AnimalService`, so you will need to
   edit that too.

5. **If you have no points system**, set `PointsPerLevel = 0` and
   leave `GetPointsForLevel` in place. It becomes a no-op.

6. **If you have no arena**, delete the `ArenaService` require and
   the raid-lock check (`UpgradeService.lua:301-303`).

7. **If you have no tutorial layer**, delete the `TutorialSignals`
   require and the `Fire` call.

8. **If you have no funnel analytics**, delete the `FunnelService`
   require and its `pcall` block.

9. **Wire the request path.** The upgrade is reached through
   `SlotMenuService`'s `SlotMenuAction` remote with
   `Action = 'Upgrade'`. If you do not have that service, write your
   own remote handler that calls
   `UpgradeService.UpgradeAnimal(player, animalId)` and fires the
   result back.

10. **Wire the readouts.** `SlotMenuService.SetUpgradeService` and
    `StandDisplayService.SetUpgradeService` are what put the cost on
    screen. Without them the transaction still works — it just has
    no UI.

11. **Keep the spend-then-mutate order.** The debit is atomic and
    the level mutation is infallible after the pre-validation.
    Reversing the order would leave a "free level" window.

12. **Consider adding a refund path.** The shipped system has none.
    If your game needs one, the safe place is after the level is
    applied: `EconomyService.AddMoney(userId, cost, TransactionReason.AdminGive)`.

---

## See also

- [`MEMORY.md`](MEMORY.md) — engineering notes for a future agent.
- [`API.md`](API.md) — every public function, with failure modes.
- [`Config.lua`](Config.lua) — the consolidated tunables.
- [`Dependencies.md`](Dependencies.md) — requires, remotes, profile fields.
- [`Setup.md`](Setup.md) — install steps into a new Rojo project.
