# SharedUtilities — API

Every public function of every module in the system.

Nine modules plus five config domains:

- `ServerScriptService.ServerLuckService`
- `ServerScriptService.SettingsService`
- `ServerScriptService.Utility.MoneyIcon`
- `ServerScriptService.Utility.MutationIcon`
- `ServerScriptService.Utility.PathfindingUtil`
- `ServerScriptService.Utility.WaterHazard`
- `ReplicatedStorage.Config.Systems.Debug`
- `ReplicatedStorage.Config.World.Movement`
- `ReplicatedStorage.Config.Presentation.Audio`
- `ReplicatedStorage.Config.Presentation.UI`
- `ReplicatedStorage.Config.Presentation.Vfx`

**General failure policy.** **Nothing in this system throws.** Every
public function body is `pcall`-guarded, and the two that can
legitimately fail (`SetLuck`, `ActivateBoost`) return `false` / `nil`
instead of raising. No call site needs its own `pcall`.

---

## `ServerLuckService`

```lua
local ServerLuckService = require(ServerScriptService.ServerLuckService)
```

The module table is `table.freeze`d.

### Module constants (not exported)

| Name | Value | Notes |
|---|---|---|
| `LUCK_POOL` | `Events.LuckPoolOrder` | The design tier order: Common(0) … Mythic(5). |
| `ATTRIBUTE` | `'ServerLuck'` | The ReplicatedStorage attribute the value is published to. |
| `DEFAULT_LUCK` | `1` | The baseline. |
| `MAX_LUCK` | `1000000` | The overflow guard. |
| `MAX_BOOST_DURATION_S` | `86400` | The longest schedulable boost (24 h). |

---

### `ServerLuckService.Init(): ()`

Publish the default so the `ServerLuck` attribute exists from boot.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. Idempotent — a second call is a
  no-op (the `_published` latch).
- **Side effects:** sets the `ServerLuck` ReplicatedStorage attribute
  to the current effective luck and logs `'[LUCK] ServerLuckService
  ready'`.
- **Note:** in the source game this is called from `EggService.Init`,
  **not** from the bootstrap. Call it yourself if you have no
  `EggService`, or late joiners and the first roll see no attribute.

---

### `ServerLuckService.GetLuck(): number`

The effective luck.

- **Parameters:** none.
- **Returns:** the active boost's multiplier if there is a live boost,
  otherwise the base multiplier.
- **Failure modes:** never throws.
- **Behaviour:** the read is **self-healing** — it reaps a stale boost
  first, so an expired boost reads as the base even before its expiry
  task has run.
- **Note:** this is a **read**. Do not use it to "set" anything —
  `SetLuck` **cancels** an active boost.

---

### `ServerLuckService.DefaultLuck(): number`

- **Parameters:** none.
- **Returns:** `1`.
- **Failure modes:** never throws.

---

### `ServerLuckService.SetLuck(mult: any): boolean`

Set the **base** multiplier (the admin path).

- **Parameters:** `mult` — any finite positive number, up to
  `MaxLuck()`.
- **Returns:** `true` on success, `false` on rejection (state
  unchanged).
- **Failure modes:** never throws. Rejections — all return `false`
  and leave the state **completely unchanged**:
  | Input | Result |
  |---|---|
  | a non-number (`'4'`, `nil`, a table) | `false` |
  | `NaN` | `false` |
  | `+math.huge` / `-math.huge` | `false` |
  | `mult <= 0` | `false` |
  | `mult > MaxLuck()` | `false` |
- **Behaviour on success:**
  - If `mult == _baseLuck` **and** there is no boost, it returns
    `true` **without publishing** — a no-op change is still a
    success.
  - Otherwise it sets `_baseLuck = mult`, **cancels any active
    boost** (`_boost = nil`), publishes the new value immediately and
    logs `'[LUCK] server luck changed'`.
- **Note:** the admin path wins immediately and deterministically. A
  fractional value (`0.5`) is legal here — but **not** for
  `ActivateBoost`.

---

### `ServerLuckService.MaxLuck(): number`

- **Parameters:** none.
- **Returns:** `1000000`.
- **Failure modes:** never throws.
- **Note:** the guard exists because the weights scale as
  `luck^(5/3)` at the top tier; `1e6` is already far beyond any sane
  value while keeping every intermediate in comfortable double range.
  Values like 10 / 100 / 1000 / 10000 all pass.

---

### `ServerLuckService.ResetLuck(): boolean`

- **Parameters:** none.
- **Returns:** `true` on success, `false` on rejection.
- **Failure modes:** never throws.
- **Behaviour:** `SetLuck(DEFAULT_LUCK)` — so it also **cancels any
  active boost**.

---

### `ServerLuckService.ActivateBoost(mult: any, durationSecs: any, source: any): number?`

Activate a temporary server-wide boost (the purchase path).

- **Parameters:** `mult` — the multiplier, `>= 1` and `<= MaxLuck()`.
  `durationSecs` — the duration in seconds, `>= 1` and
  `<= 86400`. `source` — a free-form label for the debug log.
- **Returns:** a **version token** (a number) on success, `nil` on
  rejection.
- **Failure modes:** never throws. Rejections — all return `nil` and
  leave the state unchanged:
  | Input | Result |
  |---|---|
  | a non-number multiplier, `NaN`, `±math.huge` | `nil` |
  | `mult < 1` | `nil` |
  | `mult > MaxLuck()` | `nil` |
  | a non-number / `NaN` duration | `nil` |
  | `durationSecs < 1` | `nil` |
  | `durationSecs > 86400` | `nil` — rejected as a **configuration error, not clamped** |
- **Replacement policy:** a new purchase **replaces** the current
  multiplier **and** its duration. It never stacks and never
  multiplies.
- **The version gate:** each activation increments an internal
  counter and stamps the boost with it. The expiry task re-reads the
  boost and compares versions — if a newer purchase superseded it (or
  an admin cancelled it), the stale expiry **returns without clearing
  anything**.
- **Expiry:** when the boost expires the state returns to the base
  luck, the attribute is republished, and every registered listener
  fires **once** with `{ expiredMult, version }`. Each listener is
  `pcall`-ed, so a throwing listener does not stop the others.
- **Note:** the expiry deadline is `os.clock()` (CPU time) while the
  actual expiry is a wall-clock `task.delay`. The two disagree — see
  the MEMORY gotchas.

---

### `ServerLuckService.GetBoostInfo(): any?`

The live boost snapshot.

- **Parameters:** none.
- **Returns:** `{ mult: number, remainingSecs: number, version: number }`,
  or `nil` when there is no live boost.
- **Failure modes:** never throws.
- **Behaviour:** returns `nil` if there is no boost **or** if the
  boost's `expiresAt` has already passed (the check is on the read,
  so a stale boost is reported as absent even before it is reaped).
- **Caveat:** `remainingSecs` is computed from `os.clock()`, so on an
  idle server it over-reports the real remaining wall-clock time.

---

### `ServerLuckService.OnBoostExpired(fn: (any) -> ()): ()`

Subscribe to boost expiry.

- **Parameters:** `fn` — a function taking the expiry info
  `{ expiredMult, version }`. A non-function is **silently ignored**.
- **Returns:** nothing.
- **Failure modes:** never throws. The listener is `pcall`-ed at
  fire time, so a throwing listener cannot break the expiry.
- **Note:** there is **no unsubscribe**. The listener array is only
  cleared by `_TestReset()`.

---

### `ServerLuckService.ApplyLuck(weights: { [string]: number }, luckOverride: number?): { [string]: number }`

Apply the luck curve to a weight table.

- **Parameters:** `weights` — a `{ key = number }` weight table.
  `luckOverride` — an optional number; when it is a number it is
  used **instead of** `GetLuck()`. It is a pure computation input —
  it does **not** publish.
- **Returns:** a **new** table of scaled weights. The input is never
  mutated.
- **Failure modes:** never throws. A non-table `weights` returns an
  empty table `{}`.
- **The transform:**
  ```
  luck = luckOverride (if a number) else GetLuck()
  if luck is not a finite number in (0, MaxLuck()] then luck = 1
  divisor = RarityConfig.LuckExponentDivisor
  if divisor is not a finite number > 0 then divisor = 3
  for rarity, w in pairs(weights):
      base = tonumber(w) or 0
      if rarity is in LUCK_POOL:
          out[rarity] = base * (luck ^ (tierIndex / divisor))
      else:
          out[rarity] = base
  ```
- **Key properties:**
  - **`luck = 1` is the identity** — the canonical config weights are
    unchanged at 1x.
  - **Non-pool keys pass through unscaled.** `Divine` and `Secret`
    are not in the pool, so their weights stay exactly `0` at any
    luck. They can never be rolled.
  - The tier index is the position in `LUCK_POOL` (Common 0 …
    Mythic 5), and the divisor is `3`, so the top tier scales by
    `luck^(5/3)`.
  - A non-numeric weight becomes `0` (`tonumber(w) or 0`).
- **Note:** this is a hot path in the egg roll and it allocates a new
  table every call.

---

### `ServerLuckService._TestReset(): ()`

Reset the module state. **Test only**.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Resets:** `_baseLuck = DEFAULT_LUCK`, `_boost = nil`,
  `_version = 0`, `_published = false`, and **clears the expiry
  listener list**.
- **Note:** it does **not** publish, so no attribute write happens.
  A pending `task.delay` expiry from before the reset will still fire
  — it will find `_boost == nil` and return.

---

## `SettingsService`

```lua
local SettingsService = require(ServerScriptService.SettingsService)
```

The module table is `table.freeze`d.

---

### `SettingsService.Init(): ()`

Connect the `SaveSettings` remote.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. Idempotent — the `_wired` latch
  makes a second call a no-op.
- **Side effects:** waits up to **10 seconds** for
  `Remotes.GetFolder():WaitForChild(Remotes.Names.SaveSettings, 10)`
  and connects its `OnServerEvent`. If the remote is missing it
  **warns** (`'[Settings] SaveSettings remote missing; settings will
  not persist'`) and continues — the game still boots.
- **Note:** the wait is inside a `pcall`, so a `WaitForChild` error
  is swallowed.

---

### `SettingsService.GetSettings(userId: number): { Bgm: number, Sfx: number, FastMode: boolean }`

The authoritative read.

- **Parameters:** `userId` — the player's user id.
- **Returns:** a table with exactly three fields:
  | Field | Type | Value |
  |---|---|---|
  | `Bgm` | `number` | clamped to `[0, 1]`, default `1` |
  | `Sfx` | `number` | clamped to `[0, 1]`, default `1` |
  | `FastMode` | `boolean` | default `false` |
- **Failure modes:** never throws. A missing profile, a non-table
  `data`, or a corrupt `data.Settings` all yield the **default
  shape** — never `nil`.
- **Behaviour:** the profile is read inside a `pcall`, then the value
  is sanitized. The returned table is always a **fresh copy** — the
  live profile table is never handed out, so a caller cannot mutate
  the profile by accident.
- **Sanitizer rules:** a non-number `Bgm`/`Sfx` keeps the default; a
  `NaN` keeps the default (the `v == v` check — `math.clamp(NaN, 0, 1)`
  would propagate the NaN); a non-boolean `FastMode` becomes
  `false`.

---

### `SettingsService.PushSettings(player: Player): ()`

Push the settings to the owning client.

- **Parameters:** `player` — the client to push to.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Behaviour:** gated on `Validation.LivePlayer(player)` — a `Player`
  whose `Parent` is `nil` (removed) is ignored. Otherwise it fires the
  `SettingsState` remote to that one client with the sanitized state.
- **Note:** the bootstrap calls this in the player-added path
  (line 974) inside a `pcall`.

---

### `SettingsService.ForgetPlayer(_userId: number): ()`

- **Parameters:** `userId` — ignored.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Behaviour:** a deliberate **no-op**. The service holds no
  per-player state, so there is nothing to drop. It exists so the
  bootstrap can call it uniformly across services.

---

## `MoneyIcon`

```lua
local MoneyIcon = require(ServerScriptService.Utility.MoneyIcon)
```

The module table is `table.freeze`d.

---

### `MoneyIcon.Resolve(): { [string]: any }?`

Resolve the money-icon visual config.

- **Parameters:** none.
- **Returns:** the config table, or `nil` when the asset is missing
  or unpopulated.
- **Failure modes:** never throws.
- **The config table's shape** (every field is optional except
  `Image`):
  | Field | Type | Source property |
  |---|---|---|
  | `Image` | `string` | `ImageLabel.Image` (must be a non-empty string) |
  | `RectOffset` | `{ number, number }` | `ImageRectOffset` (X, Y) |
  | `RectSize` | `{ number, number }` | `ImageRectSize` (X, Y) |
  | `ScaleType` | `string` | `ScaleType.Name` |
  | `SliceCenter` | `{ number, number, number, number }` | `SliceCenter` (MinX, MinY, MaxX, MaxY) |
  | `SliceScale` | `number` | `SliceScale` |
  | `Color` | `{ number, number, number }` | `ImageColor3` (R, G, B) |
  | `Transparency` | `number` | `ImageTransparency` |
  | `BgTransparency` | `number` | `BackgroundTransparency` |
- **Resolution order:** `ServerStorage.Assets.Decals.MoneyIcon`, then
  `ReplicatedStorage.Assets.Decals.MoneyIcon`. The first hit wins
  and the search stops.
- **Validity:** the node must be an **`ImageLabel`** with a
  **non-empty** `Image` string. Anything else is treated as missing.
- **Failure behaviour:** a miss produces **one** warning for the
  server's lifetime (the `warnedMissingIcon` latch is never reset):
  `'[IN] Assets.Decals.MoneyIcon ImageLabel missing/unpopulated — HUD
  pooling uses fallback chip'`. The caller falls back to a `"$"`
  chip.
- **Note:** this is a **fresh resolve on every call** — the design
  intent, so a Studio retarget takes effect on the next grant. The
  result is a **snapshot** that travels in the payload; a change
  mid-flight is not seen by an in-progress request.
- **Consumers:** `IncomeService:675`, `CodesService:721`,
  `DailyRewardsService:607`, `PlaytimeRewardsService:621`.

---

## `MutationIcon`

```lua
local MutationIcon = require(ServerScriptService.Utility.MutationIcon)
```

The module table is `table.freeze`d.

### The canonical mapping (module-local, not exported)

```lua
local DECAL_BY_MUTATION: { [string]: string } = {
    Galactic = 'GalaxyIcon',
    Frost    = 'SnowfallIcon',
}
```

---

### `MutationIcon.DecalNameFor(mutationId: any): string?`

The canonical mutation → decal asset name.

- **Parameters:** `mutationId` — the mutation id.
- **Returns:** `'GalaxyIcon'`, `'SnowfallIcon'`, or `nil`.
- **Failure modes:** never throws. A non-string id → `nil`. An
  unmapped id → `nil`. **No asset name is ever invented.**

---

### `MutationIcon.ResolveImage(mutationId: any): string?`

Resolve the decal image for a mutation id.

- **Parameters:** `mutationId` — the mutation id.
- **Returns:** the image id string, or `nil`.
- **Failure modes:** never throws.
  - An unmapped id → `nil`.
  - The asset is missing or unpopulated → `nil`.
  - **Either** case logs **one** warning **per mutation id** (the
    `_warnedMissing` set is keyed by `tostring(mutationId)`, and the
    unmapped id also falls through to the warning block because the
    early return is inside the `pcall`):
    `'[MI] mutation decal missing/unpopulated — overhead keeps
    prototype visuals'`.
- **Resolution order:** `ServerStorage.Assets.Decals.<name>`, then
  `ReplicatedStorage.Assets.Decals.<name>`. The node must be an
  `ImageLabel` with a non-empty `Image` string.

---

### `MutationIcon.PaintIcon(host: Instance?, mutationId: any): boolean`

Paint a freshly cloned generic mutation icon.

- **Parameters:** `host` — the `ImageLabel` itself, or a container
  holding one. `mutationId` — the mutation id.
- **Returns:** `true` when an `Image` was applied, `false` otherwise.
- **Failure modes:** never throws.
  - `host` is not an `Instance` → `false`.
  - The mutation id is unmapped → `false`.
  - The asset is missing → `false` (and the per-id warning is
    logged).
  - The host is a container with no `ImageLabel` descendant → `false`.
- **Target selection:** the host itself if it is an `ImageLabel`,
  otherwise the **first descendant** that is an `ImageLabel`
  (`FindFirstChildWhichIsA('ImageLabel', true)`).
- **Important:** painting applies **only to freshly cloned generic
  icons**. A Studio-authored per-id icon child (a `Galactic`/`Frost`
  node already living in the template's `Mutations` container) is
  **never** touched — authored art always wins, and the decal mapping
  is the fallback that makes the icon correct when the template was
  never customised per mutation.
- **Consumers:** `EggOverhead:322` and `AnimalOverhead:772`, both
  calling `pcall(MutationIcon.PaintIcon, clone, id)`.

---

## `PathfindingUtil`

```lua
local PathfindingUtil = require(ServerScriptService.Utility.PathfindingUtil)
```

The module table is `table.freeze`d.

---

### `PathfindingUtil.ShortestAngleDelta(from: number, to: number): number`

The shortest signed turn between two yaws.

- **Parameters:** `from` — the current yaw in radians. `to` — the
  target yaw in radians.
- **Returns:** the delta in `(-pi, pi]`.
- **Failure modes:** never throws. It is pure arithmetic.
- **Behaviour:** `delta = (to - from) % (2 * math.pi)`; if the result
  is `> math.pi`, subtract `2 * math.pi`. Lua's `%` on a positive
  divisor always returns a non-negative result, so the single
  correction is sufficient. This avoids the "spin the long way
  around" bug when the delta crosses ±pi.
- **Example:** `ShortestAngleDelta(0, math.pi * 1.5)` → approximately
  `-1.5708` (the short way), not `+4.7124`.

---

### `PathfindingUtil.AgentParams`

The animal pathfinder agent defaults.

| Field | Value | Why |
|---|---|---|
| `AgentRadius` | `4` | The animal model footprint is ~4×5×2 studs. A 2-stud agent treats the animal as a thin pillar, routes it through gaps the model cannot fit through, and the walk visibly clips into walls. |
| `AgentHeight` | `5` | Unchanged. |
| `AgentCanJump` | `false` | With jump enabled the pathfinder takes 4-stud "jump" links across small Y gaps, producing sideways-then-up approaches. The animal is on the ground and should route over ramps and stairs. If a gap is non-traversable without a jump, the pathfinder should **refuse** and the walker falls through to its teleport-arrive path. |
| `AgentCanClimb` | `false` | No climbing. |
| `WaypointSpacing` | `6` | A slightly longer polyline, so the LOS simplification in `WalkController` can drop more redundant interior waypoints. |

**Read by:** `Animal/WalkController.lua:295`.

---

### `PathfindingUtil.YawSmoothing`

`8.0` — assigned at **require time** from
`ReplicatedStorage.Config.World.Movement.YawSmoothing`.

- **Parameters / Returns:** n/a — it is a number field.
- **Failure modes:** n/a.
- **Gotcha:** it is a **copy**, not a live reference. Changing
  `Movement.YawSmoothing` later does **not** propagate to it — the
  two other walkers read the config directly, so the three can
  silently disagree. The field is writable, so tests may override it
  per case.

---

### `PathfindingUtil.MaxWalkSeconds`

`60` — **backwards-compat only**.

The walker itself uses a duration-based cap now. Nothing in the
codebase reads this constant; it is kept so external callers do not
break. Do not wire anything to it.

---

## `WaterHazard`

```lua
local WaterHazard = require(ServerScriptService.Utility.WaterHazard)
```

The module table is `table.freeze`d.

---

### `WaterHazard.Init(): ()`

Wire the instant-death water.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. The `Touched` connection itself is
  `pcall`-guarded, and the `ChildAdded` connection is `pcall`-guarded.
- **Behaviour:**
  1. The `_wired` latch makes a second call a no-op — **and it is set
     even when the water is missing**, so a second `Init()` will not
     retry.
  2. If `Workspace:FindFirstChild('Water')` exists:
     - a `BasePart` gets **one** `Touched` connection;
     - a `Model`/`Folder` gets **one connection per descendant
       `BasePart`**.
     - Logs `'[Water] hazard wired'`.
  3. If it does not exist: logs the warning
     `'[Water] Workspace.Water missing; hazard inactive (retrying on
     ChildAdded)'`.
  4. A `Workspace.ChildAdded` connection is armed. If a **direct
     child of `Workspace` named exactly `Water`** appears, it is
     wired and logged as `'[Water] hazard wired (late)'`.
- **The kill:** on `Touched`, the handler looks for a `Humanoid` on
  the touched instance's **parent** and sets `Health = 0`. There is
  no owner check, no grace period and no exception for a carried
  animal.
- **Note:** it is server-authoritative — a client cannot spoof a
  `Touched` event into sparing itself.

---

## The config domains

```lua
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local Movement    = require(ReplicatedStorage.Config.World.Movement)
local AudioConfig = require(ReplicatedStorage.Config.Presentation.Audio)
local UIConfig    = require(ReplicatedStorage.Config.Presentation.UI)
local VfxConfig   = require(ReplicatedStorage.Config.Presentation.Vfx)
```

Every domain is `table.freeze`d. `UI.Notify` and `UI.Overhead` are
frozen separately from `UI`; `Movement.Player` is frozen separately
from `Movement`.

---

### `DebugConfig.Validate(): { string }`

The `Systems.Debug` validator.

- **Parameters:** none.
- **Returns:** an array of issue strings. **An empty array means
  valid.**
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'ServerDebug must be a boolean'` | |
  | `'ClientDebug must be a boolean'` | |
  | `'Tags must be a table'` | |
  | `'Subsystem.<name> must be a boolean'` | One per bad flag. |
  | `'ConfigValidation must be a boolean'` | |
- **Not validated:** `DrawPaths`, `SkipPersistence`,
  `AllowStudioTestUserIds`, `Audio.Enabled`.

---

### `Movement.Validate(): { string }`

The `World.Movement` validator.

- **Parameters:** none.
- **Returns:** an array of issue strings. Empty = valid.
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'YawSmoothing must be a number > 0'` | |
  | `'AnimalWalk.AnimationBaseSpeed must be a number > 0'` | |
  | `'EggFlight.MaxClimbAboveStart must be a number >= 0'` | |
  | `'StandIdle.TickRate must be a number > 0'` | |
- **Not validated:** every other field — the egg-flight agent params,
  the EMA gains, the settle threshold/rate, the walk-size clamp, the
  sample interval, the flight tick cap, and the two stand-idle
  epsilons.

---

### `Movement.Player.Validate(): { string }`

The avatar-tunables validator (a **separately registered** domain).

- **Parameters:** none.
- **Returns:** an array of issue strings. Empty = valid.
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'WalkSpeed must be a number > 0'` | |
  | `'JumpPower must be a number >= 0'` | |

---

### `AudioConfig.Validate(): { string }`

The `Presentation.Audio` validator.

- **Parameters:** none.
- **Returns:** an array of issue strings. Empty = valid.
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'StealAlertSoundName must be a non-empty string'` | |
  | `'Collect.PoolSize must be a number >= 1'` | |
- **Not validated:** the notification cue names, the level-up asset
  names, the arena roots.

---

### `UIConfig.Overhead.Validate(): { string }`

The overhead validator (a **separately registered** domain).

- **Parameters:** none.
- **Returns:** an array of issue strings. Empty = valid.
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'TraitColors.Gold must be a Color3'` | |
  | `'TraitColors.Diamond must be a Color3'` | |
  | `'MutationColors.Galactic must be a Color3'` | |
  | `'MutationColors.Frost must be a Color3'` | |
  | `'FallbackColor must be a Color3'` | |
  | `'StolenTextColor must be a Color3'` | |
  | `'Rainbow.Period must be a number > 0'` | |
- **There is no `UIConfig.Validate()` and no `UIConfig.Notify.Validate()`.**
  The validator's contract exempts presentation-only domains without
  rules. The `UI` root's tokens (fonts, sizes, colours, layout, toast
  sizing) and the whole of `UI.Notify` are **unvalidated**.

---

### `VfxConfig.Validate(): { string }`

The `Presentation.Vfx` validator.

- **Parameters:** none.
- **Returns:** an array of issue strings. Empty = valid.
- **Failure modes:** never throws.
- **The exact rules:**
  | Issue string | Rule |
  |---|---|
  | `'LevelUp.Lifetime must be a number > 0'` | |
  | `'LevelUp.CleanupCap must be a number > 0'` | |
- **Not validated:** the bop choreography, the tilt, the burst clamps,
  the clone-cleanup padding, the scale throttle, the egg-roll sizes
  and colours, and the hygiene colours.

---

## The central validator (a shared dependency, not part of this system)

```lua
local ConfigValidator = require(ReplicatedStorage.Utility.ConfigValidator)
```

| Function | Signature | Description |
|---|---|---|
| `ConfigValidator.ValidateAll` | `(): { string }` | Runs every registered domain's `Validate()` **plus** the cross-config invariants. Empty = everything valid. |
| `ConfigValidator.Report` | `(issues: { string }): string` | Formats the standard failure block. |
| `ConfigValidator.AssertValid` | `(): ()` | **Errors** with the full report if there is at least one issue. |

**Failure modes of `ValidateAll`:** never throws. A domain that cannot
be required contributes `'<Name>: require failed: <err>'`; a domain
whose `Validate()` throws contributes `'<Name>.Validate() crashed:
<err>'`; a crashed invariant check contributes
`'INVARIANT check crashed: <err>'`.

**This system's registered domains:** `World.Movement`,
`World.Movement.Player`, `Systems.Debug`, `Presentation.Audio`,
`Presentation.Vfx`, `Presentation.UI.Overhead`.

---

## Module-locals (not public)

Listed so you know what exists. Do not call these.

| Local | Owner | Purpose |
|---|---|---|
| `sanitize(settings)` | `SettingsService` | The one settings sanitiser, used on both read and write. |
| `onSave(player, payload)` | `SettingsService` | The `SaveSettings` remote handler. |
| `_publish()` | `ServerLuckService` | Writes the `ServerLuck` attribute. |
| `_reapStaleBoost()` | `ServerLuckService` | Drops a stale boost record on a read. |
| `_killOnTouch(part)` | `WaterHazard` | Connects one `Touched` handler to a `BasePart`. |
| `_wire(node)` | `WaterHazard` | Wires a `BasePart` or a container of them. |
| `DECAL_BY_MUTATION` | `MutationIcon` | The canonical mutation → decal name map. |
| `_warnedMissing` | `MutationIcon` | The per-id warn-once set. |
| `warnedMissingIcon` | `MoneyIcon` | The warn-once latch. |
