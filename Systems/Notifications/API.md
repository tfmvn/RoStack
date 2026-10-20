# Notifications — API

Every public function of every module in this system. There are two
modules:

- `ServerScriptService.Base.NotificationService` — the delivery
  pipeline.
- `ReplicatedStorage.Config.Presentation.Messages` — a **data** module
  (no functions).

All functions are **server-only**. Nothing here may be called from a
client script.

---

## `ServerScriptService.Base.NotificationService`

```lua
local NotificationService = require(game:GetService('ServerScriptService').Base.NotificationService)
```

The module table is frozen (`table.freeze`) — you cannot add fields
to it at runtime.

**Threading:** every public function is safe to call from any server
thread. There is no `task.spawn`, no yielding, and no lock.

---

### `NotificationService.NotifyWarning(player, id, data): boolean`

Deliver a player-facing **warning** (a rejected action).

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `player` | `Player` | The actor. Only `player.UserId` is read (for throttle bucketing) and `player.PlayerGui` (for the SFX clone). |
| `id` | `string` | A `Messages.Warning` catalog `Id`. |
| `data` | `any` | Optional table of server-calculated values: `{ Amount }`, `{ Level }`, `{ EggName }`, `{ AnimalName }`, `{ Name }`, `{ MutationName }`, `{ Rarity }`, … |

**Returns**

`true` when a toast was delivered. `false` otherwise.

**Failure modes — never throws**

The whole body is inside one `pcall`; the return value is
`delivered`, initialised `false`.

| Condition | Return | Side effect |
|---|---|---|
| `playerServiceRef` is `nil` (never wired) | `false` | none |
| `playerServiceRef.Notify` is missing | `false` | none |
| `playerServiceRef.Notify` throws | `false` | none (swallowed by the `pcall`) |
| `id` is unknown / not a string | `true` | the **`General_Generic`** toast is delivered |
| The entry's `Severity` is `'Silent'` | `false` | `Debug.Log('NS', 'suppressed(silent/internal)', ...)` |
| The entry's `Severity` is `'Internal'` | `false` | same log |
| The same id was delivered to this player < 2.0 s ago | `false` | none |
| 6 warnings were already delivered to this player within 5.0 s | `false` | none |
| The player has no integer `UserId` | — | the throttle key is the literal `'?'` (shared with `nil` players) |
| Anything else throws | `false` | swallowed |

**Side effects on success**

- The toast is delivered as category `'Warning'`.
- `_lastReasonAt["<userId>:<resolvedId>"]` is set to `os.clock()`.
- A stamp is appended to `_burst["<userId>"]`.
- Two `Debug.Log` lines (`'NotificationTrace'` and `'NS'`).
- A one-shot clone of `ServerStorage.Assets.Sfx.Error` plays in the
  player's `PlayerGui` and is removed by `Debris` after
  `TimeLength + 0.5` s.

**Example**

```lua
NotificationService.NotifyWarning(player, 'Buy_InsufficientCash', { Amount = '25000' })
-- -> "You need $25.0K more to buy this Egg."
```

---

### `NotificationService.NotifySuccess(player, id, data): boolean`

Deliver a player-facing **success** (a committed action).

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `player` | `Player` | The actor. |
| `id` | `string` | A `Messages.Success` catalog `Id`. |
| `data` | `any` | Optional table of server-calculated values. |

**Returns**

`true` when a toast was delivered. `false` otherwise.

**Failure modes — never throws**

| Condition | Return | Side effect |
|---|---|---|
| `playerServiceRef` is `nil` | `false` | none |
| `playerServiceRef.Notify` is missing or throws | `false` | none |
| `id` is unknown / not a string | `false` | `Debug.Warn('NS', 'unknown success id — nothing sent', { id = ... })` |
| `GetSuccessText` returns `nil` | `false` | none |
| Anything else throws | `false` | swallowed |

**Note:** there is **no fallback message** for an unknown success id.
A fabricated success is considered worse than silence. This is the
mirror image of `NotifyWarning`, which *does* fall back.

**Side effects on success**

- The toast is delivered as category `'Reward'`.
- Two `Debug.Log` lines.
- The entry's `Sound` is played **unless** it is `nil`, `''` or
  `'None'`.

**Throttling:** none. Successes are never suppressed — a burst of
`Buy Buy Buy` commits must all show.

**Example**

```lua
NotificationService.NotifySuccess(player, 'Buy_Success', {
    EggName = 'Lucky Egg',
    Rarity  = 'Legendary',
})
-- -> 'Bought <font color="#F5C846">Lucky Egg</font>!'
```

---

### `NotificationService.GetWarningText(id, data): string`

Resolve a warning id to its final player-facing text **without
delivering it**. Useful for previews, logs and tests.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `id` | `any` | A `Messages.Warning` catalog `Id`. A non-string is treated as unknown. |
| `data` | `any` | Optional placeholder values. |

**Returns**

The resolved text. **Always a string** — an unknown id (or `nil`)
falls back to `General_Generic`'s message.

**Failure modes — never throws**

- The `gsub` is inside a `pcall`; if it threw, the **unresolved
  template** would be returned (with `{Placeholder}` still in it).
  Not observed in practice.
- An unknown severity is irrelevant here — `GetWarningText` does not
  consult `Severity`, so it will happily return the text of a
  `Silent` entry.

**Example**

```lua
NotificationService.GetWarningText('Buy_Carrying', nil)
-- -> "You can't buy while carrying something. Place it down first."
```

---

### `NotificationService.GetSuccessText(id, data): string?`

Resolve a success id to its final text **without delivering it**.

**Parameters:** `id: any`, `data: any` — as above.

**Returns**

The resolved text, or **`nil`** when the id is unknown or not a
string.

**Failure modes — never throws.** Same `pcall` protection as
`GetWarningText`.

**Example**

```lua
NotificationService.GetSuccessText('Lock_Success', { Duration = 60 })
-- -> 'Base locked for 60s!'
NotificationService.GetSuccessText('Lock_Success', nil)
-- -> 'Base locked for ?s!'   (Duration has no fallback)
```

---

### `NotificationService.SetPlayerService(ps)`

Inject the service used for delivery.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `ps` | `any` | An object with a `Notify(player, category, text)` method. `nil` disables delivery. |

**Returns:** nothing.

**Behaviour**

Replaces `playerServiceRef`. Only `ps.Notify` is ever called.

**Failure modes:** none — it cannot throw. Passing a stub without a
`Notify` field silently disables all notifications (the calls return
`false`).

---

### `NotificationService.ForgetPlayer(userId)`

Drop a player's throttle state.

**Parameters:** `userId: number`.

**Returns:** nothing.

**Behaviour**

- Deletes every `_lastReasonAt` key whose text starts with
  `"<userId>:"`.
- Sets `_burst[tostring(userId)] = nil`.

**Failure modes:** never throws. It does **not** clear the `'?'`
bucket used by players with no integer `UserId`, and it does not
clear the SFX cache.

---

### `NotificationService.Init()`

A **no-op**. The service has no boot work.

**Parameters / Returns:** none.

**Note:** it exists only so the bootstrap can call every service's
`Init()` uniformly.

---

### `NotificationService._TestReset()`

Clear the throttle and SFX caches so a spec observes a fresh service.

**Parameters / Returns:** none.

**Clears**

- `_lastReasonAt`
- `_burst`
- `_sfxCache`
- `_sfxCacheValid`

**Does NOT clear**

- `_warnedMissing` — so a missing-asset warning fires only once per
  server lifetime, even across `_TestReset()` calls.
- `playerServiceRef` — the spec clears it separately with
  `SetPlayerService(nil)`.
- The catalog indexes (`_warnings`, `_successes`) — they are
  immutable.

---

## `ReplicatedStorage.Config.Presentation.Messages`

A **data module**. It has no functions.

```lua
local Messages = require(game:GetService('ReplicatedStorage').Config.Presentation.Messages)
```

**Returns**

```lua
{
    Success = { SuccessEntry, ... },   -- 30 entries
    Warning = { WarningEntry, ... },   -- 105 entries
}
```

Both arrays are `table.freeze`d, and the wrapper table is frozen.

### `SuccessEntry`

| Field | Type | Required | Meaning |
|---|---|---|---|
| `Id` | `string` | yes | The id callers pass to `NotifySuccess`. Unique. |
| `Category` | `string` | yes | Grouping label (e.g. `'Buy'`, `'Shop'`). Documentation only — the service ignores it. |
| `Action` | `string` | yes | The gameplay action (e.g. `'Buy'`, `'BaseLock'`). Documentation only. |
| `Trigger` | `string` | yes | Human description of the commit point. Documentation only. |
| `Message` | `string` | yes | The template. May contain `{Placeholder}` tokens. |
| `NeedsData` | `{ string }?` | no | The placeholder keys this message expects. Documentation only. |
| `Sound` | `string` | yes | The SFX asset name, or `'None'` for no sound. |
| `Source` | `string?` | no | Which service fires it. Documentation only. |
| `Note` | `string?` | no | Extra commentary. Documentation only. |

### `WarningEntry`

| Field | Type | Required | Meaning |
|---|---|---|---|
| `Id` | `string` | yes | The id callers pass to `NotifyWarning`. Unique. |
| `Category` | `string` | yes | Grouping label. Documentation only. |
| `Action` | `string` | yes | The rejected action. Documentation only. |
| `Trigger` | `string` | yes | Human description. Documentation only. |
| `Severity` | `string` | yes | `'Warning'` (delivered), `'Silent'` (logged only), `'Internal'` (logged only). |
| `Message` | `string` | yes | The template. |
| `NeedsData` | `{ string }?` | no | Expected placeholder keys. Documentation only. |
| `Code` | `string?` | no | A machine-readable reason code. Documentation only. |
| `Source` | `string?` | no | Which service fires it. Documentation only. |
| `Note` | `string?` | no | Extra commentary. Documentation only. |
| `NeedsVerification` | `boolean?` | no | Flags a message that has not been playtested. Documentation only. |

**Only `Id`, `Message`, `Severity` and `Sound` are read by the
service.** Everything else is developer documentation.

### Shipped id inventory

**Success (30)** — `Buy_Success`, `Pickup_Success`, `Hatch_Success`,
`Place_Success`, `Steal_Success`, `Steal_DeliverySuccess`,
`Arrival_Success`, `Upgrade_Success`, `Sell_Success`, `Lock_Success`,
`Gear_Success`, `Arena_Started`, `Arena_Won`, `Arena_RaidComplete`,
`Codes_Success`, `Codes_PendingDelivered`, `Daily_Success`,
`Playtime_Success`, `RareEgg_Spawned`, `Shop_MoneyPack`,
`Shop_GearGranted`, `Shop_LuckActivated`, `Shop_LuckPurchased`,
`Shop_LuckExpired`, `Shop_SkipDaily`, `Shop_SkipPlaytime`,
`Shop_DoorOpened`, `Shop_GamepassActive`, `Event_EggMutated`.

**Warning (105)** — grouped by family:

| Family | Count | Ids |
|---|---|---|
| Buy | 11 | `Buy_Carrying`, `Buy_InvalidEgg`, `Buy_InProgress`, `Buy_ServiceNotReady`, `Buy_InvalidPrice`, `Buy_InsufficientCash`, `Buy_NoBase`, `Buy_BaseFull`, `Buy_SlotRace`, `Buy_ArrivalBaseFull` |
| Gear | 9 | `Gear_InvalidGear`, `Gear_AlreadyOwned`, `Gear_Busy`, `Gear_InsufficientCash`, `Gear_LockedRebirth`, `Gear_ToolUnavailable`, `Gear_RobuxOnly` |
| Shop | 3 | `Shop_AlreadyOwned`, `Shop_SkipRequired` |
| Arena | 11 | `Arena_InvalidLevel`, `Arena_Locked`, `Arena_NoTeam`, `Arena_Active`, `Arena_Carrying`, `Arena_Stealing`, `Arena_NoBase`, `Arena_Lost`, `Arena_RaidFailed`, `Arena_AreaNotReady`, `Arena_InsufficientFunds`, `Arena_RestartUnavailable` |
| Pickup | 9 | `Pickup_AlreadyCarrying`, `Pickup_InvalidSlot`, `Pickup_NotOwner`, `Pickup_TargetGone`, `Pickup_TooFar`, `Pickup_InvalidAction`, `Pickup_Dead`, `Pickup_NoCharacter`, `Pickup_NoBase`, `Pickup_CarryFailed` |
| Hatch | 4 | `Hatch_AlreadyCarrying`, `Hatch_InvalidTarget`, `Hatch_Failed`, `Hatch_Dead` |
| Place | 7 | `Place_NotCarrying`, `Place_InvalidSlot`, `Place_NotOwner`, `Place_SlotOccupied`, `Place_StealLocked`, `Place_TooFar`, `Place_CarryMismatch`, `Place_Dead` |
| Steal | 12 | `Steal_OwnAnimal`, `Steal_AlreadyCarrying`, `Steal_BaseFull`, `Steal_BaseLocked`, `Steal_TooFar`, `Steal_TargetBusy`, `Steal_TargetGone`, `Steal_Cooldown`, `Steal_InvalidRequest`, `Steal_Dead`, `Steal_CarryFailed`, `Steal_DeliveryFull`, `Steal_DeliveryStale`, `Steal_DeliveryDead` |
| Menu | 6 | `Menu_NoMenu`, `Menu_Throttled`, `Menu_StaleTarget`, `Menu_CannotUpgradeEgg`, `Menu_UpgradeUnavailable` |
| Upgrade | 10 | `Upgrade_InsufficientCash`, `Upgrade_MaxLevel`, `Upgrade_NotOwner`, `Upgrade_InvalidTarget`, `Upgrade_Busy`, `Upgrade_InvalidRequest`, `Upgrade_Unavailable`, `Upgrade_Failed`, `Upgrade_Dead` |
| Sale | 5 | `Sale_StaleTarget`, `Sale_NotOwner`, `Sale_InvalidState`, `Sale_PoolBusy`, `Sale_Failed`, `Sale_Dead` |
| Collect | 4 | `Collect_EmptyPool`, `Collect_Debounced`, `Collect_ForeignOrEmpty`, `Collect_Failed` |
| Lock | 3 | `Lock_NotOwner`, `Lock_Debounced`, `Lock_PurchasedOpen` |
| Codes | 4 | `Codes_InvalidCode`, `Codes_CodeExpired`, `Codes_CodeDisabled`, `Codes_AlreadyRedeemed` |
| Daily / Playtime | 4 | `Daily_NotReady`, `Daily_AlreadyClaimed`, `Playtime_NotReady`, `Playtime_AlreadyClaimed` |
| General | 3 | `General_Dead`, `General_Cooldown`, `General_Generic` |

(The counts above are approximate groupings; the authoritative totals
are 30 success and 105 warning entries, with 81 `'Warning'`, 20
`'Silent'` and 4 `'Internal'` severities.)

**`General_Generic` is mandatory** — it is the fallback for every
unknown warning id. Its message is `"You can't do that right now."`
