# Shops and Purchases — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Shop/ShopService.lua`

```lua
require(ReplicatedStorage.Config.Economy.Shop)
require(ReplicatedStorage.Config.Systems.Security)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.Validation)
require(ServerScriptService.Base.NotificationService)
require(ReplicatedStorage.Utility.Remotes)
require(ServerScriptService.EconomyService)
require(ServerScriptService.GearShop.GearShopService)
require(ServerScriptService.ServerLuckService)
require(ServerScriptService.ModifierService)
require(ServerScriptService.Daily.DailyRewardsService)
require(ServerScriptService.Playtime.PlaytimeRewardsService)
require(ServerScriptService.Shop.DoorService)
require(ServerScriptService.FunnelService)
require(ServerScriptService.PlayerLogger.PlayerLogger)
```

Plus one **lazy** require, inside a function body (so there is no
load-time coupling):

```lua
require(script.Parent.Parent.Rebirth.RebirthService)   -- inside SyncGamepassAsync
```

> **Every require here is unconditional and direct.** There is **no**
> `Set*Service()` injection in this system. `ShopService` therefore
> must be `Init()`ed **after** every service it calls into.

### `ServerScriptService/Shop/DoorService.lua`

```lua
require(ServerScriptService.BaseService)
require(ServerScriptService.Base.BaseLockService)
require(ReplicatedStorage.Config.Economy.Shop)
require(ReplicatedStorage.Config.World.Prompts)
require(ReplicatedStorage.Config.Systems.Security)
require(ReplicatedStorage.Utility.Validation)
require(ServerScriptService.Base.NotificationService)
require(ReplicatedStorage.Utility.Debug)
```

### `ReplicatedStorage/Config/Economy/Shop.lua`

No requires.

---

## Other Systems Required

### Required at load time (direct `require`)

| System | Module | Method / field used | Why | Optional? |
|---|---|---|---|---|
| **Economy** | `ServerScriptService.EconomyService` | `AddMoney(userId, amount, 'ShopMoneyPack')` | The money packs. | **Required** for the `Money` kind. |
| **Gear / Shop** | `ServerScriptService.GearShop.GearShopService` | `GrantRobuxGear(player, gearId)`, `EquipGear(player, gearId)` | The `Gear` kind. | **Required** for the `Gear` kind. |
| **ServerLuck** | `ServerScriptService.ServerLuckService` | `ActivateBoost(mult, durationSecs, source)`, `OnBoostExpired(fn)` | The `ServerLuck` kind + the expiry announcement. | **Required** for the `ServerLuck` kind. |
| **Modifiers** | `ServerScriptService.ModifierService` | `AddModifier`, `RemoveModifier`, `GetModifiers`, `ModifierType.MoneyMultiplier`, `Operation.Multiply` | The 2X Money gamepass multiplier. | **Required** for the gamepass. |
| **DailyRewards** | `ServerScriptService.Daily.DailyRewardsService` | `GrantSkipAccess(player)`, `ClaimAll(player)` | The `SkipDaily` kind. | **Required** for the `SkipDaily` kind. |
| **PlaytimeRewards** | `ServerScriptService.Playtime.PlaytimeRewardsService` | `GrantSkipAccess(player)`, `ClaimAll(player)` | The `SkipPlaytime` kind. | **Required** for the `SkipPlaytime` kind. |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `GetBaseById(baseId)` | Resolving the base a door prompt belongs to. | **Required** for `DoorService`. |
| **BasesAndSlots** | `ServerScriptService.Base.BaseLockService` | `IsLocked`, `HasPurchasedAccess`, `UnlockPurchased`, `SubscribeLockChanged` | The lock state and the per-buyer grant. | **Required** for `DoorService`. |
| **Notifications** | `ServerScriptService.Base.NotificationService` | `NotifySuccess`, `NotifyWarning` | Every toast. | **Required** — the require is unconditional. |
| **SharedUtilities** | `ReplicatedStorage.Utility.Remotes` | `Remotes.Names.ShopAction`, `Remotes.Names.ShopResult`, `GetFolder`, `FireClient` | The `ShopAction` wiring and the sync result. | **Required** — `ShopService.Init` asserts the remote exists. |
| **SharedUtilities** | `ReplicatedStorage.Utility.Validation` | `LivePlayer`, `CanPlayerInteract` | Server-side liveness / interaction checks. | **Required** |
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | `Log`, `Warn` | The `'SHOP'` and `'DOOR'` logging channels. | **Required** |
| **AdminTools** | `ReplicatedStorage.Config.Systems.Security` | `Receipts.SeenCap`, `Receipts.ActionCooldownSeconds`, `Door.RequestCooldownSeconds`, `Door.RangeSlackStuds` | The rate limits. | **Required** |
| **Carry** | `ReplicatedStorage.Config.World.Prompts` | `Prompts.DoorOpen` | The door prompt's text, hold duration, range. | **Required** for `DoorService`. |

### Optional in practice (the require is unconditional; the call is deletable)

| System | Module | Method used | Why | How to drop it |
|---|---|---|---|---|
| **Rebirth** | `ServerScriptService/Rebirth/RebirthService` | `RefreshBaseMultiplier(userId)` | Repaints the owner's base label with the new multiplier. | The `require` is **lazy** (inside `SyncGamepassAsync`, in a `pcall`) — if the module is missing the whole block is skipped. Nothing else to change. |
| **Analytics** | `ServerScriptService.FunnelService` | `LogStep(player, funnel, step, meta)` | Purchase / grant / prompt funnel steps. | Every call is `pcall`-guarded. Delete the require and the blocks. |
| **AdminTools** | `ServerScriptService/PlayerLogger/PlayerLogger` | `LogMilestone(player, 'PurchaseGranted', meta)` | The purchase-milestone log. | The call is `pcall`-guarded. Delete the require and the call. |

### Not required — and deliberately so

| System | Why it is absent |
|---|---|
| **Stealing** | The module header says it outright: *"Steal semantics are untouched: this module never gates stealing and never reads StealService."* A paid door grant does **not** affect raids. |
| **Arena** | Not touched. |

---

## Remotes

| Remote | Direction | Payload shape |
|---|---|---|
| `ShopAction` | C→S | `{ Action = 'SyncGamepass' }` or `{ Action = 'FunnelPrompt', ProductId?: number, GamepassId?: number }`. **Any other `Action` is silently ignored.** The `FunnelPrompt` variant is **analytics only** — it never grants anything. |
| `ShopResult` | S→C | `{ Action = 'SyncGamepass', Success = true, Owned = boolean }`. `Success` is **always `true`** (the *sync* succeeded); the entitlement state is in `Owned`. |

Remote names come from `ReplicatedStorage.Utility.Remotes` (the
`Remotes.Names` registry: `ShopAction = 'ShopAction'`,
`ShopResult = 'ShopResult'`). The server creates the events at boot
from that registry — **do not hand-author them**.

`ShopService.Init()` wires the server side:

```lua
local folder = Remotes.GetFolder()
local remote = folder:WaitForChild(Remotes.Names.ShopAction, 10)
assert(remote and remote:IsA('RemoteEvent'), 'ShopAction remote missing')
```

Both the `WaitForChild` and the `assert` sit inside a `pcall`, so a
missing remote **degrades loudly but does not block boot** — the
receipt router still installs.

**Roblox's own purchase dialogs are not remotes.** The client calls
`MarketplaceService:PromptProductPurchase` / `:PromptGamePassPurchase`
directly, and the server responds through
`MarketplaceService.ProcessReceipt`.

---

## Profile Fields

### Written by this system

| Field | Type | Writer | Notes |
|---|---|---|---|
| `Money` | string (BigNumber) | `EconomyService.AddMoney` (called by `ShopService`) | The money packs. The reason is the literal `'ShopMoneyPack'`. **Not written directly by `ShopService`.** |
| `Stats.*` (gear) | — | `GearShopService.GrantRobuxGear` (called by `ShopService`) | The Robux-bought gear. The **same** item and the **same** ownership as every other acquisition path — the Shop never creates a parallel Shop-only copy. |
| `DailyRewards` skip | — | `DailyRewardsService.GrantSkipAccess` (called by `ShopService`) | The skip entitlement. |
| `PlaytimeRewards` skip | — | `PlaytimeRewardsService.GrantSkipAccess` (called by `ShopService`) | The skip entitlement. |

### Read by this system

| Field | Type | Reader | Notes |
|---|---|---|---|
| — | — | — | **This system reads no profile field directly.** Every read goes through another service. |

### Untouched by design

`Brainrots[]`, `Rebirth`, `Multipliers`, `Arcs`, `Stats` (other than
the gear/skip services' own writes). The Shop never touches an
animal, a base's contents, or a progression record.

### Not persisted

| State | Where | Why |
|---|---|---|
| The 2X Money modifier | `ModifierService` | Session-scoped by design — the **entitlement** is the persistent thing and is re-resolved from Roblox on every join. |
| The temporary luck boost | `ServerLuckService` | Temporary by design. |
| The receipt dedupe set | `ShopService` (module-local) | Bounded in memory; cleared on overflow. |
| The door purchase context | `DoorService` (module-local) | TTL-bound, dies in ≤ 15 minutes. |
| The per-buyer door grant | `BaseLockService` (not the profile) | Lives on the **base**, not on the player. Clears on base release/reassign/wipe. |

---

## Required Studio Assets

### For `DoorService`

| Asset | Where | Notes |
|---|---|---|
| A base model with a resolvable **collector part** | The base's folder in Workspace | `DoorService` reads `base.collector` off the base record and requires it to be a **`BasePart`**. That part becomes the prompt's parent. `BaseService._resolveCollector` populates it — it picks the base folder's collector part (falling back to a primary/descendant part), so the collector is normally **auto-resolved by `BaseService`, not hand-stamped**. If the collector is missing or is not a `BasePart`, **no prompt is created** and `RefreshBase` logs `'locked base has no collector; prompt unavailable'`. |

**The door prompt itself is NOT authored in Studio.** `DoorService`
creates and destroys it server-side.

### For the `Gear` kind

| Asset | Where | Notes |
|---|---|---|
| The Galaxy Bat `Tool` | `ServerStorage` (or wherever the gear catalogue expects it) | `GearShopService.GrantRobuxGear` needs the Tool to exist. A missing Tool makes the grant fail → the receipt **retries** (it is not consumed) and a loud warn is logged. |

### For the client Shop GUI (not part of this system)

The `Shop.CardMap` refers to paths relative to the Shop
`ScrollingFrame` — `Money/Row1/1`, `Passes/5`, `Items/1`, etc. The
GUI itself belongs to the client presentation layer. Alternatively,
stamp a **`ProductId` number attribute** on each Buy button in Studio
— that wins over the `CardMap`.

### For the `ServerLuck` kind

No assets. The boost is a number in `ServerLuckService`.

---

## External APIs

| API | Use | Permissions / notes |
|---|---|---|
| `MarketplaceService.ProcessReceipt` | **Assigned** by `ShopService.Init()`. The single authoritative router. | Must be assigned **once**, before any purchase can arrive. |
| `MarketplaceService:UserOwnsGamePassAsync(userId, gamepassId)` | The 2X Money entitlement check. | A network failure leaves `owned = false` → the modifier is removed. Requires a published place. |
| `MarketplaceService:PromptProductPurchase(player, productId)` | The door purchase dialog. | A throw removes the pending context and returns `false`. |
| `MarketplaceService:PromptGamePassPurchase(player, gamepassId)` | The 2X Money purchase dialog. | Called by the **client**, not by this system. |
| `Players:GetPlayerByUserId(userId)` | Resolving the buyer in a receipt. | Wrapped in a `pcall`. |
| `Players:GetPlayers()` | The server-wide luck announcements. | O(players) per purchase and per boost expiry. |
| `DataStoreService` | **Indirect only**, through `PlayerService`'s profile. | `Enable Studio Access to API Services` in Studio. |

No HTTP requests. No `HttpService`. No webhooks. No API keys or
tokens of any kind are used or required by this system.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  GearShopService.Init()
3.  DailyRewardsService.Init()
4.  PlaytimeRewardsService.Init()
5.  ShopService.Init()      -- installs ProcessReceipt + wires ShopAction
6.  DoorService.Init()      -- subscribes to SubscribeLockChanged
7.  --- players may now join ---
```

Per-player, on join:

```text
1.  PlayerService.LoadPlayerData(player)
2.  GearShopService.OnPlayerReady(player)
3.  ShopService.OnPlayerReady(player)    -- silent gamepass entitlement sync
```

Per-player, on leave:

```text
1.  DailyRewardsService.ForgetPlayer(userId)
2.  PlaytimeRewardsService.ForgetPlayer(userId)
3.  DoorService.ForgetPlayer(userId)      -- drops the throttle, KEEPS the pending context
4.  ShopService.ForgetPlayer(userId)      -- drops the ShopAction throttle
```

> **The bootstrap's leave comment is stale.** It says "Shop: drop
> pending door-purchase contexts + throttle stamps", but
> `DoorService.ForgetPlayer` deliberately clears **only** the
> throttle. The pending context survives leave on purpose (a buyer
> who disconnects mid-dialog still fulfills on the receipt retry).
> The code is right; the comment is out of date.

### The ordering constraint

Because both services use **direct requires** and no injection, the
only hard constraint is: **`ShopService.Init()` must run after
`GearShopService.Init()`, `DailyRewardsService.Init()`,
`PlaytimeRewardsService.Init()`, and `ModifierService` must be
usable.** `DoorService.Init()` must run after `BaseLockService` is
ready to accept `SubscribeLockChanged` subscribers.

There is **no cycle**: none of the gameplay services require
`ShopService` back. The bootstrap comment states this explicitly.
