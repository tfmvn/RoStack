# Animals — Dependencies

Exact module requires, cross-system dependencies, remotes, profile
fields, Studio assets and the initialization order. See
[README.md](README.md) for the overview and [API.md](API.md) for the
function surface.

---

## Module Requires

### `ServerScriptService/AnimalService.lua`

```lua
local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local AnimalStats = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local EggType = require(script.Parent.Parent.ReplicatedStorage.Types.EggType)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local SlotMath = require(script.Parent.Animal.SlotMath)
local LevelUpPresentation = require(script.Parent.Animal.LevelUpPresentation)
local AnimalOverhead = require(script.Parent.Animal.AnimalOverhead)
local AnimalWeight = require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalWeight)
local OwnedObjectIdentity = require(script.Parent.Parent.ReplicatedStorage.Utility.OwnedObjectIdentity)
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
local CarryController = require(script.Parent.Animal.CarryController)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
local ArenaService = require(script.Parent.Arena.ArenaService)
local TraitService = require(script.Parent.TraitService)
local SlotActionHandler = require(script.Parent.Action.SlotActionHandler)
local NotificationService = require(script.Parent.Base.NotificationService)
local TutorialSignals = require(script.Parent.Tutorial.TutorialSignals)
local FunnelService = require(script.Parent.FunnelService)
```

Plus two **lazy** requires:

```lua
-- inside AnimalService._walkTo, at runtime:
local WalkController = require(script.Parent.Animal.WalkController)

-- inside AnimalService.CleanupPlayer, at runtime:
pcall(require, script.Parent.Steal.StealService)
```

`WalkController` is required lazily so the module graph stays acyclic
(`WalkController` requires `Animal.SlotMath`, which is a sibling of
`AnimalService`). `StealService` is required lazily because
`StealService` top-requires `AnimalService` — a top-level require would
be a cycle.

### `ServerScriptService/Animal/AnimalOverhead.lua`

```lua
local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local LevelConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local MutationConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local OverheadConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.UI).Overhead
local AnimalStats = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MutationIcon = require(script.Parent.Parent.Parent.ServerScriptService.Utility.MutationIcon)
```

### `ServerScriptService/Animal/CarryController.lua`

```lua
local PromptConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService/Animal/CarryPrompts.lua`

```lua
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService/Animal/LevelUpPresentation.lua`

```lua
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local Remotes = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)
local SlotMath = require(script.Parent.SlotMath)
local StandPresentation = require(script.Parent.Parent.StandPresentation)
```

### `ServerScriptService/Animal/WalkController.lua`

```lua
local PathfindingUtil = require(script.Parent.Parent.Utility.PathfindingUtil)
local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local SlotMath = require(script.Parent.SlotMath)
```

### `ReplicatedStorage/Config/Creatures/Animals.lua`

```lua
local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)
local RarityDefs = require(script.Parent.Rarity)
local SlotType = require(script.Parent.Parent.Parent.Types.SlotType)
local Prompts = require(script.Parent.Parent.World.Prompts)
```

> **Note the mixed require styles.** `Animals.lua` uses the relative
> `script.Parent...` form; `CarryPrompts.lua` uses the absolute
> `ReplicatedStorage....` form. Both work; both must resolve to the
> same instance.

### Shared modules (in `ReusableSystems/Shared/`)

| Module | Require path in the source |
|---|---|
| `AnimalStats` | `script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats` |
| `AnimalWeight` | `script.Parent.Parent.ReplicatedStorage.Utility.AnimalWeight` |
| `StatCalculator` | `script.Parent.StatCalculator` (from `AnimalStats` / `AnimalWeight`) |
| `OwnedObjectIdentity` | `script.Parent.Parent.ReplicatedStorage.Utility.OwnedObjectIdentity` |
| `Debug` | `script.Parent.Parent.ReplicatedStorage.Utility.Debug` |
| `Validation` | `script.Parent.Parent.ReplicatedStorage.Utility.Validation` |
| `Remotes` | `script.Parent.Parent.ReplicatedStorage.Utility.Remotes` |
| `BigNumber` | `script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber` |

`Shared/CommonModules/*` and `Shared/Utilities/*` **both** map to
`ReplicatedStorage.Utility`. `Shared/Types/*` maps to
`ReplicatedStorage.Types`.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **MutationsAndTraits** | `TraitService` (the inheritance roll), `Config.Creatures.Traits` and `Config.Creatures.Mutations` (the generation folds), `Config.Creatures.Rarity` (the rarity colours + `BaseLevel`, required by `Animals.lua` itself). | **No.** `Animals.lua` hard-requires `Config.Creatures.Rarity`. |
| **Upgrades** | `Config.Creatures.Progression` — the level curve, `MaxLevel`, `Normalize`, `GetPointsForLevel`. | **No.** |
| **Carry** | `Config.World.Prompts` (the prompt text, the carry distance, the head clearance), `Carry.CarryRegistry` (the authoritative carry state). | **No.** |
| **Inventory** | `Animal.SlotMath` (`FeetOffsetBelowPrimary`, `StandingCFrameOnSlot`), `Action.SlotActionHandler` (the prompt router). | **No.** |
| **BasesAndSlots** | `BaseService` and `SlotService` — the base, the slot state machine, `OccupySlot` / `ReserveSlot` / `DemoteSlotToReserved`. Injected via `Set*Service`. Also `StandPresentation` (required by `LevelUpPresentation`). | **No.** (injection) |
| **EggsAndHatching** | `EggService` — `RefundHatch` (the refund on a failed hatch), `SpawnFromPersistence`'s egg counterpart. Injected via `SetEggService`. | **No.** (injection) |
| **PlayerData** | `PlayerService` — `ConsumeEggIntoAnimal`, `AddAnimal`, `RemoveAnimal`, `GetPlayerData`, `PushState`, `BumpStat`. Injected via `SetPlayerService`. | **No.** (injection) |
| **Arena** | `ArenaService.IsAnimalRaidLocked(animalId)` — the raid lock. Required at module scope. | **No.** |
| **Stealing** | `Steal.StealService` — `RollbackIfStealing`, `RollbackStolenTarget`. **Lazily required.** | **Yes** (only the steal path needs it). |
| **Notifications** | `Base.NotificationService.NotifySuccess` — the `Pickup_Success` / `Place_Success` / `Arrival_Success` toasts. | **Yes** (pcall-guarded). |
| **Tutorials** | `Tutorial.TutorialSignals.Fire` — the `AnimalPickedUp` signal. | **Yes** (pcall-guarded). |
| **Analytics** | `FunnelService` — the funnel events. | **Yes** (a leaf module, never gameplay-critical). |
| **SharedUtilities** | `Config.World.Movement` (the walk tuning), `Config.Presentation.UI` (the overhead config), `Config.Presentation.Vfx` (the bop phases + the upgrade VFX), `Config.Systems.Debug`, `ServerScriptService.Utility.PathfindingUtil`, `ServerScriptService.Utility.MutationIcon`. | **No.** |

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `AnimalArrived` | S -> C | `{ BaseId, SlotId, Type, DisplayName, Rarity, Level, Health, Damage }` — fired once, on arrival at the slot, to the **owner**. `Type` is the `definitionId`. `Health` / `Damage` come from `AnimalStats.Snapshot` (the derived values). |
| `AnimalCarried` | S -> C | `{ UniqueId, DefinitionId, DisplayName, Rarity }` — fired to the **carrier** on a successful grab. |
| `AnimalPlaced` | S -> C | `{ UniqueId, SlotId }` — fired to the **carrier** on a successful place. |
| `AnimalLeveledUp` | S -> C | `{ AnimalId, SlotId, OldLevel, NewLevel, LevelsGained }` — fired to the **owner only**, on a real level change. `OldLevel` may be `nil` if the level was unknown. |

All four are `RemoteEvent`s in the `ReplicatedStorage.Remotes` folder.
They are fired via `Remotes.FireClient(player, Remotes.Names.<Name>, payload)`.

**The client is display-only.** No client input is trusted for a
stat, a level, or an id.

---

## Profile Schema

The animal lives in `profile.Data.Brainrots` — an append/remove list
whose ordering is not significant.

```lua
profile.Data.Brainrots = {
    {
        Type     = 'Brainrot',   -- the literal string, always
        SlotId   = 'p7:1:animal:3',
        DefId    = 'Chicken',
        Id       = 'AN_a1B2c3D4e5',  -- the persistence key
        Level    = 1,
        XP       = 0,               -- CURRENT progress, not lifetime
        CashPool = '0',             -- BigNumber decimal string
        Trait    = 'Gold',          -- string | nil (nil = no trait)
        Mutations = { 'Galactic' }, -- unique array, sanitised
    },
}
```

### Fields read

| Field | Read by | Purpose |
|---|---|---|
| `Id` | `SpawnFromPersistence` | The runtime id. A missing/invalid `AN_` id is **minted and written back**. |
| `DefId` | `SpawnFromPersistence`, `AnimalStats`, `AnimalWeight` | The catalog lookup key. |
| `SlotId` | `SpawnFromPersistence` | Where the animal is seated on rejoin. |
| `Level` | `AnimalStats`, `AnimalWeight`, `AddXP` | **The only progression state.** |
| `XP` | `AddXP` | The current progress. |
| `Trait` | `AnimalStats` (the Income fold), `AnimalOverhead`, `GetTemplate` | The trait id. `nil` = no trait. |
| `Mutations` | `AnimalStats` (the Income fold), `AnimalOverhead` | The mutation ids. |
| `CashPool` | the Income / Sell services | The uncollected cash riding with the animal. |

### Fields written

| Field | Written by |
|---|---|
| `Id`, `SlotId`, `DefId`, `Level`, `XP`, `Trait`, `Mutations` | `PlayerService.AddAnimal` / `PlayerService.ConsumeEggIntoAnimal` |
| `Level`, `XP` | `AnimalService.AddXP` (the profile record is synced after `LevelConfig.Normalize`) |
| `Level` | `AnimalService.ApplyLevelUpgrade` |
| the whole row | `PlayerService.RemoveAnimal` (from `ForceReleaseBase` only) |

**`CleanupPlayer` does NOT write.** It destroys the runtime model and
drops the registry entry, but the persisted row survives so the rejoin
can re-spawn it. Only `ForceReleaseBase` (an admin wipe) removes the
row.

### What is NOT in the profile

**Health, Damage, Income, Weight and Scale are never persisted.** They
are derived from `Level` + the definition + the config on every read.

---

## DataStore

`profile.Data.Brainrots` is saved by ProfileService (the vendored copy
lives at `src/Vendored/ProfileService.lua` in the source game; it is
**not** part of this library). The animal system's own lifecycle
contributes only the fields above — it never calls
`ProfileService:Update` directly. `PlayerService` owns the save
lifecycle; the animal system only mutates the row in place so
ProfileService's existing save picks it up.

---

## Initialization Order

```text
1. ReplicatedStorage.Utility.*  and  ReplicatedStorage.Types.*
2. ReplicatedStorage.Config.*
3. ServerScriptService.Utility.*  (PathfindingUtil, MutationIcon)
4. ServerScriptService.Animal.*  (WalkController, CarryController,
                                CarryPrompts, LevelUpPresentation,
                                AnimalOverhead)
5. ServerScriptService.AnimalService
6. AnimalService.SetPlayerService(PlayerService)
   AnimalService.SetBaseService(BaseService)
   AnimalService.SetEggService(EggService)
   AnimalService.SetSlotService(SlotService)
   AnimalService.SetModifierService(ModifierService)
7. AnimalService.Init()
```

`Init()` creates `Workspace.Animals`, runs the one-shot asset audit,
installs the weight provider, and wires the **Pickup** and **Place**
prompt callbacks. The callbacks route through `SlotActionHandler`, so
the services it needs must already be wired.

**All five `Set*Service` calls must come before `Init()`.** An unwired
ref degrades safely (`ModifierService` -> 1x XP; `SlotService` -> the
slot cannot be resolved -> `'slot-not-found'`), but the carry and walk
paths will not work.

---

## Studio Assets

### `ServerStorage.Animals.<Trait>.<Rarity>.<DefId>` — **REQUIRED**

The species models. The **`<DefId>` node IS the species `Model`** — not
a folder containing one.

- The `<Trait>` folder is one of `Normal`, `Gold`, `Diamond`, `Rainbow`
  (the trait ids, mapped by `ResolveTraitFolder`; `nil` and `''` both
  mean `Normal`).
- The `<Rarity>` folder is one of the eight rarity ids.
- Every model **must** have a `HumanoidRootPart` (it becomes the
  `PrimaryPart`). A model without one fails the hatch with
  `template-no-humanoidrootpart` and the egg is refunded.
- Every catalog species needs a `Normal` variant. A missing `Normal`
  variant breaks **all** spawns of that species. A missing trait variant
  degrades to `Normal` with a warning.

The legacy flat shape `ServerStorage.Animals.<Rarity>.<DefId>` is also
supported (defId-preferred, then any model) so an old Studio layout
keeps working during migration.

**There is no procedural fallback for animals.** Unlike eggs, a missing
template is a hard failure with a refund — not a silent downgrade.

### `ServerStorage.Assets.OverheadGui.OverheadGuiTemplate` — **REQUIRED**

A `BillboardGui` template with a `Container.Content` hierarchy:

- `Name`, `Level`, `Income`, `Rarity`, `Trait`
- `Stats.Health.Value`, `Stats.Damage.Value`
- `Mutations` — a container holding a **`Mutation1` prototype**. One
  clone is made per mutation id and painted by `MutationIcon.PaintIcon`.
- `Data` — a folder with `NumberValue`s named `Damage`, `Health`,
  `MaxHealth`.

The clone is parented under the model's `CENTER` part (or the
`PrimaryPart`) and named `OverheadGui`.

### `ServerStorage.Assets.Vfx.Upgrade` — optional

The level-up burst. An `Attachment` with a `ParticleEmitter` (plus
optionally a `Sound`). The clone's `Attachment` is re-homed under the
model's `PrimaryPart`. **Any embedded `Sound` is destroyed unplayed** —
it would be audible server-wide. The personal level-up sting plays on
the owning client via the `AnimalLeveledUp` remote.

### `Workspace.Bases.Base_<i>` — owned by the BasesAndSlots system

Not authored by this system, but required for the walk and the carry:
the base's **stand** parts (the animals are seated under
`slot.stand`) and the **Collector** parts (the egg lands there).

---

## External APIs

**None.** This system uses no API keys, tokens, webhook URLs or
credentials. It makes no HTTP calls, no Marketplace calls and no
DataStore calls of its own.

If you extend it to call a third-party service, use a **placeholder**
in the repo and supply the real value at runtime through a Roblox
`HttpService` HTTP header or a Studio-only local module — **never a
literal in the source**.
