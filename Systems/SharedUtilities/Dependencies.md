# SharedUtilities — Dependencies

Exact requires, remotes, assets and boot order for the SharedUtilities
system.

Paths are the **live Roblox** paths. The library copies sit under
`ReusableSystems/Systems/SharedUtilities/Source/`.

---

## Module Requires

### `ServerScriptService/ServerLuckService.lua`

Verbatim from the source:

```lua
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Events = require(ReplicatedStorage.Config.World.Events)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

| Require | Owning system | Optional? |
|---|---|---|
| `ReplicatedStorage.Config.Creatures.Rarity` | Creatures | No — the require is non-deferred. It is read for `RarityConfig.LuckExponentDivisor` (a degenerate value falls back to `3` at runtime, but the module itself must load). |
| `ReplicatedStorage.Config.World.Events` | **Events** | **No** — the require is non-deferred, and the value (`Events.LuckPoolOrder`) is read at module scope into `LUCK_POOL`. **This is the cross-system coupling.** See the callout below. |
| `ReplicatedStorage.Utility.Debug` | Shared | No — non-deferred. |

### `ServerScriptService/SettingsService.lua`

```lua
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local Validation = require(game:GetService('ReplicatedStorage').Utility.Validation)
local PlayerService = require(script.Parent.PlayerService)
```

| Require | Owning system | Optional? |
|---|---|---|
| `ReplicatedStorage.Utility.Remotes` | Shared | No — non-deferred. |
| `ReplicatedStorage.Utility.Debug` | Shared | No — non-deferred. |
| `ReplicatedStorage.Utility.Validation` | Shared | No — non-deferred. It is `table.freeze`d and pulls in `osyrisrblx/t` and `Types/RarityType`. |
| `ServerScriptService.PlayerService` | PlayerData | No — non-deferred, and `script.Parent` means it must be a **direct child** of `ServerScriptService`. |

### `ServerScriptService/Utility/MoneyIcon.lua`

```lua
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
```

No other requires. It reaches `ServerStorage` and `ReplicatedStorage`
at runtime through `game:GetService`.

### `ServerScriptService/Utility/MutationIcon.lua`

```lua
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
```

### `ServerScriptService/Utility/PathfindingUtil.lua`

```lua
PathfindingUtil.YawSmoothing = require(game:GetService('ReplicatedStorage').Config.World.Movement).YawSmoothing
```

The config is required **at module scope** and the value is copied
into `PathfindingUtil.YawSmoothing`. A later change to
`Movement.YawSmoothing` does **not** propagate.

### `ServerScriptService/Utility/WaterHazard.lua`

```lua
local Workspace = game:GetService('Workspace')
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
```

### The five config domains

| File | Requires |
|---|---|
| `ReplicatedStorage/Config/Systems/Debug.lua` | **none** |
| `ReplicatedStorage/Config/World/Movement.lua` | **none** |
| `ReplicatedStorage/Config/Presentation/Audio.lua` | **none** |
| `ReplicatedStorage/Config/Presentation/UI.lua` | `require(script.Parent.Parent.Creatures.Rarity)` — the `Rarity` config. `script.Parent.Parent` is `ReplicatedStorage.Config`, so the file must live at `Config/Presentation/UI.lua`. |
| `ReplicatedStorage/Config/Presentation/Vfx.lua` | **none** |

### `ServerScriptService/bootstrap.server.lua` (the reference copy)

The bootstrap requires **~50 modules** across the entire game. It is
listed here for completeness; it is a **reference copy**, not an
installable part of this system. The full list is in the source file
at lines 25-199, 288, 295, 342, 360, 371, 378, 384, 388, 458, 515,
572-573.

The five that belong to this system:

| Require | Line |
|---|---|
| `ReplicatedStorage.Config.Systems.Debug` | `:29` |
| `ReplicatedStorage.Config.World.Movement` | `:30` |
| `ReplicatedStorage.Utility.ConfigValidator` | `:31` |
| `ReplicatedStorage.Utility.Remotes` | `:32` |
| `ReplicatedStorage.Utility.Debug` | `:33` |
| `ReplicatedStorage.Utility.Validation` | `:34` |
| `ReplicatedStorage.Utility.StudioTestMode` | `:35` |
| `ReplicatedStorage.Utility.AudioGroups` | `:36` |
| `ServerScriptService.SettingsService` | `:85` |
| `ServerScriptService.Utility.WaterHazard` | `:295` |

---

## Other Systems Required

| System / module | Why | Optional? |
|---|---|---|
| **Shared** `ReplicatedStorage.Utility.Debug` | Every module logs through it. | No — non-deferred in all six modules. |
| **Shared** `ReplicatedStorage.Utility.ConfigValidator` | Runs every config domain's `Validate()` at boot. | **Yes in principle** — but if you install this system, install the validator too. It is a `pcall`-guarded call in the bootstrap, so a missing validator is just a skipped validation. |
| **Shared** `ReplicatedStorage.Utility.Validation` | `SettingsService` uses `Validation.LivePlayer`. | No — non-deferred. Pulls in `osyrisrblx/t` and `Types/RarityType`. |
| **Shared** `ReplicatedStorage.Utility.StudioTestMode` | The Studio test-id gate; seeded from `Systems.Debug.AllowStudioTestUserIds` at boot. | Yes — but `Validation` requires it transitively, so it comes along anyway. |
| **Shared** `ReplicatedStorage.Utility.Remotes` | `SettingsService` uses `SaveSettings` / `SettingsState`. | No — non-deferred. |
| **Shared** `ReplicatedStorage.Utility.AudioGroups` | The sound-group hierarchy. Used by the bootstrap, not by this system's own modules. | Yes. |
| **Shared** `ReplicatedStorage.Utility.WeightedDraw` | The weighted draw the luck spec uses. Not required by this system's code. | Yes — but needed to run `ServerLuckService.spec.lua` as written. |
| **Shared** `ReplicatedStorage.Utility.BigNumber` | `Validation` depends on it (`Validation.BigNumberString` delegates to `BigNumber.isValid`). | Transitive. |
| **Creatures** `ReplicatedStorage.Config.Creatures.Rarity` | `ServerLuckService` reads `LuckExponentDivisor`; `Config.Presentation.UI` reads `RarityColor`. | No — non-deferred in both. |
| **Events** `ReplicatedStorage.Config.World.Events` | `ServerLuckService` reads `Events.LuckPoolOrder` — **the design pool order for the luck tiers**. | No — non-deferred, and read at module scope. |
| **PlayerData** `ServerScriptService.PlayerService` | `SettingsService` reads and writes `profile.Data.Settings`. | No — non-deferred, and `script.Parent` means it must be a direct child of `ServerScriptService`. |
| **Egg** `ServerScriptService.EggService` | **`EggService.Init()` is what calls `ServerLuckService.Init()`.** The bootstrap never does. | **Effectively yes** — but without it, install `ServerLuckService` standalone and call `Init()` yourself, or the `ServerLuck` attribute never appears. |
| **Egg / Animals** `ServerScriptService.Egg.EggOverhead`, `ServerScriptService.Animal.AnimalOverhead` | Consumers of `MutationIcon.PaintIcon`. | Yes — they are consumers, not dependencies. |
| **Economy / Rewards** `IncomeService`, `CodesService`, `DailyRewardsService`, `PlaytimeRewardsService` | Consumers of `MoneyIcon.Resolve()`. | Yes — consumers, not dependencies. |
| **Animals** `ServerScriptService.Animal.WalkController`, `ServerScriptService.Egg.FlightController` | Consumers of `PathfindingUtil`. | Yes — consumers, not dependencies. |
| **Shop** `ServerScriptService.Shop.ShopService` | The consumer that calls `ActivateBoost` and subscribes to `OnBoostExpired`. | Yes — consumer. |
| **Admin** `ServerScriptService.Cmdr/Server/Commands/luckServer.lua` | The consumer that calls `SetLuck` / `ResetLuck`. | Yes — consumer. |

### The cross-system coupling that surprises people

```lua
-- ServerScriptService/ServerLuckService.lua:31
local Events = require(ReplicatedStorage.Config.World.Events)
...
local LUCK_POOL: { string } = Events.LuckPoolOrder
```

The **luck pool order** — the design tier order that decides how much
each rarity is favoured by luck — lives in the **Events** system's
config (`ReplicatedStorage/Config/World/Events.lua:554`), not in
`Rarity.lua` where it would naturally belong.

Consequences:
- Deleting the Events system breaks `ServerLuckService` with a require
  error.
- Editing `Events.LuckPoolOrder` changes the luck roll for every egg
  in the game.
- The order is **deliberately different** from `Rarity.Order`, which
  canonically sorts Mythic *below* Legendary. The luck pool favours
  Mythic most, so Mythic must keep the **highest** tier index or the
  whole curve inverts.
- The central validator has a JOIN rule that checks every
  `Events.LuckPoolOrder` entry is a real `Rarity.Order` tier:
  `'JOIN Events.LuckPoolOrder[i] (<tier>) is not a Rarity.Order tier'`.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `SaveSettings` | **C → S** | `{ Bgm?: number, Sfx?: number, FastMode?: boolean }` — all optional. A non-table payload is ignored. The server sanitizes and clamps (`Bgm`/`Sfx` to `[0, 1]`, `FastMode` to a strict boolean) before writing `profile.Data.Settings`. |
| `SettingsState` | **S → C** | `{ Bgm, Sfx, FastMode }` — the sanitized settings, always all three fields present. Pushed on player load (`bootstrap.server.lua:974`, `pcall`-wrapped) and by `SettingsService.PushSettings(player)`. |

**No other remotes.** In particular:

- `ServerLuckService` adds **no remote**. It publishes the
  `ServerLuck` ReplicatedStorage **attribute** instead.
- `MoneyIcon`, `MutationIcon`, `PathfindingUtil` and `WaterHazard`
  add no remotes.

### The `ServerLuck` attribute

| Attribute | Written by | Read by |
|---|---|---|
| `ServerLuck` | `ServerLuckService._publish()` — on every `SetLuck`, every `ActivateBoost`, every boost expiry, and once at `Init`. | The client (`StarterPlayer/StarterPlayerScripts/ServerLuckController.lua`) reads it and watches `GetAttributeChangedSignal`. |

It is the **only** client-facing channel for luck. `GetLuck()` is the
only thing server code may read.

---

## Profile Fields

| Field | Read | Written | By |
|---|---|---|---|
| `Data.Settings` | `SettingsService.GetSettings(userId)` | `SettingsService` (on the `SaveSettings` remote) | `SettingsService` |

Shape: `{ Bgm: number, Sfx: number, FastMode: boolean }`, with
`Bgm`/`Sfx` clamped to `[0, 1]` and `FastMode` strictly boolean. The
shape **default** lives in `PlayerService`, not in `SettingsService`.

Nothing else in this system touches profile data. `ServerLuckService`
is explicitly **not** persisted (no profiles, no DataStores) — it is
global runtime state.

---

## DataStore

**None.** This system reads and writes no DataStore directly. The
`Settings` preferences ride on the player profile, which is owned by
the `PlayerData` system (ProfileService).

---

## Studio Assets

| Path | What it is | Required? |
|---|---|---|
| `ServerStorage.Assets.Decals.MoneyIcon` | An `ImageLabel` with a populated `Image`. The HUD cash-pooling icon. | **No** — a missing or unpopulated one produces a single warning and the client falls back to a `"$"` chip. |
| `ReplicatedStorage.Assets.Decals.MoneyIcon` | The same, as a **fallback** — `ServerStorage` is checked first. | No. |
| `ServerStorage.Assets.Decals.GalaxyIcon` | An `ImageLabel` for the `Galactic` mutation. | No — the overhead keeps the prototype's authored visuals. |
| `ServerStorage.Assets.Decals.SnowfallIcon` | An `ImageLabel` for the `Frost` mutation. | No. |
| `ReplicatedStorage.Assets.Decals.*` | The same, as a fallback. | No. |
| `Workspace.Water` | A `BasePart`, or a `Model`/`Folder` of `BasePart`s. Anything with a `Humanoid` that touches it dies. | **No** — a missing one warns and arms a `ChildAdded` retry. |

**Icon contract (both resolvers):** the node must be an **`ImageLabel`**
and its `Image` must be a **non-empty string**. Anything else is
treated as missing. `ServerStorage` is searched **first**.

`MoneyIcon` additionally reads these `ImageLabel` properties into the
payload it returns: `ImageRectOffset`, `ImageRectSize`, `ScaleType`,
`SliceCenter`, `SliceScale`, `ImageColor3`, `ImageTransparency`,
`BackgroundTransparency`. Each is individually `pcall`-guarded.

---

## External APIs

**None.** No HTTP requests, no webhooks, no third-party services, no
credentials of any kind.

There are **no API keys, tokens, webhook URLs or credentials** in this
system, and none are needed. Every asset is Studio-authored and every
dependency is either a Roblox built-in service or a Wally package.

---

## Initialization Order

### The five config domains

The config modules are pure data — they are `require`d on demand and
have no `Init()`. The only ordering requirement is that the
`ConfigValidator` must be able to `require` them all at boot.

### The server-side sequence (from `bootstrap.server.lua`)

| Step | Line | Action |
|---|---|---|
| 1 | `:29` | `require(ReplicatedStorage.Config.Systems.Debug)`. |
| 2 | `:31-36` | `require` the shared utilities: `ConfigValidator`, `Remotes`, `Debug`, `Validation`, `StudioTestMode`, `AudioGroups`. |
| 3 | `:30` | `require(ReplicatedStorage.Config.World.Movement)` — its `.Player` sub-table is used at `:30`. |
| 4 | **`:39`** | **`Debug.SyncFromDebugConfig(DebugConfig)`** — the server's debug switches go live. **Everything after this point can log.** |
| 5 | `:44-57` | If `DebugConfig.ConfigValidation == true`, `ConfigValidator.AssertValid()` runs inside a `pcall`. In **Studio** the error is re-raised (hard fail); on a **live server** it is a `warn` only. |
| 6 | `:63` | `StudioTestMode.Enabled = DebugConfig.AllowStudioTestUserIds == true`. |
| 7 | `:85` | `require(script.Parent.SettingsService)`. |
| 8 | `:295-296` | `require(script.Parent.Utility.WaterHazard)` then `WaterHazard.Init()`. |
| 9 | `:416` | `SettingsService.Init()` — connects the `SaveSettings` remote (waits up to 10 s for it). |
| 10 | `:974` | `pcall(SettingsService.PushSettings, player)` in the player-added path. |
| 11 | (EggService) | `ServerLuckService.Init()` is called from **`EggService.Init`** (`EggService.lua:126`), **not** from the bootstrap. `EggService` also `require`s it at `EggService.lua:63`. |

**`MoneyIcon`, `MutationIcon` and `PathfindingUtil` have no `Init`.**
They are pure resolvers/helpers, required on demand. `MoneyIcon` and
`MutationIcon` read their assets fresh on **every** call, so there is
nothing to warm up.

**`WaterHazard.Init()`** must run after the Workspace exists — which
is always true in a server script. It is placed at `:296`, right
after `StandPresentation.Init()`, as a leaf service.

**`ServerLuckService.Init()`** must run **before the first egg roll**.
Because it lives in `EggService.Init`, that is automatic in the source
game. If you install it standalone, call `Init()` yourself before any
roll — the `ServerLuck` attribute must exist for late joiners and the
first roll.

### The client side

The client bootstrap calls `Debug.SyncFromDebugConfig(DebugConfig)` on
its own side. `ClientDebug` and `ClientDebug`'s tag whitelist are
completely independent of the server's.

---

## Third-party packages (Wally)

The system itself requires no package directly, but its **shared
dependency** `ReplicatedStorage.Utility.Validation` does:

```lua
local t = require(script.Parent.Parent.Packages.t)
```

That is `osyrisrblx/t` — the Roact-style type-checking library. The
source game's `wally.toml` pins it:

```toml
[dependencies]
t = "osyrisrblx/t@^2.2.1"
```

Rojo maps `Packages/` to `ReplicatedStorage.Packages`, so the
`require` resolves.

For the full test suite, also install **TestEZ**
(`roblox/testez@^0.4.0`, a dev-dependency).

The system itself uses no other package: no ProfileService (it does
not touch profiles directly), no Cmdr, no Janitor, no Fusion, no
Promise, no Signal, no TopbarPlus.
