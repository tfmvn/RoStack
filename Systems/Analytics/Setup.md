# Analytics — Setup

Installing `FunnelService` into a new Rojo project.

---

## 1. Copy the files

| From the library | To in your Rojo project | Roblox path |
|---|---|---|
| `Source/ServerScriptService/FunnelService.lua` | `src/ServerScriptService/FunnelService.lua` | `ServerScriptService.FunnelService` |

One file. There is no client half.

Your `default.project.json` needs the ordinary server mapping:

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$path": "src/ServerScriptService"
    },
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage"
    }
  }
}
```

---

## 2. Install the third-party packages

`FunnelService` itself needs **no** Wally packages. It only uses
Roblox services (`Players`, `AnalyticsService`).

The one thing you must have is the shared `Debug` utility, because
`FunnelService` requires it at module load:

```toml
# wally.toml
[dependencies]
# ...your game's dependencies
```

`ReusableSystems/Shared/Utilities/Debug.lua` is the canonical
implementation. Copy it to
`src/ReplicatedStorage/Utility/Debug.lua` → `ReplicatedStorage.Utility.Debug`.

`Debug` itself requires only `RunService`. It also expects a
`ReplicatedStorage.Config.Systems.Debug` module to sync from (see
step 3).

---

## 3. Provide the Debug config

`Debug.SyncFromDebugConfig(debugConfig)` is called by your bootstrap.
The minimum viable `ReplicatedStorage.Config.Systems.Debug` module:

```lua
local DebugConfig = {}
DebugConfig.ServerDebug = false
DebugConfig.ClientDebug = false
DebugConfig.Tags = {}
return table.freeze(DebugConfig)
```

Without a sync call, `Debug.Log` / `Debug.Warn` stay silent — which
is the intended default, but it means funnel traces will not appear
in the console until you flip `ServerDebug = true`.

---

## 4. Tune the config

Open `Config.lua` in this folder for a commented copy of every
tunable. The two you will definitely want to change:

- **`AnalyticsConfig.Funnels`** — replace the whole table with your
  own funnel plan. The array order *is* the step number.
- **`AnalyticsConfig.ONCE` / `SCOPED`** — must match your step names
  exactly, or the dedupe will silently not apply.

To apply changes, edit the literals in
`ServerScriptService/FunnelService.lua` (the module does not require
`Config.lua`). Alternatively, change the `require` inside
`FunnelService.lua` to point at your own config module and replace
the table literals with reads from it.

---

## 5. Bootstrap

In your server bootstrap, call `Start()` once:

```lua
local FunnelService = require(game:GetService('ServerScriptService').FunnelService)

-- in your boot sequence, after Debug.SyncFromDebugConfig(...)
FunnelService.Start()
```

Order matters only in that `Start()` should come after the `Debug`
sync (so funnel traces are visible) and after
`Players.PlayerAdded` handlers are set up elsewhere. `Start()` is
idempotent.

Then call `LogStep` from your gameplay commit paths — **after** the
authoritative commit, never before:

```lua
-- inside a purchase handler, AFTER the debit and the profile write
pcall(function()
    local FunnelService = require(script.Parent.FunnelService)
    FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)
end)
```

Note the **colon** syntax. `FunnelService.LogStep(player, ...)` (dot)
passes the player as `self` and silently produces garbage.

For a scoped step, pass `_key`:

```lua
FunnelService:LogStep(player, 'Rebirth', 'RebirthSucceeded', {
    rebirth_number = 3,
    _key = '3',            -- one event per rebirth number per session
})
```

---

## 6. Author the Studio assets

**None required.** `FunnelService` reads no Workspace hierarchy and
no ServerStorage folder.

The one thing you must do **outside** the game is the dashboard:

1. Open the Creator Hub → your experience → **Analytics → Funnels**.
2. Create one funnel per key in `AnalyticsConfig.Funnels`.
3. Add the steps **in exactly the array order**, with the exact
   names.
4. Do the same for the `Onboarding` funnel — Roblox treats it as a
   special "onboarding" funnel, so create it as the onboarding
   funnel, not a custom one, if the Hub offers that option.

If the dashboard does not match, the events still fire safely (the
send is `pcall`-guarded) but they will not attribute to a funnel.

---

## 7. Smoke test

1. **Start the server.** No errors in the Output window.
2. **Flip `Debug.ServerDebug = true`** in
   `ReplicatedStorage.Config.Systems.Debug` and restart.
3. **Join.** You should see `[FUNNEL]` lines only when a step fires —
   `Start()` itself logs nothing.
4. **Trigger a step.** E.g. run a purchase path that calls
   `LogStep`. Expect:
   ```text
   [FUNNEL] step user=<userId> funnel=Onboarding step=FirstEggPurchased n=2
   ```
   The `n=` value is the **positional step number** — check it against
   your `FunnelConfig.Funnels` array index.
5. **Check dedupe.** Fire the same `ONCE` step twice. Expect exactly
   **one** `[FUNNEL] step` line (the second call is dropped, so no
   second line appears).
6. **Check the session reset.** Leave and rejoin, then fire the same
   `ONCE` step again. Expect a second line — dedupe is per session,
   not per account.
7. **Check the failure path.** Temporarily rename the funnel in the
   config so `_stepNumber` returns `nil` and call `LogStep`. Expect
   `[FUNNEL] WARN unknown funnel step; dropped` and a `false` return
   — and, critically, **no error and no interruption** of the
   gameplay path that called it.
8. **Check the dashboard.** After a live session, open the Hub's
   funnel report and confirm the events landed on the right step
   numbers.

---

## 8. Optional: use the shipped spec

`Tests/FunnelService.spec.lua` is a TestEZ spec. It stubs the sender
via `_TestSetSender`, so it never calls `AnalyticsService`.

To run it, copy it into your test tree (for example
`src/Tests/ServerScriptService/TestEZTests/FunnelService.spec.lua`),
make sure `ReplicatedStorage.Utility.Debug` and your `Debug` config
exist, and run the TestEZ runner. See
`ReusableSystems/Tests/README.md` for the harness conventions.
