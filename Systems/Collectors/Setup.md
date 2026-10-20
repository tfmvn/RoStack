# Collectors — Setup

How to install the Collectors system into a new Rojo project.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Dependencies.md](Dependencies.md)

---

## 1. Copy the files

| From this library | To in your Rojo project |
|---|---|
| `Source/ServerScriptService/Base/CollectorArrival.lua` | `ServerScriptService/Base/CollectorArrival.lua` |
| `Source/ServerScriptService/Base/CollectFeedback.lua` | `ServerScriptService/Base/CollectFeedback.lua` |

Plus the modules they require (see
[Dependencies.md](Dependencies.md)):

| Required path | From | To |
|---|---|---|
| `ServerScriptService.Egg.HoverMath` | **EggsAndHatching** | `ServerScriptService/Egg/HoverMath.lua` |
| `ServerScriptService.Egg.Constants` | **EggsAndHatching** | `ServerScriptService/Egg/Constants.lua` |
| `ServerScriptService.Egg.SpawnService` | **EggsAndHatching** | `ServerScriptService/Egg/SpawnService.lua` |
| `ServerScriptService.StandPresentation` | **BasesAndSlots** | `ServerScriptService/StandPresentation.lua` |
| `ServerScriptService.EconomyService` | **Economy** | `ServerScriptService/EconomyService.lua` |
| `ServerScriptService.Base.NotificationService` | **Notifications** | `ServerScriptService/Base/NotificationService.lua` |
| `ServerScriptService.Tutorial.TutorialSignals` | **Tutorials** | `ServerScriptService/Tutorial/TutorialSignals.lua` |
| `ReplicatedStorage.Types.SlotType` | **Shared** | `ReplicatedStorage/Types/SlotType.lua` |
| `ReplicatedStorage.Types.TransactionReason` | **Shared** | `ReplicatedStorage/Types/TransactionReason.lua` |
| `ReplicatedStorage.Utility.Validation` | **Shared** | `ReplicatedStorage/Utility/Validation.lua` |
| `ReplicatedStorage.Utility.Debug` | **Shared** | `ReplicatedStorage/Utility/Debug.lua` |
| `ReplicatedStorage.Utility.BigNumber` | **Shared** | `ReplicatedStorage/Utility/BigNumber.lua` |
| `ReplicatedStorage.Utility.StandResolver` | **Shared** | `ReplicatedStorage/Utility/StandResolver.lua` |
| `ReplicatedStorage.Utility.AudioGroups` | **Shared** | `ReplicatedStorage/Utility/AudioGroups.lua` |
| `ReplicatedStorage.Config.Systems.Debug` | **SharedUtilities** | `ReplicatedStorage/Config/Systems/Debug.lua` |
| `ReplicatedStorage.Config.Presentation.Audio` | **SharedUtilities** | `ReplicatedStorage/Config/Presentation/Audio.lua` |
| `ReplicatedStorage.Config.World.Bases` | **BasesAndSlots** | `ReplicatedStorage/Config/World/Bases.lua` |

### Rojo mapping

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "Utility": {
        "$path": "src/ReplicatedStorage/Utility"
      },
      "Types": {
        "$path": "src/ReplicatedStorage/Types"
      },
      "Config": {
        "$path": "src/ReplicatedStorage/Config"
      }
    },

    "ServerScriptService": {
      "$className": "ServerScriptService",
      "Base": {
        "$path": "src/ServerScriptService/Base"
      },
      "Egg": {
        "$path": "src/ServerScriptService/Egg"
      },
      "Tutorial": {
        "$path": "src/ServerScriptService/Tutorial"
      }
    },

    "ServerStorage": {
      "$className": "ServerStorage",
      "Assets": {
        "$path": "src/ServerStorage/Assets"
      }
    }
  }
}
```

**Folder names matter.** Note especially:

- `StandPresentation.lua` must be **directly** under
  `ServerScriptService` (the require is
  `script.Parent.Parent.StandPresentation`).
- `NotificationService.lua` must be under `ServerScriptService/Base`
  (the require is `script.Parent.NotificationService`).
- `TutorialSignals.lua` must be under `ServerScriptService/Tutorial`.
- `HoverMath.lua`, `Constants.lua` and `SpawnService.lua` must be
  under `ServerScriptService/Egg`.

If you port only `CollectFeedback` (and not `CollectorArrival`), you
only need the `ReplicatedStorage` side plus `StandResolver` and
`AudioGroups` — it has **no** `ServerScriptService` dependency.

---

## 2. Third-party packages

**None.** Neither module uses a third-party package.

`CollectorArrival` reaches the profile through the injected
`refs.playerService`, so you need whatever profile library your game
already uses — but it is not a dependency of these files.

---

## 3. Configuration to tune

These modules **own no config**. Their tunables are:

| Key | Where | Default | What it does |
|---|---|---|---|
| `Bases.Collector.Feel.PressFraction` | `Config/World/Bases.lua` | `0.45` | Fraction of the live Base↔PressPart gap the button travels. |
| `Bases.Collector.Feel.MinPressTravel` | same | `0.05` | Below this projected gap the press is skipped (SFX/VFX still play). |
| `Bases.Collector.Feel.PressSeconds` | same | `0.05` | Down-tween duration. |
| `Bases.Collector.Feel.HoldSeconds` | same | `0.05` | Hold at the bottom before the release. |
| `Bases.Collector.Feel.ReleaseSeconds` | same | `0.1` | Up-tween duration. |
| `Bases.Collector.Feel.VfxSurfaceLift` | same | `0.25` | Extra lift above the button's top surface so particles escape the mesh. |
| `Bases.Collector.Feel.VfxCleanupPadding` | same | `0.75` | Added to the longest emitter lifetime for the Debris cleanup. |
| `Bases.Collector.Feel.VfxCleanupMin` | same | `1.0` | Minimum Debris lifetime. |
| `Bases.Collector.Feel.VfxCleanupMax` | same | `5.0` | Maximum Debris lifetime. |
| `Audio.Collect.PoolSize` | `Config/Presentation/Audio.lua` | `4` | The per-player SFX pool bound. |
| `Debug.Audio.Enabled` | `Config/Systems/Debug.lua` | `false` | Gates the extra `collect resolve=…` log line. Audio always plays. |

If you are porting **only** `CollectFeedback`, you can copy the
`Bases.Collector.Feel` block and the `Audio.Collect` block into a
config module of your own — nothing else reads them.

---

## 4. Bootstrap sequence

### `CollectorArrival`

**There is nothing to bootstrap.** It is invoked by the flight
controller:

```lua
-- In your FlightController._onComplete, at t >= 1:
local CollectorArrival = require(ServerScriptService.Base.CollectorArrival)
CollectorArrival.OnArrival(egg, egg._refs)
```

`egg._refs` must be the table
`{ playerService, baseService, animalService, slotService }`. If you
build your own spawn service, **wire `_refs` at spawn time** — the
arrival path reads `refs.playerService` and `refs.slotService` from it.

### `CollectFeedback`

```lua
local CollectFeedback = require(ServerScriptService.Base.CollectFeedback)

-- Optional: Init() is an empty function.
CollectFeedback.Init()

-- On join (pre-create the SFX pool):
CollectFeedback.Warm(player)

-- On leave:
CollectFeedback.ForgetPlayer(player.UserId)

-- On a successful claim commit (after AddMoney succeeds and the pool
-- zeroes):
CollectFeedback.Play(player, slot)
```

### The claim call site

`CollectFeedback.Play` must be called **only on the success branch** —
after the money has been added and the pool has zeroed. If you call it
before the commit, the player sees the feedback for a claim that then
fails.

```lua
-- In your IncomeService.TryCollect:
local ok = EconomyService.AddMoney(userId, amount, TransactionReason.Income)
if not ok then return false end
-- pool zeroed here
CollectFeedback.Play(player, slot)
return true
```

---

## 5. Studio assets to author

### 5a. The CashClaim SFX

```text
ServerStorage
└── Assets
    └── Sfx
        └── CashClaim      -- a Sound, or a container with a Sound inside
```

Short sting, `Looped = false`. The server copies `SoundId`, `Volume`,
`PlaybackSpeed`, `RollOffMinDistance`, `RollOffMaxDistance` and
`EmitterSize` from it into the player's pool members, and stamps them
into the global SFX `SoundGroup`.

### 5b. The CashClaim VFX

```text
ServerStorage
└── Assets
    └── Vfx
        └── CashClaim      -- an Attachment, or a container with an
                           -- Attachment inside
```

- Give every `ParticleEmitter` an **`EmitCount` attribute** (a number).
  It is used **exactly** — never scaled, never normalized. Without it
  the emitter fires `Emit(0)`, i.e. nothing.
- The attachment's authored local offset is **ignored** — the burst is
  re-anchored above the button's live top surface.
- `PointLight` / `SpotLight` / `SurfaceLight` / `Beam` descendants are
  switched on for the burst lifetime.
- `Sound` descendants inside the VFX also play.

### 5c. The stand button

```text
Workspace
└── Map
    └── Bases
        └── Base_<n>
            └── AnimalStands
                └── Stand<k>
                    └── Button
                        ├── Base          -- BasePart
                        └── PressPart     -- BasePart
```

`StandResolver` resolves these by name (`Button` / `Base` /
`PressPart`). A missing `Base` means **no press** — the SFX and VFX
still fire.

The press travel is derived from the **live** gap between the two, so
you do not have to match any hardcoded dimension.

**No Collector-specific workspace part is needed.** The claim button
part is read from the **slot record** (`slot.cashCollector`), and the
stand from `slot.stand`.

---

## 6. The client side

Neither module needs a client script.

- The SFX is a `Sound` the **server** creates in the client's
  `PlayerGui` (`CashClaimPool/CashClaim1..4`). The client hears it
  automatically.
- The VFX is a server-side clone in the workspace; clients see it by
  normal replication.
- The press is a server-side `TweenService` tween on a replicated
  part.

If you want the claim button to show a *label* (the amount), author a
`SurfaceGui` on the `PressPart` — that is the `StandResolver` display
convention, not a `CollectFeedback` concern.

---

## 7. Smoke test

### `CollectorArrival`

1. **Module loads.** Start the server. If you see a require failure
   for `ServerScriptService.EconomyService`, that module must exist
   even if you never refund.
2. **Tier 1 (normal arrival).** Buy an egg. It flies for ~7 seconds
   and lands on the reserved slot. The egg should sit **bottom-flush**
   on the slot's top surface, in the slot's rotation, and the slot
   should become `Occupied`. The stand should wobble slightly.
3. **Tier 1 leaves persistence alone.** Rejoin. Your egg should be
   restored to the same slot, with the same Id. No duplicate.
4. **Tier 2 (reservation gone).** Buy an egg, and **before it lands**,
   occupy the reserved slot with something else. The egg should land on
   a different free slot, and rejoin should restore it **there** (same
   Id, new `SlotId`) — **not** as a second egg.
5. **Tier 3 (base full).** Fill every slot in the base, then buy an
   egg. The flight should still complete, and on arrival you should
   get the "base full" toast, your **cash back**, and **no egg**.
   Rejoin: there should be **no phantom egg** and no leftover
   `Reserved` slot.
6. **Owner fallback.** Hard to trigger in-game; the spec covers it
   (owner resolved from the slot id when `ownerUserId` is missing).
7. **The occupy race.** Hard to trigger in-game; the spec covers it
   (the egg stays `Traveling`, and `_onArrived` does not fire).

### `CollectFeedback`

8. **The SFX.** Collect cash. You should hear the CashClaim sting.
   Collect **four times rapidly** — all four should be audible
   (overlapping, not truncated). This is the pool round-robin.
9. **The VFX.** You should see a burst **above** the button, not
   inside it. If the particles are invisible, the attachment is
   occluded by the button mesh — check that the asset has a
   `ParticleEmitter` with an `EmitCount` attribute.
10. **The press.** The button should dip toward `Base` and return
    exactly to rest. Spam the button: it must **not** drift, and it
    must never end up stuck below rest.
11. **A degenerate button.** If your `Base` is level with or above
    the `PressPart`, there should be **no press** — but the SFX and
    VFX should still play.
12. **Missing assets.** Delete (temporarily) the
    `ServerStorage.Assets.Vfx.CashClaim` asset. Collect cash: you
    should hear the SFX, see no VFX, and see exactly **one** warn
    (`'CashClaim VFX Attachment missing — claims run without VFX'`),
    not one per claim.
13. **The warm pool.** On join, your `PlayerGui` should contain a
    `CashClaimPool` folder with 4 `Sound` children.

### Running the specs

`Tests/CollectorArrival.spec.lua` and `Tests/CollectFeedback.spec.lua`
both require the shared `Tests/_Helpers.lua` and **Roblox Studio**.
See `../../Tests/README.md`.
