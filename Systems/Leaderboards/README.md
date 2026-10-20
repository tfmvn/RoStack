# Leaderboards

Two **separate** leaderboards, deliberately never mixed:

- **Global board** (`LeaderboardService`) — a server-authoritative, money-only
  board rendered on an authored Studio part in the world.
- **Tab list** (`TabListService`) — the native Roblox player list, driven by
  `player.leaderstats`, ranked **rebirths first**.

They use different rankings, different stores, and different value sources.
`LeaderboardService.EncodeScore` is *never* used for the tab list.

**Portability:** Grade **A — portable core** (score encoding, formatting,
debounced DataStore writes, native leaderstats maintenance) + Grade **B —
game-specific adapter** (the `Workspace.Map.LeaderBoard.Display` Studio
hierarchy, the money-only ranking rule, the `p7_`-prefixed store names, the
`Rebirths`/`Money` stat names). Grade **C** in the sense that it is bound to
Roblox `DataStoreService` and `Workspace`.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

### `LeaderboardService` — the global physical board

- Renders the top **10** players on
  `Workspace.Map.LeaderBoard.Display` (a `Part` with a `SurfaceGui`).
- Ranks by **money only**. Rebirths are deliberately *not* an input: a player
  with `1.0Qa` and 0 rebirths outranks a player with `400.0M` and 100
  rebirths (`Leaderboard.spec.lua:38-47` locks this case).
- Stores scores in a dedicated `OrderedDataStore` and the exact fortune +
  username in a companion `GlobalDataStore`.
- Writes are **debounced**: a scan every `SCAN_SECONDS` enqueues only changed
  snapshots; a flush every `FLUSH_SECONDS` writes a capped batch; a leave
  triggers one final write; `MarkDirty` forces a high-priority flush.
- Every DataStore call is `pcall`-guarded with retry + exponential backoff +
  jitter, and a consecutive-failure cooldown. A dead store **freezes the
  board on the last good render** — it never breaks the server.
- **There is no remote for submitting leaderboard values.** Every read comes
  from `EconomyService.GetMoney` on the server.

### `TabListService` — the native player list

- Maintains `player.leaderstats` with exactly two stats, in this order:
  1. `Rebirths` (`IntValue`) — created **first**, so it is the native primary
     sort key.
  2. `Money` (`StringValue`) — the game-formatted text (`"1.0Qa"`). A numeric
     stat cannot hold a BigNumber fortune, and a raw integer would render
     unreadably huge.
- No custom UI, no scrolling list, no feed remote. The native CoreGui
  `PlayerList` renders and sorts it.
- Values refresh on a 15 s cadence plus a 5 s-throttled dirty path. The
  client submits nothing; replication dedupes unchanged values.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `LeaderboardService.Start()` | Server | Starts the maintenance loop, the 1 Hz countdown, and the `BindToClose` final flush. Idempotent. |
| `LeaderboardService.SetPlayerService(svc)` | Server | Injects `PlayerService`. Used to check that a profile is loaded before snapshotting. |
| `LeaderboardService.SetEconomyService(svc)` | Server | Injects `EconomyService` — the only source of money. |
| `LeaderboardService.MarkDirty(userId)` | Server | High-priority enqueue. Call after a committed rebirth (money resets, so the score moves). Never yields, never throws. |
| `LeaderboardService.RequestRefresh()` | Server | Join/leave-triggered early refresh. Throttled by `EARLY_REFRESH_COOLDOWN` (20 s). |
| `LeaderboardService.RefreshNow()` | Server | One `GetSortedAsync` + render. Returns nothing; on failure the previous board stays up. |
| `LeaderboardService.OnPlayerLeaving(player)` | Server | Snapshots synchronously (before the profile is released), then writes on a spawned thread. |
| `LeaderboardService.ForgetPlayer(userId)` | Server | Drops the dirty-queue and last-written entries for a user. |
| `LeaderboardService.MoneyRank(money): number` | Pure | The encoding. String math on the canonical BigNumber decimal string. |
| `LeaderboardService.EncodeScore(money): number` | Pure | Alias of `MoneyRank`. The **only** sortable integer the global board stores. |
| `LeaderboardService.FormatMoney(money): string` | Pure | Game formatter extended past `Dc` so values above `1e33` never render as scientific notation. |
| `LeaderboardService.RankColor(rank): Color3` | Pure | Gold / Silver / Bronze / Rest. |
| `LeaderboardService._TestReset()` | Test | Clears all module state. |
| `TabListService.Start()` | Server | Starts the refresh loop. Idempotent. |
| `TabListService.SetPlayerService(svc)` | Server | Injects `PlayerService` (profile-loaded check). |
| `TabListService.SetEconomyService(svc)` | Server | Injects `EconomyService`. |
| `TabListService.SetRebirthService(svc)` | Server | Injects `RebirthService` (the `Rebirths` stat). |
| `TabListService.EnsureLeaderstats(host): Folder?` | Server | Creates/repairs the `leaderstats` folder. Never throws. |
| `TabListService.RefreshValues(host, userId): boolean` | Server | Writes both stats from authoritative profile data. `false` when the profile is unloaded — it **skips**, never zeroes. |
| `TabListService.MarkDirty()` | Server | Requests a refresh on the next tick. |
| `TabListService.RequestRefresh()` | Server | Throttled early refresh (5 s). |
| `TabListService._TestReset()` | Test | Does not exist — `TabListService` has no test seam; state is only the injected refs. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Leaderboard/LeaderboardService.lua` | `ServerScriptService.Leaderboard.LeaderboardService` | The global money-only board: encoding, DataStore writes, Studio part rendering. |
| `Source/ServerScriptService/TabList/TabListService.lua` | `ServerScriptService.TabList.TabListService` | Native `player.leaderstats` maintenance (rebirths-first). |

There is **no config file** in this system; see *Configuration*.

---

## Configuration

This system has **no config module of its own**. Every tunable is a public
constant on the service module, in a single "Tunables" block near the top of
the file. `Config.lua` in this folder is a **reference transcription** of
those constants — it is documentation, not a live module, and it is not
required by anything. To change a value, edit the constant in the service.

| Constant | Owner | Default | Meaning |
|---|---|---|---|
| `ORDERED_STORE_NAME` | `LeaderboardService` | `'p7_GlobalLeaderboardMoney_v1'` | Dedicated **money-only** `OrderedDataStore`. Never the profile store. Renamed away from the old rebirth-mixed store so stale rebirth-dominated scores can never resurface. |
| `META_STORE_NAME` | `LeaderboardService` | `'p7_GlobalLeaderboardMeta_v1'` | `GlobalDataStore`: `UserId -> { m = money string, n = username }`. Needed because `OrderedDataStore` values are integers only. |
| `MAX_ENTRIES` | `LeaderboardService` | `10` | Rows rendered. Also the `GetSortedAsync` page size. |
| `REFRESH_SECONDS` | `LeaderboardService` | `60` | Global board re-read cadence. |
| `FLUSH_SECONDS` | `LeaderboardService` | `15` | Dirty-write cadence and the maintenance-loop tick period. |
| `SCAN_SECONDS` | `LeaderboardService` | `30` | Full in-server scan cadence (enqueues changed snapshots only). |
| `MAX_WRITES_PER_FLUSH` | `LeaderboardService` | `10` | Cap per flush. Ordered + meta = 2 DataStore calls each. |
| `EARLY_REFRESH_COOLDOWN` | `LeaderboardService` | `20` | Minimum gap between join/leave-triggered early refreshes. |
| `RANK_COLORS` | `LeaderboardService` | Gold `255,215,80` / Silver `210,215,220` / Bronze `205,135,75` / Rest `225,225,225` | Rank tinting. |
| `PUSH_SECONDS` | `TabListService` | `15` | `leaderstats` refresh cadence. |
| `EARLY_PUSH_COOLDOWN` | `TabListService` | `5` | Minimum gap between join/leave/dirty-triggered refreshes **and** the loop tick period. |
| `FOLDER_NAME` | `TabListService` | `'leaderstats'` | The native folder name. |
| `REBIRTHS_STAT` | `TabListService` | `'Rebirths'` | First child = native primary sort key. |
| `MONEY_STAT` | `TabListService` | `'Money'` | Second child, a `StringValue`. |

The store names are **hardcoded literals** with no environment suffix. A new
game MUST change both strings. There is no destructive leaderboard reset
anywhere in the game, so the `ResetTime` label shows a countdown to the next
**refresh**, not a wipe.

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ReplicatedStorage.Utility.BigNumber` — the canonical decimal-string money
  format, plus `sanitize`.
- `ReplicatedStorage.Utility.StudioTestMode` — Studio multi-instance test
  UserIds (`0, -1, …`) are **excluded** from the global board so a test
  session can never pollute it.
- `ReplicatedStorage.Utility.Debug` — the `LB` / `TAB` log tags.
- `ServerScriptService.PlayerService` — profile-loaded check.
- `ServerScriptService.EconomyService` — `GetMoney(userId): string`.
- `ServerScriptService.RebirthService` — `GetRebirth(userId): number`.

`TabListService` **requires `LeaderboardService`** (for
`LeaderboardService.FormatMoney`) — a leaf-to-leaf dependency, not a cycle.

---

## Initialization Order

```text
1. Remotes folder created (bootstrap)          -- not needed by these two, but
                                                  every other service needs it
2. PlayerService.Init()                        -- before the leaderboards
3. EconomyService.Init() + SetPlayerService(PlayerService)
4. RebirthService.Init()                       -- before TabListService
5. LeaderboardService.SetPlayerService(PlayerService)
   LeaderboardService.SetEconomyService(EconomyService)
6. TabListService.SetPlayerService(PlayerService)
   TabListService.SetEconomyService(EconomyService)
   TabListService.SetRebirthService(RebirthService)
7. LeaderboardService.Start()
   TabListService.Start()
8. On PlayerRemoving:
   LeaderboardService.OnPlayerLeaving(player)  -- snapshot BEFORE the
                                                   profile is released
9. On committed rebirth:
   LeaderboardService.MarkDirty(userId)
   TabListService.MarkDirty()
```

`LeaderboardService.OnPlayerLeaving` must run **before**
`PlayerService.CleanupPlayer` releases the profile, otherwise the snapshot
reads `nil` and the last money value is never written.

---

## Data

### `OrderedDataStore` — `p7_GlobalLeaderboardMoney_v1`

| Key | Value |
|---|---|
| `tostring(userId)` | `score` — a single integer, `orderOfMagnitude * 1e6 + first6SignificantDigits`. |

### `GlobalDataStore` — `p7_GlobalLeaderboardMeta_v1`

| Key | Value |
|---|---|
| `tostring(userId)` | `{ m = money string, n = username }` |

The `m` field is the **exact** BigNumber decimal string, so the board shows
the real fortune even though the ordered value is lossy. The dropped legacy
`r` (rebirth) field is simply ignored where present.

### Encoding budget

`MONEY_SLOT = 10000000000` (1e10), `LEAD_DIGITS = 6`,
`ORDER_MULT = 1000000`, `ORDER_CAP = 9000`.

- A longer integer part **always** beats a shorter one (the `1e6` step
  exceeds the max `999999` lead spread).
- Equal lengths compare by the first 6 significant digits.
- Fractions are ignored (floor semantics). Invalid input ranks as zero.
- The score is always `< 1e10` — exactly representable in a Lua double and
  inside the `OrderedDataStore` integer limit.
- **Documented precision limit:** money that differs only past the 6th
  significant digit **ties for rank**. Display still shows each exact
  fortune.

---

## Known Limitations

- **Six-significant-digit ranking resolution.** `1000000.1` and `1000000.2`
  tie. Inherent to fitting an unbounded fortune into one integer.
- **The `ResetTime` label is a refresh countdown, not a reset.** The name is
  misleading; there is no destructive board reset in the game.
- **`META_STORE_NAME` is a plain `GlobalDataStore` with no scope.** It will
  hit DataStore limits on a large player base; the ordered store is capped at
  `MAX_ENTRIES` reads per refresh, but the meta store is read per *missing*
  key, so a first refresh after a long downtime can issue many `GetAsync`
  calls.
- **No `UpdateAsync` on the ordered store — only `SetAsync`.** A player's
  score is last-writer-wins. Fine for a single-server-per-player game,
  wrong if a player can be ranked from two servers at once.
- **`RefreshNow` is not throttled by `EARLY_REFRESH_COOLDOWN`** — only
  `RequestRefresh` is. An admin calling `RefreshNow` directly can burn the
  `GetSortedAsync` budget.
- **`TabListService` has no `_TestReset`.** The injected service refs stay
  set after a spec; the specs restore them by hand.
- **`TabListService` is entirely dependent on `RebirthService` being
  wired.** If it is not, `RefreshValues` returns `false` and the tab list
  stays empty — it does not fall back to showing money alone.
- **The `Money` column in the tab list is a display string.** It is not
  sorted by the native list (which sorts on `Rebirths`); sorting by money
  would need a numeric stat, which cannot hold a BigNumber.
- **`Display` may not have streamed in yet.** `renderBoard` warns at most
  once every 300 s and re-asserts the last good render on every refresh
  failure, so the board fills in when the part arrives.

---

## Testing

- `Tests/Leaderboard.spec.lua` — pure-function coverage: config constants,
  `EncodeScore` monotonicity (including the locked 1Qa-vs-400M case and the
  full magnitude ladder K→past-Dc), the `2^53`/1e10 integer bound, garbage
  input degradation, `FormatMoney` (never scientific, deterministic
  past-`Dc` extension tiers), and `RankColor`.
- `Tests/TabList.spec.lua` — structure coverage: `leaderstats` creation
  order, wrong-typed repair, idempotence, value writing from faked services,
  and the "unloaded profile is skipped, not zeroed" rule.

Both require Roblox Studio (TestEZ). No DataStore is touched — the specs only
exercise the pure and structural paths. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Copy the two files** to `ServerScriptService/Leaderboard/` and
   `ServerScriptService/TabList/`.
2. **Change both store names.** Add a prefix and an environment suffix:
   ```lua
   LeaderboardService.ORDERED_STORE_NAME = ('%s_GlobalLeaderboardMoney_v1_%s'):format(GAME_PREFIX, ENV)
   LeaderboardService.META_STORE_NAME    = ('%s_GlobalLeaderboardMeta_v1_%s'):format(GAME_PREFIX, ENV)
   ```
   The old `p7_` rows are abandoned, not migrated.
3. **Decide the ranking rule.** Money-only is a deliberate design choice
   (`LeaderboardService.EncodeScore` is the single place to change it). If you
   want a composite score, change `EncodeScore` — but keep the result an
   integer below `MONEY_SLOT`.
4. **Author the Studio part** `Workspace.Map.LeaderBoard.Display` with the
   exact hierarchy in `Dependencies.md` → *Studio Assets*. Without it the
   board silently does not render (it warns once).
5. **Author the tab list** — nothing to author. Keep the native CoreGui
   `PlayerList` enabled; the service maintains `leaderstats` for you.
6. **Wire the services** in the order in *Initialization Order*, and make
   sure `LeaderboardService.OnPlayerLeaving` runs before the profile is
   released.
7. **Call `MarkDirty` after anything that changes money** (rebirth is the
   one in the source game). Otherwise the board waits up to `SCAN_SECONDS`.
8. **Do not add a leaderboard submission remote.** The whole design is
   server-authoritative; a client-submitted score is an exploit.
