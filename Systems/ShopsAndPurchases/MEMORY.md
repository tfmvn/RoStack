# Shops and Purchases — MEMORY

Dense engineering notes for a future agent. Everything here is read
from the actual source in this folder, not inferred.

---

## Purpose, in one line

Turn a Roblox Marketplace purchase into a canonical, idempotent,
server-authoritative gameplay action — and let a stranger buy their way
past a locked base.

---

## How it actually works

### Two services, one router

`ShopService` owns **the one** `MarketplaceService.ProcessReceipt`
implementation in the game. `DoorService` owns the paid-door flow and
is called *by* `ShopService` when a receipt resolves to the
`UnlockDoors` kind.

`ShopService` uses **direct `require` for every dependency** — there
is no `Set*Service()` injection anywhere in this system. That is the
single biggest structural difference from the Economy / Upgrades /
Rebirth systems. Consequence: `ShopService` must be `Init()`ed
**after** every service it calls into, or the first receipt hits an
uninitialised dependency. The bootstrap comment says exactly this.

`DoorService` also uses direct requires.

### The receipt algorithm (`ShopService._handleReceipt`)

1. Read `info.PurchaseId`, `info.PlayerId`, `info.ProductId` from
   `info` (guarding `type(info) == 'table'` first).
2. **Malformed** (`PurchaseId` not a string, or `PlayerId` /
   `ProductId` not a number) → `Debug.Warn` → return
   `Enum.ProductPurchaseDecision.PurchaseGranted`.
   *Why granted, not retry:* the receipt cannot be identified, so
   retrying loops forever. The purchase is marked handled and nothing
   is granted (there is no product to resolve).
3. **Already seen** (`_seenReceipts[purchaseId] ~= nil`) → return
   `PurchaseGranted` immediately. The first pass already fulfilled it.
   No side effects run.
4. **Unknown ProductId** (`ShopConfig.FindProduct(productId) == nil`)
   → `Debug.Warn` → return `NotProcessedYet`. Roblox retries. This
   is the "the registry is wrong, do not silently eat a real
   purchase" path.
5. Resolve the buyer: `Players:GetPlayerByUserId(playerId)` inside a
   `pcall`. `player` may be `nil` (the buyer left).
6. Dispatch on `entry.Kind` (see the kind table below). Every grant
   helper returns the **string** `'granted'` or `'retry'`. The
   dispatch is inside a `pcall`; if it throws, `outcome` stays
   `'retry'`.
7. If `outcome == 'granted'`:
   - `_rememberReceipt(purchaseId)` (adds to the dedupe set; **the
     receipt is only remembered on success** — a failed grant is
     retryable and must not be deduped);
   - log;
   - fire the funnel steps and the `PlayerLogger.LogMilestone` call,
     all `pcall`-guarded, **only if the buyer is present**;
   - return `PurchaseGranted`.
8. Otherwise return `NotProcessedYet`.

**The critical detail:** the dedupe write happens **after** the grant,
not before. A receipt that failed is not recorded, so Roblox's retry
actually retries. A receipt that succeeded is recorded, so the retry
is a no-op.

### The six grant helpers

| Helper | Kind | Action | Buyer required? | Returns `'retry'` when |
|---|---|---|---|---|
| `_grantMoney` | `Money` | `EconomyService.AddMoney(userId, amount, 'ShopMoneyPack')` | **Yes** | `entry.Amount` is not a non-empty string, or the add did not succeed |
| `_grantGear` | `Gear` | `GearShopService.GrantRobuxGear(player, entry.GearId)`, then best-effort `GearShopService.EquipGear` | **Yes** | `entry.GearId` is not a non-empty string, or the grant did not return `true` |
| `_grantLuck` | `ServerLuck` | `ServerLuckService.ActivateBoost(mult, duration, 'ShopPurchase')`, then announce to **all** players | **No** | the multiplier is not a number, or `ShopConfig.ServerLuckDurations[mult]` is missing/not a number, or `ActivateBoost` returned `nil` |
| `_grantSkipDaily` | `SkipDaily` | `DailyRewardsService.GrantSkipAccess(player)` then `DailyRewardsService.ClaimAll(player)` | **Yes** | `ClaimAll` did not return a table with `Success == true` |
| `_grantSkipPlaytime` | `SkipPlaytime` | `PlaytimeRewardsService.GrantSkipAccess(player)` then `PlaytimeRewardsService.ClaimAll(player)` | **Yes** | `ClaimAll` did not return a table with `Success == true` |
| `_grantUnlockDoors` | `UnlockDoors` | `DoorService.GrantPendingUnlock(player)` | **Yes** (the helper returns `'retry'` immediately if `player == nil`) | `GrantPendingUnlock` did not return `true` |

Notes that bite:

- The **skip** grants call `GrantSkipAccess` **first**, then `ClaimAll`.
  The receipt *is* the entitlement — the access is granted and then the
  identical gated claim path runs. The order matters: calling
  `ClaimAll` without the access would be rejected.
- `_grantLuck` is the **only** buyer-independent grant. A receipt for
  a departed buyer still activates the server-wide boost. The buyer
  gets no personal toast (there is no player), but everyone else in
  the server does.
- `_grantGear` **equips** the item after granting it, and the equip is
  **best-effort** — a failure (no character yet) does not retry. The
  grant already committed, so retrying would double-grant. The equip
  is expected to be re-driven by `CharacterAdded`.
- The `GalaxyBatEquipped` funnel step fires **only** when the equip
  path actually reported success. A missed equip never claims
  success.
- `_grantMoney`'s `Amount` is the **raw BigNumber decimal string**
  (`'10000'`), not a preformatted `'10K'`. `NotificationService`
  owns all `{Amount}` formatting (`_cleanAmount`); a preformatted
  value fails `sanitize` there and renders as `'$0'`.

### The gamepass path (2X Money)

Gamepasses emit **no receipts**. So:

- `ShopService.OnPlayerReady(player)` → `pcall(SyncGamepassAsync, player)`
  — a **silent** sync on join.
- `ShopService.SyncGamepassAsync(player): boolean`
  1. `Validation.LivePlayer(player)` → `false` if not.
  2. `MarketplaceService:UserOwnsGamePassAsync(userId, ShopConfig.Gamepasses.Money2x.GamepassId)`
     inside a `pcall` (a network failure leaves `owned = false`).
  3. If owned → `ModifierService.AddModifier(userId, 'Gamepass_2XMoney', ModifierType.MoneyMultiplier, 2, Operation.Multiply)`.
     If not owned → `ModifierService.RemoveModifier(userId, 'Gamepass_2XMoney')`
     (handles the revoked / refunded edge).
  4. A **lazy** `require` of `RebirthService` and a
     `RefreshBaseMultiplier(userId)` call — the live base label
     updates immediately. The `require` is inside a `pcall` so there
     is no load-time coupling to Rebirth.
  5. If owned → a `GamepassSynced` funnel step.
  6. Returns `owned`.
- The modifier source id is the module-local constant
  `GAMEPASS_2X_SOURCE = 'Gamepass_2XMoney'`.
- The modifier is **session-scoped**. `ModifierService` never
  persists. The *entitlement* is the persistent thing, re-resolved
  every session.

### The `ShopAction` remote

`handleAction(player, payload)` — entirely inside one `pcall`, with
the error logged as `'ShopAction handler errored'`.

- `payload.Action == 'FunnelPrompt'` → `_logPromptIntent`. This is
  **analytics only, never an entitlement**. It re-resolves the
  product from `ShopConfig` (client numbers are never trusted for
  grants) and logs `ShopItemPrompted` (+ `GalaxyBatPrompted` for the
  bat). Throttled by `PROMPT_COOLDOWN_S = 2` — a **hardcoded local**,
  not in `Security.lua`.
- `payload.Action == 'SyncGamepass'` → the post-purchase gamepass
  sync:
  1. Throttle check: `Security.Receipts.ActionCooldownSeconds` (5).
  2. `wasOwned` is computed by scanning
     `ModifierService.GetModifiers(userId)` for a source whose
     `SourceId == 'Gamepass_2XMoney'`.
  3. `owned = ShopService.SyncGamepassAsync(player)`.
  4. `owned and not wasOwned` → `NotifySuccess 'Shop_GamepassActive'`;
     `owned` (already had it) → `NotifyWarning 'Shop_AlreadyOwned'`.
  5. Fires `ShopResult` S→C: `{ Action = 'SyncGamepass', Success = true, Owned = owned }`.
     Note `Success` is **always `true`** — the *sync* succeeded. The
     entitlement state is in `Owned`.
- **Any other `Action` is silently ignored.** The `ShopAction` remote
  handles exactly two verbs.

`ShopService.Init()`:

- Idempotent (`_started` guard).
- `pcall(function() MarketplaceService.ProcessReceipt = _handleReceipt end)`.
- Wires the `ShopAction` remote: `Remotes.GetFolder():WaitForChild(Remotes.Names.ShopAction, 10)` then
  `assert(remote and remote:IsA('RemoteEvent'), 'ShopAction remote missing')`.
  The `WaitForChild` + `assert` are inside a `pcall`, so a missing
  remote **degrades loudly but does not block boot** — the `assert`
  message is swallowed by the pcall and the receipt router still
  installs.
- Subscribes `ServerLuckService.OnBoostExpired` → announces
  `Shop_LuckExpired` to **every** player.

### `DoorService`

#### Prompt lifecycle

- The prompt name is `PROMPT_NAME = 'OpenDoorPrompt'`.
- The prompt is **server-created and server-destroyed**. It is never
  authored in Studio.
- It lives on `base.collector` — the base's collector part. If the
  collector is not a `BasePart`, `_promptParent` returns `nil` and no
  prompt is created; `DoorService.RefreshBase` then logs
  `'locked base has no collector; prompt unavailable'`.
- `RefreshBase(baseId)` is the single reconciler. The prompt exists
  **IFF** the base is owned (`ownerUserId` is a number) **AND**
  `BaseLockService.IsLocked(baseId)` **AND** the collector is a
  `BasePart`.
  - Exists → re-stamp the `ownerUserId` attribute and return (the
    prompt is reused, not recreated).
  - Does not exist → `Instance.new('ProximityPrompt')`, set
    `ActionText` / `ObjectText` / `HoldDuration` /
    `MaxActivationDistance` / `RequiresLineOfSight` from
    `PromptConfig.DoorOpen`, set the attributes `ownerUserId`,
    `doorPrompt = true`, `baseId`, parent it to the collector, and
    connect `prompt.Triggered` → `DoorService.RequestOpen`.
  - Should not exist → `existing:Destroy()`.
- `RefreshBase` **never throws** — the whole body is in a `pcall`.
- It is called from `_onLockChanged`, which is subscribed to
  `BaseLockService.SubscribeLockChanged`. The subscriber is a
  **module-level named function** so repeated `Init()` calls never
  stack subscriptions.
- The prompt is **event-driven** — never polled, never a Heartbeat.
- The owner never sees the prompt. That is **UX only**, via a
  `PromptOwnerFilter` door rule on the client; the server revalidates
  everything anyway.

#### The purchase request (`RequestOpen`)

Validation order, all inside one `pcall`, returning `true` only if
the Roblox dialog was actually shown:

1. `Validation.LivePlayer(player)`.
2. `Validation.CanPlayerInteract(player)`.
3. `prompt` is an `Instance` and `IsA('ProximityPrompt')`.
4. `prompt:GetAttribute('baseId')` is a non-empty string.
5. `BaseService.GetBaseById(baseId)` returns a table with a numeric
   `ownerUserId`.
6. `BaseLockService.IsLocked(baseId)` — else reject `'rejected unlocked'`.
7. `base.ownerUserId ~= player.UserId` — else reject `'rejected owner'`.
8. `BaseLockService.HasPurchasedAccess(baseId, player.UserId)` —
   if the buyer already holds a grant, notify `Shop_DoorOpened`,
   return **true**, and **never** re-prompt or re-charge.
9. Distance: `prompt.Parent` must be a `BasePart`, the player must
   have a `HumanoidRootPart`, and the distance between them must be
   `<= PromptConfig.DoorOpen.MaxActivationDistance + RANGE_SLACK`
   (12 + 2 = 14 studs). The slack covers the movement between the
   client's trigger and the server's check.
10. Throttle: `Security.Door.RequestCooldownSeconds` (5) per player.
11. `_sweepStalePending(now)`.
12. Store `_pending[player.UserId] = { baseId = baseId, ownerId = base.ownerUserId, at = now }`.
    Only the **base identity** is stored — never an Instance ref
    (bases rebuild).
13. `MarketplaceService:PromptProductPurchase(player, ShopConfig.DeveloperProducts.UnlockDoors.ProductId)`
    inside a `pcall`. If it throws, the pending context is **removed
    again** and the function returns `false`.

#### The grant (`GrantPendingUnlock`)

This is the most careful function in the system. It **re-resolves the
current authoritative state** and treats the pending context as a
**locator only**, never as truth.

1. `userId = player and player.UserId or nil`. If there is no
   `userId` → `settled = true` (consume). The comment explains:
   without a `userId` there is no context key, so nothing can be
   looked up.
2. `_sweepStalePending(os.clock())` — anything older than
   `PENDING_TTL_S` (15 minutes) is dropped.
3. `pending = _pending[userId]`, and **`_pending[userId] = nil`
   immediately** — the context is consumed whether the grant succeeds
   or not.
4. **No pending context** → warn `'no pending door context; purchase consumed'`,
   toast the buyer `General_Generic`, `settled = true`.
5. **Base gone** (`GetBaseById` fails) → warn `'base gone; purchase consumed'`,
   toast, `settled = true`.
6. **Base not locked** (raced open — a timer expired or another
   buyer's grant landed mid-dialog):
   - If the owner is **unchanged** (`base.ownerUserId == pending.ownerId`)
     **and** the buyer is **still not the owner**
     (`base.ownerUserId ~= userId`) → **still record the grant**:
     `BaseLockService.UnlockPurchased(pending.baseId, userId)`. The
     buyer paid for *access*, and a later owner re-lock must not
     revoke it. Log `'door already open; grant recorded'`, toast
     `Shop_DoorOpened`, `settled = true`.
   - Otherwise → warn `'base already unlocked; purchase consumed'`,
     toast, `settled = true`.
7. **Ownership changed** (`base.ownerUserId ~= pending.ownerId`) →
   warn `'ownership changed; purchase consumed without unlock'`,
   toast, `settled = true`. **Never** unlock a new owner's base on
   an old buyer's receipt.
8. **Buyer is now the owner** → warn `'buyer is now the owner;
   purchase consumed without unlock'`, toast, `settled = true`.
9. **The happy path**: `BaseLockService.UnlockPurchased(pending.baseId, userId)`
   — opens now **and** records the buyer. Log `'door opened
   (purchased)'`, toast `Shop_DoorOpened`, `settled = true`.

**`settled == true` means "consume the receipt"**, and it is returned
for *every* terminal no-op — not just the happy path. A paid purchase
is never swallowed silently: every terminal path logs loudly **and**
toasts the buyer. Only an internal error (a throw inside the `pcall`)
returns `false` → retry.

`DoorService.GrantPendingUnlock(nil)` returns `true` (the spec
asserts this).

#### The grant model

`BaseLockService.UnlockPurchased(baseId, purchaserUserId)`:

- Opens the base **now** (global geometry — replicated to everyone).
- Records the **buyer** in a per-base grant list. That grant is
  **independent of the owner's lock control**: the owner can always
  re-lock afterwards. The buyer keeps collision passthrough through
  their grant; everyone else is locked out again.
- Grants persist for the **base's lifetime** — there is no duration
  in the product config.
- Grants clear only on **base release / reassign / wipe**. A new
  assignment starts with a clean door slate. (This means a base that
  changes hands wipes the buyer's access.)
- Repeat receipts re-insert the same grant **idempotently**.

`DoorService.ForgetPlayer(userId)` clears only the **throttle**
(`_lastRequestAt`). It explicitly does **NOT** clear the pending
context — a buyer who leaves mid-dialog and rejoins still fulfills
on the receipt retry. The pending context dies by **TTL**, never by
leave.

### The dedupe table overflow

`_rememberReceipt` counts the table with a `pairs` loop on **every
insert** (O(n) per receipt) and, if `count > _SEEN_CAP`
(`Security.Receipts.SeenCap` = 5000), calls **`table.clear(_seenReceipts)`**
— it clears the **entire** table, then re-inserts the current
`purchaseId`. It is **not** an LRU: one overflow wipes all 5000
entries. The module comment is explicit that this is an accepted
residual risk ("Roblox retries promptly, so an ancient duplicate
re-granting is the accepted residual risk over unbounded memory
growth"). The clear also emits a `SHOP` warn.

### The config (`Shop.lua`)

- `Shop.ProductKind` is a plain table of six string constants.
- `Shop.DeveloperProducts` is keyed by feature key; each entry
  carries `Key`, `ProductId`, `Robux`, `Kind`, and the kind-specific
  payload (`Amount` / `GearId` / `Multiplier`).
- `Shop.ByProductId` is built **at require time** by iterating
  `pairs(Shop.DeveloperProducts)`. On a **duplicate `ProductId`** it
  `warn()`s and **keeps the first entry** (so receipts stay
  deterministic) — the second entry is dropped from the reverse map
  entirely, and it is still reachable by key.
- **There is NO `Validate()` function in `Shop.lua`.** It is the only
  config in this library without one. Its integrity is covered by
  `Tests/ShopConfig.spec.lua` instead.
- `Shop.FindProduct(productId)` returns `nil` for a non-number
  argument.
- `Shop.ServerLuckDurations` is keyed by **multiplier number**
  (`[2]`, `[4]`, `[8]`), value = seconds. The service reads
  `durations[mult]` where `mult = tonumber(entry.Multiplier)`.
  Because `tonumber` runs first, a string multiplier in the config
  would still work — but `entry.Multiplier` is a number today.
- `Shop.CardMap` maps a **Studio card path** to a product key. The
  paths are relative to the Shop `ScrollingFrame`, computed by
  walking up from the clicked Buy button. Four paths are
  **deliberately unmapped**: `Events/1`, `Passes/4`, `Items/2`,
  `Featured/StarterPack`. The config comment says: *"guessing a
  charge is worse than a loud error"*.
- `Robux` is **display-only** metadata. Roblox is the authority on
  the price.

---

## Public API surface

### `ShopService`

```lua
ShopService.Init()                                   -- idempotent
ShopService.OnPlayerReady(player: Player)            -- silent gamepass sync
ShopService.SyncGamepassAsync(player: Player): boolean
ShopService.ForgetPlayer(userId: number)
ShopService._TestReset()
ShopService._TestHandleReceipt(info: any): Enum.ProductPurchaseDecision
```

Module constants: `ShopService` is `table.freeze`d. The internal
`GAMEPASS_2X_SOURCE = 'Gamepass_2XMoney'` is module-local, not
exported.

### `DoorService`

```lua
DoorService.Init()                                   -- idempotent
DoorService.RefreshBase(baseId: string)              -- never throws
DoorService.RequestOpen(player: Player, prompt: ProximityPrompt): boolean
DoorService.GrantPendingUnlock(player: Player?): boolean
DoorService.ForgetPlayer(userId: number)
DoorService._TestReset()
DoorService._TestPending(userId: number): any?
DoorService._TestSetPending(userId: number, ctx: any?)
```

### `ShopConfig`

```lua
ShopConfig.ProductKind          -- { Money, Gear, ServerLuck, UnlockDoors, SkipDaily, SkipPlaytime }
ShopConfig.DeveloperProducts    -- { [key] = ProductEntry }
ShopConfig.Gamepasses           -- { [key] = { Key, GamepassId, Robux } }
ShopConfig.ServerLuckDurations  -- { [mult] = seconds }
ShopConfig.ByProductId          -- { [productId] = ProductEntry }
ShopConfig.FindProduct(productId: number): ProductEntry?
ShopConfig.CardMap              -- { [cardPath] = productKey }
```

---

## Invariants the code enforces

1. **Exactly one `ProcessReceipt` router.** `ShopService.Init()`
   assigns it. A second assignment would silently eat receipts.
2. **A receipt is remembered only on success.** A failed grant stays
   retryable.
3. **Unknown `ProductId` → `NotProcessedYet`, never consume.**
4. **Malformed receipt → `PurchaseGranted`** (to break the retry
   loop). Nothing is granted.
5. **Duplicate `PurchaseId` → `PurchaseGranted` with no side
   effects.**
6. **Player-bound grants with no buyer → `NotProcessedYet`** (retry).
7. **Server-wide grants (luck) apply with no buyer.**
8. **Every grant path is idempotent**, so a retry continues instead
   of duplicating.
9. **The grant is what the receipt remembers** — the funnel step
   `ItemGranted` fires only in the `granted` branch, so retries never
   double-count.
10. **A shown purchase prompt is not success.** Only the granted
    branch is.
11. **The client never grants.** The `FunnelPrompt` action is
    analytics only; the product is re-resolved server-side.
12. **The door prompt exists IFF** owned AND locked AND the collector
    is a `BasePart`.
13. **The door grant never trusts the stored context.** It
    re-resolves the current owner, the current lock state, and the
    buyer's current relationship to the base.
14. **A receipt never opens a base the buyer did not pay for.**
15. **Every terminal door no-op consumes the receipt *loudly*** (log
    + buyer toast), never silently.
16. **The buyer never pays twice for the same base.** A buyer who
    already holds a grant is told so and not re-prompted.
17. **The owner can always re-lock over a purchase**; the buyer keeps
    passthrough, nobody else does.
18. **The pending context survives leave** and dies only by TTL.
19. **The pending context stores base identity, never Instance
    refs.**
20. **The pending context is consumed on read** — it is cleared
    before the grant is evaluated, so a repeat receipt cannot
    re-grant.
21. **The gamepass entitlement is re-resolved from Roblox**, never
    trusted from the client.
22. **The gamepass modifier is session-scoped** and the source id is
    exactly `'Gamepass_2XMoney'`.
23. **The dedupe table is bounded** at `Security.Receipts.SeenCap`.

---

## Failure and edge-case behaviour

| Situation | Result |
|---|---|
| `info` is `nil` or `{}` | `PurchaseGranted` + warn. Nothing granted. |
| `info.PurchaseId` is not a string | `PurchaseGranted` + warn. |
| `info.PlayerId` / `info.ProductId` not a number | `PurchaseGranted` + warn. |
| `PurchaseId` already seen | `PurchaseGranted`. No side effects. |
| `ProductId` not in `ShopConfig` | `NotProcessedYet` + warn. Retries until the registry is fixed. |
| `entry.Kind` has no handler | `NotProcessedYet` + warn `'product kind has no handler'`. |
| Buyer has left, kind is `Money` / `Gear` / `SkipDaily` / `SkipPlaytime` | `NotProcessedYet`. |
| Buyer has left, kind is `ServerLuck` | **Granted.** The boost applies. |
| Buyer has left, kind is `UnlockDoors` | `NotProcessedYet` — `_grantUnlockDoors` returns `'retry'` for a `nil` player. |
| `entry.Amount` missing/empty | `'retry'` → `NotProcessedYet`. |
| `entry.GearId` missing/empty | `'retry'` → `NotProcessedYet` + warn. |
| `entry.Multiplier` missing, or no duration for it | `'retry'` → `NotProcessedYet` + warn. |
| `GearShopService.GrantRobuxGear` returns `false` | `'retry'` → `NotProcessedYet` + warn. |
| `GrantRobuxGear` succeeded but `EquipGear` failed | **Granted.** The equip is best-effort. |
| `EconomyService.AddMoney` fails | `'retry'` → `NotProcessedYet`. |
| `ClaimAll` returns no table / `Success ~= true` | `'retry'` → `NotProcessedYet`. |
| `ModifierService.AddModifier` throws (gamepass sync) | Swallowed by the `pcall`. `owned` is still returned. |
| `UserOwnsGamePassAsync` throws | `owned` stays `false`. The modifier is removed. |
| The dedupe table exceeds 5000 | The **whole** table is cleared + warn. |
| `RequestOpen` with a non-player | `false`. No dialog. |
| `RequestOpen` on an unlocked base | `false` + log `'rejected unlocked'`. |
| `RequestOpen` by the owner | `false` + log `'rejected owner'`. |
| `RequestOpen` by a buyer who already has access | `true`, toast `Shop_DoorOpened`, **no** dialog, **no** charge. |
| `RequestOpen` out of range | `false` + log `'rejected out of range'`. |
| `RequestOpen` inside the throttle window | `false`. |
| `PromptProductPurchase` throws | The pending context is removed; `false`. |
| `GrantPendingUnlock(nil)` | `true` (consume). |
| `GrantPendingUnlock` with no pending context | `true` (consume) + warn + buyer toast. |
| `GrantPendingUnlock` and the base is gone | `true` (consume) + warn + buyer toast. |
| `GrantPendingUnlock` and the base raced open (same owner) | `true` — **the grant is still recorded**. |
| `GrantPendingUnlock` and the base raced open (different owner) | `true` (consume) + warn + toast. No unlock. |
| `GrantPendingUnlock` and the owner changed | `true` (consume) + warn + toast. **No unlock.** |
| `GrantPendingUnlock` and the buyer is now the owner | `true` (consume) + warn + toast. No unlock. |
| The pending context is older than 15 minutes | Swept. The grant then takes the "no pending context" path. |

---

## Gotchas that will bite you

1. **`ShopService` uses direct requires, not injection.** You cannot
   swap a dependency at runtime. If you port this system, either keep
   the direct requires or convert to `Set*Service()` setters — but
   then you **must** `Init()` it after those services exist.
2. **`ShopConfig` has no `Validate()`.** Every other config in the
   library does. A malformed product is only caught by a *retrying
   receipt*, which means a live purchase can be stuck in a retry loop
   until someone fixes the config.
3. **The `ProductId`s are placeholders for a new game.** 12
   Developer Product ids + 1 gamepass id = **13 numbers to replace**.
   Until you do, every receipt is "an unknown ProductId".
4. **The dedupe overflow clears EVERYTHING.** It is not an LRU. A
   burst of 5001 receipts wipes the whole table, and every one of
   those 5000 older receipts becomes re-grantable.
5. **`_rememberReceipt` is O(n)** — it counts the table on every
   insert. At the 5000 cap that is 5000 iterations per receipt.
6. **The pending context is consumed on read.** A second call to
   `GrantPendingUnlock` for the same buyer finds nothing and takes the
   "no pending context" path. The grant must be idempotent inside
   `BaseLockService` for this to be safe.
7. **`RequestOpen` returning `true` does not mean "a dialog was
   shown".** It also returns `true` for the "you already have access"
   short-circuit (no dialog, no charge).
8. **`GrantPendingUnlock` returning `true` does not mean "the door
   opened".** It means "the receipt is settled" — which includes
   every terminal no-op. The door may not have opened at all.
9. **The buyer IS notified, the base owner is NOT.** The buyer gets
   `Shop_DoorOpened` on the happy path and the raced-open path, and
   `General_Generic` (a warning) on every terminal no-op. The base
   **owner** is never told that their door was bought.
10. **A grant persists for the base's lifetime and clears on
    reassign.** A buyer who paid and then had the base change hands
    loses the access and must buy again.
11. **The `CardMap` is a Studio-hierarchy artifact.** Renaming a row
    in the GUI silently breaks the mapping. The four unmapped paths
    are evidence of how fragile this is.
12. **`Robux` in the config is display-only.** Changing it does
    nothing to the actual price; Roblox's Dashboard does.
13. **The `Money` `Amount` must be a raw BigNumber string.** `'10000'`
    yes; `'10K'` or `'$10,000'` no.
14. **`PROMPT_COOLDOWN_S = 2` and `PENDING_TTL_S = 15 * 60` are
    hardcoded locals**, even though the other limits moved to
    `Security.lua`. This is an inconsistency, not a design.
15. **`ServerLuckService.OnBoostExpired` fires a toast to every
    player.** A boost expiry in a busy server is an O(players)
    broadcast.
16. **The `ShopAction` `Success` field is always `true`.** The
    entitlement state is `Owned`. Do not read `Success` as "you own
    it".
17. **`_grantLuck` announces to all players *including* the buyer**,
    and then sends the buyer a second, different toast
    (`Shop_LuckPurchased`).
18. **A malformed receipt grants nothing but is marked handled.**
    The player is charged and gets nothing. This is the deliberate
    trade for not looping forever.
19. **The door prompt is created on the base's *collector* part.**
    If your base model has no `collector` attribute pointing at a
    `BasePart`, the door flow silently degrades to "warn and no
    prompt".
20. **The door service never gates stealing and never reads
    `StealService`.** If you expected the purchase to affect raids,
    it does not.

---

## What to change to reuse it

1. **Replace the 13 IDs** in `ShopConfig.DeveloperProducts` and
   `ShopConfig.Gamepasses`.
2. **Convert the direct requires to `Set*Service()` injection** if
   you want the service to be testable or swappable. If you do, add
   the setters and move the `Init()` call after them.
3. **Add a `Validate()` to `Shop.lua`.** Mirror `Security.Validate()`:
   return a list of issue strings, never throw. Check that every
   product has a numeric `ProductId`, that `Kind` is one of the six,
   that the kind's payload is present, that the `ProductId`s are
   unique, and that the gamepass id is a number.
4. **Move `PROMPT_COOLDOWN_S` and `PENDING_TTL_S` into
   `Security.lua`** (`Security.Receipts.PromptCooldownSeconds`,
   `Security.Door.PendingTtlSeconds`) and read them from there.
5. **Replace the `CardMap`** with a `ProductId` number attribute on
   the button in Studio, or with your own path scheme.
6. **Delete the kinds you do not have** and their grant helpers, the
   dispatch branches, the config entries, and the spec's kind list.
7. **Add your own kind** by: extending `ShopConfig.ProductKind`,
   adding the config entry with the payload, adding a
   `_grant<Kind>` that returns `'granted'` / `'retry'`, adding a
   branch to the dispatch chain, and adding the kind to the spec.
8. **Keep the `NotProcessedYet` / `PurchaseGranted` discipline** and
   the "remember only on success" rule. They are the whole reason
   the system is safe.
9. **Keep the door grant's "re-resolve live" rule.** Any shortcut
   (trusting the stored `ownerId`, opening on the stored `baseId`
   without re-checking) is an exploit.
10. **Keep the "terminal no-op consumes loudly" rule.** A silent
    `true` on a failed grant is a lost purchase.
11. **Keep the `Money` amount a raw BigNumber string** and let
    `NotificationService` format it.
12. **Keep the session-scoped modifier + re-resolved entitlement**
    pattern for gamepasses. Do not persist the modifier; persist
    nothing and re-resolve.
13. **If you have no base/lock model**, delete `DoorService` and the
    `UnlockDoors` kind entirely.
14. **If you have no gear shop**, delete the `Gear` kind and the
    `EquipGear` call.
15. **If you have no daily/playtime reward services**, delete the
    `SkipDaily` / `SkipPlaytime` kinds.
16. **If you have no server luck**, delete the `ServerLuck` kind,
    `ServerLuckDurations`, and the `OnBoostExpired` subscription.
