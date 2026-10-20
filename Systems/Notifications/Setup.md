# Notifications — Setup

Installing the notification system into a new Rojo project.

---

## 1. Copy the files

| From the library | To in your Rojo project | Roblox path |
|---|---|---|
| `Source/ServerScriptService/Base/NotificationService.lua` | `src/ServerScriptService/Base/NotificationService.lua` | `ServerScriptService.Base.NotificationService` |
| `Source/ReplicatedStorage/Config/Presentation/Messages.lua` | `src/ReplicatedStorage/Config/Presentation/Messages.lua` | `ReplicatedStorage.Config.Presentation.Messages` |

Two files. There is no client half of this system — the client half
(the toast renderer) lives in the ClientPresentation system and is
**not** part of this library folder.

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

The `require` paths in `NotificationService.lua` are
`script.Parent.Parent.Parent.ReplicatedStorage.*` — i.e. the module
expects to sit at `ServerScriptService/Base/NotificationService.lua`.
If you put it somewhere else you must fix the requires.

---

## 2. Install the shared utilities

`NotificationService` requires four shared modules at load. Copy them
from `ReusableSystems/Shared/Utilities/`:

| Library path | Roblox path | Used for |
|---|---|---|
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage.Utility.Debug` | `Debug.Log` / `Debug.Warn` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` | `{Amount}` formatting |
| `Shared/Utilities/RichTextFormatter.lua` | `ReplicatedStorage.Utility.RichTextFormatter` | name escaping + rarity colouring |
| `Shared/Utilities/AudioGroups.lua` | `ReplicatedStorage.Utility.AudioGroups` | `AssignSfx` for the one-shot clone |

You also need a `ReplicatedStorage.Config.Systems.Debug` module (the
`DebugConfig` require is unconditional). The canonical one lives in
the SharedUtilities system:

`ReusableSystems/Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua`

The only field the notification system reads is
`DebugConfig.Audio.Enabled`.

**No Wally packages are needed** for this system.

---

## 3. Write your own message catalog

`ReplicatedStorage/Config/Presentation/Messages.lua` is Brainrot
Arena's copy. Replace it wholesale with your own. The shape the
service expects:

```lua
export type SuccessEntry = {
	Id: string,
	Category: string,
	Action: string,
	Trigger: string,
	Message: string,
	NeedsData: { string }?,
	Sound: string,
	Source: string?,
	Note: string?,
}

export type WarningEntry = {
	Id: string,
	Category: string,
	Action: string,
	Trigger: string,
	Severity: string,
	Message: string,
	NeedsData: { string }?,
	Code: string?,
	Source: string?,
	Note: string?,
	NeedsVerification: boolean?,
}

local SuccessMessages: { SuccessEntry } = {
	{
		Id = 'Buy_Success',
		Category = 'Buy',
		Action = 'Buy',
		Trigger = 'Purchase committed',
		Message = 'Bought {EggName}!',
		NeedsData = { 'EggName' },
		Sound = 'Approved',
	},
}

local WarningMessages: { WarningEntry } = {
	{
		Id = 'General_Generic',
		Category = 'General',
		Action = 'Generic',
		Trigger = 'Any rejected action',
		Severity = 'Warning',
		Message = "You can't do that right now.",
	},
}

return table.freeze({
	Success = table.freeze(SuccessMessages),
	Warning = table.freeze(WarningMessages),
})
```

Rules:

- **`General_Generic` must exist** in `Warning` — it is the fallback
  for every unknown warning id.
- `Severity` must be one of `'Warning'`, `'Silent'`, `'Internal'`.
  Anything else behaves like `'Warning'` (it is delivered).
- Placeholders must be **alphanumeric only** (`{EggName}`, `{Amount}`).
  `{Player_Name}` will not be substituted.
- `{Amount}` must be the **raw BigNumber string** (`'25000'`), not a
  number and not a pre-formatted `'$25K'`. A number renders `'$0'`.
- Ids are a wire contract — every caller hard-codes them.

---

## 4. Tune the config

Open `Config.lua` in this folder for a commented copy of every
tunable. The service does **not** read that file; the values live as
literals in `NotificationService.lua`:

| Line | Literal | Default |
|---|---|---|
| 94 | `WARNING_CATEGORY` | `'Warning'` |
| 95 | `SUCCESS_CATEGORY` | `'Reward'` |
| 99 | `REASON_WINDOW_S` | `2.0` |
| 100 | `BURST_MAX` | `6` |
| 101 | `BURST_WINDOW_S` | `5.0` |

To make them configurable, replace the literals with reads from a
config module of your own and add the require at the top of
`NotificationService.lua`.

The placeholder fallbacks are at line 237 (`_PLACEHOLDER_FALLBACK`)
— extend that table if your catalog uses placeholders beyond the five
shipped ones.

---

## 5. Bootstrap

```lua
local ServerScriptService = game:GetService('ServerScriptService')
local NotificationService = require(ServerScriptService.Base.NotificationService)
local PlayerService = require(ServerScriptService.PlayerService)

-- your normal boot sequence
PlayerService.Init()
NotificationService.SetPlayerService(PlayerService)
NotificationService.Init()   -- no-op, but keeps the sequence uniform
```

`NotificationService.SetPlayerService(PlayerService)` is the **one**
required ordering step. Before it, every notification call returns
`false` and delivers nothing.

Also hook cleanup:

```lua
game:GetService('Players').PlayerRemoving:Connect(function(player)
    NotificationService.ForgetPlayer(player.UserId)
end)
```

`ForgetPlayer` drops the player's throttle state. It is optional
(the throttle is time-based) but it bounds memory.

`NotificationService.Init()` does nothing — it exists for symmetry.

---

## 6. Author the Studio assets

Create these in Studio under `ServerStorage`:

```
ServerStorage
└── Assets
    └── Sfx
        ├── Error       (Sound)
        ├── Approved    (Sound)
        └── CashClaim   (Sound)
```

Each may be a `Sound` directly **or** a folder containing a `Sound`
(the service finds it recursively). The names must match the `Sound`
field of your success entries and the hard-coded `'Error'` used for
warnings.

A missing asset is **not** fatal: one `Debug.Warn` is logged and the
notifications run silent.

You do not need to author anything in `Workspace`.

---

## 7. Wire the client (or reuse the existing one)

The service delivers through `PlayerService.Notify(player, category,
text)`. Your `PlayerService` must implement that method, and it must
fire a RemoteEvent to the client with:

```lua
{ Category = 'Warning' | 'Reward', Text = string }
```

If you are reusing the Brainrot Arena client, the toast renderer is
`ToastController` in the ClientPresentation system. Copy that system
as well, or write your own renderer against the `{Category, Text}`
shape.

If you write your own `PlayerService`, the only contract is:

```lua
function PlayerService.Notify(player, category, text)
    Remotes.FireClient(Remotes.Names.Notify, player, { Category = category, Text = text })
end
```

---

## 8. Smoke test

1. **Start the server.** No errors in the Output window.
2. **Flip `DebugConfig.ServerDebug = true`** (in
   `ReplicatedStorage/Config/Systems/Debug`) and restart, so the
   `[NS]` trace lines appear.
3. **Trigger a warning.** From a temporary server script:
   ```lua
   NotificationService.NotifyWarning(player, 'Buy_InsufficientCash', { Amount = '25000' })
   ```
   Expect a toast reading
   `'You need $25.0K more to buy this Egg.'` and the console line
   `[NS] warning { player = <userId>, id = Buy_InsufficientCash, ... }`.
4. **Check the throttle.** Call the same line twice in a row. The
   second call must return `false` and produce **no** second toast.
5. **Check the burst cap.** Call six *different* warning ids in quick
   succession. The seventh must return `false`.
6. **Check success delivery.**
   ```lua
   NotificationService.NotifySuccess(player, 'Buy_Success', { EggName = 'Lucky Egg', Rarity = 'Legendary' })
   ```
   Expect `'Bought Lucky Egg!'` — with the rarity colour applied only
   when `Rarity` resolves:
   `'Bought <font color="#F5C846">Lucky Egg</font>!'`.
7. **Check that successes are not throttled.** Call the success line
   three times with different names. All three must deliver.
8. **Check the severity policy.** Call
   `NotifyWarning(player, 'Buy_InProgress', nil)` where that id has
   `Severity = 'Silent'`. Expect `false`, no toast, and a
   `[NS] suppressed(silent/internal)` log line.
9. **Check the unknown-id behaviour.** `NotifyWarning(player,
   'NoSuchId', nil)` must deliver `"You can't do that right now."`,
   while `NotifySuccess(player, 'NoSuchId', nil)` must deliver
   **nothing** and log `[NS] WARN unknown success id — nothing sent`.
10. **Check the SFX.** With `ServerStorage.Assets.Sfx.Error` present,
    a warning should be audible. Delete the asset, restart, fire a
    warning: expect one `[NS] WARN ServerStorage.Assets.Sfx missing —
    notifications run silent` line and no crash.
11. **Check the missing-player-service path.** Temporarily comment out
    the `SetPlayerService` call. Notifications must return `false`
    and **not** error.

---

## 9. Optional: use the shipped spec

`Tests/NotificationService.spec.lua` is a TestEZ spec (18 cases). It
requires a `_Helpers` module from the shared test harness
(`ReusableSystems/Tests/`) and injects a fake `PlayerService` via
`SetPlayerService`.

Copy it into your test tree (for example
`src/Tests/ServerScriptService/TestEZTests/NotificationService.spec.lua`),
make sure the shared `_Helpers` module is on the path, and run the
TestEZ runner.

Two things to know before you trust it:

- The spec asserts the **fake `PlayerService`**, so no SFX and no
  RemoteEvent are involved.
- One assertion is **wrong** against the current catalog: the
  delivery test expects `'Base locked!'` but the catalog message is
  `'Base locked for {Duration}s!'` and `Duration` is not in the
  fallback table, so the real text is `'Base locked for ?s!'`. The
  spec's own text test (line 95) asserts the correct value. Fix the
  delivery assertion when you port it.

See `ReusableSystems/Tests/README.md` for the harness conventions.
