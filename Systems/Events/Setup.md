# Events — Setup

Installing the Events system into a new Rojo project.

---

## 1. Copy the files

Four files, at four Roblox paths:

```bash
SRC=ReusableSystems/Systems/Events/Source
DST=your-project/src

mkdir -p "$DST/ReplicatedStorage/Config/World"
mkdir -p "$DST/ServerScriptService/Event"

cp "$SRC/ReplicatedStorage/Config/World/Events.lua"      "$DST/ReplicatedStorage/Config/World/"
cp "$SRC/ServerScriptService/Event/EventService.lua"      "$DST/ServerScriptService/Event/"
cp "$SRC/ServerScriptService/Event/EnvironmentModifier.lua" "$DST/ServerScriptService/Event/"
cp "$SRC/ServerScriptService/Event/EventLights.lua"       "$DST/ServerScriptService/Event/"
```

| Library path | Roblox destination |
|---|---|
| `Source/ReplicatedStorage/Config/World/Events.lua` | `ReplicatedStorage.Config.World.Events` |
| `Source/ServerScriptService/Event/EventService.lua` | `ServerScriptService.Event.EventService` |
| `Source/ServerScriptService/Event/EnvironmentModifier.lua` | `ServerScriptService.Event.EnvironmentModifier` |
| `Source/ServerScriptService/Event/EventLights.lua` | `ServerScriptService.Event.EventLights` |

**Do not move `EnvironmentModifier` or `EventLights` out of
`ServerScriptService/Event/`.** They reach `ReplicatedStorage.Utility.Debug`
through `script.Parent.Parent.Parent`, which is a fixed three-level walk
from `ServerScriptService/Event/`. Moving them up one folder breaks the
require; moving them down adds a level and breaks it too.

The tests are optional and separate — see step 8.

---

## 2. Third-party packages (Wally)

**None.** The system uses only built-in Roblox services.

---

## 3. Install the required shared modules

These live in the **shared** library (`ReusableSystems/Shared/`) or in
the source game's tree. The system does not ship them.

| Roblox path | What it is | Where to get it |
|---|---|---|
| `ReplicatedStorage.Utility.Debug` | The gated logging module. | Shared library `Utilities/Debug`. **Non-deferred require — a missing file fails the whole service.** |
| `ReplicatedStorage.Utility.Remotes` | The remote registry (`Remotes.Names.EventTransition`). | Shared library `Utilities/Remotes`. **Also non-deferred.** |
| `ReplicatedStorage.Config.Creatures.Rarity` | Rarity display names, for the mutation toast. | The creatures config domain. |
| `ServerScriptService.FunnelService` | Analytics leaf. | The analytics system. A stub is fine. |
| `ServerScriptService.PlayerService` | owner-id → `Player`. | The player system. |
| `ServerScriptService.Egg.SpawnService` | Enumerates live eggs. | The egg system. |
| `ServerScriptService.MutationService` | Applies a mutation. | The mutation system. |
| `ServerScriptService.Egg.EggOverhead` | The overhead billboard. | The egg system. |
| `ServerScriptService.Base.NotificationService` | The toast. | The notification system. |

The four lazy ones (`SpawnService`, `PlayerService`, `MutationService`,
`EggOverhead`) are resolved on first use, so a missing one degrades the
feature instead of failing the boot. The two non-deferred ones (`Debug`,
`Remotes`) **must** exist.

If you do not want analytics, replace `FunnelService` with a stub
module that has a `LogStep` method:

```lua
-- ServerScriptService/FunnelService.lua
local FunnelService = {}
function FunnelService:LogStep() end
return FunnelService
```

---

## 4. Configure

There is **no `Config.lua`** for this system — its configuration is the
live `ReplicatedStorage/Config/World/Events.lua`, which ships in the
system's `Source/` tree. The library's
[`Config.lua`](Config.lua) is a **documented reference transcription**,
not something to edit.

Tune these in `Events.lua`:

| Key | Default | Notes |
|---|---|---|
| `Events.Scheduler.CycleSeconds` | `300` | Seconds between event opportunities. Must be `>= 10`. |
| `Events.Scheduler.NoneWeight` | `60` | The "no event" bucket. Rescales every event's effective probability. |
| `Events.Order` | `{ 'Galaxy', 'Snowfall' }` | The deterministic roll order. Must not contain `'Base'`. |
| `Events.Events.Galaxy.Scheduling.Weight` | `20` | |
| `Events.Events.Snowfall.Scheduling.Weight` | `20` | |
| `Events.Events.<id>.DurationSeconds` | `180` | How long the event runs. |
| `Events.Events.<id>.MutationIntervalSeconds` | `30` | The progressive mutation cadence. |
| `Events.Events.<id>.Mutations.<mutation>.Chance` | `0.8` | A fraction in `[0, 1]`, evaluated per egg per cycle. |
| `Events.Events.<id>.Assets.FolderName` | `'Galaxy'` / `'Snowfall'` | The folder under `ServerStorage.Assets.Events`. |
| `Events.Events.<id>.Environment.Colors` | see the file | Target paths + colours. |
| `Events.Events.<id>.Lights.Containers` | see the file | Light container paths. |
| `Events.Events.<id>.Time` | `Override` + `ClockTime` | The clock override, restored exactly afterwards. |
| `Events.Transition.*` | see `Config.lua` | The cinematic. **`CoverSeconds` must be `>= FlashDelay + FlashIn + Hold`** — with the shipped values that floor is exactly `0.65`. |

### The path convention

Used by `Environment.Colors.*.Targets` and `Lights.Containers`:

| Form | Resolves to |
|---|---|
| `Map.MainIsland.Paths` | `Workspace.Map.MainIsland.Paths` |
| `Base.Build.Paths` | `<every base>/Build/Paths` — one path inside **each** child of `Workspace.Map.Bases` |
| `Base.Build.Lamps.*.Bush` | `Bush` under **every** `Lamp`, in every base, however many exist |

`'*'` matches all children at that exact level and then continues
resolving the rest of the path against each match. A plain name never
fans out.

### `Events.LuckPoolOrder` — a note

This field is in the Events config but is read by **`ServerLuckService`**
(in the SharedUtilities system), not by anything here. If you keep
`ServerLuckService`, keep this field or move it into the SharedUtilities
config.

### Debug output

The system logs through the shared `Debug` module with the tag
**`'EV'`**. Enable it with `Systems.Debug.ServerDebug = true` (and add
`'EV'` to the `Tags` whitelist if you use one). `EnvironmentModifier`
and `EventLights` use the same `'EV'` tag.

---

## 5. Author the Studio assets

Optional — everything degrades to a warning if it is missing.

### 5a. Event asset folders (in ServerStorage)

```
ServerStorage
└── Assets
    └── Events
        ├── Galaxy/     -- anything; cloned into Workspace during the event
        └── Snowfall/
```

The folder is cloned into the Workspace, renamed `EventAssets_Galaxy`
(or `EventAssets_Snowfall`), and **destroyed** when the event ends. A
missing folder logs a warning and the event still runs.

### 5b. Map targets (in Workspace)

For Snowfall's recolour:

```
Workspace
└── Map
    ├── MainIsland
    │   ├── Paths
    │   ├── Island
    │   │   └── Grass
    │   ├── Decor
    │   │   └── Grass
    │   └── PointLights        -- for Galaxy
    └── Bases
        ├── Base_1
        │   └── Build
        │       ├── Paths
        │       ├── Island
        │       │   └── Grass
        │       └── Lamps
        │           └── Lamp_1
        │               └── Bush
        └── Base_2
            └── ...
```

Every child of `Bases` is a player base, and the `Base....` targets are
resolved inside **all** of them.

---

## 6. Wire it up

### 6a. Create the remotes

The `EventTransition` remote must exist before `EventService.Init()`.
The shared `Remotes` module owns the registry; the standard pattern in
this codebase is a `createRemotes()` helper in the bootstrap that
creates the folder and every `RemoteEvent` in `Remotes.Names`.

`EventService.Init()` also does
`Remotes.GetFolder():WaitForChild(Remotes.Names.EventTransition, 10)`,
so a missing remote is a 10-second stall followed by a warning — the
service still boots, but clients never see the cinematic.

### 6b. The bootstrap sequence

In your `ServerScriptService/bootstrap.server.lua`:

```lua
-- 1. remotes first (your existing createRemotes() helper)
createRemotes()

-- 2. require
local EventService = require(script.Parent.Event.EventService)

-- 3. init
EventService.Init()

-- 4. start (late, after the rest of the world is up)
EventService.Start()
```

`Init()` sets `_started` and resolves the lazy subsystems.
`Start()` connects `RunService.Heartbeat` to the tick and calls
`ScheduleNext('boot')` — the first event opportunity is scheduled from
**that** moment, so the first event can start up to
`Scheduler.CycleSeconds` later.

Both are idempotent: calling `Init()` twice is a no-op (`_started`),
and calling `Start()` twice is a no-op (`_tickConn ~= nil`).

### 6c. The admin command (optional)

The source game exposes a Cmdr command at
`ServerScriptService/Cmdr/Server/Commands/eventServer.lua`:

```lua
EventService.EndEvent('admin')
EventService.StartEvent(id, 'admin')
```

Copy that file, or wire your own command to the same two calls. Note
that `StartEvent` returns `(boolean, string?)` — the string is the
failure reason.

### 6d. The client (optional)

The client needs **no** event code beyond reading the ReplicatedStorage
attributes:

```lua
-- current event id
local currentId = ReplicatedStorage:GetAttribute('Event_CurrentId')
-- when it ends
local endAt = ReplicatedStorage:GetAttribute('Event_EndAt')
-- the next pre-decided event
local nextId = ReplicatedStorage:GetAttribute('Event_NextId')
local nextAt = ReplicatedStorage:GetAttribute('Event_NextAt')
-- change detector
local revision = ReplicatedStorage:GetAttribute('Event_Revision')
```

For the cinematic, listen to the `EventTransition` remote and honour
the `TransitionId` handshake — ignore a `Reveal` whose `TransitionId`
does not match the `Prepare` you are animating.

---

## 7. Smoke test

### 7a. The service boots

Start the server. In the Output window you should see (with debug on):

```
[EV] EventService initialized
[EV] EventService started
```

And `ReplicatedStorage` should now carry the attributes:

```lua
print(ReplicatedStorage:GetAttribute('Event_CurrentId'))  -- '' (idle)
print(ReplicatedStorage:GetAttribute('Event_NextId'))      -- '' or 'Galaxy'/'Snowfall'
print(ReplicatedStorage:GetAttribute('Event_Revision'))   -- >= 1
```

### 7b. Force an event

```lua
local EventService = require(ServerScriptService.Event.EventService)
print(EventService.StartEvent('Galaxy', 'admin'))
```

Expect `true`. The clock should snap to night, the `Galaxy` asset
folder should appear in the Workspace as `EventAssets_Galaxy`, and the
`Map.MainIsland.PointLights` lights should be on.

### 7c. The end restores the world

```lua
print(EventService.EndEvent('admin'))
```

Expect `true`. The clock returns to its **exact** prior value (not
`14`), the asset clone is gone, the grass/paths are back to their
original colours, and the lights return to their prior `Enabled` state
(a light that was authored ON stays ON).

### 7d. The transition handshake

With a client connected, watch the `EventTransition` remote. You should
see a `Prepare` with `Kind = 'Start'`, then — after `CoverSeconds` —
a `Reveal` with the **same** `TransitionId`.

If you see a `Reveal` with a *different* `TransitionId` than the
`Prepare` you were animating, the client must ignore it. That is the
"stuck white screen" guard.

### 7e. The mutation cadence

With the Galaxy event running and eggs in the world, wait
`MutationIntervalSeconds` (30 s). The first cycle should mutate at
most the eggs that pass the `Chance` roll. It should **not** mutate
everything at once — that is the whole point of the progressive
cadence.

### 7f. The scheduler

```lua
print(EventService.PickNextEventId())        -- 'Galaxy' | 'Snowfall' | nil
print(EventService.FormatCountdown(120))      -- '02:00'
```

`PickNextEventId` returning `nil` means "normal cycle, no special
event" — that is the `NoneWeight = 60` bucket, not a failure.

### 7g. The config validator

```lua
local Events = require(ReplicatedStorage.Config.World.Events)
local issues = Events.Validate()
for _, i in ipairs(issues) do print('ISSUE: ' .. i) end
```

An empty table means clean. Try setting `Transition.CoverSeconds = 0.1`
and confirm it reports
`'Transition.CoverSeconds must cover FlashDelay + FlashIn + Hold'`.

---

## 8. The tests

The specs live in `ReusableSystems/Systems/Events/Tests/`:

- `EventService.spec.lua`
- `EventMutation.spec.lua`

They are **TestEZ** specs and they need **Roblox Studio** — there is no
headless Luau runner in this project.

To run them in a new project, copy them into a TestEZ-enabled tree
(see `ReusableSystems/Shared/CommonModules/` for the TestEZ setup used
by the source game) and point them at the installed source paths. The
specs require the modules by their **live Roblox paths**, so the files
must be installed exactly as in step 1.

The specs rely on the `_Test*` seams:

| Seam | What it overrides |
|---|---|
| `EventService._TestSetPlayerResolver(fn)` | owner-id → `Player` resolution |
| `EventService._TestSetLightsRoots(mapRoot, baseRoots)` | the `Map` root and the base list |
| `EventService._TestSetTransitionCover(seconds)` | the `CoverSeconds` wait |
| `EventService._TestBroadcasts()` | the captured transition payloads |
| `EventService._TestIsTransitioning()` | whether a transition is in flight |
| `EventService._TestReset()` | resets module state |
| `EnvironmentModifier._TestResolveCount(target, mapRoot, baseRoots)` | how many instances a path resolves to |
| `EventLights._TestCollectCount(target, mapRoot, baseRoots)` | how many lights a path resolves to |

**Warning:** `EventService._TestReset()` does **not** reset `_started`,
`_tickConn`, `_runId` or `_accum`. A spec that calls `Start()` and then
`_TestReset()` leaves a **live heartbeat connection** running the tick
against a reset module.

---

## 9. Production checklist

- [ ] The four files are at their exact Roblox paths.
- [ ] `ReplicatedStorage.Utility.Debug` and `ReplicatedStorage.Utility.Remotes` exist.
- [ ] `FunnelService` exists (or is stubbed).
- [ ] `createRemotes()` runs **before** `EventService.Init()`.
- [ ] `EventService.Init()` and `EventService.Start()` are both called.
- [ ] `Events.Validate()` returns an empty table.
- [ ] `Transition.CoverSeconds >= FlashDelay + FlashIn + Hold`.
- [ ] `Events.Order` does not contain `'Base'`.
- [ ] The event asset folders exist in `ServerStorage.Assets.Events` (or you accept the warnings).
- [ ] The map target paths resolve (test with `EnvironmentModifier._TestResolveCount`).
- [ ] `Events.LuckPoolOrder` is kept if you use `ServerLuckService`.
- [ ] A client reads the five `Event_*` attributes and honours the `TransitionId` handshake.
