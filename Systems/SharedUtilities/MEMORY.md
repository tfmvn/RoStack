# SharedUtilities — MEMORY

Engineering notes for a future agent. Dense, specific, grounded in the
code as written. Every line number below is from the files in this
system's `Source/` tree.

---

## 1. Purpose in one line

Five canonical config domains plus six small server-side leaf modules
that the rest of the game depends on: the debug switches, the
locomotion feel, the audio/UI/VFX presentation policy, the server-wide
luck multiplier, the persisted client settings, and four small
resolvers/helpers.

---

## 2. How it actually works, step by step

### 2.1 The debug gating model (`ReplicatedStorage/Utility/Debug`)

This is the spine of the whole system — every module here logs through
it.

1. `Systems/Debug.lua` holds the canonical flags. It is
   `table.freeze`d, so **nothing can flip it at runtime**.
2. At boot, `bootstrap.server.lua:39` calls
   `Debug.SyncFromDebugConfig(DebugConfig)`. The client bootstrap does
   the same on its own side.
3. `Debug.SyncFromDebugConfig` copies `ServerDebug`, `ClientDebug`,
   `Tags` and `DrawPaths` into the module's mirrors. **A missing flag
   fails QUIET** — an absent switch never enables noise. Only
   `ServerDebug`/`ClientDebug`/`Tags`/`DrawPaths` are read; every
   other field on `Systems.Debug` (`Subsystem`, `SkipPersistence`,
   `AllowStudioTestUserIds`, `ConfigValidation`, `Audio`) is read
   **directly by the code that owns it**, not by the `Debug` module.
4. `Debug.IsEnabled(tag)`:
   - Side detection is owned by the `Debug` module itself
     (`IS_CLIENT = RunService:IsClient()` evaluated **once at require
     time**). Callers never branch on side.
   - The client side checks `ClientDebugEnabled`; the server side
     checks `ServerDebugEnabled`. **The two switches are completely
     independent.**
   - Then the tag whitelist: `if tag and next(AllowedTags) ~= nil then
     return AllowedTags[tag] == true end`. The whitelist applies
     **only when the table is non-empty**. An empty `Tags = {}` means
     "all enabled tags print".
5. `Debug.Log` / `Debug.Warn` build a string and `print` / `warn` it.
   The message is coerced with `_safeMessage` (a non-string message is
   `tostring`-ed; an unprintable one becomes `'<unprintable>'`) and
   the data table with `_safeData` (a non-table becomes `nil`, so the
   fields are omitted). **A malformed debug call never throws into
   gameplay.**
6. Output format: `[TAG] message key=value, key=value`. The data
   table is stringified with `tostring` — deliberately **not**
   `HttpService:JSONEncode`, to keep the module dependency-free.

**Tags this system uses:** `LUCK` (ServerLuckService), `Settings`
(SettingsService), `IN` (MoneyIcon), `MI` (MutationIcon), `Water`
(WaterHazard), `BS` (the bootstrap).

**The `Debug` module is NOT frozen** — `Debug.DrawPaths` is a
mutable module field, and `Debug.SetEnabled(enabled)` flips the
**current side's** switch for the Studio command bar and unit tests.
`Debug.AllowedTags` is also assignable.

### 2.2 The config validation contract

1. Every config domain exposes `Validate(): { string }` — an empty
   array means valid.
2. `ConfigValidator._MODULES` is the registry. Each entry is
   `{ Name, Path = { folder segments }, Sub = optional subsection }`.
   `Path` is walked from `ReplicatedStorage.Config` with
   `WaitForChild`; `Sub` selects a nested table (e.g. `Rewards.Codes`).
3. `ConfigValidator.ValidateAll()` runs every registered domain's
   `Validate()` inside a `pcall`. A domain that fails to **require**
   produces `<Name>: require failed: <err>`. A domain whose
   `Validate()` **crashes** produces `<Name>.Validate() crashed:
   <err>`. A domain that returns a table contributes each of its
   strings, prefixed with the domain name.
4. `ConfigValidator._checkInvariants()` runs the **cross-config**
   rules — ladders, joins and preserved-baseline pins. It is also
   `pcall`-guarded; a crash becomes
   `'INVARIANT check crashed: <err>'`.
5. `ConfigValidator.Report(issues)` formats the standard block.
6. `ConfigValidator.AssertValid()` **errors** with the full report if
   there is at least one issue.
7. The bootstrap wraps `AssertValid()` in its own `pcall` and then
   **splits on the environment**: in Studio it re-raises
   (`error(tostring(validateErr), 0)`), on a live server it only
   `warn`s. A bad tune must never hard-crash production.

**This system's domains and their registered names:**

| Registered name | Path | Sub | Validator function |
|---|---|---|---|
| `World.Movement` | `World/Movement` | — | `Movement.Validate` |
| `World.Movement.Player` | `World/Movement` | `Player` | `Movement.Player.Validate` |
| `Systems.Debug` | `Systems/Debug` | — | `Debug.Validate` |
| `Presentation.Audio` | `Presentation/Audio` | — | `Audio.Validate` |
| `Presentation.Vfx` | `Presentation/Vfx` | — | `Vfx.Validate` |
| `Presentation.UI.Overhead` | `Presentation/UI` | `Overhead` | `UI.Overhead.Validate` |

`Presentation.UI` (root) and `Presentation.UI.Notify` have **no**
`Validate()`. The validator's contract explicitly exempts
presentation-only domains without rules.

### 2.3 `ServerLuckService` — the luck state machine

**State (three pieces):**

| State | Meaning |
|---|---|
| `_baseLuck` (number) | The admin-set base multiplier. Default `1`. |
| `_boost` (`{ mult, expiresAt, version }` or `nil`) | The active temporary boost. `expiresAt` is an **`os.clock()`** deadline. |
| `_version` (number) | A monotonic counter; each `ActivateBoost` increments it and stamps the boost with it. |

**Reading the effective luck:**

```
GetLuck():
  _reapStaleBoost()      -- if _boost and os.clock() >= _boost.expiresAt then _boost = nil
  if _boost then return _boost.mult end
  return _baseLuck
```

`_reapStaleBoost` makes the read **self-healing**: an expired boost
reads as the base even if its expiry task has not run yet. It never
yields and never throws.

**`SetLuck(mult)` — the admin path:**
- Rejects a non-number, `NaN`, `±math.huge` → `false`.
- Rejects `mult <= 0` or `mult > MAX_LUCK` (1000000) → `false`.
- If `mult == _baseLuck and _boost == nil` → returns **`true`**
  without publishing (a no-op change is still a success).
- Otherwise sets `_baseLuck = mult` and **cancels the boost**
  (`_boost = nil`). The admin wins immediately and deterministically.
- Publishes and returns `true`.

**`ActivateBoost(mult, durationSecs, source)` — the purchase path:**
- Rejects a non-number / `NaN` / `±inf` multiplier → `nil`.
- Rejects `mult < 1` or `mult > MAX_LUCK` → `nil`. **Note the
  asymmetry with `SetLuck`: a boost cannot be below 1x, but the base
  can (`SetLuck(0.5)` is legal).**
- Rejects a non-number / `NaN` duration, `durationSecs < 1`, or
  `durationSecs > MAX_BOOST_DURATION_S` (86400 = 24 h) → `nil`. A
  duration above the cap is rejected as a **configuration error, not
  clamped**.
- Increments `_version`, stores
  `_boost = { mult, expiresAt = os.clock() + durationSecs, version }`,
  publishes, and returns the version token.
- Schedules `task.delay(durationSecs, ...)` for the expiry.

**Replacement, not stacking.** A new purchase replaces the current
multiplier **and** its duration. The old boost's expiry task is
**not** cancelled — instead the expiry task re-reads `_boost` and
compares `b.version ~= token`. A stale token returns early and does
**not** clear the new luck. This is the version gate, and it is the
only thing standing between a superseded purchase and a wrong
expiry.

**Expiry:**
1. The task reads `_boost`; if it is `nil` or the version does not
   match, it returns (stale).
2. Otherwise it captures `expiredMult`, clears `_boost`, publishes,
   and fires every registered expiry listener with
   `{ expiredMult, version }`.
3. Each listener is `pcall`-ed — a throwing listener does not stop
   the others.

**`ApplyLuck(weights, luckOverride?)` — the weight transform:**

```
out = {}                      -- a COPY; the input is never mutated
luck = luckOverride if it is a number else GetLuck()
if luck is not a finite number in (0, MAX_LUCK] then luck = 1
divisor = RarityConfig.LuckExponentDivisor
if divisor is not a finite number > 0 then divisor = 3
tierIndex = { [rarity] = i - 1 }  for i, rarity in ipairs(LUCK_POOL)
for rarity, w in pairs(weights):
    base = tonumber(w) or 0
    if tierIndex[rarity] then
        out[rarity] = base * (luck ^ (tierIndex[rarity] / divisor))
    else
        out[rarity] = base     -- NON-POOL KEYS PASS THROUGH UNSCALED
```

The curve is `weight * luck^(tierIndex / 3)`, so `luck = 1` is the
**identity** and the canonical config weights are untouched at 1x.

`LUCK_POOL` is `Events.LuckPoolOrder` —
`{ Common, Uncommon, Rare, Epic, Legendary, Mythic }` — so the tier
indices are Common 0, Uncommon 1, Rare 2, Epic 3, Legendary 4,
**Mythic 5**. At the top tier the weight scales by `luck^(5/3)`.
This is deliberately **not** `Rarity.Order`, which canonically sorts
Mythic *below* Legendary — luck must favour Mythic most.

`Divine` and `Secret` are **not** in the pool, so their weights pass
through unscaled. Their normal weights are `0`, and `0 × anything`
stays `0` — they can never be rolled at any luck. That is a
**structural** guarantee, not a tuning accident.

**Replication:** no new remotes. The current value is published as the
`ServerLuck` attribute on `ReplicatedStorage` on every change and
once at `Init`. Late joiners read the attribute; live clients watch
it with `GetAttributeChangedSignal`. The attribute is the **only**
thing a client may read; `GetLuck()` is the only thing server code
may read.

### 2.4 `SettingsService` — the settings store

**Authority model:** `profile.Data.Settings` is the single source of
truth. The shape default lives in `PlayerService`. The server never
plays sounds for settings and never reads them for gameplay.

**`sanitize(settings)`** — the one sanitiser, used on both read and
write:

```
out = { Bgm = 1, Sfx = 1, FastMode = false }
if settings is not a table then return out end
if type(settings.Bgm) == 'number' and settings.Bgm == settings.Bgm then
    out.Bgm = math.clamp(settings.Bgm, 0, 1) end
if type(settings.Sfx) == 'number' and settings.Sfx == settings.Sfx then
    out.Sfx = math.clamp(settings.Sfx, 0, 1) end
if type(settings.FastMode) == 'boolean' then
    out.FastMode = settings.FastMode end
return out
```

Note the `NaN` guard (`v == v`) — `math.clamp(NaN, 0, 1)` would
propagate the NaN. A non-boolean `FastMode` falls back to `false`.

**`GetSettings(userId)`** reads `PlayerService.GetPlayerData(userId)`
inside a `pcall`, then sanitizes `data.Settings`. A missing profile or
a non-table `data` yields the **default** shape, not `nil`. The
returned table is always a **fresh copy** — the live profile table is
never handed out.

**`PushSettings(player)`** — guarded by `Validation.LivePlayer(player)`
(a `Player` with a non-nil `Parent`), then fires `SettingsState` to
that one client with the sanitized state.

**The `SaveSettings` handler** (`onSave`):
1. `Validation.LivePlayer(player)` — a dead/removed player is ignored.
2. A non-table payload is ignored.
3. `PlayerService.GetPlayerData(userId)` inside a `pcall`; a
   non-table result is ignored.
4. `data.Settings = sanitize(payload)` — the write.
5. A `Debug.Log('Settings', 'saved', {...})` line.

**`Init()`** is idempotent (`_wired` latch). It waits up to **10
seconds** for the `SaveSettings` remote
(`Remotes.GetFolder():WaitForChild(Remotes.Names.SaveSettings, 10)`).
If the remote is missing it **warns** (`'SaveSettings remote missing;
settings will not persist'`) and continues — the rest of the game
still boots.

**`ForgetPlayer(userId)`** is a deliberate **no-op** with a comment
explaining why: the service is stateless, there is no per-player cache
to drop. It exists so the bootstrap can call it uniformly.

### 2.5 `MoneyIcon.Resolve()` — the fresh-per-call asset resolver

1. Builds a container list: `ServerStorage.Assets` (if it exists),
   then `ReplicatedStorage.Assets` (if it exists). **ServerStorage
   first.**
2. For each container, finds `Decals` then `MoneyIcon`.
3. The node must be an **`ImageLabel`** and its `Image` must be a
   **non-empty string** — anything else is treated as missing.
4. On a hit it builds a plain config table:
   `{ Image, RectOffset = {X,Y}, RectSize = {X,Y}, ScaleType,
     SliceCenter = {MinX,MinY,MaxX,MaxY}, SliceScale,
     Color = {R,G,B}, Transparency, BgTransparency }`.
   Every optional field is individually `pcall`-guarded, so a
   property that fails to read simply omits that field.
5. It `break`s on the first hit — ServerStorage wins.
6. If nothing was found, it warns **once per server process**
   (`warnedMissingIcon` latch) with the tag `'IN'`: *"Assets.Decals.MoneyIcon
   ImageLabel missing/unpopulated — HUD pooling uses fallback chip"*.
7. Returns the config table or `nil`.

**Why it exists:** the client cannot read `ServerStorage` (a
`LocalScript` cannot touch it), and the client must not hardcode an
asset id. The config table travels in the `CashCollected` payload, so
the client applies whatever the server resolved. Because the resolve
is fresh-per-call, retargeting `MoneyIcon.Image` in Studio takes
effect on the **next grant**, with no code change.

**Consumers:** `IncomeService:675`, `CodesService:721`,
`DailyRewardsService:607`, `PlaytimeRewardsService:621` — all put it
in an `Icon = MoneyIcon.Resolve()` field.

### 2.6 `MutationIcon` — the canonical mutation→decal map

```
DECAL_BY_MUTATION = {
    Galactic = 'GalaxyIcon',
    Frost    = 'SnowfallIcon',
}
```

**`DecalNameFor(mutationId)`** returns the name for a string id, or
`nil` for a non-string or an unmapped id. **No invented assets, no
crash.**

**`ResolveImage(mutationId)`**:
1. `DecalNameFor` → `nil` means the `pcall` body returns early, so
   `image` stays `nil`. **The warning still fires** — the warn block
   is *outside* the `pcall`, so an unmapped id is warned about too.
2. Walks `ServerStorage.Assets.Decals.<name>` then
   `ReplicatedStorage.Assets.Decals.<name>`. Must be an `ImageLabel`
   with a non-empty `Image` string.
3. On any miss it warns **once per mutation id** (`_warnedMissing` is a
   set keyed by `tostring(mutationId)`), tag `'MI'`: *"mutation decal
   missing/unpopulated — overhead keeps prototype visuals"*.
4. Returns the image string or `nil`.

**`PaintIcon(host, mutationId)`**:
1. `host` must be an `Instance`, else `false`.
2. Resolves the image; `nil` means `false` (the caller keeps the
   prototype's authored visuals).
3. The target is the host itself if it is an `ImageLabel`, otherwise
   the **first descendant** that is an `ImageLabel`
   (`FindFirstChildWhichIsA('ImageLabel', true)`).
4. Sets `target.Image = image` and returns `true`.

**Important:** painting applies **only to freshly cloned generic
icons**. A Studio-authored per-id icon child (a `Galactic`/`Frost`
node already living in the template's `Mutations` container) is never
touched — authored art always wins, and the decal mapping is the
fallback.

**Consumers:** `EggOverhead:322` and `AnimalOverhead:772`, both
calling `pcall(MutationIcon.PaintIcon, clone, id)`.

### 2.7 `PathfindingUtil` — the animal pathfinder's agent

The module holds three things and one helper:

- `AgentParams = { AgentRadius 4, AgentHeight 5, AgentCanJump false,
  AgentCanClimb false, WaypointSpacing 6 }` — the animal agent. The
  animal model footprint is ~4×5×2 studs. The rationale is written
  into the module header:
  - `AgentRadius` 4 (was 2): a 2-stud agent treats the animal as a
    thin pillar, routes it through gaps the model physically cannot
    fit through, and the walk visibly clips into walls.
  - `AgentCanJump` false (was true): with jump enabled the
    pathfinder takes 4-stud "jump" links to cross small Y gaps,
    producing sideways-then-up approaches. The animal is on the
    ground and should route over ramps and stairs, not jump links.
    If a gap is non-traversable without a jump, the pathfinder should
    **refuse** and the walker falls through to its teleport-arrive
    path.
  - `WaypointSpacing` 6 (was 4): a slightly longer polyline, so the
    LOS simplification in `WalkController` can drop more redundant
    interior waypoints.
- `YawSmoothing` — **assigned at require time** from
  `ReplicatedStorage.Config.World.Movement.YawSmoothing` (8.0). It is
  a **copy**, not a live reference.
- `MaxWalkSeconds = 60` — **backwards-compat only**. The walker uses a
  duration-based cap now. Nothing in the codebase reads it.

**`ShortestAngleDelta(from, to)`**:
```
delta = (to - from) % (2 * math.pi)
if delta > math.pi then delta = delta - 2 * math.pi end
return delta
```
It returns the shortest signed turn in `(-pi, pi]`, avoiding the
"spin the long way around" bug when the delta crosses ±pi. The
`%` on a positive divisor in Lua always returns a non-negative result,
so the single `> math.pi` correction is sufficient.

**Consumers:** `Animal/WalkController.lua:295` (uses `AgentParams`)
and `:604` (uses `ShortestAngleDelta`); `Egg/FlightController.lua:534`
(uses `ShortestAngleDelta`).

### 2.8 `WaterHazard.Init()` — instant-death water

1. `_wired` latch → a second call is a no-op.
2. Finds `Workspace:FindFirstChild('Water')`.
3. If found, `_wire(water)`:
   - If the node is a `BasePart` → **one** `Touched` connection.
   - Otherwise → **one connection per descendant `BasePart`**. (Note:
     the node itself is NOT included in the descendant sweep, so a
     `Model` water that is also a `BasePart` would be missed — but an
     instance cannot be both.)
4. If not found, it **warns** and falls through to the retry.
5. Connects `Workspace.ChildAdded` and, if a **direct child of
   `Workspace` named exactly `Water`** appears, wires it. This is the
   late-added-water path.

**The `Touched` handler:**
```
character = hit.Parent
humanoid = character and character:FindFirstChildOfClass('Humanoid')
if humanoid then humanoid.Health = 0 end
```
The humanoid is found on the touched instance's **parent**. It sets
`Health = 0` — the standard Roblox death, so the normal death/respawn
flow runs.

**It is server-authoritative:** a client cannot spoof a `Touched`
event into sparing itself. There is no owner check, no grace period
and no exception for the player's own carried animal.

### 2.9 The five config domains

Each is a plain `table.freeze`d module with a `Validate()`.

**`Systems.Debug`** — the switches. `ServerDebug` and `ClientDebug`
are independent booleans, both `false`. `Tags` is an optional
whitelist. `DrawPaths` (false), `SkipPersistence` (false),
`AllowStudioTestUserIds` (**true**), `ConfigValidation` (true),
`Subsystem` (nine flags, all false) and `Audio = { Enabled = false }`.
`Validate()` checks: `ServerDebug` is a boolean, `ClientDebug` is a
boolean, `Tags` is a table, every `Subsystem.*` is a boolean,
`ConfigValidation` is a boolean. It does **not** validate
`DrawPaths`, `SkipPersistence`, `AllowStudioTestUserIds` or `Audio`.

**`World.Movement`** — locomotion feel. `YawSmoothing = 8.0` is the
single source for three consumers (WalkController, FlightController,
PathfindingUtil) that each used to hardcode `8.0`. `AnimalWalk`,
`EggFlight` and `StandIdle` are the per-system sub-tables;
`Movement.Player` holds `WalkSpeed = 20` and `JumpPower = 50` and is
`table.freeze`d separately. `Movement.Validate()` checks four
fields: `YawSmoothing > 0`, `AnimalWalk.AnimationBaseSpeed > 0`,
`EggFlight.MaxClimbAboveStart >= 0`, `StandIdle.TickRate > 0`.
`Movement.Player.Validate()` checks `WalkSpeed > 0` and
`JumpPower >= 0`. **Most fields are unvalidated** — the `EggFlight`
agent params, the EMA gains, the settle threshold, the epsilon
deadbands and the clone-padding clamps are all unchecked.

**`Presentation.Audio`** — policy, not curves. Volumes and rolloff
are **authored on the Sound instances** in Studio and this module does
not duplicate them. `Validate()` checks only
`StealAlertSoundName` (a non-empty string) and `Collect.PoolSize`
(>= 1).

**`Presentation.UI`** — the largest. `RarityColor` is an **alias**
to `Rarity.RarityColor` (read from `Creatures/Rarity.lua`), never a
copy. Font/TextSize/Color tokens, the HUD layout, the slot-row
sizing, the toast sizing, `UI.Notify` (timing, coalescing, the text
cap, the four categories and their colours, and the two motion
specs), and `UI.Overhead` (trait colours, mutation colours, the
fallback colour, the stolen-text colour, and the rainbow animation).
`UI.Notify` and `UI.Overhead` are `table.freeze`d separately from
`UI`. Only `UI.Overhead.Validate()` exists — it checks the four
named colours are `Color3`s and that `Rainbow.Period > 0`.
`UI.Notify` has **no** validator.

**`Presentation.Vfx`** — `LevelUp` (lifetime, cleanup cap, clone
cleanup, burst, the scale throttle, the full bop choreography, the
tilt), `EggRoll` (sizes, fallback colours, burst, cleanup) and
`Hygiene` (the debug path colours and marker size — diagnostic only).
`Validate()` checks only `LevelUp.Lifetime > 0` and
`LevelUp.CleanupCap > 0`. **Everything else is unchecked** — the bop
timings, the burst clamps, the egg-roll sizes, the hygiene colours.

---

## 3. The exact public API surface

### `ServerLuckService`

```lua
local ServerLuckService = require(ServerScriptService.ServerLuckService)
```

| Function | Signature |
|---|---|
| `Init` | `(): ()` |
| `GetLuck` | `(): number` |
| `DefaultLuck` | `(): number` |
| `SetLuck` | `(mult: any): boolean` |
| `MaxLuck` | `(): number` |
| `ResetLuck` | `(): boolean` |
| `ActivateBoost` | `(mult: any, durationSecs: any, source: any): number?` |
| `GetBoostInfo` | `(): any?` |
| `OnBoostExpired` | `(fn: (any) -> ()): ()` |
| `ApplyLuck` | `(weights: { [string]: number }, luckOverride: number?): { [string]: number }` |
| `_TestReset` | `(): ()` |

### `SettingsService`

```lua
local SettingsService = require(ServerScriptService.SettingsService)
```

| Function | Signature |
|---|---|
| `Init` | `(): ()` |
| `GetSettings` | `(userId: number): { Bgm: number, Sfx: number, FastMode: boolean }` |
| `PushSettings` | `(player: Player): ()` |
| `ForgetPlayer` | `(_userId: number): ()` |

### `MoneyIcon`

```lua
local MoneyIcon = require(ServerScriptService.Utility.MoneyIcon)
```

| Function | Signature |
|---|---|
| `Resolve` | `(): { [string]: any }?` |

### `MutationIcon`

```lua
local MutationIcon = require(ServerScriptService.Utility.MutationIcon)
```

| Function | Signature |
|---|---|
| `DecalNameFor` | `(mutationId: any): string?` |
| `ResolveImage` | `(mutationId: any): string?` |
| `PaintIcon` | `(host: Instance?, mutationId: any): boolean` |

### `PathfindingUtil`

```lua
local PathfindingUtil = require(ServerScriptService.Utility.PathfindingUtil)
```

| Function | Signature |
|---|---|
| `ShortestAngleDelta` | `(from: number, to: number): number` |

Data fields: `AgentParams`, `YawSmoothing`, `MaxWalkSeconds`.

### `WaterHazard`

```lua
local WaterHazard = require(ServerScriptService.Utility.WaterHazard)
```

| Function | Signature |
|---|---|
| `Init` | `(): ()` |

### The config domains

```lua
local DebugConfig    = require(ReplicatedStorage.Config.Systems.Debug)
local Movement       = require(ReplicatedStorage.Config.World.Movement)
local AudioConfig    = require(ReplicatedStorage.Config.Presentation.Audio)
local UIConfig       = require(ReplicatedStorage.Config.Presentation.UI)
local VfxConfig      = require(ReplicatedStorage.Config.Presentation.Vfx)
```

| Member | Signature |
|---|---|
| `DebugConfig.Validate` | `(): { string }` |
| `Movement.Validate` | `(): { string }` |
| `Movement.Player.Validate` | `(): { string }` |
| `AudioConfig.Validate` | `(): { string }` |
| `UIConfig.Overhead.Validate` | `(): { string }` |
| `VfxConfig.Validate` | `(): { string }` |

---

## 4. Invariants and rules the code enforces

1. `Debug` output is **off by default on both sides** and the two
   switches are **independent**.
2. The `Debug` tag whitelist applies **only when `Tags` is
   non-empty**.
3. `Debug` never throws into gameplay — a malformed message or data
   table degrades to a safe rendering.
4. `Debug` side detection is decided **once, at require time**, by the
   `Debug` module — never by the caller.
5. `Debug.SyncFromDebugConfig` fails **quietly** — an absent switch
   never enables noise.
6. A config domain with no `Validate()` is **exempt** from the
   validator; a domain whose `Validate()` crashes is reported, not
   fatal.
7. `ConfigValidator.AssertValid()` **errors**; the bootstrap turns
   that into a hard error **in Studio only** and a warn on a live
   server.
8. `ServerLuckService` never persists anything. No profile, no
   DataStore.
9. `luck = 1` is the **identity** of `ApplyLuck` — the canonical
   config weights are unchanged at 1x, and `ApplyLuck` never mutates
   its input.
10. `Divine` and `Secret` weights are **always exactly 0** — they are
    not in the luck pool, so they pass through unscaled.
11. A boost **replaces** — it never stacks and never multiplies.
12. The boost version gate: a superseded boost's expiry **must not**
    clear a newer boost.
13. `SetLuck` (admin) **cancels** any active boost immediately.
14. `GetLuck` is **self-healing** — an expired boost reads as the
    base even before its expiry task runs.
15. A boost multiplier is `>= 1`; the base multiplier may be any
    positive value `> 0` (fractionals allowed).
16. A boost duration must be `>= 1` second and `<= 86400` seconds —
    rejected, **never clamped**.
17. `MAX_LUCK = 1000000` is **rejected**, not clamped.
18. The luck is published **only** as the `ServerLuck`
    ReplicatedStorage attribute — the service adds **no** remotes.
19. `Settings` are sanitized on **every** read and **every** write,
    and the returned table is always a copy.
20. `FastMode` is strictly boolean; a non-boolean falls back to
    `false`.
21. `Bgm` and `Sfx` are clamped to `[0, 1]`; a `NaN` falls back to
    the default `1`.
22. `SettingsService` holds **no** per-player state — hence the
    no-op `ForgetPlayer`.
23. `MoneyIcon` / `MutationIcon` read `ServerStorage` **first**, then
    `ReplicatedStorage`.
24. Only an `ImageLabel` with a **non-empty** `Image` string counts as
    a valid decal source.
25. `MutationIcon` paints **only freshly cloned generic icons** — a
    Studio-authored per-id icon is never touched.
26. `MutationIcon.DecalNameFor` returns `nil` for an unknown id — it
    never invents an asset name.
27. `PathfindingUtil.AgentParams.AgentCanJump` is **false** — the
    pathfinder must refuse a non-traversable gap rather than jump it.
28. `WaterHazard` is **server-authoritative** — the server decides
    death.
29. `WaterHazard` connects **one** `Touched` handler per `BasePart`,
    connected once at boot.
30. `Movement.YawSmoothing` is the **single source** for the yaw
    rate of all three walkers.
31. `UI.RarityColor` is an **alias** to the rarity config, never a
    copy.
32. The rainbow gradient's first and last stops are the **same
    colour**, so the wrap is seamless.

---

## 5. Failure and edge-case behaviour

| Situation | What happens |
|---|---|
| `Debug.ServerDebug` is `false` | Every `Debug.Log`/`Warn` on the server returns after two boolean checks. No allocation, no string concat. |
| `Debug.Tags` is `{}` | The whitelist is skipped — every enabled tag prints. |
| `Debug.Tags` is non-empty and the tag is absent | That tag is silenced. |
| `Debug.Log` is called with a non-string message | `_safeMessage` `tostring`s it. A value that cannot be printed becomes `'<unprintable>'`. |
| `Debug.Log` is called with a non-table data | The fields are omitted; only the message prints. |
| `Debug.SyncFromDebugConfig` is called with a non-table | It returns immediately; the switches are untouched. |
| `Debug.SyncFromDebugConfig` is called with a missing `ServerDebug` | The switch is untouched — **not** enabled. |
| A config domain's `Validate()` throws | `ValidateAll()` reports `'<Name>.Validate() crashed: <err>'`. The other domains still run. |
| A config domain cannot be required | `ValidateAll()` reports `'<Name>: require failed: <err>'`. |
| A cross-config invariant check throws | One issue: `'INVARIANT check crashed: <err>'`. |
| `AssertValid()` with issues | Raises an error whose message is the full report. |
| The bootstrap's `AssertValid()` fails in **Studio** | The bootstrap re-raises it — a **hard error**. The server does not boot. |
| The bootstrap's `AssertValid()` fails on a **live server** | A `warn` only. The server boots with the bad tune. |
| `SetLuck(0)`, `SetLuck(-3)`, `SetLuck('4')`, `SetLuck(nil)`, `SetLuck(NaN)`, `SetLuck(±inf)`, `SetLuck(MAX_LUCK+1)` | `false`. The state is **unchanged**. |
| `SetLuck(v)` where `v == _baseLuck` and there is no boost | `true`, and **nothing is published** (a no-op change is a success). |
| `SetLuck(v)` while a boost is active | The base is set, the boost is **cancelled**, `true` is returned. |
| `ActivateBoost` with a multiplier `< 1` | `nil`. The state is unchanged. |
| `ActivateBoost` with a duration `< 1` or `> 86400` | `nil`. The state is unchanged. |
| A newer boost supersedes an older one | The newer one wins. The older expiry task fires, sees the version mismatch, and **returns without clearing anything**. |
| `GetBoostInfo()` with an expired boost | `nil`. The stale boost is reaped on the way out. |
| `GetBoostInfo()` with no boost | `nil`. |
| `GetBoostInfo()` on a live boost | `{ mult, remainingSecs, version }`. **`remainingSecs` is computed from `os.clock()`** — CPU time — so it does not track the wall-clock `task.delay` that actually expires the boost. On an idle server it over-reports. |
| An expiry listener throws | It is `pcall`-ed; the other listeners still fire. |
| `OnBoostExpired(nil)` | Ignored — only a `function` is appended. |
| `ApplyLuck` with a non-table `weights` | An empty table `{}`. |
| `ApplyLuck` with a `luckOverride` that is out of range | Falls back to `DEFAULT_LUCK` (1). |
| `ApplyLuck` with a degenerate `LuckExponentDivisor` | Falls back to `3`. |
| `ApplyLuck` with a non-numeric weight | `tonumber(w) or 0` → `0`. |
| `ApplyLuck` on a key outside the luck pool | The weight passes through **unscaled**. |
| `GetSettings` with no loaded profile | The default shape `{ Bgm = 1, Sfx = 1, FastMode = false }`. |
| `GetSettings` with a corrupt `data.Settings` | The default shape. |
| `PushSettings` with a player whose `Parent` is nil | Ignored (the `Validation.LivePlayer` gate). |
| The `SaveSettings` remote is missing | `Init()` waits 10 s, then warns `'SaveSettings remote
   missing; settings will not persist'`. The game still boots. |
| A client sends a garbage `SaveSettings` payload | Ignored — a non-table payload, or a payload that produces no valid profile, is dropped. |
| `MoneyIcon.Resolve()` with no decal | `nil`, plus **one** warning for the server's lifetime. |
| `MoneyIcon.Resolve()` with a decal that is not an `ImageLabel` | Treated as missing. |
| `MoneyIcon.Resolve()` with an `Image` of `''` | Treated as missing. |
| `MutationIcon.ResolveImage('Ancient')` | `nil`, plus one warning for that id. No asset is invented. |
| `MutationIcon.PaintIcon` with a host that is not an `Instance` | `false`. |
| `MutationIcon.PaintIcon` with a container that has no `ImageLabel` | `false`. The prototype keeps its authored visuals. |
| `PathfindingUtil.ShortestAngleDelta` across ±pi | Returns the short way round, in `(-pi, pi]`. |
| `WaterHazard.Init()` with no `Workspace.Water` | A warning, and the `ChildAdded` retry is armed. The hazard is inactive until a `Water` appears. |
| `Workspace.Water` is added later | It is wired when it is added — but **only** as a direct child of `Workspace` named exactly `Water`. |
| `Workspace.Water` is a `Model`/`Folder` | One connection per descendant `BasePart`. |
| Something with a Humanoid touches the water | `Health = 0`. |

---

## 6. Gotchas that would bite you

1. **`ServerLuckService` is initialised from `EggService.Init`, not
   from the bootstrap.** `bootstrap.server.lua` never calls
   `ServerLuckService.Init()`. If you install the service without an
   `EggService`, the `ServerLuck` attribute never appears.
2. **The luck pool order lives in ANOTHER system's config.**
   `ServerLuckService.lua:31` does
   `require(ReplicatedStorage.Config.World.Events)`. Delete the Events
   system and the luck roll breaks with a require error.
3. **`Events.LuckPoolOrder` is NOT `Rarity.Order`.** `Rarity.Order`
   sorts Mythic below Legendary. The luck pool deliberately favours
   Mythic most — the tier index of Mythic must be the **highest** or
   the whole curve inverts.
4. **`ServerLuckService` uses `os.clock()`, not `os.time()`.**
   In Luau, `os.clock()` returns **CPU time**, not wall time. The
   boost expiry deadline is therefore measured in CPU seconds, while
   the actual expiry is driven by `task.delay(durationSecs, ...)`,
   which IS wall time. The two disagree: the `task.delay` fires on
   schedule, but `_boost.expiresAt` — the value `GetBoostInfo` uses
   for `remainingSecs` and that `_reapStaleBoost` compares against —
   is on a different clock. On an idle server the CPU clock barely
   advances, so `remainingSecs` reads far too high and the stale
   boost is only reaped once `task.delay` fires. This is the shipped
   behaviour; the boost spec only locks the state machine and never
   asserts the timing. Treat the wall-clock/CPU-clock mismatch as a
   **latent defect** to be aware of, not something to "fix" casually
   — changing it changes the expiry semantics.
5. **A boost cannot be below 1x, but the base can.** `SetLuck(0.5)`
   is legal; `ActivateBoost(0.5, ...)` returns `nil`. The spec
   asserts this asymmetry.
6. **`SetLuck` cancels a boost.** If you call `SetLuck` "just to read
   the current value", you will silently kill an active purchase
   boost. Use `GetLuck()` to read.
7. **`GetBoostInfo` and `GetLuck` disagree in one case.** After a
   boost expires but before its expiry task runs, `GetLuck` returns
   the base (it reaps), and `GetBoostInfo` returns `nil` (it checks
   the deadline). Both are correct.
8. **`ApplyLuck` with `luckOverride` does NOT publish.** The override
   is a pure computation input. Only `SetLuck` and `ActivateBoost`
   publish.
9. **`ApplyLuck` returns a NEW table every call.** The canonical
   config is never mutated, but you also never get a cached result —
   this is a hot path in the egg roll.
10. **`Debug`'s tag whitelist is skipped when `Tags` is `{}`.** It is
    easy to read "when non-empty, only tags in this set print" as
    "an empty set prints nothing". It prints **everything**.
11. **The `Debug` tag whitelist is per-side-independent but
    per-tag-shared.** The same `Tags` table gates both sides; a tag
    that is on the server is on the client.
12. **The `Tags` comment in `Systems/Debug.lua` is out of date.** It
    lists `BS, LB, BR, PS, RM, CL, AO, CP` and does not mention
    `LUCK`, `Settings`, `IN`, `MI` or `Water`. With a non-empty
    whitelist, this system's modules are silent.
13. **`Systems.Debug` is `table.freeze`d, so you cannot flip a flag
    at runtime.** That is why `StudioTestMode` exists as a separate,
    deliberately **unfrozen** module. If you need a runtime switch,
    follow that pattern.
14. **`StudioTestMode.Enabled` is seeded from the config at boot**
    (`bootstrap.server.lua:63`) and is then **mutable**. A published
    server is still safe because `IsEnabled()` also requires
    `RunService:IsStudio()`.
15. **`Debug.SkipPersistence` is not gated on `IsStudio()` in the
    config.** The gate is in `PlayerService`. Shipping it `true`
    means nothing is ever saved.
16. **`Debug.DrawPaths` creates real Instances in the Workspace** and
    is not gated either. It is off by default.
17. **`Movement.Player` is `table.freeze`d separately from
    `Movement`.** `Movement` is frozen at the end of the file, and
    `Movement.Player` is frozen just before that. Both are immutable.
18. **`Movement.YawSmoothing` is a copy in `PathfindingUtil`, not a
    reference.** `PathfindingUtil.YawSmoothing` is assigned at require
    time. Changing `Movement.YawSmoothing` later changes the two
    walkers (which read the config directly) but **not**
    `PathfindingUtil`. The three can silently disagree.
19. **`PathfindingUtil.MaxWalkSeconds` is dead code.** Kept for
    external callers only. Do not wire anything to it.
20. **`PathfindingUtil.AgentParams.AgentCanJump = false` is
    deliberate and load-bearing.** Turning it on reintroduces the
    sideways-then-up pathfinding behaviour the module header
    describes.
21. **`MoneyIcon.Resolve()` re-walks the instance tree on every
    call.** That is the design (a Studio retarget takes effect
    immediately), but it is a per-grant instance walk. Do not call it
    in a tight loop.
22. **`MoneyIcon` warns only once, ever.** The latch is not reset,
    even by `_TestReset` (there is none). A missing icon produces
    exactly one warning per server process.
23. **`MoneyIcon` reads `ServerStorage` first.** If you have a
    `MoneyIcon` in **both** `ServerStorage.Assets.Decals` and
    `ReplicatedStorage.Assets.Decals`, the ServerStorage one wins and
    the other is silently ignored.
24. **`MoneyIcon`'s resolved config is a SNAPSHOT.** It travels in
    the payload; the client applies what was resolved at grant time.
    A change mid-flight is not seen.
25. **`MutationIcon`'s docstring says `GalaxyIcon` and the code says
    `GalaxyIcon` — but the docstring's *prose* says
    `Assets.Decals.GalaxyIcon` while the header comment above the
    table reads `Galactic -> Assets.Decals.GalaxyIcon`.** The
    authoritative mapping is the `DECAL_BY_MUTATION` table:
    `Galactic = 'GalaxyIcon'`, `Frost = 'SnowfallIcon'`. The
    `EventMutation.spec.lua` asserts exactly this.
26. **`MutationIcon` only paints CLONES.** A Studio-authored
    `Galactic`/`Frost` child inside the template's `Mutations`
    container is never touched — authored art always wins. If you
    author a per-id icon, the decal fallback will not override it.
27. **`MoneyIcon` and `MutationIcon` are server-only** — they read
    `ServerStorage`, which a `LocalScript` cannot touch. Never call
    them from the client.
28. **`SettingsService.GetSettings` does not cache.** It reads the
    profile and sanitizes on every call. A hot path pays the
    sanitization each time.
29. **`SettingsService.ForgetPlayer` does nothing.** It looks like a
    cleanup hook but is a documented no-op.
30. **`SettingsService.PushSettings` is called from the bootstrap's
    player-added path** (line 974) and is wrapped in a `pcall` there.
31. **The `Settings` shape default lives in `PlayerService`, not in
    `SettingsService`.** If you install `SettingsService` without
    `PlayerService`, `GetSettings` always returns the default shape.
32. **`WaterHazard` kills anything with a Humanoid that touches the
    water** — including a player's own carried animal if the rig
    overlaps the volume. There is no owner check.
33. **`WaterHazard` only wires `Workspace.Water`.** A water volume
    inside a base, or a `Model` nested under another folder, is never
    wired. The `ChildAdded` retry only fires for a **direct child of
    `Workspace` named exactly `Water`**.
34. **`WaterHazard.Init()`'s `_wired` latch is set even when the
    water is missing.** The `ChildAdded` retry is what saves you, not
    a second `Init()`.
35. **The `Touched` handler looks for the Humanoid on `hit.Parent`**
    only. A humanoid that is not a direct child of the touched
    instance's parent will not be found.
36. **`UI.RarityColor` is an alias, not a copy.** It is captured at
    require time, so a later change to `Rarity.RarityColor` does not
    propagate to the UI config either.
37. **`UI.Notify` has no `Validate()`.** Nothing checks
    `MaxTextLength`, `CoalesceWindow` or the category names. A
    renamed category breaks every server-side `Notify` call with no
    validation warning.
38. **`Presentation.Vfx` validates only two fields**
    (`LevelUp.Lifetime`, `LevelUp.CleanupCap`). The bop
    choreography, the burst clamps and the egg-roll sizes are
    unchecked.
39. **`Movement` validates only four fields.** The egg-flight agent
    params, the EMA gains, the settle threshold and the epsilon
    deadbands are unchecked.
40. **`bootstrap.server.lua` in this system is the whole-game
    bootstrap**, byte-identical to the production file. It is a
    reference copy, not an installable part of this system.
41. **`ConfigArchitecture.spec.lua:183` fails as shipped.** It
    expects `Movement.Player.WalkSpeed == 24`; the config says `20`.
    The source files are byte-identical between `src/` and this
    system, so this is a pre-existing defect.

---

## 7. What to change to reuse it

- **To re-theme the HUD/toasts:** edit
  `Source/ReplicatedStorage/Config/Presentation/UI.lua`. The colour,
  font, text-size and layout tokens are all in one place. Keep the
  `Notify.Category` names — they are a server-side contract.
- **To re-tune the locomotion feel:** edit
  `Source/ReplicatedStorage/Config/World/Movement.lua`. `YawSmoothing`
  is the one that affects all three walkers. If you change
  `AnimalWalk.AnimationBaseSpeed`, change `AnimalConfig.MovementSpeed`
  with it or the leg cadence drifts.
- **To change the avatar speed:** `Movement.Player.WalkSpeed` /
  `JumpPower`. Fix the stale spec assertion if you carry
  `ConfigArchitecture.spec.lua` over.
- **To add a mutation id:** add an entry to `DECAL_BY_MUTATION` in
  `MutationIcon.lua` **and** author the matching
  `Assets.Decals.<name>` `ImageLabel`. The mapping has no fallback —
  an unmapped id gets no icon.
- **To change the money icon:** author
  `ServerStorage.Assets.Decals.MoneyIcon` (or
  `ReplicatedStorage.Assets.Decals.MoneyIcon`). No code change is
  needed — the resolver reads it fresh on every grant.
- **To change the water hazard:** there is no config. Edit
  `WaterHazard.lua` — the kill is `Humanoid.Health = 0` on `Touched`.
- **To move the luck pool order:** change the `require` at
  `ServerLuckService.lua:31` and the `_MODULES` entry in
  `ConfigValidator` if you drop the Events config.
- **To change the boost caps:** `MAX_LUCK` and `MAX_BOOST_DURATION_S`
  are module-locals in `ServerLuckService.lua`. Move them into a
  config domain if you want them tunable at runtime.
- **To add a debug stream:** use a new tag and add it to the `Tags`
  comment (which is already out of date). A new tag does not need a
  `Subsystem` flag — `Subsystem` is for verbose sites that are not
  tag-gated.
- **To re-register the config domains:** add the entries to
  `ConfigValidator._MODULES`. Without that, the domains are never
  validated at boot.
