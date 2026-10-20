# Stealing — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged
when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Steal/StealService.lua`

Verbatim from `Source/ServerScriptService/Steal/StealService.lua:62-99`:

```lua
local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerStorage = game:GetService('ServerStorage')
local Debris = game:GetService('Debris')

local SlotType = require(ReplicatedStorage.Types.SlotType)
local Validation = require(ReplicatedStorage.Utility.Validation)
local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)
local StealConfig = require(ReplicatedStorage.Config.World.Stealing)
local PromptConfig = require(ReplicatedStorage.Config.World.Prompts)
local AudioConfig = require(ReplicatedStorage.Config.Presentation.Audio)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local Debug = require(ReplicatedStorage.Utility.Debug)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)

local SlotService = require(ServerScriptService.Base.SlotService)
local BaseService = require(ServerScriptService.BaseService)
local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
local CarryController = require(ServerScriptService.Animal.CarryController)
local CarryPrompts = require(ServerScriptService.Animal.CarryPrompts)
local AnimalOverhead = require(ServerScriptService.Animal.AnimalOverhead)
local StandPresentation = require(ServerScriptService.StandPresentation)
local NotificationService = require(ServerScriptService.Base.NotificationService)
local FunnelService = require(ServerScriptService.FunnelService)
local HoverMath = require(ServerScriptService.Egg.HoverMath)
local SpawnService = require(ServerScriptService.Egg.SpawnService)
local AnimalService = require(ServerScriptService.AnimalService)
local ArenaService = require(ServerScriptService.Arena.ArenaService)
```

The config module `ReplicatedStorage/Config/World/Stealing.lua` has **no**
requires of its own beyond the standard library — it is a pure data module
plus a `Validate()` function.

---

## Other Systems Required

| System | Module(s) used | Why | Optional? |
|---|---|---|---|
| **Carry** | `CarryRegistry` | **The one carry state.** A steal is a carry item with a `steal` metadata table. `IsCarrying` gates the request; `Set`/`Clear`/`Get`/`ForEach` are the transaction's bookends. | **Required.** Without it there is no carry to steal with. |
| **Inventory** | `SlotService` (`ServerScriptService.Base.SlotService`) | The slot state machine. `DemoteSlotToReserved` is the atomic reservation, `ReserveSlot`/`ReleaseSlot`/`OccupySlot` manage the destination and the original slot, `GetFreeSlot` proves capacity, `RefreshDisplays` repaints after a multi-step transaction. | **Required.** |
| **BasesAndSlots** | `BaseService`, `StandPresentation` | Base ownership (`GetBaseByOwner`), the `collector` part, the base's slot list; `StandPresentation.Bind` / `Unbind` for the egg's idle wobble. | **Required.** |
| **Animals** | `CarryController`, `CarryPrompts`, `AnimalOverhead`, `AnimalService` | The weld/follow behavior; the Steal prompt installer + callback registry; the temporary `STOLEN` overhead; `Get` (record lookup) and `SettleModelAtSlot` (animal seating). | **Required.** |
| **EggsAndHatching** | `SpawnService`, `HoverMath` | `GetEgg` (record lookup), `GetActiveContainer` (re-home the egg model), `InstallHatchPrompt` (re-install the prompt after delivery); `HoverMath.Settle` seats the egg on its slot. | **Required.** |
| **PlayerData** | `PlayerService` (injected, not required) | The profile authority: `GetEggs` / `GetAnimals` / `AddEgg` / `AddAnimal` / `RemoveEgg` / `RemoveAnimal` / `SetEggSlot` / `SetAnimalSlot` / `PushState` / `Notify`. | **Required.** Injected through `StealService.SetPlayerService`, which is what keeps the require graph acyclic. |
| **Notifications** | `NotificationService` | The canonical `NotifyWarning` / `NotifySuccess` channel and the `Steal_*` message catalog. | **Required.** |
| **Arena** | `ArenaService` | `IsAnimalRaidLocked(uniqueId)` — an animal fighting in an active raid cannot be stolen. | **Optional in principle, required in practice.** Without it, animals can be stolen mid-raid. `ArenaService` itself only requires `ReplicatedStorage` modules, so the dependency does not create a cycle. |
| **Analytics** | `FunnelService` | `FunnelService:LogStep(player, 'Social', 'StealSucceeded', { kind })` — one step, fired only on a **successful delivery**. | **Optional.** Wrapped in `pcall`; the steal succeeds without it. |
| **SharedUtilities** | `Config.Presentation.Audio`, `Config.Systems.Debug` | `StealAlertSoundName` (the SFX asset name) and `Debug.Audio.Enabled` (the SFX debug log gate). | **Required** for the sound; the debug gate is optional (the code reads it directly, so the config module must exist). |
| **Shared** | `Types.SlotType`, `Utility.Validation`, `Utility.RichTextFormatter`, `Utility.Debug`, `Utility.AudioGroups` | The `OccupantKind` values, the userId/liveness gates, the safe RichText builder for the robbery message, the logging channel, the SFX sound-group assignment. | **Required.** |

### Reverse dependencies (systems that call into `StealService`)

| System | Call | Purpose |
|---|---|---|
| `SharedUtilities` (`bootstrap.server.lua`) | `SetPlayerService`, `Init`, `Start` | Bootstrap wiring. |
| `SharedUtilities` (`bootstrap.server.lua`) | `RollbackIfStealing(userId, 'death' / 'character-destroyed' / 'studio-cmd')` | The thief's death / leave recovery. |
| `Animals` (`AnimalService.lua:2922`) | `RollbackStolenTarget('animal', uniqueId, 'owner-leaving')` | Recover the animal home **before** the base teardown. |
| `EggsAndHatching` (`EggService.lua:906`) | `RollbackStolenTarget('egg', egg.uniqueId, 'owner-leaving')` | Same, for eggs. |
| `Rebirth` (`RebirthService.lua:913/918`) | `RollbackStolenTarget(...)` | Same, on rebirth. |
| `Arena` (`ArenaService`) | `ArenaService.SetStealService(StealService)` | Injected so the arena can roll back a steal in its own flows. |
| `Combat` (`BatService`) | `RollbackIfStealing` | A bat hit cancels a steal. `BatService.Init()` must run **after** `StealService.Init()` and `StealService.Start()`. |
| `Inventory` (`SlotActionHandler`) | — | Rejects a steal-carried object from being placed (`'steal-in-progress'`). |

---

## Remotes

**This system fires no `RemoteEvent` directly.** It drives two channels
through other services, and it reads one prompt surface.

| Remote / surface | Direction | Payload shape | Fired by |
|---|---|---|---|
| `PlayerState` | S→C | `{Money (string), BaseId, Slots[] {Id, State, OccupantKind, OccupantId}, CarriedKind, CarriedName, CarriedSteal}` | `playerServiceRef.PushState(player, BaseService.Snapshot(player.UserId))` — `_push` (line 283). Pushed for the **thief** at steal start, at delivery, and on every rollback exit; and for the **owner** after a successful steal and after a delivery. `CarriedSteal` is what tells the client's `StealPresentationController` and `PromptOwnerFilter` that a steal is live. |
| `Notify` | S→C | `{Category, Text}` | `NotificationService.NotifyWarning` / `NotifySuccess`, and `playerServiceRef.Notify(player, 'Warning', text)` for the victim's robbery message. Warning ids: `Steal_Cooldown`, `Steal_OwnAnimal`, `Steal_AlreadyCarrying`, `Steal_BaseFull`, `Steal_BaseLocked`, `Steal_TooFar`, `Steal_TargetBusy`, `Steal_TargetGone`, `General_Generic`. Success ids: `Steal_Success` (`{AnimalName, Rarity}`), `Steal_DeliverySuccess` (`{AnimalName, Rarity}`). |
| `ProximityPrompt` (`StealPrompt`) | Player→Server | `{Player, occupantId, kind}` — the prompt's `Triggered` event | `CarryPrompts.InstallStealPrompt` installs it; `StealService.Init()` wires the callback to `TrySteal`. The prompt replicates **disabled**; the client `PromptOwnerFilter` enables it for eligible non-owners. |
| `ProximityPrompt` (`Collector.Touched`) | Physics→Server | `hit: Instance` | `StealService.Start()` connects one `Touched` per collector; the only completion path. |

**No C→S `RemoteEvent` is used by the steal system.** A forged request can
only arrive through the `StealPrompt`'s `Triggered` handler, and everything
it carries (`occupantId`, `kind`) is re-validated server-side.

The remotes are created at boot from the `Remotes.Names` registry — see
`Shared/CommonModules/Remotes.lua`. Do not hand-author them.

---

## Profile Fields

**This system owns no profile fields.** It moves records between two
players' existing owned-object lists.

### Read

| Source | Fields |
|---|---|
| `PlayerService.GetEggs(ownerId)` | `Id`, `Rarity`, `Mutations`, `Trait` (snapshotted before removal) |
| `PlayerService.GetAnimals(ownerId)` | `Id`, `DefId`, `Level`, `XP`, `CashPool`, `Trait`, `Mutations` |

### Written

| Call | Fields written | Notes |
|---|---|---|
| `PlayerService.AddEgg(thiefId, slotId, rarity, id, {Mutations, Trait})` | `Type='LuckyBlock'`, `SlotId`, `Rarity`, `Id`, `Mutations`, `Trait` | The `Id` is the **same** id the record had under the original owner. `AddEgg` is idempotent on `Id` — it returns `true` if the id already exists. |
| `PlayerService.AddAnimal(thiefId, slotId, defId, id, {Level, XP, CashPool, Trait, Mutations})` | `Type='Brainrot'`, `SlotId`, `DefId`, `Id`, `Level`, `XP`, `CashPool`, `Trait`, `Mutations` | Same `Id` preserved. `CashPool` is a BigNumber **string**. |
| `PlayerService.RemoveEgg(ownerId, id)` | — | Settles the pool per the global removal policy. |
| `PlayerService.RemoveAnimal(ownerId, id)` | — | Same. |
| `PlayerService.SetEggSlot(ownerId, id, newSlotId)` | `SlotId` | Rollback tier-2 only. Failure is a warning, not fatal. |
| `PlayerService.SetAnimalSlot(ownerId, id, newSlotId)` | `SlotId` | Rollback tier-2 only. |

### The profile authority contract

`StealService` calls exactly these members on the injected `playerServiceRef`.
A replacement must implement all of them:

```lua
GetEggs(userId)                 -> { {Id, Rarity, Mutations, Trait}, ... }
GetAnimals(userId)              -> { {Id, DefId, Level, XP, CashPool, Trait, Mutations}, ... }
AddEgg(userId, slotId, rarity, id, opts)            -> boolean
AddAnimal(userId, slotId, defId, id, opts)          -> boolean
RemoveEgg(userId, id)                              -> boolean
RemoveAnimal(userId, id)                           -> boolean
SetEggSlot(userId, id, newSlotId)                  -> boolean
SetAnimalSlot(userId, id, newSlotId)               -> boolean
PushState(player, baseSnapshot)                    -> (any)
Notify(player, category, text)                     -> (any)
```

`PushState` and `Notify` are called inside `pcall` (best-effort). The
`Add*` / `Remove*` / `Set*Slot` calls are **not** pcall-wrapped — their
boolean return is checked and a `false` return is treated as a transaction
failure.

### Runtime (non-profile) record fields the steal mutates

These live on the in-memory runtime record (`SpawnService.GetEgg(id)` /
`AnimalService.Get(id)`), not in the profile:

`state`, `carriedBy`, `stolenBy`, `originalSlotId`, `slotId`,
`ownerUserId`, `controller`, `controllerType`, `_mutex`.

---

## Studio Assets

### Required

| Path | Class | Used for | If missing |
|---|---|---|---|
| `ServerStorage.Assets.Sfx.Stealing` | a `Sound`, **or** any `Instance` containing a `Sound` descendant | The robbery-alert sting played to the robbed owner only. The name comes from `Audio.StealAlertSoundName`. | **Silent no-op** + a `Debug.Warn`. The steal still succeeds. The clone is parented to the owner's `PlayerGui` and cleaned up with `Debris:AddItem` after `TimeLength + AlertCleanupPad` (or `AlertFallbackCleanup`). A `Sound` with an empty `SoundId` is also a silent no-op. |

### Required Workspace hierarchy

Authored by the **BasesAndSlots** system, but the steal system reads it:

```text
Workspace
├── Bases
│   ├── Base_1
│   │   ├── Collector        (BasePart, CanTouch = true)  <- the delivery target
│   │   ├── Spawn            (BasePart)
│   │   ├── Slots
│   │   │   ├── Slot1 ... SlotN   (BasePart, one per slot)
│   │   └── ...
│   └── Base_2 ... Base_8
├── Animals
│   └── Recovering           (Folder) — created AT RUNTIME by the
│                             rollback tier-3 park, if it does not exist
└── EggArea
    └── ActiveEggs           (Folder) — the canonical container for
                              placed egg models; created by SpawnService
                              if missing
```

- **`Collector` is the delivery target.** It must be a `BasePart`.
  `_thiefCollector` (line 161) returns `(base, nil)` for anything else, and
  `StealService.Start()` (line 413) **silently skips** a base whose
  collector is missing or is not a `BasePart` — such a base can never
  complete a steal.
- **`CanTouch` must be true** on the collector, or the `Touched` event
  never fires and delivery is impossible.
- `BaseService.RegisterBases(Workspace)` must have run **before**
  `StealService.Start()`.

### Not required by this system

- No animation assets (the steal reuses the existing carry controller).
- No `Lighting` / `SoundGroup` authoring, but `AudioGroups.AssignSfx` needs
  the `GameSound` `SoundGroup` to exist in `SoundService` — the
  `AudioGroups.EnsureGroups` call in the bootstrap handles that.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `Players` | `GetPlayerFromCharacter`, `GetPlayerByUserId` (the owner lookup for the robbery alert) | — |
| `Debris` | `Debris:AddItem(soundClone, lifetime)` — cleans up the robbery-alert SFX | — |
| `ServerStorage` | Reads `Assets.Sfx.<StealAlertSoundName>` | — |
| `DataStoreService` | **Not used directly.** The profile is owned by `PlayerService` / `ProfileService`. | Enable Studio Access to API Services in Studio. |
| `HttpService` | **Not used.** The funnel analytics are sent by `FunnelService`, not by this system. | — |

**No credentials, tokens, or webhook URLs are involved in this system.**

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  BaseService.RegisterBases(Workspace)      -- the collectors must exist
3.  EggService.RegisterCenter(Workspace)     -- the ActiveEggs container
4.  StealService.SetPlayerService(PlayerService)
5.  StealService.Init()                      -- wires the Steal prompt callback
6.  StealService.Start()                     -- arms the collector Touched routing
7.  ArenaService.SetStealService(StealService)   -- later, in the arena wiring
8.  BatService.Init()                        -- MUST be after 5 and 6
```

**Two hard ordering constraints:**

- **`Start()` after `RegisterBases`.** `Start()` iterates
  `BaseService.GetAllBases()` once. A base registered later gets **no**
  `Touched` routing and can never be a delivery target. There is no
  re-arm hook; calling `Start()` again is safe (it is idempotent) but must
  be done manually.
- **`Init()` before any player can trigger a Steal prompt.** The prompt
  itself is installed by `CarryPrompts`; only the callback is this
  system's job.

**On player death** (`bootstrap.server.lua:1057`):

```text
Humanoid.Died
  -> StealService.RollbackIfStealing(userId, 'death')
       true  -> requestRespawn(player); return   (the generic recovery is skipped)
       false -> the normal AnimalService / EggService carry recovery runs
```

**On owner leave / rebirth** — recover **before** teardown:

```text
AnimalService.CleanupPlayer / EggService.CleanupPlayer / RebirthService
  -> StealService.RollbackStolenTarget(kind, uniqueId, 'owner-leaving' | 'rebirth')
       true  -> the object is back in the owner's slot; the normal
                non-destructive sweep then drops the runtime and keeps
                the profile
       false -> nothing to recover
```

**On player leave** — `StealService.ForgetPlayer(userId)` is the intended
cleanup hook, but **the bootstrap never calls it** and the function
currently throws (see `README.md` → Known Limitations).

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
