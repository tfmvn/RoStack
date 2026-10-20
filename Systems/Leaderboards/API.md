# Leaderboards — API

Every public function of every module in the system.

Two modules:

- `ServerScriptService.Leaderboard.LeaderboardService` — the global money-only
  physical board.
- `ServerScriptService.TabList.TabListService` — the native Roblox player
  list (`player.leaderstats`).

**General failure policy.** Every public function in this system is
**non-throwing**. DataStore calls are `pcall`-guarded with retry; instance
lookups are `pcall`-guarded. Functions that can fail return a falsy value or
`nil` rather than raising. There is no `pcall` needed at the call site.

---

## `LeaderboardService`

`require(ServerScriptService.Leaderboard.LeaderboardService)`

### Constants

Public and mutable at runtime. See `Config.lua` for the full annotated list.

| Name | Type | Default |
|---|---|---|
| `ORDERED_STORE_NAME` | `string` | `'p7_GlobalLeaderboardMoney_v1'` |
| `META_STORE_NAME` | `string` | `'p7_GlobalLeaderboardMeta_v1'` |
| `MAX_ENTRIES` | `number` | `10` |
| `REFRESH_SECONDS` | `number` | `60` |
| `FLUSH_SECONDS` | `number` | `15` |
| `SCAN_SECONDS` | `number` | `30` |
| `MAX_WRITES_PER_FLUSH` | `number` | `10` |
| `EARLY_REFRESH_COOLDOWN` | `number` | `20` |
| `RANK_COLORS` | `{Gold: Color3, Silver: Color3, Bronze: Color3, Rest: Color3}` | Gold `255,215,80` / Silver `210,215,220` / Bronze `205,135,75` / Rest `225,225,225` |

---

### `LeaderboardService.RankColor(rank: number): Color3`

The tint for a board rank.

- **Parameters:** `rank` — 1-based rank number.
- **Returns:** `RANK_COLORS.Gold` for 1, `.Silver` for 2, `.Bronze` for 3,
  `.Rest` for anything else (including `0` and negative ranks).
- **Failure modes:** none. Never throws.

---

### `LeaderboardService.MoneyRank(money: any): number`

Encodes a BigNumber money string into a compact, sortable integer. **Pure.**

- **Parameters:** `money` — a decimal string (the canonical BigNumber
  format). Non-strings are accepted and treated as invalid.
- **Returns:** an integer in `[0, 10_000_000_000)`:
  `orderOfMagnitude * 1_000_000 + first6SignificantDigits`.
  - non-string → `0`
  - string with no leading digits → `0`
  - `'000'` (all zeros) → `1_000_000` (a valid, non-zero rank)
  - more than 9000 integer digits → `order` is clamped to 9000
  - a computed rank `>= 10_000_000_000` → clamped to `9_999_999_999`
- **Failure modes:** none. Never throws. Invalid input degrades to `0`
  (ranks last) rather than erroring.
- **Notes:** fractions are ignored (floor semantics). Money that differs only
  past the 6th significant digit **ties for rank** — the display still shows
  the exact value.

---

### `LeaderboardService.EncodeScore(money: any): number`

Alias of `MoneyRank`. The single sortable integer the global board stores.

- **Parameters:** `money` — a BigNumber money string.
- **Returns:** the same integer as `MoneyRank`.
- **Failure modes:** none.
- **Notes:** rebirths are deliberately **not** an input. The global board is
  money-only; the tab list ranks rebirths-first and is a separate system.

---

### `LeaderboardService.FormatMoney(money: any): string`

Formats a money string for display, with extension tiers past `Dc` so huge
fortunes never render in scientific notation.

- **Parameters:** `money` — a BigNumber money string.
- **Returns:** a display string.
  - non-string → `'0'`
  - unparseable string → `'0'`
  - otherwise the game's suffix format: `'5000'` → `'5.0K'`,
    `'1500000'` → `'1.5M'`, `'1'` + 36 zeros → `'1.0UDc'`,
    `'1'` + 39 zeros → `'1.0DDc'`.
  - The output **never contains `'e'`** (no scientific notation). Past the
    extension table it uses an `x10^` engineering form with the overflow
    group carried in the suffix.
- **Failure modes:** none. Never throws. `BigNumber.Format` is `pcall`-wrapped;
  if it fails the service falls back to its own tier calculation.

---

### `LeaderboardService.SetPlayerService(svc: any): ()`

Injects the profile service.

- **Parameters:** `svc` — an object with `GetPlayerData(userId): table?`.
  Pass `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. A missing or misbehaving service
  makes every snapshot return `nil` (nothing is ever written) — it never
  causes a crash or a bogus write.

---

### `LeaderboardService.SetEconomyService(svc: any): ()`

Injects the economy service — the only source of money.

- **Parameters:** `svc` — an object with `GetMoney(userId): string`.
  Pass `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. If unset, `readMoney` returns `nil`
  and no snapshot is ever taken.

---

### `LeaderboardService.Start(): ()`

Starts the maintenance loop, the 1 Hz countdown, and the `BindToClose` final
flush.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. Idempotent — a second call is a
  no-op. On the client it sets `started = true` and returns immediately
  without spawning any loop.
- **Side effects:** spawns a maintenance loop (first tick after 5 s, then
  every `FLUSH_SECONDS`), spawns a 1 Hz countdown loop, registers a
  `game:BindToClose` handler.

---

### `LeaderboardService.MarkDirty(userId: number): ()`

High-priority enqueue of a player's current score. Call this after anything
that changes money — a rebirth is the case in the source game, because it
resets the wallet and therefore moves the money-only score.

- **Parameters:** `userId` — the player's UserId.
- **Returns:** nothing.
- **Failure modes:** none. **Never yields and never throws** — safe to call
  inside a transaction or a release path. It is a no-op when:
  - `Start()` has not been called,
  - the userId is not a positive integer,
  - the userId is a Studio test id (`StudioTestMode.IsTestUserId`),
  - the profile is not loaded,
  - `EconomyService` is unwired or returned a non-string,
  - the encoded score is identical to the last successfully written score.
- **Notes:** this **enqueues only**. The DataStore write happens on the next
  flush (≤ `FLUSH_SECONDS` = 15 s). It does not refresh the board display
  either.

---

### `LeaderboardService.OnPlayerLeaving(player: Player): ()`

Takes a final snapshot of a leaving player's money and writes it.

- **Parameters:** `player` — the leaving `Player`.
- **Returns:** nothing.
- **Failure modes:** none. Never throws, and never yields on the read path.
  - No-op if `Start()` has not been called.
  - No-op if the userId is ineligible (invalid or a Studio test id).
  - No-op if the snapshot is `nil` (profile already released, or services
    unwired) **or** the score is unchanged since the last write.
- **Notes:** the snapshot is taken **synchronously** and the write is
  `task.spawn`ed, so this never blocks player cleanup. On write failure the
  snapshot goes back into the dirty queue for the next flush. This **must be
  called before the profile is released** or the final money value is lost.
  On success it also calls `RequestRefresh()`.

---

### `LeaderboardService.RequestRefresh(): ()`

Join/leave-triggered early board refresh.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. No-op if `Start()` has not been
  called, or if less than `EARLY_REFRESH_COOLDOWN` (20 s) has passed since
  the last successful refresh — the throttle is measured against
  `lastRefreshAt`, which is set by `RefreshNow`.
- **Side effects:** on a non-throttled call, spawns a thread that runs
  `RefreshNow()` → `scanServer()` → `flushDirty()` and reschedules
  `nextRefreshAt` to `now + REFRESH_SECONDS`.

---

### `LeaderboardService.RefreshNow(): ()`

One full board read and render.

- **Parameters:** none.
- **Returns:** nothing (it renders into the Studio hierarchy; there is no
  return value and no callback).
- **Failure modes:** none. Never throws.
  - Returns immediately if a DataStore cooldown is active.
  - Returns immediately if the store handles are unavailable.
  - If `GetSortedAsync` or `GetCurrentPage` fails: logs a warning, records a
    DataStore failure, **re-renders the last good entries** (so the board
    fills in if the `Display` part streamed in late) and returns. The
    previous board stays up.
  - If a per-key `meta:GetAsync` fails, only that row shows money `'0'`; the
    rest of the board is unaffected.
- **Notes:** **not** throttled by `EARLY_REFRESH_COOLDOWN` — only
  `RequestRefresh` is. Calling it repeatedly burns the `GetSortedAsync`
  budget.

---

### `LeaderboardService.ForgetPlayer(userId: number): ()`

Drops the session write/diff state for a user.

- **Parameters:** `userId` — the player's UserId.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.
- **Side effects:** clears `dirty[userId]` and `lastWritten[userId]`. The
  global `OrderedDataStore` entry **persists by design** — forgetting a
  player does not remove them from the board.

---

### `LeaderboardService._TestReset(): ()`

Clears all module state for a spec.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.
- **Side effects:** nulls the store handles, clears `storesReady`, and empties
  `lastWritten`, `dirty`, `nameCache`, `lastMeta`, `lastEntries`; resets
  `lastRefreshAt`, `nextRefreshAt`, `consecutiveFailures`, `cooldownUntil`.
  It does **not** reset `started`.

---

## `TabListService`

`require(ServerScriptService.TabList.TabListService)`

### Constants

| Name | Type | Default |
|---|---|---|
| `PUSH_SECONDS` | `number` | `15` |
| `EARLY_PUSH_COOLDOWN` | `number` | `5` |
| `FOLDER_NAME` | `string` | `'leaderstats'` |
| `REBIRTHS_STAT` | `string` | `'Rebirths'` |
| `MONEY_STAT` | `string` | `'Money'` |

---

### `TabListService.SetPlayerService(svc: any): ()`

Injects the profile service.

- **Parameters:** `svc` — an object with `GetPlayerData(userId): table?`.
  Pass `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.

---

### `TabListService.SetEconomyService(svc: any): ()`

Injects the economy service.

- **Parameters:** `svc` — an object with `GetMoney(userId): string`.
  Pass `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.

---

### `TabListService.SetRebirthService(svc: any): ()`

Injects the rebirth service.

- **Parameters:** `svc` — an object with `GetRebirth(userId): number`.
  Pass `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.
- **Notes:** **all three** services are required. There is no partial mode —
  if `RebirthService` is unset, `RefreshValues` returns `false` and the tab
  list stays empty. It does not fall back to money-only.

---

### `TabListService.EnsureLeaderstats(host: Instance): Folder?`

Creates (or repairs) the native `leaderstats` folder on `host`.

- **Parameters:** `host` — usually a `Player`, but any `Instance` works.
- **Returns:** the `Folder`, or `nil` if `host` is not an `Instance`.
- **Failure modes:** never throws — the whole body is `pcall`-wrapped.
  Returns `nil` when `typeof(host) ~= 'Instance'`.
- **Side effects / behaviour:**
  - If a child named `leaderstats` exists but is **not** a `Folder`, it is
    destroyed and replaced with a new `Folder`.
  - `Rebirths` (an `IntValue`, initial value `0`) is created **first** — it
    is the native primary sort key. If it exists with the wrong class it is
    destroyed and recreated.
  - `Money` (a `StringValue`, initial value `'0'`) is created second. Same
    wrong-class repair.
  - **Idempotent** — calling it twice does not recreate anything.
  - The `Template`/`List` hierarchy of the global board is unrelated.

---

### `TabListService.RefreshValues(host: Instance, userId: number): boolean`

Writes the two visible stats from authoritative server-side profile data.

- **Parameters:** `host` — the `Player` (or any `Instance`) to write to.
  `userId` — the player's UserId.
- **Returns:** `true` if values were written; `false` otherwise.
- **Failure modes:** never throws — the whole body is `pcall`-wrapped.
  Returns `false` (and writes **nothing**) when:
  - `host` is not an `Instance`;
  - any of `playerServiceRef` / `economyServiceRef` / `rebirthServiceRef` is
    `nil`;
  - `GetPlayerData(userId)` returns `nil` (profile unloaded) or throws;
  - `GetMoney(userId)` does not return a string;
  - `GetRebirth(userId)` does not return a number;
  - `EnsureLeaderstats` returned `nil`.
- **Notes:** the service **skips, never zeroes**. A player whose profile is
  not loaded keeps whatever value they had; it is never reset to `0`.
  `Rebirths` is written as `math.floor(rebirths)`. `Money` is written as
  `LeaderboardService.FormatMoney(money)`.

---

### `TabListService.MarkDirty(): ()`

Requests a refresh on the next tick.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws.
- **Notes:** sets a single `dirty` boolean. It does **not** check `started`
  and does **not** refresh immediately. The loop picks it up within
  `EARLY_PUSH_COOLDOWN` (5 s).

---

### `TabListService.RequestRefresh(): ()`

Expedites a refresh after a join, a leave, or a rebirth.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. No-op if `Start()` has not been
  called.
- **Behaviour:** if less than `EARLY_PUSH_COOLDOWN` (5 s) has passed since
  the last push, it only sets `dirty = true`. Otherwise it spawns a thread
  that runs `refreshAll()` immediately.

---

### `TabListService.Start(): ()`

Starts the refresh loop.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. Never throws. Idempotent — a second call is a
  no-op. On the client it sets `started = true` and returns immediately.
- **Side effects:** spawns a loop that waits 3 s, then wakes every
  `EARLY_PUSH_COOLDOWN` (5 s) and refreshes when `dirty` is set or
  `PUSH_SECONDS` (15 s) have elapsed.

---

## There is no `_TestReset` on `TabListService`

`TabListService` has **no test seam**. Its only state is the three injected
refs and the three locals (`started`, `lastPushAt`, `dirty`). A spec that
injects fakes must restore the refs itself. The source game's
`Tests/TabList.spec.lua` does exactly that.

---

## Module-locals (not public)

Do not call these from outside. Listed so you know what exists and why.

### `LeaderboardService`

| Local | Purpose |
|---|---|
| `withRetry(label, fn, attempts)` | `pcall` + exponential backoff + jitter. Returns `boolean`. |
| `getStores()` | Lazily creates and caches the two store handles. |
| `isBoardEligible(userId)` | Rejects invalid ids and Studio test ids. |
| `readMoney(userId)` | `EconomyService.GetMoney` + `BigNumber.sanitize`. |
| `profileLoaded(userId)` | `PlayerService.GetPlayerData(userId) ~= nil`. |
| `displayNameOf(player)` | Safe `player.Name` read. |
| `snapshotPlayer(userId)` | The whole read path. Returns `nil` when anything is unsafe. |
| `writeSnapshot(userId, snap)` | Ordered + meta write with retry. |
| `scanServer()` | Enqueue changed snapshots for all in-server players. |
| `flushDirty()` | Capped batch write. |
| `resolveName(userId, fallback)` | `nameCache` → `GetNameFromUserIdAsync` → fallback → `'Unknown Player'`. |
| `findBoard()` | Resolves the `Workspace.Map.LeaderBoard.Display` hierarchy. |
| `paintRow(row, rank, name, moneyText)` | Writes one row's labels. |
| `renderBoard(entries)` | The row pool + the top-player block. |
| `renderResetCountdown()` | Writes `'UPDATE IN %dS'`. |
| `logLb` / `warnLb` | `Debug.Log` / `Debug.Warn` with the `'LB'` tag. |
| `inCooldown` / `noteSuccess` / `noteFailure` | The DataStore failure cooldown state machine. |
| `suffixForTier(tier)` | The extension-tier suffix table. |

### `TabListService`

| Local | Purpose |
|---|---|
| `refreshAll()` | Refreshes every in-server player and updates `lastPushAt`. |
