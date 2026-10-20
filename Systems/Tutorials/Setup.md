# Tutorials — Setup

Installing the tutorial system into a new Rojo project.

---

## 1. Copy the files

| From the library | To in your Rojo project | Roblox path |
|---|---|---|
| `Source/ServerScriptService/Tutorial/TutorialService.lua` | `src/ServerScriptService/Tutorial/TutorialService.lua` | `ServerScriptService.Tutorial.TutorialService` |
| `Source/ServerScriptService/Tutorial/TutorialSignals.lua` | `src/ServerScriptService/Tutorial/TutorialSignals.lua` | `ServerScriptService.Tutorial.TutorialSignals` |

Two files. **There is no client half in this library folder** — you
also need a client controller (see step 8).

Your `default.project.json`:

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$path": "src/ServerScriptService"
    },
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage"
    },
    "StarterPlayer": {
      "$path": "src/StarterPlayer"
    }
  }
}
```

The `require` paths inside `TutorialService.lua` are:

- `script.Parent.TutorialSignals` → the sibling module (the two files
  must sit together in `ServerScriptService/Tutorial/`);
- `script.Parent.Parent.FunnelService` → the Analytics module at
  `ServerScriptService/FunnelService.lua`;
- `script.Parent.Parent.PlayerLogger.PlayerLogger` → the PlayerLogging
  module at
  `ServerScriptService/PlayerLogger/PlayerLogger.lua`.

If you do not want the Analytics and PlayerLogging systems, see
step 6.

---

## 2. Install the shared modules

| Library path | Roblox path | Used for |
|---|---|---|
| `Shared/Utilities/Signals.lua` | `ReplicatedStorage.Utility.Signals` | the bus primitive (`Signals.new()`) |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage.Utility.Debug` | every trace line |
| `Shared/Utilities/Remotes.lua` | `ReplicatedStorage.Utility.Remotes` | `Remotes.Names.TutorialState` / `.TutorialAction`, `Remotes.FireClient` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage.Types.SlotType` | `ArenaSlotIndexBase`, `State.Empty` |

`Remotes.lua` must expose these two names (add them to the `Names`
table if they are not there):

```lua
TutorialAction = 'TutorialAction',   -- C->S
TutorialState  = 'TutorialState',    -- S->C
```

---

## 3. Install the config modules

| Library path | Roblox path | Used for |
|---|---|---|
| `SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage.Config.Systems.Debug` | the `Debug` sync |
| your egg config | `ReplicatedStorage.Config.Creatures.Eggs` | `GetStarterRarity()` (see step 7) |
| your rarity config | `ReplicatedStorage.Config.Creatures.Rarity` | `RarityDefs.Order[1]` |

`RarityDefs.Order` must be an array of rarity id strings — the first
entry is the fallback starter rarity.

**No Wally packages are needed** for the tutorial itself.

---

## 4. Install the gameplay services it observes

The tutorial reads five services lazily. You need them to exist for
the tutorial to work at all:

| Roblox path | Methods used |
|---|---|
| `ServerScriptService.PlayerService` | `GetPlayerData(userId)`, `SetTutorial(userId, {...})` |
| `ServerScriptService.Egg.SpawnService` | `GetEgg(id)` → `{ model, state }` |
| `ServerScriptService.AnimalService` | `Get(id)` → `{ model }` |
| `ServerScriptService.Base.SlotService` | `FindSlotByOccupant(animalId)` → `{ id }` |
| `ServerScriptService.BaseService` | `GetPlayerBase(userId)` → `{ id, arenaSlots }` |
| `ServerScriptService.Base.BaseLockService` | `IsLocked(baseId)` (only used by the recovery sweep) |

`_services()` returns `false` unless **all five** resolve, and the
tutorial then does nothing.

`PlayerService` must implement the tutorial profile field:

```lua
profile.Data.Tutorial = {
    Completed = false,
    Step = 'BuyEgg',
    EggId = nil,
    AnimalId = nil,
}
```

and

```lua
function PlayerService.SetTutorial(userId, { Completed, Step, EggId, AnimalId }) end
```

---

## 5. Wire the signal bus into your gameplay services

Each gameplay service fires the bus **exactly once per committed
action**. The tutorial is a pure observer — it must never be required
by a gameplay service (that would risk a require cycle).

```lua
-- ServerScriptService/Egg/…
local TutorialSignals = require(game:GetService('ServerScriptService').Tutorial.TutorialSignals)

-- after the purchase is committed
TutorialSignals.Fire('EggPurchased', { UserId = player.UserId, EggId = eggId })
```

The ten channels and their payloads:

| Channel | Payload |
|---|---|
| `EggPurchased` | `{ UserId: number, EggId: string }` |
| `EggPlaced` | `{ EggId: string, OwnerUserId: number?, SlotId: string }` |
| `EggHatched` | `{ UserId: number, EggId: string, AnimalId: string }` |
| `AnimalPickedUp` | `{ UserId: number, AnimalId: string }` |
| `AnimalPlaced` | `{ UserId: number, AnimalId: string, SlotId: string }` |
| `ArenaStarted` | `{ UserId: number }` |
| `ArenaEnded` | `{ UserId: number }` |
| `ArenaCancelled` | `{ UserId: number }` |
| `AnimalUpgraded` | `{ UserId: number, AnimalId: string, NewLevel: number }` |
| `BaseLocked` | `{ UserId: number, BaseId: string }` |

`Fire` never throws and is a no-op when nobody listens — so it is safe
to call from a hot path.

**The ids in the payload are load-bearing.** The tutorial validates
them against its tracked state; a wrong id means the chain does not
advance.

---

## 6. Bootstrap

```lua
local ServerScriptService = game:GetService('ServerScriptService')
local Players = game:GetService('Players')

local TutorialService = require(ServerScriptService.Tutorial.TutorialService)

-- in your boot sequence, after the remotes exist and PlayerService.Init()
TutorialService.Init()
TutorialService.Start()

Players.PlayerAdded:Connect(function(player)
    -- ... your own join pipeline: load the profile, restore the base ...
    task.defer(function()
        TutorialService.ResumeForPlayer(player)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    TutorialService.ForgetPlayer(player.UserId)
end)
```

**`ResumeForPlayer` must run after the profile has loaded.** If it
runs earlier, `profile.Tutorial` is empty and the player's persisted
progress is overwritten with `BuyEgg`.

### If you are not installing Analytics / PlayerLogging

`TutorialService.lua` requires both at load time. Either copy those
two systems too, or edit the two `require` lines and the two call
sites:

```lua
-- remove:
local FunnelService = require(script.Parent.Parent.FunnelService)
local PlayerLogger  = require(script.Parent.Parent.PlayerLogger.PlayerLogger)

-- and guard the call sites (both are already inside pcall, so a
-- nil module would error inside the pcall and be swallowed):
FunnelService:LogStep(...)
PlayerLogger.LogMilestone(...)
```

The cleanest option is to install the Analytics and PlayerLogging
systems — both are self-contained and both are documented in this
library.

---

## 7. Tune the config

Open `Config.lua` in this folder for a commented copy of every
tunable. The service does **not** read that file; the values live as
literals in `TutorialService.lua`:

| Line | Literal | Default |
|---|---|---|
| 74 | `TutorialService.TAG` | `'TutorialTarget'` |
| 90 | `BeamAssetId()` | `14403995847` |
| 1060 | the sweep accumulator check | `1` second |

### Add `GetStarterRarity()` to your egg config

The shipped code calls `EggConfig.GetStarterRarity()` inside a `pcall`.
**That function does not exist in the Brainrot Arena codebase**, so
the call silently fails and the tutorial always falls back to
`RarityDefs.Order[1]` (`'Common'`).

The result is correct today, but it comes from the rarity *display
order*, not from a price scan. Add the helper to make the contract
real:

```lua
-- ReplicatedStorage/Config/Creatures/Eggs.lua
function Eggs.GetStarterRarity(): string
    local bestRarity: string? = nil
    local bestPrice: number = math.huge
    for rarity, price in pairs(Eggs.Price) do
        if type(price) == 'number' and price < bestPrice then
            bestPrice = price
            bestRarity = rarity
        end
    end
    return bestRarity or Rarity.Common
end
```

---

## 8. Write the client controller

The server's contract with the client is:

1. **Listen** for the `TutorialState` RemoteEvent.
2. **Read** `Step`, `EggId`, `AnimalId`, `SlotId`, `BaseId`,
   `StarterEggRarity`.
3. **Find** the target model with
   `CollectionService:GetTagged('TutorialTarget_<userId>')`.
4. **Draw** a beam/arrow at it and the HUD prompt for the step.
5. **Send** `{ Action = 'State' | 'Continue' | 'Skip' }` on the
   `TutorialAction` RemoteEvent.

The Brainrot Arena reference implementation is
`ReusableSystems/Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/TutorialController.lua`
— copy that system in, or write your own.

**The tag name rule must match exactly:** `'TutorialTarget_' ..
tostring(userId)`.

### Beam asset

The server publishes the Beam template to
`ReplicatedStorage.TutorialBeamTemplate` via `InsertService:LoadAsset`.
Two options:

- **Use the shipped asset id** (`14403995847`) — it must be public to
  your experience.
- **Author your own** `TutorialBeamTemplate` in `ReplicatedStorage`
  in Studio. The publisher then skips the load entirely (it returns
  early when the name already exists), and the client uses your
  instance.

The client must handle **both**: a loaded template and a
self-built fallback beam.

### Audio

The **client** plays the step sting, once per real step change, on the
`TutorialState` push. The server never calls `:Play()` on tutorial
audio — an earlier server-side `PlayerGui` clone design was deleted
precisely to avoid double-playing.

---

## 9. Smoke test

1. **Start the server.** No errors in the Output window.
2. **Flip `DebugConfig.ServerDebug = true`** in
   `ReplicatedStorage.Config.Systems.Debug` and restart.
3. **Join.** Expect these console lines:
   ```text
   [TS] TutorialService initialized
   [TS] TutorialService started
   [TutorialEgg] player=<name> lowestEgg=Common tutorial target initialized step=BuyEgg
   [TS] resumed { userId = ..., step = BuyEgg }
   [FUNNEL] step ... funnel=Onboarding step=TutorialStarted n=1
   ```
   The `[TutorialEgg]` line proves the starter rarity was resolved and
   that **your** player's state object was created.
4. **Check the tag.** With the client connected, run
   ```lua
   print(game:GetService('CollectionService'):GetTagged('TutorialTarget_' .. player.UserId))
   ```
   It should be empty at `BuyEgg` (no egg yet) and hold the egg model
   after a purchase.
5. **Buy an egg.** Expect:
   ```text
   [TS] advanced { userId = ..., step = WaitForEgg, egg = <eggId>, ... }
   [TutorialEgg] player=<name> purchased tutorial eggId=<eggId>
   ```
   and the client to beam at **your** egg.
6. **Check the identity chain.** With two players in the server, have
   both buy an egg. Each must track their **own** egg id — the
   `[TutorialEgg]` lines must show different ids.
7. **Place the egg, hatch it, pick the animal up, place it in an
   ARENA slot.** Each transition must log `[TS] advanced` with the
   next step. A placement in a **non-arena** slot must NOT advance.
8. **Start and end an arena.** Expect `ArenaStarted` then
   `ArenaEnded`.
9. **Press Continue.** Expect `UpgradeAnimal`. Pressing Continue
   **outside** `ArenaEnded` must do nothing (the server gates it).
10. **Upgrade the tracked animal.** Expect `LockBase`. Upgrading a
    *different* animal must NOT advance.
11. **Lock your base.** Expect:
    ```text
    [TS] completed { userId = ... }
    [FUNNEL] step ... funnel=Onboarding step=TutorialCompleted n=7
    ```
    and a Discord milestone embed (PlayerLogging).
12. **Rejoin.** The tutorial must NOT restart. You should see
    `[TS] resumed { step = Completed }` and no `TutorialStarted`
    funnel event.
13. **Test the skip.** On a fresh account, send
    `{ Action = 'Skip' }` on `TutorialAction`. Expect
    `[TS] skipped`, a `TutorialSkipped` funnel event, **no** Discord
    milestone, and the tutorial gone on rejoin.
14. **Test the recovery sweep.** With a player mid-tutorial, destroy
    their tracked egg model in Studio. Within a second the sweep
    should re-derive the step; if the record is truly gone, expect
    the loud warning:
    ```text
    [TS] WARN recovery fell back to BuyEgg (must stay exceptional)
    ```
15. **Test the missing Beam asset.** Temporarily set
    `BeamAssetId()` to `0`. Restart. Expect the exact Roblox load
    error in the output and a white fallback beam on the client.

---

## 10. Optional: use the shipped spec

`Tests/TutorialService.spec.lua` is a TestEZ spec with **40 cases**.

**It cannot run standalone.** It requires:

- `StarterPlayer.StarterPlayerScripts.TutorialController` — from the
  **ClientPresentation** system, not from Tutorials;
- `Eggs.GetStarterRarity()` — which does not exist in the shipped
  egg config, so line 581 errors.

To run it you must copy the ClientPresentation system in and add the
`GetStarterRarity()` helper (step 7).

Copy the spec into your test tree (for example
`src/Tests/ServerScriptService/TestEZTests/TutorialService.spec.lua`)
and run the TestEZ runner. See `ReusableSystems/Tests/README.md`.
