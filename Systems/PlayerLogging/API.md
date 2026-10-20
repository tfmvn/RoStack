# PlayerLogging — API

Every public function of every module in this system. There are three
modules:

- `ServerScriptService.PlayerLogger.PlayerLogger` — embeds + delivery.
- `ServerScriptService.PlayerLogger.PlayerRegistry` — persistence.
- `ServerScriptService.PlayerLogger.PlayerLoggerConfig` — **data
  only**, no functions.

All functions are **server-only**. Nothing here may be called from a
client script.

---

## `ServerScriptService.PlayerLogger.PlayerLogger`

```lua
local PlayerLogger = require(game:GetService('ServerScriptService').PlayerLogger.PlayerLogger)
```

The module table is frozen (`table.freeze`) — you cannot add fields
at runtime.

**Threading:** `NotifyJoin`, `NotifyLeave` and `LogMilestone` spawn
threads internally and return immediately. They never yield the
caller.

---

### `PlayerLogger.Init()`

Boot the monitoring subsystem.

**Kind:** server lifecycle. **Parameters:** none. **Returns:** nothing.

**Behaviour**

1. Returns immediately if `_workerStarted` is already `true`
   (**idempotent**).
2. Reads the webhook URL from the `ServerScriptService` attribute
   named by `Config.WebhookAttribute` — **once, here**.
3. Probes `HttpService.HttpEnabled`.
4. Enables delivery only if **both** are available; otherwise logs one
   `Debug.Warn('PLOG', 'webhook disabled (missing URL attribute or
   HTTP off); registry-only mode', {})` and leaves `_enabled = false`.
5. `task.spawn`s the delivery worker.
6. Registers a `game:BindToClose` handler that sets `_closing = true`
   and best-effort drains up to `Config.ShutdownFlushMax` (5) queued
   embeds.

**Failure modes:** never throws. A missing attribute, a malformed URL
and `HttpEnabled == false` all degrade to registry-only mode with a
single diagnostic.

**Ordering:** the attribute must be set **before** this call — the URL
is not re-read.

---

### `PlayerLogger.IsEnabled(): boolean`

Whether Discord delivery is on.

**Parameters:** none.
**Returns:** `true` when both the webhook URL and HTTP were available
at `Init()`; `false` otherwise.

**Note:** this says nothing about whether the URL is still valid — it
is the state captured at `Init()`.

---

### `PlayerLogger.NotifyJoin(player: Player)`

Record a player's session start.

**Kind:** server lifecycle. **Parameters:** `player: Player`.
**Returns:** nothing.

**Behaviour**

1. Reads `player.UserId` inside a `pcall`. Not a number → returns.
2. **Session guard:** if `_sessions[userId]` already exists → returns
   immediately (no embed, no registry write). This dedupes a repeated
   join for the same live session.
3. Records `_sessions[userId] = { joinTick = os.clock(), joinTime =
   os.time() }` — **before** the event toggle, so the session is
   tracked even when the join event is disabled.
4. If `Config.Events.Join ~= true` → returns (no embed, no registry
   write).
5. Spawns a thread that:
   - re-checks `player.Parent ~= nil` — if the player already left,
     the session entry is cleared and nothing happens;
   - takes a `_progressSnapshot(userId)`;
   - calls `PlayerRegistry.UpsertOnJoin(userId, {...})` and derives
     `statusText` — `'First-Time Player'` when `upsert.isFirst == true`,
     `'Returning Player'` when `isFirst == false` and `ok == true`,
     `'Unknown'` when `ok == false`;
   - reads `player.AccountAge` (default `0`);
   - enqueues the join embed.

**Failure modes:** never throws. The registry call is inside a
`pcall`; the embed is enqueued even if the registry write failed.

**Note:** the return value is nothing — you cannot tell whether the
embed was queued.

---

### `PlayerLogger.NotifyLeave(player: Player)`

Record a player's session end.

**Kind:** server lifecycle. **Parameters:** `player: Player`.
**Returns:** nothing.

**Behaviour**

1. Reads `player.UserId`; not a number → returns.
2. Takes and clears `_sessions[userId]`.
3. If `Config.Events.Leave ~= true` → returns.
4. `durationSecs = math.max(0, math.floor(os.clock() - joinTick))` —
   the **server-local** session duration, measured from the join tick.
   If there was no session, `joinTick` falls back to `os.clock()`, so
   the duration is `0`.
5. `leaveTime = os.time()`.
6. Takes a `_progressSnapshot(userId)` **synchronously**.
7. Spawns `PlayerRegistry.UpdateOnLeave(userId, durationSecs, {...})`.
8. Enqueues the leave embed **synchronously**.

**Failure modes:** never throws.

**Note:** the duration measures **this server session only**. The
all-time total lives in the registry's `playtimeSeconds`.

---

### `PlayerLogger.LogMilestone(player: Player, kind: string, details?: any)`

Record a tracked milestone.

**Kind:** server event. **Parameters:** `player: Player`,
`kind: string`, `details: any?`. **Returns:** nothing.

**Behaviour**

1. `if Config.Events[kind] ~= true then return end` — **an unknown or
   disabled kind is silently ignored**. There is no warning and no
   fallback copy for the embed (the embed builder does have a generic
   `'📌 Event'` title, but you never reach it).
2. Everything else is inside a `pcall`.
3. Takes a `_progressSnapshot(userId)`.
4. Spawns `PlayerRegistry.UpdateProgress(userId, {...})` — snapshot
   fields only, no counters.
5. Enqueues `BuildMilestoneEmbed(kind, {...}, details)`.

**Failure modes:** never throws.

**Details shape** (per kind):

| kind | `details` keys used |
|---|---|
| `RebirthSucceeded` | `rebirth` → the `New Rebirth` field (`'R' .. rebirth`) |
| `PurchaseGranted` | `product_key` → `Product`, `kind` → `Kind` (both truncated to 64 chars) |
| `ArenaCompleted` | `stage` → `Stage` |
| `TutorialCompleted` | none — the details are ignored |

**Example**

```lua
pcall(function()
    PlayerLogger.LogMilestone(player, 'RebirthSucceeded', { rebirth = 3 })
end)
```

---

### `PlayerLogger.BuildJoinEmbed(ctx): { [string]: any }`

Build the join embed.

**Kind:** pure builder. **Parameters:** `ctx: any` — a table (any
non-table is treated as `{}`). **Returns:** an embed table.

**`ctx` keys**

| Key | Type | Default | Used for |
|---|---|---|---|
| `username` | string | `'???'` | the `Player` field |
| `displayName` | string | `username` | the `Player` field |
| `userId` | number | `'?'` | the `User ID` field |
| `accountAgeDays` | number | `'?'` | the `Account Age` field (`'450 days'`) |
| `rebirths` | number | `0` | the `Rebirths` field |
| `statusText` | string | `'Unknown'` | the `Player Status` field |
| `jobId` | string | `'?'` | the `Server` field (truncated to 64) |
| `joinTime` | number | `os.time()` | the `timestamp` and `Joined At` field |

**Returns**

```lua
{
    title = '🟢 Player Joined',
    description = 'A player has joined Brainrot Arena.',
    color = Config.Colors.Join,
    timestamp = '2025-10-09T08:53:20Z',
    fields = {
        { name = 'Player',      value = 'Name (@Display)', inline = true },
        { name = 'User ID',     value = '156',            inline = true },
        { name = 'Account Age', value = '450 days',       inline = true },
        { name = 'Rebirths',    value = '2',              inline = true },
        { name = 'Player Status', value = 'Returning Player', inline = true },
        { name = 'Server',      value = 'job-1',          inline = true },
        { name = 'Joined At',   value = '<t:1760000000:F> (<t:1760000000:R>)', inline = false },
    },
    footer = { text = 'Brainrot Arena • Player Monitoring' },
}
```

**Failure modes:** never throws. Every value is coerced with
`tostring` and truncated to Discord's limits (title ≤ 256,
description ≤ 4096, field name ≤ 256, field value ≤ 1024, footer ≤
2048). Over-long values are cut to `max - 1` characters and get a
`'…'` appended.

---

### `PlayerLogger.BuildLeaveEmbed(ctx): { [string]: any }`

Build the leave embed.

**Kind:** pure builder. **Parameters:** `ctx: any`.
**Returns:** an embed table.

**`ctx` keys:** `username` (`'???'`), `displayName` (`username`),
`userId` (`'?'`), `sessionSeconds` (`0`), `joinTime` (`os.time()`),
`leaveTime` (`os.time()`), `rebirths` (`0`).

**Returns**

```lua
{
    title = '🔴 Player Left',
    description = 'A player has left Brainrot Arena.',
    color = Config.Colors.Leave,
    timestamp = '...',
    fields = {
        { name = 'Player',           value = 'Name (@Display)', inline = true },
        { name = 'User ID',          value = '261',            inline = true },
        { name = 'Session Duration', value = '12m 34s',        inline = true },
        { name = 'Rebirths',         value = '1',              inline = true },
        { name = 'Joined At',        value = '<t:...:F> (<t:...:R>)', inline = true },
        { name = 'Left At',          value = '<t:...:F> (<t:...:R>)', inline = true },
    },
    footer = { text = 'Brainrot Arena • Player Monitoring' },
}
```

**Failure modes:** never throws. `sessionSeconds` goes through
`FormatDuration`, so it renders as `'45s'` / `'12m 34s'` / `'2h 14m'`.

---

### `PlayerLogger.BuildMilestoneEmbed(kind: string, ctx: any, details: any): { [string]: any }`

Build a milestone embed.

**Kind:** pure builder. **Parameters:** `kind: string`, `ctx: any`,
`details: any`. **Returns:** an embed table.

**`ctx` keys:** `username` (`'???'`), `userId` (`'?'`), `rebirths`
(`0`).

**`details` keys:** per kind — see `LogMilestone` above. A non-table
`details` is treated as `{}`.

**Copy table**

| `kind` | title | description |
|---|---|---|
| `TutorialCompleted` | `'📘 Tutorial Completed'` | `'A player finished onboarding.'` |
| `ArenaCompleted` | `'⚔️ Arena Completed'` | `'A player cleared a full arena run.'` |
| `RebirthSucceeded` | `'♻️ Rebirth Succeeded'` | `'A player rebirthed.'` |
| `PurchaseGranted` | `'💰 Purchase Granted'` | `'A Developer Product grant committed.'` |
| anything else | `'📌 Event'` | `'A tracked event occurred.'` (colour: `Config.Colors.TutorialCompleted`) |

**Base fields:** `Player` (`'Name (userId)'`), `Rebirths`.

**Kind-specific fields:** `New Rebirth` / `Product` + `Kind` /
`Stage`.

**Failure modes:** never throws. The field array is trimmed to
Discord's 25-field limit.

---

### `PlayerLogger.FormatUtc(epoch: number): string`

Format a unix timestamp as an ISO-8601 UTC string.

**Parameters:** `epoch: number`. **Returns:** e.g.
`'2025-10-09T08:53:20Z'`.

**Failure modes:** never throws. The `os.date` call is inside a
`pcall`; on failure it returns the literal
`'1970-01-01T00:00:00Z'`.

---

### `PlayerLogger.FormatDuration(totalSeconds: number): string`

Format a duration for display.

**Parameters:** `totalSeconds: number`. **Returns:** a string.

| Input | Output |
|---|---|
| `45` | `'45s'` |
| `754` | `'12m 34s'` |
| `8070` | `'2h 14m'` |
| `0` | `'0s'` |
| `-5` | `'0s'` |

**Failure modes:** never throws. The input is `math.max(0,
math.floor(totalSeconds or 0))`, so `nil` → `'0s'` and a negative
value → `'0s'`. Seconds are **truncated**, never rounded, and the
minutes are zero-padded (`'%02dm'`, `'%02ds'`).

---

### `PlayerLogger.FormatPlaytime(totalSeconds: number): string`

Format an all-time playtime for display.

**Parameters:** `totalSeconds: number`. **Returns:** a string.

| Input | Output |
|---|---|
| `45` | `'45s'` (delegates to `FormatDuration`) |
| `8280` | `'2.3h'` |
| `302400` (3.5 days) | `'3.5d'` |

**Failure modes:** never throws. `nil` → `'0s'`.

**Note:** the switch to days happens at **48 hours**, not 24. Below
that it is hours (`'%.1fh'`), computed from the **raw** seconds — so
`FormatDuration` and `FormatPlaytime` can disagree by a rounding
difference on the same input.

---

### Test seams

#### `PlayerLogger._TestReset()`

Clear the in-memory state.

**Parameters / Returns:** none.

**Clears:** `_webhookUrl`, `_enabled`, `_workerStarted`, `_closing`,
`_queue`, `_lastSendTick`, `_droppedCount`, `_configWarned`,
`_sessions`.

**Side effect:** `_closing = true` makes the running worker exit its
loop, and `_workerStarted = false` means a subsequent `Init()` will
spawn a **new** worker.

**Does not clear:** the DataStore contents.

#### `PlayerLogger._TestQueueLen(): number`

The number of queued embeds.

**Returns:** `#_queue`.

#### `PlayerLogger._TestEnable()`

Force `_enabled = true`.

**Parameters / Returns:** none.

**Note:** it does **not** set `_webhookUrl`. Any actual send will fail
with the `'request'` reason. It is intended for queue-length
assertions only.

---

## `ServerScriptService.PlayerLogger.PlayerRegistry`

```lua
local PlayerRegistry = require(game:GetService('ServerScriptService').PlayerLogger.PlayerRegistry)
```

Frozen module table.

---

### `PlayerRegistry.KeyFor(userId: number): string`

The DataStore key for a player.

**Parameters:** `userId: number`.
**Returns:** `'player_' .. tostring(userId)` → e.g.
`'player_123456789'`.

**Failure modes:** never throws. A non-number produces
`'player_<tostring>'`.

---

### `PlayerRegistry.MergeEntry(old: any, delta: any, now: number): { [string]: any }`

The pure merge — the concurrency-safety core of the registry.

**Kind:** pure function. **Parameters:** `old: any` (the stored entry
or `nil`), `delta: any` (the incoming fields), `now: number` (the
unix timestamp used for defaults).

**Returns:** a **new** table. The `old` table is not mutated.

**Merge rules**

| delta key | Rule |
|---|---|
| `userId` (number) | set |
| `username` (non-empty string) | set — an empty string is **ignored** |
| `displayName` (non-empty string) | set — an empty string is **ignored** |
| `firstSeen` (number) | set |
| `lastSeen` (number) | `max(existing, delta)` |
| `sessionsAdd` (number) | `sessions = (existing or 0) + max(0, floor(delta))` |
| `playtimeAdd` (number) | `playtimeSeconds = (existing or 0) + max(0, floor(delta))` |
| `rebirths` (number) | `max(existing, floor(delta))` |
| `arenaLevel` (number) | `max(existing, floor(delta))` |
| `arenaWins` (number) | `max(existing, floor(delta))` |
| `tutorialCompleted` (boolean) | `existing == true OR delta` |
| `lastJobId` (non-empty string) | set — an empty string is **ignored** |

Then defaults: `firstSeen`/`lastSeen` → `now` if absent;
`sessions`/`playtimeSeconds` → `0` if absent.

**Failure modes:** never throws. The body is inside a `pcall`; on
failure the partially built table is returned.

**Note the delta key names:** `sessionsAdd` and `playtimeAdd`, **not**
`sessions` and `playtimeSeconds`. Passing the wrong key silently does
nothing.

**Example**

```lua
PlayerRegistry.MergeEntry(nil, { userId = 42, username = 'Noob' }, 1000)
-- { userId = 42, username = 'Noob', firstSeen = 1000, lastSeen = 1000,
--   sessions = 0, playtimeSeconds = 0 }
```

---

### `PlayerRegistry.UpsertOnJoin(userId: number, delta: any): { [string]: any }`

Record a session start.

**Kind:** persistence. **Parameters:** `userId: number`, `delta: any`.

**Returns**

```lua
{ ok = boolean, entry = { [string]: any }?, isFirst = boolean }
```

| Field | Meaning |
|---|---|
| `ok` | `true` only if the `UpdateAsync` completed without throwing. |
| `entry` | The merged entry, or `nil` on failure. |
| `isFirst` | `true` only if the transform observed `old == nil` (i.e. the key did not exist). **`false` on any doubt.** |

**Behaviour**

- The transform receives `old`; if `old == nil` it sets `created = true`.
- The delta is built as `{ sessionsAdd = 1, lastSeen = now }` and then
  the caller's `delta` is copied over it — but `d.lastSeen` is
  re-forced to `now` **after** the copy, so the caller cannot override
  it. `sessionsAdd` is *not* re-forced, so a caller delta containing
  `sessionsAdd` would overwrite the `1`.
- The transform returns `MergeEntry(old, d, now)`.

**Failure modes:** never throws. A missing DataStore → `ok = false`. A
throwing `UpdateAsync` → `Debug.Warn('REGISTRY', 'join upsert
failed', {userId, err})` and `ok = false`.

**Note:** there is no read on the hot path — `UpdateAsync` hands the
old value to the transform.

---

### `PlayerRegistry.UpdateOnLeave(userId: number, sessionSeconds: number, delta: any): { [string]: any }`

Record a session end.

**Kind:** persistence. **Parameters:** `userId: number`,
`sessionSeconds: number`, `delta: any`.

**Returns:** `{ ok = boolean }` (plus `entry` on success).

**Behaviour**

- The transform builds `{ playtimeAdd = sessionSeconds, lastSeen =
  now }`, copies the caller's delta over it, then **re-forces**
  `d.playtimeAdd = sessionSeconds` and `d.lastSeen = now`.
- The merge is `MergeEntry(old, d, now)`.
- **No session counter is incremented** — only `UpsertOnJoin` does
  that.

**Failure modes:** never throws. On failure →
`Debug.Warn('REGISTRY', 'leave update failed', {userId, err})` and
`ok = false`.

---

### `PlayerRegistry.UpdateProgress(userId: number, patch: any): { [string]: any }`

Refresh the snapshot fields for a player.

**Kind:** persistence. **Parameters:** `userId: number`,
`patch: any`.

**Returns:** `{ ok = boolean }` (plus `entry` on success).

**Behaviour**

- The transform **returns `nil` when `old == nil`** — "never create
  from a milestone alone". `UpdateAsync` then writes nothing.
- The patch is copied over `{ lastSeen = now }`, and `d.lastSeen` is
  re-forced to `now`.
- Only snapshot fields should be in the patch (`rebirths`,
  `arenaLevel`, `arenaWins`, `tutorialCompleted`). Counters are not
  touched because the merge only adds on `sessionsAdd` /
  `playtimeAdd`.

**Failure modes:** never throws. A non-table `patch` → `ok = false`
with no write. A throwing `UpdateAsync` →
`Debug.Warn('REGISTRY', 'progress update failed', {userId, err})`.

---

### `PlayerRegistry._TestReset()`

Clear the cached DataStore handle and the one-shot warning flag.

**Parameters / Returns:** none.

**Does not delete any stored data.** The next call re-acquires the
store (and re-logs the "datastore unavailable" warning if it is still
unavailable).

---

## `ServerScriptService.PlayerLogger.PlayerLoggerConfig`

A **data module**. It has no functions.

**Returns**

```lua
{
    WebhookAttribute = 'PlayerLoggerWebhookUrl',
    RegistryStoreName = 'p7_PlayerRegistry_v1',
    RegistryKeyPrefix = 'player_',
    QueueCap = 200,
    SendIntervalSeconds = 1.2,
    MaxAttempts = 3,
    RetryBackoffSeconds = { 2, 8 },
    ShutdownFlushMax = 5,
    Events = { Join = true, Leave = true, TutorialCompleted = true,
               ArenaCompleted = true, RebirthSucceeded = true,
               PurchaseGranted = true },
    Colors = { Join = 3066993, Leave = 15158332, TutorialCompleted = 3447003,
               ArenaCompleted = 10181046, RebirthSucceeded = 15844367,
               PurchaseGranted = 5763719 },
}
```

The table is `table.freeze`d (shallow — the nested `Events`, `Colors`
and `RetryBackoffSeconds` tables are not frozen).

**`WebhookAttribute` holds the attribute NAME, not the URL.** The URL
is a secret and must never appear in source control.
