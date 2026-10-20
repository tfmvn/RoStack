# Shops and Purchases — API

Every public function of every module in the Shops and Purchases
system. Signatures are verbatim from the source.

**Error conventions:**

- `ShopService` **never throws**. Failures are expressed as a
  returned `Enum.ProductPurchaseDecision` or a `false`/`nil`.
- `DoorService` **never throws**. Failures are expressed as `false`
  (an internal error) or as a **consumed** receipt (`true`).
- `ShopConfig.FindProduct` returns `nil` for an unknown id.
- **Neither service has an error-code table.** The failure
  vocabulary lives in the log channel (`'SHOP'`, `'DOOR'`) and in
  the receipt decision.

---

## `ServerScriptService.Shop.ShopService`

The ONE authoritative `MarketplaceService.ProcessReceipt` router.

### `ShopService.Init()`

Installs the receipt router and wires the `ShopAction` remote.

**Returns:** nothing. **Throws:** never.

Behaviour:
- Idempotent — a second call returns immediately (`_started` guard).
- `pcall(function() MarketplaceService.ProcessReceipt = _handleReceipt end)`.
  A failure here is swallowed; the module comment says a second
  assignment would silently eat receipts, so **this must be the only
  one**.
- Wires `ShopAction`: `Remotes.GetFolder():WaitForChild(Remotes.Names.ShopAction, 10)`,
  then `assert(remote and remote:IsA('RemoteEvent'), 'ShopAction remote missing')`,
  then `OnServerEvent:Connect(handleAction)`. The whole block is
  `pcall`-guarded — a missing remote **degrades loudly but does not
  block boot**, and the receipt router still installs.
- Subscribes `ServerLuckService.OnBoostExpired` → announces
  `'Shop_LuckExpired'` to every player in the server.

**Ordering constraint:** call it **after** every service it calls
into and **before players join**. The requires are direct — there is
no injection.

---

### `ShopService.OnPlayerReady(player: Player)`

The join hook. A **silent** entitlement sync — the player sees no
toast.

**Parameters:** `player` — the joining player.

**Returns:** nothing. **Throws:** never.

Implementation: `pcall(ShopService.SyncGamepassAsync, player)`. Any
error is swallowed.

**Note:** the gamepass modifier is **session-scoped**
(`ModifierService` never persists), so this call is what makes the
2X Money multiplier exist at all for this session. If you skip it,
gamepass owners have no multiplier until they rejoin or sync.

---

### `ShopService.SyncGamepassAsync(player: Player): boolean`

The authoritative 2X Money entitlement check. Applies or removes the
session multiplier to match the resolved state.

**Parameters:** `player` — the player to check.

**Returns:** `true` when the player **owns** the gamepass, `false`
otherwise. **Throws:** never.

Behaviour:
1. `Validation.LivePlayer(player)` → `false` if the player is not
   live.
2. `MarketplaceService:UserOwnsGamePassAsync(userId, ShopConfig.Gamepasses.Money2x.GamepassId)`
   inside a `pcall`. **A network failure leaves `owned = false`** —
   the entitlement is then treated as absent and the modifier is
   removed.
3. If owned → `ModifierService.AddModifier(userId, 'Gamepass_2XMoney', ModifierType.MoneyMultiplier, 2, Operation.Multiply)`.
   If not owned → `ModifierService.RemoveModifier(userId, 'Gamepass_2XMoney')`
   (the revoked / refunded edge).
4. A **lazy** `require` of `RebirthService` and a
   `RefreshBaseMultiplier(userId)` call, so the owner's base label
   repaints immediately. Both are `pcall`-guarded — if Rebirth is
   absent, this is skipped silently.
5. If owned → a `GamepassSynced` funnel step.

**Never trust the client.** This method always re-resolves from
Roblox; the client never asserts ownership.

---

### `ShopService.ForgetPlayer(userId: number)`

Leave cleanup.

**Parameters:** `userId` — the departing player's user id.

**Returns:** nothing. **Throws:** never.

Clears the per-player `ShopAction` throttle stamp. It does **not**
touch the receipt dedupe set (that is bounded and shared) and does
**not** touch the door pending context (that belongs to
`DoorService`).

---

### `ShopService._TestHandleReceipt(info: any): Enum.ProductPurchaseDecision`

Test-only seam. Calls `_handleReceipt` directly.

**Parameters:** `info` — a fake receipt table
(`{ PurchaseId, PlayerId, ProductId }`).

**Returns:** the decision. **Throws:** never.

---

### `ShopService._TestReset()`

Test-only seam. Clears `_seenReceipts`, `_lastShopActionAt`,
`_lastPromptAt` and resets `_started` to `false` (so `Init()` can run
again).

**Returns:** nothing. **Throws:** never.

---

### The receipt contract (`MarketplaceService.ProcessReceipt`)

This is the contract the whole module exists to honour.

| Situation | Decision | Side effects |
|---|---|---|
| `info` is not a table, or `PurchaseId` is not a string, or `PlayerId` / `ProductId` are not numbers | `PurchaseGranted` | none. A loud warn. **Nothing is granted.** |
| `PurchaseId` already seen | `PurchaseGranted` | none. |
| `ProductId` is not in `ShopConfig` | `NotProcessedYet` | a loud warn. Retries until the registry is fixed. |
| The buyer has left, and the kind is player-bound (`Money`, `Gear`, `SkipDaily`, `SkipPlaytime`) | `NotProcessedYet` | none. |
| The buyer has left, and the kind is `ServerLuck` | `PurchaseGranted` | **the boost applies server-wide.** |
| The buyer has left, and the kind is `UnlockDoors` | `NotProcessedYet` | none. The pending context survives the leave. |
| The kind has no handler | `NotProcessedYet` | a loud warn. |
| A grant helper returned `'retry'` | `NotProcessedYet` | partial side effects may exist — every grant path is idempotent. |
| A grant helper returned `'granted'` | `PurchaseGranted` | the grant, the dedupe write, the funnel steps, the milestone log. |

**The dedupe write happens only on the `'granted'` branch.** A failed
grant is therefore not recorded, so Roblox's retry actually retries.

---

## `ServerScriptService.Shop.DoorService`

The paid-door flow.

### `DoorService.Init()`

Subscribes to the lock-changed event so prompts stay in sync.

**Returns:** nothing. **Throws:** never.

Idempotent (`_started` guard). Subscribes the **module-level named
function** `_onLockChanged` — a named subscriber so repeated `Init()`
calls never stack subscriptions. `_onLockChanged` reads
`info.baseId` and calls `DoorService.RefreshBase(baseId)`.

---

### `DoorService.RefreshBase(baseId: string)`

Reconciles one base's prompt with its live lock state.

**Parameters:** `baseId` — the base's id.

**Returns:** nothing. **Throws:** **never** — the whole body is in
a `pcall`.

Behaviour:
- A non-string or empty `baseId` → no-op.
- Resolves the base via `BaseService.GetBaseById(baseId)` (also
  `pcall`-guarded).
- The prompt parent is `base.collector`, and must be a `BasePart`.
- **The prompt exists IFF** the base is owned (`ownerUserId` is a
  number) **AND** `BaseLockService.IsLocked(baseId)` **AND** the
  collector is a `BasePart`.
- Owned + locked + no collector → a loud warn
  (`'locked base has no collector; prompt unavailable'`) and no
  prompt.
- Should exist → create a `ProximityPrompt` named `'OpenDoorPrompt'`
  with `ActionText` / `ObjectText` / `HoldDuration` /
  `MaxActivationDistance` / `RequiresLineOfSight` from
  `Prompts.DoorOpen`, the attributes `ownerUserId`, `doorPrompt = true`
  and `baseId`, and a `Triggered` connection to
  `DoorService.RequestOpen`.
- Already exists → re-stamp the `ownerUserId` attribute and return
  (the prompt is reused, not recreated).
- Should not exist → `existing:Destroy()` (idempotent).

---

### `DoorService.RequestOpen(player: Player, prompt: ProximityPrompt): boolean`

Server-side validation and the purchase dialog.

**Parameters:**
- `player` — the triggering player.
- `prompt` — the `ProximityPrompt` that fired.

**Returns:** `true` when the purchase dialog was shown, **or** when
the buyer already holds a grant (no dialog, no charge). `false`
otherwise. **Throws:** never.

Validation order:
1. `Validation.LivePlayer(player)`.
2. `Validation.CanPlayerInteract(player)`.
3. `prompt` is an `Instance` and `IsA('ProximityPrompt')`.
4. `prompt:GetAttribute('baseId')` is a non-empty string.
5. `BaseService.GetBaseById(baseId)` returns a table with a numeric
   `ownerUserId`.
6. `BaseLockService.IsLocked(baseId)` — else reject (logged `'rejected
   unlocked'`).
7. `base.ownerUserId ~= player.UserId` — else reject (logged
   `'rejected owner'`).
8. `BaseLockService.HasPurchasedAccess(baseId, player.UserId)` →
   if the buyer already holds a grant, notify `'Shop_DoorOpened'`,
   return **`true`**, and **never re-prompt or re-charge**.
9. Distance: `prompt.Parent` must be a `BasePart`, the player must
   have a `HumanoidRootPart`, and the distance must be
   `<= Prompts.DoorOpen.MaxActivationDistance + Security.Door.RangeSlackStuds`
   (12 + 2 = 14 studs). Else reject (logged `'rejected out of range'`).
10. Throttle: `Security.Door.RequestCooldownSeconds` (5) per player.
11. Store `_pending[player.UserId] = { baseId, ownerId, at }`.
12. `MarketplaceService:PromptProductPurchase(player, ShopConfig.DeveloperProducts.UnlockDoors.ProductId)`.
    If the call throws, the pending context is **removed again** and
    the function returns `false`.

**Never trusts client state.** The base, the ownership, the lock
state, the liveness, and the distance all re-resolve server-side.

---

### `DoorService.GrantPendingUnlock(player: Player?): boolean`

Fulfills a validated Unlock Doors purchase.

**Parameters:** `player` — the buyer. **`nil` is legal.**

**Returns:** `true` when the receipt is **settled** (consume it),
`false` only on an internal error (retry). **Throws:** never.

> **`true` does not mean "the door opened."** It means "the receipt
> is settled" — which includes every terminal no-op. The door may not
> have opened at all.

The decision table — **every one of these returns `true`**:

| Situation | Side effects |
|---|---|
| `player` is `nil` | none. Consumed silently (there is no `userId` to key a context by). |
| No pending context | a loud warn + a `'General_Generic'` warning toast to the buyer. Consumed. |
| The base is gone | a loud warn + a buyer toast. Consumed. |
| The base is **not locked** and the owner is **unchanged** and the buyer is **still not the owner** | **`BaseLockService.UnlockPurchased(baseId, buyerUserId)` — the grant IS recorded** (the buyer paid for access, and a later owner re-lock must not revoke it) + a `'Shop_DoorOpened'` toast. |
| The base is **not locked** and anything else | a loud warn + a buyer toast. Consumed. No unlock. |
| The owner changed since the request | a loud warn + a buyer toast. Consumed. **No unlock** — a receipt never opens a new owner's base. |
| The buyer is now the owner | a loud warn + a buyer toast. Consumed. No unlock. |
| The happy path | `BaseLockService.UnlockPurchased(baseId, buyerUserId)` — opens now **and** records the buyer + a `'Shop_DoorOpened'` toast. |

**The pending context is consumed on read** — `_pending[userId]` is
cleared before the grant is evaluated, so a repeat receipt cannot
re-grant. The grant itself is idempotent inside `BaseLockService`.

**The base owner is never notified** that their door was bought.

---

### `DoorService.ForgetPlayer(userId: number)`

Leave cleanup.

**Parameters:** `userId` — the departing player's user id.

**Returns:** nothing. **Throws:** never.

Clears **only** the throttle stamp. It deliberately **does NOT** clear
the pending purchase context — a buyer who disconnects mid-dialog and
rejoins must still fulfill when the receipt retries. The pending
context dies by **TTL** (15 minutes), never by leave.

> The source game's bootstrap comment says this call "drop[s] pending
> door-purchase contexts". That comment is **stale** — the code does
> the opposite, on purpose.

---

### `DoorService._TestPending(userId: number): any?`

Test-only seam. Returns the pending context
(`{ baseId, ownerId, at }`) or `nil`.

**Returns:** the context or `nil`. **Throws:** never.

---

### `DoorService._TestSetPending(userId: number, ctx: any?)`

Test-only seam. Plants a pending context. Passing a non-table `ctx`
(or `nil`) clears it.

**Returns:** nothing. **Throws:** never.

---

### `DoorService._TestReset()`

Test-only seam. Clears `_pending` and `_lastRequestAt`, and resets
`_started` to `false`.

**Returns:** nothing. **Throws:** never.

---

## `ReplicatedStorage.Config.Economy.Shop`

The single registry for all monetization product identities.

### `Shop.ProductKind`

```lua
Shop.ProductKind = {
    Money = 'Money',
    Gear = 'Gear',
    ServerLuck = 'ServerLuck',
    UnlockDoors = 'UnlockDoors',
    SkipDaily = 'SkipDaily',
    SkipPlaytime = 'SkipPlaytime',
}
```

### `Shop.DeveloperProducts`

A table of 12 entries, keyed by feature key. Each entry:

```lua
{
    Key = string,
    ProductId = number,
    Robux = number,        -- DISPLAY ONLY
    Kind = string,          -- one of Shop.ProductKind
    Amount = string?,       -- Money: the raw BigNumber grant string
    GearId = string?,       -- Gear: the gear catalogue id
    Multiplier = number?,   -- ServerLuck: the luck multiplier
}
```

| Key | ProductId | Robux | Kind | Payload |
|---|---|---|---|---|
| `ServerLuck2x` | 3715397847 | 99 | `ServerLuck` | `Multiplier = 2` |
| `UnlockDoors` | 3715397812 | 29 | `UnlockDoors` | — |
| `ServerLuck4x` | 3715398478 | 199 | `ServerLuck` | `Multiplier = 4` |
| `GalaxyBat` | 3715398070 | 199 | `Gear` | `GearId = 'GalaxyBat'` |
| `ServerLuck8x` | 3715398723 | 499 | `ServerLuck` | `Multiplier = 8` |
| `MoneyPack1` | 3715397862 | 19 | `Money` | `Amount = '10000'` |
| `MoneyPack2` | 3715397884 | 49 | `Money` | `Amount = '50000'` |
| `MoneyPack3` | 3715397918 | 99 | `Money` | `Amount = '250000'` |
| `MoneyPack4` | 3715397931 | 199 | `Money` | `Amount = '500000'` |
| `MoneyPack5` | 3715397968 | 249 | `Money` | `Amount = '1000000'` |
| `SkipPlaytime` | 3716261541 | 149 | `SkipPlaytime` | — |
| `SkipDaily` | 3716261585 | 249 | `SkipDaily` | — |

> **All 12 `ProductId`s are placeholders for a new game.** Replace
> them with the ids from your own Creator Dashboard.

---

### `Shop.Gamepasses`

```lua
Shop.Gamepasses = {
    Money2x = {
        Key = 'Money2x',
        GamepassId = 2002490328,
        Robux = 199,
    },
}
```

> **The `GamepassId` is also a placeholder.** Replace it.

---

### `Shop.ServerLuckDurations`

```lua
Shop.ServerLuckDurations = { [2] = 900, [4] = 600, [8] = 300 }
```

Keyed by the **multiplier number**, value = seconds. Every multiplier
used by a `ServerLuck` product **must** have an entry — a missing one
makes the receipt retry forever (`'luck product misconfigured'`).

---

### `Shop.ByProductId`

The reverse lookup, built **at require time**. `{ [productId] =
ProductEntry }`.

On a **duplicate `ProductId`** the module `warn()`s and **keeps the
first entry** — the second entry is dropped from the reverse map
entirely (it is still reachable by key), so the receipt routing stays
deterministic.

---

### `Shop.FindProduct(productId: number): ProductEntry?`

The reverse lookup by id.

**Parameters:** `productId` — the Developer Product id.

**Returns:** the entry, or `nil`.

**Returns `nil` when:**
- `productId` is not a number;
- the id is not in the registry.

**Throws:** never.

---

### `Shop.CardMap`

```lua
Shop.CardMap = {
    ['Money/Row1/1'] = 'MoneyPack1',
    ['Money/Row1/2'] = 'MoneyPack2',
    ['Money/Row1/3'] = 'MoneyPack3',
    ['Money/Row2/4'] = 'MoneyPack4',
    ['Money/Row2/5'] = 'MoneyPack5',
    ['Passes/5']     = 'Money2x',
    ['Items/1']      = 'GalaxyBat',
}
```

Studio card path → product key. **Deliberately unmapped**:
`Events/1`, `Passes/4`, `Items/2`, `Featured/StarterPack` — *"guessing
a charge is worse than a loud error"*.

A `ProductId` **number attribute** stamped on the Buy button in
Studio **wins** over the `CardMap`.

---

### `Shop.Validate()`

**Does not exist.** `Shop.lua` is the only config in this library
without a `Validate()`. Its integrity is covered by
`Tests/ShopConfig.spec.lua` instead.

---

## Not part of the public API

| Symbol | Why it is not public |
|---|---|
| `ShopService`'s `_handleReceipt`, `_rememberReceipt`, `_buyerName`, `_celebrate`, `_grantMoney`, `_grantGear`, `_grantLuck`, `_grantSkipDaily`, `_grantSkipPlaytime`, `_grantUnlockDoors`, `_logPromptIntent`, `handleAction` | Module-local helpers. `handleAction` is reachable only through the `ShopAction` remote. |
| `ShopService`'s `GAMEPASS_2X_SOURCE` | A module-local constant (`'Gamepass_2XMoney'`). It is hardcoded, not read from the config. |
| `DoorService`'s `_sweepStalePending`, `_promptParent`, `_findPrompt`, `_onLockChanged` | Module-local helpers. |
| `DoorService`'s `PROMPT_NAME`, `REQUEST_COOLDOWN_S`, `RANGE_SLACK`, `PENDING_TTL_S` | Module-local constants. `PROMPT_NAME` is hardcoded; the others are read from `Security.lua` (except `PENDING_TTL_S`). |
| `ShopConfig`'s `ByProductId` construction block | It runs once at require time. |
| `ShopConfig`'s `ProductEntry` type | It is `export type` — a type, not a runtime value. |

---

## Related APIs you will need

These live in other systems, but the shop calls them.

### `EconomyService.AddMoney(userId, amount, reason)` — Economy system

Returns an `EconomyResult`:
`{ Success, NewMoney?, Reason, Code?, TransactionId? }`. It never
throws and never mutates on failure. The shop uses the reason
`'ShopMoneyPack'`.

### `GearShopService.GrantRobuxGear(player, gearId)` / `EquipGear(player, gearId)` — Gear system

`GrantRobuxGear` must return exactly `true` for the grant to count.
`EquipGear` is **best-effort** — its failure never causes a retry.

### `ServerLuckService.ActivateBoost(mult, durationSecs, source)` / `OnBoostExpired(fn)` — ServerLuck system

`ActivateBoost` returns a token (`number?`) or `nil` on failure.
`OnBoostExpired` takes a callback.

### `ModifierService.AddModifier(userId, sourceId, type, value, operation)` / `RemoveModifier` / `GetModifiers(userId)` — Economy system

`AddModifier` returns `(boolean, string?)` — the second value is a
failure code. The shop's `pcall` swallows failures.

### `BaseLockService.UnlockPurchased(baseId, purchaserUserId?)` / `HasPurchasedAccess(baseId, userId)` / `IsLocked(baseId)` / `SubscribeLockChanged(fn)` — BasesAndSlots system

`UnlockPurchased` opens the base **and** records the buyer. The
buyer's grant survives a later owner re-lock and clears on base
release / reassign / wipe.

### `BaseService.GetBaseById(baseId)` — BasesAndSlots system

Returns the base record (with `ownerUserId` and `collector`), or
`nil`.

### `DailyRewardsService.GrantSkipAccess(player)` / `ClaimAll(player)` — DailyRewards system

The shop calls **`GrantSkipAccess` first**, then `ClaimAll`. The
receipt **is** the entitlement.

### `PlaytimeRewardsService.GrantSkipAccess(player)` / `ClaimAll(player)` — PlaytimeRewards system

Same order.

### `MarketplaceService:PromptProductPurchase(player, productId)` — Roblox

The only purchase prompt the **server** opens. Throwing removes the
pending context.

### `MarketplaceService:UserOwnsGamePassAsync(userId, gamepassId)` — Roblox

The only entitlement check. A throw is treated as "not owned".
