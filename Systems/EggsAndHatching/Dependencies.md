# EggsAndHatching — Dependencies

Exact module paths, cross-system requirements, remotes, profile fields,
and Studio assets. See [README.md](README.md) for the overview and
[API.md](API.md) for signatures.

---

## Module Requires

Verbatim from the source. The `script.Parent...` forms are relative to
each file's own Roblox location.

### `ServerScriptService.EggService`

```lua
local SpawnService = require(script.Parent.Egg.SpawnService)
local AmbientService = require(script.Parent.Egg.AmbientService)
local FlightController = require(script.Parent.Egg.FlightController)
local GuaranteeService = require(script.Parent.Egg.GuaranteeService)
local RareEggNotifier = require(script.Parent.Egg.RareEggNotifier)
local ServerLuckService = require(script.Parent.ServerLuckService)
local HoverMath = require(script.Parent.Egg.HoverMath)
local StandPresentation = require(script.Parent.StandPresentation)
local CollectorArrival = require(script.Parent.Base.CollectorArrival)
local Constants = require(script.Parent.Egg.Constants)
local Catalog = require(script.Parent.Egg.Catalog)
local CarryRegistry = require(script.Parent.Carry.CarryRegistry)
local CarryController = require(script.Parent.Animal.CarryController)
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)
local SlotActionHandler = require(script.Parent.Action.SlotActionHandler)
local EggConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local AnimalConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local PromptConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local WeightedDraw = require(script.Parent.Parent.ReplicatedStorage.Utility.WeightedDraw)
local FloorGeometry = require(script.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local RollController = require(script.Parent.Egg.RollController)
local TraitService = require(script.Parent.TraitService)
local StandResolver = require(script.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
local BigNumber = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.EconomyService)
local TutorialSignals = require(script.Parent.Tutorial.TutorialSignals)
local FunnelService = require(script.Parent.FunnelService)
local NotificationService = require(script.Parent.Base.NotificationService)
```

### `ServerScriptService.Egg.SpawnService`

```lua
local Constants = require(script.Parent.Constants)
local Catalog = require(script.Parent.Catalog)
local OwnedObjectIdentity = require(game:GetService('ReplicatedStorage').Utility.OwnedObjectIdentity)
local Placement = require(script.Parent.Placement)
local ModelBuilder = require(script.Parent.ModelBuilder)
local HoverMath = require(script.Parent.HoverMath)
local AmbientService = require(script.Parent.AmbientService)
local EggOverhead = require(script.Parent.EggOverhead)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local CarryPrompts = require(script.Parent.Parent.Animal.CarryPrompts)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local PromptConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Prompts)
local Validation = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.Parent.EconomyService)
```

### `ServerScriptService.Egg.FlightController`

```lua
local Constants = require(script.Parent.Constants)
local HoverMath = require(script.Parent.HoverMath)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local EggWalkAnimator = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local PathfindingUtil = require(script.Parent.Parent.Utility.PathfindingUtil)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)
```

### `ServerScriptService.Egg.RollController`

```lua
local Constants = require(script.Parent.Constants)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local AnimalConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local SlotMath = require(script.Parent.Parent.Animal.SlotMath)
local VfxConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Vfx)
local DebugConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local HoverMath = require(script.Parent.HoverMath)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local AudioGroups = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)
```

### `ServerScriptService.Egg.AmbientService`

```lua
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local FloorGeometry = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.FloorGeometry)
local EggWalkAnimator = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService.Egg.HoverMath`

```lua
local Constants = require(script.Parent.Constants)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
```

### `ServerScriptService.Egg.ModelBuilder`

```lua
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local Constants = require(script.Parent.Constants)
local HoverMath = require(script.Parent.HoverMath)
```

### `ServerScriptService.Egg.Placement`

```lua
local Constants = require(script.Parent.Constants)
local Security = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Security)
```

### `ServerScriptService.Egg.Catalog`

No requires (pure data + validation).

### `ServerScriptService.Egg.Constants`

```lua
local EggType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.EggType)
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local CenterSpawn = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs).CenterSpawn
local MovementConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Movement)
```

### `ServerScriptService.Egg.GuaranteeService`

```lua
local EggConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local CenterPartBillboards = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.CenterPartBillboards)
```

### `ServerScriptService.Egg.RareEggNotifier`

```lua
local Rarity = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.RarityType)
local RarityConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Rarity)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local NotificationService = require(script.Parent.Parent.Parent.ReplicatedStorage.Base.NotificationService)
local EggSpawned = require(script.Parent.EggSpawned)
```

### `ServerScriptService.Egg.EggOverhead`

```lua
local RarityConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Rarity)
local OverheadConfig = require(game:GetService('ReplicatedStorage').Config.Presentation.UI).Overhead
local MutationConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Mutations)
local EggConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Eggs)
local BigNumber = require(game:GetService('ReplicatedStorage').Utility.BigNumber)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local MutationIcon = require(script.Parent.Parent.Utility.MutationIcon)
```

### `ServerScriptService.Egg.EggSpawned`

```lua
local Signals = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Signals)
```

### `ReplicatedStorage.Config.Creatures.Eggs`

```lua
local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)
local RarityDefs = require(script.Parent.Rarity)
```

### Resolved absolute paths

| Module | Absolute Roblox path | From library |
|---|---|---|
| `EggConfig` | `ReplicatedStorage.Config.Creatures.Eggs` | **this system** |
| `AnimalConfig` | `ReplicatedStorage.Config.Creatures.Animals` | **Animals** system |
| `RarityDefs` | `ReplicatedStorage.Config.Creatures.Rarity` | **MutationsAndTraits** system |
| `MutationConfig` | `ReplicatedStorage.Config.Creatures.Mutations` | **MutationsAndTraits** system |
| `PromptConfig` | `ReplicatedStorage.Config.World.Prompts` | **Carry** system |
| `MovementConfig` | `ReplicatedStorage.Config.World.Movement` | **SharedUtilities** system |
| `VfxConfig` | `ReplicatedStorage.Config.Presentation.Vfx` | **SharedUtilities** system |
| `OverheadConfig` | `ReplicatedStorage.Config.Presentation.UI` | **SharedUtilities** system |
| `DebugConfig` | `ReplicatedStorage.Config.Systems.Debug` | **SharedUtilities** system |
| `Security` | `ReplicatedStorage.Config.Systems.Security` | **AdminTools** system |
| `SlotType` | `ReplicatedStorage.Types.SlotType` | `Shared/Types/SlotType.lua` |
| `EggType` | `ReplicatedStorage.Types.EggType` | `Shared/Types/EggType.lua` |
| `Rarity` | `ReplicatedStorage.Types.RarityType` | `Shared/Types/RarityType.lua` |
| `TransactionReason` | `ReplicatedStorage.Types.TransactionReason` | `Shared/Types/TransactionReason.lua` |
| `Validation` | `ReplicatedStorage.Utility.Validation` | `Shared/Utilities/Validation.lua` |
| `Debug` | `ReplicatedStorage.Utility.Debug` | `Shared/Utilities/Debug.lua` |
| `BigNumber` | `ReplicatedStorage.Utility.BigNumber` | `Shared/Utilities/BigNumber.lua` |
| `WeightedDraw` | `ReplicatedStorage.Utility.WeightedDraw` | `Shared/Utilities/WeightedDraw.lua` |
| `Signals` | `ReplicatedStorage.Utility.Signals` | `Shared/Utilities/Signals.lua` |
| `AudioGroups` | `ReplicatedStorage.Utility.AudioGroups` | `Shared/Utilities/AudioGroups.lua` |
| `FloorGeometry` | `ReplicatedStorage.Utility.FloorGeometry` | `Shared/CommonModules/FloorGeometry.lua` |
| `EggWalkAnimator` | `ReplicatedStorage.Utility.EggWalkAnimator` | `Shared/CommonModules/EggWalkAnimator.lua` |
| `StandResolver` | `ReplicatedStorage.Utility.StandResolver` | `Shared/CommonModules/StandResolver.lua` |
| `CenterPartBillboards` | `ReplicatedStorage.Utility.CenterPartBillboards` | `Shared/CommonModules/CenterPartBillboards.lua` |
| `OwnedObjectIdentity` | `ReplicatedStorage.Utility.OwnedObjectIdentity` | `Shared/CommonModules/OwnedObjectIdentity.lua` |
| `Remotes` | `ReplicatedStorage.Utility.Remotes` | `Shared/CommonModules/Remotes.lua` |
| `TraitService` | `ServerScriptService.TraitService` | **MutationsAndTraits** system |
| `EconomyService` | `ServerScriptService.EconomyService` | **Economy** system |
| `ServerLuckService` | `ServerScriptService.ServerLuckService` | **SharedUtilities** system |
| `PathfindingUtil` | `ServerScriptService.Utility.PathfindingUtil` | **SharedUtilities** system |
| `MutationIcon` | `ServerScriptService.Utility.MutationIcon` | **SharedUtilities** system |
| `SlotMath` | `ServerScriptService.Animal.SlotMath` | **Inventory** system |
| `CarryPrompts` | `ServerScriptService.Animal.CarryPrompts` | **Animals** system |
| `CarryController` | `ServerScriptService.Animal.CarryController` | **Animals** system |
| `CarryRegistry` | `ServerScriptService.Carry.CarryRegistry` | **Carry** system |
| `SlotActionHandler` | `ServerScriptService.Action.SlotActionHandler` | **Inventory** system |
| `CollectorArrival` | `ServerScriptService.Base.CollectorArrival` | **Collectors** system |
| `StandPresentation` | `ServerScriptService.StandPresentation` | **BasesAndSlots** system |
| `NotificationService` | `ServerScriptService.Base.NotificationService` | **Notifications** system |
| `TutorialSignals` | `ServerScriptService.Tutorial.TutorialSignals` | **Tutorials** system |
| `FunnelService` | `ServerScriptService.FunnelService` | **Analytics** system |

**`Shared/CommonModules/*` and `Shared/Utilities/*` both map to
`ReplicatedStorage.Utility.*`.** `Shared/Types/*` maps to
`ReplicatedStorage.Types.*`.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **(this system)** `Shared/CommonModules/FloorGeometry.lua` | All the floor math: `GetWorldTopY`, `GetPivotGroundOffset`, `ClampToSurface`. | **Required** — the centre floor height is wrong without it. |
| **(this system)** `Shared/CommonModules/EggWalkAnimator.lua` | The shared walk cycle, used by BOTH the ambient wander and the purchased-egg flight. | **Required** |
| **(this system)** `Shared/CommonModules/StandResolver.lua` | `GetSlotFacingRotation` for the hover/grounded CFrames. | **Required** |
| **(this system)** `Shared/CommonModules/OwnedObjectIdentity.lua` | Mints the `EG_`-prefixed unique ids. | **Required** |
| **(this system)** `Shared/CommonModules/Remotes.lua` | The `EggArrived` / `EggCarried` / `EggPlaced` channels. | **Required** |
| **(this system)** `Shared/CommonModules/CenterPartBillboards.lua` | Resolves the guarantee-timer UI node. | Optional — a missing asset degrades to a one-shot warn. |
| **(this system)** `Shared/Utilities/WeightedDraw.lua` | The weighted centre-spawn rarity pick. | **Required** |
| **(this system)** `Shared/Utilities/Validation.lua` | `ShortString` validation of the unique ids. | **Required** |
| **(this system)** `Shared/Utilities/BigNumber.lua` | The exact price formatting. | **Required** |
| **(this system)** `Shared/Utilities/Signals.lua` | The `EggSpawned` event bus. | **Required** |
| **(this system)** `Shared/Utilities/AudioGroups.lua` | Assigns the roll sounds to their SoundGroups. | Optional — a missing group degrades silently. |
| **(this system)** `Shared/Utilities/Debug.lua` | Logging. | **Required** |
| **(this system)** `Shared/Types/EggType.lua` | The five lifecycle states. | **Required** |
| **(this system)** `Shared/Types/SlotType.lua` | The slot id encoding and the `OccupantKind`. | **Required** |
| **(this system)** `Shared/Types/TransactionReason.lua` | `EggPurchase`, `EggRefund`. | **Required** |
| **MutationsAndTraits** | `Config.Creatures.Rarity` (the rarity table), `Config.Creatures.Mutations` (the mutation ids the overhead renders), and `ServerScriptService.TraitService` (the hatch inheritance). | **Required** — the config require breaks without `Rarity.lua`. |
| **Animals** | `Config.Creatures.Animals` (the hatch-roll target catalog), `ServerScriptService.Animal.CarryPrompts` (the prompt installer), `ServerScriptService.Animal.CarryController` (the carry rig), and `ServerScriptService.AnimalService` (the `CreateFromEgg` the hatch calls). | **Required** |
| **Inventory** | `ServerScriptService.Animal.SlotMath` (the feet offset for the roulette previews) and `ServerScriptService.Action.SlotActionHandler` (the Hatch / Pickup prompt routing). | **Required** |
| **Carry** | `Config.World.Prompts` (the carry distance, hold duration, and prompt text) and `ServerScriptService.Carry.CarryRegistry` (the carry state). | **Required** |
| **BasesAndSlots** | `ServerScriptService.StandPresentation` (the stand wobble binding). | **Required** |
| **Collectors** | `ServerScriptService.Base.CollectorArrival` — **resolves the landing slot on arrival.** Without it, the egg arrives and nothing is seated. | **Required for the flight to complete.** |
| **Economy** | `ServerScriptService.EconomyService` — the purchase debit and the refund. | **Required** |
| **SharedUtilities** | `Config.World.Movement` (the flight agent params), `Config.Presentation.Vfx` (the rarity explosion), `Config.Presentation.UI` (the overhead config), `Config.Systems.Debug`, `ServerScriptService.ServerLuckService` (the luck-weighted centre roll), `ServerScriptService.Utility.PathfindingUtil`, `ServerScriptService.Utility.MutationIcon`. | **Required** |
| **AdminTools** | `Config.Systems.Security` — the `Placement.MaxRandomAttempts` cap. | Optional — only affects the placement retry count. |
| **Notifications** | `ServerScriptService.Base.NotificationService` — the `Buy_Success`, `Hatch_Success`, `Pickup_Success` and `RareEgg_Spawned` toasts. | **Required** for the toasts. |
| **Tutorials** | `ServerScriptService.Tutorial.TutorialSignals` — the `EggPurchased` / `EggHatched` tutorial events. | Optional. |
| **Analytics** | `ServerScriptService.FunnelService` — the `FirstEggPurchased` / `FirstEggHatched` funnel steps. | Optional. |
| **PlayerData** | Persists the egg records; `PersistenceAudit` cleans them. | **Required for persistence.** |

**This system is one of the most connected in the game.** The `Egg/*`
sub-modules are individually portable; `EggService.lua` is not.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `EggArrived` | S->C | `{ BaseId, SlotId, Rarity, Price }` — fired when the purchased egg lands. |
| `EggCarried` | S->C | `{ BaseId, SlotId, Rarity }` — fired when the player picks the egg up. |
| `EggPlaced` | S->C | `{ BaseId, SlotId }` — fired when the player seats the egg on a stand. |

The system also **listens** to no remotes. The prompt callbacks are
invoked in-process by `ProximityPrompt.Triggered`.

---

## Profile Fields

The egg records live in the player's profile. This system **writes**
them (via `PlayerService`) and **reads** them (via
`SpawnFromPersistence` and the carry/place flows).

| Field | Type | Written by | Read by |
|---|---|---|---|
| `Id` | `string` | `SpawnService._spawnPersistence` (mints and writes back) | The persistence restore path. |
| `Rarity` | `string` | `SpawnService` | `HatchEgg` (the hatch-roll row), `EggOverhead`. |
| `Mutations` | `{ string }` | `SpawnService` | `TraitService.ResolveInheritance` at hatch. |
| `Trait` | `string?` | `SpawnService` (a forced trait, if the egg was preassigned one) | `TraitService.ResolveInheritance` at hatch. |
| `slotId` | `string?` | `EggService.PlaceEgg` -> `PlayerService.SetEggSlot` | The persistence restore path, `EggService.HatchEgg`. |
| `Price` | `number` | `SpawnService` | `EggService.Purchase`. |

**The persistence record is the source of truth.** `ForceReleaseBase`
deliberately does **not** destroy a `Placed` egg, because the profile
still holds it — only a `Traveling` egg (whose money was debited) is
destroyed and refunded.

`PersistenceAudit` (owned by **PlayerData**) cleans the legacy rows:
invalid traits are cleared, duplicate/invalid mutations are dropped, and
an egg's **pending** trait survives.

---

## Required Studio Assets

| Asset | Where | Used by | If missing |
|---|---|---|---|
| `ServerStorage.EggTemplates.<Rarity>` | One `Model` per rarity, each with a `PrimaryPart`. | `Egg.ModelBuilder.Build` | **Silently** falls back to a procedural cube of `EggSize`. No error. |
| `ServerStorage.Assets.Sfx.Pop` | A `Sound`. | `RollController._prepareRollAudio` | One loud session warning; the roll is **mute**. No throw. |
| `ServerStorage.Assets.Sfx.Reward` | A `Sound`. | `RollController` (the reveal) | Same as above. |
| `ServerStorage.Assets.Vfx.Explosions.<Rarity>` | A rarity explosion effect. | `RollController.RevealFinalAnimal` | The reveal has no VFX. No throw. |
| `ServerStorage.Assets.OverheadGui.EggOverheadGuiTemplate` | A `BillboardGui` template. | `Egg.EggOverhead.Refresh` | Falls back to `OverheadGuiTemplate`; if neither exists, one warn-once. |
| `Workspace.EggArea` | Created at runtime by `SpawnService.RegisterCenter` — you do **not** author it. | `AmbientService` | `RegisterCenter` creates it. |
| `Workspace.Map.CenterPart.BillboardGui.Egg` (legacy: `Workspace.Map.EggTimer`) | The guarantee-timer UI node. | `GuaranteeService._pushAttributes` | One-shot warn; the timer UI does not update. |

**The overhead GUI template must contain a `Mutation1` prototype** — a
clone per mutation id is made and painted by
`ServerScriptService.Utility.MutationIcon.PaintIcon`. The template also
needs the `Container.Content` hierarchy with `Name`, `Price`, `Trait` and
`Mutations` children.

**`Workspace.EggArea.Floor`** is created at runtime as a `40 x 1 x 40`
Part, but in the source game the actual floor is a **90°-rotated
Cylinder**. `RegisterCenter` therefore reads the floor height with
`FloorGeometry.GetWorldTopY(floor)`, not `Size.Y / 2`. If you author
your own floor, use a rotated cylinder and keep that reader.

---

## External APIs

**None.** No HTTP, no webhooks, no Marketplace, no DataStore.

The guarantee timers are `os.clock()`-based and **server-session
scoped** — they are not persisted.

---

## Initialization Order

```text
1. ReplicatedStorage.Utility.*     -- BigNumber, Debug, FloorGeometry,
                                      EggWalkAnimator, StandResolver,
                                      WeightedDraw, Remotes, Validation,
                                      Signals, AudioGroups,
                                      CenterPartBillboards, OwnedObjectIdentity
2. ReplicatedStorage.Types.*       -- EggType, SlotType, RarityType,
                                      TransactionReason
3. ReplicatedStorage.Config.Creatures.Rarity     (MutationsAndTraits)
4. ReplicatedStorage.Config.Creatures.Mutations  (MutationsAndTraits)
5. ReplicatedStorage.Config.Creatures.Animals    (Animals)
6. ReplicatedStorage.Config.Creatures.Eggs       (this system)
7. ReplicatedStorage.Config.World.Prompts        (Carry)
8. ReplicatedStorage.Config.World.Movement       (SharedUtilities)
9. ReplicatedStorage.Config.Presentation.*      (SharedUtilities)
10. ServerScriptService.Utility.*                (SharedUtilities)
11. ServerScriptService.Egg.*                   -- the sub-modules
12. ServerScriptService.EggService
```

Then, in your bootstrap:

```lua
local EggService = require(ServerScriptService.EggService)

EggService.SetPlayerService(PlayerService)
EggService.SetBaseService(BaseService)
EggService.SetAnimalService(AnimalService)
EggService.SetSlotService(SlotService)
EggService.SetEconomyService(EconomyService)

EggService.Init()
EggService.RegisterCenter(workspace)
EggService.Start()
```

**The `Set*Service` injection must happen BEFORE `Init()`** — `Init()`
wires the prompt callbacks, and those callbacks reach a wired service.

**`Init()` before `RegisterCenter()`** — the sub-modules must be
initialised first.

**`RegisterCenter()` before `Start()`** — the top-up thread spawns eggs,
and a spawn needs a registered centre to know the floor height.

`EggService.Init()` internally calls `SpawnService.Init()`,
`ServerLuckService.Init()` and `RareEggNotifier.Start()`, and wires the
three prompt callbacks:

- **Buy** -> `EggService.Purchase`
- **Hatch** -> `SlotActionHandler.Handle(player, { Action = 'Hatch', SlotId = egg.slotId, OccupantId = uniqueId })`
- **Egg Grab** -> `SlotActionHandler.Handle(player, { Action = 'Pickup', ... })`

---

## Third-Party Packages

**None.** This system requires no Wally packages. `BigNumber`,
`FloorGeometry`, `EggWalkAnimator` and `StandResolver` are first-party
modules in `ReusableSystems/Shared/`.

---

## Secrets

**None.** This system uses no API keys, tokens, webhook URLs or
credentials of any kind. If you extend it to call a third-party service
(for example an analytics provider), use a placeholder in the repo and
supply the real value through a Roblox `HttpService` HTTP header or a
Studio-only local module — never a literal in the source.
