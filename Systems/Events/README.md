# Events

**Portability:** Grade **A — portable core**. The whole engine is
generic: it knows *how* to run an event, never *which* event. Galaxy and
Snowfall are pure data in a config table — there is intentionally **no**
`GalaxyEventScript` or `SnowfallEventScript` anywhere. Grade **B** is
confined to (a) the `ReplicatedStorage.Config.World.Events` module
itself, which is a game-level config module, and (b) the Studio-authored
asset folders the config points at (`ServerStorage.Assets.Events.*`),
and (c) the `Map.*` / `Base.*` Workspace path convention, which is this
game's map layout.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

A **generic world-event engine**. It runs a special, time-limited world
state (night sky, map recolour, extra map assets, a mutation chance on
eggs) and tears it down cleanly afterwards.

### The pipeline

```text
Config/World/Events.lua        (WHAT — data)
        |
        v
EventService                   (HOW — scheduler + lifecycle)
   |         |          |
   v         v          v
  UI     Assets/Env/   Eggs
  (client)  Time      (persistent mutation data)
```

### The lifecycle

```text
SERVER START
  -> EventService.Init()
  -> EventService.Start()
  -> ScheduleNext()   -- pre-pick the next special event + publish UI timestamps
  -> countdown
  -> StartEvent()     -- clone assets, override time, apply env colors,
                       -- turn on lights, publish, arm the mutation worker
  -> duration         -- progressive mutation cycles every MutationIntervalSeconds
  -> EndEvent()       -- remove assets, restore env/time/lights,
                       -- KEEP egg mutations, publish
  -> ScheduleNext()   -> repeat
```

### Rules the engine enforces

- **One special event at a time.** Starting an event while another is
  active ends the previous one through the **same** cleanup path first.
- **The scheduler and the admin command call the same
  `StartEvent` / `EndEvent`.** There is no duplicate event
  implementation.
- **Egg mutations are persistent gameplay data.** Ending an event
  **never** strips them. Hatch inheritance is automatic, via the
  existing trait-resolution path, because the egg already carries the
  mutation id.
- **Already-mutated eggs are protected from overwrite.** The only skip
  condition in the mutation path is "this egg already has a mutation".
- **Every world change has a cleanup path, and cleanup is idempotent.**
- **Server-authoritative.** The scheduler, the RNG, the state, the
  assets, the mutations and the clock are all server-side. Clients only
  render countdowns from replicated attributes plus the transition
  cinematic. They never decide event state.

### The scheduling model

Every `Scheduler.CycleSeconds` (300) the server performs **one weighted
roll** over the enabled special events in `Events.Order`, plus an
implicit "none" bucket of `Scheduler.NoneWeight`.

With the current 20/20/60 weights that is **Galaxy 20%, Snowfall 20%,
normal cycle 60%.**

The winner is **pre-decided at schedule time** so the UI can count down
to it ("GALAXY EVENT IN 5:00"). It is decided once per cycle, not
re-rolled at the moment of the start.

### The progressive mutation cadence

Events do **not** roll all eggs at start. A worker evaluates the
currently-eligible eggs **every `MutationIntervalSeconds`** (30) while
the event is active. Unmutated eggs roll fresh every cycle, so
mutations happen over time — including for eggs that spawn or arrive
**after** the event began. With a 180 s duration and a 30 s interval
that is **6 opportunities per run**.

### The transition cinematic

One presentation layer around the authoritative lifecycle. The server
broadcasts on a single remote, `EventTransition`:

| t | What |
|---|---|
| 0.00 | server broadcasts **Prepare**; clients start the FOV zoom |
| 0.05 | the white flash begins building (FOV leads, flash follows) |
| 0.35 | the screen is fully white |
| 0.65 | the server performs the world change **behind the white** |
| 0.65 | the server broadcasts **Reveal**; clients fade out and ease the FOV back |
| 1.65 | the new world is fully revealed |

The server **never waits on clients** — it gates on the fixed
`CoverSeconds` and then acts. Joins, leaves and lag therefore cannot
deadlock it, and the final truth stays in the replicated attributes.
A **replace** (Galaxy → Snowfall) runs as **one** continuous transition,
not two flashes: the inner end is *suppressed*.

`CoverSeconds` is validated to be at least
`FlashDelaySeconds + FlashInSeconds + HoldSeconds` (0.65 >= 0.65
exactly, in the shipped config).

---

## Entry Points

### `ServerScriptService.Event.EventService`

| Entry point | Kind | Notes |
|---|---|---|
| `EventService.Init(): ()` | function | Idempotent. Resolves the lazy service refs. |
| `EventService.Start(): ()` | function | Idempotent. Connects the `Heartbeat` tick and schedules the first cycle. |
| `EventService.StartEvent(eventId: any, source: any): (boolean, string?)` | function | The **one** start path. Returns `(true)` or `(false, reason)`. |
| `EventService.EndEvent(source: any): boolean` | function | The **one** end path. Idempotent. |
| `EventService.ScheduleNext(reason: string?): ()` | function | Pre-picks the next cycle's event and publishes the UI timestamps. |
| `EventService.GetCurrentEvent(): ActiveEvent?` | function | `{ Id, RunId, StartedAt, EndAt, Source }` or `nil`. |
| `EventService.GetNextEvent(): NextEvent?` | function | `{ Id: string?, At: number }` or `nil`. |
| `EventService.GetEvent(eventId: any): any` | function | The canonical config definition, or `nil` for an unknown id. |
| `EventService.IsStartable(eventId: any): boolean` | function | `false` for `Base` and for unknown ids. |
| `EventService.PickNextEventId(rollOverride: number?): string?` | function | The weighted roll. `nil` for a normal cycle. |
| `EventService.RollMutationChance(chance: any, rollOverride: number?): boolean` | function | The pure chance gate. |
| `EventService.FormatCountdown(totalSeconds: number): string` | function | `M:SS`. |
| `EventService.TryMutateEgg(egg: any, rollOverride: number?): boolean` | function | One-time mutation roll for a single egg. |
| `EventService.RunMutationCycle(rollOverride: number?): number` | function | One cycle over every eligible live egg. Returns the number of new mutations. |
| `EventService._TestReset(): ()` | function | Test seam. |
| `EventService._TestSetPlayerResolver(fn)` | function | Test seam — override owner-player resolution. |
| `EventService._TestSetLightsRoots(mapRoot, baseRoots)` | function | Test seam — override the light roots. |
| `EventService._TestSetTransitionCover(seconds: number?)` | function | Test seam — override the cover gate. |
| `EventService._TestBroadcasts(): { any }` | function | Test seam — every broadcast payload, in order (capped at 50). |
| `EventService._TestIsTransitioning(): boolean` | function | Test seam — is a transition in flight? |

### `ServerScriptService.Event.EnvironmentModifier`

| Entry point | Kind | Notes |
|---|---|---|
| `EnvironmentModifier.ApplyColors(colors: any, opts: ResolveOptions?): EnvSnapshot` | function | Applies one event's `Environment.Colors`. Returns the snapshot for `Restore`. |
| `EnvironmentModifier.Restore(snapshot: EnvSnapshot?): ()` | function | Puts the exact originals back. Idempotent. |
| `EnvironmentModifier.ResolveRoots(target: string, opts: ResolveOptions?): { Instance }` | function | Resolves one configured path string to its root instances. |
| `EnvironmentModifier.CollectParts(root: Instance?): { BasePart }` | function | The root **and** every descendant `BasePart`. |
| `EnvironmentModifier._TestResolveCount(target, mapRootOverride, baseRootsOverride): number` | function | Test seam — how many parts would a target hit? |

### `ServerScriptService.Event.EventLights`

| Entry point | Kind | Notes |
|---|---|---|
| `EventLights.ApplyLights(lightCfg: any, opts: LightsOptions?): LightSnapshot` | function | Turns every resolved `Light` **on**. Returns the snapshot. |
| `EventLights.Restore(snapshot: LightSnapshot?): ()` | function | Restores the exact prior `Enabled` states. Idempotent. |
| `EventLights._TestCollectCount(target, mapRootOverride, baseRootsOverride): number` | function | Test seam. |

### `ReplicatedStorage.Config.World.Events`

| Entry point | Kind | Notes |
|---|---|---|
| `Events.Validate(): { string }` | function | The `ConfigValidator` domain. An **empty array** means clean. |
| `Events.Events` | data | The event definitions. |
| `Events.Order` | data | The deterministic scheduler iteration order. |
| `Events.Scheduler` | data | `CycleSeconds`, `NoneWeight`. |
| `Events.Transition` | data | The cinematic timings. |
| `Events.LuckPoolOrder` | data | **Surprise:** the luck-tier order, read by `ServerLuckService` (SharedUtilities). It lives in this config for historical reasons — see [Known Limitations](#known-limitations). |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ReplicatedStorage/Config/World/Events.lua` | `ReplicatedStorage.Config.World.Events` | The canonical event config: definitions, scheduler, transition, and the `Validate()` domain. 562 lines, `--!strict --!native`. |
| `Source/ServerScriptService/Event/EventService.lua` | `ServerScriptService.Event.EventService` | The scheduler, the lifecycle, the mutation worker, the transition broadcast. 1106 lines, `--!strict --!native`. |
| `Source/ServerScriptService/Event/EnvironmentModifier.lua` | `ServerScriptService.Event.EnvironmentModifier` | The generic map recolour engine. 349 lines. |
| `Source/ServerScriptService/Event/EventLights.lua` | `ServerScriptService.Event.EventLights` | The generic light switchboard. 160 lines. |

The **client** side (`EventController`, `EventTransitionController`) is
not in this system's `Source/` tree — it belongs to the
`ClientPresentation` system. See [Dependencies](#dependencies).

---

## Configuration

The live config is `Source/ReplicatedStorage/Config/World/Events.lua`.
This system **does** have a config module of its own, so a `Config.lua`
**is** provided — but it is a **documented reference transcription**, not
live configuration, because the real config already ships in the
system's `Source/` tree at its original Roblox path.

### The event definitions

| Event | Duration | Mutation interval | Weight | Mutation | Chance | Time | Assets |
|---|---|---|---|---|---|---|---|
| `Base` | 0 | 0 | 0 (disabled) | — | — | no override (14) | none |
| `Galaxy` | 180 s | 30 s | 20 | `Galactic` | 0.8 | override → 0 (midnight) | `Galaxy` |
| `Snowfall` | 180 s | 30 s | 20 | `Frost` | 0.8 | override → 14 (day) | `Snowfall` |

`Base` is the **baseline**: it is never scheduled, never started, and
exists so every system has a named "normal" state to fall back to. Its
`Time.ClockTime` of 14 is the documented default, but the engine
**never** applies it — the engine restores the *actual* prior clock time
from a snapshot, never an assumed default.

### The scheduler

| Key | Default | Meaning |
|---|---|---|
| `Scheduler.CycleSeconds` | `300` | Seconds between special-event opportunities. Must be `>= 10`. |
| `Scheduler.NoneWeight` | `60` | The implicit "no special event this cycle" weight. Must be `>= 0`. |
| `Order` | `{ 'Galaxy', 'Snowfall' }` | The deterministic scheduler iteration order (`pairs()` order is **not** guaranteed, so the weighted roll walks this list). Must not contain `'Base'`. |

### The transition

| Key | Default | Meaning |
|---|---|---|
| `Transition.FovMultiplier` | `0.83` | Camera FOV multiplier during the flash (70 → ~58). Must satisfy `0 < x < 1`. |
| `Transition.FovSeconds` | `0.35` | FOV zoom duration. `>= 0`. |
| `Transition.FlashDelaySeconds` | `0.05` | Flash starts this far after the FOV zoom begins. `>= 0`. |
| `Transition.FlashInSeconds` | `0.3` | Transparent → fully white. `> 0`. |
| `Transition.HoldSeconds` | `0.3` | Full-white dwell before the server acts. `>= 0`. |
| `Transition.FadeOutSeconds` | `1` | Fully white → transparent. `> 0`. |
| `Transition.CoverSeconds` | `0.65` | The **server gate**: Prepare broadcast → world change. Must be `>= FlashDelay + FlashIn + Hold`. |

### The path convention

`Environment.Colors.*.Targets` and `Lights.Containers` both use the same
convention:

| Form | Resolves to |
|---|---|
| `Map....` | `Workspace.Map....` — the `Map` segment is the **first** segment. `"Map.MainIsland.Paths"` → `Workspace.Map.MainIsland.Paths`. |
| `Base....` | Inside **every** player-base folder (`Workspace.Map.Bases.Base_1 .. Base_N` — never only `Base_1`). `"Base.Build.Paths"` → `<each base>/Build/Paths`. |
| `*` | Wildcard: matches **all** children at that exact path level, then continues resolving the rest against every match. `"Base.Build.Lamps.*.Bush"` finds `Bush` under **every** `Lamp`, however many exist. Multiple wildcards fan out level by level (`"Map.*.*.Grass"`). |

A **plain name never fans out** — duplicate names resolve to the single
`FindFirstChild` hit.

**Every configured path is a RECURSIVE ROOT.** The resolved instance
itself is processed when it is a `BasePart` (or a `Light`), **plus**
every descendant at any depth. Adding a path to a `Targets` array
automatically includes it — no engine change.

### The Snowfall targets

| Category | Colour | Targets |
|---|---|---|
| `Gray` | `170, 170, 170` | `Map.MainIsland.Paths`, `Base.Build.Paths` |
| `White` | `255, 255, 255` | `Map.MainIsland.Island.Grass`, `Map.MainIsland.Decor.Grass`, `Base.Build.Island.Grass`, `Base.Build.Lamps.*.Bush` |

Galaxy has **no** map recolour — night plus the assets carry it. The
`Colors` table stays extensible: adding e.g. `Colors.Purple.Targets`
just works.

### The Galaxy lights

`Galaxy.Lights.Containers = { 'Map.MainIsland.PointLights',
'Base.PointLights' }` — every `Light` under the island container plus
every base's own container turns **on** for the run, then restores its
exact prior `Enabled` state (a light authored ON stays ON).

---

## Dependencies

Full detail in [`Dependencies.md`](Dependencies.md).

- `ReplicatedStorage.Config.World.Events` — the config (self).
- `ReplicatedStorage.Config.Creatures.Rarity` — `RarityDisplayName` for the owner toast.
- `ReplicatedStorage.Utility.Debug` — logging.
- `ReplicatedStorage.Utility.Remotes` — the `EventTransition` broadcast.
- `ServerScriptService.FunnelService` — analytics on a committed mutation.
- `ServerScriptService.Base.NotificationService` — the owner toast (lazy).
- `ServerScriptService.Egg.SpawnService` — the live egg registry (lazy).
- `ServerScriptService.PlayerService` — `SetEggMutations` (lazy).
- `ServerScriptService.MutationService` — `SanitizeList` / `IsValidMutation` (lazy).
- `ServerScriptService.Egg.EggOverhead` — repaint the icon (lazy).
- `ServerScriptService.TraitService` — hatch inheritance (indirect).
- `ServerScriptService.Admin.AdminService` — the admin command (indirect).
- **Client side (not in this folder):** `StarterPlayerScripts.EventController`
  and `StarterPlayerScripts.EventTransitionController`.

---

## Initialization Order

```text
1.  createRemotes()                    -- bootstrap :222; the EventTransition
                                         --   remote must exist before
                                         --   EventService can broadcast
2.  EventService.Init()                -- bootstrap :372
       -> resolves the lazy service refs (SpawnService, PlayerService,
          MutationService, EggOverhead). Never throws.
3.  ... (the rest of the game boots) ...
4.  EventService.Start()               -- bootstrap :1292
       -> RunService.Heartbeat:Connect(_tick)
       -> ScheduleNext('boot')
```

`Init()` and `Start()` are **both** required and **both** idempotent.

`Start()` must come **after** `createRemotes()` — the first
`ScheduleNext` publishes attributes (fine) but the first transition
broadcast needs the remote. `EventService.Init()` is in the
"early services" block (bootstrap `:371-372`); `Start()` is in the
"Section 7" loop block (bootstrap `:1292`).

There is **no** `Set*Service` wiring. The service refs are resolved
**lazily** on first use, inside a `pcall`, specifically to avoid
load-time cycles (`SpawnService` and `MutationService` both reach into
the egg/animal systems).

### Runtime hooks

| Event | Call | Line |
|---|---|---|
| Admin `/event start Galaxy` | `EventService.StartEvent(id, 'admin')` | `Cmdr/Server/Commands/eventServer.lua:79` |
| Admin `/event stop` | `EventService.EndEvent('admin')` | `Cmdr/Server/Commands/eventServer.lua:70` |
| Admin `/event status` | `GetCurrentEvent()` / `GetNextEvent()` / `FormatCountdown` | `eventServer.lua` |

---

## Data

### ReplicatedStorage attributes

The UI reads these; they are the **source of truth** for clients.

| Attribute | Type | Meaning |
|---|---|---|
| `Event_CurrentId` | `string` | The active event's id, or `''` when none. |
| `Event_EndAt` | `number` | The absolute server timestamp when the active event ends. `0` when none. |
| `Event_NextId` | `string` | The **pre-decided** next event's id, or `''` for a normal cycle. |
| `Event_NextAt` | `number` | The absolute server timestamp of the next cycle. `0` when none. |
| `Event_Revision` | `number` | A bump guard — increments on every publish. |

The `_publish()` function bumps `_revision` **before** setting the
attributes, so a client that sees a new revision sees a consistent set.

### Profile fields

| Field | Read/Write | Meaning |
|---|---|---|
| `LuckyBlocks[].Mutations` | **Written** by `PlayerService.SetEggMutations(owner, eggUniqueId, { mutationId })` | The persistent mutation list on an owned egg. This is what makes the mutation survive a rejoin and what the hatch inherits. |

The engine writes the mutation **only** when the egg has an
`ownerUserId` and a `uniqueId` (i.e. it is a base egg). A center egg
has no owner, so its mutation is **not persisted** — it is a world
outcome for the current run only.

### In-memory state

| State | Meaning |
|---|---|
| `_current` | The active event: `{ Id, RunId, StartedAt, EndAt, Source }`. |
| `_next` | The pre-decided next cycle: `{ Id: string?, At: number }`. |
| `_runId` | A monotonically increasing counter, incremented on each start. |
| `_revision` | The publish revision counter. |
| `_tickConn` | The `Heartbeat` connection. |
| `_accum` / `_mutAccum` | The tick accumulator and the mutation-cycle accumulator. |
| `_assetClone` | The cloned event assets (destroyed on end). |
| `_envSnapshot` | The colour snapshot (restored on end). |
| `_savedClockTime` | The prior `Lighting.ClockTime` (restored on end). |
| `_lightsSnapshot` | The light `Enabled` snapshot (restored on end). |
| `_transitionSeq` / `_transitionId` | The transition id mint and the in-flight id. |
| `_suppressTransition` | Set while a replace's inner end runs, so it does not flash. |
| `_testBroadcasts` | The last 50 broadcast payloads (test seam). |

### DataStore

**None.** The event system stores nothing. It is entirely server-memory
plus the profile's own egg-mutation rows.

---

## Known Limitations

1. **`Events.LuckPoolOrder` lives in the wrong module.** The luck-tier
   order (`Common, Uncommon, Rare, Epic, Legendary, Mythic`) is read by
   `ServerLuckService`, which lives in the **SharedUtilities** system —
   but the array sits in this system's config file. It is a historical
   leftover ("moved from `ServerLuckService.LUCK_POOL`"). A new game
   that installs Events but not SharedUtilities gets a config with an
   unused array; a new game that installs SharedUtilities but not
   Events gets a `require` of a module it does not have.

2. **The event schedule is per-server, not global.** Every server rolls
   its own weighted pick at its own `CycleSeconds` boundary. Two servers
   in the same place can be running **different events at the same
   time**, and their cycle boundaries drift. There is no DataStore
   coordination (unlike the weekly pool in `CodesAndRewards`'s
   `DailyRewardsWeek`).

3. **The cycle boundary is not aligned across servers.** `ScheduleNext`
   sets `At = _serverNow() + cycle` from the moment it runs, so the
   phase is whatever the server's own history was. A server that
   restarts mid-cycle starts a fresh cycle.

4. **The mutation worker fires on a 1 Hz tick, not a precise timer.**
   The tick accumulates `dt` and fires at most once per second. The
   mutation interval is therefore accurate to about **one second**,
   and the first cycle lands one full interval *after* the start (never
   at the start).

5. **The first mutation cycle is one full interval late.** The spec
   asserts this explicitly ("nothing at start, late eggs join"). It is
   by design, but it means an event shorter than
   `MutationIntervalSeconds` never mutates anything.

6. **`Lighting.ClockTime` is global.** The time override affects the
   whole place, not just the map. Two overlapping systems that both
   override the clock would fight.

7. **The `Base.*` path convention is hardcoded to
   `Workspace.Map.Bases`, with a `Workspace.Bases` fallback.** A game
   whose bases live elsewhere gets no base recolour — and only a
   warning, not an error. The base roots are also **every direct
   child** of the bases container, so a stray folder in there becomes a
   "base".

8. **`EventService` has no `Set*Service` seam.** The service refs are
   resolved lazily inside a `pcall` on first use. In a spec that
   fakes the world, `_TestSetLightsRoots` and
   `_TestSetPlayerResolver` are the only two seams — there is **no**
   way to inject a fake `SpawnService`, so the mutation path always
   touches the real registry.

9. **`_TestReset` drops the cleanup handles without restoring them.**
   The source says so explicitly: "cleanup handles are dropped WITHOUT
   restoring, so only use on a headless registry." A spec that calls it
   on the live game leaves the map recoloured and the clock overridden.

10. **The transition is a fixed gate, not a client handshake.** The
    server waits `CoverSeconds` and acts. A slow client (or one that
    joined mid-transition) may see the world change without the full
    white — the final state is still correct.

11. **The `EventTransition` remote is broadcast to every client**, but
    the **server** is the only authority. A client that misses a
    broadcast (join mid-transition) relies on the attributes.

12. **The `Source` field of `ActiveEvent` is `'schedule'`, `'admin'` or
    `'replace'`** — a diagnostic label only. It is never used to change
    behaviour.

13. **An unknown scope in a target path only warns.** `'Foo.Bar'` logs
    `environment target has unknown scope (want Map/Base); skipped` and
    is otherwise ignored. A typo in a config path is a silent
    no-op at runtime — the validator does **not** check that the paths
    resolve.

14. **A misconfigured catalog produces `Source = 'misconfigured'` and a
    warning, not an error.** The event system keeps running with no
    event.

---

## Testing

Two specs ship with this system:

| Spec | Covers |
|---|---|
| `Tests/EventService.spec.lua` (875 lines) | The config contract, the weighted scheduler, the mutation-chance gate, the countdown format, the lifecycle guards, the real one-time mutation flow, the client text states, and the transition broadcast sequencing. |
| `Tests/EventMutation.spec.lua` (497 lines) | The real mutation flow end to end: spawn-with-mutation, the command-pipeline stamp, progressive cycles, the live icon update, the owner-only toast, slot-context eligibility, the toast format, hatch inheritance, and the mutation-icon mapping. |

**They need Roblox Studio.** There is no headless Luau runner in this
project. Run them from the TestEZ panel.

### What the specs pin

- `EventConfig.Validate()` returns **0** issues.
- `Base` is disabled, weight 0, and `IsStartable('Base') == false`.
- `Galaxy`: `DurationSeconds == 180`, `MutationIntervalSeconds == 30`,
  `Scheduling.Weight == 20`, `Assets.FolderName == 'Galaxy'`,
  `Time.ClockTime == 0`.
- `Snowfall`: `DurationSeconds == 180`, `MutationIntervalSeconds == 30`,
  `Weight == 20`, `Assets.FolderName == 'Snowfall'`.
- `Transition`: `FovMultiplier == 0.83`, `FovSeconds == 0.35`,
  `FlashDelaySeconds == 0.05`, `FlashInSeconds == 0.3`,
  `HoldSeconds == 0.3`, `FadeOutSeconds == 1`, `CoverSeconds == 0.65`,
  and `CoverSeconds >= FlashDelay + FlashIn + Hold` (0.65 >= 0.65
  exactly).
- `PickNextEventId(0) == 'Galaxy'`, `(0.19) == 'Galaxy'`,
  `(0.2) == 'Snowfall'`, `(0.39) == 'Snowfall'`, `(0.4) == nil`,
  `(0.99) == nil`.
- `RollMutationChance(0, 0) == false`, `(1, 0.999) == true`,
  `(0.05, 0) == true`, `(0.05, 0.5) == false`, `('nope', 0) == false`.
- `FormatCountdown(300) == '5:00'`, `(65) == '1:05'`, `(0) == '0:00'`,
  `(-9) == '0:00'`.
- The Galaxy light container order is pinned:
  `{ 'Map.MainIsland.PointLights', 'Base.PointLights' }`.
- The transition broadcast counts are pinned: **2/4/4/2/0** for the five
  broadcast scenarios.
- The client text states are exact: `'GALAXY EVENT ACTIVE'`,
  `'SNOWFALL EVENT IN 8:00'`, `'NORMAL'`.
- `Lighting.ClockTime` is restored to the **exact** pre-event value.

### The spec's own caveats

- `EventService.Start()` is **never** called in the spec — no threads
  are started.
- The spec uses the **real** `SpawnService` and the **live**
  `Workspace`; it fabricates
  `ServerStorage.Assets.OverheadGui.{Egg,Animal}OverheadGuiTemplate` and
  `ServerStorage.Assets.Decals.{GalaxyIcon,SnowfallIcon}` only when they
  are absent.
- The fake player is `{ UserId = 7001, Name = 'OwnerA' }`.
- The `EventMutation.spec.lua` docstring advertises "TEST A–J" but the
  body actually contains **TEST K** and inconsistent prefixes — the
  docstring is stale.

---

## Adapting to a New Game

1. **Copy the four files** to their original Roblox paths — see
   [`Setup.md`](Setup.md).
2. **Author your event definitions** in
   `ReplicatedStorage/Config/World/Events.lua`. To add an event (say
   `Volcano`):
   ```lua
   Events.Order = { 'Galaxy', 'Snowfall', 'Volcano' }
   Events.Events.Volcano = {
       Id = 'Volcano', Name = 'Volcano', DisplayName = 'VOLCANO',
       DurationSeconds = 180, MutationIntervalSeconds = 30,
       Scheduling = { Enabled = true, Weight = 20 },
       Assets = { FolderName = 'Volcano' },
       Mutations = { Magma = { MutationId = 'Magma', Chance = 0.5 } },
       Environment = { Colors = { Red = { Color = Color3.fromRGB(200,60,40),
           Targets = { 'Map.MainIsland.Paths' } } } },
       Time = { Override = true, ClockTime = 12 },
   }
   ```
   **No engine change is needed** for duration, chance, assets,
   mutations, time, map colours or the UI label — all of it is data.
   The mutation id must exist in `Config/Creatures/Mutations.lua`.
3. **Author the event assets** at
   `ServerStorage.Assets.Events.<FolderName>` — a Folder whose contents
   are cloned into the Workspace for the event's duration. A missing
   folder is a **warning**, not an error: the event still runs, just
   without the assets.
4. **Author the mutation** in `Config/Creatures/Mutations.lua` and, if
   you want a bespoke overhead icon, a decal at
   `ServerStorage.Assets.Decals.<YourIcon>` plus an overhead-GUI child
   named **exactly** by the mutation id.
5. **Map the colour targets to your map.** The `Map.` and `Base.`
   conventions assume `Workspace.Map` and `Workspace.Map.Bases` with
   one child per base. If your map is laid out differently, either
   rename your folders or extend `_mapRoot` / `_baseRoots` in
   `EnvironmentModifier` — that is the **only** place a path-specific
   branch belongs.
6. **Wire the bootstrap:**
   ```lua
   EventService.Init()    -- early, in the services block
   EventService.Start()   -- late, in the start loop
   ```
   `Start()` must come after `createRemotes()`.
7. **Install the client side.** `EventController` (the countdown
   banner) and `EventTransitionController` (the FOV + white flash) are
   **not** in this folder — take them from the `ClientPresentation`
   system, or write your own that reads the five `Event_*` attributes
   and the `EventTransition` remote.
8. **Decide whether the schedule should be global.** The per-server
   roll means two servers can run different events. If you need one
   global event, adopt the `CodesAndRewards` pattern (`DailyRewardsWeek` /
   `PlaytimeRewardsDay`): an atomic `UpdateAsync` selection in a
   DataStore, with the per-server engine reading it.
9. **Add a `Config.lua`-style surface if you want external tunables.**
   The shipped config already *is* the tunable surface — the
   `Config.lua` in this folder is a reference transcription only.
10. **Reconcile `LuckPoolOrder`.** If you install SharedUtilities but
    not this config, `ServerLuckService` has nothing to require.
    Consider moving that array to the SharedUtilities config where it
    belongs.
11. **Re-run the specs** in Studio after any config change —
    `EventConfig.Validate()` must return 0 issues, and the weighted
    roll expectations change if you touch the weights.
