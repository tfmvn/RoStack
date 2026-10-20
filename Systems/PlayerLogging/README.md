# PlayerLogging

Server-side player monitoring for Brainrot Arena: **lifecycle** (join /
leave) and **milestone** events shipped as Discord webhook embeds, plus
a persistent **all-time player registry** in its own DataStore.

**Portability:** Grade A core (the embed builders, the bounded
delivery queue, the monotonic registry merge) + Grade B (the Discord
webhook as the sink, the Brainrot Arena copy and colours, and the
snapshot fields). See *Portability* below.

**Source game:** Brainrot Arena (`p-7`).

> **Credential warning.** The source game shipped a **live Discord
> webhook URL as a literal** in `PlayerLoggerConfig.WebhookAttribute`.
> The library copy has been sanitised: the field now holds the
> **attribute name** (`'PlayerLoggerWebhookUrl'`), which is what the
> consuming code actually reads. The URL itself is a secret and must
> live only in a Studio place file or a runtime attribute — never in
> source control. See `PlayerLoggerConfig.lua` and
> `Setup.md` §5.

---

## What It Does

```
  PLAYER JOINS                 PLAYER LEAVES              MILESTONE
      |                             |                          |
      v                             v                          v
  NotifyJoin(player)         NotifyLeave(player)        LogMilestone(player,
      |                             |                     kind, details)
      |                             |                          |
      v                             v                          v
  _progressSnapshot()        _progressSnapshot()       _progressSnapshot()
  (rebirths / arenaLevel /   (same)                   (same)
   arenaWins / tutorial)
      |                             |                          |
      +-------------+---------------+--------------------------+
                    |
                    v
        PlayerRegistry  ->  DataStore "p7_PlayerRegistry_v1"
        (monotonic merge, one key per player)
                    |
                    v
        PlayerLogger  ->  bounded queue  ->  worker  ->  Discord webhook
        (embed builders)   (cap 200)       (1.2s gap)    (HTTP POST)
```

Three guarantees shape the whole design:

1. **Never gameplay-critical.** Every send is async through a bounded
   queue. A Discord outage can neither OOM the server nor wedge a
   join, leave, save, purchase or rebirth.
2. **The webhook URL is a runtime attribute**, never a literal, never
   replicated, never logged, never client-visible.
3. **Missing URL or HTTP disabled → Discord off, registry still
   updates.** The game runs exactly as before, with one diagnostic.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `PlayerLogger.Init()` | Server | Reads the webhook attribute, probes `HttpService.HttpEnabled`, starts the worker, registers the `BindToClose` flush. Idempotent. |
| `PlayerLogger.NotifyJoin(player)` | Server | Session start. Dedupes by live session. Spawns the registry upsert. Enqueues a join embed. |
| `PlayerLogger.NotifyLeave(player)` | Server | Session end. Computes the duration from the server join tick. Spawns the registry update. Enqueues a leave embed. |
| `PlayerLogger.LogMilestone(player, kind, details?)` | Server | A tracked milestone. Spawns a registry progress refresh. Enqueues a milestone embed. |
| `PlayerLogger.IsEnabled()` | Server | Whether Discord delivery is on. |
| `PlayerLogger.BuildJoinEmbed(ctx)` | Server (pure) | Builds the join embed. Headless-testable. |
| `PlayerLogger.BuildLeaveEmbed(ctx)` | Server (pure) | Builds the leave embed. |
| `PlayerLogger.BuildMilestoneEmbed(kind, ctx, details)` | Server (pure) | Builds a milestone embed from the `MILESTONE_COPY` table. |
| `PlayerLogger.FormatUtc(epoch)` | Server (pure) | ISO-8601 UTC string. |
| `PlayerLogger.FormatDuration(seconds)` | Server (pure) | `'45s'`, `'12m 34s'`, `'2h 14m'`. |
| `PlayerLogger.FormatPlaytime(seconds)` | Server (pure) | `'45s'`, `'2.3h'`, `'3.5d'`. |
| `PlayerRegistry.KeyFor(userId)` | Server (pure) | `'player_<userId>'`. |
| `PlayerRegistry.MergeEntry(old, delta, now)` | Server (pure) | The monotonic merge. The concurrency-safety core. |
| `PlayerRegistry.UpsertOnJoin(userId, delta)` | Server | `+1` session, refresh names/snapshot. Returns `{ok, entry, isFirst}`. |
| `PlayerRegistry.UpdateOnLeave(userId, sessionSeconds, delta)` | Server | Add playtime, refresh `lastSeen` + snapshot. |
| `PlayerRegistry.UpdateProgress(userId, patch)` | Server | Snapshot fields only, no counters. **Never creates an entry.** |
| `PlayerLogger._TestReset()` / `PlayerRegistry._TestReset()` | Test seam | Clear in-memory state. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/PlayerLogger/PlayerLogger.lua` | `ServerScriptService.PlayerLogger.PlayerLogger` | Embed builders, bounded delivery queue, worker, public API. |
| `Source/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` | `ServerScriptService.PlayerLogger.PlayerLoggerConfig` | Static tunables (queue cap, backoff, event toggles, colours, **attribute name**). |
| `Source/ServerScriptService/PlayerLogger/PlayerRegistry.lua` | `ServerScriptService.PlayerLogger.PlayerRegistry` | The persistent all-time registry (DataStore). |

---

## Configuration

`PlayerLoggerConfig.lua` is **data only** — no services, no secrets,
no HTTP.

| Field | Default | Meaning |
|---|---|---|
| `WebhookAttribute` | `'PlayerLoggerWebhookUrl'` | The **name** of the `ServerScriptService` string attribute that holds the Discord webhook URL. The URL is a secret and never lives in this file. |
| `RegistryStoreName` | `'p7_PlayerRegistry_v1'` | The DataStore name for the registry. Separate from the gameplay profile store. |
| `RegistryKeyPrefix` | `'player_'` | Key prefix; the key is `player_<userId>`. |
| `QueueCap` | `200` | Max queued embeds. When full, the **oldest** is dropped. |
| `SendIntervalSeconds` | `1.2` | Minimum gap between two webhook POSTs. |
| `MaxAttempts` | `3` | Total attempts per embed before it is dropped with a diagnostic. |
| `RetryBackoffSeconds` | `{2, 8}` | Backoff between attempts. Attempts past the list reuse the last entry. |
| `ShutdownFlushMax` | `5` | Max embeds drained synchronously on `BindToClose`. |
| `Events.Join` / `.Leave` / `.TutorialCompleted` / `.ArenaCompleted` / `.RebirthSucceeded` / `.PurchaseGranted` | all `true` | Per-kind toggles. |
| `Colors.*` | `3066993` / `15158332` / `3447003` / `10181046` / `15844367` / `5763719` | Decimal embed colours: green / red / blue / purple / gold / teal. |

See `Config.lua` for a commented copy of every field.

### External requirements

| Requirement | Where | If missing |
|---|---|---|
| `ServerScriptService` attribute `PlayerLoggerWebhookUrl` holding a `https://discord.com/api/webhooks/...` URL | Studio place file, or set at runtime before `Init()` | Discord delivery stays off; registry still updates; one `Debug.Warn`. |
| `HttpService.HttpEnabled == true` | Game Settings → Security → **Allow HTTP Requests** (the live game needs this; "Enable Studio Access to API" is not enough) | Same as above. |
| `ReplicatedStorage.Utility.Debug` | SharedUtilities system | The module fails to load. |

The URL is validated with the pattern
`^https://discord%.com/api/webhooks/` — a value that does not match is
treated as absent.

---

## Dependencies

See `Dependencies.md` for the full list.

Module requires:

- `ServerScriptService/PlayerLogger/PlayerLogger.lua` →
  `script.Parent.PlayerLoggerConfig`,
  `script.Parent.PlayerRegistry`,
  `script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug`
- `ServerScriptService/PlayerLogger/PlayerRegistry.lua` →
  `script.Parent.PlayerLoggerConfig`,
  `script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug`

Both are leaves at the top (they never require a gameplay service at
load). `PlayerService` is reached **lazily** inside
`_progressSnapshot` via `ServerScriptService:WaitForChild('PlayerService', 2)`,
which is what keeps the module cycle-free.

Roblox services: `HttpService`, `ServerScriptService`,
`DataStoreService`, `Players` (not directly — the bootstrap calls
`NotifyJoin`/`NotifyLeave`).

---

## Initialization Order

```text
1. createRemotes()                        -- unrelated to this system
2. PlayerService.Init()                   -- the snapshot needs it
3. PlayerLogger.Init()                    -- reads the webhook attribute,
                                           -- probes HttpEnabled,
                                           -- starts the worker,
                                           -- registers the BindToClose flush
4. Players.PlayerAdded    -> PlayerLogger.NotifyJoin(player)
5. Players.PlayerRemoving -> PlayerLogger.NotifyLeave(player)
```

`PlayerLogger.Init()` must run **before** the first `NotifyJoin`,
otherwise `_enabled` is `false` and the join embed is dropped (the
registry write still happens, because `NotifyJoin` enqueues only the
embed).

**The webhook attribute must be set before `Init()`** — `_webhookUrl`
is read exactly once, at `Init()` (line 374). Setting it later has no
effect until the next server start.

`Init()` is idempotent (`_workerStarted` guard).

---

## Data

### The registry (DataStore `p7_PlayerRegistry_v1`)

One key per player: `player_<userId>`.

```lua
{
    userId = 12345,          -- number
    username = 'Name',       -- string, never blanked
    displayName = 'Name',    -- string, never blanked
    firstSeen = 1760000000,  -- unix UTC
    lastSeen = 1760000754,   -- unix UTC
    sessions = 3,            -- number, additive
    playtimeSeconds = 500,   -- number, additive
    rebirths = 2,            -- number, max()
    arenaLevel = 1,          -- number, max()
    arenaWins = 0,           -- number, max()
    tutorialCompleted = false,-- boolean, OR
    lastJobId = 'job-id',    -- string
}
```

**Merge semantics** (in `PlayerRegistry.MergeEntry`):

| Field | Rule |
|---|---|
| `firstSeen` | Set once, on creation. Never moved. |
| `lastSeen` | `max(old, delta)` — monotonic. |
| `sessions` | `old + delta.sessionsAdd` — additive. |
| `playtimeSeconds` | `old + delta.playtimeAdd` — additive. |
| `rebirths`, `arenaLevel`, `arenaWins` | `max(old, delta)` — never downgraded. |
| `tutorialCompleted` | `old OR delta` — never downgraded to `false`. |
| `username`, `displayName` | Overwritten only when the new value is a **non-empty string**. Never blanked. |
| `lastJobId` | Overwritten only when the new value is a non-empty string. |

The merge is a **pure function** of `(old, delta, now)` and is run
inside `DataStoreService:UpdateAsync`, so concurrent servers cannot
overwrite each other's counters.

### The in-memory session table

`PlayerLogger._sessions[userId] = { joinTick = os.clock(), joinTime = os.time() }`.

`joinTick` is `os.clock()` (monotonic, server-local) and is used to
compute the session duration. `joinTime` is `os.time()` (wall clock)
and is only used for display.

---

## Known Limitations

- **The `PlayerService` snapshot is best-effort and can be stale.**
  `_progressSnapshot` requires `PlayerService` with a 2-second
  `WaitForChild`. If the service is not yet present, the snapshot
  falls back to `{rebirths = 0, arenaLevel = 1, arenaWins = 0,
  tutorialCompleted = false}` — which is a **lie**, not "unknown". A
  join embed can therefore say "Rebirths 0" for a veteran.
- **`PlayerService.GetPlayerData(userId)` must return the live
  profile table.** If it returns `nil`, the same fallback applies.
- **The registry write is fire-and-forget.** `NotifyJoin` /
  `NotifyLeave` / `LogMilestone` all `task.spawn` the DataStore
  write. A server that closes immediately after a leave may lose that
  write — the `BindToClose` flush only drains the **webhook queue**,
  not the registry.
- **`isFirst` is `false` on ANY doubt.** If the store is unavailable
  or the update fails, `UpsertOnJoin` returns `ok = false,
  isFirst = false`, and the embed says `"Player Status: Unknown"`
  rather than a false "Returning Player". This is deliberate.
- **A double join counts two sessions.** The engine prevents two
  `Player` objects for one `userId`, but the registry's `sessionsAdd`
  is a blind `+1` — it cannot detect a duplicate. The in-memory
  `_sessions` guard prevents a duplicate *embed* within one server
  session, but not across a rejoin.
- **The Discord rate limit is handled but the queue can still fill.**
  Discord allows ~30 posts/minute; the config's 1.2 s gap is ~50/min.
  A 429 is honoured via the `Retry-After` header (clamped to
  1..60 s), and the failed item is **re-inserted at the head of the
  queue** — so it blocks the queue behind it.
- **`_postEmbed` failures are classified, not diagnosed.** The reason
  strings are `'encode'`, `'request'`, `'rate-limited:<n>'` and
  `'status:<code>'`. The HTTP body is never logged (it can contain
  the webhook URL).
- **The queue is drop-oldest.** At `QueueCap` (200) the oldest embed
  is discarded. A diagnostic is logged on the 1st drop and every
  50th.
- **`_TestReset()` does not stop the worker thread.** It sets
  `_closing = true`, which makes the worker exit its loop, but a
  running `task.wait` inside `_worker` still completes first. Calling
  `_TestReset()` mid-flight can leave the worker dead and
  `_workerStarted` false.
- **`_TestEnable()` sets `_enabled = true` but `_webhookUrl` stays
  `nil`.** Any queued item then fails with a `RequestAsync` on a
  `nil` URL → `'request'` → retried and dropped. The seam is for
  queue-length assertions only.
- **`PlayerRegistry._TestReset()` only clears the cached DataStore
  handle** and the one-shot warning flag. It does not delete any
  stored data.
- **The DataStore is not session-locked.** `PlayerRegistry` uses
  plain `UpdateAsync`, not `ProfileService`. Concurrent servers are
  safe thanks to the pure merge, but a **crash mid-update** is
  handled by DataStore's own retry semantics only.
- **The embed copy is Brainrot Arena's.** `'A player has joined
  Brainrot Arena.'`, the footer `'Brainrot Arena • Player
  Monitoring'`, the webhook `username = 'Brainrot Arena'`, and the
  emoji titles are all game-specific.
- **No client-facing surface at all.** Nothing is sent to players;
  this is an operator tool.

---

## Testing

`Tests/PlayerLogger.spec.lua` — 9 cases in two groups.

*Builders* — the join embed's layout and field values, the leave
embed's session duration, milestone embeds for `RebirthSucceeded` and
`PurchaseGranted` (with the whitelisted `Product` field), truncation
of a 3000-character username to Discord's limits, duration formatting
(`'45s'`, `'12m 34s'`, `'2h 14m'`, `'0s'` for a negative input), and
"disabled with no webhook → queue stays empty".

*Registry merge* — sane defaults from `nil`, monotonic merging across
two successive writers (sessions `3 → 5`, playtime `500 → 590`,
`lastSeen` stays `300`, `firstSeen` stays `100`), no downgrade of
snapshots or names to empty, and the stable `player_<userId>` key.

The spec **never touches the network and never touches a DataStore**
(no `DataStoreService` is mocked; the merge is exercised through the
pure `MergeEntry` function). Live HTTP delivery, DataStore
persistence and Studio join/leave are Studio-verified.

Run it with the TestEZ runner. See `../../Tests/README.md`.

---

## Portability

**Grade A — portable core**, with a **Grade B** sink/adapter layer.

**Grade A (portable as-is):**
- `PlayerRegistry.MergeEntry` — the pure monotonic merge. This is the
  hard part and it is fully generic.
- The `UpdateAsync`-based store pattern with one key per player.
- The embed builders' Discord-limit discipline (256 / 4096 / 1024 /
  2048 / 25 fields), the `_truncate` helper, and `_field`.
- The bounded queue: drop-oldest, capped retries, exponential-ish
  backoff, 429 `Retry-After` honouring, shutdown flush.
- The `FormatUtc` / `FormatDuration` / `FormatPlaytime` helpers.
- The "never gameplay-critical" contract (`task.spawn` everywhere,
  `pcall` everywhere).

**Grade B (game-specific adapter — must be rewritten):**
- **The Discord webhook as the sink.** The whole delivery path is
  hard-coded to `https://discord.com/api/webhooks/`. A different sink
  (Slack, a log file, Roblox `MessagingService`) means rewriting
  `_postEmbed` and `_readWebhookUrl`.
- The Brainrot Arena copy: titles, descriptions, footers, the webhook
  `username`, the emoji.
- The snapshot fields (`rebirths`, `arenaLevel`, `arenaWins`,
  `tutorialCompleted`) and the `_progressSnapshot` reader.
- The milestone kinds (`TutorialCompleted`, `ArenaCompleted`,
  `RebirthSucceeded`, `PurchaseGranted`) and their colours.
- The `PlayerService.GetPlayerData(userId)` contract.

**Grade C (platform-bound):** none in the sense of an external
service — Discord is a plain HTTPS endpoint, not a Roblox platform
feature. `DataStoreService` is a Roblox platform service but is
wrapped in a standard pattern. The `ServerScriptService` **attribute**
as the secret store is a Studio convention, not a Roblox API
guarantee.

---

## Adapting to a New Game

1. **Never commit the webhook URL.** Set it as a
   `ServerScriptService` attribute in a Studio place file, or inject
   it at runtime before `PlayerLogger.Init()`. Change
   `Config.WebhookAttribute` if you use a different attribute name.
2. **Enable HTTP Requests** in the live game's security settings, or
   the logger silently degrades to registry-only.
3. **Rewrite the embed copy** in `BuildJoinEmbed` / `BuildLeaveEmbed`
   / `BuildMilestoneEmbed` and `MILESTONE_COPY`, plus the webhook
   `username` in `_postEmbed`.
4. **Rewrite `_progressSnapshot`** to read your game's progression
   fields, and update the `snap` default table so an unreadable
   profile does not report zeroes as if they were facts.
5. **Extend `MILESTONE_COPY`** with your own kinds, and add a
   matching `Config.Events.<Kind> = true` toggle — `LogMilestone`
   **silently returns** for any kind that is not toggled on.
6. **Wire the lifecycle** in your bootstrap:
   `PlayerAdded → NotifyJoin`, `PlayerRemoving → NotifyLeave`.
7. **Call `LogMilestone` after the authoritative commit**, inside a
   `pcall`, from the owning service.
8. **Keep the registry in its own DataStore.** It must not share the
   gameplay profile store.
9. **Adjust `SendIntervalSeconds`** to your sink's rate limit:
   Discord allows ~30 posts/minute, so the shipped 1.2 s gap
   (≈50/min) can trigger 429s.
