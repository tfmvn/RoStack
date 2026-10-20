# Carry — Dependencies

Exact module require paths (verbatim from the source), the systems Carry
needs, the remotes it uses, the Studio assets it assumes, and the exact
initialization order.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Setup.md](Setup.md) · [Config.lua](Config.lua)

---

## Module Requires

### `Source/ServerScriptService/Carry/CarryRegistry.lua`

```lua
local SlotType = require(script.Parent.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `Source/ServerScriptService/Carry/ToolLockService.lua`

```lua
local CarryRegistry = require(script.Parent.CarryRegistry)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `Source/ServerScriptService/Carry/ResetProtectionService.lua`

```lua
local CarryRegistry = require(script.Parent.CarryRegistry)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `Source/ServerScriptService/Carry/PlayerGrabService.lua`

```lua
local CarryRegistry = require(script.Parent.CarryRegistry)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `Source/ReplicatedStorage/Config/World/Prompts.lua`

```lua
local SlotType = require(script.Parent.Parent.Parent.Types.SlotType)
```

### Notes on the paths

- Two spellings of the same thing appear in the source:
  `script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug` (relative,
  from `ServerScriptService.Carry.*`) and `ReplicatedStorage.Utility.Debug`
  (absolute). Both resolve to the same module. The relative form breaks if
  you move the `Carry` folder up one level.
- `ReplicatedStorage.Utility.*` is where the shared `Utilities` folder
  lands in the game tree — `Remotes`, `Debug`, `Validation`, `BigNumber`.
  `ReplicatedStorage.Types.*` is where the shared `Types` folder lands —
  `SlotType`, `TransactionReason`.
- `Prompts.lua` uses `script.Parent.Parent.Parent.Types.SlotType`
  (no `ReplicatedStorage.` segment) because the config tree is nested
  deeper. If you relocate `Prompts.lua`, fix that path too.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **Shared Utilities** (`Remotes`, `Debug`) | `Remotes.FireClient` carries `CarryLock` / `ResetProtection`; `Debug` is the logging channel. | **No.** Without `Remotes` the two derived services cannot push; without `Debug` the requires fail. |
| **Shared Types** (`SlotType`) | `SlotType.OccupantKind.Egg` / `.Animal` are the only two legal `kind` values. `CarryRegistry.Set` rejects anything else with `KindMismatch`. | **No.** |
| **Inventory** (`SlotActionHandler`) | The server-side dispatcher that calls `CarryRegistry.Set` / `Clear` for Pickup / Place, and the consumer of `Prompts.Carry.Actions`. | **Yes for Carry itself** — Carry does not require it. **Required for the flow to be reachable.** |
| **Eggs** (`EggService`) | Mints the egg record and calls `CarryRegistry.Set` on grab. | Yes. |
| **Animals** (`AnimalService`) | Mints the animal record and calls `CarryRegistry.Set` on grab. | Yes. |
| **Stealing** (`StealService`) | Sets `item.steal`, which is what makes a carry a *steal* carry and changes the reset reason to `Stealing`. | Yes. |
| **PlayerData / PlayerService** | On death / leave / reset, calls `CarryRegistry.Clear` and `ForEach` to return the carried object. | **Effectively required** — without the recovery path a carried object is orphaned on leave. |
| **Combat** (`BatService` and other server-activated Tools) | Must gate on `CarryRegistry.IsCarrying` — the client-side `CarryLock` push is UX, not enforcement. | **Yes**, but the gate is required in any game that has a gameplay `Tool`. |
| **ClientPresentation** (`ToolLockController`, `CarryController`) | Consumes `CarryLock` / `ResetProtection` and performs the actual client-side tool lock and the head-weld visual. | Yes — the server works without them. |

**Nothing in this system requires another *game system*'s config.** Carry
owns its own config (`ReplicatedStorage/Config/World/Prompts.lua`).

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `CarryLock` | S → C | `{ Locked: boolean }` — `true` while the player is carrying anything. Pushed **on change only**. |
| `ResetProtection` | S → C | `{ Protected: boolean, Reason: string? }` — `Reason` is `'CarryingAnimal'`, `'CarryingEgg'`, or `'Stealing'`. Pushed **on change only**. |

Both names come from `Remotes.Names` in `Shared/CommonModules/Remotes.lua`
(lines 216–222). Both are fired with
`Remotes.FireClient(player, Remotes.Names.X, payload)`.

Notes:

- **There is no client → server remote in this system.** Carry is driven
  by the Inventory system's dispatcher, not by a Carry-owned remote.
- The `Reason` string `'Carrying'` can be emitted for an unrecognised
  carry kind (fail-closed), and it is **not** in
  `ResetProtectionService.Reason`. Clients must have a fallback branch.
- A push failure is logged, not fatal. The client mirror is corrected on
  the *next* change, not immediately.

---

## Profile Fields

**None.** Carry reads and writes **no** profile fields.

The carried object itself lives in the profile's owned-object lists
(`Brainrots` for animals, `LuckyBlocks` for eggs) — the registry holds
only a **live reference** to the record. `CarryRegistry` is not
persisted: a server restart clears every carry.

---

## Required Studio Assets

### ServerStorage (server-only, never replicated)

```text
ServerStorage
└── Assets
    └── Animations
        └── Player
            └── Grab      -- Animation, non-empty AnimationId
```

- Resolved by `FindFirstChild`, **never cloned**, and the `AnimationId`
  is **never hard-coded**.
- A missing asset is a **warn**, not an error: the carry still works,
  just without a pose.
- The clip is expected to be **upper-body-only** — see the
  `AnimationPriority.Action4` note in `MEMORY.md`.

### Workspace

**Carry itself needs no Workspace hierarchy.** The carry prompts are
built by the client-side prompt controllers from `Prompts`; this system
only holds state.

(For context, the surrounding flow does need
`Workspace.Map.Bases.Base_<n>.AnimalStands.Stand<k>` — see the
Inventory system's `Dependencies.md`.)

---

## External APIs

**None.** No DataStore, no HTTP, no MarketplaceService, no third-party
package, no API key or token. Carry is entirely in-memory and
server-local.

---

## Exact Initialization Order

```text
1.  ReplicatedStorage.Utility.Remotes is available, and the remote
    folder has been created and passed to Remotes.SetRemotes(...).
    -- Both derived services call Remotes.FireClient. If the folder
    -- does not exist yet, the FIRST push errors (pcall-guarded and
    -- logged, so it is survivable, but the client stays out of sync
    -- until the next change).

2.  CarryRegistry.Init()
    -- Resets carriedBy = {} AND _subscribers = {}.
    -- MUST run before any subscriber registers.

3.  ToolLockService.Init()
    -- Subscribes to CarryRegistry.OnChanged.

4.  ResetProtectionService.Init()
    -- Subscribes to CarryRegistry.OnChanged.

5.  PlayerGrabService.Init()
    -- Subscribes to CarryRegistry.OnChanged.
    -- Connects Players.PlayerAdded and Players.PlayerRemoving
    -- (guarded by a `playersWired` flag, so it is idempotent).
```

### Why this order

`CarryRegistry.Init()` clears the **subscriber list** as well as the
state. Any service that subscribes *before* step 2 loses its
subscription silently.

The three derived services each store their unsubscribe handle and
re-subscribe on their own `Init`, so a wrong order is survivable *for
them*. A **fourth** subscriber is not protected.

`PlayerGrabService` also needs the `Grab` animation to exist before a
carry starts, but a missing asset only warns — it is not an ordering
constraint.

### Player lifecycle

```text
Player added
  -> nothing required (the registry is keyed by userId and is created
     lazily on the first Set)

Player leaves (the recovery path, owned by PlayerData/PlayerService)
  -> CarryRegistry.Clear(userId)
       -> the change feed fires
       -> ToolLockService.Refresh      -> pushes CarryLock { Locked = false }
       -> ResetProtectionService.Refresh -> pushes ResetProtection { Protected = false }
       -> PlayerGrabService.syncGrab   -> stops the Grab track
  -> ToolLockService.ForgetPlayer(userId)
  -> ResetProtectionService.ForgetPlayer(userId)
```

### Character respawn

```text
CharacterAdded
  -> PlayerGrabService re-syncs the Grab track on the NEW character.
     A carry that survives a respawn plays its pose on the new body.
```
