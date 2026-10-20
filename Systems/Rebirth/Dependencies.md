# Rebirth — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Rebirth/RebirthService.lua`

```lua
-- Shared
require(game:GetService('ReplicatedStorage').Utility.Validation)
require(game:GetService('ReplicatedStorage').Utility.Remotes)
require(game:GetService('ReplicatedStorage').Utility.Debug)
require(game:GetService('ReplicatedStorage').Utility.BigNumber)
require(game:GetService('ReplicatedStorage').Config.Economy.Rebirth)
require(game:GetService('ReplicatedStorage').Utility.RebirthUnlocks)
require(game:GetService('ReplicatedStorage').Config.Creatures.Animals)
require(game:GetService('ReplicatedStorage').Types.SlotType)

-- Server services (DIRECT requires -- not injected)
require(script.Parent.Parent.PlayerService)
require(script.Parent.Parent.AnimalService)
require(script.Parent.Parent.BaseService)
require(script.Parent.Parent.Base.SlotService)
require(script.Parent.Parent.Arena.ArenaProgressionService)
require(script.Parent.Parent.ModifierService)
require(script.Parent.Parent.Carry.CarryRegistry)
require(script.Parent.Parent.Arena.ArenaService)
require(script.Parent.Parent.Steal.StealService)
require(script.Parent.Parent.EggService)
require(script.Parent.Parent.FunnelService)
require(script.Parent.Parent.PlayerLogger.PlayerLogger)
```

Lazy, inside the function body:

```lua
require(script.Parent.Parent.Base.DynamicSlotService)  -- resolveStandTemplate
require(script.Parent.Parent.Leaderboard.LeaderboardService)  -- MarkDirty
require(script.Parent.Parent.TabList.TabListService)        -- MarkDirty
```

All three lazy requires are `pcall`-guarded at the call site.

### `ReplicatedStorage/Config/Economy/Rebirth.lua`

No requires.

### `ReplicatedStorage/Utility/RebirthUnlocks.lua` (shared)

```lua
require(script.Parent.Parent.Config.Economy.Rebirth)
require(script.Parent.Parent.Config.Economy.Gear)
require(script.Parent.Parent.Config.Presentation.UI).Overhead
```

---

## Other Systems Required

`RebirthService` resolves all of these by **direct require at load
time**. There are no `Set*Service()` setters. The list below is
therefore also the require order in your bootstrap.

| System | Module | Why | Optional? |
|---|---|---|---|
| **PlayerData** | `ServerScriptService.PlayerService` | `GetPlayerData`, `AssignBase`, `GetBaseId`, `RemoveAnimal`, `PushState`. Owns `profile.Data.Rebirth`. | **Required** |
| **Animals** | `ServerScriptService.AnimalService` | `ListForPlayer` (the raid-lock sweep), `DestroyRuntimeAnimal`, `GetTemplate` (the preview clones). | **Required** |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `GetBaseByOwner`, `ReleasePlayerBase`, `AssignBaseById`, `AssignBaseForPlayer`, `PointPlayerToBaseSpawn`, `Snapshot`. | **Required** |
| **Inventory** | `ServerScriptService.Base.SlotService` | `FindSlotByOccupant`, `ReleaseSlot`, `_findSlotById` (the egg-record check). | **Required** |
| **Arena** | `ServerScriptService.Arena.ArenaProgressionService` | `GetArenaLevel` (the requirement), `ResetArena` (the reset). | **Required** |
| **Arena** | `ServerScriptService.Arena.ArenaService` | `IsAnimalRaidLocked` — an active raid blocks the rebirth. | **Required** |
| **Economy** | `ServerScriptService.ModifierService` | `AddModifier` / `GetMoneyMultiplier` — the permanent multiplier's home. | **Required** |
| **Carry** | `ServerScriptService.Carry.CarryRegistry` | `IsCarrying` (the entry gate), `ForEach` (the post-rebirth steal check). | **Required** |
| **Stealing** | `ServerScriptService.Steal.StealService` | `RollbackIfStealing`, `RollbackStolenTarget` — the recover-then-sweep before teardown. | **Required** |
| **Eggs** | `ServerScriptService.EggService` | `ReconcileAfterBaseSwap` — re-homes egg slot ids after the base is rebuilt. | **Optional** — `pcall`-guarded. Without it, eggs may alias dead slots. |
| **Analytics** | `ServerScriptService.FunnelService` | `LogStep` for `RebirthAttempted`, `RebirthRequirementReached`, `RebirthSucceeded`, `FirstRebirth`. | **Optional** — `pcall`-guarded. |
| **Logging** | `ServerScriptService.PlayerLogger.PlayerLogger` | `LogMilestone` on a committed rebirth. | **Optional** — `pcall`-guarded. |
| **Leaderboards** | `ServerScriptService.Leaderboard.LeaderboardService` | `MarkDirty` — a rebirth moves the money-only global board. Lazy require. | **Optional** — `pcall`-guarded. |
| **SharedUtilities** | `ReplicatedStorage.Config.Creatures.Animals` | `Get` — the `displayName` and the rarity for the preview cards. | **Required** |
| **Combat** | `ReplicatedStorage.Config.Economy.Gear` | Read by `RebirthUnlocks` to derive the gear unlock rows. | **Required** (via `RebirthUnlocks`) |
| **SharedUtilities** | `ReplicatedStorage.Config.Presentation.UI` | The `Overhead.FallbackColor` / `Overhead.TraitColors.Gold` constants `RebirthUnlocks` reuses. | **Required** (via `RebirthUnlocks`) |
| **Inventory** | `ServerScriptService.Base.DynamicSlotService` | `GetTemplate` / `GetArenaTemplate` — the source of the parked `__Stand` / `__ArenaStand` preview clones. Lazy require. | **Optional** — a missing template parks nothing; the card renders text-only. |
| **Upgrades** | — | The `MinimumLevel` values in the ladder are compared against `record.Level`, which the UpgradeService owns. No require. | n/a |

**Cycle safety:** nothing in the required list requires `RebirthService`
back. The only service that reads it is `GearShopService`, which
resolves it **lazily** inside `GetPlayerRebirth` — so the require graph
stays acyclic.

**Reverse dependency (you must wire these):**

| Consumer | What it needs | How |
|---|---|---|
| `DynamicSlotService` | The player's rebirth count, to build the right number of stands | `DynamicSlotService.SetUnlockResolver(function(userId) return RebirthService.ResolveRebirthForStands(userId) end)` |
| `ModifierService` | The multiplier to be re-applied each join | Call `RebirthService.ApplySessionModifiers(userId)` in your `PlayerAdded` handler, after the profile loads. |
| `BaseService` | The `MoneyMultPart` label on the base | Author `Base/MoneyMultPart/SurfaceGui/TextLabel`. |
| `TabListService` | The rebirth count for the native leaderboard | `TabListService.SetRebirthService(RebirthService)` |

---

## Remotes

| Remote | Direction | Payload shape |
|---|---|---|
| `RebirthAction` | C→S | `{ Action: 'Rebirth' \| 'State' }`. Anything else (including a missing `Action`) is treated as `'Rebirth'`. The client never supplies a rebirth number. |
| `RebirthState` | S→C | The full GUI snapshot: `{ Current, Next?, Maxed, CanRebirth, Money?, MoneyRequired?, MoneySatisfied?, ArenaLevel?, ArenaRequired?, ArenaSatisfied?, Animals?, Unlocks?, StartingCash?, MoneyMultiplier? }`. When maxed, only `Current` / `Next=nil` / `Maxed=true` / `CanRebirth=false` are present. |
| `RebirthResult` | S→C | `{ Success: boolean, Rebirth?: number, Error?: string }`. `Error` is one of the codes in `RebirthService.RequestRebirth`. |

Remote names come from `ReplicatedStorage.Utility.Remotes` (the
`Remotes.Names` registry). The server creates the events at boot from
that registry — **do not hand-author them**.

`RebirthState` carries two live `Instance` references:
`Animals[i].TemplateModel` and `Unlocks[i].TemplateModel` are parked
clones in `ReplicatedStorage.RebirthPreviews/U<userId>/`. The client
renders them; the server never reparents or mutates the live models.

---

## Profile Fields

### Written by this system

| Field | Type | Notes |
|---|---|---|
| `Rebirth` | number (integer `>= 0`) | The completed rebirth count. Always set to `nextIndex` on a successful commit. |
| `Money` | string (BigNumber) | Written **directly** on reset (`data.Money = BigNumber.sanitize(StartingCash) or '0'`). **Bypasses `EconomyService`** — no transaction record, and the `MaxMoney` cap is not applied. |
| `Brainrots` | array | Replaced with `{}` when `Reset.Animals` is true. |

### Read by this system

| Field | Type | Notes |
|---|---|---|
| `Money` | string (BigNumber) | The money requirement check. |
| `Brainrots[]` | array | The animal requirements. `Type`, `Id`, `DefId`, `Trait`, `Level` are read. |
| `LuckyBlocks[]` | array | Read during the steal rollback sweep. **Never reset.** |
| `Multipliers` | table | The `Multipliers.Money` compat field is **not** read and **not** written by a rebirth. |

### Owned elsewhere (read here, written elsewhere)

| Field | Owner |
|---|---|
| `Stats.UpgradesApplied` | `UpgradeService` — the `Level` on each brainrot record that `MinimumLevel` is compared against. |
| `BaseId` | `PlayerService.AssignBase` / `BaseService` — re-bound during the base reset. |
| `ArenaLevel` | `ArenaProgressionService` — reset by `ArenaProgressionService.ResetArena`. |

---

## Required Studio Assets

| Asset | Path shape | Used for | If missing |
|---|---|---|---|
| Multiplier label | `Base/MoneyMultPart/SurfaceGui/TextLabel` (a `TextLabel`) | The `Mult: 1.5x` readout on the player's own base | The lookup silently skips; the label stays as authored. **Display only** — the multiplier itself is unaffected. |
| Stand template | The model `DynamicSlotService.GetTemplate()` returns | The `__Stand` preview clone in the unlock card | A warning; the card renders text-only. |
| Arena stand template | The model `DynamicSlotService.GetArenaTemplate()` returns | The `__ArenaStand` preview clone | A warning; the card renders text-only. |
| Animal templates | The models `AnimalService.GetTemplate(rarity, defId, trait)` returns | The per-requirement preview clones | A warning; the card renders text-only. |
| Base folder | `base.folder` on the BaseService record | The parent of `MoneyMultPart` | The label is not found. |

**Nothing under `ServerStorage` is read directly** — the templates come
through `AnimalService` and `DynamicSlotService`, and the *clones* are
parked in `ReplicatedStorage` so clients can see them.

**No DataStore, no Marketplace, no HTTP.** The rebirth rides
`PlayerService`'s normal profile save cycle; there is no explicit save
API call.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `Players` | Implicitly, through the `Player` argument to `RequestRebirth`. | — |
| `DataStoreService` | **Indirect only**, through `PlayerService`'s profile. | `Enable Studio Access to API Services` in Studio. |

No HTTP requests. No Marketplace calls. No `HttpService`.

The `PlayerLogger` dependency may post to an external service in a
deployment that configures it; that configuration is **outside this
library** and is not documented here. In the source game it is
`pcall`-guarded and a failure is ignored.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  RebirthService.Init()     -- wires RebirthAction ONLY; every other
                                 dependency is a direct require, so the
                                 REQUIRES themselves must already
                                 resolve at this point
3.  RebirthService.HideAllBaseMultipliers()   -- optional; at boot no
                                                 base has an owner
4.  --- players may now join ---
```

Because the service resolves its dependencies by direct `require`, the
**module load order** in your bootstrap matters. The safe order is:

```text
  PlayerService
  -> AnimalService
  -> BaseService (+ SlotService)
  -> ArenaProgressionService
  -> ModifierService
  -> CarryRegistry
  -> ArenaService
  -> StealService
  -> EggService
  -> FunnelService
  -> PlayerLogger
  -> RebirthService        <- last
```

Per-player, on `PlayerAdded` (order matters):

```text
1.  PlayerService.LoadPlayerData(player)
2.  base assign / restore
3.  RebirthService.ApplySessionModifiers(userId)   -- restores the
                                                       multiplier; MUST
                                                       be after the
                                                       profile loads
```

Per-player, on leave:

```text
1.  RebirthService.ForgetPlayer(userId)   -- busy flag, pending build,
                                             parked preview clones
```
