# Events — Dependencies

Exact requires, remotes, assets and boot order for the Events system.

Paths are the **live Roblox** paths. The library copies sit under
`ReusableSystems/Systems/Events/Source/`.

---

## Module Requires

### `ServerScriptService/Event/EventService.lua`

Verbatim from the source:

```lua
local EventConfig = require(ReplicatedStorage.Config.World.Events)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local FunnelService = require(script.Parent.Parent.FunnelService)
local EnvironmentModifier = require(script.Parent.EnvironmentModifier)
local EventLights = require(script.Parent.EventLights)
```

`FunnelService` lives at `ServerScriptService/FunnelService.lua` — it is
**not** part of this system (see "Other Systems Required").

The following four are **lazy** requires, resolved on first use inside
`_services()` (line 98) and cached:

```lua
_spawnService = require(sss.Egg.SpawnService)      -- ServerScriptService.Egg.SpawnService
_playerService = require(sss.PlayerService)         -- ServerScriptService.PlayerService
_mutationService = require(sss.MutationService)     -- ServerScriptService.MutationService
_eggOverhead = require(sss.Egg.EggOverhead)         -- ServerScriptService.Egg.EggOverhead
```

They are deferred so that the event service can boot **before** the egg
and player subsystems exist. A missing one is logged and the affected
capability is disabled — it is **not** fatal.

A fifth lazy require, inline at line 624, fetches the notification
service only when an egg actually mutates:

```lua
return require(game:GetService('ServerScriptService').Base.NotificationService)
```

### `ServerScriptService/Event/EnvironmentModifier.lua`

```lua
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

Note the `script.Parent.Parent.Parent` — this module sits three levels
down (`ServerScriptService.Event.EnvironmentModifier`), so the walk
reaches `game`. If you move the module up one folder, this require
breaks.

### `ServerScriptService/Event/EventLights.lua`

```lua
local EnvironmentModifier = require(script.Parent.EnvironmentModifier)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

`EventLights` reuses `EnvironmentModifier`'s path resolver rather than
implementing its own.

### `ReplicatedStorage/Config/World/Events.lua`

**No requires.** It is a pure data module (it is `--!strict --!native`).

---

## Other Systems Required

| System / module | Why | Optional? |
|---|---|---|
| `ReplicatedStorage.Config.Creatures.Rarity` | `EventService` reads rarity display names to build the mutation notification text (`Rarity.RarityDisplayName`). | **Effectively yes** — a missing rarity config degrades the notification string, it does not break the event. But the live `src/` tree has it, so keep it. |
| `ReplicatedStorage.Utility.Debug` | Structured logging for all three modules. | No — the requires are non-deferred, so a missing `Debug` module fails the `require` of the whole service. |
| `ReplicatedStorage.Utility.Remotes` | The `EventTransition` remote registry entry. | No — same, non-deferred. |
| `ServerScriptService.FunnelService` | Analytics only: `FunnelService:LogStep(ownerPlayer, 'Event', 'EventParticipated' \| 'MutationReceived', {...})` (lines 761, 765). | **Yes** — it is a leaf analytics module and the comment says "never gameplay-critical". But the require is non-deferred, so the file must exist. Swap it for a stub if you do not want analytics. |
| `ServerScriptService.PlayerService` | Resolves an egg owner id to a `Player` (via `_TestSetPlayerResolver` in tests). | Yes — the resolution is wrapped and a miss is handled. |
| `ServerScriptService.Egg.SpawnService` | Enumerates the currently-spawned eggs that are eligible for mutation. | Yes — without it, `RunMutationCycle` finds no eggs. |
| `ServerScriptService.MutationService` | Applies the mutation to an egg. | Yes — without it, no egg is ever mutated. |
| `ServerScriptService.Egg.EggOverhead` | The overhead billboard above a mutated egg. | Yes — the notification text is skipped without it. |
| `ServerScriptService.Base.NotificationService` | The toast shown to the egg owner when their egg mutates. | Yes — a failed notification does not undo the mutation. |
| `Events.LuckPoolOrder` → `ServerLuckService` | **The reverse direction.** `Events.lua` defines `LuckPoolOrder` (line 554) and `ServerLuckService` (in the **SharedUtilities** system) reads it. | n/a — this system is the *provider* here. See the callout below. |

### The cross-system coupling that surprises people

`ReplicatedStorage/Config/World/Events.lua` contains a field that has
**nothing to do with events**:

```lua
Events.LuckPoolOrder = { 'Common', 'Uncommon', 'Rare', 'Epic', 'Legendary', 'Mythic' }
```

It is read by `ServerLuckService` in the **SharedUtilities** system, and
by nothing in this system. If you delete the Events system and keep
`ServerLuckService`, you break the luck roll. Either move
`LuckPoolOrder` into the SharedUtilities config, or keep Events installed.

Note also that it is **deliberately not** `Rarity.Order` — it favours
`Mythic` most, whereas `Rarity.Order` sorts `Mythic` below
`Legendary`.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `EventTransition` | **S → C** (broadcast to every client) | Two shapes, discriminated by `Phase`:<br>**Prepare** — `{ Phase = 'Prepare', Kind = 'Start' \| 'End', EventId, TransitionId, FovMultiplier, FovSeconds, FlashDelaySeconds, FlashInSeconds, FadeOutSeconds, CoverSeconds }`<br>**Reveal** — `{ Phase = 'Reveal', Kind, EventId, TransitionId }`<br>`TransitionId` is a **monotonic** number. Clients ignore a `Reveal` whose `TransitionId` does not match the `Prepare` they are animating, so a join or a dropped packet cannot leave a client stuck on a white screen. |

There is **no** client→server remote for this system. The client never
requests an event and never reports one — event state is published
through **ReplicatedStorage attributes**, not remotes.

The remote name comes from `ReplicatedStorage/Utility/Remotes.lua`
(`Names.EventTransition = 'EventTransition'`, line 208). The server
creates the folder at boot (see "Initialization Order", step 2).

---

## ReplicatedStorage Attributes (the real client feed)

These are set on the **`ReplicatedStorage` instance itself** by
`_publish()` (lines 294-317). They are the source of truth for the UI:

| Attribute | Type | Meaning |
|---|---|---|
| `Event_CurrentId` | `string` | The running event's id, or `''` when idle. |
| `Event_EndAt` | `number` | Unix timestamp when the current event ends (`0` when idle). |
| `Event_NextId` | `string` | The **pre-decided** next event's id, or `''` for "no event this cycle". |
| `Event_NextAt` | `number` | Unix timestamp of the next event opportunity. |
| `Event_Revision` | `number` | Monotonic counter, incremented on every publish. |

`_publish()` is wrapped in a `pcall` — if the attribute write fails the
increment still happened, so `Event_Revision` is the only thing that
guarantees a client can detect a change.

---

## Notification ids

| Notification id | Source | When |
|---|---|---|
| `Event_EggMutated` | `ReplicatedStorage/Config/Presentation/Messages.lua:335` — Category `'Event'`, Action `'Mutate'`, Message `'Your {EggName} got the {MutationName} mutation.'`, Sound `'Approved'`. | The owner of a successfully mutated egg. |

---

## Profile Fields

**None.** The Events system does not read or write player profile data.
Mutations are applied to the **egg** (an egg instance's data), not to
the player profile. The player is only used to resolve the owner for
the notification.

---

## DataStore

**None.** The Events system stores nothing on disk. Event selection is
in-memory and per-server, seeded from the scheduler.

---

## Studio Assets

| Path | What it is | Required? |
|---|---|---|
| `ServerStorage.Assets.Events.Galaxy` | A folder cloned into the Workspace for the Galaxy event. The clone is renamed `EventAssets_Galaxy` and destroyed when the event ends. | **No** — a missing folder logs a **warning** and the event runs without assets. |
| `ServerStorage.Assets.Events.Snowfall` | Same, for Snowfall. | **No** — same behaviour. |
| `Workspace.Map.MainIsland.Paths` | Recoloured grey by Snowfall. | **No** — an unresolved path is a warning and is skipped. |
| `Workspace.Map.MainIsland.Island.Grass` | Recoloured white by Snowfall. | No — same. |
| `Workspace.Map.MainIsland.Decor.Grass` | Recoloured white by Snowfall. | No — same. |
| `Workspace.Map.MainIsland.PointLights` | Lights forced on for Galaxy. | No — same. |
| `Workspace.Map.Bases.*` | Every child of `Bases` is a player base. `Base.Build.Paths`, `Base.Build.Island.Grass`, `Base.Build.Lamps.*.Bush` are resolved **inside every base**. | No — same. |
| `Lighting` | `Lighting.ClockTime` is overridden and restored. | The `Lighting` service always exists. |

The path convention is shared by `EnvironmentModifier` and `EventLights`:
`Map....` from the Workspace's `Map`, `Base....` inside every player
base, and `*` as a wildcard that fans out one path level.

---

## External APIs

**None.** No HTTP requests, no webhooks, no third-party services, no
credentials of any kind.

`DataStoreService` is not used by this system at all.

---

## Initialization Order

The exact sequence in `src/ServerScriptService/bootstrap.server.lua`:

| Step | Line | Action |
|---|---|---|
| 1 | `:222` | `createRemotes()` runs — the server creates the `Remotes` folder under ReplicatedStorage and every `RemoteEvent` in the registry, including `EventTransition`. **This must happen before `EventService.Init()`**, which waits for the remote. |
| 2 | `:371` | `local EventService = require(script.Parent.Event.EventService)` — the module is loaded. Its non-deferred requires (`Config.World.Events`, `Config.Creatures.Rarity`, `Utility.Debug`, `Utility.Remotes`, `FunnelService`) must all resolve at this point. |
| 3 | `:372` | `EventService.Init()` — validates the config, ensures the `EventTransition` remote exists, and publishes the initial state. |
| 4 | `:1292` | `EventService.Start()` — starts the heartbeat-driven tick and schedules the first event. |

`EventService.Init()` internally does
`Remotes.GetFolder():WaitForChild(Remotes.Names.EventTransition, 10)` — a
10 second timeout, after which it warns and continues. So if you forget
step 1, the service still boots, but the transition cinematic never
reaches the clients.

`Start()` is what actually schedules the first event, so the ordering
`Init()` → `Start()` matters. Calling `Start()` without `Init()` means
no remote is ensured.

### The lazy subsystems

`EventService` resolves `SpawnService`, `PlayerService`,
`MutationService` and `EggOverhead` **on first use**, not at boot. The
first mutation cycle happens `MutationIntervalSeconds` (30 s) after the
event starts, so the egg subsystem has time to come up. If a subsystem
is missing at that moment, the resolution fails, the failure is logged,
and the cycle finds nothing — it does **not** crash the tick.

### Admin command

`src/ServerScriptService/Cmdr/Server/Commands/eventServer.lua` drives
the service manually:

- `EndEvent('admin')` — line 70
- `StartEvent(id, 'admin')` — line 79
- a `status` verb

`_normalizeId` only maps `'galaxy'` → `'Galaxy'` and `'snowfall'` →
`'Snowfall'`; any other id is rejected, so the admin command cannot
start an event that is not in `Events.Events`.
