# Collectors — Dependencies

Exact module require paths (verbatim from the source), the systems
Collectors needs, the remotes it uses, the profile fields it reads and
writes, the Studio assets it assumes, and the exact initialization
order.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Setup.md](Setup.md)

---

## Module Requires

### `Source/ServerScriptService/Base/CollectorArrival.lua` (lines 59–72)

```lua
local HoverMath = require(script.Parent.Parent.Egg.HoverMath)
local StandPresentation = require(script.Parent.Parent.StandPresentation)
local Constants = require(script.Parent.Parent.Egg.Constants)
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Validation = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
local EconomyService = require(script.Parent.Parent.Parent.EconomyService)
-- Canonical player-facing rejections. Leaf module (no
-- ServerScriptService requires) — safe to load here even though
-- EggService requires this module.
local NotificationService = require(script.Parent.NotificationService)
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals)
```

### One lazy require inside `CollectorArrival`

```lua
-- Inside _refundAndDrop (line ~175):
local SpawnService = require(script.Parent.Parent.Egg.SpawnService)
SpawnService.DropEgg(egg.uniqueId)
```

`SpawnService` is required by `EggService`, which requires
`CollectorArrival` — a top-level require would close the cycle.

### `Source/ServerScriptService/Base/CollectFeedback.lua` (lines 72–82)

```lua
local ServerStorage = game:GetService('ServerStorage')
local TweenService = game:GetService('TweenService')
local RunService = game:GetService('RunService')
local Debris = game:GetService('Debris')

local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local DebugConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local AudioConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Audio)
local Bases = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local AudioGroups = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)
```

### Where each required module lives

| Required path | Roblox destination | Owned by |
|---|---|---|
| `ServerScriptService.Egg.HoverMath` | `ServerScriptService/Egg/HoverMath.lua` | **EggsAndHatching** |
| `ServerScriptService.StandPresentation` | `ServerScriptService/StandPresentation.lua` | **BasesAndSlots** |
| `ServerScriptService.Egg.Constants` | `ServerScriptService/Egg/Constants.lua` | **EggsAndHatching** |
| `ServerScriptService.Egg.SpawnService` | `ServerScriptService/Egg/SpawnService.lua` | **EggsAndHatching** (lazy) |
| `ServerScriptService.EconomyService` | `ServerScriptService/EconomyService.lua` | **Economy** |
| `ServerScriptService.Base.NotificationService` | `ServerScriptService/Base/NotificationService.lua` | **Notifications** |
| `ServerScriptService.Tutorial.TutorialSignals` | `ServerScriptService/Tutorial/TutorialSignals.lua` | **Tutorials** |
| `ReplicatedStorage.Types.SlotType` | `ReplicatedStorage/Types/SlotType.lua` | **Shared** |
| `ReplicatedStorage.Types.TransactionReason` | `ReplicatedStorage/Types/TransactionReason.lua` | **Shared** |
| `ReplicatedStorage.Utility.Validation` | `ReplicatedStorage/Utility/Validation.lua` | **Shared** |
| `ReplicatedStorage.Utility.Debug` | `ReplicatedStorage/Utility/Debug.lua` | **Shared** |
| `ReplicatedStorage.Utility.BigNumber` | `ReplicatedStorage/Utility/BigNumber.lua` | **Shared** |
| `ReplicatedStorage.Utility.StandResolver` | `ReplicatedStorage/Utility/StandResolver.lua` | **Shared** |
| `ReplicatedStorage.Utility.AudioGroups` | `ReplicatedStorage/Utility/AudioGroups.lua` | **Shared** |
| `ReplicatedStorage.Config.Systems.Debug` | `ReplicatedStorage/Config/Systems/Debug.lua` | **SharedUtilities** |
| `ReplicatedStorage.Config.Presentation.Audio` | `ReplicatedStorage/Config/Presentation/Audio.lua` | **SharedUtilities** |
| `ReplicatedStorage.Config.World.Bases` | `ReplicatedStorage/Config/World/Bases.lua` | **BasesAndSlots** |

### Path notes

- `script.Parent.Parent.Parent.ReplicatedStorage.*` resolves to
  `ReplicatedStorage.*` from `ServerScriptService/Base/*.lua` (three
  levels up from the module: `Base` → `ServerScriptService` → game).
- `script.Parent.Parent.Egg.HoverMath` resolves to
  `ServerScriptService/Egg/HoverMath.lua` (two levels up, then into
  `Egg`).
- `script.Parent.Parent.StandPresentation` resolves to
  `ServerScriptService/StandPresentation.lua` — **directly** under
  `ServerScriptService`, not under `Base`.
- `script.Parent.NotificationService` resolves to
  `ServerScriptService/Base/NotificationService.lua`.
- `script.Parent.Parent.Tutorial.TutorialSignals` resolves to
  `ServerScriptService/Tutorial/TutorialSignals.lua`.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **EggsAndHatching** (`HoverMath`, `Constants`, `SpawnService`) | `Settle` lands the egg; `Constants.State.Traveling` / `.Placed` gate the arrival; `DropEgg` removes it from the spawn registry on Tier 3. | **No** for `HoverMath` / `Constants` — the module will not load. `SpawnService` is required lazily and only on the Tier-3 path. |
| **BasesAndSlots** (`StandPresentation`, `SlotService`, `Bases` config) | `StandPresentation.Bind` is the stand wobble; `SlotService` owns the slot state machine that this module drives (`_findSlotById`, `GetFreeSlot`, `ReserveSlot`, `OccupySlot`, `ReleaseSlot`); `Bases.Collector.Feel` is the press/VFX tuning. | **No.** |
| **Economy** (`EconomyService`) | `AddMoney(userId, amount, TransactionReason.EggRefund)` — the Tier-3 refund. | **No** — it is a **hard top-level require**, not an injection. |
| **PlayerData** (`PlayerService`) | `SetEggSlot`, `AddEgg`, `RemoveEgg`, `RemoveEggAtSlot` — the persistence re-point and removal. | **No in practice** — it is read from `refs.playerService`, not required. Without it, Tier 2 cannot re-point the record and Tier 3 cannot remove it. |
| **Shared** (`SlotType`, `TransactionReason`, `Validation`, `Debug`, `BigNumber`, `StandResolver`, `AudioGroups`) | Slot-id parsing, the refund reason, the owner-userid predicate, logging, the refund amount sanitiser, the button-part resolver, the SFX group stamping. | **No.** |
| **SharedUtilities** (`Config.Systems.Debug`, `Config.Presentation.Audio`) | `Debug.Audio.Enabled` (log gate), `Audio.Collect.PoolSize` (the SFX pool bound). | **No** — both are hard requires. |
| **Notifications** (`NotificationService`) | The `Buy_ArrivalBaseFull` toast on Tier 3. | **Yes** — `pcall`-guarded; the arrival still works without it. |
| **Tutorials** (`TutorialSignals`) | `TutorialSignals.Fire('EggPlaced', …)` after the commit. | **Yes** — `pcall`-guarded; a throwing bus never affects the arrival. |
| **Income** (`IncomeService`) | The **caller**: it invokes `CollectFeedback.Play(player, slot)` after `AddMoney` succeeds and the pool zeroes. | **Yes for the module**, **required for the flow**. |

**Note the dependency direction.** `CollectorArrival` calls
`EconomyService` directly (a hard require), but everything else comes
through the `refs` table. `CollectFeedback` requires **no**
`ServerScriptService` module at all — it is entirely
`ServerStorage` + `ReplicatedStorage` + the shared config.

---

## Remotes

**None.** Neither module creates, listens on, or fires a remote.

- `CollectorArrival` produces the player-facing rejection through
  `NotificationService.NotifyWarning` (which fires the game's shared
  `Notify` remote) and through `TutorialSignals.Fire` (an in-process
  bus, not a remote).
- `CollectFeedback` produces the claim feedback entirely **server-side**
  (a `Sound` created in the client's `PlayerGui`, a VFX clone in the
  workspace, and a `TweenService` tween).

---

## Profile Fields

Neither module reads or writes a profile field **directly**. They
mutate the profile through `PlayerService` (in `refs`):

| Call | When | Effect |
|---|---|---|
| `playerService.SetEggSlot(userId, egg.uniqueId, newSlotId)` | Tier 2 | Re-points the **same** egg record to the new slot. Mutates in place. |
| `playerService.AddEgg(userId, slotId, rarity, uniqueId, { Mutations, Trait })` | Tier 2 fallback | Only when `SetEggSlot` returned false. Passes the runtime's own Id explicitly so it can never mint a duplicate record. |
| `playerService.RemoveEgg(userId, egg.uniqueId)` | Tier 3 | Removes the record **by its own Id** (the persistence key). |
| `playerService.RemoveEggAtSlot(userId, egg.slotId)` | Tier 3 fallback | Only when `RemoveEgg` returned false. |

The **economy** side of the refund also mutates persistent state,
through `EconomyService.AddMoney(userId, amount, TransactionReason.EggRefund)`.

`CollectFeedback` touches **no** profile state at all.

---

## Required Studio Assets

### ServerStorage (server-only, never replicated)

```text
ServerStorage
└── Assets
    ├── Sfx
    │   └── CashClaim      -- a Sound, OR a container with a Sound inside
    └── Vfx
        └── CashClaim      -- an Attachment, OR a container with an
                           -- Attachment inside
```

Both resolvers accept either shape: if the asset **is** a `Sound` /
`Attachment`, it is used directly; otherwise the first descendant of
that type is used.

For the VFX:

- The attachment's **authored local offset is ignored** — the burst is
  re-anchored above the button's live top surface.
- Every `ParticleEmitter` should carry an **`EmitCount` attribute**
  (a number). The value is used **exactly**; an emitter without the
  attribute fires `Emit(0)` (nothing).
- `PointLight` / `SpotLight` / `SurfaceLight` / `Beam` descendants are
  switched **on** for the burst lifetime (on the clone only).
- `Sound` descendants inside the VFX also play.

A missing asset is a **warn, once per server session** — the claim
still succeeds, it just runs mute / without VFX.

### Workspace (button hierarchy)

```text
Workspace
└── Map
    └── Bases
        └── Base_<n>
            └── AnimalStands
                └── Stand<k>
                    └── Button            -- StandResolver.Names.ButtonFolder
                        ├── Base         -- StandResolver.Names.ButtonBase
                        └── PressPart    -- StandResolver.Names.PressPart
```

Resolved by `StandResolver.GetButtonParts(stand)`. Both `Base` and
`PressPart` must be `BasePart`s. A missing `Base` means **no press**
(SFX and VFX still fire).

**No Collector-specific workspace parts are required.** `slot.cashCollector`
is read from the **slot record** (the live slot carries its parts), so
there is no workspace scan.

---

## External APIs

**None.** No DataStore, no HTTP, no MarketplaceService, no third-party
package, no API key or token.

The only persistence-adjacent call is `EconomyService.AddMoney`, which
is the **Economy** system's business — this module neither owns the
DataStore nor touches a credential.

---

## Exact Initialization Order

### `CollectorArrival`

**There is no init function.** `CollectorArrival` is invoked by
`FlightController._onComplete` at `t >= 1`, after that controller's own
guards and after the final `PivotTo(Collector)`.

Its collaborators are wired by `SpawnService` at **spawn** time:

```text
egg._refs = { playerService, baseService, animalService, slotService }
```

So the order is:

```text
1.  SlotService / BaseService initialised (the slot state machine)
2.  EconomyService initialised (the refund surface)
3.  EggService / SpawnService initialised
      -> they wire egg._refs at spawn time
4.  FlightController launches a flight
5.  FlightController._onComplete (t >= 1)
      -> CollectorArrival.OnArrival(egg, egg._refs)
```

### `CollectFeedback`

`CollectFeedback.Init()` is an **empty function**. The only real setup
is per-player:

```text
1.  Player joins
      -> CollectFeedback.Warm(player)
         creates the CashClaimPool (4 Sounds) under their PlayerGui
         so the first claim does not create-and-play in the same tick

2.  Player leaves
      -> CollectFeedback.ForgetPlayer(userId)

3.  A successful claim commit (IncomeService.TryCollect, after
    AddMoney succeeds and the pool zeroes)
      -> CollectFeedback.Play(player, slot)
```

`Warm` is optional — `_ensurePool` self-heals on the first `Play` — but
it is worth calling at join for the replication head start.

**There is no ordering constraint between the two modules.** They share
nothing but the `Base` folder.
