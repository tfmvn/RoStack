# Events — API

Every public function of every module in the system.

Three modules plus one config:

- `ServerScriptService.Event.EventService` — the engine.
- `ServerScriptService.Event.EnvironmentModifier` — path resolution +
  recolouring.
- `ServerScriptService.Event.EventLights` — light switching.
- `ReplicatedStorage.Config.World.Events` — the data.

**General failure policy.** **Nothing in this system throws.** Every
public function body is wrapped in a `pcall`, and the one exception —
`StartEvent` — returns `(false, reason)` instead of raising. No call
site needs its own `pcall`.

---

## `EventService`

```lua
local EventService = require(ServerScriptService.Event.EventService)
```

The module table is `table.freeze`d.

### Types

```lua
export type ActiveEvent = {
    Id: string,
    RunId: number,
    StartedAt: number,
    EndAt: number,
    Source: string,
}

export type NextEvent = {
    Id: string?,
    At: number,
}
```

---

### `EventService.Init(): ()`

Boot the service. Idempotent.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. `_started` is set to `true` on the
  first call, so a second call is a **no-op**.
- **Side effects:** resolves the four lazy subsystems (`SpawnService`,
  `PlayerService`, `MutationService`, `EggOverhead`) via `_services()`.
  A missing subsystem is logged and that capability is disabled — it is
  **not** fatal.
- **What it does *not* do:** it does **not** connect the heartbeat, and
  it does **not** schedule anything. That is `Start()`.

---

### `EventService.Start(): ()`

Start the tick and schedule the first event. Idempotent.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. If `_tickConn ~= nil` it is a
  **no-op**.
- **Side effects:** connects `RunService.Heartbeat` to `_tick` and
  calls `ScheduleNext('boot')`. The first event opportunity is
  `Scheduler.CycleSeconds` (300 s) after this call — the cycle is
  **not** aligned to any wall-clock boundary, and it is **per-server**,
  so two servers drift.
- **Note:** there is **no spawn-bus subscription**, by design. New eggs
  join an ongoing event through the worker's next cycle; there is
  exactly one mutation path and nothing rolls at spawn or at event
  start.

---

### `EventService.ScheduleNext(reason: string?): ()`

Pre-decide the next cycle's event and publish the UI timestamps.

- **Parameters:** `reason` — a free-form string recorded in the debug
  log. Optional.
- **Returns:** nothing.
- **Failure modes:** never throws (the whole body is `pcall`-guarded).
- **Side effects:** sets `_next = { Id = <id or nil>, At = _serverNow() + cycle }`
  and calls `_publish()`. The **id is decided here, at schedule time**,
  not at the moment the event starts — that is what lets the UI show an
  accurate countdown.
- **Notes:** the cycle length falls back to `300` if
  `Scheduler.CycleSeconds` is missing or `< 10`. `reason` is only ever
  used for logging; the shipped values are `'boot'` and `'event-end'`.

---

### `EventService.GetEvent(eventId: any): any`

Look up an event definition.

- **Parameters:** `eventId` — the event id.
- **Returns:** the `EventDefinition` table from `Events.Events`, or
  `nil` if `eventId` is not a string, the config is not a table, or
  there is no such event.
- **Failure modes:** never throws. **Returns `nil` rather than
  raising** for a bad id — including a non-string.

---

### `EventService.IsStartable(eventId: any): boolean`

Can this event be started right now?

- **Parameters:** `eventId`.
- **Returns:** `true` only if `GetEvent(eventId)` is non-nil **and**
  `eventId ~= 'Base'`. `false` otherwise.
- **Failure modes:** never throws.
- **Note:** this checks **existence**, not eligibility. It does not
  consult `Scheduling.Enabled` or the weight — an event can be
  startable by hand (admin command) even when it is disabled in the
  scheduler.

---

### `EventService.PickNextEventId(rollOverride: number?): string?`

Weighted pick of the next special event.

- **Parameters:** `rollOverride` — optional number in `[0, 1)`, the
  test seam. Production passes `nil` (which means `math.random()`).
  The value is clamped to `[0, 0.999999]` and **multiplied by the
  total weight**, so it is a *fraction*, not a raw roll.
- **Returns:** the event id (`'Galaxy'`, `'Snowfall'`, …) or **`nil` for
  a normal cycle**.
- **Failure modes:** never throws. The whole body is `pcall`-guarded;
  on an unexpected error it returns `nil`.
- **How the roll works:**
  1. Walk `EventConfig.Order` **in order** (not `pairs` — the order
     must be deterministic).
  2. Skip anything that is not a string, is `''`, or is `'Base'`.
  3. Keep it only if `Scheduling.Enabled == true` **and**
     `Scheduling.Weight` is a number `> 0`.
  4. `total = sum(weights) + NoneWeight`.
  5. `roll = (rollOverride or math.random()) * total`.
  6. Walk the entries accumulating; the first whose cumulative sum
     exceeds `roll` wins. Otherwise `nil`.
- **Important:** `nil` means "no special event this cycle" — it is the
  `NoneWeight = 60` bucket, **not** a failure. With the shipped
  weights that is a 60% chance of a normal cycle.

---

### `EventService.RollMutationChance(chance: any, rollOverride: number?): boolean`

Pure chance gate.

- **Parameters:** `chance` — a fraction in `[0, 1]`. `rollOverride` —
  optional number in `[0, 1)`, the test seam.
- **Returns:** `boolean`.
- **Failure modes:** never throws.
  - `chance` is not a number, or `<= 0` → **`false`** (never mutate).
  - `chance >= 1` → **`true`** (always mutate).
  - Otherwise `roll < chance`, where `roll` is `rollOverride` when it
    is a number, else `math.random()`.
- **Note:** the `rollOverride` here is **not** scaled by any total —
  it is compared directly against `chance`.

---

### `EventService.FormatCountdown(totalSeconds: number): string`

Format a countdown as `M:SS`.

- **Parameters:** `totalSeconds` — the seconds remaining.
- **Returns:** a string like `'5:00'` or `'02:07'`.
- **Failure modes:** never throws. Negative or `nil` input is clamped
  to `0` (`math.max(0, math.floor(totalSeconds or 0))`), so
  `FormatCountdown(-5)` returns `'0:00'`.

---

### `EventService.GetCurrentEvent(): ActiveEvent?`

The running event.

- **Parameters:** none.
- **Returns:** the `ActiveEvent` table, or `nil` when idle.
- **Failure modes:** never throws.
- **Note:** the returned table is the **live internal table**, not a
  copy. Mutating it corrupts the engine's state. Read it only.

---

### `EventService.GetNextEvent(): NextEvent?`

The pre-decided next event.

- **Parameters:** none.
- **Returns:** `{ Id: string?, At: number }`, or `nil` when nothing is
  scheduled.
- **Failure modes:** never throws.
- **Note:** `Id` may be `nil` inside the table — that means "a normal
  cycle, no special event". The published attribute `Event_NextId` is
  `''` in that case.

---

### `EventService.StartEvent(eventId: any, source: any): (boolean, string?)`

Start an event. The one start path.

- **Parameters:** `eventId` — the event id. `source` — a label for who
  started it (`'admin'`, `'tick'`, …). A non-string or empty source
  becomes `'unknown'`.
- **Returns:** `(ok, reason)`. `ok` is `true` on success. On failure
  `ok` is `false` and `reason` is a human-readable string.
- **Failure modes:** **never throws.** The body is `pcall`-guarded, and
  a mid-transition throw still broadcasts a `Reveal` so clients are
  never trapped behind a white screen.
- **The failure ladder** (in order):
  | Reason | Cause |
  |---|---|
  | `'Unknown or non-startable event: "<id>"'` | `IsStartable` was false — unknown id, or `'Base'`. |
  | `'Event services unavailable'` | `_services()` could not resolve the lazy subsystems. |
  | `'Event "<id>" is already active'` | The same event is already running. |
  | `'An event transition is already in progress'` | A `Start`/`End` cinematic is mid-flight. |
  | `'Previous event failed to end'` | A replacing event could not be torn down first. |
- **What it does, in order:**
  1. Validates the id and the services.
  2. Consumes `_next` **before** the cover gate — the tick keeps
     running during the wait, and a still-set `_next` would re-enter
     `StartEvent` (rejected) and burn a retry roll.
  3. Allocates a new monotonic `TransitionId` and broadcasts
     `Prepare`.
  4. `task.wait(timings.CoverSeconds)` — the world change happens
     behind full white.
  5. If an event was already running, ends it with `_suppressTransition`
     set, so the replacement does **not** produce a second cinematic.
  6. Sets `_current = { Id, RunId, StartedAt, EndAt, Source }` and
     resets the mutation accumulator.
  7. Applies the clock, the assets, the environment and the lights —
     in that order.
  8. Publishes the state and broadcasts `Reveal`.
- **Notes:**
  - `DurationSeconds` falls back to `180` if the config value is
    missing or `<= 0`.
  - `RunId` is a monotonic counter across the server's life.
  - The event is **not** rolled here — `StartEvent` starts the event
    you name. The roll happens in `ScheduleNext`.

---

### `EventService.EndEvent(source: any): boolean`

End the running event through the normal cleanup path.

- **Parameters:** `source` — a label for who ended it. A non-string or
  empty source becomes `'unknown'`.
- **Returns:** `true` on success, `false` when a transition is already
  in progress.
- **Failure modes:** **never throws.** The body is `pcall`-guarded, and
  a mid-transition throw still broadcasts a `Reveal`.
- **Behaviour:**
  - **Idempotent.** Ending with nothing active is a safe no-op that
    returns `true`.
  - If a transition is in progress and it is **not** a suppressed
    replace-end, it returns **`false`** without doing anything — the
    tick retries on the next second.
  - The cleanup removes the assets, restores the environment, restores
    the lights and restores the clock — **in that order** — then clears
    `_current` and calls `ScheduleNext('event-end')`.
  - **Egg mutations are KEPT.** They are persistent gameplay data, not
    event state.
  - A genuine `Special → Normal` end broadcasts **one** `Prepare`,
    gates `CoverSeconds`, cleans up behind full white, then broadcasts
    `Reveal`.
  - A **suppressed** replace-end (from `StartEvent`) runs silently
    inside the start's single transition.

---

### `EventService.TryMutateEgg(egg: any, rollOverride: number?): boolean`

Try to apply this event's mutation to one egg.

- **Parameters:** `egg` — the egg record. `rollOverride` — optional
  number in `[0, 1)`, the test seam, forwarded to
  `RollMutationChance`.
- **Returns:** `true` if the egg was mutated by this call, `false`
  otherwise.
- **Failure modes:** never throws — the body is `pcall`-guarded.
- **The eligibility ladder** (any failure → `false`):
  1. There is **no current event** → `false`.
  2. `egg` is not a table → `false`.
  3. The event has no `Mutations` table → `false`.
  4. `egg.state` is not `'Available'`, `'Traveling'` or `'Placed'` →
     `false`. (Consumed/`Opening` eggs never roll.)
  5. The egg **already has a mutation** → `false`. An existing
     mutation is **never** overwritten by an event roll.
- **What it does on success:** sets `egg.Mutations = { MutationId }`,
  persists it onto the profile row when the egg is owned (so a rejoin
  and a hatch see the same mutation), and notifies the owner with
  `Event_EggMutated`.
- **Important:** there is **deliberately no per-event run stamp**.
  Every worker cycle re-evaluates unmutated eggs, so a failure retries
  later in the event. The existing-mutation guard is the only skip —
  which means protection can never be bypassed and retries can never
  duplicate.
- **Mutation validation:** when `MutationService` is available, the
  id is checked with `IsValidMutation` before it is applied. When it is
  not available, the id is applied as-is.

---

### `EventService.RunMutationCycle(rollOverride: number?): number`

Run one mutation pass over every live egg.

- **Parameters:** `rollOverride` — optional number in `[0, 1)`, the
  test seam, forwarded to every `TryMutateEgg` call.
- **Returns:** the number of eggs mutated in this cycle (`0` when
  there is no event, no services, or no eggs).
- **Failure modes:** never throws — the body is `pcall`-guarded.
- **Behaviour:** no current event → `0` (and no services are even
  resolved). `_services()` failing → `0`, with a
  `'mutation cycle skipped: services unavailable'` warning. The egg
  list comes from `SpawnService.AllEggs()`.

---

### `EventService._TestReset(): ()`

Reset module state. **Test only** — production never calls this.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Resets:** `_current`, `_next`, `_assetClone`, `_envSnapshot`,
  `_savedClockTime`, `_revision`, `_testPlayerResolver`, `_mutAccum`,
  `_transitionSeq`, `_transitionId`, `_suppressTransition`,
  `_testCoverOverride`, `_testBroadcasts`, `_lightsSnapshot`,
  `_testLightsRoots`.
- **Does NOT reset:** `_started`, `_tickConn`, `_runId`, `_accum`.
  **A spec that calls `Start()` and then `_TestReset()` leaves a live
  heartbeat connection running the tick against a reset module.**
- **Note:** cleanup handles are dropped **without restoring** — the
  world is not rolled back. Only use it on a headless registry.

---

### `EventService._TestSetPlayerResolver(fn: ((number) -> any)?): ()`

Override the owner-id → `Player` resolution.

- **Parameters:** `fn` — a function taking a user id and returning a
  `Player` (or anything truthy). Pass `nil` to restore the default.
- **Returns:** nothing.
- **Failure modes:** never throws.

---

### `EventService._TestSetLightsRoots(mapRoot: Instance?, baseRoots: { Instance }?): ()`

Override the `Map` root and the base list used by the path resolver.

- **Parameters:** `mapRoot` — the instance to treat as `Map`. `baseRoots`
  — the list of base folders. Pass `nil` for both to restore the live
  ones.
- **Returns:** nothing.
- **Failure modes:** never throws.

---

### `EventService._TestSetTransitionCover(seconds: number?): ()`

Override the `CoverSeconds` wait.

- **Parameters:** `seconds` — the number of seconds to wait instead of
  the configured `CoverSeconds`. `nil` restores the config value.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Note:** this is what lets a spec run a transition without a
  multi-second wait.

---

### `EventService._TestBroadcasts(): { any }`

The captured transition payloads.

- **Parameters:** none.
- **Returns:** the array of payloads broadcast since the last reset.
- **Failure modes:** never throws.
- **Note:** the array is the live internal table — treat it as
  read-only.

---

### `EventService._TestIsTransitioning(): boolean`

Is a cinematic in flight right now?

- **Parameters:** none.
- **Returns:** `true` while `_transitionId ~= nil`.
- **Failure modes:** never throws.

---

## `EnvironmentModifier`

```lua
local EnvironmentModifier = require(ServerScriptService.Event.EnvironmentModifier)
```

### Types

```lua
export type EnvSnapshot = {
    entries: { { inst: Instance, color: Color3, material: Enum.Material } },
}

export type ResolveOptions = {
    mapRoot: Instance?,
    baseRoots: { Instance }?,
}
```

---

### `EnvironmentModifier.ResolveRoots(target: string, opts: ResolveOptions?): { Instance }`

Resolve one configured target path to its **root** instances.

- **Parameters:** `target` — the path string. `opts` — optional
  overrides for the `Map` root and the base list (the headless-test
  seam; production passes `nil`).
- **Returns:** an array of root `Instance`s. **Empty** when the path
  is invalid or resolves to nothing.
- **Failure modes:** never throws — the body is `pcall`-guarded.
  - A non-string or empty target → `{}`.
  - A path with fewer than 2 segments → `{}`.
  - An unknown scope (anything other than `Map` or `Base`) → `{}` plus
    a `'environment target has unknown scope (want Map/Base); skipped'`
    warning.
- **The scopes:**
  - `'Map....'` — at most **one** root. The walk starts **at**
    `Workspace.Map`, so the `Map` segment is dropped from the rest:
    `'Map.MainIsland.Paths'` → `Workspace.Map.MainIsland.Paths`.
  - `'Base....'` — **one root per base folder**. Every child of
    `Workspace.Map.Bases` is a base, and the rest of the path is
    resolved inside each.
  - `'*'` — a wildcard at one path level: it matches all children at
    that level and continues resolving the rest against each match.
    A plain name never fans out.
- **Note:** this returns the **roots**, not the parts. Call
  `CollectParts` to expand them.
- **Trap:** a path that resolves to nothing is a **silent no-op** at
  runtime (a warning is logged). A typo in a target is therefore
  invisible to a player.

---

### `EnvironmentModifier.CollectParts(root: Instance?): { BasePart }`

Expand a root into its paintable parts.

- **Parameters:** `root` — the instance to expand.
- **Returns:** an array of `BasePart`s — the root itself if it is a
  `BasePart`, plus every `BasePart` descendant.
- **Failure modes:** never throws. A `nil` or non-`Instance` root →
  an **empty array**.

---

### `EnvironmentModifier.ApplyColors(colors: any, opts: ResolveOptions?): EnvSnapshot`

Apply one event's `Environment.Colors`.

- **Parameters:** `colors` — the `Environment.Colors` table. `opts` —
  optional root overrides.
- **Returns:** an `EnvSnapshot` for `Restore`. Always a table, even on
  failure (`{ entries = {} }`).
- **Failure modes:** never throws — the body is `pcall`-guarded.
  - A non-table `colors` → an empty snapshot.
  - A category with no `Color3` → that category is skipped with a
    warning.
  - A target that resolves to nothing → skipped with a warning.
  - A target with no renderable parts → skipped with a warning.
- **Determinism:** categories are applied in **sorted key order**.
  The **first** write wins the snapshot; the **last** write wins the
  visual. So if two categories touch the same part, the snapshot holds
  the *original* colour (correct) and the part ends up in the
  alphabetically-later category's colour.
- **A part is snapshotted once** — `saved[part]` guards the snapshot,
  so a part hit by two targets is restored to its original colour
  exactly once, not to the intermediate colour.

---

### `EnvironmentModifier.Restore(snapshot: EnvSnapshot?): ()`

Restore a snapshot.

- **Parameters:** `snapshot` — the value returned by `ApplyColors`.
- **Returns:** nothing.
- **Failure modes:** never throws. A `nil` or malformed snapshot → a
  no-op. A destroyed instance is **skipped**, not an error.
- **Idempotent:** the entries are cleared with `table.clear` after the
  restore, so a second call is a no-op.
- **Note:** it restores `Color` **and** `Material`. `ApplyColors` only
  writes `Color`, so the material is normally unchanged — but the
  snapshot records it, so the restore is exact.

---

### `EnvironmentModifier._TestResolveCount(target: string, mapRootOverride: Instance?, baseRootsOverride: { Instance }?): number`

How many paintable parts a target path would hit.

- **Parameters:** as named.
- **Returns:** the count. `0` for an invalid or unresolved path.
- **Failure modes:** never throws.
- **Note:** pure resolution — **no writes**. This is the way to verify
  a target path before shipping it.

---

## `EventLights`

```lua
local EventLights = require(ServerScriptService.Event.EventLights)
```

### Types

```lua
export type LightSnapshot = {
    entries: { { inst: Light, enabled: boolean } },
}

export type LightsOptions = {
    mapRoot: Instance?,
    baseRoots: { Instance }?,
}
```

---

### `EventLights.ApplyLights(lightCfg: any, opts: LightsOptions?): LightSnapshot`

Turn on every light under the configured containers.

- **Parameters:** `lightCfg` — the `Lights` table (it reads
  `lightCfg.Containers`). `opts` — optional root overrides.
- **Returns:** a `LightSnapshot` for `Restore`. Always a table.
- **Failure modes:** never throws — the body is `pcall`-guarded.
  - A non-table `lightCfg` or `Containers` → an empty snapshot.
  - A container that resolves to nothing → skipped with
    `'event light container resolved to nothing; skipped'`.
  - A container with no lights in it → skipped with
    `'event light container has no lights; skipped'`.
- **Behaviour:** every `Light` under the resolved roots has
  `Enabled = true`. The light's **prior** `Enabled` value is recorded
  in the snapshot **once** (a `saved[light]` guard), so a light
  authored ON is restored to ON, not OFF.
- **Note:** it reuses `EnvironmentModifier.ResolveRoots`, so the path
  convention is identical.

---

### `EventLights.Restore(snapshot: LightSnapshot?): ()`

Restore a light snapshot.

- **Parameters:** `snapshot` — the value returned by `ApplyLights`.
- **Returns:** nothing.
- **Failure modes:** never throws. A `nil` or malformed snapshot → a
  no-op. A destroyed instance is skipped.
- **Idempotent:** the entries are cleared after the restore, so a
  second call is a no-op.

---

### `EventLights._TestCollectCount(target: string, mapRootOverride: Instance?, baseRootsOverride: { Instance }?): number`

How many lights a container path would hit.

- **Parameters:** as named.
- **Returns:** the count. `0` for an invalid or unresolved path.
- **Failure modes:** never throws.
- **Note:** pure resolution — no writes.

---

## `Events` (the config)

```lua
local EventConfig = require(ReplicatedStorage.Config.World.Events)
```

| Member | Signature | Description |
|---|---|---|
| `Events.Validate` | `(): { string }` | The `ConfigValidator` domain. Returns an array of issue strings; **an empty array means clean**. Never throws — it wraps its body in a `pcall`. |
| `Events.Events` | `{ [string]: EventDefinition }` | The catalog: `Base`, `Galaxy`, `Snowfall`. |
| `Events.Order` | `{ string }` | The deterministic scheduler order. |
| `Events.Scheduler` | `{ CycleSeconds: number, NoneWeight: number }` | |
| `Events.Transition` | `{ FovMultiplier, FovSeconds, FlashDelaySeconds, FlashInSeconds, HoldSeconds, FadeOutSeconds, CoverSeconds }` | |
| `Events.LuckPoolOrder` | `{ string }` | The luck-tier order — **read by `ServerLuckService` (SharedUtilities), not by this system.** |

### Types

```lua
export type EventMutationEntry = { MutationId: string, Chance: number }
export type EventColorCategory = { Color: Color3, Targets: { string } }
export type EventDefinition = {
    Id: string,
    Name: string,
    DisplayName: string,
    DurationSeconds: number,
    MutationIntervalSeconds: number,
    Scheduling: { Enabled: boolean, Weight: number },
    Assets: { FolderName: string },
    Mutations: { [string]: EventMutationEntry },
    Environment: { Colors: { [string]: EventColorCategory } },
    Lights: { Containers: { string } }?,
    Time: { Override: boolean, ClockTime: number },
}
```

### `Events.Validate()` — the exact rules

Returns an array of issue strings. Every rule below produces one
string:

| Issue string | Rule |
|---|---|
| `'Scheduler must be a table'` | |
| `'Scheduler.CycleSeconds must be a number >= 10'` | |
| `'Scheduler.NoneWeight must be a number >= 0'` | |
| `'Order must be a non-empty array of event ids'` | |
| `'Transition must be a table'` | |
| `'Transition.FovMultiplier must narrow (0 < x < 1)'` | Also rejects `NaN`. |
| `'Transition.FovSeconds must be a number >= 0'` | |
| `'Transition.FlashDelaySeconds must be a number >= 0'` | |
| `'Transition.FlashInSeconds must be a number > 0'` | Strictly greater. |
| `'Transition.HoldSeconds must be a number >= 0'` | |
| `'Transition.FadeOutSeconds must be a number > 0'` | Strictly greater. |
| `'Transition.CoverSeconds must be a number >= 0'` | |
| `'Transition.CoverSeconds must cover FlashDelay + FlashIn + Hold'` | The cover floor. |
| `'Events must be a table'` | |
| `'Events.Base must exist with Id == "Base"'` | |
| `'Order entries must be non-empty strings'` | |
| `'Order has duplicate id "<id>"'` | |
| `'Order must not contain "Base" (Base is never scheduled)'` | |
| `'Order id "<id>" has no Events entry'` | |
| (plus per-event rules below) | |

**Note:** the shipped values sit **exactly** on the cover floor —
`0.05 + 0.3 + 0.3 = 0.65` and `CoverSeconds = 0.65`. Any reduction of
`FlashDelay`, `FlashIn` or `Hold` lowers the floor and leaves
`CoverSeconds` with margin; any increase of them **breaks** the
validation until `CoverSeconds` is raised to match.

The per-event rules (each `EventDefinition` is checked) are:
`DurationSeconds` is a number `>= 0`; `MutationIntervalSeconds` is a
number `>= 5`; `Scheduling.Enabled` is a boolean; `Scheduling.Weight` is
a number `>= 0`; `Assets.FolderName` is a string; each `Mutations`
entry has a non-empty `MutationId` and a `Chance` in `[0, 1]`; each
`Environment.Colors` category has a `Color3` and an array of target
strings; `Time.Override` is a boolean and `Time.ClockTime` is a number
in `[0, 24]`.

---

## Module-locals (not public)

Listed so you know what exists. Do not call these.

| Local | Purpose |
|---|---|
| `_tick(dt)` | The heartbeat handler. Accumulates time, ends an expired event, and runs the mutation worker on its own cadence. |
| `_services()` | Resolves and caches the four lazy subsystems. Returns `boolean`. |
| `_resolveOwnerPlayer(ownerUserId)` | owner-id → `Player`, via the test resolver if set. |
| `_transitionTimings()` | Reads `Events.Transition` with defensive fallbacks. |
| `_broadcastTransition(phase, kind, eventId, token, timings)` | Sends the `EventTransition` remote. |
| `_serverNow()` | `Workspace:GetServerTimeNow()` with an `os.time()` fallback. |
| `_publish()` | Writes the five `Event_*` attributes on `ReplicatedStorage`. |
| `_applyAssets` / `_removeAssets` | Clone / destroy the event asset folder. |
| `_applyTime` / `_restoreTime` | Override / restore `Lighting.ClockTime`. |
| `_applyEnvironment` / `_restoreEnvironment` | Recolour / restore. |
| `_applyLights` / `_restoreLights` | Lights on / restore. |
| `_notifyBaseEggOwner(egg, mutationId)` | The `Event_EggMutated` toast. |
