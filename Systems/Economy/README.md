# Economy

The money pipeline: the wallet, the income that fills it, the
modifiers that shape it, and the sale that drains a pool into it.

**Portability:** Grade A core (`EconomyService`, `ModifierService`,
`IncomeService`'s accumulator, `SellService`'s transaction shape) +
Grade B (the price ladders, rarity sell factors, and the `Sell`/viewport
tunables are Brainrot Arena's content). Nothing here is platform-bound:
no DataStore, no Marketplace, no HTTP.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

Four services, each with one job:

- **`EconomyService`** — the single authoritative mutator for
  `profile.Data.Money`. Every grant and every debit goes through
  `AddMoney` / `TrySpendMoney`, both of which return a structured
  `EconomyResult` and log an audit reason from the closed
  `TransactionReason` enum. Money is a **string-backed BigNumber**,
  never a Lua number.
- **`IncomeService`** — the ONE central income system. Animals
  generate income over time into their own **`CashPool`** (a field on
  the animal's profile record, not the wallet). A player touching a
  slot's cash collector transfers the pool into the wallet. Also owns
  offline earnings, pool settlement on removal, and the sale/collect
  race lock.
- **`ModifierService`** — the ONE place a multiplier is resolved.
  Sources are per-player, per-type, multiplicative, and order-
  independent. The Money multiplier applies **only** to newly
  generated online income.
- **`SellService`** — the ONE authority for selling animals. Eggs are
  **not sellable**; there is no egg sale path anywhere. Selling is a
  two-step server-authoritative flow: the prompt opens a confirmation
  GUI, the GUI's button transacts.

The wallet, the pool, and the multiplier are three different
concepts on purpose. The **wallet** is `Money`. The **pool** is
per-animal uncollected cash. The **multiplier** shapes new income
only. Mixing them is the bug class this system exists to prevent.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `EconomyService.Init()` | Server | No-op. The service fails every call until `SetPlayerService` runs. |
| `EconomyService.SetPlayerService(playerService)` | Server | Injects the profile owner. Required before any money call. |
| `EconomyService.SetBaseService(baseService)` | Server | Injects the base snapshot provider used by the post-mutation push. |
| `EconomyService.GetMoney(userId): string` | Server | Canonical BigNumber string. Returns `'0'` — never `nil`, never an error — when the profile is absent. |
| `EconomyService.CanAfford(userId, cost): boolean` | Server | Non-mutating compare. `false` for a malformed cost. |
| `EconomyService.AddMoney(userId, amount, reason, opts?): EconomyResult` | Server | The grant path. Clamps at `MaxMoney` with `Code = 'cap-exceeded'` (still a success). |
| `EconomyService.TrySpendMoney(userId, cost, reason, opts?): EconomyResult` | Server | Atomic compare-then-debit. On insufficient funds, **nothing mutates**. |
| `IncomeService.Init()` | Server | No-op; all wiring is via the `Set*` injectors. |
| `IncomeService.SetPlayerService/SetEconomyService/SetSlotService/SetBaseService/SetAnimalService/SetModifierService` | Server | Late-bound service refs. `SetModifierService` is optional (unwired → 1×). |
| `IncomeService.Start()` | Server | Starts the ONE background income loop. **Idempotent.** Must run after the bases/collectors exist. |
| `IncomeService.TickSources(elapsed, userIds?)` | Server | Advances the given (or all) players' pools by `elapsed` seconds. The testability seam. |
| `IncomeService.ApplyOfflineEarnings(player)` | Server | Credits the capped offline window into the pools. **Consumes the offline anchor exactly once.** |
| `IncomeService.TryCollect(slot, player)` | Server | Attempts the transfer of one slot's pool into the wallet. Silent no-op on rejection. |
| `IncomeService.SettleAnimalPool(userId, record)` | Server | Transfer path for a removed animal. Injected into `PlayerService` as the settlement handler. |
| `IncomeService.ConsumePoolForSale(userId, animalId)` | Server | Atomically takes the pool for a sale. Returns `(pool, nil)` or `(nil, code)`. |
| `IncomeService.EnsureCollectorsForSlots(slots)` / `ForgetCollectorsForSlots(slots)` | Server | Wire/unwire cash triggers for runtime-created and destroyed slots. |
| `IncomeService.RepublishSlot(slot)` | Server | Re-publishes one slot's pool (attribute + label) immediately. |
| `IncomeService.ForgetPlayer(userId)` | Server | Drops the per-session debounce and fractional remainders. |
| `ModifierService.Init()` | Server | No-op; state is created on first `AddModifier`. |
| `ModifierService.AddModifier(userId, sourceId, type, value, operation?, metadata?): (boolean, string?)` | Server | Adds or **replaces** one source. The `(userId, type, sourceId)` triple is the identity. |
| `ModifierService.RemoveModifier(userId, sourceId, modifierType?): boolean` | Server | Removes one source; with no type, removes it from every type. |
| `ModifierService.GetModifiers(userId, type?): { ModifierSource }` | Server | Deterministic **copies**, sorted by type then source id. |
| `ModifierService.GetMoneyMultiplier(userId): number` | Server | `1` when no sources. Never NaN/inf. |
| `ModifierService.GetXPModifier(userId): number` | Server | `1` when no sources. |
| `ModifierService.GetResolvedModifiers(userId)` | Server | Both multipliers + both source lists in one call. |
| `ModifierService.ForgetPlayer(userId)` / `ClearModifiers(userId)` | Server | Drops every source for a player. `ClearModifiers` is an alias. |
| `SellService.Init()` | Server | Wires the Sell prompt callback and the `SellConfirmAction` remote. **Idempotent.** |
| `SellService.SetPlayerService/SetSlotService/SetBaseService/SetAnimalService/SetEconomyService/SetIncomeService/SetModifierService` | Server | Late-bound service refs. All six are required before a sale. |
| `SellService.SetEggService(_svc)` | Server | **Compat no-op.** Eggs are not sellable; the setter exists so bootstrap wiring is unchanged. |
| `SellService.GetAnimalBaseSellValue(definitionId): string?` | Server | Pure. `nil` for an unknown definition or rarity. |
| `SellService.GetAnimalLevelSellValue(definitionId, level, trait?, mutations?): string?` | Server | Pure. base × level × rarity factor × trait × mutation, exact. |
| `SellService.GetAnimalTotalPayout(definitionId, level, pool, trait?, mutations?): string?` | Server | Pure. Level value + pool. |
| `SellService.SellAnimal(player, animalId)` | Server | The transaction. Returns `{ success, payout, saleValue, pool }` or `{ success = false, error }`. |
| `SellService.PreviewSell(player, animalId)` | Server | Read-only preview push. Mutates nothing. |
| `SellService.ConfirmSell(player, animalId)` | Server | Runs the canonical pipeline and fires `SellConfirmResult`. |

Full signatures, parameters, return shapes, and failure modes: see
[`API.md`](API.md).

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/EconomyService.lua` | `ServerScriptService.EconomyService` | The wallet authority. |
| `Source/ServerScriptService/IncomeService.lua` | `ServerScriptService.IncomeService` | Pools, income tick, offline earnings, collection, settlement. |
| `Source/ServerScriptService/ModifierService.lua` | `ServerScriptService.ModifierService` | Multiplier resolution. |
| `Source/ServerScriptService/SellService.lua` | `ServerScriptService.SellService` | The sale authority. |
| `Source/ReplicatedStorage/Config/Economy/Money.lua` | `ReplicatedStorage.Config.Economy.Money` | The economy tunables. |
| `Source/ReplicatedStorage/Config/Economy/Sell.lua` | `ReplicatedStorage.Config.Economy.Sell` | Sell-preview presentation tunables. |

---

## Configuration

The system has **two** config modules of its own.

- `ReplicatedStorage.Config.Economy.Money` — the economy tunables
  (starting money, cap, tick cadence, offline window, debounce).
  This is the one that matters.
- `ReplicatedStorage.Config.Economy.Sell` — the sell **confirmation
  screen's** look: viewport staging, rarity-gradient shading, preview
  scale, result timeout, confirmation labels. Presentation only; it
  never touches a value.

A consolidated, commented view of both lives in
[`Config.lua`](Config.lua).

The price ladders themselves are **owned elsewhere** and are only
referenced here:

| Value | Lives in | Meaning |
|---|---|---|
| `Animals.SellBaseValue[rarity]` | `Config/Creatures/Animals.lua` | The base price **and** the upgrade-cost anchor. |
| `Animals.SellMultiplier[rarity]` | `Config/Creatures/Animals.lua` | The liquidation haircut, uniformly `'0.75'`. |
| `Traits.SellMultiplierFor(trait)` | `Config/Creatures/Traits.lua` | Per-trait sale factor. |
| `Mutations.SellFold(mutations)` | `Config/Creatures/Mutations.lua` | Folded mutation sale factor. |
| `AnimalConfig.Stats.Income.Base` | `Config/Creatures/Animals.lua` | The per-second income rate ladder. |
| `Progression.XP.GrowthRate` | `Config/Creatures/Progression.lua` | The 1.12 curve shared with the upgrade economy. |

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the exact require paths,
remotes, profile fields, and Studio assets.

The load-bearing ones:

- `ReplicatedStorage.Utility.BigNumber` — all money arithmetic.
- `ReplicatedStorage.Types.TransactionReason` — the closed audit enum.
- `ReplicatedStorage.Utility.Validation` — `LivePlayer`,
  `CanPlayerInteract`, `IsValidPlayerUserId`.
- `ServerScriptService.PlayerService` — the profile owner. Injected,
  not required.
- `ServerScriptService.SlotService` / `BaseService` / `AnimalService`
  — slot, base, and animal lookups. Injected.
- `ServerScriptService.Base.CollectFeedback` — the collection SFX/VFX
  (from the **Collectors** system).
- `ServerScriptService.Utility.MoneyIcon` — the icon descriptor shipped
  with `CashCollected` (from **SharedUtilities**).
- `ServerScriptService.Action.SlotActionHandler` — the unified action
  pipeline the confirmation routes through (from **Inventory**).
- `ServerScriptService.Arena.ArenaService` — the raid lock (from
  **Arena**).

**Remotes used:** `PlayerState` (S→C, pushed after every successful
money write), `CashCollected` (S→C, collection + sale burst),
`SellPreviewState` (S→C), `SellConfirmAction` (C→S),
`SellConfirmResult` (S→C).

**Profile fields written:** `Money` (EconomyService),
`Brainrots[].CashPool` (IncomeService), `Stats.UpgradesApplied` is
**not** written here (UpgradeService owns it).

---

## Initialization Order

From the source game's `bootstrap.server.lua`:

```text
1.  Remotes folder created
2.  EconomyService.Init()
3.  EconomyService.SetPlayerService(PlayerService)
4.  PlayerService.Init()
5.  SlotService.Init() / BaseService.Init() + setters
6.  EggService.Init() + setters
7.  AnimalService.Init() + setters
8.  EconomyService.SetBaseService(BaseService)      -- enables the post-mutation push
9.  ModifierService.Init()
10. IncomeService.SetModifierService(ModifierService)
11. SellService.Set* (all seven) ; SellService.Init()
12. IncomeService.Init() ; IncomeService.SetPlayerService / SetEconomyService /
    SetSlotService / SetBaseService / SetAnimalService
13. PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)
14. SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
15. RebirthService.Init()  (owns the Money multiplier source)
16. --- players may now join ---
17. IncomeService.Start()   -- AFTER the bases/collectors exist
```

The two orderings that actually matter:

- **`EconomyService.SetBaseService` must run before any money
  mutation.** Without it, `pushMoneyState` no-ops and the HUD never
  converges (the transaction still succeeds — it is best-effort by
  design).
- **`IncomeService.Start()` must run after the bases are registered.**
  The collector `Touched` connections are taken once, at `Start()`;
  runtime-created slots must go through `EnsureCollectorsForSlots`.

Per-player, on `PlayerAdded`:

```text
1. PlayerService.LoadPlayerData(player)      -- money seeded
2. BaseService.AssignBaseForPlayer / AssignBase / PointPlayerToBaseSpawn
3. BaseService.RestorePlayerBase(userId, profileData)
4. IncomeService.ApplyOfflineEarnings(player)  -- BEFORE the state push
5. RebirthService.ApplySessionModifiers(userId)
6. PlayerService.MarkLoaded
7. PlayerService.PushState(player, BaseService.Snapshot(userId))
```

---

## Data

The wallet lives at `profile.Data.Money` as a **BigNumber decimal
string** (e.g. `'12500.5'`). It is never a number.

The pool lives at `profile.Data.Brainrots[i].CashPool`, also a
BigNumber string. It rides the animal record, so moving an animal
between slots moves the pool for free.

Neither field is owned by the profile template in a way that matters:
the profile template seeds `Money`, and `IncomeService` maintains the
pool.

There is **no DataStore of its own** — the economy writes into
`PlayerService`'s profile. There is no schema version and no
migration path inside this system; see *Known Limitations*.

---

## Known Limitations

- **`profile.Data.Money` is written directly in two places that bypass
  `EconomyService`:** `PlayerService.WipeUser` and
  `RebirthService` (`data.Money = BigNumber.sanitize(...)`). Those
  writes skip the audit trail and the `MaxMoney` cap.
- **`EconomyService.AddMoney` still honours the deprecated
  `profile.Data.Multipliers.Money` field** by default
  (`opts.ApplyMultiplier` defaults to `true`). The field is always
  `1` in legitimate profiles, and every live caller passes
  `{ ApplyMultiplier = false }`, so the egg is inert — but a new
  caller that forgets the opt-in will silently multiply a grant.
- **`TrySpendMoney`'s `AllowNegative` option has no observable
  effect.** `BigNumber.Subtract` clamps at `'0'` regardless, so the
  flag is accepted and ignored. It exists so a future "borrowed
  money" flow does not need a signature change.
- **`ModifierService` state is per-session and in-memory.** Nothing
  is persisted; a persistent source (e.g. a rebirth bonus) persists
  the *source*, not the resolved multiplier, and must be re-applied
  on every join (`RebirthService.ApplySessionModifiers` does this
  for the rebirth bonus).
- **The `Money` multiplier applies to offline earnings at
  `OfflineEffectiveness` (0.5)** — the doc comment in
  `IncomeService.lua:48-57` claims the multiplier "NEVER applies in
  `ApplyOfflineEarnings`", but the code at
  `IncomeService.lua:522-528` *does* apply it, scaled by
  effectiveness. The code is the newer behaviour; the header comment
  is stale. This is a real contradiction inside the source.
- **A `MaxMoney` clamp is a silent loss.** `AddMoney` returns
  `Success = true` with `Code = 'cap-exceeded'`; the difference
  between the requested and granted amount is not reported.
- **`IncomeService` holds one `Touched` connection per collector
  part forever.** Parts are only released through
  `ForgetCollectorsForSlots`; a leaked part pins its slot record.
- **The income loop is a single global `task.spawn` while-loop.** One
  slow player blocks every other player's tick for that frame. It
  never yields inside the per-player work, so this is bounded, but
  it is not per-player isolated.
- **`SellService.PreviewSell` ships the live animal `Model` instance
  to the client**, which clones it locally. The live model is never
  reparented, but the payload does cross the network.
- **`SellService` requires `SlotActionHandler`, `CarryPrompts`,
  `NotificationService`, and `ArenaService` at load time.** It is the
  most tightly coupled module in the system.

---

## Testing

Four spec files, all requiring Roblox Studio (there is no headless
Luau runner in this project — see `../../Tests/README.md`).

| Spec | Covers |
|---|---|
| `Tests/EconomyService.spec.lua` | GetMoney, CanAfford, AddMoney (precision, cap, bad reason, bad amount, multiplier), TrySpendMoney (atomicity, exact balance, operand-length regression), per-player isolation. |
| `Tests/IncomeService.spec.lua` | Accumulation and fractional retention, the full ineligibility matrix, collection (empty, repeat, wrong owner, AddMoney failure), the multiplier rules (online 1×, offline 50×, transfer 1:1), offline capping and exactly-once consumption, settlement, and the `MoneyLabel` binding. |
| `Tests/ModifierService.spec.lua` | Defaults of exactly 1, multiplicative stacking, insertion-order independence, replace-not-double-count, every invalid-value rejection, and the economy integration proofs. |
| `Tests/SellService.spec.lua` | Level scaling and monotonicity, pool added exactly once, removal and slot release, double-sell pays once, wrong-owner/invalid rejection, carried rejection, the collect/sale race both ways, the multiplier never shaping the payout, and the preview/confirm flow. |

**No DataStore, no published place, and no Robux are required.** The
specs stub the profile and the remotes through `_Helpers` and inject
hand-rolled service fakes.

The `Touched` wiring, the `PromptProductPurchase` dialog, and the
`MarketplaceService` receipt path are **Studio-only** and are not
exercised by these specs.

---

## Adapting to a New Game

1. **Keep the three concepts separate.** Wallet (`Money`), pool
   (`CashPool`), and multiplier. If your game has no per-animal pools,
   drop `IncomeService` and wire `EconomyService` alone.
2. **Keep money a string.** `BigNumber` is the whole point. If your
   game's economy fits in a double, you can still keep the string
   shape — the `Money` field is read by clients for display and by
   the server for arithmetic, and the string form costs nothing.
3. **Replace the price ladders.** `Animals.SellBaseValue` and
   `Animals.SellMultiplier` are Brainrot Arena content. Point
   `SellService.GetAnimalBaseSellValue` and
   `UpgradeService.GetBasePrice` at your own table. The *shape* —
   base value per rarity, a liquidation factor per rarity — is the
   reusable part.
4. **Keep the `TransactionReason` enum closed.** Adding a reason is a
   deliberate change to the audit taxonomy. Do not pass free-form
   strings.
5. **Re-derive the multiplier application points.** By default the
   Money multiplier applies to online income only, and offline earns
   at `OfflineEffectiveness`. If your game wants the multiplier on
   everything, change `IncomeService._tickPlayer` and
   `ApplyOfflineEarnings` together — and change the comment.
6. **Decide what "selling" means.** In Brainrot Arena, eggs are
   never sellable and animals liquidate at a 75% haircut. Both are
   design choices, not mechanisms.
7. **Re-tune the offline window.** `MaxOfflineSeconds` (3 hours) and
   `OfflineEffectiveness` (0.5) are the two numbers that decide
   whether returning is worth it.
