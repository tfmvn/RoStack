# Notifications

The one canonical player-feedback system: **warnings** (rejected
actions) and **successes** (committed actions) through the same
server-authoritative path.

**Portability:** Grade A core (the catalog-driven delivery pipeline,
the throttle, the placeholder resolver) + Grade B (the message catalog
is Brainrot Arena's copy and every entry names a Brainrot Arena
service). See *Portability* below.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

```
  PLAYER ACTION
       |
       v
  SERVER VALIDATES (the gameplay service owns the rules)
       |
     +---+---+
     |       |
   SUCCESS  REJECT
     |       |
     v       v
  NotifySuccess  NotifyWarning
     |       |
     +---+---+
         |
         v
  PlayerService.Notify -> Notify RemoteEvent
  (ToastController: Warning amber / Reward green, coalesced, animated, capped)
  + one-shot SFX clone in the actor's PlayerGui
```

`NotificationService` is the **only** module that turns a gameplay
outcome into a player-facing toast. It:

- Resolves a **catalog id** to a message template. The template
  contains `{Placeholder}` tokens that are resolved server-side with
  server-calculated values (money via `BigNumber`, names escaped and
  rarity-coloured).
- Applies a **severity policy** to warnings: `Silent` and `Internal`
  severities never reach the player.
- **Throttles warnings** per player (same id within 2 s, plus a
  6-per-5 s burst cap). Successes are **never** throttled.
- Plays a **one-shot SFX clone** into the acting player's `PlayerGui`
  (Warning → `Assets.Sfx.Error`; Success → the catalog entry's own
  `Sound`).
- Delivers through `PlayerService.Notify(player, category, text)`,
  so the wire format stays `{Category, Text}` and `ToastController`
  is untouched.

The structured decision (`{Type, Id, Data}`) happens at the
`NotificationService` API boundary; the client only renders.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `NotificationService.NotifyWarning(player, id, data?)` | Server | Rejected action. `id` is a `WarningMessages` catalog id. Returns `true` when a toast was delivered. |
| `NotificationService.NotifySuccess(player, id, data?)` | Server | Committed action. `id` is a `SuccessMessages` catalog id. Returns `true` when a toast was delivered. |
| `NotificationService.GetWarningText(id, data?)` | Server | Resolves a warning id to its final text **without delivering**. Unknown ids fall back to `General_Generic`. |
| `NotificationService.GetSuccessText(id, data?)` | Server | Resolves a success id to its final text **without delivering**. Unknown ids return `nil`. |
| `NotificationService.SetPlayerService(ps)` | Server | Injects the `PlayerService` ref used for delivery. Bootstrap-injected. `nil` disables delivery (calls return `false`). |
| `NotificationService.ForgetPlayer(userId)` | Server | Drops that player's throttle state. |
| `NotificationService.Init()` | Server | No-op. The service has no boot work. |
| `NotificationService._TestReset()` | Test seam | Clears throttle state and the SFX cache. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Base/NotificationService.lua` | `ServerScriptService.Base.NotificationService` | The delivery pipeline. |
| `Source/ReplicatedStorage/Config/Presentation/Messages.lua` | `ReplicatedStorage.Config.Presentation.Messages` | The message catalog: `.Success` and `.Warning` arrays. |

---

## Configuration

There is **no config module of its own**, but there are three tunables
that are literals inside `NotificationService.lua`:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `REASON_WINDOW_S` | `NotificationService.lua:99` | `2.0` | Seconds. A repeated **same-id** warning to the same player inside this window is dropped. |
| `BURST_MAX` | `NotificationService.lua:100` | `6` | Maximum warnings delivered to one player inside `BURST_WINDOW_S`. |
| `BURST_WINDOW_S` | `NotificationService.lua:101` | `5.0` | Seconds. The burst window. |
| `WARNING_CATEGORY` | `NotificationService.lua:94` | `'Warning'` | The category string sent to the client. |
| `SUCCESS_CATEGORY` | `NotificationService.lua:95` | `'Reward'` | The category string sent to the client. |

Two external values are read:

| Value | Lives in | Meaning |
|---|---|---|
| `DebugConfig.Audio.Enabled` | `ReplicatedStorage.Config.Systems.Debug` | When `true`, `_playSfx` logs the resolved sound id / volume / parent. |
| `ServerStorage.Assets.Sfx.<name>` | Studio | The sound templates. Missing → one warning, then notifications run silent. |

See `Config.lua` for a commented copy of the tunables.

### The message catalog

`ReplicatedStorage.Config.Presentation.Messages` returns
`{ Success = {SuccessEntry}..., Warning = {WarningEntry}... }`.

**Success entry shape** — `Id`, `Category`, `Action`, `Trigger`,
`Message`, `NeedsData?`, `Sound`, `Source?`, `Note?`.

**Warning entry shape** — `Id`, `Category`, `Action`, `Trigger`,
`Severity`, `Message`, `NeedsData?`, `Code?`, `Source?`, `Note?`,
`NeedsVerification?`.

`Severity` is a field, not a separate list, and it is the whole
warning policy:

| Severity | Behaviour |
|---|---|
| `'Warning'` | Delivered as a toast. |
| `'Silent'` | Never delivered. Logged only. Used for normal races and debounces. |
| `'Internal'` | Never delivered. Logged only. Used for developer/system failures. |

The catalog is **data only** — the service interprets it.

---

## Dependencies

See `Dependencies.md` for the full list.

Module requires (all `ReplicatedStorage` leaves at load time, so
there is no require cycle and every gameplay service can require
`NotificationService` directly):

- `ReplicatedStorage.Config.Presentation.Messages`
- `ReplicatedStorage.Config.Systems.Debug`
- `ReplicatedStorage.Utility.Debug`
- `ReplicatedStorage.Utility.BigNumber`
- `ReplicatedStorage.Utility.RichTextFormatter`
- `ReplicatedStorage.Utility.AudioGroups`

Injected at runtime:

- `ServerScriptService.PlayerService` — via `SetPlayerService(ps)`.
  Only `PlayerService.Notify(player, category, text)` is used.

Roblox services: `ServerStorage` (SFX templates), `Debris` (SFX
cleanup).

---

## Initialization Order

`NotificationService` needs no boot work. The only ordering
requirement is the `PlayerService` injection:

```text
1. createRemotes()                       -- the Notify RemoteEvent must exist
2. PlayerService.Init()
3. NotificationService.SetPlayerService(PlayerService)
```

Before step 3, `NotifyWarning` / `NotifySuccess` return `false` and
deliver nothing — they degrade to a `Debug.Log`, they do not error.

`NotificationService.Init()` is a no-op and can be called anywhere.

---

## Data

**No persistence.** `NotificationService` reads and writes no profile
field and no DataStore.

In-memory state:

| Table | Key | Value | Cleared by |
|---|---|---|---|
| `_warnings` | catalog id | entry | never (built at load) |
| `_successes` | catalog id | entry | never (built at load) |
| `_lastReasonAt` | `"<userId>:<resolvedId>"` | `os.clock()` of the last delivery | `ForgetPlayer(userId)` |
| `_burst` | `userId` | array of `os.clock()` stamps inside the window | `ForgetPlayer(userId)` |
| `_sfxCache` | sound name | resolved `Sound` | `_TestReset()` |
| `_sfxCacheValid` | sound name | `true` once the lookup was attempted | `_TestReset()` |
| `_warnedMissing` | sound name | `true` once the "missing asset" warning was logged | **never** — `_TestReset()` does not clear it |

`ForgetPlayer` clears throttle state **by string prefix** on
`"<userId>:"`, so it also removes the per-id entry.

---

## Known Limitations

- **The wire format is still `{Category, Text}`.** The structured
  `{Type, Id, Data}` decision is consumed at the API boundary and
  then flattened. A client cannot distinguish two different success
  ids that resolve to the same text, and cannot react to a specific
  id.
- **The catalog is the game.** Every `Source` field names a
  Brainrot Arena service (`EggService._onEggArrived`,
  `BaseLockService.Lock`, …). A new game must write its own catalog
  or accept nonsense audit trails.
- **`Lock_Success` renders `'Base locked for ?s!'` when `Duration` is
  missing.** The placeholder fallback table (`_PLACEHOLDER_FALLBACK`)
  covers only `EggName`, `AnimalName`, `Name`, `Level`, `Amount` —
  not `Duration`, `RewardText`, `GearName`, `Multiplier`, `Required`,
  or `PlayerName`. Any missing value falls through to the generic
  branch and becomes `'?'`. Pass the data.
- **The shipped spec is stale in one place.**
  `Tests/NotificationService.spec.lua:175` expects the delivered
  success text to be `'Base locked!'`, but the catalog message is
  `'Base locked for {Duration}s!'`, so the actual delivered text is
  `'Base locked for ?s!'`. The spec's *own* text-resolution test
  (line 95) asserts `'Base locked for ?s!'`. The two assertions
  contradict each other; the catalog is the newer of the two.
- **The SFX clone is a `Sound` in the `PlayerGui`.** It is a
  per-player clone, so it replicates to that client alone — but it
  is created server-side, which means it counts against the
  instance count and is cleaned up by `Debris` after
  `TimeLength + 0.5` s.
- **A missing SFX asset only warns once per asset name per server
  session.** The `_warnedMissing` table is never cleared — not even by
  `_TestReset()`.
- **`AudioGroups.AssignSfx(clone)` must succeed** for the sound to
  be routed to the right `SoundGroup`. If the `SoundGroup` hierarchy
  is missing, the clone still plays at default volume.
- **Warning throttling is per `(userId, id)`, not per category.** A
  player spamming 40 distinct warning ids still gets 6 in 5 seconds.
- **The success path never throttles.** That is deliberate ("Buy Buy
  Buy" must show every toast), but it means a buggy caller can spam
  successes at the client.
- **No test seam for the delivered payload other than injecting a
  fake `PlayerService`.** The spec does exactly that.

---

## Testing

`Tests/NotificationService.spec.lua` — 18 cases in two groups
(10 catalog, 8 delivery).

*Catalog* — verbatim warning text, dynamic `{Amount}` in HUD format,
raw BigNumber strings for money packs, the purchased-open door copy,
unknown-warning fallback to `General_Generic`, success text with
server data, rarity-coloured entity names, markup escaping, unknown
success ids returning `nil`, and "no internals in the text"
(the strings must not contain `RemoteEvent` or `Service`).

*Delivery* — the `Warning` and `Reward` categories, same-id
suppression, repeated successes never suppressed, `Silent`/`Internal`
never delivered, unknown success ids never delivered, per-player
isolation, and "never throws / reports `false` without a wired
ref".

The spec injects a fake `PlayerService` via `SetPlayerService` and
stubs the remotes via `_Helpers`. **No DataStore is touched.** It
still requires Roblox Studio (TestEZ). See `../../Tests/README.md`.

---

## Portability

**Grade A — portable core**, with a **Grade B** content layer.

**Grade A (portable as-is):**
- The delivery pipeline (`NotificationService.lua`): catalog lookup,
  severity policy, warning throttle, placeholder resolution, one-shot
  SFX clone, `pcall` discipline, the `{Category, Text}` wire contract.
- The `PlayerService.Notify(player, category, text)` interface — any
  object with that method works.
- The shared utilities it depends on (`Debug`, `BigNumber`,
  `RichTextFormatter`, `AudioGroups`).

**Grade B (game-specific adapter — must be rewritten):**
- `ReplicatedStorage/Config/Presentation/Messages.lua` — the entire
  catalog is Brainrot Arena's copy. Every id, every message and every
  `Source` field names a Brainrot Arena service. The *shape* is
  portable; the *content* is not.
- The `Sound` names in the catalog (`Approved`, `CashClaim`) and the
  hard-coded `'Error'` warning sound.
- The `ServerStorage.Assets.Sfx` hierarchy (Studio-authored).

**Grade C (platform-bound):** none. The system talks to no external
API and touches no DataStore. (The *client* toast renderer is
platform-bound in the sense that it lives in the ClientPresentation
system, but it is not part of this library folder.)

---

## Adapting to a New Game

1. **Write your own `Messages.lua`.** Keep the two arrays
   (`Success`, `Warning`) and the entry shapes. Ids must be stable
   (`<System>_<Case>`); the service resolves by id, and every caller
   hard-codes the id.
2. **Set `Severity` deliberately.** `Silent` and `Internal` are the
   only way to record a rejection without annoying the player. Use
   `Internal` for authoring/wiring faults.
3. **Never fabricate a success.** Call `NotifySuccess` only after the
   authoritative commit, and only with an id that exists in the
   catalog. An unknown id delivers nothing and warns server-side.
4. **Pass every placeholder the message uses.** Missing values render
   as `'?'`; add the key to `_PLACEHOLDER_FALLBACK` if you want a
   nicer default.
5. **Keep the wire format.** `{Category, Text}` means the existing
   `ToastController` keeps working. Change the wire format only if
   you also rewrite the client.
6. **Author `ServerStorage.Assets.Sfx`** with the sound names your
   catalog references (`Error`, `Approved`, `CashClaim`, `None`).
   Missing sounds are a warning, not a crash.
7. **Adjust the throttle** (`REASON_WINDOW_S`, `BURST_MAX`,
   `BURST_WINDOW_S`) if your game produces a different warning
   cadence.
