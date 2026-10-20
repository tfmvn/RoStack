# Notifications — MEMORY

Engineering notes for a future agent. Dense, factual, about the code as
it actually is.

---

## Purpose

One server-authoritative path that turns a gameplay outcome into a
player-facing toast: `NotifyWarning` (rejected) and `NotifySuccess`
(committed), resolved from a **data catalog** of message templates.

---

## How it actually works, step by step

### Load time

1. `NotificationService` requires six `ReplicatedStorage` leaves at
   module load (lines 68-74). All are leaves, so there is **no require
   cycle** — any gameplay service can require this module directly.
2. It builds two index tables from the catalog arrays:
   `_warnings[id] = entry` and `_successes[id] = entry`
   (lines 80-92). Only entries with a `string` `Id` are indexed;
   anything else is skipped.
3. Literals are fixed: `WARNING_CATEGORY = 'Warning'`,
   `SUCCESS_CATEGORY = 'Reward'`, `REASON_WINDOW_S = 2.0`,
   `BURST_MAX = 6`, `BURST_WINDOW_S = 5.0`.
4. `playerServiceRef` starts `nil`. Delivery is **off** until
   `SetPlayerService` is called.

### `NotifyWarning(player, id, data)`

1. The whole body is inside one `pcall` (line 339) → **never throws**;
   the return value is `delivered`, initialised `false`.
2. `key = _userKey(player)` — `player.UserId` read inside a `pcall`;
   if it is not an integer number the key is the literal `'?'`.
   **Consequence: a nil player and a fake player without a `UserId`
   share the throttle bucket `'?'`.** Two such actors suppress each
   other. (In the shipped spec every fake player has a real integer
   `UserId`, so this is latent, not observed.)
3. Look up `entry = _warnings[id]`. If `id` is not a string, or the id
   is unknown, `entry` is `nil` and `resolvedId` becomes
   `'General_Generic'`. **An unknown warning id therefore still
   delivers a toast** — the generic one.
4. **Severity gate**: if `entry.Severity == 'Silent'` or `'Internal'`,
   log and return `false`. No toast, no SFX, no throttle bookkeeping.
5. `text = GetWarningText(resolvedId, data)` — placeholder resolution.
6. **Same-id suppression**: `reasonKey = key .. ':' .. resolvedId`.
   If `_lastReasonAt[reasonKey]` exists and `now - last < 2.0`, return
   `false`. Note the key uses the **resolved** id, so an unknown id
   throttles against `General_Generic`.
7. **Burst cap**: rebuild `_burst[key]` keeping only stamps inside
   `5.0` s, then if `#fresh >= 6` return `false`. This is a *rolling*
   window over all warning ids for that player, not a per-id count.
8. `_deliver(player, 'Warning', text)`. `_deliver` returns `false` when
   `playerServiceRef` or `playerServiceRef.Notify` is missing, and
   wraps the actual call in a `pcall` → a throwing `Notify` yields
   `false`, not an error.
9. On success: `delivered = true`, `_lastReasonAt[reasonKey] = now`,
   the stamp is appended to `_burst[key]`, two `Debug.Log` lines
   (`'NotificationTrace'` and `'NS'`), then `_playSfx(player,
   'Error')`.

**The throttle stamps are only written when the toast was actually
delivered.** A suppressed warning does not consume burst budget.

### `NotifySuccess(player, id, data)`

1. Same `pcall` wrapper.
2. Look up `_successes[id]`. If the id is unknown or not a string →
   `Debug.Warn('NS', 'unknown success id — nothing sent', ...)` and
   return `false`. **No toast, no fallback.** A fabricated success is
   considered worse than silence.
3. `GetSuccessText(id, data)` — `nil` → return `false`.
4. `_deliver(player, 'Reward', text)`.
5. On success: `Debug.Log` twice, then `_playSfx(player, entry.Sound)`
   **only if** `entry.Sound` is not `nil`, not `''`, and not `'None'`.
   So a success with `Sound = 'None'` is visual-only.
6. **No throttle of any kind.** Successes are never suppressed.

### Placeholder resolution (`_resolvePlaceholders`)

`string.gsub(out, '{(%w+)}', fn)` — the key must be
**alphanumeric only** (`%w+`). A placeholder with an underscore
(`{Player_Name}`) will **not** match and will be left in the text
verbatim.

Per-key handling:

| Key | Behaviour |
|---|---|
| `Amount` | `_cleanAmount(value)`: requires a **string**; `BigNumber.sanitize(raw)`; on failure `'$0'`; else `'$' .. BigNumber.Format(sane)`. A **number** `Amount` returns `'$0'` — the caller must pass the raw BigNumber *string*. |
| `Level` | Must be a `number` **and an integer** (`value == math.floor(value)`), else the fallback `'?'`. |
| `EggName`, `AnimalName`, `Name` | `RichTextFormatter.Entity(value, rarity, fallback)`. Always escaped; rarity-coloured when `data.Rarity` resolves. Fallbacks: `'Egg'`, `'Animal'`, `'item'`. |
| `MutationName` | `RichTextFormatter.Mutation(text, value, 'mutation')`. `text` is the value if it is a string, else `'mutation'`. |
| anything else | `RichTextFormatter.Escape(tostring(value) or '?')` → so a missing value renders as the literal `'?'`. |

The rarity is read from `data.Rarity` (server-resolved) — one rarity
per message by catalog design.

The whole `gsub` is inside a `pcall`. If it throws, `out` keeps the
**unresolved template** and the caller gets the raw `{Placeholder}`
text. (Not observed; `gsub` with a function callback is safe here.)

### SFX (`_playSfx`)

- Requires `player` to be a `Player` **instance** (`typeof(player) ==
  'Instance'` and `IsA('Player')`). A fake table player is rejected →
  **no SFX in tests**.
- `_resolveSfx(name)` looks up `ServerStorage.Assets.Sfx.<name>`:
  - the child may be a `Sound` directly, **or** a folder containing a
    `Sound` (found with `FindFirstChildWhichIsA('Sound', true)`);
  - results are cached in `_sfxCache`; `_sfxCacheValid` marks "attempt
    done" so a miss is **not** re-searched every call;
  - a miss logs `Debug.Warn('NS', 'ServerStorage.Assets.Sfx missing —
    notifications run silent', {asset = name})` **once per name per
    server session** (`_warnedMissing`).
- The clone: `source:Clone()`, renamed `<name>NotifySfx`,
  `Looped = false`, `PlayOnRemove = false`,
  `AudioGroups.AssignSfx(clone)`, `Parent = playerGui`, `Play()`.
- Cleanup: `Debris:AddItem(clone, length + 0.5)` where `length` is
  `clone.TimeLength` when it is a positive finite number, else `2`.
- The clone lives in the **server's** `PlayerGui` instance, so it
  replicates to that client only.
- The whole function is inside a `pcall` → never throws.

---

## Public API surface (exact)

```lua
NotificationService.SetPlayerService(ps: any)                -- no return
NotificationService.GetWarningText(id: any, data: any): string
NotificationService.GetSuccessText(id: any, data: any): string?
NotificationService.NotifyWarning(player: any, id: any, data: any): boolean
NotificationService.NotifySuccess(player: any, id: any, data: any): boolean
NotificationService.ForgetPlayer(userId: number)              -- no return
NotificationService.Init()                                    -- no-op
NotificationService._TestReset()                              -- no return
```

The module table is `table.freeze`d (line 423) — you cannot add fields
at runtime.

Note the naming asymmetry: the two public delivery functions take
`(player, id, data)` while the two text resolvers take `(id, data)`.
The spec calls them with `nil` for `data`, so `data` is effectively
required positionally even though Luau types it `any`.

---

## Invariants the code enforces

1. **A toast is only ever delivered after the authoritative commit.**
   The caller owns that; the service has no ordering knowledge.
2. **Unknown success ids deliver nothing.** Unknown *warning* ids
   deliver `General_Generic`.
3. **`Silent` and `Internal` severities never reach the player.**
4. **Successes are never throttled.** Warnings are.
5. **The wire format is `{Category, Text}`** — `Warning` or `Reward`.
6. **Money is formatted server-side** by `BigNumber`; the client never
   does arithmetic.
7. **Names are always escaped** before they enter the text.
8. **Delivery without a wired `PlayerService` returns `false` and
   never throws.**
9. **One toast per commit**: the caller is expected to call
   `NotifySuccess` exactly once per commit.

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| `player` is `nil` | `key = '?'`; delivery still attempted (`PlayerService.Notify(nil, ...)` will throw inside the `pcall` → `false`). Returns `false`. |
| `playerServiceRef` is `nil` | `_deliver` returns `false` → `NotifyWarning`/`NotifySuccess` return `false`, **no toast, no SFX**. |
| `playerServiceRef.Notify` throws | `pcall` swallows → `_deliver` returns `false` → the public call returns `false`. |
| Unknown warning id | Delivers `General_Generic` text (`"You can't do that right now."`). |
| Unknown / non-string success id | `Debug.Warn`, returns `false`, nothing delivered. |
| `Silent` / `Internal` warning | `Debug.Log('NS', 'suppressed(silent/internal)', ...)`, returns `false`. |
| Missing `Duration` in `Lock_Success` | Renders `'Base locked for ?s!'` — `Duration` is **not** in `_PLACEHOLDER_FALLBACK`. |
| `Amount` passed as a number | `'$0'` (the `Amount` branch requires a string). |
| `Level` passed as a float | `'?'`. |
| Placeholder with an underscore | Not matched; left verbatim in the text. |
| Missing SFX asset | One `Debug.Warn`, then silence for that asset name for the rest of the session. |
| `player` is not a `Player` instance (a fake table) | `_playSfx` returns early — **no SFX**. |

---

## Gotchas that would bite you

- **The spec has an internal contradiction.** Line 95 asserts
  `GetSuccessText('Lock_Success', nil) == 'Base locked for ?s!'`, and
  line 175 asserts that delivering `Lock_Success` produces the text
  `'Base locked!'`. The catalog says `'Base locked for {Duration}s!'`
  and `Duration` is not in the fallback table, so the real delivered
  text is `'Base locked for ?s!'`. **Line 175 is wrong** (the catalog
  is newer). If you fork the system, fix the spec, not the catalog.
- **`_warnedMissing` is not cleared by `_TestReset()`** (which clears
  `_lastReasonAt`, `_burst`, `_sfxCache`, `_sfxCacheValid` only). A
  missing-asset warning fires once per server lifetime.
- **`ForgetPlayer(userId)` clears by string prefix** `"<userId>:"` on
  `_lastReasonAt` and sets `_burst[tostring(userId)] = nil`. It does
  **not** clear the `'?'` bucket, so a nil-player spammer survives
  `ForgetPlayer`.
- **`os.clock()` is used for the throttle**, not `os.time()`. It is
  monotonic and per-server; fine for a 2 s window.
- **The burst cap counts delivered warnings only.** A burst of
  suppressed warnings never fills the budget, so a held-E spammer
  (same id) is throttled by the *same-id* rule, not the burst rule.
- **`GetSuccessText` returns `nil`, not a fallback string.** Callers
  must nil-check.
- **`_deliver` returns `false` if `playerServiceRef.Notify` is falsy**
  — a `PlayerService` stub without a `Notify` field silently disables
  all notifications.
- **The module is frozen.** Cannot monkey-patch `NotificationService`
  for tests; use `SetPlayerService` and `_TestReset`.
- **`SuccessEntry.Sound` is required by the type** (`Sound: string`,
  not optional), but the runtime check also accepts `nil`. `'None'`
  means "no sound".
- **`_PLACEHOLDER_FALLBACK` has only 5 keys.** Any other missing
  placeholder renders as `'?'`.
- **`_resolveSfx` caches a miss.** If the asset is added to
  `ServerStorage` at runtime after the first failed lookup, it will
  not be found.

---

## What to change to reuse it

1. **Replace `ReplicatedStorage/Config/Presentation/Messages.lua`** with
   your own catalog. Keep the two arrays (`Success`, `Warning`) and the
   entry shapes. **Ids are a wire contract** — every caller hard-codes
   them.
2. **Keep the severity vocabulary** (`'Warning'`, `'Silent'`,
   `'Internal'`). The service only checks those three values; an
   unknown severity string behaves like `'Warning'` (delivered).
3. **Extend `_PLACEHOLDER_FALLBACK`** if you want nicer defaults for
   placeholders beyond the five shipped ones.
4. **Keep the wire format `{Category, Text}`** if you want to reuse
   `ToastController` unchanged.
5. **Author `ServerStorage.Assets.Sfx`** with the names your catalog
   references (`Error`, `Approved`, `CashClaim`).
6. **Adjust the three literals** `REASON_WINDOW_S`, `BURST_MAX`,
   `BURST_WINDOW_S` at lines 99-101 to taste.
7. **Only `PlayerService.Notify(player, category, text)` is used** from
   the injected service. Any object with that method works.
8. **`DebugConfig.Audio.Enabled`** gates the extra audio trace line;
   it does not gate playback.
