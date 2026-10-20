# Analytics

The one centralized server-side funnel-analytics layer. Every gameplay
service reports player-journey milestones here; this module is the
only place in the game that touches Roblox `AnalyticsService`.

**Portability:** Grade A core (the funnel plan, dedupe policy, session
model) + Grade B (the funnel names and step names are Brainrot
Arena's product vocabulary). See *Portability* below.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

`FunnelService` records Roblox **funnel events** for a player's
current session. It is deliberately the thinnest possible analytics
layer:

- **It never blocks gameplay.** Every call is `pcall`-guarded, never
  yields, and returns a boolean. A failed analytics send logs one
  warning and gameplay continues.
- **It never persists.** Session ids are memory-only (`userId` +
  a join-time `os.clock()` stamp). A session ends when the player
  leaves. There is no DataStore involvement.
- **It invents no remotes and no gameplay systems.** Callers invoke
  `LogStep` *after* their own authoritative commit and continue.
- **Step numbering is positional.** The index of a step name inside
  `FunnelService.Funnels[funnel]` *is* the funnel step number.
  Roblox keys funnel telemetry on `(funnelName, stepNumber)`, so the
  order of the arrays below is load-bearing — a dashboard built with
  a different order will not attribute the events.

Two dedupe policies are applied per session:

| Policy | Table | Behaviour |
|---|---|---|
| `ONCE` | `FunnelService.ONCE` | The step fires at most once per session, per (funnel, step). Repeat calls are dropped (but still return `true`). |
| `SCOPED` | `FunnelService.SCOPED` | The step fires at most once per session **per `metadata._key`**. Callers MUST pass `_key` (e.g. the rebirth number) or the step fires every time. |

Everything else (`Arena/ArenaStarted`, `Rewards/CodeRedeemed`,
`Event/EventParticipated` is scoped, etc.) fires on every call.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `FunnelService:LogStep(player, funnelName, stepName, metadata?)` | Server | The only call gameplay code needs. Method syntax (`:`) — the first parameter is `self`. Returns `true` when the event was accepted, `false` when dropped. |
| `FunnelService.Start()` | Server | Registers sessions for current players and subscribes to `PlayerAdded` / `PlayerRemoving`. Idempotent. |
| `FunnelService.RegisterSession(player): string?` | Server | Starts (or reuses) a session for the player. Returns `"<userId>:<stamp>"`, or `nil` if the player has no `UserId`. |
| `FunnelService.GetSessionKey(userId): string?` | Server | The current session key for a userId, or `nil`. |
| `FunnelService.ForgetPlayer(userId)` | Server | Ends the session and clears that player's dedupe keys. |
| `FunnelService.LevelBand(level): string` | Server | Pure bucketing helper: `'1-10'`, `'11-25'`, `'26-50'`, `'51-100'`, `'100+'`. |
| `FunnelService.IsArenaMilestone(stage): boolean` | Server | Pure helper: `true` only for arena stages 1, 5, 10, 25, 50. |
| `FunnelService.Funnels` | Server (data) | The canonical funnel plan. Read-only. |
| `FunnelService._TestReset()` | Test seam | Clears sessions, dedupe keys, recorded calls, the sender, and re-enables the service. |
| `FunnelService._TestSetSender(fn)` | Test seam | Installs a fake sender in place of `AnalyticsService`. |
| `FunnelService._TestSetEnabled(enabled)` | Test seam | Turns the whole service into a no-op. |
| `FunnelService._TestGetCalls()` | Test seam | The recorded call log (capped at 1000 entries). |
| `FunnelService._TestWasLogged(userId, funnel, step)` | Test seam | Whether a call was recorded. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/FunnelService.lua` | `ServerScriptService.FunnelService` | The whole analytics layer. One file. |

There is no client half. The service is server-only by design; the
Roblox `AnalyticsService` funnel endpoints are server-authoritative.

---

## Configuration

There is **no config module of its own**. Every tunable is a literal
inside `FunnelService.lua`:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `FunnelService.Funnels` | `FunnelService.lua:69-131` | 12 funnels | The canonical step plan. The array **index is the step number**. |
| `FunnelService.ONCE` | `FunnelService.lua:135-152` | 16 entries | One-time-per-session milestones. |
| `FunnelService.SCOPED` | `FunnelService.lua:160-171` | 10 entries | One-time-per-session-per-`_key` milestones. |
| `ARENA_MILESTONES` | `FunnelService.lua:175-181` | `{1,5,10,25,50}` | Arena stages worth a funnel event. |
| `_CALLS_CAP` | `FunnelService.lua:190` | `1000` | The in-memory call log is capped. Older entries are dropped silently. |
| `_enabled` | `FunnelService.lua:185` | `true` | Master switch. Flipped only by `_TestSetEnabled`. |

See `Config.lua` for a consolidated, commented copy of these
tunables.

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ReplicatedStorage.Utility.Debug` — the only require. `FunnelService`
  is a **leaf**: it cannot form a require cycle.
- Roblox `AnalyticsService` — obtained lazily via
  `game:GetService('AnalyticsService')` inside `_defaultSend`, inside
  a `pcall`. It is never captured at module load.
- Roblox `Players` — for `GetPlayers`, `PlayerAdded`,
  `PlayerRemoving`.

Other systems that call into this one: `Tutorials` (onboarding funnel
steps), plus `Arena`, `Rebirth`, `Upgrades`, `Economy`,
`ShopsAndPurchases`, `CodesAndRewards`, `Events`, `Inventory`,
`Items`, `Collectors`, `Stealing`, `BasesAndSlots`, `Animals`,
`EggsAndHatching`, `ClientPresentation`, `PlayerData`,
`SharedUtilities`.

---

## Initialization Order

`FunnelService` is a leaf and has no ordering requirement of its own,
but the *session* must exist before the first `LogStep` for a player.
`LogStep` auto-registers a session if none exists, so the service is
safe to use before `Start()`.

```text
1. FunnelService.Start()            -- optional; auto-registers on demand
2. On PlayerAdded:  FunnelService.RegisterSession(player)  -- automatic
3. On PlayerRemoving: FunnelService.ForgetPlayer(userId)  -- automatic
4. Gameplay commit → FunnelService:LogStep(player, funnel, step, meta)
```

The `PlayerRemoving` → `ForgetPlayer` step is what bounds memory: the
session stamp and every dedupe key for that userId are dropped.

---

## Data

**None persisted.** `FunnelService` writes no DataStore and reads no
profile field.

In-memory state:

| Table | Key | Value | Lifetime |
|---|---|---|---|
| `_sessions` | `userId` | `os.clock()` join stamp | Until `ForgetPlayer`. |
| `_logged` | `"<sessionKey>|<funnel>/<step>"` or `"<sessionKey>|<funnel>/<step>/<scopeKey>"` | `true` | Until `ForgetPlayer` (prefix match on `"<userId>:"`). |
| `_calls` | array index | `{UserId, Session, Funnel, Step, StepNumber, Metadata}` | Capped at 1000; never trimmed, just stops recording. |

The session key format is `"<userId>:<joinStamp>"` where `joinStamp`
is `os.clock()` at first registration — **not** `os.time()`. It is a
monotonic, per-server value, not a wall clock.

---

## Known Limitations

- **Dashboard setup is manual and exact.** A funnel event only
  attributes in the Creator Hub if a funnel with the **same name and
  the same step order** exists in the dashboard. The code comments
  (`FunnelService.lua:48-52`) say so explicitly. The API calls are
  still `pcall`-guarded and safe when no dashboard exists.
- **The `Onboarding` funnel uses a different endpoint.**
  `LogOnboardingFunnelStepEvent(player, step, stepName)` takes no
  funnel name and no session id, so an `Onboarding` step is *not*
  session-scoped on Roblox's side even though this module dedupes it
  per session.
- **`_calls` grows to 1000 and then stops recording.** It is a
  diagnostic buffer, not a log.
- **Dedupe is per session, not per account.** A player who rejoins
  gets a fresh session and can re-fire every `ONCE` milestone. This
  is deliberate (no DataStore writes) but means "first ever" is not
  measurable here.
- **`SCOPED` steps silently fire every time when the caller forgets
  `_key`.** There is no warning for a missing `_key`.
- **`LogStep` is method-syntax.** `FunnelService.LogStep(player, ...)`
  (dot) would pass `player` as `self` and break. Every call site in
  the codebase uses `:`.
- **No error surface for the caller.** `LogStep` returns `true` even
  when the underlying analytics send failed — the failure is a
  `Debug.Warn('FUNNEL', ...)`, not a return value. `true` means "the
  event was accepted and attempted", not "it reached Roblox".

---

## Testing

`Tests/FunnelService.spec.lua` — 13 cases covering the positional
step number, the Rebirth fire order, analytics failure and a throwing
sender never propagating into gameplay, one-time suppression, repeat
steps, player isolation, session isolation via `ForgetPlayer`, `_key`
scoping, invalid player / unknown funnel / unknown step, the disabled
no-op path, level banding, and arena milestone filtering.

The spec stubs the sender via `_TestSetSender`, so **no
`AnalyticsService` call is made in tests**. It still requires Roblox
Studio (TestEZ). See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Rewrite `FunnelService.Funnels`.** The array order *is* the step
   number. Build the Creator Hub dashboard to match exactly, or the
   events will not attribute.
2. **Keep `LogStep` called after the authoritative commit**, not
   before. A funnel step that fires for a rolled-back action is a
   lie.
3. **Pass `metadata._key`** for every `SCOPED` step, or move that step
   to `ONCE` / remove it from `SCOPED`.
4. **Keep the leaf property.** `FunnelService` must require only
   `Debug`. If you add a require of a gameplay service, you have
   created a cycle.
5. **Prefer `FunnelService.LevelBand` / `IsArenaMilestone`** over
   raw values, so metadata cardinality stays bounded.
6. **Keep metadata tiny.** The funnel API carries no custom fields;
   metadata here is diagnostic-only (a `Debug` line and the test
   log). Never put positions, inventories, or PII in it.
7. **Call `Start()` once at boot** so sessions are registered on join
   rather than lazily on the first event.
