# Analytics — engineering notes

## Purpose

One-line: the single server-side wrapper over Roblox `AnalyticsService`
funnel events, with a per-session dedupe policy, that can never break
gameplay.

## How it actually works

1. `FunnelService:LogStep(player, funnelName, stepName, metadata)` is
   the only public entry point. It is a **method** — the first declared
   parameter is `self` (= the module table), so `player` is the second
   positional argument. Call it as `FunnelService:LogStep(p, 'Rebirth',
   'RebirthSucceeded', { _key = '3' })`.
2. Inside a single `pcall`:
   - `_enabled` false → return `false` immediately, no send, no
     recorded call.
   - `_userIdOf(player)` → `nil` for a non-player → return `false`.
   - `funnelName` / `stepName` must both be strings → else `false`.
   - `_stepNumber(funnelName, stepName)` looks the step name up in
     `FunnelService.Funnels[funnelName]` and returns its **1-based
     index**. This index is the Roblox funnel step number. Unknown
     funnel or unknown step → `Debug.Warn('FUNNEL', 'unknown funnel
     step; dropped', ...)` and return `false`.
   - Session key: `GetSessionKey(userId)`, or `RegisterSession(player)`
     if absent. If that is still `nil` → return `false`.
   - Dedupe key selection:
     - base = `"<funnelName>/<stepName>"`.
     - if `ONCE[base]` → key = `"<sessionKey>|<base>"`.
     - elseif `SCOPED[base]` **and** `metadata._key` is a non-empty
       string → key = `"<sessionKey>|<base>/<metadata._key>"`.
     - else → `nil` (no dedupe; fires every time).
   - If a dedupe key exists and is already `true` → set `ok = true` and
     return **without sending**. (The call is still counted as
     accepted.)
   - If a dedupe key exists, set it to `true` **before** the send.
   - Record the call in `_calls` if `#_calls < 1000`.
   - `Debug.Log('FUNNEL', 'step', ...)`.
   - Send: `pcall(sender, player, funnelName, sessionKey, stepNumber,
     stepName)` where `sender` is `_sender` (test seam) or
     `_defaultSend`. A `false` return or a non-`true` second pcall
     result logs `Debug.Warn('FUNNEL', 'send failed; gameplay
     unaffected', ...)`.
   - `ok = true`.
3. `_defaultSend` resolves `AnalyticsService` **lazily** via
   `pcall(game.GetService, game, 'AnalyticsService')`. If the funnel is
   `Onboarding` it calls
   `svc:LogOnboardingFunnelStepEvent(player, stepNumber, stepName)`;
   otherwise
   `svc:LogFunnelStepEvent(player, funnel, sessionId, stepNumber, stepName)`.
   That argument order is the documented Roblox order — do not
   reorder.
4. `Start()` registers a session for every current player and hooks
   `PlayerAdded` → `RegisterSession` and `PlayerRemoving` →
   `ForgetPlayer`. `ForgetPlayer` clears `_sessions[userId]` and every
   `_logged` key with the prefix `"<userId>:"`.

## Public API surface

```lua
FunnelService.Funnels: { [string]: { string } }          -- data
FunnelService:LogStep(player: Player, funnelName: string, stepName: string,
                       metadata: { [string]: any }?): boolean
FunnelService.Start()
FunnelService.RegisterSession(player: Player): string?
FunnelService.GetSessionKey(userId: number): string?
FunnelService.ForgetPlayer(userId: number)
FunnelService.LevelBand(level: any): string
FunnelService.IsArenaMilestone(stage: any): boolean
FunnelService._TestReset()
FunnelService._TestSetSender(fn: ((player: Player, funnel: string,
                       sessionId: string?, stepNumber: number,
                       stepName: string) -> boolean)?)
FunnelService._TestSetEnabled(enabled: boolean)
FunnelService._TestGetCalls(): { { [string]: any } }
FunnelService._TestWasLogged(userId: number, funnel: string, step: string): boolean
```

## Invariants the code enforces

- **The array index is the step number.** Reordering
  `FunnelService.Funnels` renumbers every event in the dashboard.
  Adding a step in the middle shifts every later step in that funnel.
- **The module is a leaf.** It requires exactly one thing:
  `ReplicatedStorage.Utility.Debug`. No gameplay service may be
  required from here, or a require cycle forms.
- **Nothing persists.** No DataStore, no profile read, no write.
- **Nothing yields.** `LogStep` never calls `task.wait`. The whole
  body is synchronous inside one `pcall`.
- **Nothing throws.** Every failure path is a `pcall` + `return false`
  or a `Debug.Warn`.
- **`LogStep` returns `true` even when the send failed.** The return
  value means "accepted and attempted", not "delivered".
- **Deduping is per session, not per account.** `ForgetPlayer` is the
  only thing that clears it.
- **`_key` is the only scope key.** It is read from `metadata._key`
  and must be a non-empty string.

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| `_enabled == false` | `false`, no send, no recorded call. |
| `player` is `nil` / not a Player | `false`. |
| `funnelName` or `stepName` not a string | `false`. |
| Unknown funnel name | `false` + `Debug.Warn('FUNNEL', 'unknown funnel step; dropped')`. |
| Unknown step name in a known funnel | Same as above. |
| No session and `RegisterSession` fails | `false`. |
| Duplicate `ONCE` step in the same session | `true`, **not sent**. |
| Duplicate `SCOPED` step with the same `_key` | `true`, **not sent**. |
| `SCOPED` step with no `_key` | Sends **every** time (no dedupe). |
| Sender returns `false` | `true` returned, `Debug.Warn('FUNNEL', 'send failed; gameplay unaffected')`. |
| Sender throws | `true` returned, same warning. The pcall swallows the error. |
| `AnalyticsService` unavailable | `_defaultSend` returns `false` → warning, `true` returned. |
| `_calls` already at 1000 | The call is **not** recorded, but it is still sent and still deduped. |
| `LevelBand(nil)` | `'1-10'` (`tonumber(nil) or 0`). |
| `LevelBand(150)` | `'100+'`. |
| `IsArenaMilestone(nil)` | `false`. |
| `IsArenaMilestone(2)` | `false` — only 1, 5, 10, 25, 50. |
| `IsArenaMilestone(5.7)` | `true` — `math.floor` is applied. |
| `ForgetPlayer` with a non-number | No-op (returns early). |

## Gotchas that would bite you

- **Dot vs colon.** `FunnelService.LogStep(player, ...)` passes the
  player as `self` and silently logs garbage. Always `:`.
- **`Onboarding` is a special endpoint.** Roblox's
  `LogOnboardingFunnelStepEvent` takes no funnel name and no session
  id. Do not "unify" it with the other funnels.
- **The `ONCE` / `SCOPED` tables are keyed `"<funnel>/<step>"`, not
  `"<step>"`.** A step name that appears in two funnels has two
  independent dedupe entries.
- **A `SCOPED` step that fires without `_key` looks like a bug but is
  not** — it is a documented "noisier but safe" fallback. There is no
  warning for it.
- **`_logged` keys are cleared by string prefix** `"<userId>:"`.
  `ForgetPlayer` will therefore also clear any other key that happens
  to start with those characters. Nothing else writes `_logged`.
- **The session stamp is `os.clock()`, not `os.time()`.** It is
  monotonic and per-server; two different servers give the same
  userId two different stamps. Do not treat it as a timestamp.
- **`_sender` is a module-level singleton.** Setting it in one spec
  affects every other spec until `_TestReset()` runs.
- **`Debug.Log` is silent by default** (`Debug.ServerDebug = false`).
  If you are looking for funnel traces and see nothing, that is the
  switch, not a bug.
- **`metadata` is NOT sent to Roblox.** The funnel API has no custom
  fields. Metadata only reaches the `Debug` line and `_calls`.

## What to change to reuse it

1. Replace `FunnelService.Funnels` with your own funnel plan, in
   dashboard order.
2. Rebuild `ONCE` and `SCOPED` to match your step names.
3. Replace `ARENA_MILESTONES` (or delete it and drop
   `IsArenaMilestone`).
4. Keep the leaf property (only `Debug` required).
5. Optionally raise `_CALLS_CAP` if you want a longer diagnostic
   window; it is a diagnostic buffer only.
6. Call `Start()` at boot. Leave `LogStep` alone — its contract
   (never throws, never yields, returns a boolean) is what makes it
   safe to call from every commit path.
