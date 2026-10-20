# MEMORY.md

**The persistent engineering knowledge document for this library.**

This is the file a future coding agent or developer should read first. It
describes the *actual* extracted code — not an idealized version of it. Where
the source game has a quirk, a bug, or a hardcoded assumption, it is written
down here rather than smoothed over.

---

## 1. Project Overview

**What this is.** A reusable collection of Roblox game systems, extracted
from **Brainrot Arena** (the `p-7` Rojo project in this repository) into
`ReusableSystems/`. It is a *reference implementation with documentation*,
not a publishable package.

**Source game.** Brainrot Arena — a "brainrot" / creature-collector
incremental game on Roblox. Players buy eggs, hatch them into animals, place
animals on stands to generate cash, upgrade them, mutate them, rebirth, and
raid an arena. Monetisation is Robux developer products, gamepasses, and
optional ads-style prompts.

**Extraction principles.**

1. **The production game was not modified.** `src/` is byte-identical to
   before this task. Every file under `ReusableSystems/` is a copy.
2. **Files keep their original Roblox path.** `Systems/<X>/Source/` mirrors
   the path the file occupied in the source game, so both absolute requires
   (`require(ReplicatedStorage.Config.Y)`) and relative requires
   (`require(script.Parent.Z)`) resolve unchanged when you copy the tree to
   the documented destination.
3. **The library is not in the Rojo build.** `default.project.json` does not
   map `ReusableSystems/`, so it cannot ship by accident. A separate
   `library.project.json` builds it standalone.
4. **One physical home per file.** Every source file lives in exactly one
   place: its owning system, or `Shared/` if it is genuinely shared. Nothing
   is duplicated; cross-system usage is recorded in `DEPENDENCY_MAP.md` and
   in each system's `Dependencies.md`.

**Two deliberate deviations from a pure copy**, both documented in
`SECURITY_NOTES.md`:

| File | Deviation | Why |
|---|---|---|
| `Systems/PlayerLogging/…/PlayerLoggerConfig.lua` | The live Discord webhook URL literal was replaced with the **attribute name** `'PlayerLoggerWebhookUrl'`. | The literal is a secret. The consuming code (`PlayerLogger.lua:267`) already expected a *name*, so this also fixes a latent bug. |
| `Systems/AdminTools/…/AdminConfig.lua` | The live admin allowlist (2 real userIds + Studio ids 0/1/2) was emptied. | Live userIds are private identifiers, and granting `superadmin` to userId `0` with no `IsStudio()` gate is a privilege-escalation hole. |

Everything else is copied **unchanged**.

---

## 2. Complete System Catalog

26 systems were found. The full table with entry points, config, dependencies,
portability, and tests is in [`SYSTEM_INDEX.md`](SYSTEM_INDEX.md). This
section summarises what each one *is*.

### 2.1 The data spine

| System | What it owns |
|---|---|
| **PlayerData** | The profile. Load → reconcile → audit → expose → release. The only module that touches `ProfileService`. |
| **Economy** | Money. `EconomyService` (the wallet authority), `IncomeService` (cash pools), `ModifierService` (multipliers), `SellService` (selling). |
| **Inventory** | The unified slot pool. `SlotService` owns slot occupancy; `SlotMenuService` and `SlotActionHandler` are the menu/mutation layer. |
| **Items** | `GearShopService` — the gear catalogue, purchase and auto-buy. |
| **Upgrades** | `UpgradeService` — animal XP, levels, and upgrade cost. |
| **Rebirth** | `RebirthService` — the prestige loop, its ladder, and its unlocks. |

### 2.2 The content spine

| System | What it owns |
|---|---|
| **Animals** | `AnimalService` (3 286 lines — the largest service), plus carry, walk, and level-up presentation. |
| **EggsAndHatching** | `EggService` and 14 egg modules — spawn, roll, hatch, guarantee, flight, ambient, contest. |
| **MutationsAndTraits** | `TraitService` and `MutationService` — the trait/mutation catalogues and their application. |
| **BasesAndSlots** | `BaseService`, `BaseLockService`, `StandDisplayService`, `StandPresentation`, `DynamicSlotService`. |
| **Collectors** | `CollectFeedback` and `CollectorArrival` — the cash-collect interaction. |

### 2.3 The world and conflict

| System | What it owns |
|---|---|
| **Arena** | `ArenaService`, `ArenaBattleService`, `ArenaProgressionService` — the wave/raid loop. |
| **Combat** | `BatService` and `RagdollService`. |
| **Stealing** | `StealService` — stealing from other players' bases. |
| **Carry** | `CarryRegistry`, `PlayerGrabService`, `ResetProtectionService`, `ToolLockService`. |

### 2.4 The meta layer

| System | What it owns |
|---|---|
| **ShopsAndPurchases** | `ShopService` (Marketplace receipts) and `DoorService`. |
| **CodesAndRewards** | `CodesService`, `DailyRewardsService`, `PlaytimeRewardsService`, plus `DailyRewardsWeek` and `PlaytimeRewardsDay` — the two global content-rotation modules. |
| **Tutorials** | `TutorialService` and `TutorialSignals` — the onboarding step machine. |
| **Notifications** | `NotificationService` plus the 134-entry `Messages` catalogue. |
| **Events** | `EventService`, `EnvironmentModifier`, `EventLights` — the generic event engine. |
| **Leaderboards** | `LeaderboardService` (OrderedDataStore) and `TabListService`. |
| **Analytics** | `FunnelService` — Roblox `AnalyticsService` funnel events. |
| **PlayerLogging** | `PlayerLogger` + `PlayerRegistry` — Discord embeds and a separate all-time registry DataStore. |
| **AdminTools** | The admin framework (8 modules) and 68 Cmdr commands with 8 argument types. |
| **ClientPresentation** | The 40-script client layer and its bootstrap. |
| **SharedUtilities** | `ServerLuckService`, `SettingsService`, `WaterHazard`, `PathfindingUtil`, icon helpers, and the Presentation/Movement/Debug config. |

### 2.5 Categories that do NOT exist

The task's suggested taxonomy listed a few categories the source game does not
have. They are marked **ABSENT** in `SYSTEM_INDEX.md` rather than invented:

- **Gamepasses** — gamepass entitlement is handled *inside* `ShopService`
  (`Config.Economy.Shop` has both product and gamepass entries). There is no
  separate gamepass service. Extracting one would be a rewrite, which the
  rules forbid.
- **Combat (as a combat-system framework)** — what exists is a bat and a
  ragdoll. There is no generic damage/stat pipeline.
- **A generic inventory-bag system** — "Inventory" here means the *stand slot
  pool*, not a backpack.
- **Discord (as a bot)** — the `discord_bot/` Python service is gitignored
  and was never part of `src/`. Only the **webhook** side is in the library.

---

## 3. Architecture

### 3.1 Layer model

```text
StarterPlayerScripts (40 client controllers)
        │  intent + ids only
        ▼
ReplicatedStorage
  ├── Config/{Creatures,Economy,Presentation,Systems,World}   ← WHAT the game is
  ├── Types/                                                ← data shapes
  ├── Utility/                                             ← generic helpers
  └── Remotes (47 RemoteEvents, created at boot)
        │  server re-resolves everything
        ▼
ServerScriptService
  ├── bootstrap.server.lua          ← THE WIRING REGISTRY
  ├── 30 services (singletons)
  ├── Admin/ (8 modules)
  ├── Cmdr/Server/ (68 commands + 8 argument types)
  └── Utility/
        │
        ▼
Workspace / ServerStorage        ← Studio-authored assets (not in this repo)
```

### 3.2 The service pattern

Every service in the source game follows the same shape:

```lua
local Service = {}
local initialized = false

function Service.Init()
    if initialized then return end
    initialized = true
    -- …
end

function Service.SetPeerService(other)  -- late-bound injection
    peer = other
end

return table.freeze(Service)
```

Rules that follow from this:

- **Singletons.** One instance per server, module-level state.
- **`table.freeze` on the export.** The handful of modules that legitimately
  hold mutable state (`Debug`, `StudioTestMode`, `Remotes`) are the
  exceptions.
- **`Init()` is idempotent.** A second call is a no-op, not an error.
- **`Set<Peer>Service()` instead of mutual `require`.** This is the mechanism
  that keeps the dependency graph **acyclic**. Two services that need each
  other never require each other; one is injected.
- **Lazy `require` inside functions** for the remaining cycles
  (`PlayerService.GetLoadedSignal` requires `Signals` inside the function).
- **Lifecycle hooks** the services expose: `OnPlayerReady(player)`,
  `ForgetPlayer(userId)`, `OnCharacterSpawned(player, character)`.
- **`_TestReset()`** seams so the specs can reset module state between runs.
- **`pcall`-wrapped public entry points** return a sentinel (`nil`, `false`,
  or a result table with `ok = false`) rather than throwing.

### 3.3 The bootstrap

`ServerScriptService/bootstrap.server.lua` (1 426 lines) is the wiring
registry. It is the **authoritative init order**, and it is included in the
library at
`Systems/SharedUtilities/Source/ServerScriptService/bootstrap.server.lua`.

It does, in order:

1. `createRemotes()` — creates all 47 remotes from `Remotes.Names`.
2. Initialises ~30 services in dependency order, with `Set*Service()`
   injections interleaved.
3. Boots Cmdr (`CmdrBootstrap.luau`).
4. Registers bases and the egg center from the Workspace.
5. Wires the player lifecycle: `onPlayerAdded` → load → assign base →
   restore → offline earnings → mark loaded → push state.
6. Sets `Players.CharacterAutoLoads = false` and implements a 5-second
   respawn delay with a generation guard.

**The full ordered list is in [`DEPENDENCY_MAP.md`](DEPENDENCY_MAP.md).**

### 3.4 Client / server split

- The client bootstrap (`bootstrap.client.lua`) creates 28 controllers in a
  fixed order, **without** `pcall` — a failure in one aborts the rest.
- The client never computes a price, a level, a weight, or an outcome. It
  sends ids and renders what comes back.
- The server never trusts a client-supplied value. This is the most
  important security property of the extraction.

### 3.5 The remote protocol

47 remotes, all created at boot from the `Remotes.Names` registry in
`Shared/CommonModules/Remotes.lua`. **Do not hand-author them** — copy the
registry, or the names will drift.

Naming is consistent:

- `<Thing>Action` — client → server intent.
- `<Thing>Result` / `<Thing>State` / `<Thing>Update` — server → client.
- `Remotes.Ready` is a `Signal` that fires when the folder is populated.

### 3.6 The config domain tree

```text
ReplicatedStorage/Config/
├── Creatures/    Animals, Eggs, Mutations, Traits, Rarity, Progression
├── Economy/      Money, Sell, Gear, Rebirth, Rewards, Shop
├── Presentation/ UI, Audio, Vfx, Messages
├── Systems/      Debug, Security
└── World/        Arena, ArenaFeel, Bases, Events, Movement, Prompts, Stealing
```

Every domain module is frozen and exposes `Validate(): { string }` returning
a list of problem strings (empty = valid). `ConfigValidator` holds a
registry of 19 domains and cross-config invariants, and is checked at boot:
**a validation failure is a hard error in Studio and a warning in a live
server** — a bad tuning value must never crash production.

**Known gap:** `Economy.Shop` and `Economy.Gear` are **not** registered in
`ConfigValidator`, and `Shop.lua` has **no `Validate()` at all**. The price
ladder and duplicate-ProductId checks are therefore not enforced at boot.
Recorded, not fixed.

### 3.7 The Event engine's rule

`Config/World/Events.lua` carries the mantra:

> **CONFIG DEFINES WHAT. ENGINE DEFINES HOW.**

Path conventions in event config: `Map....`, `Base....`, and `*` as a
wildcard. The engine (`EventService`) knows nothing about galaxy or
snowfall; the config names them. This is the cleanest portable subsystem in
the library.

---

## 4. Persistence

### 4.1 The profile

- **Library:** `ProfileService`. A **verbatim copy** of the source game's
  `src/Vendored/ProfileService.lua` lives at
  `ReusableSystems/Vendored/ProfileService.lua`, so the library's own test
  and example projects build without reaching into `src/`. It is
  third-party code, not extracted game source — see
  `EXTRACTION_MANIFEST.md` §1.1. In your own game, either install it from
  Wally or keep the vendored copy; the only requirement is a module named
  `ProfileService` at `ServerScriptService.Packages.ProfileService`.
- **DataStore name:** `p7_PlayerData_Money_v1_dev_1` — a hardcoded literal
  in `PlayerService.lua:115`. No environment computation. Changing it
  abandons the old data.
- **Key format:** `Player_<userId>`.
- **Release handler:** `'ForceLoad'` — steals the session lock from a
  possibly-live session. Fine for a dev store, questionable for production.
- **Schema:** 19 top-level keys, documented in
  `Systems/PlayerData/Dependencies.md` → *Profile Schema*.

### 4.2 The three-stage load

```text
profile:Reconcile()          ← fills MISSING keys from the template
  → ~20 per-field repair blocks   ← fixes WRONG-TYPE values Reconcile leaves alone
    → PersistenceAudit             ← validates the owned-object lists
```

`Reconcile` will not fix a field that exists with the wrong type, so the
repair blocks are not optional. `PersistenceAudit` then repairs, quarantines,
or re-homes invalid animal/egg records before anything else reads them.

### 4.3 Other DataStores

| Store | Used by | Key format | Notes |
|---|---|---|---|
| `p7_PlayerRegistry_v1` | `PlayerRegistry` | `player_<userId>` (one key per player) | Separate from the gameplay profile. One key per player so it never becomes one growing blob. |
| *(ordered)* — `LeaderboardService` | `LeaderboardService` | see `Leaderboards/Dependencies.md` | `OrderedDataStore` for global ranking. |

### 4.4 Money is a string

`Data.Money` is a **BigNumber decimal string**, never a Lua number.
`BigNumber` is a hand-rolled arbitrary-precision decimal-string
implementation — no external library. Canonical form: no leading zeros, no
trailing fraction zeros, no sign for zero.

`TransactionReason` is a closed enum of 17 values. Every money movement
carries one.

**Two places bypass `EconomyService`** and write `Data.Money` directly:
`PlayerService.WipeUser` and `RebirthService`. Those writes skip the audit
trail and the `MaxMoney` cap. Recorded, not fixed.

### 4.5 The unified slot pool

Every base has `Slots.Count` slots. A slot holds **either** an egg **or** an
animal — not both, and not separate lists. Slot ids are
`p7:<userId>:slot:<index>`. `ArenaSlotIndexBase = 1000` offsets arena slots
out of the base's index range.

`ReplicatedStorage/Types/PlayerDataType.lua` is **stale** — it declares
`Cash: number` and four fields; the live schema has `Money: string` and
nineteen. It is required by nothing. It is copied verbatim and flagged, not
silently "fixed".

---

## 5. Integration Instructions

The full procedure is in each system's `Setup.md`. The general shape:

### 5.1 Add the library to a Rojo project

```json
{
  "name": "my-game",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "$path": "src/ReplicatedStorage",

      "Config": { "$path": "ReusableSystems/Systems/Economy/Source/ReplicatedStorage/Config" }
    },
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "$path": "src/ServerScriptService"
    }
  }
}
```

**The catch:** the library's `Source/` trees are per-system, so a single
Roblox path can be fed by several folders. Rojo cannot map two `$path`s to
one instance. The working pattern is to **copy** the system folders into
your own `src/` tree (preserving the sub-paths), or to point `$path` at the
system folder that owns that path and add the rest as siblings.

This is why each system has a `Dependencies.md` with an explicit
"Library path → Roblox destination" table. **Follow that table; do not
guess.**

### 5.2 Install the third-party packages

From `wally.toml` in the source game:

| Package | Version | Needed by |
|---|---|---|
| `sleitnick/signal` | 1.5.0 | `Shared/Utilities/Signals.lua` (re-export) |
| `osyrisrblx/t` | 2.2.1 | `Shared/Utilities/Validation.lua` (re-export) |
| `kineticwallet/janitor` | 1.17.0 | `PlayerService`, `AnimalService`, others |
| `evaera/cmdr` | 1.12.0 | `AdminTools` |
| `TopbarPlus` | 3.4.0 | client topbar controllers |
| `roblox/testez` | 0.4.1 | the test suite (**dev dependency**) |
| `ProfileService` | vendored (copy in `ReusableSystems/Vendored/`) | `PlayerData` |

**Dead dependencies:** `Fusion` 0.3.0 and `Promise` 4.0.0 are declared in
`wally.toml` and installed, but **nothing in `src/` requires them**. They are
safe to drop. Do not carry them into a new project.

### 5.3 Wire the bootstrap

Follow the order in `DEPENDENCY_MAP.md`. The essential shape:

```lua
-- ServerScriptService/bootstrap.server.lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
Remotes.CreateRemotes()  -- or the equivalent your bootstrap uses

local EconomyService = require(…EconomyService)
local PlayerService  = require(…PlayerService)

EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)
PlayerService.Init()
-- … etc, in the documented order
```

### 5.4 Wire the remotes

Copy `Shared/CommonModules/Remotes.lua` → `ReplicatedStorage/Utility/Remotes.lua`
and create the folder at boot from `Remotes.Names`. The client and the
server both read the same registry, which is what keeps the 47 names in
sync.

### 5.5 Author the Studio assets

**None of the GUI, models, sounds, or the map are in this repository.**
`src/StarterGui/` and `src/Workspace/` contain only `.gitkeep`. Every system
documents the exact hierarchy it expects in its `Dependencies.md` →
*Assets*. Budget real time for this — it is usually longer than the code
work.

### 5.6 Do not forget

- **Change the DataStore name**, with an environment suffix and a schema
  version.
- **Change every `ProductId` / gamepass ID.**
- **Empty the admin allowlist** (the library copy already is).
- **Set the Discord webhook as a Studio attribute**, not in source.
- **Run the test suite in Studio** — see §7.

---

## 6. Configuration Guide

### 6.1 Where values live

| Kind | Location | Example | Committed? |
|---|---|---|---|
| **Game design** | The owning `Config/<Domain>/<Module>.lua` | `Economy/Money.lua` → `StartingMoney = '5000'` | Yes |
| **Technical** | `Config/Systems/Security.lua`, `Config/Systems/Debug.lua` | `RequestThrottleSeconds = 0.5` | Yes |
| **Environment-specific** | The owning module, one place | `Economy/Shop.lua` → `ProductId` | Yes (public ids) |
| **Secrets** | **Nowhere in the repo.** Studio attribute / `HttpService:GetSecret` / env var. | Discord webhook | **No** |

`ReusableSystems/Config.lua` files are **documentation-and-consolidation**
views of the values a system uses. They are not a second source of truth: the
runtime still reads `ReplicatedStorage/Config/...`. Where a `Config.lua`
disagrees with the runtime module, **the runtime module wins** — the
`Config.lua` is a reading aid. This is stated in every such file's header.

### 6.2 The `Validate()` contract

Every config domain module exposes:

```lua
function Module.Validate(): { string }
```

Returning a list of problem descriptions. Empty = valid. The registry
`Shared/Utilities/ConfigValidator.lua` runs all 19 domains plus
cross-config invariants at boot:

- the price ladder is monotonic,
- `Progression.XP.GrowthRate` is `1.12` (also asserted by `UpgradeService`
  at load — it is **pinned**),
- `LuckPoolOrder ⊆ Rarity.Order`,
- gear combat entries join the combat tables,
- baseline sanity checks.

**Gap:** `Economy.Shop` and `Economy.Gear` are not registered, and `Shop.lua`
has no `Validate()`. A new game that adds prices should add one.

### 6.3 Pinned values

These must not be changed without reading the code that depends on them:

| Value | Pinned to | Enforced by |
|---|---|---|
| `Progression.XP.GrowthRate` | `1.12` | `UpgradeService` asserts at load |
| `Progression.MaxLevel` | `100` | `Progression.Normalize` |
| `Progression.PointsPerLevel` | `3` | `UpgradeService` |
| `SlotType.ArenaSlotIndexBase` | `1000` | `SlotType` |
| `SlotType.MaxArenaStands` | `99` | `SlotType` |
| `Economy.Money.MaxMoney` | `'1000000000000000'` | `EconomyService` |
| `OwnedObjectIdentity` id format | `AN_`/`EG_` + 10 base-62 chars | `OwnedObjectIdentity` (the only place) |

---

## 7. Compatibility and Known Issues

### 7.1 The test suite has never been executed as committed

This is the most important thing in this section. The 89 specs are written
and the test place builds, but the suite **has never been run**.

| # | Defect | Status in this library |
|---|---|---|
| 1 | `TestRunner.server.lua` requires `script.Parent.Parent.Packages.TestEZ`. The real path is `script.Parent.Parent.Packages.DevPackages.TestEZ`. | **FIXED** — the library's `Tests/TestRunner.server.lua` is a library-authored file, not a copy. |
| 2 | `TestRunner.server.lua` calls `TestEZ.RunBootstrap()`, which does not exist in TestEZ 0.4.1. The 0.4.1 API is `TestEZ.run(testRoot, callback)` plus `TestEZ.Reporters.TextReporter.report(results)`. | **FIXED** — same file, same reason. |
| 3 | `AnimalXP.spec.lua` returns a **table**, not a function. TestEZ 0.4.1 expects `return function() … end` (the other 88 do this). | **STILL PRESENT** — the specs are byte-identical copies, and fixing one is a production change. |

**Consequence for this library:** every "tested" claim in the system docs
means *"a spec exists that was written against this code"* — **not** *"the
spec was observed passing"*. The library copies the specs verbatim and
documents this in `Tests/README.md`.

**The suite still needs Roblox Studio.** TestEZ is a Roblox-runtime-only
framework and this repository has no headless Luau runner, so the suite was
**not** executed during the extraction. It was verified to *build* — see
`Tests/README.md` §3 for the exact two-step procedure.

### 7.2 Static-analysis findings (pre-existing, not fixed)

The library was linted with the **same** tools and the **same** config as
the source game, and the findings were compared file-by-file against the
`src/` baseline. The result:

| Linter | `src/` findings | Library findings | Library-only |
|---|---|---|---|
| `selene` (repo `selene.toml`, `std = "roblox"`) | 6 726 | 6 723 | **0** |
| `stylua --check` (repo `stylua.toml`) | 77 files | 75 files | **0** |

Every finding in the library is **byte-for-byte the same finding in the
source game's original file**. The extraction introduced none. The counts
differ only because of the two `src/` files that are deliberately not
copied (see §7.6) and because the library's own copy of
`PlayerLoggerConfig.lua` no longer carries the formatting drift.

Re-run the comparison yourself with:

```bash
python ReusableSystems/Tools/triage_lint.py
```

**The findings themselves:**

| Lint | Location | Nature |
|---|---|---|
| `undefined_variable` | `src/ServerScriptService/Steal/StealService.lua:444` (`_thiefSpeed`) | **Real runtime bug** — the `local` is declared at line 587, *below* the use, so the name is an undefined global and `nil[userId]` **throws**. See `SECURITY_NOTES.md` §5 S-3 / S-7. |
| `undefined_variable` ×many | every `*.spec.lua` (`describe`, `it`, `expect`) | **False positive** — TestEZ injects these globals at runtime. Selene's `roblox` std has no TestEZ std. |
| `if_same_then_else` ×5 | `src/ReplicatedStorage/Utility/AnimalShowcase.lua:82, 84, 86, 114, 116` | Style — a chain of `elseif` branches that all call `desc:Destroy()`. |
| `unused_variable` ×4 | `Carry/ResetProtectionService.lua:70`, `Carry/PlayerGrabService.lua:65`, `Combat/RagdollService.lua:35`, `Rebirth/RebirthService.lua:42` | Style. |
| `shadowing` | `StarterPlayerScripts/BatController.lua:186` (`character`) | Style. |
| `incorrect_standard_library_use` | many spec files (`assert` with 1 argument) | **False positive** — TestEZ's `assert` takes a message. |
| `manual_table_clone` | `src/Vendored/ProfileService.lua:2397` | In vendored third-party code. |
| `stylua --check` fails on 77 files | across `Config/`, `ClientPresentation/`, and the services | Formatting drift, mostly **CRLF line endings** against the repo's `line_endings = "Unix"`. |

**None of these were fixed** — the rules forbid fixing unrelated production
bugs during extraction. They are recorded here so the owner can decide.

### 7.3 A server/client asset-id mismatch

`TutorialService.BeamAssetId()` returns `14403995847`, but the client
(`TutorialController.lua`) and the spec (`TutorialService.spec.lua:267`)
both expect `17476697388`. The server and client are out of sync — the
tutorial beam will not display. Recorded, not fixed.

### 7.4 Other behavioural gaps

- **`AdminConfig.SuperadminGroup = 'Superadmin'` never matches
  `AdminConfig.RankOrder.superadmin`.** The rank table's keys are
  lowercase; the group name is capitalised. `AdminService.CanRun` refuses
  an unknown rank name by default, so `AssertCanRun(userId, 'Superadmin')`
  is **always false** — `/addadmin`, `/removeadmin` and `/shutdown` deny
  **everyone**, including real superadmins. One-character fix in the
  source game; **not fixed here**. Full analysis in
  [`SECURITY_NOTES.md`](SECURITY_NOTES.md) §5 S-6.
- **`AdminConfig` docstring vs content.** The source file says *"the prod
  list is intentionally empty here"* — it was not; it held 5 entries. The
  library copy is now genuinely empty and the docstring is accurate.
- **`resetCash` declares `Group = 'Admin'` but gates on
  `AssertCanRun(userId, 'superadmin')`.** The gate is stricter than the
  group, so it is not a hole, but the two disagree.
- **`eventServer.lua` hardcodes the event ids `'galaxy'` and `'snowfall'`,
  contradicting the Event engine's "config defines what" rule.**
- **Global code-redemption counters are per-server and in-memory.** They
  reset on restart and are not shared across servers. `MaxGlobalRedemptions`
  therefore means "per server instance", not "per game".
- **`Debug.SkipPersistence` shares mutable tables across players.** In that
  mode, `Settings`, `Stats`, `Arena`, `DailyRewards`, and `PlaytimeRewards`
  are not deep-cloned per player (unlike `Multipliers`, `Tutorial`, and the
  two object lists). Studio-only footgun.
- **`wally.lock` declares `registry = "test"` while `wally.toml` declares
  `registry = "https://github.com/UpliftGames/wally-index"`.** A clean
  `wally install` may re-resolve differently or fail validation. Verify on
  a fresh clone before promising a reproducible install.
- **The client bootstrap has no `pcall`.** A failure in one of the 28
  controllers aborts the rest of the client layer.
- **`Data.Money` is written directly** in `WipeUser` and `RebirthService`,
  bypassing `EconomyService`'s audit trail and cap.
- **`EventService._TestReset()` leaves a live heartbeat running.** A test
  that calls it leaves a `Heartbeat` handler bound to a service it
  believes is idle.
- **Two specs assert values the config does not have.**
  `ConfigArchitecture.spec.lua:183` expects `WalkSpeed == 24` but
  `Config/World/Movement.lua:129` sets `20`;
  `BaseLockTimer.spec.lua:99` expects `LockDurationSeconds == 30` but
  `Config/World/Bases.lua:187` sets `60`.
- **`AnimalOverhead.spec.lua` expects `Triceratops` to be Legendary; it is
  Mythic** (`Config/Creatures/Animals.lua:161`). `AnimalWalkHandoff.spec.lua`
  additionally has two no-op assertions (`expect(true).to.equal(true)`).
- **The production *test* build cannot resolve `ProfileService`.**
  `test.project.json` maps `ServerScriptService/Packages` to
  `ServerPackages/` (which holds `Cmdr.lua`, `Janitor.lua`, `_Index/`) but
  **not** `src/Vendored/ProfileService.lua` — that mapping exists only in
  `default.project.json`. So `PlayerService.lua:61` cannot resolve its
  require in the `p-7-tests` build, and any spec that touches
  `PlayerService` will fail for that reason. **Pre-existing and not fixed
  here**: all four inputs are byte-identical to commit `5a1cb35`. The
  library's own test project maps it correctly. Full analysis in
  [`SECURITY_NOTES.md`](SECURITY_NOTES.md) §5 S-11.

### 7.5 Stale source-game documentation

The source repo's own `Docs/` folder (45 files) contains several documents
that no longer match the code:

| Document | Stale in |
|---|---|
| `Docs/architecture/ARCHITECTURE_V2.md` | A *target* doc. Its file map, its 11-step bootstrap order (the real one is ~35), a deleted `GameConfig` reference, and "6 slots" (now 8). |
| `Docs/configuration/Animals.md` | Says `GrowthRate 1.25`; the live value is `1.12`. |
| `Docs/CMDR_COMMANDS.md` | Says 66 commands; the directory holds 136 files. |
| `Docs/CURRENT_SYSTEM_README.md` | Pinned to an older commit, old `Brainrot`/`LuckyBlock` terminology. |

**This library does not copy the source repo's `Docs/` folder.** The library
documentation is written from the code, not from those documents. Where this
library and `Docs/` disagree, **this library is correct** — because it was
derived from the current code.

### 7.6 The two `src/` files that are deliberately not copied

Of the **421** `.lua`/`.luau` files in the source game's `src/` tree, **419**
are in the library as extracted game source. The two that are not, and why:

| `src/` file | Why it is not counted as extracted game source | What to do instead |
|---|---|---|
| `src/Vendored/ProfileService.lua` | **Third-party code** (MadworkRoblox's standalone ProfileService, MIT). It is not this game's system, so it is not extracted game source. A **byte-identical copy** is kept at `ReusableSystems/Vendored/ProfileService.lua` so the library's own test and example projects build without reaching into `src/`. | Install `ProfileService` from Wally, or keep the vendored copy. `Systems/PlayerData/Setup.md` §2 says exactly how, and `ReusableSystems/Vendored/README.md` covers the choice. |
| `src/Tests/ServerScriptService/TestEZTests/TestRunner.server.lua` | It is a **defective** test runner (see §7.1, defects 1 and 2). Copying it would copy a runner that cannot start. | The library has its own **fixed** runner at `ReusableSystems/Tests/TestRunner.server.lua`. Use that one. |

Both exclusions are recorded in
[`EXTRACTION_MANIFEST.md`](EXTRACTION_MANIFEST.md) §4 with the same
"original path → reason" treatment as every other file.

---

## 8. Engineering Rules

These are the source game's rules, preserved. They are the reason the code
looks the way it does.

### 8.1 Server authority

> Clients send **intent and ids**. The server re-resolves prices, levels,
> weights, outcomes, and eligibility.

Never accept a client-supplied price, level, amount, or result. If a new
feature needs a number the client computed, the server recomputes it.
This is the single most important rule in the codebase, and the one most
likely to be broken by a careless port.

### 8.2 Money is a BigNumber string

Never a Lua number. Use `Shared/Utilities/BigNumber.lua`. Compare with
`BigNumber.Compare`, add with `BigNumber.Add`, and format with
`BigNumber.Format`. `TransactionReason` is a closed enum — extend it
deliberately.

### 8.3 Late-bound injection, never mutual require

Two services that need each other use `Set<Peer>Service()`. This is what
keeps the graph acyclic. If you find yourself about to `require` a peer
service from inside another, **inject it instead**.

### 8.4 One owner per profile field

Each profile key has exactly one owning system. Other systems read it; they
ask the owner to write it. `PlayerService.AssignBase` exists so that only
`BaseService` writes `BaseId`. When you add a field, decide its owner and
document it in `Dependencies.md`.

### 8.5 `pcall`-wrapped public entry points

Public service functions return a sentinel rather than throwing. A remote
handler must never be able to kill the server with a malformed payload.

### 8.6 `table.freeze` on exports

Except for the modules that genuinely hold mutable state: `Debug`,
`StudioTestMode`, `Remotes`.

### 8.7 Config defines what; the engine defines how

`Config/World/Events.lua` states it and the codebase mostly follows it. A
system's behaviour belongs in code; its *content* (which animals, which
prices, which events) belongs in config. If you find a hardcoded price or a
hardcoded animal id inside a service, that is a bug.

### 8.8 Studio assets are not in the repository

`src/StarterGui/` and `src/Workspace/` contain only `.gitkeep`. Every GUI,
model, sound, tool, and the map itself is authored inside Roblox Studio and
is **not** version-controlled here. Systems document the hierarchy they
expect; authoring it is part of every integration.

### 8.9 Type discipline

`--!strict` on every module, `--!native` on server modules. `selene` is
configured but currently reports 6 errors and 12 warnings (see §7.2) — all
pre-existing.

### 8.10 Version pinning

`aftman.toml` pins Rojo 7.7.0, Wally 0.3.2, StyLua 2.5.2, Selene 0.31.0.
`wally.lock` is the committed source of truth for package versions; the
`Packages/`, `ServerPackages/`, and `DevPackages/` directories are gitignored
and rebuilt by `wally install`.

### 8.11 Formatting

StyLua with the repo's `stylua.toml` (tabs, 120 columns). Run
`stylua --check src` before committing — it currently fails on 5 files
(§7.2).

### 8.12 Do not copy generated files

`Packages/`, `ServerPackages/`, `DevPackages/`, `sourcemap.json`, `.history/`,
`ignore/`, and `discord_bot/` are not part of this library. The extraction
manifest accounts for every file in `src/`; nothing else was copied.

---

## 9. Document Map

| Document | What it holds |
|---|---|
| [`README.md`](README.md) | Entry point. Contents, layout, how to use a system. |
| [`MEMORY.md`](MEMORY.md) | This file. The master knowledge document. |
| [`SYSTEM_INDEX.md`](SYSTEM_INDEX.md) | Every system in one table: purpose, entry point, config, dependencies, portability, tests. |
| [`DEPENDENCY_MAP.md`](DEPENDENCY_MAP.md) | What depends on what, the required init order, the Mermaid graph. |
| [`EXTRACTION_MANIFEST.md`](EXTRACTION_MANIFEST.md) | Every file in `src/`: original path → library destination → copied / adapted / excluded, with reasons. |
| [`PROJECT_SETUP.md`](PROJECT_SETUP.md) | Adding the library to a Rojo project; building it standalone. |
| [`SECURITY_NOTES.md`](SECURITY_NOTES.md) | Secrets, trust boundaries, environment-specific identifiers, and the issues found. |
| [`Templates/SystemConfigTemplate.lua`](Templates/SystemConfigTemplate.lua) | The four kinds of value and the `Validate()` contract. |
| [`Templates/SystemREADME.md`](Templates/SystemREADME.md) | The per-system README skeleton. |
| [`Templates/IntegrationChecklist.md`](Templates/IntegrationChecklist.md) | The pre-ship checklist. |
| [`Tests/README.md`](Tests/README.md) | How to run the suite — and why it needs Studio. |
| [`Examples/IntegrationExamples/`](Examples/IntegrationExamples/) | A full Economy + PlayerData walkthrough. |
| [`Examples/MinimalGame/`](Examples/MinimalGame/) | A runnable Rojo project mounting a subset. |
