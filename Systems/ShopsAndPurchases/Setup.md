# Shops and Purchases — Setup

Installing the Shops and Purchases system into a new Rojo project.
Steps 1-4 are the system itself; steps 5-6 add the UI and the
client request path.

---

## 1. Copy the files

| Copy from | To | Required? |
|---|---|---|
| `Source/ServerScriptService/Shop/ShopService.lua` | `ServerScriptService/Shop/ShopService.lua` | **Yes** |
| `Source/ServerScriptService/Shop/DoorService.lua` | `ServerScriptService/Shop/DoorService.lua` | **Yes** |
| `Source/ReplicatedStorage/Config/Economy/Shop.lua` | `ReplicatedStorage/Config/Economy/Shop.lua` | **Yes** |

**Shared modules you also need** (from `ReusableSystems/Shared/`):

| Library file | Roblox destination |
|---|---|
| `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Utilities/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `CommonModules/...` | `ReplicatedStorage/Utility/...` |

**External configs you also need** (they live in *other* systems'
folders in this library):

| Library file | Roblox destination | What is read |
|---|---|---|
| `AdminTools/Source/ReplicatedStorage/Config/Systems/Security.lua` | `ReplicatedStorage/Config/Systems/Security.lua` | `Receipts.SeenCap`, `Receipts.ActionCooldownSeconds`, `Door.RequestCooldownSeconds`, `Door.RangeSlackStuds` |
| `Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` | `Prompts.DoorOpen` |

**Other systems you need present** (the requires are unconditional):

| System | Module | Used for |
|---|---|---|
| **Economy** | `ServerScriptService/EconomyService.lua` | The money packs. |
| **Gear / Shop** | `ServerScriptService/GearShop/GearShopService.lua` | The Galaxy Bat product. |
| **ServerLuck** | `ServerScriptService/ServerLuckService.lua` | The luck boosts + the expiry announcement. |
| **Modifiers** | `ServerScriptService/ModifierService.lua` | The 2X Money multiplier. |
| **DailyRewards** | `ServerScriptService/Daily/DailyRewardsService.lua` | The Skip Daily product. |
| **PlaytimeRewards** | `ServerScriptService/Playtime/PlaytimeRewardsService.lua` | The Skip Playtime product. |
| **BasesAndSlots** | `ServerScriptService/BaseService.lua` + `ServerScriptService/Base/BaseLockService.lua` | The door flow. |
| **Notifications** | `ServerScriptService/Base/NotificationService.lua` | Every toast. |
| **PlayerData** | `ServerScriptService/PlayerService.lua` | The profile (indirectly). |
| **Analytics** | `ServerScriptService/FunnelService.lua` | Optional — every call is `pcall`-guarded. |
| **AdminTools** | `ServerScriptService/PlayerLogger/PlayerLogger.lua` | Optional — the call is `pcall`-guarded. |
| **Rebirth** | `ServerScriptService/Rebirth/RebirthService.lua` | Optional — a **lazy** require; if the module is absent the block is skipped entirely. |

---

## 2. Third-party packages (Wally)

The Shops system itself needs **no** third-party package, but its
dependencies do:

```toml
[dependencies]
janitor = "kineticwallet/janitor@1.17.0"   -- only if you install PlayerData
```

and the vendored `ProfileService` at
`ServerScriptService/Packages/ProfileService.lua`.

`Validation.lua` requires `ReplicatedStorage.Packages.t`
(`osyrisrblx/t`), which the source game vendors under `Packages/`.

---

## 3. Configuration to tune

Open `ReplicatedStorage/Config/Economy/Shop.lua`.

> **THE ONE THING YOU MUST DO: replace all 13 ids.**
>
> | # | Where | Value to replace |
> |---|---|---|
> | 1-12 | `Shop.DeveloperProducts.*.ProductId` | The 12 Developer Product ids |
> | 13 | `Shop.Gamepasses.Money2x.GamepassId` | The gamepass id |
>
> The shipped values are the **real ids from the source game's
> Creator Dashboard**. They are **placeholders for a new game**.
> Until you replace them, every receipt resolves as an "unknown
> ProductId" and Roblox retries it forever.

Get the real ids from **your own** Creator Dashboard → **Store** →
**Developer Products** / **Game Passes**.

Other values worth a look:

| Value | Default | When to change it |
|---|---|---|
| `DeveloperProducts.*.Robux` | 19-499 | Display-only metadata (the client shows it). Roblox's Dashboard is the authority on the real price. |
| `DeveloperProducts.*.Amount` (money packs) | `'10000'` … `'1000000'` | The config comment flags the ladder as *"sane but unapproved -- DESIGNER: confirm these before launch"*. **Must be a raw BigNumber decimal string**, not `'10K'`. |
| `DeveloperProducts.*.Multiplier` | 2, 4, 8 | Must have a matching `ServerLuckDurations` entry. |
| `ServerLuckDurations` | 900 / 600 / 300 | Designer-owned. Higher multipliers last shorter. |
| `Gamepasses.Money2x.Robux` | 199 | Display-only. |
| `CardMap` | 7 paths | Tied to your Shop GUI's exact hierarchy. See below. |

**The `CardMap`.** It maps a **Studio card path** to a product key,
for cards whose Buy button carries neither a `ProductId` attribute
nor a product-key name. The paths are relative to the Shop
`ScrollingFrame`, computed by walking up from the clicked Buy
button:

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

**Four paths are deliberately UNMAPPED**: `Events/1`, `Passes/4`,
`Items/2`, `Featured/StarterPack`. The config says why: *"guessing a
charge is worse than a loud error"*. Do not map them unless you
actually create the products.

**The better option:** stamp a `ProductId` **number attribute** on
each Buy button in Studio. The attribute wins over the `CardMap`,
and it survives a GUI redesign.

**Two hardcoded limits are not in `Security.lua`.** If you want them
tunable, move them:

| Constant | Where | Value |
|---|---|---|
| `PROMPT_COOLDOWN_S` | `ShopService.lua` | `2` (the funnel prompt-intent throttle) |
| `PENDING_TTL_S` | `DoorService.lua` | `15 * 60` (the pending door context's TTL) |

The other four limits (`SeenCap`, `ActionCooldownSeconds`,
`Door.RequestCooldownSeconds`, `Door.RangeSlackStuds`) are already in
`Security.lua`.

A consolidated, documented view of every value is in
[`Config.lua`](Config.lua).

---

## 4. Bootstrap: the exact sequence

```lua
-- ReplicatedStorage
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

-- --- 1. Remotes first ---
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Instance.new('Folder')
remotesFolder.Name = 'Remotes'
remotesFolder.Parent = ReplicatedStorage
Remotes.SetRemotes(remotesFolder)

-- --- 2. The services the shop calls into. Their Init() must run
--     BEFORE ShopService.Init() (the requires are direct, not
--     injected).
local GearShopService = require(ServerScriptService.GearShop.GearShopService)
local DailyRewardsService = require(ServerScriptService.Daily.DailyRewardsService)
local PlaytimeRewardsService = require(ServerScriptService.Playtime.PlaytimeRewardsService)
GearShopService.Init()
DailyRewardsService.Init()
PlaytimeRewardsService.Init()

-- --- 3. The shop itself ---
local ShopService = require(ServerScriptService.Shop.ShopService)
local DoorService = require(ServerScriptService.Shop.DoorService)
ShopService.Init()   -- installs MarketplaceService.ProcessReceipt
DoorService.Init()   -- subscribes to SubscribeLockChanged

-- --- 4. players may now join ---
```

> **There is no `Set*Service()` in this system.** Every dependency
> is a direct `require`. That means `ShopService.Init()` cannot be
> moved before the services it calls into — it would be fine to
> *require* it early, but its `Init()` must come last.
>
> `ShopService.Init()` must be **after** every service it calls
> into, and **before players join** (the bootstrap says exactly
> this).

### The join and leave hooks

```lua
-- OnPlayerAdded (after the profile is loaded):
pcall(GearShopService.OnPlayerReady, player)
pcall(ShopService.OnPlayerReady, player)   -- silent gamepass sync

-- OnPlayerRemoving:
DoorService.ForgetPlayer(userId)   -- drops the throttle, KEEPS the pending context
ShopService.ForgetPlayer(userId)   -- drops the ShopAction throttle
```

> The source game's bootstrap comment claims `DoorService.ForgetPlayer`
> "drop[s] pending door-purchase contexts". **It does not** — the
> service deliberately keeps them (a buyer who leaves mid-dialog must
> still fulfill on the receipt retry). The code is correct; the
> comment is stale.

---

## 5. The client request path

`ShopService` handles **two** client verbs on the `ShopAction`
remote.

### A. Buying a Developer Product

The **client** calls Roblox directly — there is no server round-trip:

```lua
MarketplaceService:PromptProductPurchase(player, productId)
```

The server responds through `MarketplaceService.ProcessReceipt`,
which `ShopService` owns. Do not write your own purchase handler on
top of it.

### B. Buying a gamepass

Also client-side:

```lua
MarketplaceService:PromptGamePassPurchase(player, gamepassId)
```

Gamepasses emit **no receipt**, so after the dialog closes the client
must ask the server to re-resolve the entitlement:

```lua
Remotes.FireServer(Remotes.Names.ShopAction, { Action = 'SyncGamepass' })
```

The server answers with `ShopResult`:

```lua
{ Action = 'SyncGamepass', Success = true, Owned = true }
```

`Success` is **always `true`** — the sync ran. The entitlement state
is `Owned`.

### C. The funnel ping (optional, analytics only)

```lua
Remotes.FireServer(Remotes.Names.ShopAction, {
    Action = 'FunnelPrompt',
    ProductId = 3715397862,
})
```

This is **never** an entitlement. The server re-resolves the product
from `ShopConfig` and only logs a funnel step. Throttled to one per
2 seconds per player.

### D. The door purchase (server-initiated)

The door does **not** go through `ShopAction`. The server calls
`MarketplaceService:PromptProductPurchase` itself from
`DoorService.RequestOpen`, after validating everything.

---

## 6. Studio assets to author

### For the door flow

| Asset | Where | Notes |
|---|---|---|
| A base folder with a resolvable **collector part** | Workspace | `BaseService._resolveCollector` finds it; `DoorService` parents the prompt to `base.collector`. The collector must be a **`BasePart`**. |
| A `PromptOwnerFilter` door rule (owner never sees the prompt) | Client UI | **UX only.** The server revalidates everything, so this is safe to omit. |

**You do NOT author the `OpenDoorPrompt`.** `DoorService` creates and
destroys it server-side:

- Created when the base becomes owned **and** locked.
- Destroyed when it unlocks (owner button, timer expiry, release, or
  purchase grant).
- `ActionText` = `'Open Door'`, `ObjectText` = `'Locked Base'`,
  `HoldDuration` = `0`, `MaxActivationDistance` = `12`,
  `RequiresLineOfSight` = `false` — all from
  `Prompts.DoorOpen`.

### For the gear product

| Asset | Where | Notes |
|---|---|---|
| The Galaxy Bat `Tool` | wherever `GearShopService` expects it | A missing Tool makes the grant fail → the receipt **retries**, and a loud warn is logged. |

### For the Shop GUI (client presentation layer, not this system)

Each Buy button needs either a `ProductId` **number attribute** or a
path that resolves in `Shop.CardMap`. See step 3.

---

## 7. Smoke test

Do these in order in a **published** place (the gamepass check and
the purchase dialogs need a live experience).

**A. The receipt router is installed.**

1. Publish the place and buy the cheapest Developer Product.
2. The money arrives, the receipt logs `'purchase receipt'` then
   `'purchase granted'`.
3. If the money does **not** arrive, check the `Shop` log channel —
   an `'unknown ProductId; receipt will retry'` warning means your
   `ProductId` in the config does not match the Dashboard.

**B. The money amount is exact.**

1. Note the wallet before the purchase.
2. Buy `MoneyPack1` (`'10000'`).
3. The wallet went up by exactly `10000` — not `10000.00`, not
   `10000` in scientific notation.
4. The toast reads a **formatted** amount (`$10K`), because
   `NotificationService` owns the formatting.

**C. A duplicate receipt does not double-grant.**

1. Buy `MoneyPack1` again (a second, real purchase).
2. The wallet goes up by `10000` **once**.

**D. The unknown-product path retries.**

1. Temporarily add a bogus `ProductId` to the config.
2. Buy it.
3. The log shows `'unknown ProductId; receipt will retry'` and the
   purchase is **not** consumed. Remove the bogus entry.

**E. The gamepass.**

1. Buy the 2X Money gamepass.
2. The client fires `ShopAction { Action = 'SyncGamepass' }`.
3. The server replies `ShopResult { Owned = true }` and the player
   sees the `'Shop_GamepassActive'` toast.
4. Rejoin → the entitlement is re-resolved silently and the
   multiplier is still there.
5. Buy it **again** → the player sees `'Shop_AlreadyOwned'`, not
   `'Shop_GamepassActive'`.

**F. The server luck boost.**

1. Buy the 2X luck product.
2. `ServerLuckService.GetLuck()` goes to 2 for the **whole server**.
3. **Every** player in the server sees the `'Shop_LuckActivated'`
   toast.
4. When the boost expires (15 minutes at 2x), every player sees
   `'Shop_LuckExpired'`.

**G. The door.**

1. Lock a base (as its owner).
2. A `ProximityPrompt` reading `'Open Door'` appears on the base's
   collector. The owner does **not** see it.
3. Walk up as **another** player and trigger it.
4. The Roblox purchase dialog opens.
5. Buy it. The base opens, you get `'Shop_DoorOpened'`, and you can
   walk through.
6. The **owner** re-locks the base. You can **still** walk through.
   Another player **cannot**.
7. Trigger the prompt again → you get `'Shop_DoorOpened'` immediately
   and are **not** charged again.

**H. The door's failure paths.**

1. Have the owner unlock the base while the purchase dialog is open,
   then complete the purchase. The grant is **still recorded** (you
   paid for access), and a later re-lock keeps your passthrough.
2. Have the base **change hands** while the dialog is open, then
   complete the purchase. The purchase is consumed **without**
   unlocking the new owner's base, and you get a warning toast.

**I. Leave mid-dialog.**

1. Start the door purchase, then **leave the server**.
2. Rejoin.
3. Complete the purchase from the resumed dialog (or let the receipt
   retry). The grant lands.

**J. The dedupe cap.**

1. Not practical to test by hand (5000 receipts). If you need to,
   lower `Security.Receipts.SeenCap` temporarily and watch the
   `'receipt dedupe table overflowed; cleared'` warn.

---

## 8. Running the tests

Three spec files, all TestEZ and Studio-only (there is no headless
Luau runner in this project).

1. Copy `Systems/ShopsAndPurchases/Tests/*.spec.lua` into your test
   tree.
2. Copy `ReusableSystems/Tests/_Helpers.lua` alongside them (the
   specs `require(script.Parent._Helpers)`).
3. Wire a TestEZ runner; see `ReusableSystems/Tests/README.md`.
4. Run in Studio.

`ShopReceipt.spec.lua` drives `ShopService._TestHandleReceipt`
directly — it never makes a real purchase.

`ShopConfig.spec.lua` is pure — it only reads `ShopConfig`.

`DoorService.spec.lua` uses the **real** `BaseService` and
`BaseLockService`, and plants purchase contexts with
`DoorService._TestSetPending` (the real prompt path needs Studio
characters and a live Roblox dialog, so it cannot be unit-tested).

The specs need **no DataStore, no published place, and no Robux**.

---

## 9. Trimming the system

| You want | Keep | Drop |
|---|---|---|
| Just Developer Products, no doors | `ShopService` + `Shop.lua` | `DoorService`, the `UnlockDoors` kind, the `UnlockDoors` product entry, the `Shop_DoorOpened` toast |
| No gear products | — | The `Gear` kind, `_grantGear`, the `GearShopService` require, the `GalaxyBat` product entry, the `GearShopService` Tool asset |
| No server luck | — | The `ServerLuck` kind, `_grantLuck`, `ServerLuckDurations`, the `ServerLuckService` require, the `OnBoostExpired` subscription, the `Shop_Luck*` toasts |
| No daily / playtime rewards | — | The `SkipDaily` / `SkipPlaytime` kinds and their helpers |
| No gamepasses | — | `SyncGamepassAsync`, `OnPlayerReady`'s body, the `ShopAction` branch, `ShopConfig.Gamepasses`, the `ModifierService` require, the `Shop_Gamepass*` toasts |
| No analytics | — | The `FunnelService` require and its `pcall` blocks, the `PlayerLogger` require and its call, the `FunnelPrompt` action branch, `_logPromptIntent` |

**Do not trim the receipt decision discipline.** The
`NotProcessedYet` / `PurchaseGranted` split, the "remember only on
success" rule, and the "unknown product never consumes" rule are the
difference between "a player never loses money" and "a player pays
and gets nothing".

**Do not trim the door grant's live re-validation.** Any shortcut —
trusting the stored `ownerId`, or opening the stored `baseId`
without re-checking ownership — is an exploit: one player could buy
a door and open a stranger's base.
