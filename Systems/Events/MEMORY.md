# Events — MEMORY

Engineering notes for a future agent. Everything here was read out of
the four files in `Source/`, plus the two spec files in `Tests/`.

Files:
- `Source/ReplicatedStorage/Config/World/Events.lua` (562)
- `Source/ServerScriptService/Event/EventService.lua` (1106)
- `Source/ServerScriptService/Event/EnvironmentModifier.lua` (349)
- `Source/ServerScriptService/Event/EventLights.lua` (160)

---

## 1. Purpose in one line

A generic, config-driven world-event engine: schedule a special
world state on a weighted cycle, apply it (assets, clock, map colours,
lights, egg mutations), and tear it down exactly — with egg mutations
kept as permanent gameplay data.

**The single most important design fact:** the engine knows *how*, never
*which*. `Galaxy` and `Snowfall` are rows in a config table. There is no
`GalaxyEventScript`. Adding an event is config work.

---

## 2. How it actually works, step by step

### 2.1 The tick (`_tick`, driven by `RunService.Heartbeat`)

```lua
local function _tick(dt: number)
    _accum += dt
    if _accum < 1 then return end     -- 1 Hz ceiling
    _accum = 0
    ...
end
```

The tick is a **1 Hz** loop, not a precise timer. It accumulates `dt`
and bails out until a full second has passed, so the mutation interval
is accurate to roughly ±1 s.

Inside the tick, exactly one of two things happens:

**If an event is active (`_current ~= nil`):**
1. If `now >= _current.EndAt` → `EndEvent('schedule')` and return.
2. Otherwise `_mutAccum += 1`; if `_mutAccum >= interval` (the event's
   `MutationIntervalSeconds`, default 30) → reset `_mutAccum = 0` and
   `RunMutationCycle()`.

**If no event is active:**
1. If `_next ~= nil` and `now >= _next.At`:
   - `_next.Id` is a non-empty string → `StartEvent(id, 'schedule')`.
     **If the start fails**, `ScheduleNext('retry')` — a new roll, so
     the cycle is re-drawn.
   - `_next.Id` is `nil` or `''` (a normal cycle) → `ScheduleNext('cycle')`.

### 2.2 `ScheduleNext(reason?)`

```lua
local cycle = 300
-- overridden by EventConfig.Scheduler.CycleSeconds if >= 10
local id = EventService.PickNextEventId()
_next = { Id = id, At = _serverNow() + cycle }
_publish()
```

**The next event is pre-decided**, so the UI can name it in the
countdown ("GALAXY EVENT IN 5:00"). It is rolled **once per cycle**, not
re-rolled at the moment of the start.

`At` is computed from `_serverNow()` (the server clock), so the phase
is relative to whenever this server last scheduled.

### 2.3 `PickNextEventId(rollOverride?)`

Walks `EventConfig.Order` (deterministic order — `pairs()` order is not
guaranteed) and collects entries where:
- the id is a non-empty string, **not** `'Base'`,
- `def.Scheduling.Enabled == true`,
- `def.Scheduling.Weight` is a number `> 0`.

Then `total += EventConfig.Scheduler.NoneWeight` (if `> 0`).

The roll:
```lua
roll = (rollOverride or math.random()) * total
acc = 0
for _, entry in ipairs(entries) do
    acc += entry.Weight
    if roll < acc then return entry.Id end
end
return nil   -- the "none" bucket
```

`rollOverride` is clamped to `[0, 0.999999]`. With the shipped
20/20/60 weights, `total = 100` and the boundaries are exactly 0.2 and
0.4 — which is why the spec asserts `0.19 → 'Galaxy'` and `0.2 →
'Snowfall'`.

**Note the `nil` return means "normal cycle"**, and `_next.Id = nil`
(not `''`) is the signal the tick reads.

### 2.4 `StartEvent(eventId, source)` — the one start path

```
1.  src = (type(source) == 'string' and source ~= '') and source or 'unknown'
2.  if not IsStartable(eventId) -> return false, 'Unknown or non-startable event: "<id>"'
3.  if not _services()            -> return false, 'Event services unavailable'
4.  if _current and _current.Id == eventId
                                -> return false, 'Event "<id>" is already active'
5.  if _transitionId ~= nil       -> return false, 'An event transition is already in progress'
6.  replacing = (_current ~= nil)
7.  _next = nil                  -- CONSUME THE SCHEDULE BEFORE THE COVER GATE
8.  _transitionSeq += 1; _transitionId = _transitionSeq; token = _transitionId
9.  timings = _transitionTimings()
10. _broadcastTransition('Prepare', 'Start', eventId, token, timings)
11. task.wait(timings.CoverSeconds)   -- the white window
12. if replacing:
       _suppressTransition = true
       replaceOk = EndEvent('replace')
       _suppressTransition = false
       if not replaceOk:
           _broadcastTransition('Reveal', 'Start', eventId, token, timings)
           _transitionId = nil
           return false, 'Previous event failed to end'
13. duration = def.DurationSeconds (default 180)
14. now = _serverNow(); _runId += 1
15. _current = { Id, RunId, StartedAt = now, EndAt = now + duration, Source = src }
16. _mutAccum = 0
17. _applyTime(def); _applyAssets(def); _applyEnvironment(def); _applyLights(def)
18. _publish()
19. _broadcastTransition('Reveal', 'Start', eventId, token, timings)
20. _transitionId = nil
21. return true
```

**Step 7 is subtle and load-bearing.** `_next = nil` happens *before*
the cover gate because the tick keeps running during the `task.wait`. If
`_next` were still set, the tick would fire `StartEvent` again — which
is rejected at step 5 (transition in progress) — and would then call
`ScheduleNext('retry')`, **burning a retry roll**. Clearing it first
means the retry roll is only spent on a genuine failure.

**The replace path is one transition, not two.** When an event is
already active, `EndEvent('replace')` runs with `_suppressTransition =
true`, so it does the cleanup **silently** — no Prepare, no Reveal, no
second flash. The whole Galaxy → Snowfall swap is one continuous
white-out.

**The order of the apply steps is fixed:** time → assets → environment
→ lights. The reverse on cleanup: assets → environment → lights → time.

**Every failure path is `pcall`-guarded internally**, and the outer
`pcall` around the whole body means `StartEvent` **never throws**. The
one truly exceptional case is a body throw *between* the Prepare
broadcast and the Reveal: the code after the `pcall` detects a non-nil
`startedToken` and broadcasts the Reveal anyway — **never trap clients
behind white**.

### 2.5 `EndEvent(source)`

```
1.  if _current == nil -> return true (idempotent no-op)
2.  if _transitionId ~= nil and not _suppressTransition
       -> return false ("a concurrent transition rejects with false;
          the tick retries next second")
3.  if not _suppressTransition:
       _transitionSeq += 1; _transitionId = _transitionSeq
       timings = _transitionTimings()
       _broadcastTransition('Prepare', 'End', id, token, timings)
       task.wait(timings.CoverSeconds)
4.  _removeAssets(); _restoreEnvironment(); _restoreLights(); _restoreTime()
5.  _current = nil
6.  EventService.ScheduleNext('event-end')
7.  if not _suppressTransition:
       _broadcastTransition('Reveal', 'End', id, token, timings)
       _transitionId = nil
```

Note the cleanup order is the **mirror** of the apply order (assets,
environment, lights, time) — assets first so the recoloured parts go
away with the assets, and the clock last.

`EndEvent` **never throws** and is **idempotent**: ending with nothing
active returns `true`.

**Egg mutations are never touched** by the cleanup. That is the whole
point: they are persistent gameplay data.

### 2.6 The transition broadcast

`_broadcastTransition(phase, kind, eventId, token, timings)` builds the
payload and fires it on `Remotes.Names.EventTransition` with
`FireAllClients`.

**Prepare payload:**
```lua
{ Phase = 'Prepare', Kind = 'Start' | 'End', EventId = eventId,
  TransitionId = token, FovMultiplier, FovSeconds, FlashDelaySeconds,
  FlashInSeconds, FadeOutSeconds, CoverSeconds }
```

**Reveal payload:**
```lua
{ Phase = 'Reveal', Kind = 'Start' | 'End', EventId = eventId,
  TransitionId = token }
```

`TransitionId` is a monotonic counter. The client ignores unknown or
replayed ids, so a late joiner or a duplicated delivery cannot stick
the transition. The server **never waits on clients** — it gates on
`CoverSeconds` and acts.

Every broadcast is also appended to `_testBroadcasts` (capped at 50,
oldest dropped) so a spec can assert the exact sequence.

### 2.7 `_transitionTimings()`

Config-first with **defensive fallbacks identical to the client
defaults**:

```lua
{ FovMultiplier = 0.83, FovSeconds = 0.35, FlashDelaySeconds = 0.05,
  FlashInSeconds = 0.3, FadeOutSeconds = 1, CoverSeconds = 0.65 }
```

Each field is only taken from the config if it passes a type/range
check; otherwise the fallback stays. `_testCoverOverride` (the test
seam) replaces `CoverSeconds` last.

### 2.8 `_publish()`

```lua
_revision += 1
ReplicatedStorage:SetAttribute('Event_CurrentId', currentId)
ReplicatedStorage:SetAttribute('Event_EndAt', endAt)
ReplicatedStorage:SetAttribute('Event_NextId', nextId)
ReplicatedStorage:SetAttribute('Event_NextAt', nextAt)
ReplicatedStorage:SetAttribute('Event_Revision', _revision)
```

The revision is bumped **before** the attributes are set, so a client
that observes a new revision sees a consistent set.

`Event_NextId` is `''` (not `nil`) when the next cycle is normal.

### 2.9 The world application / restoration

All four apply functions follow the same shape: `pcall`-wrapped, with
their own inner `pcall`s, and they **never throw**.

**`_applyTime(def)`** — if `def.Time.Override` is true, it snapshots
`Lighting.ClockTime` into `_savedClockTime` and sets the new value.
`_restoreTime()` puts the exact saved value back. **It never assumes a
default** — a place whose clock was at 3.7 comes back at 3.7.

**`_applyAssets(def)`** — clones
`ServerStorage.Assets.Events.<FolderName>` into the Workspace, renames
the clone to `'EventAssets_' .. def.Id`, and stores the handle in
`_assetClone`. A **missing** asset folder is a **warning**
(`event asset folder missing; continuing without assets`) — the event
still runs, just without the assets. `_removeAssets()` destroys the
clone and is idempotent (the handle is nulled first).

**`_applyEnvironment(def)`** — calls
`EnvironmentModifier.ApplyColors(def.Environment.Colors)` and stores
the snapshot. `_restoreEnvironment()` calls
`EnvironmentModifier.Restore(snapshot)` then nulls it.

**`_applyLights(def)`** — calls
`EventLights.ApplyLights(def.Lights, _testLightsRoots)` and stores the
snapshot. `_restoreLights()` restores it.

**The apply order is fixed** and the **cleanup order is its exact
mirror**.

### 2.10 `EnvironmentModifier` — path resolution

`_splitPath(path)` splits on `.` into segments. `string.gmatch(path,
'[^.]+')` skips empty segments, so `'Map..Paths'` yields
`{ 'Map', 'Paths' }` — but the **validator** rejects that form, so it
never reaches here in a validated config.

`_walkSegments(roots, segments)` resolves one segment at a time over
the **set** of current matches:

- a **normal** segment → `FindFirstChild(seg)` on each current match.
  Duplicate names do **not** fan out — a single hit per match.
- a `'*'` segment → **all** children of every current match, and the
  remaining segments resolve under each of them.

The set is empty → the walk breaks early and returns `{}`.

`ResolveRoots(target, opts)`:
- The **first** segment is the **scope**: `'Map'` or `'Base'`. Anything
  else → `Debug.Warn('EV', 'environment target has unknown scope (want
  Map/Base); skipped')` and `{}`.
- A path with **fewer than 2 segments** → `{}` (a scope alone is not a
  target).
- `'Map'` scope: `_mapRoot(opts.mapRoot)` — `Workspace.Map`, or the
  override. **The walk starts AT `Workspace.Map`**, and the scope
  segment is dropped from the remainder. So `'Map.MainIsland.Paths'`
  walks `Map` → `MainIsland` → `Paths`. (The source comments that an
  earlier revision walked the remainder under `Workspace` and silently
  resolved every `Map.*` target to nothing.)
- `'Base'` scope: `_baseRoots(opts.baseRoots)` — **every direct child**
  of `Workspace.Map.Bases`, falling back to `Workspace.Bases`. Then the
  remainder is walked under all of them.

`CollectParts(root)` — the single reusable traversal:
- If the root **itself** `IsA('BasePart')`, it is included.
- Then **every descendant** that `IsA('BasePart')`.

`GetDescendants()` alone would miss a Part-root, so the root check is
explicit. This makes a lone `Grass` part and a `Paths` folder behave
identically.

`ApplyColors(colors, opts)`:
- Categories are applied in **sorted key order** — deterministic.
- **First write wins the snapshot**: `saved[part]` guards, so an
  instance in two categories is snapshotted once (with its true
  original) but painted twice (last write wins the visual).
- Only `Color` and `Material` are touched. Never deletion,
  reparenting, collision or prompts.
- A missing target → a warning **and** three `Debug.Log('EventEnvironment', ...)`
  lines (`Resolved target: <t>` / `Root Class: <class>` /
  `Renderable parts found: <n>`), one per target per event start.
- A target that resolves but has no renderable parts → a warning.

`Restore(snapshot)`:
- Restores `Color` **and** `Material` for each entry, skipping
  destroyed or reparented-away instances.
- **`table.clear(snap.entries)`** at the end — that is what makes it
  idempotent: a second `Restore` on the same snapshot is a no-op.

### 2.11 `EventLights` — the switchboard

Structurally identical to `EnvironmentModifier` but for `Light`:

- `_collectLights(root)` — the root itself if `IsA('Light')`, plus every
  descendant `Light`. (`PointLight`, `SpotLight`, `SurfaceLight` all
  inherit `Light`.)
- `ApplyLights(lightCfg, opts)` — for each container path, resolve the
  roots, then set `light.Enabled = true` on every collected light.
  The prior `Enabled` value is snapshotted **before** the first write
  (`saved[light]` guard) — a light authored ON stays ON.
- **Nothing is cloned, created or destroyed.**
- `Restore(snapshot)` — puts the exact prior `Enabled` states back and
  clears the entries (idempotent).

`EventLights` reuses `EnvironmentModifier.ResolveRoots`, so the path
convention is identical for colours and lights.

### 2.12 The mutation path

`TryMutateEgg(egg, rollOverride)`:

```
1.  if _current == nil -> false
2.  if type(egg) ~= 'table' -> false
3.  def = GetEvent(_current.Id); if def or def.Mutations is not a table -> false
4.  ELIGIBILITY: egg.state must be 'Available', 'Traveling' or 'Placed'.
    ('Consumed' / 'Opening' never roll.)
5.  CONFLICT RULE: existing = MutationService.SanitizeList(egg.Mutations)
    (or a manual scan when MutationService is unavailable).
    if #existing > 0 -> false.   An already-mutated egg is never
    overwritten.
6.  for each entry in pairs(def.Mutations):
       if RollMutationChance(entry.Chance, rollOverride):
           if MutationService.IsValidMutation(entry.MutationId):
               egg.Mutations = { entry.MutationId }
               -> PlayerService.SetEggMutations(owner, uniqueId, egg.Mutations)
                  (only when ownerUserId is a number and uniqueId is a
                   non-empty string — i.e. a base egg)
               -> EggOverhead.Refresh(egg)  (repaint the icon)
               -> _notifyBaseEggOwner(egg, entry.MutationId)
               -> FunnelService:LogStep(...)  (twice: EventParticipated
                  + MutationReceived)
               -> Debug.Log('EventMutation', ...)  (the team-test trace)
               mutated = true
           break
```

**The `break` is inside the `if` that succeeded** — so exactly one
mutation is applied per egg per roll, and the iteration stops at the
first mutation that passed the chance gate.

**There is deliberately no per-event run stamp.** The comment says so:
"Every worker cycle re-evaluates unmutated eggs (failures retry later
in the event); the existing-mutation guard below is the only skip, so
protection can never be bypassed and retries can never duplicate."

**`pairs(def.Mutations)`** — the mutation entries are iterated in
**unordered** `pairs` order. With one mutation per event (the current
case) that does not matter, but with two, which one applies is
**nondeterministic**.

`_notifyBaseEggOwner(egg, mutationId)` fires **only** when:
- `egg.state == 'Placed'` (a base egg, not a traveling one),
- `egg.ownerUserId` is a number,
- the owner resolves to a live `Player`,
- `NotificationService` is available (lazy-required if needed).

It sends `NotificationService.NotifySuccess(player, 'Event_EggMutated',
{ EggName, Rarity, MutationName })`. The `EggName` comes from
`RarityConfig.RarityDisplayName[egg.rarity]`, defaulting to `'Egg'`.

**Spawn-with-mutation, traveling eggs, offline owners, hatch
inheritance and protected re-rolls never notify.** The toast fires only
on a *real new assignment*.

`RunMutationCycle(rollOverride)`:
```
1.  if _current == nil -> 0
2.  if not _services() -> warn 'mutation cycle skipped: services unavailable'; 0
3.  list = SpawnService.AllEggs()
4.  for each egg: if TryMutateEgg(egg, rollOverride) then count += 1
5.  return count
```

The **single `SpawnService` registry** is the source of truth for
"which eggs exist" — so eggs that spawned or arrived **after** the
event began are picked up automatically on the next cycle. There is no
spawn-bus subscription, by design.

### 2.13 `RollMutationChance(chance, rollOverride)`

```lua
if type(chance) ~= 'number' or chance <= 0 then return false end
if chance >= 1 then return true end
return (rollOverride or math.random()) < chance
```

Pure. `rollOverride` is the test seam.

---

## 3. Exact public API surface

### `EventService`

```lua
local EventService = require(ServerScriptService.Event.EventService)
```

| Function | Signature |
|---|---|
| `Init` | `(): ()` |
| `Start` | `(): ()` |
| `StartEvent` | `(eventId: any, source: any): (boolean, string?)` |
| `EndEvent` | `(source: any): boolean` |
| `ScheduleNext` | `(reason: string?): ()` |
| `GetCurrentEvent` | `(): ActiveEvent?` |
| `GetNextEvent` | `(): NextEvent?` |
| `GetEvent` | `(eventId: any): any` |
| `IsStartable` | `(eventId: any): boolean` |
| `PickNextEventId` | `(rollOverride: number?): string?` |
| `RollMutationChance` | `(chance: any, rollOverride: number?): boolean` |
| `FormatCountdown` | `(totalSeconds: number): string` |
| `TryMutateEgg` | `(egg: any, rollOverride: number?): boolean` |
| `RunMutationCycle` | `(rollOverride: number?): number` |
| `_TestReset` | `(): ()` |
| `_TestSetPlayerResolver` | `(fn: ((number) -> any)?): ()` |
| `_TestSetLightsRoots` | `(mapRoot: Instance?, baseRoots: { Instance }?): ()` |
| `_TestSetTransitionCover` | `(seconds: number?): ()` |
| `_TestBroadcasts` | `(): { any }` |
| `_TestIsTransitioning` | `(): boolean` |

Types:
```lua
export type ActiveEvent = { Id: string, RunId: number, StartedAt: number,
                            EndAt: number, Source: string }
export type NextEvent = { Id: string?, At: number }
```

### `EnvironmentModifier`

```lua
local EnvironmentModifier = require(ServerScriptService.Event.EnvironmentModifier)
```

| Function | Signature |
|---|---|
| `ApplyColors` | `(colors: any, opts: ResolveOptions?): EnvSnapshot` |
| `Restore` | `(snapshot: EnvSnapshot?): ()` |
| `ResolveRoots` | `(target: string, opts: ResolveOptions?): { Instance }` |
| `CollectParts` | `(root: Instance?): { BasePart }` |
| `_TestResolveCount` | `(target: string, mapRootOverride: Instance?, baseRootsOverride: { Instance }?): number` |

Types:
```lua
export type EnvSnapshot = { entries: { { inst: Instance, color: Color3,
                                        material: Enum.Material } } }
export type ResolveOptions = { mapRoot: Instance?, baseRoots: { Instance }? }
```

### `EventLights`

```lua
local EventLights = require(ServerScriptService.Event.EventLights)
```

| Function | Signature |
|---|---|
| `ApplyLights` | `(lightCfg: any, opts: LightsOptions?): LightSnapshot` |
| `Restore` | `(snapshot: LightSnapshot?): ()` |
| `_TestCollectCount` | `(target: string, mapRootOverride: Instance?, baseRootsOverride: { Instance }?): number` |

Types:
```lua
export type LightSnapshot = { entries: { { inst: Light, enabled: boolean } } }
export type LightsOptions = { mapRoot: Instance?, baseRoots: { Instance }? }
```

### `Events` (the config)

```lua
local EventConfig = require(ReplicatedStorage.Config.World.Events)
```

| Member | Type | Notes |
|---|---|---|
| `Events.Validate()` | `(): { string }` | The `ConfigValidator` domain. Empty array = clean. |
| `Events.Events` | `{ [string]: EventDefinition }` | `Base`, `Galaxy`, `Snowfall`. |
| `Events.Order` | `{ string }` | The deterministic scheduler order. |
| `Events.Scheduler` | `{ CycleSeconds: number, NoneWeight: number }` | |
| `Events.Transition` | `{ FovMultiplier, FovSeconds, FlashDelaySeconds, FlashInSeconds, HoldSeconds, FadeOutSeconds, CoverSeconds }` | |
| `Events.LuckPoolOrder` | `{ string }` | The luck-tier order — **read by `ServerLuckService`, not by this system.** |

Types:
```lua
export type EventMutationEntry = { MutationId: string, Chance: number }
export type EventColorCategory = { Color: Color3, Targets: { string } }
export type EventDefinition = {
    Id: string, Name: string, DisplayName: string,
    DurationSeconds: number, MutationIntervalSeconds: number,
    Scheduling: { Enabled: boolean, Weight: number },
    Assets: { FolderName: string },
    Mutations: { [string]: EventMutationEntry },
    Environment: { Colors: { [string]: EventColorCategory } },
    Lights: { Containers: { string } }?,
    Time: { Override: boolean, ClockTime: number },
}
```

---

## 4. Invariants and rules the code enforces

1. **One special event at a time.** Starting while active ends the
   previous one first, through the same cleanup path.
2. **The scheduler and the admin command use the same
   `StartEvent`/`EndEvent`.** No duplicate implementation.
3. **Egg mutations survive the event end.** Cleanup never touches
   them.
4. **An already-mutated egg is never overwritten.** The existing
   mutation is the *only* skip condition.
5. **Only unhatched eggs roll** — `Available`, `Traveling`, `Placed`.
   `Consumed` / `Opening` never do.
6. **A mutation is committed only after `IsValidMutation` passes.**
7. **The mutation is persisted only for owned eggs** (numeric
   `ownerUserId` + non-empty `uniqueId`).
8. **The owner toast fires only on a real new assignment to a `Placed`
   egg with a live owner.**
9. **World changes are applied in a fixed order** (time → assets →
   environment → lights) and **restored in the exact mirror order**
   (assets → environment → lights → time).
10. **Cleanup is idempotent.** `Restore` clears its entries; a second
    call is a no-op. `_removeAssets` nulls the handle before destroying.
11. **The prior state is snapshotted, never assumed.** The exact
    `Lighting.ClockTime`, the exact `Color`/`Material`, the exact
    `Light.Enabled` are captured before the first write.
12. **Only visual properties are touched** by the environment modifier.
    Never deletion, reparenting, collision or prompts.
13. **A missing path never aborts the rest.** One bad target is warned
    about and skipped.
14. **The engine never throws.** Every public entry point is
    `pcall`-wrapped.
15. **The server never waits on clients.** It gates on the fixed
    `CoverSeconds` and acts.
16. **A replace is one transition, not two.** The inner end is
    suppressed.
17. **`TransitionId` is monotonic**, and the client ignores unknown or
    replayed ids.
18. **`CoverSeconds >= FlashDelaySeconds + FlashInSeconds +
    HoldSeconds`** (enforced by the config validator).
19. **`Base` is never scheduled and never startable.** The validator
    rejects `'Base'` in `Order`.
20. **The mutation worker never runs at start** — the first cycle is
    one full interval later.
21. **The next event is pre-decided at schedule time** and published
    for the countdown.
22. **`_publish()` bumps the revision before setting the attributes.**

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour | Result |
|---|---|---|
| `StartEvent('Base')` | `IsStartable` is false | `false, 'Unknown or non-startable event: "Base"'` |
| `StartEvent('Nope')` | unknown id | `false, 'Unknown or non-startable event: "Nope"'` |
| `StartEvent` on the already-active event | guarded | `false, 'Event "X" is already active'` |
| `StartEvent` during a transition | guarded | `false, 'An event transition is already in progress'` |
| `StartEvent` with the services unavailable | `_services()` false | `false, 'Event services unavailable'` |
| `StartEvent` where the previous event fails to end | the replace path | `false, 'Previous event failed to end'` — **and the Reveal is still broadcast** so clients are not stuck white |
| `EndEvent` with nothing active | idempotent | `true` |
| `EndEvent` during a transition | rejected | `false` (the tick retries next second) |
| `EndEvent` from inside a replace | `_suppressTransition` | silent cleanup, `true` |
| A body throw between Prepare and Reveal | the post-`pcall` guard | the Reveal is broadcast anyway — clients are never left white |
| The asset folder is missing | a warning | the event still runs, `_assetClone` stays `nil` |
| The clone fails | `pcall` | `_assetClone` stays `nil` |
| A colour target resolves to nothing | a warning + three `EventEnvironment` log lines | skipped; the rest still applies |
| A colour target resolves but has no `BasePart`s | a warning | skipped |
| An unknown scope (`'Foo.Bar'`) | a warning | skipped |
| A path with one segment (`'Map'`) | `< 2` segments → `{}` | skipped |
| A `Light` container is missing | a warning | skipped |
| A `Light` container has no lights | a warning | skipped |
| A part is destroyed before `Restore` | `Parent == nil` check | skipped |
| A part is reparented away before `Restore` | `Parent ~= nil` but not under the same parent | **it is still restored** — the check is only `raw.Parent ~= nil`, not a parent-identity check |
| `RollMutationChance(0, x)` | `<= 0` | `false` |
| `RollMutationChance(1, 0.999)` | `>= 1` | `true` |
| `RollMutationChance('nope', 0)` | not a number | `false` |
| `RollMutationChance(0.05, 0.5)` | `0.5 < 0.05` | `false` |
| `FormatCountdown(-9)` | `math.max(0, ...)` | `'0:00'` |
| `FormatCountdown(300)` | | `'5:00'` |
| `FormatCountdown(65)` | | `'1:05'` |
| `TryMutateEgg` with no active event | `_current == nil` | `false` |
| `TryMutateEgg` on a `Consumed` egg | eligibility | `false` |
| `TryMutateEgg` on an already-mutated egg | the conflict rule | `false` (no overwrite) |
| `TryMutateEgg` on a center egg (no owner) | the mutation is applied in memory but **not persisted** | `true` |
| `RunMutationCycle` with no active event | | `0` |
| `RunMutationCycle` with the services unavailable | a warning | `0` |
| The mutation id is not valid | `IsValidMutation` false | no mutation, the loop continues to the next entry |
| `PickNextEventId` with all weights 0 | `total <= 0` | `nil` (a normal cycle) |
| `PickNextEventId(0.4)` with 20/20/60 | past the last bucket | `nil` |
| The config has no `Order` | not a table | `nil` |
| The clock moves backwards | — | not handled; `now >= EndAt` simply does not fire |
| `Lighting.ClockTime` is changed by another system during the event | — | the event's restore puts back the **pre-event** value, clobbering the other change |

---

## 6. Gotchas that would bite you

1. **`_next = nil` happens before the cover gate, not after.** If you
   move it, a start that fails during the wait burns a retry roll and
   the cycle skips.

2. **`_next.Id` is `nil` for a normal cycle, but `Event_NextId` the
   attribute is `''`.** Two different representations of "no event".
   The tick checks `_next.Id`, the client reads the attribute.

3. **The weighted roll boundaries are exact.** `0.19 → Galaxy`,
   `0.2 → Snowfall`, `0.39 → Snowfall`, `0.4 → nil`. The `roll < acc`
   comparison is strict. Any weight change moves these boundaries and
   breaks the spec.

4. **`RollMutationChance` short-circuits `>= 1` to `true` and `<= 0`
   to `false`** — before the override is even consulted. A
   `rollOverride` of `0.999` still returns `true` for `chance == 1`.

5. **`pairs(def.Mutations)` is unordered.** With two mutations on one
   event, which one applies is nondeterministic. The current events
   each have exactly one.

6. **The mutation is applied to `egg.Mutations` as a single-element
   table** (`= { entry.MutationId }`) — it **replaces**, it does not
   append. For an unmutated egg that is the same thing, but it means
   the code would clobber a multi-mutation egg if the conflict guard
   ever failed.

7. **The conflict guard depends on `MutationService.SanitizeList`.**
   If `MutationService` is unavailable, the code falls back to a manual
   scan of `egg.Mutations` — which only collects **string** entries. A
   malformed non-string entry would not be seen, and the egg could be
   re-rolled.

8. **The owner toast is `Placed`-only.** A `Traveling` egg that
   mutates gets **no** notification, even though it has an owner.

9. **The owner toast requires a live `Player`.** An offline owner's
   egg mutates silently.

10. **The `Event_EggMutated` toast goes to the owner only**, and the
    `Approved` SFX plays for that player only.

11. **`pairs(def.Mutations)` combined with `break` means the first
    *successful* mutation wins** — but a mutation that passes the
    chance gate and then **fails** `IsValidMutation` does **not**
    break, so the next entry is tried.

12. **`_publish()` is called on start, end and schedule — but not on
    every tick.** The `Event_EndAt` attribute is therefore set at the
    start and the client counts down locally.

13. **The `Event_Revision` attribute is a bump guard, not a version
    of the event.** It increments on every publish.

14. **The `Debug.Warn` for an unknown scope uses the tag `'EV'`**, but
    `Debug.Log('EventEnvironment', ...)` uses the **module name** as
    the tag. So the per-target resolution lines are only visible with a
    `Tags` whitelist that includes `EventEnvironment`.

15. **`Debug.Log('EventMutation', ...)`** — the team-test trace — also
    uses the module name as a tag, not `'EV'`. Same whitelist trap.

16. **`_TestReset` drops the cleanup handles WITHOUT restoring.** The
    map stays recoloured, the clock stays overridden, the lights stay
    on. The source says so explicitly: "only use on a headless
    registry".

17. **`_TestReset` does not reset `_started`, `_tickConn`, `_runId` or
    `_accum`.** All four survive. A spec that calls `Start()` and then
    `_TestReset()` still has a **live heartbeat connection** running
    the tick against a reset module. `Init()` after a reset is a
    no-op, and `Start()` after a reset is a no-op (the `_tickConn`
    guard), so there is no way to restart the loop from a reset state.
    The run counter also keeps incrementing across tests.

    The exact reset list is: `_current`, `_next`, `_assetClone`,
    `_envSnapshot`, `_savedClockTime`, `_revision`,
    `_testPlayerResolver`, `_mutAccum`, `_transitionSeq`,
    `_transitionId`, `_suppressTransition`, `_testCoverOverride`,
    `_testBroadcasts`, `_lightsSnapshot`, `_testLightsRoots`.

18. **`EventService` has no `Set*Service` seam.** The service refs are
    resolved lazily inside a `pcall` on first use, to avoid load-time
    cycles. A spec cannot inject a fake `SpawnService`; the mutation
    path always hits the real registry.

19. **The `Map.` scope resolves the walk starting AT `Workspace.Map`**
    and drops the scope segment. An earlier revision walked the
    remainder under `Workspace` and silently resolved every `Map.*`
    target to nothing. If you "fix" this, you will break every Map
    target.

20. **`Base` roots are every direct child** of `Workspace.Map.Bases`
    (with a `Workspace.Bases` fallback). A stray folder in there
    becomes a "base" and gets recoloured.

21. **The `Base` fallback is `Workspace.Bases`, not
    `Workspace.Map.Bases` only.** A place with a `Workspace.Map.Bases`
    folder wins; a place with only `Workspace.Bases` also works.

22. **The restore of a recoloured part only checks `raw.Parent ~= nil`
    and `raw:IsA('BasePart')`** — it does **not** check that the part
    is still the same part. If the map was rebuilt, the old instance
    (still parented somewhere) gets its colour written back, and the
    new instance keeps the event colour.

23. **`EnvironmentModifier.Restore` clears `snap.entries` with
    `table.clear`** — so a snapshot is **single-use**. If you need to
    restore twice, you must snapshot twice.

24. **`EventLights.ApplyLights` only ever turns lights ON.** There is
    no "turn off" mode — the restore puts back the snapshot, which
    may have been ON.

25. **The transition `CoverSeconds` is validated against
    `FlashDelay + FlashIn + Hold`, but `HoldSeconds` is not in
    `Events.Transition` as the engine uses it** — the engine's
    fallback table does not include `HoldSeconds` at all. The client
    owns the hold; the server only needs the cover gate.

26. **`Events.LuckPoolOrder` is in the wrong file.** It is read by
    `ServerLuckService` (the SharedUtilities system) and by nothing in
    this system.

27. **The `Events` config is `--!native`.** It runs in the native
    VM. The `Validate()` function is `pcall`-wrapped and returns
    `'Events validation crashed: ' .. err` as an issue string if it
    ever throws.

28. **The `Validate()` clock-time range is `[0, 24]`** — 24 is
    allowed, which is not a valid Roblox `ClockTime` (the range is
    0..24 exclusive at 24). `Lighting.ClockTime = 24` is a no-op or an
    error depending on the engine.

29. **`Time.ClockTime` for `Base` is 14, but the engine never applies
    it.** `Base` is never started, and the restore path uses the
    snapshot, not the config.

30. **The `Event_EggMutated` notification id lives in
    `Config/Presentation/Messages.lua`,** not in this system. If you
    install the Events system without the Notifications system, the
    toast is silently lost (the `pcall` swallows the failure).

31. **The admin command's `_normalizeId` only knows
    `'galaxy'` and `'snowfall'`.** Adding an event to the config does
    **not** make it startable from the admin command — you must extend
    `_normalizeId` in `Cmdr/Server/Commands/eventServer.lua`.

32. **The admin `/event start` is the only manual override.** There is
    no "force the next event" API and no way to shorten a cycle at
    runtime.

---

## 7. What to change to reuse it

| Goal | Change |
|---|---|
| Add an event | Add a row to `Events.Events` and its id to `Events.Order`. Nothing else. |
| Add a mutation to an event | Add a `Mutations.<Id>` entry; the id must exist in `Config/Creatures/Mutations.lua`. |
| Change the schedule | `Events.Scheduler.CycleSeconds` and the per-event `Scheduling.Weight`; re-derive the `NoneWeight` to keep the split you want. |
| Change the event duration | `DurationSeconds` per event. |
| Change the mutation cadence | `MutationIntervalSeconds` per event (must be `>= 5` for a non-`Base` event). |
| Change the transition | `Events.Transition`. Keep `CoverSeconds >= FlashDelay + FlashIn + Hold`. |
| Use a different map layout | Rename your folders to `Map` / `Bases`, **or** edit `_mapRoot` and `_baseRoots` in `EnvironmentModifier` — that is the only place a path branch belongs. |
| Support a different scope name | Extend the `if scope == 'Map' / elseif scope == 'Base'` chain in `ResolveRoots`. |
| Make the schedule global across servers | Adopt the `CodesAndRewards` pattern (`DailyRewardsWeek` / `PlaytimeRewardsDay`): an atomic `UpdateAsync` selection in a DataStore, read by `ScheduleNext` instead of `PickNextEventId`. |
| Inject fake services in a spec | There is no seam. Add a `Set*Service` set to `EventService` mirroring `CodesService`. |
| Make the toast work | Install the Notifications system — `Event_EggMutated` must exist in `Config/Presentation/Messages.lua`. |
| Let the admin command start a new event | Extend `_normalizeId` in `Cmdr/Server/Commands/eventServer.lua`. |
| Give the event bespoke icons | Author a decal under `ServerStorage.Assets.Decals` and an overhead-GUI child named **exactly** by the mutation id. No `ImageId` lives in code. |
| Fix the `LuckPoolOrder` placement | Move `Events.LuckPoolOrder` into the SharedUtilities config where `ServerLuckService` can own it. |
| Make the world change survive a mid-event admin stop | Nothing to change — the cleanup already restores the exact prior state. |
| Make the transition client-aware | Replace the `task.wait(CoverSeconds)` gate with a client ack and a timeout. The current design deliberately does not wait on clients. |
| Make `_TestReset` safe on the live game | Capture and restore the handles instead of dropping them. |
