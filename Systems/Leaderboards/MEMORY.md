# Leaderboards — MEMORY

Engineering notes for a future agent. Read this before touching anything in
`Source/`.

---

## 1. Purpose in one line

Two independent leaderboards — a money-only global physical board
(`LeaderboardService`) and the native Roblox player list (`TabListService`) —
that deliberately share **no** ranking values.

---

## 2. How it actually works

### 2.1 `LeaderboardService`

**State (module-locals, `LeaderboardService.lua:256-282`)**

| Local | Type | Meaning |
|---|---|---|
| `started` | boolean | `Start()` was called. Every public mutator no-ops while false. |
| `orderedStore` / `metaStore` | `OrderedDataStore?` / `GlobalDataStore?` | Lazily created by `getStores()`. |
| `storesReady` | boolean | Handles cached. |
| `lastWritten` | `{[number]: number}` | userId → last **successfully written** score. The diff base. |
| `dirty` | `{[number]: {score, money, name}}` | userId → pending snapshot. |
| `nameCache` | `{[number]: string}` | userId → username. Never cleared mid-session. |
| `lastMeta` | `{[string]: {m, n}}` | orderedKey → last seen meta. |
| `lastEntries` | `{{key, score}}` | Last successful board. Re-rendered on failure. |
| `lastRefreshAt` / `nextRefreshAt` | number | `os.clock()` timestamps. |
| `lastMissingWarnAt` | number | Rate-limits the "Display not found" warning to 1 per 300 s. |
| `consecutiveFailures` / `cooldownUntil` | number / number | DataStore failure cooldown. |

**Boot**

`Start()` (`:837`) sets `started = true`, returns immediately on the client,
then spawns three loops:

1. **Maintenance loop** — waits 5 s, then every `FLUSH_SECONDS` (15 s):
   - if `now - lastScanAt >= SCAN_SECONDS` (30 s) → `scanServer()`
   - always → `flushDirty()`
   - if `now >= nextRefreshAt` → `RefreshNow()`, `nextRefreshAt = now + REFRESH_SECONDS`
   The whole tick body is `pcall`-wrapped; a throw is logged and the loop continues.
2. **Countdown loop** — 1 Hz `renderResetCountdown()`. Label only, no DataStore.
3. **`game:BindToClose`** — best-effort final write of every in-server player's
   snapshot. **No retries** (the close window is short); the next session's
   scan heals any gap.

`nextRefreshAt` is initialised to `os.clock() + 5` so the first board read
happens ~5 s after start, not 60 s.

**Snapshotting** — `snapshotPlayer(userId)` (`:402`)

Returns `nil` (meaning "do not write anything") when any of these hold:

- `isBoardEligible(userId)` is false — userId is not a positive integer, **or**
  `StudioTestMode.IsTestUserId(userId)` is true (Studio test ids `0, -1, -2…`).
- `profileLoaded(userId)` is false — `PlayerService.GetPlayerData(userId)`
  returned `nil` (or threw).
- `readMoney(userId)` is nil — `EconomyService` unwired, threw, or returned a
  non-string.

**This is the key invariant: a failed read must never write a zero score over
a real one.** A zero write would permanently drop a rich player off the board.

**Writes** — `writeSnapshot(userId, snap)` (`:446`)

1. `getStores()`; bail if either handle is nil or `inCooldown()`.
2. `ordered:SetAsync(tostring(userId), snap.score)` with `withRetry(..., 3)`.
3. `meta:SetAsync(tostring(userId), { m = snap.money, n = snap.name })` with
   `withRetry(..., 2)`.
4. On success: update `lastWritten[userId]`, `nameCache`, `lastMeta`.

`withRetry(label, fn, attempts)` (`:314`) is `pcall`-based with exponential
backoff (`delay` 1, 2, 4 …) **plus random jitter** (`delay + math.random()`),
and calls `noteSuccess()` on the first success. After all attempts fail it
calls `noteFailure(label)`.

`noteFailure` (`:301`) increments `consecutiveFailures`; at
`FAILURE_COOLDOWN_AFTER = 5` it sets `cooldownUntil = os.clock() + 300`
(`FAILURE_COOLDOWN_SECONDS`). While in cooldown, `RefreshNow` returns
immediately and `writeSnapshot` refuses to write. `noteSuccess` (`:296`) resets
the counter and clears the cooldown.

**Flush** — `flushDirty()` (`:486`)

Iterates `dirty`, stopping at `MAX_WRITES_PER_FLUSH` (10). Note the counter
increments **on failure too** — a dead store must not spin the budget dry
mid-cycle. Failed entries stay queued for the next flush.

**Scan** — `scanServer()` (`:474`)

Iterates `Players:GetPlayers()`, snapshots each eligible player, and enqueues
only those whose `lastWritten[userId] ~= snap.score`. So the scan is cheap
and idempotent.

**Refresh** — `RefreshNow()` (`:762`)

1. If in cooldown → return.
2. `getStores()`; bail if nil.
3. `ordered:GetSortedAsync(false, MAX_ENTRIES)` — `false` = descending.
   `pcall`-wrapped. On failure: log, `noteFailure`, **re-render `lastEntries`**
   (so the board fills in if the `Display` part streamed in late) and return.
4. `pages:GetCurrentPage()` → `entries` list of `{key, score}`. Only
   `key: string` + `value: number` pairs are kept; anything else is dropped.
5. For each entry, if `lastMeta[key]` is nil, `meta:GetAsync(key)` — at most
   `MAX_ENTRIES` (10) reads per refresh. Missing/failed meta → the row shows
   `'0'` money.
6. Also refreshes `nameCache` for in-server players on this page.
7. `lastEntries = entries`, `lastRefreshAt = os.clock()`, `noteSuccess()`,
   `renderBoard(entries)`, `renderResetCountdown()`.

**Render** — `renderBoard(entries)` (`:657`)

- `findBoard()` (`:568`) resolves the Studio hierarchy. Returns `nil` if any
  piece is missing or of the wrong class → the render is skipped and a
  warning is emitted at most once per 300 s.
- `board.template.Visible = false` — the Template is a **clone source only**,
  never a row.
- Row pool = children of `list` that are `Frame`, not the template, and whose
  name matches `^Row%d+$`. Rows are sorted by `LayoutOrder` and **reused**;
  new ones are created by cloning the template and renaming to `'Row' .. i`.
- `paintRow` (`:636`) sets `row.LayoutOrder = rank` (this is what the
  `UIListLayout` sorts by), writes `'#'..rank` / name / money into the
  `Rank` / `Name` / `Money` `TextLabel`s, tints all three with
  `RankColor(rank)`, and sets `row.Visible = true`.
- Rows beyond `shown = min(#entries, MAX_ENTRIES)` are hidden, not destroyed.
  (Also hides pool rows grown past `MAX_ENTRIES` by an older config.)
- The **top-player** block (`Rank`/`Name`/`Money` at the `SurfaceGui` level)
  mirrors entry #1 and is always Gold. With no entries it shows `—`.

**Countdown** — `renderResetCountdown()` (`:749`)

Writes `'UPDATE IN %dS'` to the `ResetTime` label. **There is no destructive
leaderboard reset in the game.** The label name is legacy; it is a refresh
countdown, a status value.

**Leave** — `OnPlayerLeaving(player)` (`:508`)

Must be called **before** the profile is released. It takes a synchronous
snapshot (no yield) and then `task.spawn`s the actual write, so it never
blocks cleanup. On write failure the snapshot goes back into `dirty`.

**`RequestRefresh()`** (`:533`) — throttled by `EARLY_REFRESH_COOLDOWN` (20 s)
against `lastRefreshAt`. On a hit it spawns `RefreshNow()` → `scanServer()` →
`flushDirty()` and reschedules `nextRefreshAt`.

**`MarkDirty(userId)`** (`:429`) — the high-priority path. Snapshots
synchronously, compares against `lastWritten`, and enqueues. **Never yields,
never throws** — it is safe inside a transaction. It is a no-op if
`started` is false or the player is ineligible. Because it does not write,
the actual DataStore write still waits for the next flush (≤15 s).

### 2.2 `TabListService`

**State:** `started`, `lastPushAt`, `dirty` (a single boolean — not a map).

**`EnsureLeaderstats(host)`** (`:84`)

Entirely `pcall`-wrapped, so it never throws. Returns the `Folder`, or `nil`
if `host` is not an `Instance`.

- If `leaderstats` exists but is **not** a `Folder` → destroy it and make a
  new `Folder`. (A `Folder` named something else is a different child, so
  `FindFirstChild` by name is safe.)
- `Rebirths`: if missing or not an `IntValue` → destroy and recreate with
  `Value = 0`. **Parented first** — Roblox's native player list uses child
  creation order as the column order and the **first** child as the primary
  sort key.
- `Money`: if missing or not a `StringValue` → destroy and recreate with
  `Value = '0'`.
- Idempotent: calling it twice does not recreate anything.

**`RefreshValues(host, userId)`** (`:139`)

Returns `true` iff values were written. It **skips, never zeroes**:

- `host` is not an `Instance` → skip.
- Any of `playerServiceRef` / `economyServiceRef` / `rebirthServiceRef` is
  nil → skip. **All three are required**; there is no partial mode. If
  `RebirthService` is not wired, the tab list stays empty — it does not fall
  back to showing money alone.
- `PlayerService.GetPlayerData(userId)` is nil → skip.
- `EconomyService.GetMoney(userId)` is not a string → skip.
- `RebirthService.GetRebirth(userId)` is not a number → skip.

Then it ensures the folder, and writes `math.floor(rebirths)` into the
`IntValue` and `LeaderboardService.FormatMoney(money)` into the `StringValue`.

**`Start()`** (`:223`) — waits 3 s, then every `EARLY_PUSH_COOLDOWN` (5 s)
refreshes if `dirty` is set or `PUSH_SECONDS` (15 s) have elapsed.

**`RequestRefresh()`** (`:210`) — if less than 5 s since the last push, it
only sets `dirty = true` (the next tick picks it up). Otherwise it spawns
`refreshAll()` immediately.

**`MarkDirty()`** (`:206`) — sets `dirty = true`. Does nothing else, and does
**not** check `started`.

**There is no `_TestReset`** on `TabListService`. The only state is the three
injected refs and the three locals; the specs restore the refs by hand.

---

## 3. Public API surface

### `ServerScriptService.Leaderboard.LeaderboardService`

```lua
-- Pure
LeaderboardService.RankColor(rank: number): Color3
LeaderboardService.MoneyRank(money: any): number
LeaderboardService.EncodeScore(money: any): number     -- alias of MoneyRank
LeaderboardService.FormatMoney(money: any): string

-- Wiring
LeaderboardService.SetPlayerService(svc: any): ()
LeaderboardService.SetEconomyService(svc: any): ()

-- Lifecycle / mutation
LeaderboardService.Start(): ()
LeaderboardService.MarkDirty(userId: number): ()
LeaderboardService.OnPlayerLeaving(player: Player): ()
LeaderboardService.RequestRefresh(): ()
LeaderboardService.RefreshNow(): ()
LeaderboardService.ForgetPlayer(userId: number): ()

-- Test
LeaderboardService._TestReset(): ()

-- Constants (public, mutable)
LeaderboardService.ORDERED_STORE_NAME: string
LeaderboardService.META_STORE_NAME: string
LeaderboardService.MAX_ENTRIES: number
LeaderboardService.REFRESH_SECONDS: number
LeaderboardService.FLUSH_SECONDS: number
LeaderboardService.SCAN_SECONDS: number
LeaderboardService.MAX_WRITES_PER_FLUSH: number
LeaderboardService.EARLY_REFRESH_COOLDOWN: number
LeaderboardService.RANK_COLORS: { Gold: Color3, Silver: Color3, Bronze: Color3, Rest: Color3 }
```

### `ServerScriptService.TabList.TabListService`

```lua
TabListService.SetPlayerService(svc: any): ()
TabListService.SetEconomyService(svc: any): ()
TabListService.SetRebirthService(svc: any): ()
TabListService.EnsureLeaderstats(host: Instance): Folder?
TabListService.RefreshValues(host: Instance, userId: number): boolean
TabListService.MarkDirty(): ()
TabListService.RequestRefresh(): ()
TabListService.Start(): ()

TabListService.PUSH_SECONDS: number
TabListService.EARLY_PUSH_COOLDOWN: number
TabListService.FOLDER_NAME: string
TabListService.REBIRTHS_STAT: string
TabListService.MONEY_STAT: string
```

**Not public** (module-locals, do not call from outside):
`withRetry`, `getStores`, `isBoardEligible`, `readMoney`, `profileLoaded`,
`displayNameOf`, `snapshotPlayer`, `writeSnapshot`, `scanServer`,
`flushDirty`, `resolveName`, `findBoard`, `paintRow`, `renderBoard`,
`renderResetCountdown`, `refreshAll`, `logLb`, `warnLb`, `inCooldown`,
`noteSuccess`, `noteFailure`, `suffixForTier`.

---

## 4. Invariants the code enforces

1. **Money-only ranking on the global board.** Rebirths are never read by
   `LeaderboardService`. A player with `1.0Qa` and 0 rebirths outranks a
   player with `400.0M` and 100 rebirths.
2. **A score is never written from a failed read.** `snapshotPlayer` returns
   `nil` for every unsafe case and every caller skips.
3. **A score is only written when it changed.** `lastWritten[userId]` is the
   diff base; identical scores are never re-written.
4. **The ordered score is an integer in `[0, 1e10)`.** `MONEY_SLOT =
   10000000000`. Exactly representable in a Lua double, well inside the
   `OrderedDataStore` integer limit.
5. **Monotonic in magnitude.** A longer integer part always beats a shorter
   one, because the `1e6` step exceeds the maximum `999999` lead spread.
6. **A DataStore failure never breaks the server.** Every DataStore call is
   `pcall`-guarded; the board keeps its last good render.
7. **The tab list never zeroes a value it failed to read.** It skips.
8. **`Rebirths` is the first child of `leaderstats`.** Creation order is the
   native sort key.
9. **The client submits nothing.** No remote exists for either board.
10. **Studio test UserIds never pollute the global board.**
    `isBoardEligible` rejects them.

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `MoneyRank` / `EncodeScore` given a non-string | returns `0` |
| given a string with no leading digits | returns `0` |
| given `'000'` (all zeros) | returns `ORDER_MULT` (1e6) — a valid, non-zero rank |
| given a number of digits > `ORDER_CAP` (9000) | `order` is clamped to 9000 |
| given a value whose rank would reach `MONEY_SLOT` | clamped to `MONEY_SLOT - 1` |
| `FormatMoney` given a non-string | returns `'0'` |
| given an unparseable string | returns `'0'` |
| `FormatMoney` on a huge value | extended-tier suffix, **never** `'e'` notation. `1` + 36 zeros → `'1.0UDc'`; 39 zeros → `'1.0DDc'` |
| `FormatMoney` on a one-digit integer with a fraction | `'7.5'` → `'7.5'` (first fraction digit kept) |
| `getStores()` throws | handles stay nil, a warning is logged, `noteFailure` runs |
| `GetSortedAsync` throws | previous board stays, `lastEntries` re-rendered, `noteFailure` runs |
| `GetCurrentPage` throws | same as above |
| `meta:GetAsync` fails for one key | that row shows money `'0'`; other rows unaffected |
| 5 consecutive DataStore failures | 300 s cooldown: no reads, no writes |
| Any later success | cooldown cleared, counter reset to 0 |
| `Display` part missing | render skipped, warning at most 1 per 300 s, everything else keeps working |
| `Display` part present but a child is missing / wrong class | `findBoard()` returns nil → same as above |
| `leaderstats` exists as a non-Folder | destroyed and rebuilt |
| `Rebirths` exists as a `StringValue` | destroyed and rebuilt as `IntValue` |
| Profile unloaded when `RefreshValues` runs | returns `false`; the folder is not even created |
| `RebirthService` unwired | `RefreshValues` returns `false`; tab list stays empty |
| `OnPlayerLeaving` after the profile was released | snapshot is nil → no write |
| `MarkDirty` before `Start()` | no-op (returns early on `not started`) |
| `MarkDirty` for an ineligible user | no-op |
| `RefreshNow` during cooldown | returns immediately, no read |
| `RequestRefresh` within 20 s of the last refresh | no-op |
| `TabListService.RequestRefresh` within 5 s of the last push | sets `dirty = true` only |

---

## 6. Gotchas that will bite you

1. **`ResetTime` is not a reset.** The game has no destructive leaderboard
   reset. The label shows the time until the next board refresh. Do not
   "fix" it into a reset without also implementing the reset.
2. **The two boards must never be merged.** Different rankings, different
   stores, different value sources. `EncodeScore` is not used by the tab
   list.
3. **The `Money` stat is a `StringValue`.** The native player list will not
   sort by it. That is deliberate — a `NumberValue` cannot hold a BigNumber
   fortune, and a raw integer would display unreadably huge. If you want
   money sorting in the tab list you need a separate numeric stat and
   accept that it is a lossy projection of the wallet.
4. **`Rebirths` must be parented first.** Roblox uses child creation order
   as the native column order and the first child as the primary sort key.
   Creating `Money` first silently changes the tab list's sort.
5. **The ordered store is lossy at 6 significant digits.** `1000000.1` and
   `1000000.2` tie for rank. The *display* still shows the exact fortune
   (from the meta store). Do not treat a rank tie as a data bug.
6. **`ORDERED_STORE_NAME` was deliberately renamed** away from the old
   rebirth-mixed store so stale rebirth-dominated scores could never
   resurface. Do not "merge" the two stores.
7. **The stores are hardcoded literals with no environment suffix.** A new
   game MUST change both, or it will read another game's rows.
8. **The meta store is read once per key per session** (`lastMeta` cache).
   A first refresh after a long downtime issues up to `MAX_ENTRIES` (10)
   `GetAsync` calls. There is no bulk read.
9. **`SetAsync` is last-writer-wins, not `UpdateAsync`.** If a player can be
   ranked from two servers at once, this is wrong. The source game assumes
   one server per player.
10. **`OnPlayerLeaving` must be ordered before profile cleanup.** Otherwise
    the snapshot is nil and the final money value is never written.
11. **`flushDirty` counts failures against the write cap.** This is
    intentional (a dead store must not spin the budget), but it means a
    failing flush advances the counter without writing — do not "fix" it by
    moving `count += 1` into the success branch.
12. **`RenderBoard` reuses row clones by name pattern `^Row%d+$`.** Renaming
    rows in Studio breaks the pool: a new clone is created instead.
13. **`Template` must be a `Frame` child of `List` and is never shown.** The
    `UIListLayout` order is driven by `row.LayoutOrder`, not child order.
14. **`TabListService` requires `LeaderboardService`** for `FormatMoney`.
    That is a leaf-to-leaf dependency, not a cycle — but it means the
    `Leaderboard` folder must be copied even if you only want the tab list.
15. **`TabListService` has no `_TestReset`.** After a spec, the injected
    refs stay set. Restore them by hand.
16. **`Start()` returns early on the client** but still sets `started = true`.
17. **`RefreshNow` is not covered by the `EARLY_REFRESH_COOLDOWN`.** Only
    `RequestRefresh` is. An admin calling `RefreshNow` directly burns the
    `GetSortedAsync` budget.
18. **No remotes exist for either board.** Do not add one. A
    client-submitted score is an exploit.

---

## 7. What to change to reuse it

| Change | Where |
|---|---|
| Store names (must be unique per game + environment) | `LeaderboardService.ORDERED_STORE_NAME`, `.META_STORE_NAME` (`:83`, `:89`) |
| Number of rows | `LeaderboardService.MAX_ENTRIES` (`:91`) — also the `GetSortedAsync` page size |
| Refresh / flush / scan cadences | `.REFRESH_SECONDS`, `.FLUSH_SECONDS`, `.SCAN_SECONDS` (`:93`, `:95`, `:97`) |
| Write cap per flush | `.MAX_WRITES_PER_FLUSH` (`:99`) |
| Early-refresh cooldown | `.EARLY_REFRESH_COOLDOWN` (`:101`) |
| Rank colours | `.RANK_COLORS` (`:115`) |
| The Studio hierarchy | `findBoard()` (`:568`) — change the path lookups |
| **The ranking rule itself** | `LeaderboardService.EncodeScore` / `MoneyRank` (`:141`, `:174`) — the single place. Keep the result an integer below `MONEY_SLOT`. |
| The formatter's suffix table | `GAME_SUFFIXES`, `EXT_ONES`, `EXT_GROUPS` (`:181-183`) |
| Tab list cadence | `TabListService.PUSH_SECONDS`, `.EARLY_PUSH_COOLDOWN` (`:51`, `:53`) |
| Stat names | `TabListService.FOLDER_NAME`, `.REBIRTHS_STAT`, `.MONEY_STAT` (`:55-57`) |
| Which stat is the primary sort key | `EnsureLeaderstats` (`:84`) — the **parenting order** of the two stats |
| DataStore failure cooldown | `FAILURE_COOLDOWN_AFTER` / `FAILURE_COOLDOWN_SECONDS` (`:280-281`) — module-locals, not public |

**Not worth changing:** the retry/backoff helper, the diff-based dirty
queue, the row-clone pool, the "never write a zero from a failed read"
rule, and the whole "no client-submitted values" stance.
