# Tutorials — MEMORY

Engineering notes for a future agent. Dense, factual, about the code as
it actually is.

---

## Purpose

A server-authoritative onboarding **guide layer**: it observes committed
gameplay actions through a signal bus and advances exactly one active
step per player. It implements no gameplay rules.

---

## How it actually works, step by step

### Two modules

`TutorialSignals.lua` — the bus. `TutorialService.lua` — the state
machine and the runtime.

Both are `table.freeze`d.

### The bus (`TutorialSignals`)

```lua
_channels: { [string]: any } = {}   -- name -> Signals.new() object
```

`_channel(name)` returns the existing channel or creates one with
`Signals.new()` inside a `pcall`. If the creation fails, `nil` is
returned and **the channel is not cached** — the next call retries.

`Fire(name, payload)` — rejects a non-string or empty name, then
`(channel):Fire(payload)`. The whole body is inside a `pcall` → never
throws, never yields the caller, and is a no-op when nobody listens.

`Connect(name, fn)` — rejects a non-string/empty name and a
non-function `fn`. Returns the `RBXScriptConnection`, or `nil` when
the bus is unavailable. **The connection is never stored by the bus** —
the caller must keep it (the Tutorial service does not; it never
disconnects).

`_TestReset()` — `table.clear(_channels)`.

### The channels and their payloads

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

### The transition table (`NextStep(state, event)`)

**Pure.** `state = { Step, EggId?, AnimalId? }`,
`event = { Name, EggId?, AnimalId?, SlotId?, BaseId? }`.

Returns a **new** state table, or `nil` for "no transition". The whole
body is inside a `pcall`; a non-table `state` or `event` returns `nil`.

| Current step | Event | Guard | Next step |
|---|---|---|---|
| `BuyEgg` | `EggPurchased` | `event.EggId` is a string | `WaitForEgg`, tracks `EggId` |
| `WaitForEgg` | `EggPlaced` | `event.EggId == state.EggId` | `HatchEgg` |
| `HatchEgg` | `EggHatched` | `event.EggId == state.EggId` **and** `event.AnimalId` is a string | `PickUpAnimal`, tracks `AnimalId`, **clears `EggId`** |
| `PickUpAnimal` | `AnimalPickedUp` | `event.AnimalId == state.AnimalId` | `PlaceAnimal` |
| `PlaceAnimal` | `AnimalPlaced` | `event.AnimalId == state.AnimalId` **and** `_isArenaSlotId(event.SlotId)` | `StartArena` |
| `StartArena` | `ArenaStarted` | — | `ArenaStarted` |
| `ArenaStarted` | `ArenaEnded` | — | `ArenaEnded` |
| `ArenaStarted` | `ArenaCancelled` | — | `StartArena` (**backwards**) |
| `ArenaEnded` | `ContinueConfirmed` | — | `UpgradeAnimal` |
| `UpgradeAnimal` | `AnimalUpgraded` | `event.AnimalId == state.AnimalId` | `LockBase` |
| `LockBase` | `BaseLocked` | — | `Completed` |
| `Completed` | anything | — | `nil` (terminal) |

**Invariants:**

- `EggId` is cleared the moment the animal id appears (from
  `HatchEgg` onwards).
- `AnimalId` is cleared on `Completed`.
- **There is no transition back to `BuyEgg`** from any later step. A
  hatch can never reset the chain.
- `ArenaCancelled` is the only backwards transition.
- Every step is reachable, and the chain has exactly one terminal.

`_isArenaSlotId(slotId)` — `slotId` must be a string; it parses the
trailing `:N` with `string.match(slotId, ':(%d+)$')` and returns true
when `N >= SlotType.ArenaSlotIndexBase` (1000).

### The resume derivation (`DeriveResume(persisted, lookup)`)

**Pure** apart from the injected `lookup`, which has three functions:

```lua
lookup.eggById(id: string): any?              -- the egg record, or nil
lookup.animalById(id: string): any?           -- the animal record, or nil
lookup.ownedUnhatchedEggId(): string?         -- an owned, interactable egg id
```

Logic:

1. `persisted.Completed == true` → `{Step = 'Completed', EggId = nil,
   AnimalId = nil}`.
2. `step = persisted.Step` (or `'BuyEgg'` if not a string).
3. Resolve `liveEgg = lookup.eggById(persisted.EggId)` and
   `liveAnimal = lookup.animalById(persisted.AnimalId)` — only when the
   id is a string.
4. Per step:
   - **`BuyEgg`** → if `ownedUnhatchedEggId()` returns a string, adopt
     it: `{Step = 'HatchEgg', EggId = owned}`. Otherwise stay
     `BuyEgg`. **This is the out-of-order grace.**
   - **`WaitForEgg` / `HatchEgg`** → if `liveEgg` exists, keep the step
     and the egg id. Otherwise adopt an owned egg (`HatchEgg`), else
     fall back to `BuyEgg`.
   - **`PickUpAnimal` / `PlaceAnimal` / `StartArena` / `ArenaStarted`
     / `ArenaEnded` / `UpgradeAnimal`** → if `liveAnimal` exists, keep
     the step and the animal id. **Else if `liveEgg` exists** → go back
     to `HatchEgg` with that egg id. Else adopt an owned egg
     (`HatchEgg`), else fall back to `BuyEgg`.
   - **`LockBase`** → keep the step. If `liveAnimal` exists keep the
     animal id, otherwise clear it. The lock state itself is re-read
     live by `RecoverFor`, not here.
   - anything else → the fallback `{BuyEgg, nil, nil}`.

**It never invents animals** — an animal id only survives if the live
lookup finds it.

### The runtime

```lua
_active: { [number]: any } = {}   -- userId -> { Step, EggId, AnimalId }
_taggedByUser: { [number]: Instance? } = {}
```

`_services()` lazily requires and caches five services:
`PlayerService`, `Egg.SpawnService`, `AnimalService`,
`Base.SlotService`, `BaseService`. It returns `true` only when **all
five** resolved. Each `require` is inside one `pcall`, so a single
failure aborts the whole resolution (the already-resolved ones stay
cached).

### `_onBusEvent(name, payload)`

1. The payload must be a table.
2. `userId = payload.UserId or payload.OwnerUserId` — must be a
   **number**. (`EggPlaced` uses `OwnerUserId`.)
3. `_active[userId]` must exist, else return — **the bus only affects
   players with an active tutorial**.
4. **Base-lock defence in depth**: for `BaseLocked`, if
   `payload.BaseId` is a string, the player's own base id is read from
   `BaseService.GetPlayerBase(userId).id`. If they differ → return.
   (If the own base id cannot be read, the event is **allowed**.)
5. `NextStep(state, {...})` → if non-nil, `_applyTransition`.

### `_applyTransition(userId, next, viaSkip?)`

1. `_active[userId] = next` — **even if the player instance is gone**
   (the runtime commit happens before the player lookup).
2. `_writePersisted(userId, next)` → `PlayerService.SetTutorial`.
3. `Players:GetPlayerByUserId(userId)`; if the player exists:
   - `_retargetTag(userId)` — move the CollectionService tag to the
     new tracked model;
   - `PublishTo(player)` — push the `TutorialState` snapshot.
4. `Debug.Log('TS', 'advanced', {...})`.
5. If the new step is `WaitForEgg`, a `TutorialEgg` trace line logs the
   player name and their actual egg id (proving per-player tracking).
6. If the new step is `Completed`:
   - `_active[userId] = nil` (the runtime entry is removed);
   - `_untagPlayer(userId)`;
   - `Debug.Log('TS', 'completed', ...)`;
   - the funnel logs `'TutorialSkipped'` when `viaSkip == true`, else
     `'TutorialCompleted'` **plus** `PlayerLogger.LogMilestone(player,
     'TutorialCompleted', nil)`.

### The tagging

`TutorialService.TagFor(userId)` → `'TutorialTarget_' .. userId`.

**Tags are per-player on purpose.** A shared `'TutorialTarget'` tag
would expose every player's tracked object to every client (each
client would beam at whoever was tagged last).

`_untagPlayer(userId)` removes the tag from **that player's own**
previously tagged instance only (`_taggedByUser[userId]`). There is
**no global clear** — one player's completion must not strip another
player's highlight.

`_retargetTag(userId)`:
1. `_untagPlayer(userId)`.
2. If there is no state → return.
3. `_modelForEgg(state.EggId)` if `EggId ~= nil`, else
   `_modelForAnimal(state.AnimalId)`.
   - `_modelForEgg` → `SpawnService.GetEgg(id).model`
   - `_modelForAnimal` → `AnimalService.Get(id).model`
4. If the model is an `Instance` **and** `model.Parent ~= nil` →
   `CollectionService:AddTag(model, TagFor(userId))` and
   `_taggedByUser[userId] = model`.

### The publish

`PublishTo(target)` — `target` may be a `Player` instance or a
`number` (userId). It resolves the player, reads `_active[userId]`
and fires the `TutorialState` remote with:

```lua
{
    Step = state.Step,
    EggId = state.EggId,
    AnimalId = state.AnimalId,
    SlotId = nil,          -- filled for two steps, see below
    BaseId = _baseIdOf(userId),
    StarterEggRarity = TutorialService.StarterEggRarity(),
}
```

`SlotId` is only populated for two steps:

- **`PlaceAnimal`** → `_suggestArenaSlotId(userId)`: the player's base
  slots are sorted by `arenaIndex`; the first `SlotType.State.Empty`
  slot id wins; if none is empty, the **first** slot id is used as a
  fallback. **A display suggestion only** — completion accepts *any*
  arena slot holding the tracked animal.
- **`UpgradeAnimal`** → `_slotIdOfAnimal(state.AnimalId)`:
  `SlotService.FindSlotByOccupant(animalId).id`. This is needed
  because the tracked animal's model is world-positioned and is **not**
  parented under its stand, so the client cannot climb from the tag
  to the stand's `MenuPart`.

`BaseId` comes from `profile.BaseId` via `PlayerService.GetPlayerData`.

### The recovery sweep

`Start()` connects `RunService.Heartbeat`. It accumulates `dt` and
fires at **1 Hz**, iterating `_active` and calling `RecoverFor(userId)`
for each. It is guarded by `_tickConn ~= nil` (idempotent).

`RecoverFor(userId)`:
1. `_active[userId]` must exist.
2. `_services()` must succeed.
3. `lookup = _makeLookup(userId)`.
4. `resumed = DeriveResume({Step, EggId, AnimalId}, lookup)`.
5. **LockBase re-check**: if the resumed step is `LockBase`, read
   `BaseLockService.IsLocked(base.id)`. If locked → the resumed step
   becomes `Completed` immediately.
6. If anything changed → `_applyTransition(userId, resumed)`;
   otherwise `_retargetTag(userId)`.

**The fallback warning:** if the resumed step is `BuyEgg` and the
previous step was **not** `BuyEgg`, a loud
`Debug.Warn('TS', 'recovery fell back to BuyEgg (must stay
exceptional)', {...})` is logged.

### The lookup (`_makeLookup`)

`eggById(id)` → `SpawnService.GetEgg(id)` — returns the record if it
is a table, even if the model is destroyed.

`animalById(id)` → `AnimalService.Get(id)` — same.

`ownedUnhatchedEggId()` → scans `profile.LuckyBlocks` rows for the
first one whose egg record is in state `'Available'`, `'Traveling'` or
`'Placed'` **and** whose `model` is an `Instance` with a non-nil
`Parent`. (Model liveness is required only for *adopting a
replacement* egg.)

**Record existence, not model liveness, decides "still relevant".** A
hatching egg has state `Opening` with a **destroyed model for ~5 s**
(`EggService` destroys it before the roulette); treating that as
"gone" is what used to reset `HatchEgg → BuyEgg` mid-hatch. An
arena-deployed animal's stand model may be parked while the record and
the fight are alive.

### The client intents

`HandleAction(player, payload)` — the whole body is inside a `pcall`.

- The player must be a `Player` **instance**.
- `action = payload.Action` (the payload must be a table).
- **`'State'`** → `PublishTo(player)`. No gating.
- **`'Continue'`** → `_active[userId]` must exist; then
  `NextStep(state, {Name = 'ContinueConfirmed'})`. Since
  `NextStep` only accepts `ContinueConfirmed` from the `ArenaEnded`
  step, the intent is **automatically gated** — a client cannot
  advance from any other step.
- **`'Skip'`** → `_active[userId]` must exist and must not already be
  `Completed`. Then `_applyTransition(userId, {Step = 'Completed'},
  true)` — a real completion (persisted `Completed`, runtime cleared,
  untagged, final snapshot pushed) plus
  `Debug.Log('TS', 'skipped', ...)`.
- anything else → `Debug.Log('TS', 'unknown action ignored', ...)`.

### The join entry

`ResumeForPlayer(player)`:
1. The player must be a `Player` instance.
2. `_services()` must succeed.
3. `persisted = _readPersisted(userId)` — `profile.Tutorial` with
   defaults `{Completed = false, Step = 'BuyEgg', EggId = nil,
   AnimalId = nil}` when the profile is missing.
4. If `persisted.Completed == true` → `_active[userId] = nil` and
   return. **A completed player never re-enters the tutorial.**
5. `resumed = DeriveResume(persisted, lookup)`;
   `_active[userId] = resumed`; `_writePersisted(userId, resumed)`;
   `_retargetTag(userId)`; `PublishTo(player)`.
6. Two trace logs.
7. If the resumed step is `BuyEgg` → the funnel logs
   `'TutorialStarted'`. **Mid-tutorial rejoins resume silently** — no
   fake restarts.

### The Beam template

`_publishBeamTemplate()` (spawned from `Init()`):
- If `ReplicatedStorage.TutorialBeamTemplate` already exists → return.
- `InsertService:LoadAsset(TutorialService.BeamAssetId())` inside a
  `pcall`. The **exact** Roblox error is printed (never swallowed) so
  a private/deleted/wrong-type asset is diagnosable.
- The loaded instance is renamed `TutorialBeamTemplate` and parented
  to `ReplicatedStorage`.
- A class-name census is logged.

It accepts **any** instance type (Model, MeshPart, Beam, Decal, …) —
the client inspects it and adapts.

### The starter rarity

```lua
function TutorialService.StarterEggRarity(): string
    -- pcall EggConfig.GetStarterRarity()
    -- -> pcall RarityDefs.Order[1]
    -- -> 'Common'
end
```

**In this codebase `EggConfig.GetStarterRarity` does not exist**, so
the first `pcall` fails and the function returns
`RarityDefs.Order[1]` = `'Common'`.

---

## Public API surface (exact)

```lua
-- TutorialService
TutorialService.Step            -- data: the 11 step names
TutorialService.TAG             -- data: 'TutorialTarget'
TutorialService.TagFor(userId: number): string
TutorialService.BeamAssetId(): number
TutorialService.StarterEggRarity(): string
TutorialService.NextStep(state: any, event: any): any?
TutorialService.DeriveResume(persisted: any, lookup: any): any
TutorialService.PublishTo(target: any)
TutorialService.RecoverFor(userId: number)
TutorialService.GetStep(userId: number): string?
TutorialService.GetState(userId: number): any?
TutorialService.HandleAction(player: Player, payload: any)
TutorialService.ResumeForPlayer(player: Player)
TutorialService.ForgetPlayer(userId: number)
TutorialService.Init()
TutorialService.Start()
TutorialService._TestSetState(userId: number, state: any?)
TutorialService._TestReset()

-- TutorialSignals
TutorialSignals.Fire(name: any, payload: any)
TutorialSignals.Connect(name: any, fn: (any) -> ()): RBXScriptConnection?
TutorialSignals._TestReset()
```

`TutorialService.GetState` returns a **copy**
`{ Step, EggId, AnimalId }`, not the live table.

`TutorialService.ForgetPlayer(userId)` clears `_active[userId]` and
untags that player — but it does **not** write to the profile. The
persisted state survives.

---

## Invariants the code enforces

1. **Exactly one active step per player.**
2. **Tracked ids must match.** Every id-bearing transition compares
   the event's id with the state's id.
3. **No transition back to `BuyEgg`** from `NextStep`.
4. **`Completed` is terminal.** `NextStep` returns `nil` for it;
   `ResumeForPlayer` refuses to re-enter for a completed player.
5. **`Continue` only advances from `ArenaEnded`** — enforced by the
   transition table, not by a separate check.
6. **The client never advances the chain on its own.** Only `Continue`
   (gated) and `Skip` (terminal) are client intents.
7. **Tags are per-player and never globally cleared.**
8. **The tutorial never implements gameplay.** It only observes.
9. **The tutorial never invents animals.** A tracked animal id
   survives only if the live lookup finds it.
10. **The server never plays tutorial audio.** The client plays the
    step sting once per real step change on the push.
11. **Persistence and runtime commit even when the player is gone** —
    the push is skipped, the state is not.

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| `EggConfig.GetStarterRarity` is missing | The `pcall` swallows it; the fallback `RarityDefs.Order[1]` = `'Common'` is returned. |
| A gameplay service is missing | `_services()` returns false; `ResumeForPlayer` and `RecoverFor` return without doing anything. |
| `profile.Tutorial` is missing | `_readPersisted` returns the defaults (`BuyEgg`). |
| `profile.Tutorial.Step` is not a string | Defaults to `'BuyEgg'`. |
| The player left before `ResumeForPlayer` | `_readPersisted` returns the defaults and a fresh `BuyEgg` is set — **the persisted progress is overwritten**. |
| The tracked egg record exists but its model is destroyed | The record still counts as live (existence, not liveness). |
| The tracked animal record is gone but the egg is live | The step falls back to `HatchEgg` with that egg id. |
| Both are gone but an owned egg exists | Adopts it → `HatchEgg`. |
| Everything is gone | Falls back to `BuyEgg` and logs the loud warning. |
| A `BaseLocked` event for another player's base | Rejected by the own-base check — **unless** the own base id cannot be read. |
| `HandleAction` with a non-Player | Returns immediately. |
| `HandleAction` with a nil payload | `action` is nil → `'unknown action ignored'`. |
| `HandleAction` with `'Continue'` outside `ArenaEnded` | `NextStep` returns nil → nothing happens, silently. |
| `HandleAction` with `'Skip'` when there is no active state | Nothing happens. |
| The Beam asset is private/deleted | The exact Roblox error is printed; the client falls back to a white beam. |
| `InsertService` is unavailable | `Debug.Log('TS', 'beam asset: InsertService unavailable; clients use fallback beam')`. |
| `TutorialAction` remote is missing | The `WaitForChild` times out after 10 s and the remote is never bound. |
| `NextStep` is called with a non-table | Returns `nil`. |

---

## Gotchas that would bite you

- **`EggConfig.GetStarterRarity` does not exist** in this codebase.
  The result is still `'Common'` (via `RarityDefs.Order[1]`), but the
  "never hardcoded, read from the config" contract is not really
  satisfied — it reads the rarity *display order*, not the price.
- **The shipped spec calls `Eggs.GetStarterRarity()` directly**
  (spec line 581) and therefore **errors**. The spec cannot pass as
  shipped.
- **The Tutorials spec requires `TutorialController`** from the
  ClientPresentation system — the Tutorials system alone cannot run
  its own tests.
- **`DeriveResume` can move the step BACKWARDS** (e.g.
  `PlaceAnimal → HatchEgg`). That is deliberate recovery, not a bug.
- **`_applyTransition` writes the profile even when the player is
  gone.** The state is committed first, the push second.
- **`_active[userId]` is set to `nil` on completion**, but the
  persisted `Completed = true` is what actually stops a rejoin.
- **`TutorialSignals.Connect` never stores the connection**, so
  `TutorialService.Init()` connecting the same channel twice would
  double-fire. `Init()` is guarded by `_started`.
- **`_started` and `_tickConn` are separate guards.** `Init()` sets
  `_started`; `Start()` checks `_tickConn`. Calling `Start()` without
  `Init()` starts a sweep with no channels connected.
- **`_TestReset()` clears `_active` and `_taggedByUser` but does not
  disconnect the bus connections** — a spec that calls `Init()` again
  after `_TestReset()` would double-connect (unless `_started` was
  also reset, which `_TestReset` does **not** do).
- **`TutorialSignals._TestReset()` clears the channels**, which
  invalidates the connections the service already made — the service
  will then be listening to orphaned signal objects.
- **`_isArenaSlotId` requires the id to end in `:<digits>`.** A slot
  id with any other suffix is never an arena slot.
- **`_suggestArenaSlotId` sorts by `arenaIndex` and falls back to the
  first slot**, so the suggestion can point at an occupied slot. It
  is a display hint only.
- **`ownedUnhatchedEggId` requires the model to be parented.** An egg
  in state `'Opening'` (model destroyed for ~5 s) is **not** adoptable
  — but it is also not "gone" for the `eggById` liveness check. The
  two checks deliberately differ.
- **The `EggPlaced` payload uses `OwnerUserId`, not `UserId`** —
  `_onBusEvent` accepts either.
- **`PublishTo` accepts a userId number** as well as a `Player`.

---

## What to change to reuse it

1. **Redraw `TutorialService.Step` and the `NextStep` table.** They
   must be edited together — the table is exhaustive.
2. **Rename the signal channels** in both `Init()`'s `channels` list
   and `NextStep`'s `name ==` branches.
3. **Fire the signals from your gameplay services** with the tracked
   ids in the payload.
4. **Replace `_isArenaSlotId`** with your own arena-slot test.
5. **Add `GetStarterRarity()` to your egg config** so the starter
   rarity is genuinely price-derived.
6. **Replace the `lookup` implementation** in `_makeLookup` — the
   `eggById` / `animalById` / `ownedUnhatchedEggId` interface is
   already injected and decoupled.
7. **Adapt the profile contract**: `profile.Data.Tutorial` and
   `PlayerService.SetTutorial` / `GetPlayerData`.
8. **Keep the `pcall` discipline and the `pcall`-guarded lazy
   `_services()`** — they are what make the module cycle-free and
   crash-proof.
9. **Keep the 1 Hz recovery sweep.** Without it, a destroyed mid-hatch
   egg loses the player's tutorial target.
10. **Write the client controller** (or copy the ClientPresentation
    system's `TutorialController`). The server's contract is
    `TutorialState` in, `TutorialAction` out, plus the
    `TutorialTarget_<userId>` tag.
