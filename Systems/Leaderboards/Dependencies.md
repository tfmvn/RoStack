# Leaderboards — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Leaderboard/LeaderboardService.lua`

```lua
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.StudioTestMode)
```

Engine services used:

```lua
game:GetService('Players')
game:GetService('DataStoreService')
game:GetService('RunService')
game:GetService('Workspace')
game:GetService('ReplicatedStorage')
```

### `ServerScriptService/TabList/TabListService.lua`

```lua
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.Debug)
require(ServerScriptService.Leaderboard.LeaderboardService)  -- for FormatMoney
```

Engine services used:

```lua
game:GetService('Players')
game:GetService('RunService')
game:GetService('ReplicatedStorage')
game:GetService('ServerScriptService')
```

**`TabListService` requires `LeaderboardService`.** That is a leaf-to-leaf
dependency (a display-formatter reuse), not a cycle — `LeaderboardService`
never requires `TabListService` back. If you copy only the tab list you must
also copy `LeaderboardService` (or replace the one `FormatMoney` call).

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **PlayerData** (`PlayerService`) | `GetPlayerData(userId)` — the "is the profile loaded?" check before a snapshot or a `leaderstats` write. | **Required.** Without it every snapshot returns `nil` and neither board ever shows a value. |
| **Economy** (`EconomyService`) | `GetMoney(userId): string` — the only source of the money value on the global board, and the `Money` stat on the tab list. | **Required.** The global board has no fallback. |
| **Rebirth** (`RebirthService`) | `GetRebirth(userId): number` — the `Rebirths` stat on the tab list. | **Required for the tab list only.** The global board is money-only and never reads rebirths. If `RebirthService` is unwired, `TabListService.RefreshValues` returns `false` and the tab list stays **empty** — it does not degrade to money-only. |
| **Shared utilities** (`BigNumber`, `Debug`, `StudioTestMode`) | Money canonicalisation, logging, and Studio test-UserId exclusion. | **Required.** `StudioTestMode` in particular is what keeps a Studio multi-instance test from polluting the global board. |

No other system is required. The Leaderboards system is a **leaf** in the
dependency graph: it only reads other services through injected refs.

---

## Remotes

**None.** Neither service creates, reads, or fires a remote.

This is deliberate and load-bearing: the whole design is server-authoritative.
A client never submits a leaderboard value. The global board's values come
from `EconomyService.GetMoney` (server-side profile data) and the tab list's
values come from `EconomyService.GetMoney` / `RebirthService.GetRebirth`.

The CoreGui `PlayerList` (the TAB menu) is a **built-in** UI, not a remote.
It is kept enabled in `StarterPlayerScripts/bootstrap.client.lua:112`; do not
disable it.

---

## Profile Fields Read / Written

**Read only.** Neither service writes to the profile.

| Source | Read via | Field | Used for |
|---|---|---|---|
| `PlayerService` | `GetPlayerData(userId)` | *(existence only)* | Gate: is the profile loaded? |
| `EconomyService` | `GetMoney(userId)` | `Money` (BigNumber string) | The global board score and the tab list `Money` stat. |
| `RebirthService` | `GetRebirth(userId)` | `Rebirth` | The tab list `Rebirths` stat. |

The global board and the tab list do **not** read each other's values.
`LeaderboardService.EncodeScore` is never used by `TabListService`.

Nothing in the profile is written by this system, and nothing is persisted in
the profile by it.

---

## DataStore

| Property | Ordered (scores) | Meta (exact values) |
|---|---|---|
| Name | `p7_GlobalLeaderboardMoney_v1` | `p7_GlobalLeaderboardMeta_v1` |
| Type | `OrderedDataStore` | `GlobalDataStore` (via `DataStoreService:GetDataStore`) |
| Key | `tostring(userId)` | `tostring(userId)` |
| Value | `number` — the encoded score | `{ m = <money string>, n = <username> }` |
| Scope | unset (a plain string name) | unset |

The names are **hardcoded literals** in the service module
(`LeaderboardService.lua:83` and `:89`). There is no environment suffix
computation — a new game MUST change both, or it will read another game's
rows.

**Encoding** (see `MEMORY.md` for the full derivation):

```
score = orderOfMagnitude * 1_000_000 + first6SignificantDigits
```

clamped to `[0, 10_000_000_000)`. Integer-only, exactly representable in a
Lua double, well inside the `OrderedDataStore` integer limit.

**The meta store exists because an `OrderedDataStore` can only hold
integers.** The exact BigNumber fortune cannot be stored in the ordered
store, so the companion meta store holds it for exact display.

---

## Initialization Order

The source game's bootstrap does this (all line numbers in
`src/ServerScriptService/bootstrap.server.lua`):

```text
1.  require the two services (bootstrap.server.lua:150, :156)
      -- leaf-shaped: only shared utility leaves are loaded at
      -- require time; no server authorities are taken

2.  RebirthService.Init()                         (:493)

3.  LeaderboardService.SetPlayerService(PlayerService)   (:501)
    LeaderboardService.SetEconomyService(EconomyService)   (:502)

4.  TabListService.SetPlayerService(PlayerService)        (:506)
    TabListService.SetEconomyService(EconomyService)        (:507)
    TabListService.SetRebirthService(RebirthService)        (:508)

    ... other services initialise ...

5.  LeaderboardService.Start()                    (:1311)
    TabListService.Start()                        (:1316)
    -- placed AFTER the income loop is set up, so the join-time
    -- scans already see settled profiles
```

### Runtime hooks

| Event | Call | Line |
|---|---|---|
| `Players.PlayerAdded` | `LeaderboardService.RequestRefresh()` | `:1175` |
| `Players.PlayerAdded` | `TabListService.RequestRefresh()` | `:1178` |
| `Players.PlayerRemoving` | `LeaderboardService.OnPlayerLeaving(player)` | `:1187` |
| `Players.PlayerRemoving` | `TabListService.RequestRefresh()` | `:1190` |
| `Players.PlayerRemoving` (late) | `LeaderboardService.ForgetPlayer(userId)` | `:1274` |
| Committed rebirth | `LeaderboardService.MarkDirty(userId)` | `RebirthService.lua:1107` (lazy require, `pcall`-wrapped) |
| Committed rebirth | `TabListService.MarkDirty()` | `RebirthService.lua:1110` (lazy require, `pcall`-wrapped) |

**The critical ordering constraint:** `LeaderboardService.OnPlayerLeaving`
must run **before** `PlayerService.CleanupPlayer` releases the profile. It
takes a synchronous snapshot, so it must be the *first* thing in the
`PlayerRemoving` handler. If the profile is already released, the snapshot is
`nil` and the player's final money value is never written.

`RebirthService` calls `MarkDirty` through **lazy `require` inside a
`pcall`**, not through injection — because `LeaderboardService` is a leaf and
a top-level require from `RebirthService` would create a load-order
dependency. `MarkDirty` never yields and never throws, so it is safe inside
the rebirth release path.

`MarkDirty` **enqueues**; it does not write. The DataStore write still waits
for the next flush (≤ `FLUSH_SECONDS` = 15 s).

---

## Studio Assets

### `Workspace.Map.LeaderBoard.Display` — the global board

The board is rendered on a real `Part` with a `SurfaceGui`. The service
resolves this hierarchy in `findBoard()` (`LeaderboardService.lua:568`) and
**returns `nil` (rendering nothing) if any piece is missing or of the wrong
class.** The service does not create any of it.

```text
Workspace
└── Map
    └── LeaderBoard
        └── Display            (BasePart / Part — must be a BasePart)
            └── <SurfaceGui>   (any SurfaceGui child; found via FindFirstChildOfClass)
                ├── Rank       (TextLabel) — top player, rank
                ├── Name       (TextLabel) — top player, name
                ├── Money      (TextLabel) — top player, fortune
                ├── ResetTime  (TextLabel) — "UPDATE IN 45S" countdown
                └── List       (ScrollingFrame)
                    ├── Template    (Frame) — clone source, NEVER shown
                    │   ├── Rank    (TextLabel)
                    │   ├── Name    (TextLabel)
                    │   └── Money   (TextLabel)
                    ├── Row1        (Frame) — created at runtime by cloning Template
                    ├── Row2
                    └── ...
```

Required properties, checked by `findBoard()`:

| Instance | Required type | Notes |
|---|---|---|
| `Workspace.Map.LeaderBoard.Display` | `BasePart` | Anything else → board skipped. |
| `Display.<SurfaceGui>` | `SurfaceGui` | Found by class, so the name is free. |
| `SurfaceGui.List` | `ScrollingFrame` | Must be a `ScrollingFrame`. |
| `SurfaceGui.Rank` / `.Name` / `.Money` / `.ResetTime` | `TextLabel` | The top-player block. |
| `List.Template` | `Frame` | The clone source. |
| `Template.Name` / `.Money` / `.Rank` | `TextLabel` | Filled in on each clone. |

**Row ordering** is driven by `row.LayoutOrder`, which the service sets to
the rank. Put a **`UIListLayout`** inside `List` with `SortOrder =
LayoutOrder` (the default) so the rows appear in rank order. The service
does not create the layout.

**Row pooling:** the service reuses children of `List` whose name matches
`^Row%d+$`. It clones `Template` and names the clone `'Row' .. i`. If you
name your authored rows something else, the service will simply create new
clones and your authored rows will sit in the list as junk. Either leave `List`
with only `Template` inside it, or name the rows `Row1`, `Row2`, ….

**`Template` must be hidden** — the service sets `template.Visible = false`
on every render, but a `Template` with `Visible = true` will flash in the
list between renders.

### `ServerStorage` / `ReplicatedStorage`

**None.** Neither service reads any asset from `ServerStorage` or
`ReplicatedStorage` beyond the utility modules it requires.

### The tab list

**Nothing to author.** The native CoreGui `PlayerList` renders
`player.leaderstats`. The only requirement is that the player list is **not**
disabled in `StarterPlayerScripts/bootstrap.client.lua` (the source game
keeps it enabled at `:112`).

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `DataStoreService` | `OrderedDataStore` + `GlobalDataStore` reads/writes for the global board. | `Enable Studio Access to API Services` in Studio; a published place needs no toggle. |
| `Players` | Player lifecycle, `GetPlayerByUserId`, `GetNameFromUserIdAsync` (for offline display names). | — |

No HTTP. No Marketplace. No webhooks. **No API keys, tokens, or credentials
of any kind** — the two store names are not secrets, but they *are*
environment-specific and must be changed per game.
