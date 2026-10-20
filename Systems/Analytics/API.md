# Analytics — API

Every public function of every module in this system. There is one
module: `ServerScriptService.FunnelService`.

All functions are **server-only**. Nothing here may be called from a
client script.

---

## `ServerScriptService.FunnelService`

```lua
local FunnelService = require(game:GetService('ServerScriptService').FunnelService)
```

The module table is frozen (`table.freeze`) — you cannot add fields
to it at runtime.

---

### `FunnelService:LogStep(player, funnelName, stepName, metadata?): boolean`

Record one funnel step for a player's current session.

**Kind:** method (the first declared parameter is `self`). Call with
`:` — `FunnelService:LogStep(...)`.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `self` | table | The `FunnelService` module. Supplied by `:`. |
| `player` | `Player` | The player the event belongs to. Read via `player.UserId` inside a `pcall`. |
| `funnelName` | `string` | Must be a key of `FunnelService.Funnels`. |
| `stepName` | `string` | Must be a name inside `FunnelService.Funnels[funnelName]`. |
| `metadata` | `{ [string]: any }?` | Optional. Diagnostic only — **never sent to Roblox**. Must contain `_key` (a non-empty string) for the step to be scoped. |

**Returns**

`true` when the event was **accepted** (dedupe passed and a send was
attempted, or the step was intentionally suppressed as a duplicate).
`false` when the event was **dropped**.

**Failure modes — never throws**

The whole body is inside one `pcall`, so nothing propagates. Drops:

| Condition | Return | Side effect |
|---|---|---|
| `_enabled == false` | `false` | none |
| `player` is not a Player / has no `UserId` | `false` | none |
| `funnelName` or `stepName` is not a string | `false` | none |
| Unknown funnel name | `false` | `Debug.Warn('FUNNEL', 'unknown funnel step; dropped', ...)` |
| Unknown step name in a known funnel | `false` | same warning |
| No session and `RegisterSession` returns `nil` | `false` | none |
| Duplicate `ONCE` step in the same session | `true` | **not sent** |
| Duplicate `SCOPED` step with the same `_key` | `true` | **not sent** |
| The analytics send fails or throws | `true` | `Debug.Warn('FUNNEL', 'send failed; gameplay unaffected', ...)` |

**Note:** `true` means "accepted and attempted", **not** "delivered".
A failed send still returns `true`.

**Example**

```lua
FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)

FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', {
    rebirth_number = 3,
    _key = '3',   -- one event per rebirth number per session
})
```

---

### `FunnelService.Start()`

Register a session for every player already in the server and hook
the player lifecycle.

**Kind:** server lifecycle. **Parameters:** none.
**Returns:** nothing.

**Behaviour**

- For each player in `Players:GetPlayers()`, call `RegisterSession`.
- Connect `Players.PlayerAdded` → `RegisterSession(player)`.
- Connect `Players.PlayerRemoving` → `ForgetPlayer(userId)`.

**Failure modes:** the whole body is inside a `pcall`; a failure to
hook is swallowed. Idempotent — a second call is a no-op
(`_started` guard).

**Ordering note:** `LogStep` auto-registers a missing session, so
`Start()` is optional. Calling it at boot is still preferable so the
session stamp is taken at join time.

---

### `FunnelService.RegisterSession(player): string?`

Start (or reuse) the analytics session for a player.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `player` | `Player` | Read via `player.UserId` inside a `pcall`. |

**Returns**

The session key `"<userId>:<joinStamp>"` where `joinStamp` is
`os.clock()` captured the first time this userId was seen, or `nil`
if the player has no numeric `UserId`.

**Failure modes:** returns `nil` for a non-player. Never throws.

**Note:** the stamp is `os.clock()`, not `os.time()`. It is
monotonic and per-server; it is **not** a wall clock and must not be
persisted or compared across servers.

---

### `FunnelService.GetSessionKey(userId): string?`

The current session key for a userId.

**Parameters:** `userId: number`.
**Returns:** `"<userId>:<joinStamp>"`, or `nil` when no session exists.
**Failure modes:** never throws. A non-number `userId` simply finds no
entry and returns `nil`.

---

### `FunnelService.ForgetPlayer(userId)`

End a player's analytics session and clear their dedupe keys.

**Parameters:** `userId: number`.
**Returns:** nothing.

**Behaviour**

- Deletes `_sessions[userId]`.
- Deletes every `_logged` key whose text starts with `"<userId>:"`.

**Failure modes:** a non-number `userId` returns early (no-op).
Never throws.

**Note:** this is what makes one-time milestones re-armable after a
rejoin. Call it on `PlayerRemoving`.

---

### `FunnelService.LevelBand(level): string`

Bucket a level into a coarse band for analytics metadata.

**Parameters:** `level: any` — coerced with `tonumber`.
**Returns:** one of `'1-10'`, `'11-25'`, `'26-50'`, `'51-100'`,
`'100+'`.

**Behaviour**

| Input | Result |
|---|---|
| `<= 10` | `'1-10'` |
| `<= 25` | `'11-25'` |
| `<= 50` | `'26-50'` |
| `<= 100` | `'51-100'` |
| `> 100` | `'100+'` |
| `nil` / non-numeric | `'1-10'` (`tonumber(level) or 0`) |

**Failure modes:** never throws; non-numeric input falls back to the
first band.

---

### `FunnelService.IsArenaMilestone(stage): boolean`

Whether an arena stage is worth a funnel event.

**Parameters:** `stage: any` — coerced with `tonumber`, then
`math.floor`.
**Returns:** `true` for stages 1, 5, 10, 25, 50; `false` otherwise.

**Failure modes:** never throws. `nil` or a non-numeric stage returns
`false`.

---

### `FunnelService.Funnels` (data)

The canonical funnel plan: `{ [funnelName: string]: { stepName: string } }`.

Read-only (`table.freeze` on the module does not deep-freeze this
table, but nothing in the codebase mutates it). The **1-based index**
of a step name inside its array is the Roblox funnel step number.

---

### `FunnelService.ONCE` / `FunnelService.SCOPED` (data)

Dedupe policy tables, keyed `"<funnelName>/<stepName>"`.

- `ONCE` — at most one event per session.
- `SCOPED` — at most one event per session per `metadata._key`.

---

## Test seams

These are public functions on the module, intended for specs only.
They are part of the module's surface because the shipped spec uses
them.

### `FunnelService._TestReset()`

Clears `_sessions`, `_logged`, `_calls`; clears `_sender`; sets
`_enabled = true`; sets `_started = false`.

**Parameters / Returns:** none.

---

### `FunnelService._TestSetSender(fn)`

Install a fake sender in place of `AnalyticsService`.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `fn` | `((player: Player, funnel: string, sessionId: string?, stepNumber: number, stepName: string) -> boolean)?` | The same shape the default sender uses. `nil` restores the default. |

**Returns:** nothing.

**Note:** `_sender` is a module-level singleton. Always pair this with
`_TestReset()` in `afterEach`.

---

### `FunnelService._TestSetEnabled(enabled: boolean)`

Turn the whole service into a no-op.

**Parameters:** `enabled: boolean` (coerced with `and true or false`).
**Returns:** nothing.

---

### `FunnelService._TestGetCalls(): { { [string]: any } }`

A copy of the recorded call log. Each entry is
`{ UserId, Session, Funnel, Step, StepNumber, Metadata }`.

**Returns:** an array (a copy — mutating it does not affect the
module).

---

### `FunnelService._TestWasLogged(userId: number, funnel: string, step: string): boolean`

Whether a matching call was recorded.

**Parameters:** `userId: number`, `funnel: string`, `step: string`.
**Returns:** `true` if any recorded call matches all three, else
`false`. Never throws.
