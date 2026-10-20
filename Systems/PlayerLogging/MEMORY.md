# PlayerLogging — MEMORY

Engineering notes for a future agent. Dense, factual, about the code as
it actually is.

---

## Purpose

Operator-side monitoring: player join/leave and milestone events as
Discord webhook embeds, plus a persistent all-time registry of every
player who has ever joined. Never gameplay-critical.

---

## How it actually works, step by step

### Module layout

`PlayerLogger.lua` (delivery + embeds) and `PlayerRegistry.lua`
(persistence) both require `PlayerLoggerConfig.lua` and
`ReplicatedStorage.Utility.Debug`. Nothing else at load time.

**`PlayerService` is reached lazily**, inside `_progressSnapshot`:

```lua
local sss = game:GetService('ServerScriptService')
local okPs, playerService = pcall(require, sss:WaitForChild('PlayerService', 2))
```

This is what keeps the module cycle-free — `PlayerService` never
requires `PlayerLogger`.

### `PlayerLogger.Init()`

1. If `_workerStarted` → return (idempotent).
2. `_webhookUrl = _readWebhookUrl()` — **read exactly once**, here.
   `_readWebhookUrl` does
   `ServerScriptService:GetAttribute(Config.WebhookAttribute)` and
   accepts the value only if it is a string matching
   `^https://discord%.com/api/webhooks/`. Anything else → `nil`.
3. Probes `HttpService.HttpEnabled == true` inside a `pcall`.
4. If **both** the URL and HTTP are available → `_enabled = true` and
   `Debug.Log('PLOG', 'player logger ready (webhook configured)', {})`.
   Otherwise `_enabled` stays `false` and **one** `Debug.Warn('PLOG',
   'webhook disabled (missing URL attribute or HTTP off);
   registry-only mode', {})` is logged (`_configWarned` guard — once
   per server lifetime).
5. `task.spawn(_worker)` — the delivery worker.
6. `game:BindToClose(...)` — sets `_closing = true` and drains up to
   `Config.ShutdownFlushMax` (5) queued embeds with a best-effort
   `pcall(_postEmbed, item)`.

**Critical:** the URL is captured at `Init()`. Setting the attribute
after `Init()` has **no effect** until the next server start.

### The worker (`_worker`)

```lua
while not _closing do
    if #_queue == 0 then task.wait(0.5) continue end
    local gap = Config.SendIntervalSeconds - (os.clock() - _lastSendTick)
    if gap > 0 then task.wait(gap) continue end
    local item = table.remove(_queue, 1)
    _lastSendTick = os.clock()
    local sent, reason = _postEmbed(item)
    ...
end
```

- The loop is **busy-ish**: it polls every 0.5 s when idle, and
  otherwise sleeps until the next send slot.
- `_lastSendTick` is set **before** the send, so a slow request does
  not cause a burst afterwards.
- On failure: `item.attempts += 1`. If `attempts >= Config.MaxAttempts`
  (3) → `Debug.Warn('PLOG', 'webhook delivery failed; event dropped',
  {reason, attempts})` and the item is discarded.
- Otherwise the backoff is `Config.RetryBackoffSeconds[min(attempts,
  #backoff)]` — so attempt 1 waits 2 s, attempt 2 waits 8 s, and any
  attempt beyond the list reuses the last entry (8).
- **A 429 overrides the backoff**: if the reason starts with
  `'rate-limited:'` the wait becomes `max(backoff, retryAfter)`.
- The failed item is **re-inserted at the head** of the queue
  (`table.insert(_queue, 1, item)`), so it blocks everything behind
  it until it succeeds or is dropped.
- The item is **removed from the queue before** the POST, so the
  queue length drops during the request.

### `_postEmbed(item)` — the HTTP call

1. `HttpService:JSONEncode({ username = 'Brainrot Arena', embeds = {
   item.embed } })` inside a `pcall`. Failure → `false, 'encode'`.
2. `HttpService:RequestAsync({ Method = 'POST', Url = _webhookUrl,
   Headers = {['Content-Type'] = 'application/json'}, Body = body })`
   inside a `pcall`. Failure or a non-table response → `false,
   'request'`.
3. `status = tonumber(response.StatusCode) or 0`.
   - `200 <= status < 300` → `true, nil`.
   - `status == 429` → reads `response.Headers['retry-after']` (also
     tries `'Retry-After'` and `'Retry-after'`), `tonumber`s it, and
     accepts it only if `0 < n <= 60`; otherwise the wait is 5 s.
     Returns `false, 'rate-limited:<n>'`.
   - anything else → `false, 'status:<code>'`.

**The response body is never read or logged** — it can echo the
webhook URL back.

### `_enqueue(embed)`

- If `_enabled` is false → **the embed is dropped immediately**. The
  registry write still happens (it is a separate `task.spawn`).
- If `#_queue >= Config.QueueCap` (200) → `table.remove(_queue, 1)`
  (**drop-oldest**), `_droppedCount += 1`, and a `Debug.Warn('PLOG',
  'queue full; oldest event dropped', {dropped})` is logged on the
  1st drop and every 50th.

### `NotifyJoin(player)`

1. Read `player.UserId` in a `pcall`; not a number → return.
2. **Session guard**: if `_sessions[userId] ~= nil` → return
   immediately. This dedupes a duplicate join for a live session.
3. `_sessions[userId] = { joinTick = os.clock(), joinTime = os.time() }`.
   This happens **before** the `Config.Events.Join` check — so the
   session is recorded even when the join event is disabled.
4. If `Config.Events.Join ~= true` → return (no embed, no registry
   write).
5. `task.spawn(...)`:
   - Re-checks `player.Parent ~= nil`; if the player already left,
     the session entry is cleared and the thread returns.
   - `_progressSnapshot(userId)`.
   - `PlayerRegistry.UpsertOnJoin(userId, {...})` — **this is the
     first/returning decision**: `upsert.isFirst == true` → `'First-Time
     Player'`, `false` → `'Returning Player'`, `ok == false` →
     `'Unknown'`.
   - `player.AccountAge` (in a `pcall`, default 0).
   - `_enqueue(BuildJoinEmbed({...}))`.

### `NotifyLeave(player)`

1. Read `userId`; not a number → return.
2. `session = _sessions[userId]`; then `_sessions[userId] = nil`.
3. If `Config.Events.Leave ~= true` → return.
4. `joinTick = session.joinTick or os.clock()`,
   `joinTime = session.joinTime or os.time()`.
   `durationSecs = math.max(0, math.floor(os.clock() - joinTick))` —
   **server-local monotonic**, so it is immune to clock changes and
   does not include time spent in a previous session.
5. `leaveTime = os.time()`.
6. `_progressSnapshot(userId)` — computed **synchronously**, before
   the spawn.
7. `task.spawn(...)` → `PlayerRegistry.UpdateOnLeave(userId,
   durationSecs, {...})`.
8. `_enqueue(BuildLeaveEmbed({...}))` — **synchronous**, so the leave
   embed is queued immediately.

### `LogMilestone(player, kind, details)`

1. `if Config.Events[kind] ~= true then return end` — **an unknown
   kind is silently ignored** (the `Events` table has no `__index`).
2. Everything else is inside a `pcall`.
3. `_progressSnapshot(userId)`.
4. `task.spawn` → `PlayerRegistry.UpdateProgress(userId, {...})` —
   snapshot fields only, no counters.
5. `_enqueue(BuildMilestoneEmbed(kind, {...}, details))`.

### `_progressSnapshot(userId)`

Defaults: `{ rebirths = 0, arenaLevel = 1, arenaWins = 0,
tutorialCompleted = false }`.

Reads `PlayerService.GetPlayerData(userId)` and takes
`data.Rebirth` (number), `data.Arena.Level` (number, min 1),
`data.Arena.Wins` (number), `data.Tutorial.Completed == true`.

**Gotcha:** a missing service or a `nil` profile leaves the defaults
in place — which read as *facts*, not as "unknown". `arenaLevel`
defaults to `1` (not `0`), so a new player and an unreadable profile
are indistinguishable.

### The embed builders

All three are **pure** and headless-testable.

`_field(name, value, inline)` truncates name to 256 and value to 1024
and sets `inline = (inline == true)`.

`_truncate(text, max)` cuts to `max - 1` characters and appends `'…'`
(U+2026).

`_mentionTime(epoch)` → `'<t:1760000000:F> (<t:1760000000:R>)'` —
Discord's relative/absolute timestamp markup.

**`BuildJoinEmbed(ctx)`** — title `'🟢 Player Joined'`, description
`'A player has joined Brainrot Arena.'`, colour `Config.Colors.Join`.
Fields: `Player` (`username (@displayName)`), `User ID`,
`Account Age` (`'450 days'`), `Rebirths`, `Player Status`, `Server`
(the job id, truncated to 64), `Joined At` (the mention). Footer
`'Brainrot Arena • Player Monitoring'`.

**`BuildLeaveEmbed(ctx)`** — title `'🔴 Player Left'`, colour
`Config.Colors.Leave`. Fields: `Player`, `User ID`, `Session
Duration` (`FormatDuration`), `Rebirths`, `Joined At`, `Left At`.

**`BuildMilestoneEmbed(kind, ctx, details)`** — the copy comes from
`MILESTONE_COPY[kind]`:

| kind | title |
|---|---|
| `TutorialCompleted` | `'📘 Tutorial Completed'` |
| `ArenaCompleted` | `'⚔️ Arena Completed'` |
| `RebirthSucceeded` | `'♻️ Rebirth Succeeded'` |
| `PurchaseGranted` | `'💰 Purchase Granted'` |
| anything else | `'📌 Event'` / `'A tracked event occurred.'` / colour `Config.Colors.TutorialCompleted` |

Base fields: `Player` (`username (userId)`), `Rebirths`. Then
kind-specific fields: `RebirthSucceeded` → `New Rebirth`
(`'R' .. rebirth`); `PurchaseGranted` → `Product` and `Kind` (both
truncated to 64); `ArenaCompleted` → `Stage`.

The field array is then trimmed to Discord's 25-field limit with
`while #fields > 25 do table.remove(fields, #fields) end`.

### The formatting helpers

`FormatUtc(epoch)` → `pcall(os.date, '!%Y-%m-%dT%H:%M:%SZ', epoch)`
→ e.g. `'2025-10-09T08:53:20Z'`. On failure →
`'1970-01-01T00:00:00Z'`.

`FormatDuration(seconds)`:
- `h > 0` → `'%dh %02dm'` → `'2h 14m'`
- `m > 0` → `'%dm %02ds'` → `'12m 34s'`
- else → `'%ds'` → `'45s'`
- negative input → `math.max(0, ...)` → `'0s'`
- seconds are **truncated**, never rounded.

`FormatPlaytime(seconds)`:
- `h >= 48` → `'%.1fd'` → `'3.5d'`
- `h > 0` → `'%.1fh'` → `'2.3h'`
- else → `FormatDuration(s)`

Note the asymmetry: `FormatDuration` uses the **truncated** `h`, but
`FormatPlaytime` divides the **raw** `s` by 3600.

### The registry

`PlayerRegistry.KeyFor(userId)` → `'player_' .. tostring(userId)`.

`MergeEntry(old, delta, now)` — the pure merge. Copies `old` into a
new table, then applies `delta`:

| delta key | effect |
|---|---|
| `userId` (number) | set |
| `username`, `displayName` (non-empty string) | set |
| `firstSeen` (number) | set |
| `lastSeen` (number) | `entry.lastSeen = max(entry.lastSeen, d.lastSeen)` |
| `sessionsAdd` (number) | `entry.sessions = (entry.sessions or 0) + max(0, floor(d.sessionsAdd))` |
| `playtimeAdd` (number) | `entry.playtimeSeconds = (entry.playtimeSeconds or 0) + max(0, floor(d.playtimeAdd))` |
| `rebirths`, `arenaLevel`, `arenaWins` (number) | `max(existing, floor(d))` — **never downgraded** |
| `tutorialCompleted` (boolean) | `existing == true OR d` — **never downgraded** |
| `lastJobId` (non-empty string) | set |

Then defaults are filled: `firstSeen`/`lastSeen` → `now` if absent;
`sessions`/`playtimeSeconds` → `0` if absent.

The whole body is inside a `pcall`; on failure it returns whatever
was accumulated (possibly an empty table).

**Note the delta key names are `sessionsAdd` / `playtimeAdd`, not
`sessions` / `playtimeSeconds`.** Passing `sessions` in a delta has
**no effect** — the counter only moves via `sessionsAdd`.

`UpsertOnJoin(userId, delta)` → `{ok, entry, isFirst}`.
`isFirst` is set inside the `UpdateAsync` transform when `old == nil`
— i.e. it reflects what the DataStore actually had. On a store error
or an update failure, `ok = false` and `isFirst = false` (the header
calls this "false on ANY doubt"; the caller must render "Unknown").

`UpdateOnLeave(userId, sessionSeconds, delta)` → `{ok}`.
Forces `playtimeAdd = sessionSeconds` and `lastSeen = now` after
copying the delta, so the caller's delta cannot override them.
Note: it does **not** add a session — the counter moves only on join.

`UpdateProgress(userId, patch)` → `{ok}`.
**The transform returns `nil` when `old == nil`** — "never create from
a milestone alone". The `UpdateAsync` then writes nothing and the
result is `ok = true` with no entry.

All three use `store:UpdateAsync(key, transform)` with the transform
returning the merged value. **No reads on the hot path** —
`UpdateAsync` hands the old value to the transform.

`_getStore()` caches the `DataStore` handle. On failure it logs
`Debug.Warn('REGISTRY', 'datastore unavailable; registry writes
skipped', {})` **once** (`_storeWarned`).

---

## Public API surface (exact)

```lua
-- PlayerLogger
PlayerLogger.FormatUtc(epoch: number): string
PlayerLogger.FormatDuration(totalSeconds: number): string
PlayerLogger.FormatPlaytime(totalSeconds: number): string
PlayerLogger.BuildJoinEmbed(ctx: any): { [string]: any }
PlayerLogger.BuildLeaveEmbed(ctx: any): { [string]: any }
PlayerLogger.BuildMilestoneEmbed(kind: string, ctx: any, details: any): { [string]: any }
PlayerLogger.Init()                              -- no return
PlayerLogger.IsEnabled(): boolean
PlayerLogger.NotifyJoin(player: Player)          -- no return
PlayerLogger.NotifyLeave(player: Player)         -- no return
PlayerLogger.LogMilestone(player: Player, kind: string, details: any?)  -- no return
PlayerLogger._TestReset()                        -- no return
PlayerLogger._TestQueueLen(): number
PlayerLogger._TestEnable()                       -- no return

-- PlayerRegistry
PlayerRegistry.KeyFor(userId: number): string
PlayerRegistry.MergeEntry(old: any, delta: any, now: number): { [string]: any }
PlayerRegistry.UpsertOnJoin(userId: number, delta: any): { [string]: any }
PlayerRegistry.UpdateOnLeave(userId: number, sessionSeconds: number, delta: any): { [string]: any }
PlayerRegistry.UpdateProgress(userId: number, patch: any): { [string]: any }
PlayerRegistry._TestReset()                      -- no return
```

Both module tables are `table.freeze`d.

**Every public function returns nothing except the `Build*`,
`Format*`, `IsEnabled`, `_TestQueueLen`, `KeyFor` and `MergeEntry`
ones.** There is no success/failure return on `NotifyJoin` /
`NotifyLeave` / `LogMilestone` — you cannot tell whether the embed
was queued.

---

## Invariants the code enforces

1. **Gameplay never waits on Discord.** Every registry write and
   every embed enqueue happens on a `task.spawn`ed thread or
   synchronously-but-cheaply.
2. **The webhook URL is never logged, never replicated, never
   returned.** It lives in a local and in a Studio attribute.
3. **The registry merge is monotonic** — counters add, snapshots max,
   booleans OR, names are never blanked.
4. **The registry never creates an entry from a milestone alone.**
5. **`isFirst` is never optimistic.** Uncertain → `false`.
6. **The queue is bounded** (`QueueCap`, drop-oldest) and the retries
   are bounded (`MaxAttempts`, finite backoff list).
7. **Discord limits are respected**: title ≤ 256, description ≤ 4096,
   field name ≤ 256, field value ≤ 1024, footer ≤ 2048, ≤ 25 fields.
8. **No raw profile data is ever sent** — only the four scalar
   snapshot fields, names, counters and timestamps.
9. **Every failure path is a `Debug.Warn`, never an error.** Nothing
   in this system can throw into gameplay.

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| The webhook attribute is absent | `_enabled = false`; one `Debug.Warn`; embeds dropped; **the registry still updates**. |
| The attribute value is not a Discord webhook URL | Same as absent (the pattern check rejects it). |
| `HttpService.HttpEnabled` is false | Same as absent. |
| The DataStore is unavailable | `Debug.Warn('REGISTRY', 'datastore unavailable; registry writes skipped', {})` once; all registry calls return `ok = false`. |
| `UpdateAsync` throws | `Debug.Warn('REGISTRY', '<op> failed', {userId, err})`; the call returns `ok = false`. |
| The webhook returns 429 | Classified `'rate-limited:<n>'`; the item is re-queued at the head and retried after `max(backoff, retryAfter)`. |
| The webhook returns 500 | Classified `'status:500'`; normal backoff. |
| `JSONEncode` throws | `'encode'`; normal backoff. |
| The queue is full | The **oldest** embed is dropped; a warning on the 1st and every 50th drop. |
| `NotifyJoin` is called twice for the same live session | The second call returns immediately — no embed, no registry write. |
| The player leaves before the join thread runs | `player.Parent == nil` → the session entry is cleared and nothing is enqueued. |
| `LogMilestone` is called with an unknown kind | Silently returns — `Config.Events[kind]` is `nil`, not `true`. |
| `LogMilestone` is called with a disabled kind | Silently returns. |
| `MergeEntry(nil, {...}, now)` | Creates the entry with `firstSeen = lastSeen = now`, `sessions = 0`, `playtimeSeconds = 0`. |
| `MergeEntry` with `username = ''` | The old username is kept. |
| `MergeEntry` with `rebirths = 1` on an entry with `rebirths = 4` | Stays `4`. |
| `UpdateProgress` on a player with no registry entry | The transform returns `nil`; nothing is written; `ok = true`. |
| `FormatDuration(-5)` | `'0s'`. |
| `FormatUtc` with a bad epoch | `'1970-01-01T00:00:00Z'`. |
| A 3000-character username | Truncated to 1023 characters plus `'…'` in the field value. |

---

## Gotchas that would bite you

- **The source game shipped a live webhook URL as a literal** in
  `PlayerLoggerConfig.WebhookAttribute`, under a comment saying it
  belonged in Studio. The library copy has been sanitised and the
  field now holds the attribute **name**. Do not "restore" the URL.
- **`WebhookAttribute` is a NAME, not a URL.** This is the single most
  important thing to get right when wiring it up.
- **`Config.Events[kind]` gates `LogMilestone`.** There is no
  fallback — an unlisted kind is dropped without a log line.
- **`MergeEntry` wants `sessionsAdd` / `playtimeAdd`**, not
  `sessions` / `playtimeSeconds`. The wrong key silently does
  nothing.
- **`UpdateOnLeave` does not increment `sessions`.** Only
  `UpsertOnJoin` does.
- **`UpdateProgress` never creates an entry** — it returns `nil` from
  the transform. A milestone for a player who never joined does
  nothing.
- **`_progressSnapshot` reports zeroes as facts.** An unreadable
  profile is indistinguishable from a fresh one.
- **`_webhookUrl` is captured at `Init()`** — setting the attribute
  later does nothing.
- **`_TestEnable()` does not set `_webhookUrl`**, so any send attempt
  fails with `'request'`. It is for queue-length assertions only.
- **`_TestReset()` sets `_closing = true`**, which kills the worker
  thread, and `_workerStarted = false`. Restarting the service in the
  same server spawns a second worker.
- **`_TestReset()` does not clear `_droppedCount` semantics safely**:
  it sets it to 0, so the "every 50th drop" cadence restarts.
- **The failed item is re-inserted at the HEAD of the queue**
  (`table.insert(_queue, 1, item)`), so one bad item head-of-line
  blocks the whole queue for the backoff duration.
- **`FormatPlaytime` divides the raw seconds; `FormatDuration` uses
  the truncated hours.** `'1h 59m'` from one, `'1.9h'` from the
  other.
- **`NotifyLeave` computes the duration from `os.clock()`**, so it
  measures *this server session only*. A player who rejoined gets a
  fresh duration; the total is accumulated in the registry.
- **The `AccountAge` field is read from the live `Player`** and is
  therefore unavailable for a fake player — it defaults to `0` days.

---

## What to change to reuse it

1. **Set the webhook URL as an attribute**, never as a literal. Change
   `Config.WebhookAttribute` if you name it differently.
2. **Rewrite the embed copy** — the three `Build*` functions, the
   `MILESTONE_COPY` table, the footer, and the webhook `username` in
   `_postEmbed`.
3. **Rewrite `_postEmbed`** if your sink is not a Discord webhook
   (change the URL pattern in `_readWebhookUrl` too).
4. **Rewrite `_progressSnapshot`** for your game's progression
   fields — and fix the defaults so "unknown" is distinguishable from
   "zero".
5. **Extend `MILESTONE_COPY`** and add a matching
   `Config.Events.<Kind> = true`.
6. **Keep `PlayerRegistry.MergeEntry` as-is.** It is the hard part and
   it is generic.
7. **Keep the registry in its own DataStore** — never the gameplay
   profile store.
8. **Adjust `SendIntervalSeconds`** to your sink's rate limit.
9. **Keep `QueueCap`, `MaxAttempts` and `RetryBackoffSeconds`
   finite.** They are what stops a sink outage from becoming a server
   outage.
10. **Keep every `task.spawn` / `pcall`.** The "never
    gameplay-critical" guarantee is the system's entire value.
