# Items — Dependencies

Exact module require paths (verbatim from the source), the systems Items
needs, the remotes it uses, the profile fields it reads and writes, the
Studio assets it assumes, and the exact initialization order.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Setup.md](Setup.md)

---

## Module Requires

All requires are in
`Source/ServerScriptService/GearShop/GearShopService.lua` (lines 44–57).

```lua
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local ServerScriptService = game:GetService('ServerScriptService')
local Workspace = game:GetService('Workspace')

local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Validation = require(ReplicatedStorage.Utility.Validation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local Debug = require(ReplicatedStorage.Utility.Debug)
local NotificationService = require(ServerScriptService.Base.NotificationService)
-- Funnel analytics (leaf module — never gameplay-critical).
local FunnelService = require(ServerScriptService.FunnelService)
```

### One lazy require

```lua
-- Inside GearShopService.GetPlayerRebirth (line ~155):
local RebirthService = require(script.Parent.Parent.Rebirth.RebirthService)
```

`script.Parent.Parent.Rebirth.RebirthService` resolves to
`ServerScriptService.Rebirth.RebirthService` — the `Rebirth` folder is
a **sibling** of `GearShop` under `ServerScriptService`. It is required
**lazily inside a `pcall`** to break a require cycle, and a failure
fails closed to a rebirth count of `0`.

### Injected dependencies (not `require`d)

```lua
GearShopService.SetPlayerService(svc)    -- needs svc.GetPlayerData(userId) -> table?
GearShopService.SetEconomyService(svc)   -- needs svc.GetMoney(userId) -> string
                                         --      svc.TrySpendMoney(userId, amount, reason) -> { Success, Code? }
                                         --      svc.AddMoney(userId, amount, reason, opts?) 
```

Both are injected to keep the module free of require cycles. The service
degrades gracefully when either is missing — but **a purchase without
`EconomyService` fails** with `error = 'service-not-ready'`, and
**`SetAutoBuy` without `PlayerService` fails** with the same error.

### Where each required module lives

| Required path | Roblox destination | Owned by |
|---|---|---|
| `ReplicatedStorage.Config.Economy.Gear` | `ReplicatedStorage/Config/Economy/Gear.lua` | **Combat** |
| `ReplicatedStorage.Config.World.Prompts` | `ReplicatedStorage/Config/World/Prompts.lua` | **Carry** |
| `ReplicatedStorage.Utility.Remotes` | `ReplicatedStorage/Utility/Remotes.lua` | **Shared** |
| `ReplicatedStorage.Utility.Validation` | `ReplicatedStorage/Utility/Validation.lua` | **Shared** |
| `ReplicatedStorage.Utility.BigNumber` | `ReplicatedStorage/Utility/BigNumber.lua` | **Shared** |
| `ReplicatedStorage.Utility.Debug` | `ReplicatedStorage/Utility/Debug.lua` | **Shared** |
| `ServerScriptService.Base.NotificationService` | `ServerScriptService/Base/NotificationService.lua` | **Notifications** |
| `ServerScriptService.FunnelService` | `ServerScriptService/FunnelService.lua` | **Analytics** |
| `ServerScriptService.Rebirth.RebirthService` | `ServerScriptService/Rebirth/RebirthService.lua` | **Upgrades** (lazy, `pcall`-guarded) |

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **Combat** (`ReplicatedStorage.Config.Economy.Gear`) | The catalog (`GetAll`, `FindGear`, `IsLocked`, `ValidateLive`) and `Gear.Combat.GetByToolName` (the bat-name test used by the duplicate cleanup). | **No.** Without it the module fails to load. |
| **Economy** (`EconomyService`) | `TrySpendMoney` / `AddMoney` / `GetMoney`. Injected, not required. | **Effectively required** — purchases fail with `'service-not-ready'` without it. |
| **PlayerData** (`PlayerService`) | `GetPlayerData(userId)` — the profile table that holds `GearAutoBuy` and `OwnedRobuxGear`. Injected, not required. | **Effectively required** — AutoBuy write, the Robux entitlement write, and the join auto-buy all need it. |
| **Shared** (`Remotes`, `Validation`, `BigNumber`, `Debug`) | Remote plumbing, the `LivePlayer` predicate, price formatting and the shortfall, and logging. | **No.** |
| **Notifications** (`NotificationService`) | The shop toasts (`Gear_Success`, `Gear_AlreadyOwned`, `Gear_InsufficientCash`, `Gear_RobuxOnly`, `Gear_LockedRebirth`, `Gear_ToolUnavailable`, `Gear_InvalidGear`, `Gear_Busy`). | **Yes** — the toasts are all `pcall`-guarded; the purchase still works without them. |
| **Analytics** (`FunnelService`) | `FirstGearPurchased` and `FirstGearEquipped` funnel steps. | **Yes** — `pcall`-guarded and never gameplay-critical. |
| **Upgrades / Rebirth** (`RebirthService`) | `GetRebirth(userId)` — the unlock ladder. | **Yes** — lazily required inside a `pcall`; a failure fails closed to `0` rebirth, which locks every rebirth-gated gear. |
| **ShopsAndPurchases** (`ShopService`) | Calls `GearShopService.GrantRobuxGear(player, entry.GearId)` from the Developer Product receipt. | **Yes** — but without it the `GalaxyBat` can never be granted. |
| **AdminTools** (`giveGear`, `giveAllGear`) | Calls `GearShopService.EnsureGearTool` to admin-grant gear. | **Yes.** |
| **CodesAndRewards** (`CodesService`, `DailyRewardsService`, `PlaytimeRewardsService`) | Inject `GearShopService` via `SetGearShopService` and call `EnsureGearTool` to grant reward gear. | **Yes.** |
| **ClientPresentation** (`GearShopController`, `RebirthController`) | Renders the shop GUI, reads `GearShopState`, sends `GearShopAction`, and previews gear from `ReplicatedStorage.GearShopPreviews`. | **Yes** — the server works without it (the GUI just never opens). |

**Note the ownership direction.** The gear *catalog* belongs to the
**Combat** system, not to Items. The *shop* belongs to Items. This
system therefore has **no config of its own** — see
[README.md](README.md#configuration).

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `GearShopAction` | C → S | `{ Action: 'Purchase' \| 'Equip' \| 'SetAutoBuy', GearId: string, Enabled: boolean? }` |
| `GearShopState` | S → C | `{ Money: string, MoneyText: string, Rebirth: number, Show: boolean?, Gears: { … }[] }` — the per-gear entry is `{ Id, Name, Description, Price, PriceText, RequiredRebirth, ToolName, Locked, Owned, AutoBuy }`. |
| `GearShopResult` | S → C | `{ Action: string, GearId: string, Success: boolean, Error: string? }` |

All three names come from `Remotes.Names` in
`Shared/CommonModules/Remotes.lua` (lines 124–126). The server listens
on `GearShopAction`; it pushes `GearShopState` and `GearShopResult`.

### The `GearShopAction` payload, precisely

- `Action` **must** be a string. A payload that is not a table, or
  whose `Action` is not a string, is logged as
  `'[GearShop] Malformed action from player=<name>'` and dropped.
- `Purchase` → `GearShopService.Purchase(player, payload.GearId)`, then
  pushes a `GearShopResult` **and** a fresh `GearShopState`.
- `Equip` → `GearShopService.EquipGear(player, payload.GearId)`, then
  pushes a `GearShopResult` and a fresh `GearShopState`.
- `SetAutoBuy` → `GearShopService.SetAutoBuy(player, payload.GearId,
  payload.Enabled)`, then pushes a `GearShopResult`. It does **not**
  push a state itself — `SetAutoBuy` does that internally.
- Any other action → logged as
  `'[GearShop] Unknown action=<action> from player=<name>'` and
  dropped.

The server **never trusts** `GearId` — it re-resolves everything from
the catalog by `Id`.

---

## Profile Fields

| Field | Type | Read by | Written by |
|---|---|---|---|
| `GearAutoBuy` | `{ [gearId]: boolean }` | `BuildState` (the per-gear `AutoBuy` flag), `OnPlayerReady` (the auto-buy loop) | `SetAutoBuy` (a single key), `NormalizeAutoBuy` (adds a missing known gear as `false`) |
| `OwnedRobuxGear` | `{ [gearId]: true }` | `OnPlayerReady` (the Robux re-grant loop) | `GrantRobuxGear` (a single key), `NormalizeOwnedRobuxGear` (creates the table if absent) |

Both are accessed through `playerServiceRef.GetPlayerData(userId)`
inside `pcall`s.

**No other profile field is read or written.** Notably:

- **Cash purchases are NOT persisted.** There is no `OwnedGear` field.
  The session `ownedBy` table is the only ownership store for
  cash-purchased gear, and it dies with the server.
- **The equipped choice is NOT persisted.** `equippedBy` is session
  only.

---

## Required Studio Assets

### ServerStorage (server-only, never replicated)

```text
ServerStorage
└── Assets
    └── Ui
        └── GearShop
            ├── GearTemplate          -- the authoritative shop row prototype
            └── Tools
                ├── Default Bat       -- Tool
                ├── Speed Coil        -- Tool
                ├── Silver Bat        -- Tool
                ├── Gravity Coil      -- Tool
                ├── Gold Bat          -- Tool
                ├── Coil Combo        -- Tool
                ├── Diamond Bat       -- Tool
                ├── Obsidian Bat      -- Tool
                ├── Crystal Bat       -- Tool
                ├── Invisible Cloak   -- Tool
                ├── Hacker Bat        -- Tool
                └── Galaxy Bat        -- Tool
```

The folder name for each `Tool` is the **exact** `ToolName` from the
catalog entry. The **display** `Name` (e.g. `'Silver Bat'` for the
`SilverBat` entry) is free to change without touching the mapping.

`Tool` authoring notes:

- A `Tool` with `RequiresHandle = true` needs a `Handle` child that
  is a `BasePart`. The trace dump reports `handle=missing` otherwise,
  and the player can hold the instance but never properly equip or
  use it.
- The handle should generally be `Anchored = true` and
  `CanCollide = false`.
- `GearTemplate` must be a `GuiObject`-compatible prototype with
  **no `GearId` attribute** — the server treats a template that
  already has one as stale and re-clones it.

### Workspace

```text
Workspace
└── Map
    └── Shop
        └── PromptPart      -- BasePart
            └── ProximityPrompt   (optional — created by the server
                                   if absent)
```

If `PromptPart` is missing, the server logs
`'[GearShop] PromptPart missing (expected Workspace.Map.Shop.PromptPart); shop has no world entry'`
and the shop has no world entry — the GUI path still works if the
client opens it another way.

### StarterGui (client-side)

```text
StarterGui
└── GearShop                  -- a ScreenGui (or any Instance the client can find)
    └── ScrollingFrame        -- the server clones the template into this
```

The server finds it with `PlayerGui:FindFirstChild('GearShop', true)`
and then `:FindFirstChild('ScrollingFrame', true)`. Both are found
**recursively**, so they may be nested.

### ReplicatedStorage (published by the server)

```text
ReplicatedStorage
└── GearShopPreviews          -- created by publishPreviews() at Init
    ├── SpeedCoil             -- script-stripped Tool clone, named by gearId
    ├── SilverBat
    ├── …
    └── DefaultBat
```

Published **once** at `Init`. The clones have every `Script` and
`LocalScript` descendant destroyed. The client renders these in
`ViewportFrame`s.

---

## External APIs

| API | Used by | Where |
|---|---|---|
| **Roblox MarketplaceService** (Developer Product receipts) | The **Shop** system, not this one | `ShopsAndPurchases` calls `GearShopService.GrantRobuxGear(player, entry.GearId)` from the receipt handler. `GearShopService` itself makes **no** MarketplaceService call. |

**No API key, token, webhook URL or credential is involved.** The
`GalaxyBat` product is identified by its **Product Id**, which is
configured in the **Shop** system's config, not here. If you port the
Robux path, configure the Developer Product Id through your own
secret-management approach (e.g. a server-only config module or
Roblox's `HttpService`/`GamePassService` conventions) — **never** hard-code
it in a client-visible module and never commit it to source control.

---

## Exact Initialization Order

```text
1.  Remotes folder created + Remotes.SetRemotes(folder)
    -- GearShopAction must exist. Init() waits up to 10 seconds for it
    -- (Remotes.GetFolder():WaitForChild(...)) and warns if it is
    -- missing; the rest of the service still initialises.

2.  GearShopService.SetPlayerService(PlayerService)
3.  GearShopService.SetEconomyService(EconomyService)
4.  GearShopService.Init()
      a. GearConfig.ValidateLive()  -> config issues are warns
      b. publishPreviews()          -> ReplicatedStorage.GearShopPreviews
      c. wireShopPrompt()           -> Workspace.Map.Shop.PromptPart
      d. connect GearShopAction.OnServerEvent
```

`Init` is guarded by a `started` flag, so a second call is a no-op —
it will **not** re-publish the previews or re-wire the prompt.

### Per-player order

```text
Player joins
  -> the profile is loaded (MarkLoaded)
  -> GearShopService.OnPlayerReady(player)
       1. EnsureDefaultBat + EquipGear(DefaultBat)
       2. NormalizeAutoBuy(profile)
       3. auto-buy loop, in CATALOG ORDER, quiet = true
       4. persisted Robux entitlement re-grant
       5. pushState if anything was granted

Character spawns / respawns
  -> GearShopService.OnCharacterSpawned(player)
       1. EnsureOwnedTools(player)
       2. EquipGear(session choice, or DefaultBat)

Player leaves
  -> GearShopService.ForgetPlayer(userId)
```

**`OnPlayerReady` must run after the profile is loaded.** The
`readyBy` guard means it will not retry: if it is called too early, the
auto-buy loop sees no profile, does nothing, and the player never gets
their auto-buy on that join.
