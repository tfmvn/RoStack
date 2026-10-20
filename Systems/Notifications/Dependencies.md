# Notifications — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Base/NotificationService.lua`

All six are required at **module load**:

```lua
local WarningMessages = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Messages).Warning
local SuccessMessages = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Presentation.Messages).Success
local DebugConfig     = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Systems.Debug)
local Debug           = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber       = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local RichTextFormatter = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.RichTextFormatter)
local AudioGroups     = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.AudioGroups)
```

Note `Messages` is required **twice** — once for `.Warning`, once for
`.Success`. Both resolves hit the same module (require is cached), so
the catalog is instantiated once.

Roblox services obtained at runtime:

```lua
local ServerStorage = game:GetService('ServerStorage')   -- module load
local Debris        = game:GetService('Debris')          -- module load
```

`ServerStorage` is used only for the SFX templates;
`Debris` only for cleaning up the one-shot clones.

### `ReplicatedStorage/Config/Presentation/Messages.lua`

A **leaf** — it requires nothing.

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | `Debug.Log` / `Debug.Warn` for every delivery, suppression, unknown id and missing asset. | **Required** — the module fails to load without it. |
| **SharedUtilities** | `ReplicatedStorage.Utility.BigNumber` | `BigNumber.sanitize` + `BigNumber.Format` for the `{Amount}` placeholder. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.RichTextFormatter` | `Entity` / `Mutation` / `Escape` for every name placeholder. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.AudioGroups` | `AssignSfx(clone)` routes the one-shot clone to the right `SoundGroup`. | **Required** (the require itself is unconditional; the function is only called on a clone). |
| **SharedUtilities** | `ReplicatedStorage.Config.Systems.Debug` | Only `DebugConfig.Audio.Enabled` is read. | **Required** (unconditional require). |
| **ClientPresentation** | `ReplicatedStorage.Config.Presentation.Messages` | The message catalog itself. Lives in this system's own `Source/` tree. | **Required.** |
| **PlayerData** | `ServerScriptService.PlayerService` | Injected via `SetPlayerService`; only `Notify(player, category, text)` is used. | **Required at runtime** — before injection, notifications silently do nothing. |

### Systems that call *into* this one (callers, not dependencies)

| System | Typical call |
|---|---|
| `EggsAndHatching` | `NotifySuccess(player, 'Buy_Success', { EggName = ..., Rarity = ... })` from `EggService._onEggArrived` |
| `Animals` | `NotifySuccess(player, 'Hatch_Success' / 'Pickup_Success' / 'Place_Success', ...)` |
| `Economy` | `NotifySuccess(player, 'Sell_Success', { Name = ..., Amount = ... })` |
| `Upgrades` | `NotifySuccess(player, 'Upgrade_Success', { AnimalName = ..., Level = ... })` |
| `BasesAndSlots` | `NotifySuccess(player, 'Lock_Success', { Duration = ... })` |
| `ShopsAndPurchases` | `NotifySuccess(player, 'Shop_MoneyPack' / 'Shop_GearGranted' / ...)` |
| `CodesAndRewards` | `NotifySuccess(player, 'Codes_Success' / 'Codes_PendingDelivered' / 'Daily_Success' / 'Playtime_Success', ...)` |
| `Stealing` | `NotifySuccess(player, 'Steal_Success' / 'Steal_DeliverySuccess', ...)` |
| `Arena` | `NotifySuccess(player, 'Arena_Started' / 'Arena_Won' / 'Arena_RaidComplete', ...)` |
| `Events` | `NotifySuccess(player, 'Event_EggMutated', ...)` |
| everywhere | `NotifyWarning(player, '<Id>', data)` for rejections |

---

## Remotes

The service **creates no remotes and listens to none**. It writes
through `PlayerService.Notify`, which fires the shared `Notify`
RemoteEvent.

| Remote | Direction | Payload |
|---|---|---|
| `ReplicatedStorage.Utility.Remotes.Names.Notify` | Server → Client | `{ Category = 'Warning' \| 'Reward', Text = string }` |

The payload shape is owned by `PlayerService.Notify` and the client
`ToastController`; `NotificationService` only supplies the two string
fields. The catalog's structured `{Type, Id, Data}` decision is
flattened at the API boundary and **is not** on the wire.

`PlayerService.Notify` is the only method of the injected service that
is used.

---

## Profile Fields Read / Written

**None.** `NotificationService` never touches `ProfileService`, never
reads `profile.Data`, and never writes to it.

The only player identity it uses is `player.UserId`, read defensively
inside a `pcall` (`_userKey`). It is used for throttle bucketing only
— never persisted.

---

## Required Studio Assets

| Path | Contents | If missing |
|---|---|---|
| `ServerStorage.Assets.Sfx.Error` | A `Sound` (or a folder containing one). | One `Debug.Warn` per server session; warning toasts are silent. |
| `ServerStorage.Assets.Sfx.Approved` | A `Sound` (or folder). | Successes with `Sound = 'Approved'` are silent. |
| `ServerStorage.Assets.Sfx.CashClaim` | A `Sound` (or folder). | Money successes are silent. |

The lookup accepts either shape:

```lua
ServerStorage.Assets.Sfx.<name>        -- a Sound
ServerStorage.Assets.Sfx.<name>/<any>  -- a folder holding a Sound (found recursively)
```

**No Workspace hierarchy is read.** Nothing is placed in the world.

### `SoundGroup` hierarchy

`AudioGroups.AssignSfx(clone)` is expected to route the clone into a
`SoundGroup`. If the group hierarchy is missing, the clone still plays
at the template's own volume — the notification is not lost.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `PlayerService.Notify` | Delivers the toast (fires a RemoteEvent). | — |
| `HttpService` | **Not used.** | — |
| `DataStoreService` | **Not used.** | — |
| `MarketplaceService` | **Not used.** | — |

**No HTTP, no DataStore, no Marketplace.** The system is entirely
in-memory + a RemoteEvent.

---

## Initialization Order

```text
1. createRemotes()                              -- the Notify RemoteEvent must exist
2. PlayerService.Init()
3. NotificationService.SetPlayerService(PlayerService)
4. (any time)  NotificationService.Init()       -- no-op
```

Steps 1-3 are the real requirement. `NotificationService` has no
boot work of its own; the `Init()` function exists only for symmetry
with the other services and does nothing.

Before step 3 every `NotifyWarning` / `NotifySuccess` call returns
`false` and delivers nothing — it degrades to a `Debug.Log`, it does
not error.

On `Players.PlayerRemoving`, call:

```lua
NotificationService.ForgetPlayer(player.UserId)
```

to drop that player's throttle state. It is not required for
correctness (the throttle is time-based), but it bounds memory.

---

## Require-cycle notes

`NotificationService` requires only `ReplicatedStorage` leaves, so it
can never form a cycle. Every gameplay service can require it directly
without worrying about ordering. This is deliberate — the file header
states it explicitly:

> "Requires only ReplicatedStorage leaves at load: every gameplay
> service requires this directly, cycle-free."
