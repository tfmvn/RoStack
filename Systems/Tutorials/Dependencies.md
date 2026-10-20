# Tutorials — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Tutorial/TutorialService.lua`

At load time:

```lua
local TutorialSignals = require(script.Parent.TutorialSignals)
local SlotType       = require(ReplicatedStorage.Types.SlotType)
local Remotes        = require(ReplicatedStorage.Utility.Remotes)
local Debug          = require(ReplicatedStorage.Utility.Debug)
local EggConfig      = require(ReplicatedStorage.Config.Creatures.Eggs)
local RarityDefs     = require(ReplicatedStorage.Config.Creatures.Rarity)
local FunnelService  = require(script.Parent.Parent.FunnelService)
local PlayerLogger   = require(script.Parent.Parent.PlayerLogger.PlayerLogger)
```

Note `script.Parent.Parent.FunnelService` → the Analytics system, and
`script.Parent.Parent.PlayerLogger.PlayerLogger` → the PlayerLogging
system. Both must sit at `ServerScriptService/` root.

Roblox services obtained at runtime:

```lua
local Players           = game:GetService('Players')
local CollectionService = game:GetService('CollectionService')
local RunService        = game:GetService('RunService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
```

### Lazy service refs (resolved by `_services()` on first use)

```lua
require(sss.PlayerService)
require(sss.Egg.SpawnService)
require(sss.AnimalService)
require(sss.Base.SlotService)
require(sss.BaseService)
```

Each `require` is inside one `pcall`. If any of them fails, the whole
resolution returns `false` — but the ones already resolved stay
cached, so the next call only retries the missing ones.

### `ServerScriptService/Tutorial/TutorialSignals.lua`

```lua
local Signals = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Signals)
local Debug   = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **SharedUtilities** | `ReplicatedStorage.Utility.Signals` | `Signals.new()` — the bus primitive. | **Required** — the bus cannot create channels without it. |
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | Every trace line and the "fell back to BuyEgg" warning. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.Remotes` | `Remotes.Names.TutorialState` / `.TutorialAction` and `Remotes.FireClient`. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Types.SlotType` | `SlotType.ArenaSlotIndexBase` and `SlotType.State.Empty`. | **Required.** |
| **EggsAndHatching** | `ReplicatedStorage.Config.Creatures.Eggs` | The starter rarity (via `GetStarterRarity`, **which does not exist** — see `Config.lua`). | **Required** at load. |
| **Animals** | `ReplicatedStorage.Config.Creatures.Rarity` | `RarityDefs.Order[1]` — the starter-rarity fallback. | **Required** at load. |
| **Analytics** | `ServerScriptService.FunnelService` | `FunnelService:LogStep(player, 'Onboarding', 'TutorialStarted' / 'TutorialCompleted' / 'TutorialSkipped', nil)`. | **Optional in effect** — every call is inside a `pcall`, but the `require` at load is **not**, so the module must exist. |
| **PlayerLogging** | `ServerScriptService.PlayerLogger.PlayerLogger` | `PlayerLogger.LogMilestone(player, 'TutorialCompleted', nil)` on a real completion. | **Optional in effect** — the call is inside a `pcall`, but the `require` at load is **not**, so the module must exist. |
| **PlayerData** | `ServerScriptService.PlayerService` | `GetPlayerData(userId)` and `SetTutorial(userId, {...})`. | **Required at runtime** — without it the tutorial cannot persist or resume. |
| **EggsAndHatching** | `ServerScriptService.Egg.SpawnService` | `GetEgg(id)` — the egg registry lookup and the model for the tag. | **Required at runtime.** |
| **Animals** | `ServerScriptService.AnimalService` | `Get(id)` — the animal registry lookup and the model for the tag. | **Required at runtime.** |
| **BasesAndSlots** | `ServerScriptService.Base.SlotService` | `FindSlotByOccupant(animalId)` — the slot id for the upgrade step. | **Required at runtime.** |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `GetPlayerBase(userId)` — the arena slot suggestion and the own-base check. | **Required at runtime.** |
| **BasesAndSlots** | `ServerScriptService.Base.BaseLockService` | `IsLocked(base.id)` — the LockBase re-check in `RecoverFor`. Required lazily, **inside** `RecoverFor` only. | **Optional** — the lock re-check is skipped if the require fails. |

### Systems that call *into* this one (callers, not dependencies)

| System | Call |
|---|---|
| **EggsAndHatching** | `TutorialSignals.Fire('EggPurchased', { UserId, EggId })`, `'EggPlaced'`, `'EggHatched'` |
| **Animals** | `TutorialSignals.Fire('AnimalPickedUp', { UserId, AnimalId })`, `'AnimalPlaced'` |
| **Arena** | `TutorialSignals.Fire('ArenaStarted' / 'ArenaEnded' / 'ArenaCancelled', { UserId })` |
| **Upgrades** | `TutorialSignals.Fire('AnimalUpgraded', { UserId, AnimalId, NewLevel })` |
| **BasesAndSlots** | `TutorialSignals.Fire('BaseLocked', { UserId, BaseId })` |
| **Bootstrap** | `TutorialService.Init()`, `.Start()`, `.ResumeForPlayer(player)`, `.ForgetPlayer(userId)` |

The gameplay systems fire the bus; they never call `TutorialService`
directly (except the bootstrap). This is what keeps the tutorial a
pure observer.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `Remotes.Names.TutorialAction` = `'TutorialAction'` | Client → Server | `{ Action = 'State' \| 'Continue' \| 'Skip' }` |
| `Remotes.Names.TutorialState` = `'TutorialState'` | Server → Client | `{ Step, EggId?, AnimalId?, SlotId?, BaseId?, StarterEggRarity? }` |

**`TutorialAction`** is bound in `TutorialService.Init()` via
`ReplicatedStorage:WaitForChild('Remotes', 10)` then
`WaitForChild(Remotes.Names.TutorialAction, 10)`. The handler is
`TutorialService.HandleAction(player, payload)`.

**`TutorialState`** is fired by `TutorialService.PublishTo` through
`Remotes.FireClient(player, Remotes.Names.TutorialState, snapshot)`.

The `Remotes` module is the shared registry — the two names must
exist in it.

### The CollectionService tag (not a remote, but a client channel)

`CollectionService:AddTag(model, 'TutorialTarget_<userId>')`.

The tag is the **only** way the client finds the object to beam at.
The client reads it with the same `<prefix>_<userId>` rule.

---

## Profile Fields Read / Written

**Written** — one field, via `PlayerService.SetTutorial(userId, {...})`:

```lua
profile.Data.Tutorial = {
    Completed = boolean,   -- state.Step == 'Completed'
    Step = string,         -- one of the 11 step names
    EggId = string?,       -- the tracked egg id
    AnimalId = string?,    -- the tracked animal id
}
```

**Read** — via `PlayerService.GetPlayerData(userId)`:

| Field | Used for |
|---|---|
| `profile.Tutorial` | `_readPersisted` — the resume input. |
| `profile.BaseId` | `_baseIdOf` — the `BaseId` in the published snapshot. |
| `profile.LuckyBlocks` | `lookup.ownedUnhatchedEggId()` — the rows are scanned for an owned, interactable egg. Each row has an `Id`. |

**Read** from the egg record (`SpawnService.GetEgg(id)`):

| Field | Used for |
|---|---|
| `egg.model` | the tagged instance. |
| `egg.state` | `'Available'`, `'Traveling'`, `'Placed'` gate the adoption of a replacement egg. |

**Read** from the animal record (`AnimalService.Get(id)`):

| Field | Used for |
|---|---|
| `animal.model` | the tagged instance. |

**Read** from the base (`BaseService.GetPlayerBase(userId)`):

| Field | Used for |
|---|---|
| `base.id` | the own-base check for `BaseLocked`. |
| `base.arenaSlots` | the arena slot suggestion — each slot has `id`, `state`, `arenaIndex`. |

---

## Required Studio Assets

**None in `Workspace`.**

The one asset is optional and remote:

| Asset | How | If unavailable |
|---|---|---|
| The Beam template (asset id `14403995847`) | `InsertService:LoadAsset` at `Init()`, parented to `ReplicatedStorage` as `TutorialBeamTemplate`. | The exact Roblox error is printed; the client builds a **white fallback beam** itself. |

**Alternative:** author a `TutorialBeamTemplate` instance directly in
`ReplicatedStorage` in Studio. The publisher then returns immediately
and loads nothing.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `InsertService:LoadAsset` | The Beam template. | The asset must be public (or owned by the experience). |
| `DataStoreService` | **Not used directly** — the tutorial persists through `PlayerService`, which owns the store. | — |
| `HttpService` | **Not used.** | — |

**No HTTP, no Marketplace.** The analytics and monitoring calls are
made by the Analytics and PlayerLogging systems, not by the tutorial.

---

## Initialization Order

```text
1. createRemotes()
     - Remotes.Names.TutorialAction and .TutorialState must exist
2. PlayerService.Init()
3. TutorialService.Init()
     - resolves the five lazy services (_services())
     - spawns the Beam template fetch (never blocks boot)
     - connects the ten TutorialSignals channels
     - binds TutorialAction.OnServerEvent -> HandleAction
4. TutorialService.Start()
     - starts the 1 Hz recovery sweep
5. On player join, AFTER the profile has loaded and the base has
   been restored:
     TutorialService.ResumeForPlayer(player)
```

**Step 5 must come after the profile load.** `ResumeForPlayer` reads
`profile.Tutorial` and validates it against the live egg/animal
registries; running it earlier derives the wrong step.

**Step 3 before step 5** — `ResumeForPlayer` needs the services that
`Init()` resolves (though `_services()` is also called there, so it
would resolve them anyway).

**Step 4 is optional but recommended.** Without the sweep, a player
whose egg model is destroyed mid-hatch loses their target.

On player removal:

```lua
TutorialService.ForgetPlayer(player.UserId)
```

---

## Require-cycle notes

The tutorial requires only **leaf** modules at load time:

- `TutorialSignals` → `Signals`, `Debug`
- `SlotType`, `Remotes`, `Debug`, `Eggs`, `Rarity` → all leaves
- `FunnelService` → `Debug`
- `PlayerLogger` → `PlayerLoggerConfig`, `PlayerRegistry`, `Debug`

The five gameplay services are required **lazily** inside `_services()`
and each `require` is `pcall`-guarded, so a require cycle cannot form
and a missing service cannot break the module load.

**The gameplay systems must not require `TutorialService`** — they
fire `TutorialSignals` instead. That is what keeps the dependency
one-way.
