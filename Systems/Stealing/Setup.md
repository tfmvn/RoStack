# Stealing — Setup

Installing the Stealing system into a **new** Rojo project. Every path
below is the destination Roblox path; the library's `Source/` tree
mirrors it, so the `require` calls resolve unchanged.

This system is **not standalone.** It is a thin, security-critical
transaction layer over four other systems (Carry, Inventory, BasesAndSlots,
Animals/EggsAndHatching) plus the profile authority. If any of those are
missing, the require at load time fails and the module never loads.

---

## 1. Copy the files

| From the library | To your Rojo project | Roblox path |
|---|---|---|
| `Systems/Stealing/Source/ServerScriptService/Steal/StealService.lua` | `src/ServerScriptService/Steal/StealService.lua` | `ServerScriptService.Steal.StealService` |
| `Systems/Stealing/Source/ReplicatedStorage/Config/World/Stealing.lua` | `src/ReplicatedStorage/Config/World/Stealing.lua` | `ReplicatedStorage.Config.World.Stealing` |
| `Systems/Stealing/Tests/StealService.spec.lua` | `src/Tests/ServerScriptService/TestEZTests/StealService.spec.lua` | (spec) |

The `ReplicatedStorage/Config/World/Stealing.lua` file is also mirrored,
documented, in [`Config.lua`](Config.lua) at the root of this system
folder. The **copy** in `Source/` is the one that ships; `Config.lua` is
the annotated reference.

### Shared leaves this system requires

From `ReusableSystems/Shared/`:

| From the library | To your Rojo project | Roblox path |
|---|---|---|
| `Shared/Types/SlotType.lua` | `src/ReplicatedStorage/Types/SlotType.lua` | `ReplicatedStorage.Types.SlotType` |
| `Shared/Utilities/Validation.lua` | `src/ReplicatedStorage/Utility/Validation.lua` | `ReplicatedStorage.Utility.Validation` |
| `Shared/Utilities/RichTextFormatter.lua` | `src/ReplicatedStorage/Utility/RichTextFormatter.lua` | `ReplicatedStorage.Utility.RichTextFormatter` |
| `Shared/Utilities/Debug.lua` | `src/ReplicatedStorage/Utility/Debug.lua` | `ReplicatedStorage.Utility.Debug` |
| `Shared/Utilities/AudioGroups.lua` | `src/ReplicatedStorage/Utility/AudioGroups.lua` | `ReplicatedStorage.Utility.AudioGroups` |
| `Shared/Utilities/StudioTestMode.lua` | `src/ReplicatedStorage/Utility/StudioTestMode.lua` | `ReplicatedStorage.Utility.StudioTestMode` (needed by `Validation` / `SlotType`) |
| `Shared/Utilities/BigNumber.lua` | `src/ReplicatedStorage/Utility/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` (needed by `Validation`) |
| `Shared/Types/RarityType.lua` | `src/ReplicatedStorage/Types/RarityType.lua` | `ReplicatedStorage.Types.RarityType` (needed by `Validation`) |
| `Shared/CommonModules/Remotes.lua` | `src/ReplicatedStorage/Utility/Remotes.lua` | `ReplicatedStorage.Utility.Remotes` (needed by the client controllers) |

Note on the library's shared layout: `Shared/Utilities/` and
`Shared/CommonModules/` both land under `ReplicatedStorage.Utility.*` in
the original game — the two folders merge into the same destination.

### Config modules owned by OTHER systems that this one reads

| From the library | To your Rojo project | Roblox path |
|---|---|---|
| `Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `src/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage.Config.World.Prompts` |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/Audio.lua` | `src/ReplicatedStorage/Config/Presentation/Audio.lua` | `ReplicatedStorage.Config.Presentation.Audio` |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `src/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage.Config.Systems.Debug` |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/UI.lua` | `src/ReplicatedStorage/Config/Presentation/UI.lua` | `ReplicatedStorage.Config.Presentation.UI` (needed by `RichTextFormatter` and `AnimalOverhead`) |
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | `src/ReplicatedStorage/Config/Creatures/Rarity.lua` | `ReplicatedStorage.Config.Creatures.Rarity` (needed by `RichTextFormatter`) |

### Systems you must also install

See [`Dependencies.md`](Dependencies.md) for the full list. Minimum set:

| Roblox path | System | Why it is load-bearing |
|---|---|---|
| `ServerScriptService.Carry.CarryRegistry` | Carry | The one carry state. |
| `ServerScriptService.Base.SlotService` | Inventory | The slot state machine and the atomic reservation. |
| `ServerScriptService.BaseService` | BasesAndSlots | Base ownership, the `collector` part, the base's slots. |
| `ServerScriptService.Animal.CarryController` | Animals | The carry behavior. |
| `ServerScriptService.Animal.CarryPrompts` | Animals | The Steal prompt + the callback registry. |
| `ServerScriptService.Animal.AnimalOverhead` | Animals | The `STOLEN` overhead. |
| `ServerScriptService.AnimalService` | Animals | `Get` (record lookup) and `SettleModelAtSlot`. |
| `ServerScriptService.Egg.SpawnService` | EggsAndHatching | `GetEgg`, `GetActiveContainer`, `InstallHatchPrompt`. |
| `ServerScriptService.Egg.HoverMath` | EggsAndHatching | `Settle` (egg seating math). |
| `ServerScriptService.StandPresentation` | BasesAndSlots | The egg's idle wobble bind/unbind. |
| `ServerScriptService.Base.NotificationService` | Notifications | The `Steal_*` message catalog. |
| `ServerScriptService.FunnelService` | Analytics | Optional — one analytics step, pcall-wrapped. |
| `ServerScriptService.Arena.ArenaService` | Arena | Optional — the raid lock. |
| `ServerScriptService.PlayerService` | PlayerData | The profile authority, injected via `SetPlayerService`. |

---

## 2. Install third-party packages (Wally)

This system needs **no** package of its own. Its transitive requirements are:

- `t` — required by `ReplicatedStorage.Utility.Validation`
  (`osyrisrblx/t@^2.2.1`).
- `ProfileService` — only if you also install the **PlayerData** system
  (the profile authority). Not required by this system directly.

```toml
# wally.toml
[package]
name = "yourgame/yourgame"
version = "0.1.0"
registry = "https://github.com/UpliftGames/wally-index"
realm = "shared"

[dependencies]
t = "osyrisrblx/t@^2.2.1"
```

Then:

```bash
wally install
```

and map `Packages/` into `ReplicatedStorage.Packages` in your
`default.project.json`:

```json
{
  "name": "yourgame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage",
      "Packages": { "$path": "Packages" }
    },
    "ServerScriptService": { "$path": "src/ServerScriptService" },
    "StarterPlayer": {
      "StarterPlayerScripts": { "$path": "src/StarterPlayer/StarterPlayerScripts" }
    },
    "StarterGui": { "$path": "src/StarterGui", "$ignoreUnknownInstances": true },
    "Workspace": { "$path": "src/Workspace", "$ignoreUnknownInstances": true }
  }
}
```

**No credentials, tokens, or webhook URLs are needed** by this system. The
analytics step goes through `FunnelService`, which owns its own transport
and its own configuration — if you do not install it, the steal still
works (the call is pcall-wrapped).

---

## 3. Author the Studio assets

### 3a. The robbery-alert SFX (strongly recommended)

```text
ServerStorage
└── Assets
    └── Sfx
        └── Stealing          (Sound)
```

- The name **must** match `Audio.StealAlertSoundName` in
  `ReplicatedStorage/Config/Presentation/Audio.lua` (currently `'Stealing'`).
- It may be a `Sound` directly, **or** any `Instance` that contains a
  `Sound` descendant — the code does `template:FindFirstChildWhichIsA('Sound', true)`
  when the template is not itself a `Sound`.
- The `SoundId` must not be empty. An empty `SoundId` is a silent no-op
  with a `Debug.Warn`.
- The clone is parented to the **victim's** `PlayerGui`, so only the
  robbed owner hears it. The clone is removed by `Debris` after
  `Sound.TimeLength + 0.5` (or `3` seconds if the length is unreadable).
- The `Sound` is assigned to the `GameSound` `SoundGroup` by
  `AudioGroups.AssignSfx` — make sure that group exists in `SoundService`
  (the bootstrap's `AudioGroups.EnsureGroups` creates it).

**If you skip it**, the steal still works end to end. You lose only the
victim's audio cue, and you get a `Debug.Warn` on every successful steal.

### 3b. The base `Collector` part (mandatory)

Every base the player owns must have a `Collector` `BasePart`:

```text
Workspace
└── Bases
    ├── Base_1
    │   ├── Collector     (BasePart, Anchored, CanTouch = TRUE)
    │   ├── Spawn
    │   ├── Slots
    │   │   ├── Slot1 ... SlotN
    │   └── ...
    └── Base_2 ... Base_N
```

- `Collector` **must** be a `BasePart` and **must** have `CanTouch = true`.
  A non-`BasePart` collector is silently skipped by `StealService.Start()`
  and the base can never complete a steal.
- The delivery proximity radius is
  `collector.Size.Magnitude / 2 + PromptConfig.CarryMaxDistance` (8), so a
  6×1×6 collector gives roughly 11 studs of reach.
- `BaseService.RegisterBases(Workspace)` must run **before**
  `StealService.Start()`.

### 3c. Optional / created at runtime

```text
Workspace
├── Animals
│   └── Recovering        (Folder) -- CREATED AT RUNTIME by the rollback
│                            tier-3 park, if it does not exist
└── EggArea
    └── ActiveEggs        (Folder) -- created by SpawnService if missing
```

`ActiveEggs` is the canonical home of a placed egg model. The completion
and rollback paths **re-home** the egg into it (the carry controller
reparents it into a per-player carried folder, so it would otherwise
linger in a stale folder).

### 3d. The client-side camera presentation (optional but recommended)

The FOV effect is a **client** feature and lives in the **ClientPresentation**
system, not here:

```text
StarterPlayer/StarterPlayerScripts/StealPresentationController.lua
```

It requires `ReplicatedStorage.Config.World.Stealing` (for
`StealPresentation.FOVMultiplier` / `FOVTweenTime`) and listens to the
`PlayerState` remote for `CarriedSteal == true` **and**
`CarriedKind == 'animal'`. The server never touches the field of view.

You also want the client `PromptOwnerFilter` (same system) — it is what
shows the `StealPrompt` to non-owners and hides it from the owner, on its
0.25 s tick. Without it, the Steal prompt stays **disabled** (the prompt
is installed fail-closed) and nobody can steal.

---

## 4. Configuration to tune

Open `ReplicatedStorage/Config/World/Stealing.lua` (or the annotated
consolidation in [`Config.lua`](Config.lua)):

- **`Stealing.Cooldown` (0.5 s)** — the anti-spam window between steal
  requests. `0` disables it.
- **`Stealing.AlertCleanupPad` (0.5 s)** — the tail added to the measured
  SFX length. **Not validated** by `Stealing.Validate()`.
- **`Stealing.AlertFallbackCleanup` (3 s)** — the SFX lifetime when
  `TimeLength` is unreadable.
- **`Stealing.StealSpeedMultiplier` (0.6)** — the thief's WalkSpeed
  multiplier while steal-carrying. `1.0` = no slow. Relative, so an
  admin-set speed survives the round trip.
- **`Stealing.StealPresentation.FOVMultiplier` (0.9)** and
  **`FOVTweenTime` (0.3 s)** — client-only camera presentation. Must
  narrow (`0 < x < 1`).

And in the **other** systems' configs:

- `ReplicatedStorage.Config.World.Prompts` — `Prompts.Steal.*` (the prompt
  label, hold duration, activation distance), `Prompts.CarryMaxDistance`
  (8), `Prompts.AnimalPickup.MaxActivationDistance` (8).
  **Watch out:** `Prompts.Steal.HoldDuration` is `2.5` seconds even though
  the config's own comment says *"INSTANT (hold 0)"*. The comment is
  stale; the value is what ships.
- `ReplicatedStorage.Config.Presentation.Audio` —
  `Audio.StealAlertSoundName` (`'Stealing'`), the asset name.
- `ReplicatedStorage.Config.Systems.Debug` — set `ServerDebug = true` to
  see the steal's `Debug.Log` / `Debug.Warn` output. It defaults to
  `false`, so production is silent. **If you set `Debug.Tags` to a
  non-empty whitelist, add `'ST'`** — the steal logs under the `'ST'`
  tag, and a whitelist without it drops every steal log line.
- `ReplicatedStorage.Config.Presentation.Messages` — the `Steal_*` catalog
  ids (`Steal_Success`, `Steal_DeliverySuccess`, `Steal_Cooldown`,
  `Steal_OwnAnimal`, `Steal_AlreadyCarrying`, `Steal_BaseFull`,
  `Steal_BaseLocked`, `Steal_TooFar`, `Steal_TargetBusy`,
  `Steal_TargetGone`) plus `General_Generic`. A missing id is **dropped**
  by the notification layer.

---

## 5. Bootstrap sequence

The exact order, from the source game's
`src/ServerScriptService/bootstrap.server.lua`:

```lua
-- top of the bootstrap, after the Remotes folder is created
local StealService = require(script.Parent.Steal.StealService)

-- ... other service inits ...

-- section 5: register Studio assets
BaseService.RegisterBases(Workspace)
EggService.RegisterCenter(Workspace)
BaseLockService.Init()

-- section 6: stealing (multiplayer)
StealService.SetPlayerService(PlayerService)
StealService.Init()
StealService.Start()

-- later, in the arena wiring
ArenaService.SetStealService(StealService)

-- section 6: Bat PvP — MUST come after the steal wiring
BatService.Init()
```

Rules:

- **`StealService.SetPlayerService(PlayerService)` first.** The profile
  authority is the only injected dependency, and `TryComplete` needs it to
  move the record. Without it the steal can start but can never complete.
- **`StealService.Init()` before any player can trigger a Steal prompt.**
  It wires the prompt callback into `CarryPrompts`.
- **`StealService.Start()` after `BaseService.RegisterBases(Workspace)`.**
  It arms one `Touched` connection per collector, and it only sees the
  bases that exist at the moment it runs. **A base registered later is
  never a delivery target** — there is no re-arm hook. `Start()` is
  idempotent, so you can call it again after a late `RegisterBases`.
- **`StealService.Start()` before players join** (or at least before a
  player tries to deliver).
- **`BatService.Init()` after `StealService.Init()` and
  `StealService.Start()`** — a bat hit calls
  `StealService.RollbackIfStealing`.
- **On player death**, the bootstrap must call
  `StealService.RollbackIfStealing(player.UserId, 'death')` **before** the
  generic carry recovery, and skip the generic recovery when it returns
  `true` (the generic path assumes the owner, which would misplace the
  record):

  ```lua
  hum.Died:Connect(function()
      if StealService.RollbackIfStealing(player.UserId, 'death') then
          requestRespawn(player)
          return
      end
      -- ... the normal AnimalService / EggService carry recovery ...
  end)
  ```

- **On owner leave / rebirth**, the owning system must call
  `StealService.RollbackStolenTarget(kind, uniqueId, reason)` **before**
  the base teardown, so the object lands home while its slot still exists:

  ```lua
  if stealSvc.RollbackStolenTarget('animal', uniqueId, 'owner-leaving') then
      -- the steal is already recovered; the normal sweep may continue
  end
  ```

- **`StealService.ForgetPlayer(userId)` is the intended leave cleanup, but
  the source game's bootstrap never calls it — and the function currently
  throws** (it reads `_thiefSpeed` before the local is declared, so it
  indexes a `nil` global). If you call it, fix the declaration first: move
  `local _thiefSpeed: { [number]: number } = {}` up next to
  `local _lastAttempt` (around line 115 of `StealService.lua`).

---

## 6. Smoke test

Run these in order in a **Studio multi-player test** (two players needed
from step 4 onward):

1. **Config validation.** From the command bar:
   ```lua
   print(require(game:GetService('ReplicatedStorage').Config.World.Stealing).Validate())
   ```
   It should print an empty table. A non-empty result names the bad field.
2. **Module load.** `require(game:GetService('ServerScriptService').Steal.StealService)`
   should not error. A missing dependency fails here, at load time.
3. **Wiring.** The bootstrap should log `[ST] Init: steal callback wired`
   and `[ST] Start: collector touch routing armed` (with
   `Debug.ServerDebug = true`). If `Start` logs nothing, check that
   `BaseService.RegisterBases` ran **before** it.
4. **The Steal prompt.** Player A owns an animal on their base. Player B
   walks up. B should see a **"Steal"** prompt after the client
   `PromptOwnerFilter` tick (up to 0.25 s). **A must not see it** — that
   is the fail-closed `Enabled = false` install plus the client filter.
   If B never sees it, the `PromptOwnerFilter` LocalScript is missing.
5. **The steal start.** B presses E. The server console should print
   `[ST] steal started kind=... uniqueId=... thief=... owner=...`. The
   animal should weld to B, B's `WalkSpeed` should drop to 60 %, and the
   animal's overhead should read `STOLEN` in red. A should receive the
   robbery toast and hear the SFX.
6. **The cooldown.** Press E again immediately — the server should print
   the `Steal_Cooldown` rejection (the window is 0.5 s).
7. **The delivery.** B walks to **B's own** `Collector` and touches it.
   The server should print `[ST] steal complete kind=... slotId=...`. The
   animal should now be seated in B's base, A's base slot should be empty,
   the profile record should have moved A → B **under the same id**, and
   B should get the `Steal_DeliverySuccess` toast. A should get the
   robbery toast a second time.
8. **Touch-only delivery.** Check that there is **no** Deliver prompt on
   the collector and that pressing E near it does nothing. The
   `Deliver` prompt surface was removed on purpose.
9. **Wrong collector.** B touches **A's** collector — nothing should
   happen. The touch handler only routes to the thief's own base.
10. **The rollback.** Start a steal, then kill B. The server should print
    `[ST] > RollbackCarried` and `[ST] < RollbackCarried: original slot`.
    The animal should be back in A's slot, with its Pickup and Steal
    prompts reinstalled, and B should be back at full WalkSpeed.
11. **Owner leave.** Start a steal, then have A leave. The animal should
    be recovered home before the sweep — the slot should end `Occupied` by
    the animal's id, and the profile should be preserved for a rejoin.
12. **The capacity guard.** Fill B's base completely, then try to steal.
    The request should be rejected with `Steal_BaseFull` and **nothing**
    should change on A's side (no reservation, no carry).

**Automated coverage:** `Systems/Stealing/Tests/StealService.spec.lua`
(1323 lines) covers the validation matrix, the atomicity of the slot
demotion, all three rollback tiers, the egg and animal transfers with
exact progression preservation, the failure atomicity of the delivery,
the owner-leave recovery, the prompt install, the place guard, and the
victim-text escaping.

The spec requires the shared `Tests/_Helpers.lua` and still requires
**Roblox Studio**. It fakes the profile layer through
`StealService.SetPlayerService` and uses the **real** bases, slots, and
models. The live-character `TrySteal` happy path is deliberately **not**
covered — it needs real `Player` instances and network ownership.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
