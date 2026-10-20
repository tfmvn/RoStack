# PlayerLogging — Setup

Installing the player-monitoring system into a new Rojo project.

---

## 1. Copy the files

| From the library | To in your Rojo project | Roblox path |
|---|---|---|
| `Source/ServerScriptService/PlayerLogger/PlayerLogger.lua` | `src/ServerScriptService/PlayerLogger/PlayerLogger.lua` | `ServerScriptService.PlayerLogger.PlayerLogger` |
| `Source/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` | `src/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` | `ServerScriptService.PlayerLogger.PlayerLoggerConfig` |
| `Source/ServerScriptService/PlayerLogger/PlayerRegistry.lua` | `src/ServerScriptService/PlayerLogger/PlayerRegistry.lua` | `ServerScriptService.PlayerLogger.PlayerRegistry` |

Three files. There is no client half — this system sends nothing to
players.

Your `default.project.json` needs the ordinary mappings:

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

The `require` paths are `script.Parent.*` for the sibling modules and
`script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug` for the
shared utility — so the three modules must sit together in
`ServerScriptService/PlayerLogger/`.

---

## 2. Install the shared utility

Copy `ReusableSystems/Shared/Utilities/Debug.lua` to
`src/ReplicatedStorage/Utility/Debug.lua` →
`ReplicatedStorage.Utility.Debug`.

Both modules require it unconditionally, so without it they fail to
load.

**No Wally packages are needed** for this system.

---

## 3. Provide the Debug config

`Debug.SyncFromDebugConfig(debugConfig)` is called by your bootstrap.
The minimum viable `ReplicatedStorage.Config.Systems.Debug`:

```lua
local DebugConfig = {}
DebugConfig.ServerDebug = false
DebugConfig.ClientDebug = false
DebugConfig.Tags = {}
return table.freeze(DebugConfig)
```

Without the sync, the `[PLOG]` and `[REGISTRY]` diagnostics stay
silent — which is the intended default, but it means you will not see
the "webhook disabled" warning until you flip `ServerDebug = true`.

---

## 4. Tune the config

Open `Config.lua` in this folder for a commented copy of every
tunable. The real file is
`ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` — the
modules read **that**, not `Config.lua`.

Things you will want to change:

| Field | Change it to |
|---|---|
| `RegistryStoreName` | Your own project prefix, e.g. `'mygame_PlayerRegistry_v1'`. The shipped `'p7_'` prefix is Brainrot Arena's project id. Changing it orphans existing entries. |
| `RegistryKeyPrefix` | Usually stays `'player_'`. |
| `SendIntervalSeconds` | `2.0` if you want to stay under Discord's ~30 posts/minute. The shipped `1.2` is ~50/min and will hit 429s. |
| `Events.*` | Turn off the kinds you do not use. An unlisted kind is **silently dropped** by `LogMilestone`. |
| `Colors.*` | Your palette. |

---

## 5. Configure the webhook — SECRET

**Never put the webhook URL in a script, a config file, or version
control.** The URL contains a bot token: anyone with it can post to
your channel, and a leaked token is a channel compromise.

The supported way is a **Studio place-file attribute**:

1. Open the place in Studio.
2. Select the `ServerScriptService` instance in the Explorer.
3. In the **Properties** panel → **Attributes** → add:
   - Name: `PlayerLoggerWebhookUrl`
   - Type: `String`
   - Value: `https://discord.com/api/webhooks/<webhook_id>/<webhook_token>`
4. Save the place.

Rojo does **not** manage attributes, so the attribute lives in the
`.rbxl`/`.rbxlx` place file — which is exactly why it must not be
committed alongside source unless your repo ignores the place file.

To create the webhook: Discord → Server Settings → Integrations →
Webhooks → New Webhook → copy the URL.

To read the attribute name from the config:

```lua
PlayerLoggerConfig.WebhookAttribute  -- 'PlayerLoggerWebhookUrl'
```

The code validates the value against
`^https://discord%.com/api/webhooks/`; anything else is treated as
absent.

**Alternative (not recommended):** set the attribute at runtime before
`Init()`:

```lua
game:GetService('ServerScriptService'):SetAttribute(
    'PlayerLoggerWebhookUrl',
    mySecurelyLoadedUrl
)
```

`mySecurelyLoadedUrl` must come from somewhere that is not source
control (a secrets service, an environment-driven module you keep
outside the repo, etc.).

> **Note on the source game.** The original Brainrot Arena build shipped
> a live webhook URL as a literal in `PlayerLoggerConfig.WebhookAttribute`,
> immediately under a comment saying the URL belonged in Studio. The
> library copy has been sanitised — the field now holds the attribute
> **name**, which is what the consuming code actually reads. If you are
> porting from the original, delete the URL and set the attribute in
> the place file instead.

---

## 6. Enable HTTP requests

In the **live experience**: Game Settings → Security →
**Allow HTTP Requests** → on.

("Enable Studio Access to API" is a different toggle and is not
enough.) In Studio, HTTP is available to published games only; a
published-but-unpublished local server will report
`HttpEnabled == false` and the logger will degrade to registry-only
mode with one warning.

---

## 7. Bootstrap

```lua
local ServerScriptService = game:GetService('ServerScriptService')
local Players = game:GetService('Players')

local PlayerLogger = require(ServerScriptService.PlayerLogger.PlayerLogger)

-- after PlayerService.Init()
PlayerLogger.Init()

Players.PlayerAdded:Connect(function(player)
    -- ... your own join pipeline ...
    PlayerLogger.NotifyJoin(player)   -- call at the TAIL of the join pipeline
end)

Players.PlayerRemoving:Connect(function(player)
    PlayerLogger.NotifyLeave(player)
end)
```

`PlayerLogger.Init()` must run **before** the first `NotifyJoin`, and
**after** the webhook attribute is set.

`NotifyJoin` is intended to be called at the **tail** of your join
pipeline — it does a registry read/write and may yield for up to 2 s
waiting for `PlayerService` (inside a `task.spawn`, so it does not
block the pipeline).

For milestones, call from the owning service **after** the
authoritative commit:

```lua
pcall(function()
    PlayerLogger.LogMilestone(player, 'RebirthSucceeded', { rebirth = 3 })
end)
```

The kinds you can use are exactly the keys of
`PlayerLoggerConfig.Events`:
`TutorialCompleted`, `ArenaCompleted`, `RebirthSucceeded`,
`PurchaseGranted` (plus `Join`/`Leave` for the lifecycle events).
Anything else is **silently ignored**.

---

## 8. Configure the snapshot source (optional)

`_progressSnapshot` reads four fields through
`PlayerService.GetPlayerData(userId)`:

```lua
data.Rebirth
data.Arena.Level
data.Arena.Wins
data.Tutorial.Completed
```

If your profile is shaped differently, edit `_progressSnapshot` in
`PlayerLogger.lua`. While you are there, consider making the default
distinguishable from a real zero — the shipped defaults
(`rebirths = 0, arenaLevel = 1, arenaWins = 0,
tutorialCompleted = false`) are reported as if they were facts when
the profile cannot be read.

---

## 9. Author the Studio assets

**None.** No `Workspace` or `ServerStorage` hierarchy is used.

The only Studio-side item is the `ServerScriptService` attribute from
step 5.

---

## 10. Smoke test

1. **Start the server.** No errors in the Output window.
2. **Flip `DebugConfig.ServerDebug = true`** in
   `ReplicatedStorage.Config.Systems.Debug` and restart.
3. **With no webhook attribute set**, you should see exactly one
   diagnostic on boot:
   ```text
   [PLOG] WARN webhook disabled (missing URL attribute or HTTP off); registry-only mode
   ```
   and then nothing more. The game must run normally.
4. **Set the attribute** in the place file, restart, and confirm the
   boot line changes to:
   ```text
   [PLOG] player logger ready (webhook configured)
   ```
   If it still says "webhook disabled", either the attribute name is
   wrong, the value does not match the Discord URL pattern, or
   `HttpEnabled` is false.
5. **Join.** Expect a green **🟢 Player Joined** embed in your Discord
   channel with the player name, user id, account age, rebirths and
   `Player Status` = `First-Time Player` or `Returning Player`.
   A brand-new player should say **First-Time Player**.
6. **Check the registry.** Open the DataStore
   `p7_PlayerRegistry_v1` (Studio's DataStore editor, or Open Cloud)
   and look for the key `player_<userId>`. It must contain
   `sessions = 1`, `firstSeen`, `lastSeen`, `playtimeSeconds = 0`.
7. **Leave.** Expect a red **🔴 Player Left** embed with
   `Session Duration`. Then check the registry again:
   `sessions` must still be `1` and `playtimeSeconds` must have grown
   by roughly the session length.
8. **Check that the registry is monotonic.** Set `rebirths` in the
   stored entry to `5`, then trigger a milestone for that player. The
   value must stay `5` (the snapshot merge is `max()`, not a
   replacement).
9. **Check the milestone path.** Trigger a rebirth (or call
   `LogMilestone(player, 'RebirthSucceeded', { rebirth = 1 })` from a
   temporary script). Expect a gold **♻️ Rebirth Succeeded** embed
   with a `New Rebirth` field.
10. **Check the 429 path.** Lower `SendIntervalSeconds` to `0` and
    fire many events at once. Expect occasional
    `[PLOG] WARN webhook delivery failed; event dropped` lines — and
    **no** crash and **no** error in the gameplay path.
11. **Check that gameplay is never blocked.** Time a join. The join
    must complete in the same time whether or not Discord is
    reachable. Stop the network (or set a bogus URL) and confirm the
    game still runs at full speed.
12. **Check the shutdown flush.** Stop the server with a few events
    queued. Expect up to `ShutdownFlushMax` (5) more embeds to
    arrive.

---

## 11. Optional: use the shipped spec

`Tests/PlayerLogger.spec.lua` is a TestEZ spec (9 cases). It never
touches the network and never touches a DataStore — the registry is
exercised through the pure `MergeEntry` function.

Copy it into your test tree (for example
`src/Tests/ServerScriptService/TestEZTests/PlayerLogger.spec.lua`)
and run the TestEZ runner.

Note that the spec's "stays disabled with no webhook and queues
nothing" case depends on `PlayerLogger.IsEnabled()` being `false` —
which is the case as long as the test environment has no webhook
attribute.

See `ReusableSystems/Tests/README.md` for the harness conventions.
