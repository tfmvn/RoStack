# PlayerLogging — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/PlayerLogger/PlayerLogger.lua`

```lua
local Config        = require(script.Parent.PlayerLoggerConfig)
local PlayerRegistry = require(script.Parent.PlayerRegistry)
local Debug         = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

Roblox services obtained at runtime:

```lua
local HttpService         = game:GetService('HttpService')
local ServerScriptService = game:GetService('ServerScriptService')
```

`ServerScriptService` is used for `GetAttribute` only.
`HttpService` is used for `JSONEncode` and `RequestAsync`.

### `ServerScriptService/PlayerLogger/PlayerRegistry.lua`

```lua
local Config = require(script.Parent.PlayerLoggerConfig)
local Debug  = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

Roblox services:

```lua
local DataStoreService = game:GetService('DataStoreService')
```

### `ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua`

A **leaf** — it requires nothing.

### Lazy require (not at load time)

Inside `PlayerLogger._progressSnapshot`:

```lua
local sss = game:GetService('ServerScriptService')
local okPs, playerService = pcall(require, sss:WaitForChild('PlayerService', 2))
```

This is the **only** reference to a gameplay service, and it is
deliberately lazy: it keeps `PlayerLogger` cycle-free and lets it work
in a server where `PlayerService` has not been created yet.

The only method used on it is:

```lua
playerService.GetPlayerData(userId) -> { [string]: any }?
```

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | `Debug.Log` / `Debug.Warn` for every diagnostic. | **Required** — both modules fail to load without it. |
| **PlayerData** | `ServerScriptService.PlayerService` | Lazy. `GetPlayerData(userId)` supplies the progression snapshot. | **Optional in practice** — without it the snapshot falls back to `{rebirths = 0, arenaLevel = 1, arenaWins = 0, tutorialCompleted = false}`. |

### Systems that call *into* this one (callers, not dependencies)

| System | Call | Where |
|---|---|---|
| Bootstrap | `PlayerLogger.NotifyJoin(player)` | the `Players.PlayerAdded` tail |
| Bootstrap | `PlayerLogger.NotifyLeave(player)` | the `Players.PlayerRemoving` handler |
| **Tutorials** | `PlayerLogger.LogMilestone(player, 'TutorialCompleted', nil)` | `TutorialService`, on real completion |
| **Arena** | `PlayerLogger.LogMilestone(player, 'ArenaCompleted', { stage = n })` | the raid-complete branch |
| **Rebirth** | `PlayerLogger.LogMilestone(player, 'RebirthSucceeded', { rebirth = n })` | the success branch |
| **ShopsAndPurchases** | `PlayerLogger.LogMilestone(player, 'PurchaseGranted', { product_key = ..., kind = ... })` | the granted branch (once per `PurchaseId`) |

These are all **optional** from `PlayerLogger`'s point of view — the
logger works with zero callers.

---

## Remotes

**None.** The system creates no remotes, listens to none, and sends
nothing to clients. It is entirely server → Discord + server →
DataStore.

---

## Profile Fields Read / Written

### Gameplay profile: **read only, and only via `PlayerService`**

`PlayerLogger._progressSnapshot` reads four scalars through
`PlayerService.GetPlayerData(userId)`:

| Field | Path | Type | Used for |
|---|---|---|---|
| Rebirth count | `data.Rebirth` | number | the `Rebirths` embed field, the registry `rebirths` snapshot |
| Arena level | `data.Arena.Level` | number (min 1) | the registry `arenaLevel` snapshot |
| Arena wins | `data.Arena.Wins` | number | the registry `arenaWins` snapshot |
| Tutorial done | `data.Tutorial.Completed == true` | boolean | the registry `tutorialCompleted` snapshot |

**Nothing in the gameplay profile is written.** The registry is a
**separate DataStore**; the two never mix.

### Registry DataStore: written

Store: `p7_PlayerRegistry_v1` (from `Config.RegistryStoreName`).
Key: `player_<userId>` (from `Config.RegistryKeyPrefix`).

| Field | Direction | Rule |
|---|---|---|
| `userId` | write | set |
| `username` | write | overwritten only when non-empty |
| `displayName` | write | overwritten only when non-empty |
| `firstSeen` | write | set on creation, never moved |
| `lastSeen` | write | `max()` — monotonic |
| `sessions` | write | `+1` per join (`sessionsAdd`) |
| `playtimeSeconds` | write | `+` the session duration (`playtimeAdd`) |
| `rebirths` | write | `max()` — never downgraded |
| `arenaLevel` | write | `max()` — never downgraded |
| `arenaWins` | write | `max()` — never downgraded |
| `tutorialCompleted` | write | `OR` — never downgraded |
| `lastJobId` | write | overwritten only when non-empty |

All writes go through `DataStoreService:UpdateAsync` with the pure
merge as the transform, so there is **no read on the hot path**.

---

## Required Studio Assets

**None in `Workspace` or `ServerStorage`.**

The one Studio-side requirement is a **string attribute**:

```
ServerScriptService
└── (Attributes)
    └── PlayerLoggerWebhookUrl = "https://discord.com/api/webhooks/<id>/<token>"
```

Set it in the Studio **place file** (the `.rbxl`), not in a script, so
it never enters version control. Alternatively, set it at runtime
before `PlayerLogger.Init()`.

**Game setting:** `HttpService.HttpEnabled` must be `true`. In the
live game this is **Game Settings → Security → Allow HTTP Requests**.
("Enable Studio Access to API" is *not* the same thing and is not
enough.)

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `HttpService:RequestAsync` | `POST` the embed to the Discord webhook. | The game's HTTP Requests setting must be enabled. |
| `HttpService:JSONEncode` | Serialise `{ username, embeds }`. | — |
| `DataStoreService:UpdateAsync` | The registry (one key per player). | Standard DataStore access; the store is created implicitly on first write. |
| `DataStoreService:GetDataStore` | The registry store handle. | Same. |

### Discord webhook URL — placeholder only

The webhook URL is a **secret**. It is:

- read from a `ServerScriptService` **attribute name**
  (`Config.WebhookAttribute` = `'PlayerLoggerWebhookUrl'`);
- validated against `^https://discord%.com/api/webhooks/`;
- stored in a module-local variable and never returned by any
  function;
- **never logged** — no diagnostic includes it, and the HTTP response
  body (which can echo the URL) is never read;
- **never replicated** — it lives in a server-side module local, not
  in `ReplicatedStorage`.

**Never commit the real URL.** See `Setup.md` §5.

---

## Initialization Order

```text
1. PlayerService.Init()                  -- so the snapshot has data
2. Set the ServerScriptService attribute 'PlayerLoggerWebhookUrl'
   (place file, or at runtime before step 3)
3. PlayerLogger.Init()
     - reads the attribute ONCE
     - probes HttpService.HttpEnabled
     - starts the delivery worker (task.spawn)
     - registers the BindToClose flush
4. Players.PlayerAdded    -> PlayerLogger.NotifyJoin(player)
5. Players.PlayerRemoving -> PlayerLogger.NotifyLeave(player)
6. Gameplay commit paths  -> PlayerLogger.LogMilestone(player, kind, details)
```

**Step 2 before step 3 is mandatory** — `_webhookUrl` is captured once,
at `Init()`.

**Step 3 before step 4** — otherwise `_enabled` is false and the join
embed is dropped (the registry write still happens).

**Step 5 before the profile is released** — `NotifyLeave` reads the
profile snapshot synchronously.

`PlayerLogger.Init()` is idempotent (`_workerStarted` guard).

---

## Require-cycle notes

Neither module requires a gameplay service at load time. `PlayerService`
is reached through a lazy `WaitForChild` inside a `pcall`, so:

- `PlayerService` may require `PlayerLogger` without a cycle;
- `PlayerLogger` works in a server where `PlayerService` does not exist
  (the snapshot degrades to defaults);
- `TutorialService`, `ArenaService`, `RebirthService` and the shop
  service may all call `LogMilestone` without ordering constraints.
