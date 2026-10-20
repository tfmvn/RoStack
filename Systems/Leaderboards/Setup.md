# Leaderboards — Setup

Installing the Leaderboards system into a new Rojo project.

Assumes the `PlayerData`, `Economy`, and `Rebirth` systems are already in
place (they are hard dependencies — see `Dependencies.md`).

---

## 1. Copy the source files

| From the library | To your project (Roblox path) |
|---|---|
| `Systems/Leaderboards/Source/ServerScriptService/Leaderboard/LeaderboardService.lua` | `ServerScriptService/Leaderboard/LeaderboardService.lua` |
| `Systems/Leaderboards/Source/ServerScriptService/TabList/TabListService.lua` | `ServerScriptService/TabList/TabListService.lua` |

In a Rojo project with `src/` mirroring Roblox paths:

```bash
cp -r ReusableSystems/Systems/Leaderboards/Source/ServerScriptService/Leaderboard \
      src/ServerScriptService/
cp -r ReusableSystems/Systems/Leaderboards/Source/ServerScriptService/TabList \
      src/ServerScriptService/
```

If your project is not Rojo, place the two files in Studio at the same paths.
`TabListService` requires `ServerScriptService.Leaderboard.LeaderboardService`
by path, so the `Leaderboard` folder must exist even if you only want the
tab list.

## 2. Third-party packages

**None.** The Leaderboards system has no Wally dependencies. It uses only
Roblox engine services plus these three shared library modules, which you
already have if you copied the `Shared/` tree:

- `ReplicatedStorage.Utility.BigNumber`
- `ReplicatedStorage.Utility.Debug`
- `ReplicatedStorage.Utility.StudioTestMode`

(`StudioTestMode` is what excludes Studio test UserIds `0, -1, -2…` from the
global board. If you omit it, a Studio multi-instance test will write real
rows to your leaderboard.)

## 3. Configure

### 3.1 Change the DataStore names — mandatory

`ServerScriptService/Leaderboard/LeaderboardService.lua:83` and `:89`:

```lua
LeaderboardService.ORDERED_STORE_NAME = 'p7_GlobalLeaderboardMoney_v1'
LeaderboardService.META_STORE_NAME    = 'p7_GlobalLeaderboardMeta_v1'
```

Replace with names unique to your game **and** your environment:

```lua
local GAME_PREFIX = 'MyGame'
local ENV = RunService:IsStudio() and 'dev' or 'live'
LeaderboardService.ORDERED_STORE_NAME = ('%s_GlobalLeaderboardMoney_v1_%s'):format(GAME_PREFIX, ENV)
LeaderboardService.META_STORE_NAME    = ('%s_GlobalLeaderboardMeta_v1_%s'):format(GAME_PREFIX, ENV)
```

Changing the name **abandons** the old rows. There is no migration.

### 3.2 Tune the constants

All tunables live in one block at the top of `LeaderboardService.lua`
(`:76-101`) and one block in `TabListService.lua` (`:49-57`). See
`Config.lua` in this folder for the annotated list. The ones you will most
likely want to change:

| Constant | Default | When to change it |
|---|---|---|
| `LeaderboardService.MAX_ENTRIES` | `10` | You want more or fewer rows. |
| `LeaderboardService.REFRESH_SECONDS` | `60` | The board feels stale (or is too chatty). |
| `LeaderboardService.FLUSH_SECONDS` | `15` | You want money changes to land faster. |
| `LeaderboardService.SCAN_SECONDS` | `30` | Ordinary money gains reach the board too slowly. |
| `LeaderboardService.MAX_WRITES_PER_FLUSH` | `10` | You are hitting DataStore write limits on a large server. |
| `LeaderboardService.EARLY_REFRESH_COOLDOWN` | `20` | Joins/leaves feel sluggish. |
| `LeaderboardService.RANK_COLORS` | medal colours | Cosmetic. Update `Tests/Leaderboard.spec.lua` if you change the RGB values — it pins them. |
| `TabListService.PUSH_SECONDS` | `15` | The tab list feels stale. |
| `TabListService.EARLY_PUSH_COOLDOWN` | `5` | — |
| `TabListService.REBIRTHS_STAT` | `'Rebirths'` | Your stat is named differently. Update `Tests/TabList.spec.lua` if you rename it. |
| `TabListService.MONEY_STAT` | `'Money'` | Ditto. |

### 3.3 Decide the ranking rule (optional)

The global board is **money-only** by design. If you want a composite score,
change `LeaderboardService.EncodeScore` / `MoneyRank` (`:141`, `:174`) — that
is the single place. Keep the return value an integer below `MONEY_SLOT`
(1e10) so it stays exactly representable and inside the `OrderedDataStore`
limit.

If you change the ranking, also update the header comment, which explicitly
documents the money-only decision.

## 4. Author the Studio assets

The global board renders on a real `Part` in the world. The service creates
**none** of this; if the hierarchy is wrong, the board silently does not
render (it logs a warning at most once per 300 s).

In Studio, under `Workspace`:

```text
Map
└── LeaderBoard
    └── Display            (Part)
        └── SurfaceGui
            ├── Rank       (TextLabel)
            ├── Name       (TextLabel)
            ├── Money      (TextLabel)
            ├── ResetTime  (TextLabel)
            └── List       (ScrollingFrame)
                ├── Template   (Frame, Visible = false)
                │   ├── Rank   (TextLabel)
                │   ├── Name   (TextLabel)
                │   └── Money  (TextLabel)
                └── UIListLayout
```

Checklist:

- [ ] `Display` is a `BasePart` (a `Part` is fine).
- [ ] The `SurfaceGui` is a child of `Display` (any name; found by class).
- [ ] `List` is a `ScrollingFrame` with a `UIListLayout` inside it, and the
      `UIListLayout.SortOrder` is `LayoutOrder` (the default).
- [ ] `Template` is a `Frame` with `Visible = false`, and its `Rank`/`Name`/
      `Money` children are `TextLabel`s.
- [ ] `List` contains **only** `Template` (plus the `UIListLayout`) before
      the first run. The service's row pool matches children named
      `^Row%d+$`; any other row you author will sit in the list as a
      permanently stale entry.
- [ ] `Rank`, `Name`, `Money`, `ResetTime` at the `SurfaceGui` level are
      `TextLabel`s.

**No other assets.** The tab list needs nothing — the native CoreGui
`PlayerList` renders `player.leaderstats`. Just do not disable the player
list in your client bootstrap.

## 5. Wire the bootstrap

In your server bootstrap:

```lua
-- requires
local LeaderboardService = require(script.Parent.Leaderboard.LeaderboardService)
local TabListService = require(script.Parent.TabList.TabListService)
```

```lua
-- injection (after PlayerService, EconomyService and RebirthService exist)
LeaderboardService.SetPlayerService(PlayerService)
LeaderboardService.SetEconomyService(EconomyService)

TabListService.SetPlayerService(PlayerService)
TabListService.SetEconomyService(EconomyService)
TabListService.SetRebirthService(RebirthService)
```

```lua
-- start (after the economy/income loops, so join-time scans see settled profiles)
LeaderboardService.Start()
TabListService.Start()
```

```lua
-- Players.PlayerAdded
LeaderboardService.RequestRefresh()
TabListService.RequestRefresh()

-- Players.PlayerRemoving — ORDER MATTERS
Players.PlayerRemoving:Connect(function(player)
    -- FIRST: snapshot while the profile is still loaded.
    LeaderboardService.OnPlayerLeaving(player)
    TabListService.RequestRefresh()
    -- ... then your profile cleanup ...
    PlayerService.CleanupPlayer(player.UserId)
    -- ... later, once the player is fully gone:
    LeaderboardService.ForgetPlayer(player.UserId)
end)
```

```lua
-- after a committed rebirth (money resets, so the score moves)
pcall(function()
    require(script.Parent.Leaderboard.LeaderboardService).MarkDirty(userId)
end)
pcall(function()
    require(script.Parent.TabList.TabListService).MarkDirty()
end)
```

`MarkDirty` only **enqueues**; the write lands on the next flush (≤ 15 s).
`OnPlayerLeaving` must be the first thing in the `PlayerRemoving` handler —
if the profile is released first, the final money value is never written.

## 6. Smoke test

### 6.1 In Studio

1. Enable **Game Settings → Security → Enable Studio Access to API Services**.
2. Press **Play** (not Run) so `Players` is populated.
3. **Global board:** after ~5 s the board should show your row. Check the
   Output window for `LB` log lines. If you see
   `'Display path Workspace.Map.LeaderBoard.Display not found; board render skipped'`,
   your Studio hierarchy is wrong — re-check section 4.
4. **Money changes:** give yourself money through your own economy path. Within
   `SCAN_SECONDS` (30 s) the board should update. You can also call
   `LeaderboardService.MarkDirty(userId)` from the command bar to enqueue
   immediately, then wait one flush.
5. **Tab list:** press **TAB** in a second client. You should see two stats:
   `Rebirths` (a number) and `Money` (e.g. `5000` or `5.0K`). If the entry
   is blank, `RebirthService` is probably not wired — check
   `TabListService.SetRebirthService(RebirthService)`.
6. **Rebirth:** perform a rebirth. The tab list's `Rebirths` should increment
   and the global board's money should drop to the new (reset) value.

### 6.2 Command-bar checks

```lua
-- encoded score for a huge fortune
print(require(game:GetService('ServerScriptService').Leaderboard.LeaderboardService).EncodeScore('1' .. string.rep('0', 30)))

-- formatted fortune
print(require(game:GetService('ServerScriptService').Leaderboard.LeaderboardService).FormatMoney('1500000'))

-- refresh the board by hand
require(game:GetService('ServerScriptService').Leaderboard.LeaderboardService).RefreshNow()
```

### 6.3 Specs

Copy `Systems/Leaderboards/Tests/Leaderboard.spec.lua` and
`Systems/Leaderboards/Tests/TabList.spec.lua` into your test tree and run them
in Studio (TestEZ). They touch **no DataStore** and need no published place.
`Leaderboard.spec.lua` pins the exact `RANK_COLORS` RGB values and the
`MAX_ENTRIES` / `REFRESH_SECONDS` / `ORDERED_STORE_NAME` constants — if you
changed those, update the spec.

## 7. Production checklist

- [ ] Both DataStore names changed and unique to your game + environment.
- [ ] `Enable Studio Access to API Services` **off** in the published place.
- [ ] The `Workspace.Map.LeaderBoard.Display` hierarchy verified in a live
      server (not just Studio — the part must be replicated).
- [ ] `OnPlayerLeaving` ordered before profile cleanup.
- [ ] `MarkDirty` called after anything that changes money.
- [ ] No remote added for submitting leaderboard values.
