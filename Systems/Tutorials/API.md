# Tutorials — API

Every public function of every module in this system. There are two
modules:

- `ServerScriptService.Tutorial.TutorialService`
- `ServerScriptService.Tutorial.TutorialSignals`

All functions are **server-only**. The client half is a separate
module (the ClientPresentation system's `TutorialController`).

---

## `ServerScriptService.Tutorial.TutorialService`

```lua
local TutorialService = require(game:GetService('ServerScriptService').Tutorial.TutorialService)
```

The module table is frozen (`table.freeze`) — you cannot add fields
to it at runtime.

---

### `TutorialService.NextStep(state: any, event: any): any?`

The transition function — **the heart of the system**. Pure: no
services, no I/O.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `state` | `any` | `{ Step = string, EggId = string?, AnimalId = string? }` |
| `event` | `any` | `{ Name = string, EggId = string?, AnimalId = string?, SlotId = string?, BaseId = string? }` |

**Returns**

A **new** state table `{ Step, EggId, AnimalId }`, or **`nil`** when
there is no valid transition.

**Failure modes — never throws**

The body is inside one `pcall`; a non-table `state` or `event`
returns `nil`.

**The full transition table**

| `state.Step` | `event.Name` | Guard | Result |
|---|---|---|---|
| `BuyEgg` | `EggPurchased` | `event.EggId` is a string | `{Step='WaitForEgg', EggId=event.EggId, AnimalId=nil}` |
| `WaitForEgg` | `EggPlaced` | `event.EggId == state.EggId` | `{Step='HatchEgg', EggId=state.EggId, AnimalId=nil}` |
| `HatchEgg` | `EggHatched` | `event.EggId == state.EggId` and `event.AnimalId` is a string | `{Step='PickUpAnimal', EggId=nil, AnimalId=event.AnimalId}` |
| `PickUpAnimal` | `AnimalPickedUp` | `event.AnimalId == state.AnimalId` | `{Step='PlaceAnimal', EggId=nil, AnimalId=state.AnimalId}` |
| `PlaceAnimal` | `AnimalPlaced` | `event.AnimalId == state.AnimalId` and the slot is an arena slot | `{Step='StartArena', EggId=nil, AnimalId=state.AnimalId}` |
| `StartArena` | `ArenaStarted` | — | `{Step='ArenaStarted', EggId=nil, AnimalId=state.AnimalId}` |
| `ArenaStarted` | `ArenaEnded` | — | `{Step='ArenaEnded', ...}` |
| `ArenaStarted` | `ArenaCancelled` | — | `{Step='StartArena', ...}` (**backwards**) |
| `ArenaEnded` | `ContinueConfirmed` | — | `{Step='UpgradeAnimal', ...}` |
| `UpgradeAnimal` | `AnimalUpgraded` | `event.AnimalId == state.AnimalId` | `{Step='LockBase', ...}` |
| `LockBase` | `BaseLocked` | — | `{Step='Completed', EggId=nil, AnimalId=nil}` |
| `Completed` | anything | — | `nil` (terminal) |

Anything not in the table returns `nil`.

**Example**

```lua
local next = TutorialService.NextStep(
    { Step = 'BuyEgg' },
    { Name = 'EggPurchased', EggId = 'egg-abc' }
)
-- { Step = 'WaitForEgg', EggId = 'egg-abc', AnimalId = nil }
```

---

### `TutorialService.DeriveResume(persisted: any, lookup: any): any`

Derive the resume state from the persisted state plus the live
registries. Pure apart from the injected `lookup`.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `persisted` | `any` | `{ Completed = boolean?, Step = string?, EggId = string?, AnimalId = string? }` |
| `lookup` | `any` | Three functions: `eggById(id)`, `animalById(id)`, `ownedUnhatchedEggId()`. |

**Returns**

`{ Step = string, EggId = string?, AnimalId = string? }`.

**Behaviour**

| Persisted step | Result |
|---|---|
| `Completed == true` | `{Step='Completed', EggId=nil, AnimalId=nil}` |
| `BuyEgg` | Adopts `ownedUnhatchedEggId()` → `{Step='HatchEgg', EggId=owned}`; otherwise stays `BuyEgg`. |
| `WaitForEgg` / `HatchEgg` | Keeps the step + egg id if `eggById` finds it; else adopts an owned egg (`HatchEgg`); else falls back to `BuyEgg`. |
| `PickUpAnimal` … `UpgradeAnimal` | Keeps the step + animal id if `animalById` finds it; else if `eggById` finds the egg → `{Step='HatchEgg', EggId=eggId}`; else adopts an owned egg; else falls back to `BuyEgg`. |
| `LockBase` | Keeps the step; keeps the animal id only if `animalById` finds it. |
| anything else | `{Step='BuyEgg', EggId=nil, AnimalId=nil}` |

**Failure modes — never throws.** The body is inside a `pcall`; on
failure the fallback `{BuyEgg, nil, nil}` is returned.

**Invariant:** it **never invents an animal** — an animal id survives
only when `lookup.animalById` returns it.

---

### `TutorialService.Init()`

Connect the bus, bind the remote, publish the Beam template.

**Kind:** server lifecycle. **Parameters:** none. **Returns:** nothing.

**Behaviour**

1. Returns immediately if `_started` (**idempotent**).
2. `_services()` — resolves and caches the five lazy services.
3. `task.spawn(_publishBeamTemplate)` — the asset fetch yields, so it
   never stalls boot.
4. Connects the ten signal channels (`EggPurchased`, `EggPlaced`,
   `EggHatched`, `AnimalPickedUp`, `AnimalPlaced`, `ArenaStarted`,
   `ArenaEnded`, `ArenaCancelled`, `AnimalUpgraded`, `BaseLocked`)
   to `_onBusEvent`.
5. Binds `TutorialAction.OnServerEvent` →
   `TutorialService.HandleAction`, via two 10-second `WaitForChild`
   calls inside a `pcall`.
6. `Debug.Log('TS', 'TutorialService initialized', {})`.

**Failure modes:** never throws. A missing `TutorialAction` remote
means client intents are never accepted — silently.

---

### `TutorialService.Start()`

Start the recovery sweep.

**Kind:** server lifecycle. **Parameters:** none. **Returns:** nothing.

**Behaviour**

- Guarded by `_tickConn ~= nil` (**idempotent**).
- Connects `RunService.Heartbeat`; accumulates `dt` and fires at
  **1 Hz**, calling `TutorialService.RecoverFor(userId)` for every
  entry in `_active`.
- `Debug.Log('TS', 'TutorialService started', {})`.

**Failure modes:** never throws.

**Note:** `Start()` does **not** call `Init()`. Calling it without
`Init()` starts a sweep with no channels connected.

---

### `TutorialService.ResumeForPlayer(player: Player)`

Join entry — start or resume the tutorial.

**Kind:** server lifecycle. **Parameters:** `player: Player`.
**Returns:** nothing.

**Behaviour**

1. The player must be a `Player` instance; `_services()` must
   succeed.
2. Reads the persisted state (`profile.Tutorial`, defaulting to
   `{Completed=false, Step='BuyEgg'}`).
3. If `persisted.Completed == true` → `_active[userId] = nil` and
   return. **A completed player never re-enters.**
4. `resumed = DeriveResume(persisted, lookup)`.
5. `_active[userId] = resumed`; writes it back to the profile;
   `_retargetTag(userId)`; `PublishTo(player)`.
6. If the resumed step is `BuyEgg` → the funnel logs
   `'TutorialStarted'`. **Mid-tutorial rejoins resume silently.**

**Failure modes:** never throws (the whole body is in a `pcall`).

**Ordering:** call this **after** the profile has loaded and the base
has been restored.

---

### `TutorialService.HandleAction(player: Player, payload: any)`

The client-intent handler.

**Kind:** server event. **Parameters:** `player: Player`,
`payload: any`. **Returns:** nothing.

**`payload` shape:** `{ Action = 'State' | 'Continue' | 'Skip' }`.

**Behaviour**

| Action | Effect |
|---|---|
| `'State'` | `PublishTo(player)` — re-pushes the snapshot. No gating. |
| `'Continue'` | Requires an active state. `NextStep(state, {Name='ContinueConfirmed'})` — which only transitions from `ArenaEnded`. The gate is structural. |
| `'Skip'` | Requires an active, non-completed state. Applies the `Completed` transition with `viaSkip = true`: the profile records `Completed = true`, the runtime entry is cleared, the tag is removed, the final snapshot is pushed, the funnel logs `'TutorialSkipped'`. |
| anything else | `Debug.Log('TS', 'unknown action ignored', ...)`. |

**Failure modes:** never throws. A non-`Player` argument returns
immediately; a nil payload is treated as an unknown action.

---

### `TutorialService.RecoverFor(userId: number)`

Re-validate a player's tracked ids and repair the step.

**Kind:** server recovery. **Parameters:** `userId: number`.
**Returns:** nothing.

**Behaviour**

1. `_active[userId]` must exist; `_services()` must succeed.
2. `resumed = DeriveResume({Step, EggId, AnimalId}, lookup)`.
3. **LockBase re-check:** if the resumed step is `LockBase`, reads
   `BaseLockService.IsLocked(base.id)`. If locked → the step becomes
   `Completed` immediately.
4. If anything changed → `_applyTransition(userId, resumed)`;
   otherwise `_retargetTag(userId)`.

**Failure modes:** never throws.

**The loud warning:** if the resumed step is `BuyEgg` and the previous
step was not, it logs
`Debug.Warn('TS', 'recovery fell back to BuyEgg (must stay
exceptional)', {...})`.

---

### `TutorialService.PublishTo(target: any)`

Push the `TutorialState` snapshot to a player.

**Kind:** server event. **Parameters:** `target: any` — a `Player`
instance **or** a `number` (userId). **Returns:** nothing.

**Returns** (via the remote)

```lua
{
    Step = 'BuyEgg',
    EggId = nil,
    AnimalId = nil,
    SlotId = nil,             -- only for PlaceAnimal / UpgradeAnimal
    BaseId = 'base-123',      -- profile.BaseId
    StarterEggRarity = 'Common',
}
```

**`SlotId` per step**

| Step | Source |
|---|---|
| `PlaceAnimal` | `_suggestArenaSlotId(userId)` — the first empty arena slot of the player's base, sorted by `arenaIndex`; falls back to the first slot. **A display suggestion only.** |
| `UpgradeAnimal` | `_slotIdOfAnimal(state.AnimalId)` — `SlotService.FindSlotByOccupant(animalId).id`. Needed because the animal's model is world-positioned and is not parented under its stand. |
| anything else | `nil` |

**Failure modes:** never throws (the body is in a `pcall`). A target
that is not a Player and not a number → nothing happens. A player with
no active state → nothing is sent.

---

### `TutorialService.GetStep(userId: number): string?`

The current step name.

**Parameters:** `userId: number`.
**Returns:** the step string, or **`nil`** when there is no active
tutorial for that user.

**Failure modes:** never throws.

---

### `TutorialService.GetState(userId: number): any?`

The current runtime state.

**Parameters:** `userId: number`.
**Returns:** a **copy** `{ Step, EggId, AnimalId }`, or **`nil`**.

**Note:** it is a copy — mutating it does not affect the service.

---

### `TutorialService.ForgetPlayer(userId: number)`

Drop a player's runtime state and highlight.

**Kind:** server lifecycle. **Parameters:** `userId: number`.
**Returns:** nothing.

**Behaviour**

- `_active[userId] = nil`.
- Removes that player's CollectionService tag from their own tracked
  instance only. **Other players keep theirs** — there is no global
  clear.

**Failure modes:** never throws.

**Note:** it does **not** write to the profile. The persisted state
survives a forget.

---

### `TutorialService.TagFor(userId: number): string`

The per-player CollectionService tag name.

**Parameters:** `userId: number`.
**Returns:** `'TutorialTarget_' .. tostring(userId)`.

**Failure modes:** never throws.

**Example**

```lua
TutorialService.TagFor(123)  --> 'TutorialTarget_123'
```

---

### `TutorialService.BeamAssetId(): number`

The InsertService asset id of the tutorial Beam template.

**Parameters:** none.
**Returns:** `14403995847`.

**Failure modes:** never throws.

---

### `TutorialService.StarterEggRarity(): string`

The canonical starter egg rarity — the same for every new tutorial
player.

**Parameters:** none.
**Returns:** a rarity id string.

**Behaviour**

1. `pcall` `EggConfig.GetStarterRarity()`.
2. If it returned a non-empty string → use it.
3. Else `pcall` `RarityDefs.Order[1]`.
4. Else the literal `'Common'`.

**Failure modes:** never throws.

**Note:** in the Brainrot Arena codebase `EggConfig.GetStarterRarity`
**does not exist**, so step 1 always fails and the function returns
`RarityDefs.Order[1]` = `'Common'`.

---

### `TutorialService.Step` (data)

The 11 step names:

```lua
{ BuyEgg = 'BuyEgg', WaitForEgg = 'WaitForEgg', HatchEgg = 'HatchEgg',
  PickUpAnimal = 'PickUpAnimal', PlaceAnimal = 'PlaceAnimal',
  StartArena = 'StartArena', ArenaStarted = 'ArenaStarted',
  ArenaEnded = 'ArenaEnded', UpgradeAnimal = 'UpgradeAnimal',
  LockBase = 'LockBase', Completed = 'Completed' }
```

### `TutorialService.TAG` (data)

`'TutorialTarget'` — the tag **prefix**. The full tag is
`TagFor(userId)`.

---

### Test seams

#### `TutorialService._TestSetState(userId: number, state: any?)`

Inject the runtime state.

**Parameters:** `userId: number`, `state: any?` — `{ Step, EggId,
AnimalId }`. A `nil` state removes the entry.

**Returns:** nothing.

#### `TutorialService._TestReset()`

Clear the runtime state.

**Clears:** `_active`, `_taggedByUser`, and `_tickAccum`.

**Does NOT clear:** `_started`, `_tickConn`, or the bus connections.

---

## `ServerScriptService.Tutorial.TutorialSignals`

```lua
local TutorialSignals = require(game:GetService('ServerScriptService').Tutorial.TutorialSignals)
```

Frozen module table.

---

### `TutorialSignals.Fire(name: any, payload: any)`

Publish a gameplay event on the bus.

**Kind:** server event. **Parameters:** `name: any` (a channel
string), `payload: any` (a table). **Returns:** nothing.

**Behaviour**

- A non-string or empty name → nothing happens.
- Otherwise `(channel):Fire(payload)`.

**Failure modes:** never throws (the whole body is in a `pcall`). It
never yields the caller and is a no-op when nobody listens.

**Payload shapes**

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

**Example**

```lua
TutorialSignals.Fire('AnimalUpgraded', {
    UserId = player.UserId,
    AnimalId = animalId,
    NewLevel = 7,
})
```

---

### `TutorialSignals.Connect(name: any, fn: (any) -> ()): RBXScriptConnection?`

Subscribe to a channel.

**Kind:** server event. **Parameters:** `name: any`, `fn: (any) -> ()`.
**Returns:** the `RBXScriptConnection`, or **`nil`** when the bus is
unavailable or the arguments are invalid.

**Behaviour**

- A non-string/empty name or a non-function `fn` → `nil`.
- Otherwise `(channel):Connect(fn)`.

**Failure modes:** never throws.

**Note:** the bus does **not** store the connection — the caller must
keep it if it wants to disconnect. The tutorial service never
disconnects.

---

### `TutorialSignals._TestReset()`

Drop all channels.

**Parameters / Returns:** none.

**Side effect:** `Debug.Log('TS', 'channels reset', {})`.

**Warning:** this invalidates any connection the tutorial service
already made — the service will then be listening to orphaned signal
objects.

---
