# Economy — engineering notes

**One line:** The money pipeline — wallet, per-animal cash pools, the
multiplier that shapes new income, and the sale that drains a pool into
the wallet — with a single authoritative mutator per concern.

---

## How it actually works

### `EconomyService` (the wallet)

Reads/writes `profile.Data.Money`, a **BigNumber decimal string**.
`GetPlayerData` is reached through the injected `_playerService`; the
service never requires `PlayerService` back.

`AddMoney(userId, amount, reason, opts?)`:
1. `TransactionReason.isValid(reason)` — else `_fail('invalid-reason')`.
2. profile present — else `_fail('no-profile')`.
3. `amount` is a string that `BigNumber.sanitize` accepts — else
   `_fail('invalid-amount')`.
4. If `opts.ApplyMultiplier ~= false` and `data.Multipliers.Money` is a
   number, multiply. Guard: `mult < 0` or non-integer → fail. `mult == 0`
   is legal (it absorbs the grant).
5. If the (shaped) amount is zero → `_ok` with the **current** balance.
   No write, but still logged.
6. `sum = Add(current, amount)`; if `sum > MaxMoney` → `sum = MaxMoney`,
   `capped = true`.
7. `data.Money = sum` — the write. No `task.yield()` between the
   read and the write, so a second same-script call sees the new value.
8. `pushMoneyState(userId)`.
9. Returns `_ok(reason, sum, tx)`, plus `Code = 'cap-exceeded'` if
   capped (still `Success = true`).

`TrySpendMoney(userId, cost, reason, opts?)`:
1. Same reason / profile / amount validation.
2. `current = GetMoney(userId)`.
3. Zero cost → `_ok(reason, current, tx)`, no write.
4. `Compare(current, cost) < 0` → `_fail(reason, 'insufficient')`.
   **Nothing mutates.**
5. `data.Money = Subtract(current, cost)` (Subtract clamps at `'0'`).
6. `pushMoneyState(userId)`.

`pushMoneyState` is a best-effort, `pcall`-guarded push of
`PlayerState`. It **no-ops** when `_playerService` or `_baseService` is
unset, when the player is gone, or when `GetBaseId(userId)` is `nil`
(no base yet). It can never fail a money transaction.

`GetMoney` returns `'0'` for every failure mode (no service, no
profile, `data.Money` not a string). It never returns `nil`.

`CanAfford(userId, cost)` is a pure compare. A malformed cost → `false`.
A zero cost → `true` (always affordable).

`EconomyResult` = `{ Success: boolean, NewMoney: string?, Reason: string,
Code: string?, TransactionId: string? }`. `NewMoney` is `nil` on
failure. `Code` is one of `'invalid-reason'`, `'no-profile'`,
`'invalid-amount'`, `'insufficient'`, `'cap-exceeded'`.

Transaction ids are `tx-<userId>-<counter>` — grep-able, not UUIDs,
not collision-safe.

### `IncomeService` (the pools)

Three separate money-like things, deliberately:

| Thing | Where it lives | Who writes it |
|---|---|---|
| Wallet | `profile.Data.Money` | **Only** `EconomyService` (plus two direct writers: `PlayerService.WipeUser`, `RebirthService`). |
| Pool | `record.CashPool` on the animal profile record | `IncomeService` only. |
| Rate | derived, never persisted | `AnimalStats.Calculate(record, 'Income')` |

Because the pool rides the **record**, moving an animal between slots
moves the pool for free, and removing an animal must settle it.

**The tick.** `IncomeService.Start()` spawns exactly one
`task.spawn` loop: `task.wait(IncomeTickSeconds)`, compute
`elapsed = os.clock() - lastClock`, call `TickSources(elapsed)`, then
`_sweepPublish()`. The cadence is a *granularity*, not the rate — the
elapsed real time drives the math, so a slow server still credits
exactly the right amount.

**`TickSources(elapsed, userIds?)`** → `_tickPlayer(userId, elapsed)`:
- refresh `data.LastSeen` at most every `OfflineHeartbeatSeconds`;
- resolve the carried animal id;
- resolve `moneyMult` from `ModifierService.GetMoneyMultiplier` via
  `pcall`, degrading to `1` on any failure;
- `records = table.clone(data.Brainrots)` (snapshot the array, not the
  records);
- for each eligible record: `rate = AnimalStats.Calculate(record, 'Income')`,
  `acc = _frac[key] + rate * moneyMult * elapsed`, `whole = floor(acc)`;
  if `whole >= 1` → `_frac[key] = acc - whole` and `_creditPool(record, whole)`,
  else `_frac[key] = acc`. The remainder carries forward so no income is
  lost to flooring.

`_frac` is keyed `'<userId>:<animalId>'`.

**Eligibility (`_isEligible`)** — all must hold:
- `record.Type == 'Brainrot'` (eggs never earn);
- the record is not the carried animal;
- `AnimalService.IsArenaDeployed(record.Id)` is false (a deployed
  animal's pool is **frozen**: never reset, never deleted, earns
  nothing);
- `SlotService.FindSlotByOccupant(record.Id)` returns a slot;
- `slot.ownerUserId == userId`;
- `slot.state == Occupied` and `slot.occupantKind == Animal`.

Arena stands are first-class slots — arena-team animals earn through
the same chain. Location never duplicates income.

**Publishing.** `_publishSlot(slot, value)` writes
`part:SetAttribute('CashPool', value)` and mirrors the value into the
display label. The label lookup is MAIN GAME first
(`Stand.Button.PressPart.SurfaceGui.Amount`), legacy fallback
(`CashCollector.CollectorGui.MoneyLabel`); a missing/mistyped chain
warns **once per part** and still publishes the attribute.

`_sweepPublish()` runs every `CashPoolAttributeThrottleSeconds` and
converges every slot's attribute + label. `RepublishSlot(slot)` forces
one slot immediately (used by the SlotService display hook on place /
pickup / move / release). Collection and offline application publish
directly, bypassing the throttle.

**Offline earnings.** `ApplyOfflineEarnings(player)`:
- `captured = PlayerService.ConsumeOfflineTimestamp(userId)` — consumed
  **exactly once**, so a window can never pay twice;
- `captured <= 0` → pay nothing;
- `duration = clamp(os.time() - captured, 0, MaxOfflineSeconds)`;
- resolve `moneyMult` (same pcall/degrade-to-1 as the tick) and
  `effectiveness = OfflineEffectiveness` (clamped to 0..1, default 0.5);
- for each eligible record: `earned = floor(rate * moneyMult * effectiveness * duration)`,
  credit it, and force-publish that slot.

It writes **only** `CashPool`. No XP, no levels, no wallet.

**Collection.** `TryCollect(slot, player)`:
1. `Validation.CanPlayerInteract(player)` — a corpse on a collector
   collects nothing. Non-Player table shims pass through.
2. `slot.ownerUserId == player.UserId` — else silent no-op.
3. `slot.state == Occupied` and `slot.occupantKind == Animal` — else
   no-op.
4. `playerServiceRef` and `economyServiceRef` must be wired.
5. Per-player debounce: `os.clock() - _lastTouch[userId] <
   CollectorDebounceSeconds` → no-op. (Collapses a multi-body-part
   touch into one collection.)
6. Claim lock: `_claims[slot.id]` → no-op; else set it.
7. Inside a `pcall`: find the record by `slot.occupantId`; if the
   profile has no matching record → **loud warn** (state
   inconsistency). If the pool is zero → silent no-op. Otherwise
   `AddMoney(userId, pool, CashCollector, { ApplyMultiplier = false })`.
8. On success: `record.CashPool = '0'`, `_publishSlot(slot, '0')`,
   `CollectFeedback.Play(player, slot)`, then fire
   `CashCollected { Amount, NewMoney, Icon, Origin }` to the collecting
   player only. On failure: **warn and preserve the pool**.
9. `_claims[slot.id] = nil` (always, even on error).

Collection is deliberately **silent** on rejection — no toast. A
character standing on a collector would spam toasts.

**Settlement.** `SettleAnimalPool(userId, record)` — the handler
injected into `PlayerService.SetAnimalPoolSettlementHandler`. It
transfers the pool to the wallet with `{ ApplyMultiplier = false }`
and zeroes it, or warns and **preserves the value on the record** if
the grant fails. `WipeUser` deliberately does NOT settle.

**Sale consumption.** `ConsumePoolForSale(userId, animalId)`:
returns `(nil, 'unavailable' | 'not-found' | 'no-slot' | 'busy' | 'error')`
or `(pool, nil)`. It takes the slot's claim lock, zeroes the pool,
clears the fractional remainder, publishes `'0'`, releases the lock.
Ownership/sellability is the **caller's** job. The caller MUST pay the
returned pool into the sale; on payment failure the caller restores it.

### `ModifierService` (the multiplier)

State: `_sources[userId][type][sourceId] = ModifierSource`.

`AddModifier` validates: userId (via `Validation.IsValidPlayerUserId`),
sourceId (string, 1..64 chars), type (must be `MoneyMultiplier` or
`XPModifier`), value (finite number, `> 0`, `<= 1_000_000`), operation
(only `'Multiply'`), metadata (nil or a table). Each rejection returns
`(false, code)` with code one of `'invalid-player'`, `'invalid-source'`,
`'invalid-type'`, `'invalid-value'`, `'unsupported-operation'`,
`'invalid-metadata'`.

Adding the same `(userId, type, sourceId)` **replaces** the previous
source — the triple is the identity, so a source can never double-count
itself.

`_resolve` sorts the source ids, folds multiplicatively from `1`, and
returns `1` if the running product becomes NaN/inf/`<= 0`. It
re-validates each stored value at read time — a poisoned entry is
skipped, not a NaN cascade.

`GetModifiers` returns **copies** (the caller can never mutate
authoritative state) sorted by type then source id.

### `SellService` (the sale)

Pure functions (no refs, shared by gameplay and the HUD):
- `GetAnimalBaseSellValue(definitionId)` → `Animals.SellBaseValue[rarity]`
  as a BigNumber string, or `nil`.
- `GetAnimalLevelSellValue(definitionId, level, trait?, mutations?)` →
  `base × level` (BigNumber.Multiply, integer) `× Animals.SellMultiplier[rarity]`
  (decimal string) `× Traits.SellMultiplierFor(trait)`
  `× Mutations.SellFold(mutations)` — all via
  `BigNumber.MultiplyDecimal`, so the result is exact. `nil` if the
  level is invalid or the definition is unknown.
- `GetAnimalTotalPayout(definitionId, level, pool, trait?, mutations?)` →
  level value + pool. `nil` on any failure.

The transaction `SellAnimal(player, animalId)`, in order:
1. `Validation.LivePlayer` → `'invalid-player'`.
2. `animalId` is a non-empty string → `'invalid-id'`.
3. All six service refs wired → `'service-unavailable'`.
4. `animalService.Get(animalId)` → `'not-found'`.
5. `animal.ownerUserId == userId` → `'not-owner'`.
6. `animal._mutex` → `'busy'`; else set the mutex.
7. `animal.state == 'Carried'` → `'carried'`.
8. `ArenaService.IsAnimalRaidLocked(animalId)` → `'busy'`.
9. `animal.state` is `Consumed`/`Destroyed` → `'invalid-state'`.
10. `animal.slotId` is a string → `'slot-state'`.
11. `animal.definitionId` non-empty and `AnimalConfig.Get` resolves →
    `'invalid-definition'`.
12. `animal.Level` is an integer in `1..MaxLevel` → `'invalid-level'`.
13. The slot is `Occupied`, `slot.occupantId == animalId`,
    `slot.ownerUserId == userId` → `'slot-state'`.
14. `saleValue = GetAnimalLevelSellValue(...)` → `'no-sell-value'`.
15. `pool = IncomeService.ConsumePoolForSale(userId, animalId)`; a
    `'busy'` code → `'pool-busy'`, anything else → `'slot-state'`.
16. `total = GetAnimalTotalPayout(definitionId, level, pool, trait, muts)`.
17. `EconomyService.AddMoney(userId, total, SellAnimal,
    { ApplyMultiplier = false })`. On failure: **restore the pool onto
    the still-live record**, warn, return `'grant-failed'`.
18. Teardown: `DestroyRuntimeAnimal`, `ReleaseSlot`,
    `CarryPrompts._UnregisterPromptsForSlot`, `PlayerService.RemoveAnimal`
    (the removal settlement sees a zero pool and no-ops),
    `CodesService.TryDeliverPending`, fire `CashCollected`, push state,
    `NotifySuccess('Sell_Success')`.

Returns `{ success = true, payout, saleValue, pool }`.

**Eggs are not sellable.** No `SellEgg`, no egg value function, no egg
sell prompt, no egg sell remote. `SlotActionHandler` has no `'SellEgg'`
branch. `SellService.SetEggService` is a compat no-op.

**The two-step sale.** `SellService.Init()` wires
`CarryPrompts.SetSellPromptCallback` and the `SellConfirmAction`
remote. The prompt calls `PreviewSell` (read-only: no mutex, no money,
no mutation) which pushes `SellPreviewState` with
`{ Valid, AnimalId, SlotId, Name, Rarity, Trait, Level, LevelText,
GenerationText, Mutations, SellValueRaw, Model }`. The GUI's button
fires `SellConfirmAction { AnimalId }` → `ConfirmSell` → the canonical
`SlotActionHandler.Handle(player, { Action = 'SellAnimal', SlotId,
OccupantId })` → `SellAnimal`. `ConfirmSell` always fires
`SellConfirmResult { AnimalId, Success, Error }`.

---

## Public API surface (exact)

```lua
-- EconomyService
EconomyService.Init()
EconomyService.SetPlayerService(playerService: any)
EconomyService.SetBaseService(baseService: any)
EconomyService.GetMoney(userId: number): string
EconomyService.CanAfford(userId: number, cost: string): boolean
EconomyService.AddMoney(userId: number, amount: string, reason: string,
    opts: { ApplyMultiplier: boolean? }?): EconomyResult
EconomyService.TrySpendMoney(userId: number, cost: string, reason: string,
    opts: { AllowNegative: boolean? }?): EconomyResult

-- IncomeService
IncomeService.Init()
IncomeService.SetPlayerService(ps: any)
IncomeService.SetEconomyService(es: any)
IncomeService.SetSlotService(ss: any)
IncomeService.SetBaseService(bs: any)
IncomeService.SetAnimalService(svc: any)
IncomeService.SetModifierService(ms: any)
IncomeService.Start()
IncomeService.TickSources(elapsed: number, userIds: { number }?)
IncomeService.ApplyOfflineEarnings(player: Player)
IncomeService.TryCollect(slot: any, player: Player)
IncomeService.SettleAnimalPool(userId: number, record: any)
IncomeService.ConsumePoolForSale(userId: number, animalId: string): (string?, string?)
IncomeService.EnsureCollectorsForSlots(slots: any)
IncomeService.ForgetCollectorsForSlots(slots: any)
IncomeService.RepublishSlot(slot: any)
IncomeService.ForgetPlayer(userId: number)

-- ModifierService
ModifierService.ModifierType = { MoneyMultiplier = 'MoneyMultiplier', XPModifier = 'XPModifier' }
ModifierService.Operation = { Multiply = 'Multiply' }
ModifierService.Init()
ModifierService.AddModifier(userId: number, sourceId: string, modifierType: string,
    value: number, operation: string?, metadata: any?): (boolean, string?)
ModifierService.RemoveModifier(userId: number, sourceId: string, modifierType: string?): boolean
ModifierService.GetModifiers(userId: number, modifierType: string?): { ModifierSource }
ModifierService.GetMoneyMultiplier(userId: number): number
ModifierService.GetXPModifier(userId: number): number
ModifierService.GetResolvedModifiers(userId: number): {
    MoneyMultiplier: number, XPModifier: number,
    MoneySources: { ModifierSource }, XPSources: { ModifierSource } }
ModifierService.ForgetPlayer(userId: number)
ModifierService.ClearModifiers(userId: number)   -- alias of ForgetPlayer

-- SellService
SellService.Error = { InvalidPlayer, InvalidId, NotFound, NotOwner, Busy, Carried,
    InvalidState, InvalidDefinition, InvalidLevel, InvalidRarity, NoSellValue,
    SlotState, PoolBusy, GrantFailed, ServiceUnavailable }  -- stable string codes
SellService.Init()
SellService.SetPlayerService / SetSlotService / SetBaseService / SetAnimalService
    / SetEggService / SetEconomyService / SetIncomeService / SetModifierService
SellService.GetAnimalBaseSellValue(definitionId: string): string?
SellService.GetAnimalLevelSellValue(definitionId: string, level: number,
    trait: string?, mutations: { string }?): string?
SellService.GetAnimalTotalPayout(definitionId: string, level: number, pool: string,
    trait: string?, mutations: { string }?): string?
SellService.SellAnimal(player: Player, animalId: string): { [string]: any }
SellService.PreviewSell(player: Player, animalId: string): { [string]: any }
SellService.ConfirmSell(player: Player, animalId: string): { [string]: any }
```

`SellService.Error` values: `invalid-player`, `invalid-id`,
`not-found`, `not-owner`, `busy`, `carried`, `invalid-state`,
`invalid-definition`, `invalid-level`, `invalid-rarity`,
`no-sell-value`, `slot-state`, `pool-busy`, `grant-failed`,
`service-unavailable`.

`SellService` also has a `SellService.SetEggService(_svc)` **no-op**
shim and a `SellService.Error.InvalidRarity` code that is declared but
never returned.

---

## Invariants the code enforces

1. **Money is a string.** `data.Money` is only ever assigned a
   `BigNumber.sanitize` output. Never a number.
2. **One writer for the wallet.** `EconomyService` is the only
   *service* that writes `Money`. (`WipeUser` and `RebirthService`
   bypass it — a known violation, not a rule.)
3. **The reason is validated first.** An invalid `TransactionReason`
   fails before any money moves, so a typo in an admin command cannot
   change a balance.
4. **Spends are atomic.** `TrySpendMoney` compares and writes with no
   `yield` between them. Insufficient funds → no mutation at all.
5. **The cap is a clamp, not a failure.** `AddMoney` over `MaxMoney`
   succeeds with `Code = 'cap-exceeded'`.
6. **The pool is per-record, and only `IncomeService` writes it.**
7. **The multiplier applies to NEW income only.** Never to the
   existing pool, never at collection, never at settlement.
8. **Collection and settlement are transfers, not grants** — always
   `{ ApplyMultiplier = false }`.
9. **A pool is zeroed only after the money landed.** On an
   `AddMoney` failure the pool is preserved.
10. **Only whole dollars are credited.** Fractional income is carried
    in `_frac`, never lost and never credited early.
11. **The offline anchor is consumed exactly once.**
12. **Modifiers are multiplicative and order-independent.** The source
    ids are sorted before folding.
13. **A modifier source cannot double-count itself** — the
    `(userId, type, sourceId)` triple replaces.
14. **Modifier values are bounded** to `(0, 1_000_000]` and finite.
15. **The sale pays the pool exactly once.** The pool is consumed under
    the slot's claim lock; a racing collection either wins first (the
    sale consumes `'0'`) or loses (the collect sees `'0'`).
16. **The sale grants `saleValue + pool` in a single `AddMoney`.**
17. **A failed grant rolls the pool back** onto the still-live record.
18. **The multiplier never shapes a sale.** `ApplyMultiplier = false`.
19. **Eggs are never sellable.**
20. **A sale is refused for a carried animal** and for a raid-locked
    animal.

---

## Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| No `PlayerService` injected | `GetMoney` → `'0'`; `CanAfford` → `false`; mutations → `{ Success = false, Code = 'no-profile' }`. |
| Player not loaded | Same as above (`no-profile`). |
| `data.Money` is not a string | `GetMoney` → `'0'`. `AddMoney` reads the current balance as `'0'`. |
| Malformed amount / cost | `Code = 'invalid-amount'`, no mutation. |
| Unknown `TransactionReason` | `Code = 'invalid-reason'`, no mutation. |
| Grant exceeds `MaxMoney` | Success, balance clamped, `Code = 'cap-exceeded'`. |
| Zero amount / zero cost | Success, no write. |
| `opts.ApplyMultiplier` omitted | Defaults to `true` — the deprecated `data.Multipliers.Money` is applied. |
| `data.Multipliers.Money` is `0` | The grant is absorbed (success, no change). |
| `data.Multipliers.Money` is negative or fractional | `Code = 'invalid-amount'`, no mutation. |
| `opts.AllowNegative = true` | **Accepted and ignored.** `Subtract` clamps at `'0'` regardless. |
| `ModifierService` unwired in `IncomeService` | Every player resolves to `1×`. |
| `ModifierService.GetMoneyMultiplier` throws | `pcall`-guarded → `1×`. Same for a NaN/inf/`<= 0` result. |
| Empty pool touch | Silent no-op, **no transaction**. |
| Wrong-owner touch | Silent no-op. |
| Debounced touch (within `CollectorDebounceSeconds`) | Silent no-op. |
| Dead character on a collector | Silent no-op (`CanPlayerInteract`). |
| Slot occupied but the profile has no matching record | **Loud warn**, no transaction. |
| `AddMoney` fails during collection | **Warn**, pool preserved. |
| `ConsumePoolForSale` while a collect is in flight | `(nil, 'busy')` → `SellService` returns `'pool-busy'`. |
| `ConsumePoolForSale` with no slot / no record | `(nil, 'no-slot')` / `(nil, 'not-found')`. |
| Offline anchor missing or `<= 0` | Pays nothing. |
| Offline window longer than `MaxOfflineSeconds` | Clamped; a log line records raw vs capped. |
| Modifier resolution returns a non-number | Degrades to `1×`. |
| `UpgradeService` cost at `MaxLevel` | `nil` — no 100 → 101 price exists. |
| `SellService` refs not all wired | `'service-unavailable'`, nothing mutates. |
| `SellService` at `MaxLevel`… n/a | — |

---

## Gotchas that will bite you

1. **`AddMoney` multiplies by default.** The `ApplyMultiplier` opt
   defaults to `true`, and it reads the **deprecated**
   `profile.Data.Multipliers.Money`. Every live caller passes
   `{ ApplyMultiplier = false }`. If you add a caller and forget the
   opt, a legacy multiplier (always `1` in practice) will silently
   shape the grant. The comment block at `EconomyService.lua:239-249`
   is the authoritative warning.
2. **The `IncomeService` header comment contradicts the code.** The
   header says the Money multiplier "NEVER applies in
   `ApplyOfflineEarnings`", but `IncomeService.lua:522-528` applies it
   scaled by `OfflineEffectiveness`. The code is authoritative. Update
   the comment if you touch this.
3. **The wallet and the pool are different money.** A player who
   sells an animal gets `saleValue + pool` in one grant. Do not
   "collect" first and then sell — that would be two transfers of the
   same money (the second would see a zero pool, so it is safe, but
   it is wasteful and it changes the `CashCollected` animation).
4. **`CashPool` is not the wallet and never was.** Reading
   `record.CashPool` to decide "how much money does the player have"
   is wrong. Use `EconomyService.GetMoney`.
5. **`_frac` is keyed by user + animal.** Reusing an animal id across
   players would collide, and `ForgetPlayer` only clears the caller's
   prefix. If you delete an animal, clear its remainder
   (`SettleAnimalPool` and `ConsumePoolForSale` both do).
6. **`SellService` requires `SlotActionHandler` at load time**, and
   `SlotActionHandler` resolves `SellService` lazily. Both directions
   exist — do not "fix" one of them into a cycle.
7. **`ConsumePoolForSale` does not restore on failure.** The caller
   must put the pool back. `SellService` does this
   (`SellService.lua:461-475`).
8. **`BigNumber.Multiply` takes a small non-negative integer**, not a
   decimal. Use `BigNumber.MultiplyDecimal` for `'0.75'`, `'1.5'`.
   `Multiply` **throws** on a bad multiplier, and `MultiplyDecimal`
   throws on more than 6 significant digits.
9. **`BigNumber.Subtract` clamps at `'0'`.** It never returns a
   negative. Use `Compare` first if you need the difference.
10. **`BigNumber.Divide` throws on a fractional divisor** and on
    divide-by-zero. `UpgradeService` uses it only with `25^k`.
11. **`BigNumber.Format` is display-only.** It uses `tonumber` and
    loses precision above 2^53. Never feed a `Format` output back into
    money arithmetic.
12. **`EconomyService.GetMoney` returns `'0'` for a missing profile** —
    it never returns `nil`. If you need "no profile", check
    `PlayerService.GetPlayerData` yourself.
13. **The `MaxMoney` cap loses money silently.** The difference is not
    reported; only `Code = 'cap-exceeded'` is. If a grant looks
    short, check the cap.
14. **`IncomeService.Start()` is where the `Touched` connections are
    taken.** Calling `Start()` before the bases exist means no
    collector ever fires. Runtime-created slots need
    `EnsureCollectorsForSlots`.
15. **`ModifierService` is per-session.** `ForgetPlayer` is called on
    leave, so a persistent source must be re-applied on every join
    (`RebirthService.ApplySessionModifiers`).
16. **`_publishSlot` change-detects.** If the value is unchanged it
    writes nothing — so a display that must refresh even when the
    value is identical will not.
17. **`BigNumber.sanitize` rejects signs.** `'-5'` is invalid, and
    `Subtract` therefore can never go negative. A refund that needs a
    negative delta must be expressed as a positive add.
18. **`TransactionReason` is closed.** `isValid` iterates a frozen
    list. `EggOpenRefund` is in the enum but never emitted — it is
    reserved.

---

## What to change to reuse it

- **Prices** → replace `Animals.SellBaseValue` /
  `Animals.SellMultiplier` / `Traits.SellMultiplierFor` /
  `Mutations.SellFold` with your own tables. The *shape* is
  reusable; the numbers are not.
- **Income rates** → `AnimalConfig.Stats.Income.Base` and the
  `AnimalStats.Calculate` path. `IncomeService` calls
  `AnimalStats.Calculate(record, 'Income')` in exactly two places
  (`_tickPlayer`, `ApplyOfflineEarnings`); if your game computes the
  rate differently, change those two calls.
- **The `CashPool` concept** → if you do not want per-animal pools,
  delete `IncomeService` and call `EconomyService.AddMoney` from your
  own tick. The pool machinery (claim locks, settlement, sale
  consumption) is the part that is expensive to get right.
- **The multiplier application points** → they are enumerated in the
  `ModifierService` header (`IncomeService._tickPlayer` for money,
  `AnimalService.AddXP` for XP). Add a new source type by adding to
  `ModifierService.ModifierType` and `_isKnownType`, and by reading it
  at exactly one place.
- **The `TransactionReason` enum** → add your reasons to
  `ReplicatedStorage/Types/TransactionReason.lua` and to its `_ALL`
  list. Nothing else accepts a reason.
- **The offline policy** → `MaxOfflineSeconds` and
  `OfflineEffectiveness` in `Money.lua`. If offline should not pay at
  all, set `MaxOfflineSeconds = 0`.
- **The sell haircut** → `Animals.SellMultiplier`. Raising it above
  `1` breaks the "hatch-and-sell can never print money" invariant.
- **The `Sell` config** → `Config/Economy/Sell.lua` is pure
  presentation; replace the numbers freely. It is **not** read by
  `SellService` itself — the client-side confirmation controller
  reads it.
- **The `IncomeService` display binding** → the label lookup path
  (`SurfaceGui.Amount` / `CollectorGui.MoneyLabel`) and the
  `CashPool` attribute name are hardcoded in `IncomeService.lua:215-260`.
  Change both together if your world uses different names.
- **The `Money` seed** → `Money.StartingMoney` (`'5000'`). Changing it
  affects new players only.
