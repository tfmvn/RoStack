# Shops and Purchases

**A single Roblox Marketplace receipt router that turns any Developer Product or gamepass into a canonical server-side action, plus a paid-door flow for locked bases.**

**Portability:** Grade **C — platform-bound** for the monetization core, with a Grade A refund/idempotency core inside it. The receipt *state machine* — dedupe by `PurchaseId`, resolve the product from a registry, dispatch to a kind handler, and return `NotProcessedYet` for anything transient so Roblox retries — is fully portable logic. But the **transport is Roblox-specific**: `MarketplaceService.ProcessReceipt`, `MarketplaceService:PromptProductPurchase`, `MarketplaceService:UserOwnsGamePassAsync`, and the `Enum.ProductPurchaseDecision` values have no equivalent elsewhere. The `DoorService` half is a Grade **B** game-specific adapter: it is written against this game's base/lock model and its Studio prompt hierarchy.

**Source game:** Brainrot Arena (p-7)

---

## What It Does

Two services:

**`ShopService`** owns the **one** authoritative
`MarketplaceService.ProcessReceipt` implementation. Every Developer
Product in the game resolves through `ShopConfig` to one of six
canonical actions:

| Product kind | Action |
|---|---|
| `Money` | `EconomyService.AddMoney(userId, Amount, 'ShopMoneyPack')` |
| `Gear` | `GearShopService.GrantRobuxGear(player, GearId)`, then equip it |
| `ServerLuck` | `ServerLuckService.ActivateBoost(mult, duration, 'ShopPurchase')` — **server-wide** |
| `SkipDaily` | `DailyRewardsService.GrantSkipAccess` + `ClaimAll` |
| `SkipPlaytime` | `PlaytimeRewardsService.GrantSkipAccess` + `ClaimAll` |
| `UnlockDoors` | `DoorService.GrantPendingUnlock(player)` |

It also owns the **gamepass entitlement sync** (2X Money). Roblox
gamepasses emit no receipts, so ownership is re-checked
authoritatively on join and on an explicit `ShopAction 'SyncGamepass'`
after an in-session purchase.

**`DoorService`** implements the paid-door flow: a `ProximityPrompt`
appears on a locked base's collector; triggering it validates
everything server-side and opens a Roblox purchase dialog; the
receipt then unlocks the base and records a **per-buyer** access
grant that survives a later owner re-lock.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `ShopService.Init()` | server service | Installs the receipt router and wires the `ShopAction` remote. **Idempotent.** |
| `ShopService.OnPlayerReady(player)` | server service | The join hook. Silently re-syncs the gamepass entitlement. |
| `ShopService.SyncGamepassAsync(player): boolean` | server service | Authoritative ownership check; applies or removes the 2X Money modifier. Returns whether the player owns it. |
| `ShopService.ForgetPlayer(userId)` | server service | Leave cleanup (drops the action throttle). |
| `ShopService._TestReset()` / `ShopService._TestHandleReceipt(info)` | server service | Test-only seams. |
| `DoorService.Init()` | server service | Subscribes to the lock-changed event. **Idempotent.** |
| `DoorService.RefreshBase(baseId)` | server service | Reconciles one base's prompt with its live lock state. |
| `DoorService.RequestOpen(player, prompt): boolean` | server service | Server-side validation + the purchase dialog. Returns whether the dialog was shown. |
| `DoorService.GrantPendingUnlock(player?): boolean` | server service | The receipt-side fulfillment. `true` = settled (consume the receipt); `false` = retry. |
| `DoorService.ForgetPlayer(userId)` | server service | Leave cleanup (drops the throttle, **keeps** the pending context). |
| `DoorService._TestReset` / `_TestPending` / `_TestSetPending` | server service | Test-only seams. |
| `ShopConfig.FindProduct(productId)` | config | The reverse lookup: ProductId -> entry, or `nil`. |
| `ShopConfig.DeveloperProducts` / `.Gamepasses` / `.ByProductId` / `.CardMap` / `.ServerLuckDurations` / `.ProductKind` | config | The registry. |
| `ShopAction` | remote (C→S) | `{ Action: 'SyncGamepass' \| 'FunnelPrompt' }`. |
| `ShopResult` | remote (S→C) | `{ Action, Success, Owned? }`. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Shop/ShopService.lua` | `ServerScriptService/Shop/ShopService.lua` | The receipt router + gamepass sync. 580 lines. |
| `Source/ServerScriptService/Shop/DoorService.lua` | `ServerScriptService/Shop/DoorService.lua` | The paid-door flow. 451 lines. |
| `Source/ReplicatedStorage/Config/Economy/Shop.lua` | `ReplicatedStorage/Config/Economy/Shop.lua` | The product registry. 220 lines. |
| `Tests/ShopReceipt.spec.lua` | (test tree) | The receipt router contract. 7 cases. |
| `Tests/ShopConfig.spec.lua` | (test tree) | The registry's integrity. 7 cases. |
| `Tests/DoorService.spec.lua` | (test tree) | The door prompt lifecycle + grant semantics. 11 cases. |

**External configs this system reads** (they live in other systems):

| Library path | Roblox destination | Purpose |
|---|---|---|
| `AdminTools/Source/ReplicatedStorage/Config/Systems/Security.lua` | `ReplicatedStorage/Config/Systems/Security.lua` | `Security.Receipts.SeenCap`, `ActionCooldownSeconds`, `Security.Door.RequestCooldownSeconds`, `RangeSlackStuds`. |
| `Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` | `Prompts.DoorOpen` — the prompt's text, hold duration, and activation distance. |

---

## Configuration

The system has **its own config**: `ReplicatedStorage/Config/Economy/Shop.lua`.
It is the **single registry for ALL monetization product identities** —
the server receipt routing, the client Shop buttons, and the audit logs
all resolve through it.

### Developer Products

| Key | ProductId | Robux | Kind | Payload |
|---|---|---|---|---|
| `MoneyPack1` | 3715397862 | 19 | `Money` | `Amount = '10000'` |
| `MoneyPack2` | 3715397884 | 49 | `Money` | `Amount = '50000'` |
| `MoneyPack3` | 3715397918 | 99 | `Money` | `Amount = '250000'` |
| `MoneyPack4` | 3715397931 | 199 | `Money` | `Amount = '500000'` |
| `MoneyPack5` | 3715397968 | 249 | `Money` | `Amount = '1000000'` |
| `ServerLuck2x` | 3715397847 | 99 | `ServerLuck` | `Multiplier = 2` |
| `ServerLuck4x` | 3715398478 | 199 | `ServerLuck` | `Multiplier = 4` |
| `ServerLuck8x` | 3715398723 | 499 | `ServerLuck` | `Multiplier = 8` |
| `UnlockDoors` | 3715397812 | 29 | `UnlockDoors` | — |
| `GalaxyBat` | 3715398070 | 199 | `Gear` | `GearId = 'GalaxyBat'` |
| `SkipDaily` | 3716261585 | 249 | `SkipDaily` | — |
| `SkipPlaytime` | 3716261541 | 149 | `SkipPlaytime` | — |

> **The `ProductId`s are placeholders for a real place.** They are
> hardcoded in the shipped config and are the real IDs from the source
> game's Creator Dashboard. In a new game you must replace every one
> of them with the IDs from **your own** Creator Dashboard, or every
> receipt will be "an unknown ProductId" and will retry forever.
> `Robux` is display-only metadata (the client shows it); Roblox is
> the authority on the actual price.

### Gamepasses

| Key | GamepassId | Robux |
|---|---|---|
| `Money2x` | 2002490328 | 199 |

### Server luck durations

`ShopConfig.ServerLuckDurations = { [2] = 900, [4] = 600, [8] = 300 }`
— seconds per multiplier. **Designer-owned**: no duration is hardcoded
in the service logic.

### The `CardMap`

`Shop.CardMap` maps a **Studio card path** to a product key, for Shop
cards whose Buy buttons carry neither a `ProductId` attribute nor a
product-key name. The paths are relative to the Shop `ScrollingFrame`
and are computed by walking up from the clicked Buy button.

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

**Four paths are deliberately UNMAPPED**: `Events/1` (one Server Luck
card but three products), `Passes/4` (VIP — no product exists),
`Items/2`, and `Featured/StarterPack` (no product anywhere). The
config comment says it plainly: *"guessing a charge is worse than a
loud error"*. The spec asserts all four stay `nil`.

A `ProductId` **number attribute stamped on the button in Studio wins**
over the `CardMap`.

### Validation

**`Shop.lua` has NO `Validate()` function.** It is the only config in
this library that lacks one. The only integrity check is a `warn()` at
require time when two products share a `ProductId` — the first entry
wins so the receipt routing stays deterministic. Everything else
(ProductIds present, kinds carrying their payload, the gamepass
registered, the luck durations present) is checked by
`Tests/ShopConfig.spec.lua` instead.

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the verbatim `require`
paths, the remotes, the profile fields, and the initialization order.

Summary: `ShopService` **directly requires** `MarketplaceService`,
`Players`, `ShopConfig`, `Security`, `Debug`, `Validation`,
`NotificationService`, `Remotes`, `EconomyService`,
`GearShopService`, `ServerLuckService`, `ModifierService`,
`DailyRewardsService`, `PlaytimeRewardsService`, `DoorService`,
`FunnelService`, and `PlayerLogger`.

`DoorService` **directly requires** `MarketplaceService`, `BaseService`,
`BaseLockService`, `ShopConfig`, `PromptConfig`, `Security`,
`Validation`, `NotificationService`, and `Debug`.

Both are loaded **after** every service they call into (the bootstrap
comment says so explicitly: "Init after every service it calls into;
before players join").

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  GearShopService.Init()
3.  DailyRewardsService.Init() / PlaytimeRewardsService.Init()
4.  ShopService.Init()      -- installs ProcessReceipt + the ShopAction remote
5.  DoorService.Init()      -- subscribes to the lock-changed event
6.  --- players may now join ---
```

Per-player, on join:

```text
1.  PlayerService.LoadPlayerData(player)
2.  GearShopService.OnPlayerReady(player)
3.  ShopService.OnPlayerReady(player)    -- silent gamepass entitlement sync
```

Per-player, on leave:

```text
1.  GearShopService.ForgetPlayer(userId)
2.  DoorService.ForgetPlayer(userId)      -- drops the throttle, KEEPS the pending context
3.  ShopService.ForgetPlayer(userId)      -- drops the action throttle
```

---

## Data

### Profile fields

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `Money` | string (BigNumber) | `EconomyService.AddMoney` | The money packs. The reason is the literal string `'ShopMoneyPack'`. |
| `Stats.*` (gear) | — | `GearShopService` | The Robux-bought gear. The **same** item, the **same** ownership — the Shop never creates a parallel Shop-only copy. |
| `DailyRewards` skip | — | `DailyRewardsService.GrantSkipAccess` | The skip entitlement. |
| `PlaytimeRewards` skip | — | `PlaytimeRewardsService.GrantSkipAccess` | The skip entitlement. |

### Session state (not persisted)

| State | Where | Meaning |
|---|---|---|
| `_seenReceipts` | `ShopService` module-local | `PurchaseId -> os.clock()`. The idempotency set. |
| `_lastShopActionAt` | `ShopService` module-local | The per-player `ShopAction` throttle. |
| `_lastPromptAt` | `ShopService` module-local | The per-player funnel-prompt throttle (2 s, hardcoded). |
| `_pending` | `DoorService` module-local | `userId -> { baseId, ownerId, at }`. The pending door purchase context. |
| `_lastRequestAt` | `DoorService` module-local | The per-player door prompt throttle. |
| `'Gamepass_2XMoney'` modifier source | `ModifierService` | The 2X Money multiplier. **Session-scoped** — `ModifierService` never persists. |
| `'ShopPurchase'` luck boost | `ServerLuckService` | The temporary server-wide luck boost. |

### Base lock state (owned by `BaseLockService`)

The door grant is `BaseLockService.UnlockPurchased(baseId, buyerUserId)`
— it records the **buyer** and opens the base. It persists for the
base's lifetime and clears on base release / reassign / wipe.

---

## Known Limitations

1. **Every `ProductId` and `GamepassId` is a hardcoded placeholder
   for a new game.** The shipped values belong to the source game's
   Creator Dashboard. You must replace all 13 of them.

2. **`Shop.lua` has no `Validate()`.** A malformed entry (a product
   with no `ProductId`, a `Money` product with no `Amount`) is only
   caught at runtime, by a retrying receipt. Every other config in
   this library has a non-throwing `Validate()`.

3. **The receipt dedupe table is cleared wholesale past the cap**
   (`Security.Receipts.SeenCap = 5000`). The code accepts this
   residual risk explicitly: an ancient duplicate receipt could
   re-grant. The comment says "Roblox retries promptly, so an ancient
   duplicate re-granting is the accepted residual risk over unbounded
   memory growth."

4. **A malformed receipt resolves `PurchaseGranted`** — not
   `NotProcessedYet`. The comment says "granting to avoid retry loop".
   That is a deliberate trade: a malformed receipt cannot be
   identified, so it is granted rather than retried forever. It also
   means a malformed receipt grants **nothing** (there is no product
   to resolve) but is marked handled.

5. **A gamepass purchase is not atomic with its effect.** The 2X
   Money entitlement is re-resolved from `UserOwnsGamePassAsync` on
   join and on an explicit sync — there is no receipt, so there is no
   guaranteed "it applied immediately" moment. The player must send
   `ShopAction { Action = 'SyncGamepass' }` (or rejoin).

6. **The gamepass modifier is session-scoped.** `ModifierService` is
   in-memory. If `ShopService.OnPlayerReady` is not called on join, a
   gamepass owner has no 2X Money until they rejoin or sync.

7. **`ServerLuck` grants are server-wide and buyer-independent.** The
   spec proves it: a receipt with an unknown `PlayerId` still moves
   the global luck. The buyer is not notified (there is no player to
   notify), but everyone else is.

8. **`_grantLuck` announces to every player in the server** — the
   toast loop is O(players) per purchase. Fine for a small server;
   it is a broadcast storm on a large one.

9. **The `CardMap` is tied to the Studio GUI's exact hierarchy.**
   Any layout change (renaming `Row1`, moving a card) silently
   breaks the mapping. The four deliberately-unmapped paths are
   evidence that this is fragile.

10. **The pending door context survives leave, but it is TTL-bound
    to 15 minutes** (`PENDING_TTL_S = 15 * 60`, hardcoded — it is
    **not** in `Security.lua` even though the other door limits are).
    After 15 minutes the receipt consumes loudly and the buyer is
    refunded nothing.

11. **The door prompt is created and destroyed by the server.** It is
    not authored in Studio. A base whose `collector` is not a
    `BasePart` gets a warning and no prompt.

12. **The owner can re-lock over a paid grant.** The buyer keeps
    passthrough; nobody else does. This is intentional and the spec
    asserts it.

13. **The distance check is re-validated server-side with 2 studs of
    slack** over the prompt's `MaxActivationDistance` (12), so the
    effective reach is 14 studs.

14. **The door's per-buyer grant clears on base release / reassign.**
    A base that changes hands wipes the buyer's access — the buyer
    would have to buy again.

15. **The `ShopAction` handler only understands two actions.**
    `'SyncGamepass'` and `'FunnelPrompt'`. Everything else is
    silently ignored.

16. **The funnel prompt-intent cooldown (2 s) is hardcoded** in
    `ShopService`, not in `Security.lua` like the other limits.

---

## Testing

Three spec files, all TestEZ and Studio-only.

**`ShopReceipt.spec.lua`** — the receipt router contract:
- A malformed receipt (`nil`, `{}`) resolves `PurchaseGranted` — no
  retry loop.
- An unknown `ProductId` resolves `NotProcessedYet` — a loud retry.
- **Server-wide luck grants apply buyer-independently**: a receipt
  with an unknown `PlayerId` still moves `ServerLuckService.GetLuck()`
  from 1 to 4.
- **Duplicate `PurchaseId`s resolve without re-executing** — the spec
  cancels the boost out of band and replays the same receipt, proving
  the dedupe does not re-activate it.
- Player-bound grants with no buyer (money, door) resolve
  `NotProcessedYet`.
- Every `ShopConfig` product maps to a handled kind.

**`ShopConfig.spec.lua`** — the registry's integrity:
- Every product resolves by ID with its kind payload, and no two share
  a `ProductId`.
- The 12 shipped `ProductId`s are all present; `FindProduct(1)` and
  `FindProduct('nope')` are `nil`.
- The 2X Money gamepass and all three luck durations are registered.
- Every `CardMap` path resolves to a real product entry.
- `Passes/5` is the gamepass, `Items/1` is the GalaxyBat product.
- The four ambiguous cards stay unmapped — "no invented products".

**`DoorService.spec.lua`** — the door flow, against the **real**
`BaseService` / `BaseLockService`:
- The `OpenDoorPrompt` appears on lock with the `ownerUserId` and
  `doorPrompt` markers, and the `ActionText` is `'Open Door'`.
- The prompt is destroyed on unlock, idempotently.
- `RefreshBase` on an unknown base never throws.
- `RequestOpen` fail-closes on a non-player caller.
- `GrantPendingUnlock` with no player resolves terminally.
- A purchase opens the base, records the per-buyer grant, and the
  owner can still re-lock — the buyer keeps passthrough, nobody else
  does. A repeat receipt is idempotent. A base release clears the
  slate.
- A raced-open base still records the grant.
- A stale context is consumed without opening a stranger's base.

The specs need **no DataStore, no published place, and no Robux** — no
real purchase is ever made. `DoorService.spec.lua` needs
`ReusableSystems/Tests/_Helpers.lua` beside it (it uses
`Helpers.WireServices`, `Helpers.EnsureCollectors`, and
`Helpers.StubRemotes`).

---

## Adapting to a New Game

1. **Replace every `ProductId` and `GamepassId`.** 13 numbers. They
   live in `ShopConfig.DeveloperProducts` and `ShopConfig.Gamepasses`.
   Get them from your own Creator Dashboard.

2. **Decide what each product grants.** The six kinds are
   `Money`, `Gear`, `ServerLuck`, `UnlockDoors`, `SkipDaily`,
   `SkipPlaytime`. To add one:
   - add the kind to `ShopConfig.ProductKind`;
   - add the product entry with the kind's payload;
   - add a `_grant<Kind>` function in `ShopService` that returns
     `'granted'` or `'retry'`;
   - add a branch to the dispatch chain in `_handleReceipt`;
   - add the kind to the list in `Tests/ShopReceipt.spec.lua`.

3. **The money packs need a BigNumber string.** `Amount` is the raw
   decimal string, and `NotificationService` owns **all** `{Amount}`
   formatting. A preformatted `'$10K'` would fail `sanitize` there and
   render as `'$0'`.

4. **The receipt router must be the only one.**
   `ShopService.Init()` assigns `MarketplaceService.ProcessReceipt`.
   If another module assigns it, receipts are silently eaten. The
   source game installs this **after** every service that could
   conceivably want a receipt.

5. **If you have no doors**, delete `DoorService` and the
   `UnlockDoors` kind. The `UnlockDoors` product is one of the twelve
   `ShopConfig` entries.

6. **If you have no gear shop**, delete the `Gear` kind. The
   `_grantGear` path also equips the item — if you do not want that,
   drop the `GearShopService.EquipGear` call.

7. **If you have no server luck**, delete the `ServerLuck` kind and
   `ShopConfig.ServerLuckDurations`.

8. **If you have no daily/playtime rewards**, delete the
   `SkipDaily` / `SkipPlaytime` kinds.

9. **If you have no gamepasses**, delete `SyncGamepassAsync`,
   `OnPlayerReady`'s body, the `ShopAction` branch, and
   `ShopConfig.Gamepasses`.

10. **Rewrite the `CardMap` for your GUI.** It is a Studio-hierarchy
    artifact. If your Shop cards carry a `ProductId` number attribute,
    you do not need the `CardMap` at all.

11. **Move the two hardcoded limits into `Security.lua`.**
    `PROMPT_COOLDOWN_S = 2` and `PENDING_TTL_S = 15 * 60` are
    hardcoded; the other limits (`SeenCap`, `ActionCooldownSeconds`,
    `Door.RequestCooldownSeconds`, `Door.RangeSlackStuds`) are
    already there.

12. **Keep the `NotProcessedYet` discipline.** Every transient
    failure must return `NotProcessedYet` so Roblox retries. Every
    *terminal* state must return `PurchaseGranted` so the purchase is
    not retried forever. The receipt rules at the top of the module
    are the contract.

13. **Keep the purchase context separate from the pending lock
    state.** A receipt must never open a base the buyer did not pay
    for. `GrantPendingUnlock` re-resolves the CURRENT authoritative
    state and never trusts the stored context blindly.

---

## See also

- [`MEMORY.md`](MEMORY.md) — engineering notes for a future agent.
- [`API.md`](API.md) — every public function, with failure modes.
- [`Config.lua`](Config.lua) — the consolidated tunables.
- [`Dependencies.md`](Dependencies.md) — requires, remotes, profile fields.
- [`Setup.md`](Setup.md) — install steps into a new Rojo project.
