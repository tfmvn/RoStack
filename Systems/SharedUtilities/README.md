# SharedUtilities

Cross-cutting config domains and small server-side leaf modules that
everything else in the game leans on.

**Portability:** Grade A core (the five config domains, the debug
gating model, the luck/boost state machine, the settings store, the
icon resolvers, the pathfinding helpers, the water hazard) + Grade B
(the asset paths `Assets.Decals.MoneyIcon` / `Assets.Decals.GalaxyIcon`,
the debug tag names, the map-relative avatar tunables).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

This system is a **bag of shared foundations**, not a feature. It holds
nine source modules and five config domains:

**Five config domains** — the canonical, single-source-of-truth
configuration for five areas of the game:

| Domain | Live path | Owns |
|---|---|---|
| `Systems.Debug` | `ReplicatedStorage.Config.Systems.Debug` | The debug master switches, the per-tag whitelist, the path-visualisation switch, the persistence bypass, the Studio test-id gate, the per-subsystem verbose flags, the config-validation switch. |
| `World.Movement` | `ReplicatedStorage.Config.World.Movement` | Locomotion **feel** — the shared yaw smoothing rate, the animal walk cadence, the egg-flight walk rhythm, the stand idle cadence — plus the avatar tunables in `Movement.Player`. |
| `Presentation.Audio` | `ReplicatedStorage.Config.Presentation.Audio` | Audio **policy** — notification cue names, the steal-alert source, the CashClaim SFX pool size, the level-up asset names, the arena asset roots. |
| `Presentation.UI` | `ReplicatedStorage.Config.Presentation.UI` | HUD/toast tokens, toast timing, and the animal-overhead presentation mapping. |
| `Presentation.Vfx` | `ReplicatedStorage.Config.Presentation.Vfx` | VFX lifetimes, cleanup caps and the level-up celebration choreography. |

**Four server leaf modules:**

| Module | What it does |
|---|---|
| `ServerScriptService.ServerLuckService` | The authoritative server-wide luck multiplier for normal egg rarity rolls, with a temporary-boost state machine on top. Global runtime state — never per-player, never persisted. |
| `ServerScriptService.SettingsService` | The server side of the client's presentation settings (BGM volume, SFX volume, FastMode). Persisted preferences, mirrored to the owning client. |
| `ServerScriptService.Utility.MoneyIcon` | Resolves the money-icon visual config (from a Studio-authored `ImageLabel`) so the client never hardcodes an asset id. |
| `ServerScriptService.Utility.MutationIcon` | The one canonical mutation-id → decal-asset map, plus the painter for freshly cloned overhead icons. |
| `ServerScriptService.Utility.PathfindingUtil` | The animal pathfinder's agent params, the shared yaw smoothing rate, and the shortest-angle-delta helper. |
| `ServerScriptService.Utility.WaterHazard` | Instant-death water. Server-authoritative, one `Touched` connection per part. |

**One packaging artifact:** `Source/ServerScriptService/bootstrap.server.lua`
is the **whole-game bootstrap** (1426 lines, byte-identical to the
production file). It is not a shared utility — it is the game's
composition root, and it was swept into this folder by mistake. See
[Known Limitations](#known-limitations).

---

## Entry Points

### `ServerLuckService`

| Entry point | Kind | Notes |
|---|---|---|
| `ServerLuckService.Init(): ()` | Server | Publishes the default `ServerLuck` attribute so the attribute exists from boot. Idempotent. |
| `ServerLuckService.GetLuck(): number` | Server | The effective luck: the active boost if there is one, otherwise the base. Self-healing — an expired boost reads as the base even before its expiry task fires. |
| `ServerLuckService.DefaultLuck(): number` | Server | `1`. The baseline. |
| `ServerLuckService.SetLuck(mult): boolean` | Server | Sets the **base** multiplier (the admin path). Cancels any active boost. Returns `false` on rejection, state unchanged. |
| `ServerLuckService.MaxLuck(): number` | Server | `1000000`. The overflow guard. |
| `ServerLuckService.ResetLuck(): boolean` | Server | Back to `1x`. |
| `ServerLuckService.ActivateBoost(mult, durationSecs, source): number?` | Server | Activates a temporary boost (the purchase path). Returns a version token, or `nil` on rejection. |
| `ServerLuckService.GetBoostInfo(): table?` | Server | `{ mult, remainingSecs, version }`, or `nil` when there is no live boost. |
| `ServerLuckService.OnBoostExpired(fn): ()` | Server | Subscribes to boost expiry. Listeners are `pcall`-ed. |
| `ServerLuckService.ApplyLuck(weights, luckOverride?): table` | Server | Returns a **copy** of a weight table with the luck curve applied. The canonical config is never mutated. |
| `ServerLuckService._TestReset(): ()` | Test | Resets the module state. |

### `SettingsService`

| Entry point | Kind | Notes |
|---|---|---|
| `SettingsService.Init(): ()` | Server | Connects the `SaveSettings` remote. Idempotent. |
| `SettingsService.GetSettings(userId): { Bgm, Sfx, FastMode }` | Server | The authoritative read — always a sanitized **copy**, never the live table. |
| `SettingsService.PushSettings(player): ()` | Server | Pushes the sanitized settings to the owning client via `SettingsState`. |
| `SettingsService.ForgetPlayer(userId): ()` | Server | A deliberate no-op — the service is stateless. |

### `MoneyIcon` / `MutationIcon`

| Entry point | Kind | Notes |
|---|---|---|
| `MoneyIcon.Resolve(): table?` | Server | The money-icon visual config, or `nil` when the asset is missing. Warn-once. |
| `MutationIcon.DecalNameFor(mutationId): string?` | Server | The canonical mutation → decal asset name. `nil` for an unmapped id. |
| `MutationIcon.ResolveImage(mutationId): string?` | Server | The decal image string, or `nil`. Warn-once **per mutation id**. |
| `MutationIcon.PaintIcon(host, mutationId): boolean` | Server | Paints a freshly cloned generic icon. `false` when unmapped or the asset is missing. |

### `PathfindingUtil` / `WaterHazard`

| Entry point | Kind | Notes |
|---|---|---|
| `PathfindingUtil.ShortestAngleDelta(from, to): number` | Pure | The shortest-path angle delta in `(-pi, pi]`. |
| `PathfindingUtil.AgentParams` | Data | The animal pathfinder agent defaults. |
| `PathfindingUtil.YawSmoothing` | Data | Assigned at require time from `Movement.YawSmoothing`. |
| `PathfindingUtil.MaxWalkSeconds` | Data | `60`. Backwards-compat only — nothing in the codebase reads it. |
| `WaterHazard.Init(): ()` | Server | Wires the `Touched` handlers. Idempotent. |

### Config domains

| Entry point | Kind | Notes |
|---|---|---|
| `Debug.Validate(): { string }` | Config | The `Systems.Debug` validator. Empty array = clean. |
| `Movement.Validate(): { string }` | Config | The `World.Movement` validator. |
| `Movement.Player.Validate(): { string }` | Config | The avatar-tunables validator (a separate registered domain). |
| `Audio.Validate(): { string }` | Config | The `Presentation.Audio` validator. |
| `Vfx.Validate(): { string }` | Config | The `Presentation.Vfx` validator. |
| `UI.Overhead.Validate(): { string }` | Config | The overhead validator (a separate registered domain). |
| `UI.Notify` | Config | **No `Validate()`** — presentation-only, exempt by the validator's contract. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage.Config.Systems.Debug` | Every debug tunable. |
| `Source/ReplicatedStorage/Config/World/Movement.lua` | `ReplicatedStorage.Config.World.Movement` | Locomotion feel + avatar tunables. |
| `Source/ReplicatedStorage/Config/Presentation/Audio.lua` | `ReplicatedStorage.Config.Presentation.Audio` | Audio tunables + policy. |
| `Source/ReplicatedStorage/Config/Presentation/UI.lua` | `ReplicatedStorage.Config.Presentation.UI` | HUD/toast tokens, toast timing, overhead presentation. |
| `Source/ReplicatedStorage/Config/Presentation/Vfx.lua` | `ReplicatedStorage.Config.Presentation.Vfx` | VFX lifetimes, cleanup caps, level-up choreography. |
| `Source/ServerScriptService/ServerLuckService.lua` | `ServerScriptService.ServerLuckService` | The server-wide luck multiplier + boost state machine. |
| `Source/ServerScriptService/SettingsService.lua` | `ServerScriptService.SettingsService` | The server side of the client settings. |
| `Source/ServerScriptService/Utility/MoneyIcon.lua` | `ServerScriptService.Utility.MoneyIcon` | The money-icon visual resolver. |
| `Source/ServerScriptService/Utility/MutationIcon.lua` | `ServerScriptService.Utility.MutationIcon` | The mutation → decal map and painter. |
| `Source/ServerScriptService/Utility/PathfindingUtil.lua` | `ServerScriptService.Utility.PathfindingUtil` | The pathfinder agent params + yaw helper. |
| `Source/ServerScriptService/Utility/WaterHazard.lua` | `ServerScriptService.Utility.WaterHazard` | Instant-death water. |
| `Source/ServerScriptService/bootstrap.server.lua` | `ServerScriptService.bootstrap.server` | **The whole-game bootstrap.** Not a shared utility — see Known Limitations. |
| `Config.lua` | — (documentation only) | The consolidated tunable reference. **Not live config.** |
| `Tests/ServerLuckService.spec.lua` | — | Tests `ServerLuckService`. |
| `Tests/ServerLuckBoost.spec.lua` | — | Tests the boost state machine. |
| `Tests/ConfigArchitecture.spec.lua` | — | Tests the whole config tree, including this system's five domains. |
| `Tests/BigNumber.spec.lua` | — | Tests `ReplicatedStorage.Utility.BigNumber` — **not this system.** |
| `Tests/RichTextFormatter.spec.lua` | — | Tests `ReplicatedStorage.Utility.RichTextFormatter` — **not this system.** |
| `Tests/StatCalculator.spec.lua` | — | Tests `ReplicatedStorage.Utility.StatCalculator` — **not this system.** |
| `Tests/HudTree.spec.lua` | — | Tests `StarterPlayer.StarterPlayerScripts.HudTree` — **not this system.** |
| `Tests/PromptOwnerFilter.spec.lua` | — | Tests the carry/steal prompt visibility rule — **not this system.** |
| `Tests/SellConfirmViewport.spec.lua` | — | Tests the sell-confirmation viewport — **not this system.** |
| `Tests/StudioTestUserIds.spec.lua` | — | Tests the Studio test-id gate (touches `Systems.Debug` and `StudioTestMode`) — **partly this system.** |

### The shared modules this system depends on

These live in `ReusableSystems/Shared/` and are **not** shipped in this
system's `Source/` tree. They are listed in
[Dependencies.md](Dependencies.md) with their exact Roblox paths.

| Library path | Roblox destination |
|---|---|
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage.Utility.Debug` |
| `Shared/Utilities/ConfigValidator.lua` | `ReplicatedStorage.Utility.ConfigValidator` |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage.Utility.Validation` |
| `Shared/Utilities/StudioTestMode.lua` | `ReplicatedStorage.Utility.StudioTestMode` |
| `Shared/Utilities/AudioGroups.lua` | `ReplicatedStorage.Utility.AudioGroups` |
| `Shared/Utilities/WeightedDraw.lua` | `ReplicatedStorage.Utility.WeightedDraw` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` |
| `Shared/Utilities/RichTextFormatter.lua` | `ReplicatedStorage.Utility.RichTextFormatter` |
| `Shared/Utilities/NumberUtils.lua` | `ReplicatedStorage.Utility.NumberUtils` |
| `Shared/Utilities/Signals.lua` | `ReplicatedStorage.Utility.Signals` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage.Types.SlotType` |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage.Types.RarityType` |
| `Shared/CommonModules/StatCalculator.lua` | `ReplicatedStorage.Utility.StatCalculator` |
| `Shared/CommonModules/AnimalViewport.lua` | `ReplicatedStorage.Utility.AnimalViewport` |

---

## Configuration

**There is no `Config.lua` in the live game for this system** — its
configuration *is* the five domain modules in its `Source/` tree.
The library's [`Config.lua`](Config.lua) is a **documented reference
transcription**: every tunable with its default, meaning, valid range,
safety and reader. Editing it changes nothing at runtime.

The five domains are registered with the central validator
(`ReplicatedStorage.Utility.ConfigValidator`) as six entries:

| Registered name | Path | Subsection |
|---|---|---|
| `World.Movement` | `World/Movement` | — |
| `World.Movement.Player` | `World/Movement` | `Player` |
| `Systems.Debug` | `Systems/Debug` | — |
| `Presentation.Audio` | `Presentation/Audio` | — |
| `Presentation.Vfx` | `Presentation/Vfx` | — |
| `Presentation.UI.Overhead` | `Presentation/UI` | `Overhead` |

`Presentation.UI` (the root) and `Presentation.UI.Notify` have **no**
`Validate()` — the validator's contract exempts presentation-only
domains without rules.

The most important tunables, in one place:

| Tunable | Default | Effect |
|---|---|---|
| `Debug.ServerDebug` | `false` | The server-side debug master switch. |
| `Debug.ClientDebug` | `false` | The client-side debug master switch. Independent of the server one. |
| `Debug.Tags` | `{}` | An optional per-tag whitelist. **Only applied when non-empty.** |
| `Debug.ConfigValidation` | `true` | Runs `ConfigValidator.AssertValid()` at boot. Hard error in Studio, warn in live. |
| `Debug.AllowStudioTestUserIds` | `true` | Accepts Studio test UserIds (0, -1, …). Harmless at publish — the `IsStudio()` gate is in `StudioTestMode`. |
| `Movement.YawSmoothing` | `8.0` | The shared yaw rate for animal walks, egg flights and the pathfinder. |
| `Movement.Player.WalkSpeed` | `20` | The default avatar walk speed. |
| `Movement.Player.JumpPower` | `50` | The default avatar jump power. |
| `Movement.StandIdle.TickRate` | `30` | The whole-registry idle tick rate. |
| `Audio.Collect.PoolSize` | `4` | The per-player CashClaim SFX pool. |
| `UI.Notify.MaxTextLength` | `120` | The toast text cap. |
| `UI.Notify.CoalesceWindow` | `1.5` | Same-category toast coalescing window. |
| `UI.Overhead.Rainbow.Period` | `3` | The rainbow overhead cycle time. |
| `Vfx.LevelUp.Lifetime` / `CleanupCap` | `2.0` / `1.2` | The level-up celebration cleanup. |
| `ServerLuckService` `MAX_LUCK` | `1000000` | The luck overflow guard (a module-local, not a config field). |
| `ServerLuckService` `MAX_BOOST_DURATION_S` | `86400` | The longest schedulable boost. |

---

## Dependencies

See [Dependencies.md](Dependencies.md) for the exact require paths, the
remotes, the profile fields, the required Studio assets and the exact
initialization order.

The short version:

- **`Debug`** — every module logs through the shared
  `ReplicatedStorage.Utility.Debug`. The tags this system uses are
  `LUCK`, `Settings`, `IN`, `MI`, `Water` (plus `BS` in the
  bootstrap).
- **`Remotes`** — `SettingsService` uses `SaveSettings` (C→S) and
  `SettingsState` (S→C). `ServerLuckService` adds **no** remote — it
  publishes the `ServerLuck` ReplicatedStorage attribute instead.
- **`Config.World.Events`** — `ServerLuckService` reads
  `Events.LuckPoolOrder`. This is a **cross-system coupling**: the
  luck pool order lives in the Events system's config.
- **`Config.Creatures.Rarity`** — `ServerLuckService` reads
  `LuckExponentDivisor`; `Config.Presentation.UI` reads `RarityColor`.
- **`PlayerService`** — `SettingsService` reads and writes
  `profile.Data.Settings`.

---

## Initialization Order

The exact order in `bootstrap.server.lua` (line numbers from the
production file, which is byte-identical to this system's copy):

| Step | Line | Action |
|---|---|---|
| 1 | `:29` | `require(ReplicatedStorage.Config.Systems.Debug)`. |
| 2 | `:39` | `Debug.SyncFromDebugConfig(DebugConfig)` — the server's debug switches are now live. **Everything after this point can log.** |
| 3 | `:44-57` | If `DebugConfig.ConfigValidation == true`, `ConfigValidator.AssertValid()` runs. In **Studio** a failure re-raises (hard error); on a **live server** it is only a `warn`. |
| 4 | `:63` | `StudioTestMode.Enabled = DebugConfig.AllowStudioTestUserIds == true`. |
| 5 | `:31` + `:45` | `ConfigValidator` and `StudioTestMode` are required. |
| 6 | `:85` | `require(script.Parent.SettingsService)`. |
| 7 | `:295-296` | `require(script.Parent.Utility.WaterHazard)` then `WaterHazard.Init()`. |
| 8 | `:416` | `SettingsService.Init()` — connects the `SaveSettings` remote. |
| 9 | (EggService) | `ServerLuckService.Init()` is called from **`EggService.Init`**, not from the bootstrap directly, so the `ServerLuck` attribute exists before the first roll. |

**`ServerLuckService` has no bootstrap line of its own.** The `Init()`
call lives inside `EggService.Init` — the comment in `ServerLuckService`
says so explicitly ("Called from EggService.Init (no bootstrap changes
needed)"). If you install `ServerLuckService` without `EggService`, you
must call `ServerLuckService.Init()` yourself.

**`MoneyIcon`, `MutationIcon` and `PathfindingUtil` have no `Init`.**
They are pure resolvers/helpers, required on demand.

---

## Data

### Profile fields

| Field | Read | Written | By |
|---|---|---|---|
| `Data.Settings` | `SettingsService.GetSettings` | `SettingsService` (on the `SaveSettings` remote) | `SettingsService` |

`Settings` has the shape `{ Bgm: number, Sfx: number, FastMode: boolean }`.
It is **sanitized on every read and every write** — the shape default
lives in `PlayerService`.

### ReplicatedStorage attributes

| Attribute | Written by | Meaning |
|---|---|---|
| `ServerLuck` | `ServerLuckService` | The current effective luck multiplier. Published on every change and once at `Init`. The **only** client-facing channel for luck — the service adds no remotes. |

### DataStore

**None.** This system reads and writes no DataStore directly. The
`Settings` preferences ride on the player profile, which is owned by
the `PlayerData` system.

### In-memory state

| Owner | State | Lifetime |
|---|---|---|
| `ServerLuckService` | `_baseLuck`, `_boost` (`{ mult, expiresAt, version }`), `_version`, `_published`, `_expiryListeners` | Server process. Never persisted. |
| `SettingsService` | `_wired` | Server process. |
| `MoneyIcon` | `warnedMissingIcon` | Server process (warn-once latch). |
| `MutationIcon` | `_warnedMissing` (a set) | Server process (warn-once per mutation id). |
| `WaterHazard` | `_wired` | Server process. |

---

## Known Limitations

1. **`bootstrap.server.lua` does not belong in this system.** It is the
   whole-game composition root (1426 lines), byte-identical to
   `src/ServerScriptService/bootstrap.server.lua`. It was swept into
   this folder because it lives in `ServerScriptService/`. It is
   **not** a shared utility and it cannot be installed on its own —
   it requires every other system in the game. Treat it as a
   **reference copy** of the game's boot order, not as part of this
   system.

2. **Seven of the ten test files test code that is not in this
   system.** `BigNumber.spec.lua`, `RichTextFormatter.spec.lua`,
   `StatCalculator.spec.lua`, `HudTree.spec.lua`,
   `PromptOwnerFilter.spec.lua`, `SellConfirmViewport.spec.lua` and
   `StudioTestUserIds.spec.lua` test shared modules and client
   scripts that live elsewhere. They are hosted in this folder
   because it doubles as a test-hosting folder, not because they
   belong to this system. Only `ServerLuckService.spec.lua`,
   `ServerLuckBoost.spec.lua` and (partly)
   `ConfigArchitecture.spec.lua` cover this system's own code.

3. **`ConfigArchitecture.spec.lua:183` asserts a value the config does
   not have.** It expects `Movement.Player.WalkSpeed == 24`, but
   `Config/World/Movement.lua:129` sets `WalkSpeed = 20` (the source
   comment even says "spec baseline; comment once said 16"). The
   source files are byte-identical between `src/` and this system, so
   **the spec fails as shipped** — a pre-existing defect, not
   something this library introduced. Either the config is wrong or
   the spec is stale; the comment suggests both have moved.

4. **`ServerLuckService` reads its pool order from another system's
   config.** `LUCK_POOL = Events.LuckPoolOrder` — the design pool
   order lives in `ReplicatedStorage.Config.World.Events`, i.e. in the
   **Events** system. Delete the Events system and the luck roll
   breaks. This is the only cross-system config dependency in the
   system, and the `ConfigValidator` even has a JOIN rule that checks
   every `Events.LuckPoolOrder` entry is a real `Rarity.Order` tier.

5. **`ServerLuckService` has no bootstrap line.** `Init()` is called
   from `EggService.Init`, not from `bootstrap.server.lua`. A system
   that uses luck without `EggService` must call `Init()` itself or
   the `ServerLuck` attribute never appears (late joiners and first
   rolls would see no attribute).

6. **`Debug.Tags` in the live config is out of date.** The comment
   lists `BS, LB, BR, PS, RM, CL, AO, CP` — it does not mention
   `LUCK`, `Settings`, `IN`, `MI` or `Water`, which are the tags this
   system actually uses. With a non-empty `Tags` whitelist, those five
   modules stay silent.

7. **`MoneyIcon` and `MutationIcon` are server-only.** They read
   `ServerStorage`, which a `LocalScript` cannot touch. That is why
   they resolve the asset into a plain config table and ship it in the
   payload — the client never reads the server-only container. The
   consequence is that the config table is a **snapshot**: a change
   mid-flight is not seen by an in-progress request.

8. **`MutationIcon`'s docstring contradicts its code.** The header
   comment says `Galactic -> Assets.Decals.GalaxyIcon`, but the
   `DECAL_BY_MUTATION` table maps `Galactic = 'GalaxyIcon'`. The
   **code is right** and the comment is wrong.

9. **`MoneyIcon.Resolve` and `MutationIcon.ResolveImage` are
   deliberately fresh-per-call.** They re-walk the instance tree on
   every call so a Studio retarget takes effect immediately. That is
   correct for the design, but it is a per-grant instance walk — a
   hot path if you call it in a tight loop.

10. **`MoneyIcon` warns only ONCE, ever.** The `warnedMissingIcon`
    latch is not reset, so a missing icon produces exactly one
    warning per server process. If the icon is added later in the
    session, no new warning appears and the fallback chip keeps
    being used.

11. **`SettingsService` is not a cache.** `GetSettings` reads the
    profile and sanitizes it on **every** call. There is no
    per-player cache and no dirty flag, so a hot path that reads
    settings per frame pays the sanitization cost each time.

12. **`SettingsService.ForgetPlayer` is a deliberate no-op.** It
    exists so the bootstrap can call it uniformly across services,
    but the service keeps no per-player state to drop.

13. **`WaterHazard` kills anything with a Humanoid that touches the
    water** — including a player's own carried animal if the rig
    overlaps it. There is no owner check and no grace period.

14. **`WaterHazard` only wires up `Workspace.Water` and its
    descendants.** A water volume in a different container (a base, a
    Model nested elsewhere) is never wired. The `ChildAdded` retry
    only fires for a **direct child of `Workspace` named exactly
    `Water`**.

15. **`PathfindingUtil.MaxWalkSeconds` is dead code.** It is
    documented as backwards-compat only and nothing in the codebase
    reads it.

16. **`PathfindingUtil.YawSmoothing` is captured at require time.** A
    later change to `Movement.YawSmoothing` does **not** propagate to
    it — the value was copied, not referenced. The other two walkers
    read the config directly, so they can disagree.

17. **`Debug.DrawPaths` creates real Instances in the Workspace** and
    is not gated on `IsStudio()`. It is off by default; do not ship
    it on.

18. **`Debug.SkipPersistence` is not `IsStudio()`-gated in the config
    itself.** The gate lives in `PlayerService`. Shipping it `true`
    means nothing is ever saved.

19. **The boost expiry mixes two clocks.** `ServerLuckService` stores
    `expiresAt = os.clock() + durationSecs` — in Luau `os.clock()` is
    **CPU** time — but the actual expiry is driven by
    `task.delay(durationSecs, ...)`, which is wall time. The two
    disagree, so `GetBoostInfo().remainingSecs` over-reports on an
    idle server, and `_reapStaleBoost` only clears the boost once the
    `task.delay` has fired. The boost spec only locks the state
    machine and never asserts the timing. Treat this as a latent
    defect, not something to change casually.

---

## Testing

The specs are **TestEZ** specs and need **Roblox Studio** — there is
no headless Luau runner in this project. See
[Setup.md](Setup.md) for how to run them.

| Spec | Covers | Notes |
|---|---|---|
| `ServerLuckService.spec.lua` | The luck state and `ApplyLuck`. | Uses `Helpers.MakeRng` (a seeded RNG) through the **real** `WeightedDraw.Choose`, so it exercises the production path. Asserts: the default is 1x; `SetLuck`/`ResetLuck`; invalid values (`0`, `-3`, `'4'`, `nil`, `NaN`, `+inf`, `MaxLuck()+1`) are rejected **without changing state**; fractional multipliers are accepted; `ApplyLuck` never mutates the canonical `RarityConfig.SpawnWeight`; 1x is the identity; **Divine and Secret stay exactly 0 at any luck** (both in the weights and in 5000 seeded rolls); below-baseline luck favours common tiers; higher luck yields more high-rarity eggs, and Mythic stays under 5% even at 4x. |
| `ServerLuckBoost.spec.lua` | The boost state machine. | Asserts: a boost is reported by `GetLuck` and `GetBoostInfo`; a **newer purchase REPLACES** (never stacks or multiplies); an admin `SetLuck` **cancels** the boost immediately; invalid multiplier/duration (`0`, `-2`, `'4'`, `0`, `-5`, `+inf`) is rejected with the state kept; expiry listeners subscribe without throwing. The **timed expiry itself is not tested** — it is a `task.delay` path the spec notes as "Studio-verified". |
| `ConfigArchitecture.spec.lua` | The whole config tree. | Asserts `ConfigValidator.ValidateAll()` returns **zero** issues; every registered domain's `Validate()` is clean; the economy ladders stay pegged; the legacy `GameConfig` and `FormattingConfig` mirrors are **deleted**; and a set of preserved baseline values. **It fails as shipped** — see Known Limitation 3. |
| `StudioTestUserIds.spec.lua` | The Studio test-id gate. | Touches this system: it asserts `Debug.AllowStudioTestUserIds` defaults to `true` and that `Debug.Audio.Enabled` is `false`. The rest covers `Validation.IsValidPlayerUserId` and `StudioTestMode`. |
| `BigNumber.spec.lua` | `ReplicatedStorage.Utility.BigNumber`. | **Not this system.** |
| `RichTextFormatter.spec.lua` | `ReplicatedStorage.Utility.RichTextFormatter`. | **Not this system.** |
| `StatCalculator.spec.lua` | `ReplicatedStorage.Utility.StatCalculator`. | **Not this system.** |
| `HudTree.spec.lua` | `StarterPlayer.StarterPlayerScripts.HudTree`. | **Not this system.** |
| `PromptOwnerFilter.spec.lua` | The carry/steal prompt visibility rule. | **Not this system.** |
| `SellConfirmViewport.spec.lua` | The sell-confirmation viewport. | **Not this system.** |

`ServerLuckService.spec.lua` requires
`ServerScriptService.TestEZTests._Helpers` — a **test-helper module
that is not in this system**. You must copy it in.

---

## Adapting to a New Game

1. **Copy the five config domains.** `Systems/Debug`,
   `World/Movement`, `Presentation/Audio`, `Presentation/UI`,
   `Presentation/Vfx` → `ReplicatedStorage/Config/…`. Keep the
   `Validate()` on each — the central validator calls it.

2. **Copy the shared modules this system needs** (see
   [Dependencies.md](Dependencies.md) for the full list). The minimum
   is `Utility/Debug`, `Utility/ConfigValidator`, `Utility/Validation`
   and `Utility/StudioTestMode`.

3. **Install `osyrisrblx/t`** — `Validation` requires it
   (`script.Parent.Parent.Packages.t`).

4. **Copy the six server modules** to their Roblox paths. Note the
   `Utility/` subfolder — `MoneyIcon`, `MutationIcon`,
   `PathfindingUtil` and `WaterHazard` all live at
   `ServerScriptService.Utility.*`.

5. **Do not copy `bootstrap.server.lua`.** It is a reference copy of
   the source game's boot order. Read it for the wiring, then wire
   your own bootstrap:
   - `Debug.SyncFromDebugConfig(DebugConfig)` — **first**, before
     anything logs.
   - `ConfigValidator.AssertValid()` under the Studio/live split.
   - `StudioTestMode.Enabled = DebugConfig.AllowStudioTestUserIds == true`.
   - `WaterHazard.Init()`.
   - `SettingsService.Init()`.
   - `ServerLuckService.Init()` — **call it yourself** if you do not
     have an `EggService`.

6. **Decide the luck pool order's home.** If you use
   `ServerLuckService`, you must either keep the `Events` config or
   move `LuckPoolOrder` into your own config and change the one
   `require` in `ServerLuckService.lua:31`.

7. **Author the Studio assets:**
   - `ServerStorage.Assets.Decals.MoneyIcon` (an `ImageLabel` with a
     populated `Image`).
   - `ServerStorage.Assets.Decals.GalaxyIcon` and
     `ServerStorage.Assets.Decals.SnowfallIcon` (same contract).
   - `Workspace.Water` (a `BasePart`, or a `Model`/`Folder` of
     `BasePart`s).

8. **Set the avatar tunables** in `Movement.Player`, and fix the
   stale `ConfigArchitecture.spec.lua` assertion (`WalkSpeed == 24` →
   `20`) if you carry that spec over.

9. **Fix the `Debug.Tags` comment** if you use a tag whitelist — add
   `LUCK`, `Settings`, `IN`, `MI`, `Water`.

10. **Copy the tests** you want: `ServerLuckService.spec.lua` and
    `ServerLuckBoost.spec.lua` are self-contained apart from
    `ServerScriptService.TestEZTests._Helpers` and
    `ReplicatedStorage.Utility.WeightedDraw`. `ConfigArchitecture.spec.lua`
    needs the **entire** config tree and every other system's config
    domain — it is not portable on its own.

11. **Re-register the config domains** in `ConfigValidator._MODULES` if
    you use the central validator. The entries for this system are
    `World.Movement`, `World.Movement.Player`, `Systems.Debug`,
    `Presentation.Audio`, `Presentation.Vfx` and
    `Presentation.UI.Overhead`.
