# Economy — API

Every public function of every module in the Economy system. Signatures
are verbatim from the source. **Nothing here throws** unless stated:
failures are returned as data.

---

## `ServerScriptService.EconomyService`

The single authoritative mutator for `profile.Data.Money`.

### Types

```lua
export type EconomyResult = {
    Success: boolean,
    NewMoney: string?,      -- nil on failure; the post-write balance on success
    Reason: string,         -- the TransactionReason that was passed in
    Code: string?,          -- 'invalid-reason' | 'no-profile' | 'invalid-amount'
                           -- | 'insufficient' | 'cap-exceeded'
    TransactionId: string?, -- 'tx-<userId>-<n>'
}
```

`NewMoney` is **nil on every failure**. Always check `.Success` before
reading it.

---

### `EconomyService.Init()`

No-op. The service holds no state until a profile is read. Every call
fails until `SetPlayerService` has run.

**Returns:** nothing. **Throws:** never.

---

### `EconomyService.SetPlayerService(playerService: any)`

Injects the profile owner. Must expose `GetPlayerData(userId) -> table?`
and, for the post-mutation push, `GetBaseId(userId)` and
`PushState(player, snapshot?)`.

**Returns:** nothing. **Throws:** never.

---

### `EconomyService.SetBaseService(baseService: any)`

Injects the base snapshot provider. Must expose `Snapshot(userId)`. Until
this is set, `pushMoneyState` is a no-op — money still changes, but the
HUD does not converge.

**Returns:** nothing. **Throws:** never.

---

### `EconomyService.GetMoney(userId: number): string`

The player's wallet as a canonical BigNumber string.

**Parameters:** `userId` — the player's UserId.

**Returns:** the sanitized balance string, e.g. `'12500.5'`. Returns
`'0'` — never `nil` — when the service is unwired, the profile is
absent, or `data.Money` is not a string.

**Throws:** never.

---

### `EconomyService.CanAfford(userId: number, cost: string): boolean`

Non-mutating compare of the wallet against a cost.

**Parameters:** `userId`, `cost` — a BigNumber decimal string.

**Returns:** `true` iff `Money >= cost`. A zero cost is always
affordable. `false` for a non-string cost, a cost that fails
`BigNumber.sanitize`, or an unwired/absent profile.

**Throws:** never. Use `TrySpendMoney` for the mutating path.

---

### `EconomyService.AddMoney(userId: number, amount: string, reason: string, opts: { ApplyMultiplier: boolean? }?): EconomyResult`

Adds `amount` to the wallet.

**Parameters:**
- `userId` — the player's UserId.
- `amount` — a BigNumber decimal string. Non-string → `invalid-amount`.
- `reason` — a `TransactionReason` value. An unknown value →
  `invalid-reason`, and **nothing moves**.
- `opts.ApplyMultiplier` — **defaults to `true`**. When true (the
  default) and `profile.Data.Multipliers.Money` is a number, the
  amount is multiplied by it. That field is **deprecated** and always
  `1` in legitimate profiles. Every live caller passes
  `{ ApplyMultiplier = false }`. A multiplier of `0` absorbs the grant
  (a legal, successful no-op); a negative or fractional multiplier
  fails with `invalid-amount`.

**Returns:** an `EconomyResult`.
- Success: `Success = true`, `NewMoney` = the new balance.
- The grant is clamped at `Money.MaxMoney`; the result is still a
  success but `Code = 'cap-exceeded'` and `NewMoney` is the capped
  value. **The clamped-away amount is not reported.**
- A zero amount is a success with the **unchanged** balance.
- Failures: `Code = 'invalid-reason' | 'no-profile' | 'invalid-amount'`.

**Throws:** never. On success it pushes the canonical `PlayerState`
(best-effort, `pcall`-guarded — it can never fail the transaction).

---

### `EconomyService.TrySpendMoney(userId: number, cost: string, reason: string, opts: { AllowNegative: boolean? }?): EconomyResult`

Atomic compare-then-debit.

**Parameters:**
- `userId`, `cost`, `reason` — as `AddMoney`.
- `opts.AllowNegative` — **accepted and ignored.** `BigNumber.Subtract`
  clamps at `'0'` regardless, and the caller has already checked
  `current >= cost`. The option exists so a future "borrowed money"
  flow does not need a signature change.

**Returns:** an `EconomyResult`.
- Success: `Success = true`, `NewMoney` = the balance after the debit.
- Insufficient funds: `Success = false`, `Code = 'insufficient'`, and
  **the balance is not mutated**.
- A zero cost is a success with the unchanged balance.
- Other failures: `Code = 'invalid-reason' | 'no-profile' | 'invalid-amount'`.

**Throws:** never. There is no `task.yield()` between the read and the
write, so a second same-script call on the same user sees the
post-write balance.

---

## `ServerScriptService.IncomeService`

Pools, the income tick, offline earnings, collection, settlement, and
the sale/collect race lock.

---

### `IncomeService.Init()`

No-op. All wiring arrives through the `Set*` injectors.

**Returns:** nothing. **Throws:** never.

---

### `IncomeService.SetPlayerService(ps: any)` / `SetEconomyService(es: any)` / `SetSlotService(ss: any)` / `SetBaseService(bs: any)` / `SetAnimalService(svc: any)`

Late-bound service refs.

- `SetPlayerService` — needs `GetPlayerData`, `ConsumeOfflineTimestamp`.
- `SetEconomyService` — needs `AddMoney`. **Required for collection and
  settlement.**
- `SetSlotService` — needs `FindSlotByOccupant`. **Required for income
  eligibility and sale consumption.**
- `SetBaseService` — needs `GetAllBases`. Required for the collector
  sweep.
- `SetAnimalService` — needs `GetCarriedAnimalByUserId` and
  `IsArenaDeployed`. Optional; the eligibility chain degrades
  (a carried animal would then earn, so wire it).

**Returns:** nothing. **Throws:** never.

---

### `IncomeService.SetModifierService(ms: any)`

Injects the multiplier authority. Needs `GetMoneyMultiplier(userId)`.

**Optional.** Unwired → every player resolves to `1×`. A throwing,
NaN, infinite, or non-positive result also degrades to `1×` (the call
is `pcall`-guarded).

**Returns:** nothing. **Throws:** never.

---

### `IncomeService.Start()`

Starts the ONE background income loop and takes the collector
`Touched` connections.

**Must be called after the bases and their collector parts exist** —
the connections are taken once, here. Runtime-created slots must go
through `EnsureCollectorsForSlots`.

**Idempotent:** a second call is a no-op.

**Returns:** nothing. **Throws:** never (the loop body is `pcall`-guarded;
a failing tick logs a warning and continues).

---

### `IncomeService.TickSources(elapsed: number, userIds: { number }?)`

Advances every (or the given) player's sources by `elapsed` real
seconds. Synchronous and yield-free.

**Parameters:**
- `elapsed` — seconds. A non-number, NaN, or `<= 0` is ignored.
- `userIds` — optional list. When omitted, the current
  `Players:GetPlayers()` list is used. This is the testability seam.

**Returns:** nothing. **Throws:** never.

---

### `IncomeService.ApplyOfflineEarnings(player: Player)`

Credits the capped offline window into the player's animals' `CashPool`s.

**Contract:**
- The offline anchor is consumed **exactly once** via
  `PlayerService.ConsumeOfflineTimestamp` — a window can never pay
  twice.
- The window is clamped to `Money.MaxOfflineSeconds`.
- The Money multiplier applies at `Money.OfflineEffectiveness`
  (0.5). **Note:** the module header claims the multiplier "NEVER
  applies" offline; the code at `IncomeService.lua:522-528` applies it.
  The code wins.
- The same eligibility chain as the online tick: carried, slotless,
  wrong-owner, and non-Animal records earn nothing.
- **No XP, no levels, no stats, and no wallet writes.** Only
  `CashPool`.

**Parameters:** `player` — the joining player.

**Returns:** nothing. **Throws:** never (a missing anchor, a missing
profile, or an unwired `PlayerService` all result in "pay nothing").

---

### `IncomeService.TryCollect(slot: any, player: Player)`

Attempts to transfer one slot's pool into the player's wallet.

**Parameters:**
- `slot` — a slot record. Needs `id`, `ownerUserId`, `state`,
  `occupantKind`, `occupantId`, `cashCollector`.
- `player` — the touching player.

**Validation chain (all silent no-ops on rejection):**
1. `Validation.CanPlayerInteract(player)` — a dead character collects
   nothing. Non-Player table shims pass through.
2. `slot.ownerUserId == player.UserId`.
3. `slot.state == 'Occupied'` and `slot.occupantKind == 'animal'`.
4. `playerService` and `economyService` are wired.
5. The per-player debounce (`Money.CollectorDebounceSeconds`) has
   elapsed.
6. The slot's claim lock is free.

**On success:** the pool is added to the wallet with
`{ ApplyMultiplier = false }` (a transfer, not a grant), the pool is
zeroed, the slot's attribute and label are republished as `'0'`,
`CollectFeedback.Play` runs, and `CashCollected` is fired to the
collecting player.

**On an `AddMoney` failure:** the pool is **preserved** and a warning
is logged.

**On a slot with no matching profile record:** a **loud warning** — this
is a state inconsistency, not normal rejection.

**Returns:** nothing. **Throws:** never — the whole body is `pcall`-guarded
and the claim lock is always released.

---

### `IncomeService.SettleAnimalPool(userId: number, record: any)`

Transfers a removed animal's pool into the owner's wallet. Injected
into `PlayerService` via `SetAnimalPoolSettlementHandler` so every
removal settles **before** the record leaves the profile.

**Parameters:** `userId`, `record` — the animal record.

**Returns:** nothing. **Throws:** never. A non-`'Brainrot'` record or a
zero pool is a no-op. A failed grant **preserves the value on the
record** and warns — never a silent delete. `WipeUser` deliberately
does **not** route through here.

---

### `IncomeService.ConsumePoolForSale(userId: number, animalId: string): (string?, string?)`

Atomically takes an animal's pool for a sale.

**Parameters:** `userId`, `animalId`.

**Returns:** `(pool, nil)` on success, where `pool` is the BigNumber
string taken from the record. On failure: `(nil, code)` with `code`
one of:
- `'unavailable'` — bad input, or `playerService`/`slotService` unwired.
- `'not-found'` — no such record in the profile.
- `'no-slot'` — the animal has no live slot.
- `'busy'` — a collection is in flight on that slot.
- `'error'` — an unexpected error inside the critical section.

**The caller MUST pay the returned pool into the sale.** On a payment
failure the caller must add the pool back onto the (still live) record
itself — this function never restores.

**Throws:** never.

---

### `IncomeService.EnsureCollectorsForSlots(slots: any)`

Wires the `Touched` connection for runtime-created slots. Idempotent
per part (already-wired parts are skipped). Never throws.

**Returns:** nothing.

---

### `IncomeService.ForgetCollectorsForSlots(slots: any)`

Drops the part-keyed maps for runtime-destroyed slots, so a destroyed
part never pins a stale slot record. Never throws.

**Returns:** nothing.

---

### `IncomeService.RepublishSlot(slot: any)`

Recomputes and publishes one slot's pool (the `CashPool` attribute +
the display label) immediately, bypassing the sweep throttle. Called
by the SlotService display hook on every slot transition.

**Returns:** nothing. **Throws:** never — a no-op on any unexpected
shape.

---

### `IncomeService.ForgetPlayer(userId: number)`

Drops the player's per-session collection debounce and their
fractional-income remainders. Does **not** touch the pool value (that
lives on the profile record).

**Returns:** nothing. **Throws:** never.

---

## `ServerScriptService.ModifierService`

The ONE place a multiplier is resolved.

### Enums

```lua
ModifierService.ModifierType = { MoneyMultiplier = 'MoneyMultiplier', XPModifier = 'XPModifier' }
ModifierService.Operation    = { Multiply = 'Multiply' }

export type ModifierSource = {
    SourceId: string,
    Type: string,
    Value: number,
    Operation: string,
    Metadata: any?,
}
```

---

### `ModifierService.Init()`

No-op. State is created on the first `AddModifier`.

---

### `ModifierService.AddModifier(userId: number, sourceId: string, modifierType: string, value: number, operation: string?, metadata: any?): (boolean, string?)`

Adds or **replaces** one modifier source.

**Parameters:**
- `userId` — must pass `Validation.IsValidPlayerUserId`.
- `sourceId` — a non-empty string, at most 64 characters.
- `modifierType` — `'MoneyMultiplier'` or `'XPModifier'`.
- `value` — a finite number, `> 0` and `<= 1_000_000`.
- `operation` — optional; defaults to `'Multiply'`. Any other value is
  rejected.
- `metadata` — optional; must be `nil` or a table.

**Returns:** `(true)` on success, or `(false, code)` with `code` one of
`'invalid-player'`, `'invalid-source'`, `'invalid-type'`,
`'invalid-value'`, `'unsupported-operation'`, `'invalid-metadata'`.

Re-adding the same `(userId, type, sourceId)` **replaces** the previous
source. A source can never double-count itself.

**Throws:** never.

---

### `ModifierService.RemoveModifier(userId: number, sourceId: string, modifierType: string?): boolean`

Removes one source. With `modifierType` omitted, removes `sourceId`
from **every** type.

**Returns:** `true` iff something was actually removed; `false`
otherwise (including for an invalid userId, an invalid sourceId, an
unknown type, or a source that was not present).

**Throws:** never.

---

### `ModifierService.GetModifiers(userId: number, modifierType: string?): { ModifierSource }`

The active sources for a player.

**Returns:** an array of **copies**, sorted by `Type` then `SourceId`.
An invalid userId or an unknown type filter returns an empty array. The
caller can mutate the result without touching authoritative state.

**Throws:** never.

---

### `ModifierService.GetMoneyMultiplier(userId: number): number`

The resolved Money multiplier. `1` when no sources are active.

Never NaN, never infinite, never `<= 0` — a poisoned entry degrades to
a skip, not a cascade.

**Throws:** never.

---

### `ModifierService.GetXPModifier(userId: number): number`

The resolved XP multiplier. `1` when no sources are active. Same
guarantees as above.

---

### `ModifierService.GetResolvedModifiers(userId: number): { MoneyMultiplier: number, XPModifier: number, MoneySources: { ModifierSource }, XPSources: { ModifierSource } }`

Both resolved values plus both source lists in one call.

**Throws:** never.

---

### `ModifierService.ForgetPlayer(userId: number)` / `ModifierService.ClearModifiers(userId: number)`

Drops every source for a player. `ClearModifiers` is an alias.

**Returns:** nothing. **Throws:** never.

---

## `ServerScriptService.SellService`

The ONE authority for selling animals. **Eggs are not sellable.**

### Error codes

```lua
SellService.Error = {
    InvalidPlayer = 'invalid-player',
    InvalidId = 'invalid-id',
    NotFound = 'not-found',
    NotOwner = 'not-owner',
    Busy = 'busy',
    Carried = 'carried',
    InvalidState = 'invalid-state',
    InvalidDefinition = 'invalid-definition',
    InvalidLevel = 'invalid-level',
    InvalidRarity = 'invalid-rarity',   -- declared, never returned
    NoSellValue = 'no-sell-value',
    SlotState = 'slot-state',
    PoolBusy = 'pool-busy',
    GrantFailed = 'grant-failed',
    ServiceUnavailable = 'service-unavailable',
}
```

---

### `SellService.Init()`

Wires the Sell prompt dispatch (`CarryPrompts.SetSellPromptCallback`)
and the `SellConfirmAction` remote.

**Idempotent** — a second call is a no-op. If the remote is missing it
warns (`'SellConfirmAction remote missing'`) and continues.

**Returns:** nothing. **Throws:** never (the remote wiring is
`pcall`-guarded).

---

### `SellService.SetPlayerService / SetSlotService / SetBaseService / SetAnimalService / SetEconomyService / SetIncomeService / SetModifierService`

Late-bound service refs. **All six of `playerService`, `slotService`,
`baseService`, `animalService`, `economyService`, and `incomeService`
must be set** before a sale — otherwise every sale returns
`'service-unavailable'`.

`SetModifierService` is optional (unwired → 1×; it is only used for
the display-only $/sec figure in the preview).

**Returns:** nothing. **Throws:** never.

---

### `SellService.SetEggService(_svc: any)`

**Compat no-op.** Eggs are not sellable, so the egg service is never
read. The setter exists only so bootstrap wiring is unchanged.

---

### `SellService.GetAnimalBaseSellValue(definitionId: string): string?`

The base sell value for an animal definition.

**Parameters:** `definitionId` — a catalogue definition id.

**Returns:** a BigNumber string, or `nil` when the id is not a string,
is empty, is not in the catalogue, or its rarity has no valid
`SellBaseValue` entry.

**Throws:** never (`AnimalConfig.Get` is `pcall`-guarded).

---

### `SellService.GetAnimalLevelSellValue(definitionId: string, level: number, trait: string?, mutations: { string }?): string?`

The level-adjusted sell value.

`base × level × Animals.SellMultiplier[rarity] × Traits.SellMultiplierFor(trait) × Mutations.SellFold(mutations)`, computed with
`BigNumber.Multiply` and `BigNumber.MultiplyDecimal` — exact decimal
strings, no float dust. Optional `trait`/`mutations` default to 1×.

**Parameters:** `definitionId`, `level` (an integer in `1..MaxLevel`),
`trait` (optional string), `mutations` (optional array of strings).

**Returns:** the exact BigNumber string, or `nil` for an invalid
definition, an invalid level, or a failed multiplication.

**Throws:** never.

---

### `SellService.GetAnimalTotalPayout(definitionId: string, level: number, pool: string, trait: string?, mutations: string?): string?`

The total payout: the level-adjusted value **plus** the current pool.

**Parameters:** as above, plus `pool` — the animal's current `CashPool`
as a BigNumber string. A malformed pool is sanitized to `'0'`.

**Returns:** the exact BigNumber string, or `nil` on any failure.

**Throws:** never.

---

### `SellService.SellAnimal(player: Player, animalId: string): { [string]: any }`

The sale transaction. **Atomic**: the pool is consumed under the slot's
claim lock, then a single grant pays `saleValue + pool`, then the
animal is torn down.

**Parameters:** `player` — the seller; `animalId` — the animal to sell.

**Returns:**
- Success: `{ success = true, payout = <BigNumber string>, saleValue = <BigNumber string>, pool = <BigNumber string> }`.
- Failure: `{ success = false, error = <code from SellService.Error> }`.

**Failure codes and their causes:**
| Code | Cause |
|---|---|
| `invalid-player` | Not a live `Player`. |
| `invalid-id` | `animalId` is not a non-empty string. |
| `service-unavailable` | Not all six service refs are wired. |
| `not-found` | No runtime animal with that id. |
| `not-owner` | The animal belongs to another player. |
| `busy` | A sale or upgrade is already in flight on the animal (`_mutex`), **or** the animal is raid-locked. |
| `carried` | The animal is being carried. |
| `invalid-state` | The animal is `Consumed` or `Destroyed`. |
| `invalid-definition` | Missing or unknown `definitionId`. |
| `invalid-level` | The level is not an integer in `1..MaxLevel`. |
| `slot-state` | The animal is not on a live `Occupied` slot owned by the seller, or the slot is missing. |
| `no-sell-value` | The payout could not be computed. |
| `pool-busy` | A collection was in flight on the slot (`ConsumePoolForSale` returned `'busy'`). |
| `grant-failed` | `EconomyService.AddMoney` failed. **The pool is restored onto the still-live record** and the animal is untouched. |

**On success** the service also: destroys the runtime animal, releases
the slot, unregisters the slot's prompts, removes the profile record,
tries to deliver pending code rewards, fires `CashCollected`, pushes
`PlayerState`, and sends a success notification.

**Throws:** never.

---

### `SellService.PreviewSell(player: Player, animalId: string): { [string]: any }`

Validates sellability and pushes the confirmation data to the client.
**Strictly read-only** — no mutex, no money, no mutation.

**Parameters:** `player`, `animalId`.

**Returns:**
- Success: the pushed state table — `{ Valid = true, AnimalId, SlotId,
  Name, Rarity, Trait?, Level, LevelText, GenerationText, Mutations,
  SellValueRaw?, Model? }`. `Model` is the **live** animal Model
  instance (the client clones it locally; the live model is never
  reparented or mutated). `SellValueRaw` is the raw BigNumber string.
- Failure: `{ Valid = false, AnimalId, Reason }` with `Reason` one of
  `'invalid-player'`, `'invalid-id'`, `'service-unavailable'`,
  `'not-found'`, `'not-owner'`, `'busy'`, `'invalid-state'`,
  `'slot-state'`, `'invalid-definition'`, `'invalid-level'`.

**Throws:** never. The state is pushed with `pcall(Remotes.FireClient, ...)`.

---

### `SellService.ConfirmSell(player: Player, animalId: string): { [string]: any }`

The final confirmation. Re-resolves everything and runs the canonical
`SlotActionHandler.Handle(player, { Action = 'SellAnimal', SlotId,
OccupantId })` pipeline.

**Parameters:** `player`, `animalId`.

**Returns:** the handler's result table — `{ success = true, payout, ... }`
or `{ success = false, error }`. A stale or invalid target yields
`{ success = false, error = 'stale' }`.

Always fires `SellConfirmResult { AnimalId, Success, Error }` to the
client.

**Throws:** never.

---

## Not part of the public API

| Symbol | Why it is not public |
|---|---|
| `SellService.Error.InvalidRarity` | Declared in the error table but never returned by any code path. |
| `IncomeService`'s `_frac`, `_claims`, `_published`, `_lastTouch` | Module-local state. |
| `EconomyService`'s `_playerService`, `_baseService`, `_txCounter` | Module-local state. |
| `ModifierService._sources` | Module-local state. |
| `IncomeService._sweepPublish` | Module-local; the public entry is `RepublishSlot`. |
