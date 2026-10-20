# Analytics Providers

**Status: one provider, no abstraction. The source game calls Roblox
`AnalyticsService` directly.**

---

## 1. What exists

| Piece | Where | In this library? |
|---|---|---|
| `FunnelService` | `src/ServerScriptService/FunnelService.lua` | **Yes** — `Systems/Analytics/` |
| Roblox `AnalyticsService` | a Roblox platform service | Platform — not copied |

**There is no provider interface.** `FunnelService` calls
`AnalyticsService` directly, and a second provider (GameAnalytics, PlayFab,
Heap, etc.) would require editing `FunnelService` or writing an adapter.

---

## 2. The funnel model

### 2.1 A funnel is an ordered list of steps

```lua
FunnelService.Funnels = {
  Onboarding = {
    'TutorialStarted', 'FirstEggPurchased', 'FirstEggHatched',
    'FirstAnimalPlaced', 'FirstArenaStarted', 'FirstArenaCompleted',
    'TutorialCompleted', 'TutorialSkipped',
  },
  -- 10 more
}
```

**Step number is positional** — step N is the index of the step name in the
list. Roblox's telemetry dashboard keys on `(funnelName, stepNumber)`, so
**reordering a funnel changes what your dashboard shows**. Treat the lists
as a schema, not as a convenience.

The 11 funnels: `Onboarding` (8), `Progression` (3), `Upgrade` (2),
`Rebirth` (3), `Arena` (3), `Monetization` (3), `GalaxyBat` (4), `Gear` (2),
`Gamepass` (2), `Event` (2), `Rewards` (3), `Social` (2).

### 2.2 Logging a step

```lua
FunnelService:LogStep(player, 'Onboarding', 'FirstEggHatched')
```

**Note the colon** — `LogStep` is a method; the rest are plain functions.

Returns `true` if the event was sent, `false` if it was dropped.

### 2.3 The two endpoints

```lua
-- Onboarding has a dedicated endpoint:
AnalyticsService:LogOnboardingFunnelStepEvent(player, stepNumber, stepName)

-- everything else:
AnalyticsService:LogFunnelStepEvent(player, funnel, sessionId, stepNumber, stepName)
```

### 2.4 The session id

```lua
FunnelService.RegisterSession(player)  -- → tostring(userId) .. ':' .. tostring(os.clock())
FunnelService.GetSessionKey(userId)
FunnelService.ForgetPlayer(userId)    -- clears the session and every _logged key
```

**Sessions are memory-only.** There is no DataStore persistence. A session
ends when the player leaves.

---

## 3. Dedupe

Two modes, and the difference matters:

| Mode | Behaviour | Used by |
|---|---|---|
| `ONCE` | At most once per session, per step. | 16 step keys |
| `SCOPED` | At most once per session, **per `metadata._key`**. | 10 step keys |

A `SCOPED` step without a `_key` logs **every time**. The callers are
expected to pass one:

```lua
FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', { _key = tostring(rebirthCount) })
FunnelService:LogStep(player, 'Arena', 'StageProgressed', { _key = tostring(stage) })
FunnelService:LogStep(player, 'Monetization', 'PurchaseConfirmed', { _key = tostring(purchaseId) })
```

This is benign — it over-counts, it does not corrupt anything — but it will
make your dashboard look wrong.

---

## 4. What the metadata may contain

> **Keep payloads tiny.** Product keys, level bands, milestone numbers.
>
> **Never positions, inventories, or PII.**

The funnel API carries no custom fields — `metadata` is diagnostic only.

`FunnelService.LevelBand(level)` gives you the safe bands the source game
uses: `'1-10'`, `'11-25'`, `'26-50'`, `'51-100'`, `'100+'`.
`FunnelService.IsArenaMilestone(stage)` is true only for stages 1, 5, 10,
25, 50.

---

## 5. Failure behaviour

**Analytics is never gameplay-critical.** Every call site is `pcall`-guarded
and fires *after* the authoritative commit. A failure logs a diagnostic and
gameplay continues. There are **no retries and no rollbacks**.

An unknown funnel or step is dropped with
`Debug.Warn('FUNNEL', 'unknown funnel step; dropped', …)`.

This is the right design: a telemetry outage must never cost a player a
purchase.

---

## 6. Adding a second provider

You need an adapter. The contract `FunnelService` actually uses is small:

```lua
provider:LogOnboardingFunnelStepEvent(player, stepNumber, stepName)
provider:LogFunnelStepEvent(player, funnel, sessionId, stepNumber, stepName)
```

The cleanest way to add one without rewriting `FunnelService` is to
intercept at the `AnalyticsService` boundary. The source game does not do
this — it has a single provider — so an adapter is your own work.

**What you must preserve:**

- The `(funnelName, stepNumber)` contract. If a second provider has a
  different shape, translate at the adapter, not at the call sites.
- The `pcall` guard and the "never gameplay-critical" property.
- The dedupe semantics (`ONCE` / `SCOPED`).
- The "no PII" rule.

---

## 7. The dashboard requirement

> One Roblox dashboard funnel per `FunnelService.Funnels` key, with steps
> in the listed order and the **exact step names**.

Events still fire safely with no dashboard configured — the `pcall` swallows
the error. But you will see nothing, and it will look like the code is
broken.

---

## 8. Checklist for a new game

- [ ] `Systems/Analytics/Source/` copied → `ServerScriptService/FunnelService.lua`.
- [ ] `FunnelService.Start()` called in the bootstrap, after
      `PlayerService` is available.
- [ ] The funnel catalog rewritten for your game — or kept as a starting
      point.
- [ ] A Roblox dashboard funnel created per catalog key, with the steps in
      the same order and the same names.
- [ ] The `SCOPED` call sites pass a `_key`.
- [ ] No PII in the metadata.
