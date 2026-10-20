# Tests

89 TestEZ spec files, a shared helper module, and a test runner.

---

## 1. The honest status

> **The suite has never been executed.** The runner defects that blocked it
> are **fixed in the library's copy** of `TestRunner.server.lua` (defects 1
> and 2 below). The third defect — a spec that returns a table instead of a
> function — is in a *spec* file, and the specs are copied byte-for-byte from
> the source game, so it is **still present**.
>
> This means: **"N specs" in any system document means "N specs exist that
> were written against this code" — not "N specs were observed passing".**
> Nothing in this library claims a test was observed green, because none
> was. There is no headless Luau runner in this repository and TestEZ is a
> Roblox-runtime library, so the suite can only be run in Roblox Studio.

The source game's own phase documents are consistent with this — they say
"specs written" and "NOT executed" in the same breath.

### The three defects

| # | File | Defect | Status in the library |
|---|---|---|---|
| 1 | `TestRunner.server.lua` | Requires `script.Parent.Parent.Packages.TestEZ`. That path does not exist. The real path is `script.Parent.Parent.Packages.DevPackages.TestEZ` — `test.project.json` nests `DevPackages` **inside** `Packages`. | **FIXED** in the library's copy. |
| 2 | `TestRunner.server.lua` | Calls `TestEZ.RunBootstrap()`. **That function does not exist in TestEZ 0.4.1.** The 0.4.1 API exports `TestEZ.run(testRoot, callback)` and the sub-modules `TestBootstrap`, `TestPlanner`, `TestRunner`, `Reporters.*`. | **FIXED** in the library's copy — it now calls `TestEZ.run(testRoot, cb)` and `TestEZ.Reporters.TextReporter.report(results)`. |
| 3 | `AnimalXP.spec.lua` | Returns a **table**, not a function. TestEZ 0.4.1's planner calls `plan:addRoot(module.path, module.method)` and expects a function that calls `describe`/`it`. The other **88 of 89** specs use `return function() … end`. | **STILL PRESENT.** The specs are byte-identical copies of the source game's, and this task is an extraction, not a production change. Convert it to the function form to run the whole suite. |

Defects 1 and 2 were fixed only in `ReusableSystems/Tests/TestRunner.server.lua`
— which is a **library-authored** file, not a copy. `src/` was left
byte-identical, so the source game still carries all three defects.

**Also note:** `AnimalOverhead.spec.lua` expects `Triceratops` to be
**Legendary**; it is **Mythic** (`Config/Creatures/Animals.lua:161`). And
`AnimalWalkHandoff.spec.lua`'s two "ForceReleaseBase" tests assert nothing
(`expect(true).to.equal(true)`). These are pre-existing spec-vs-source
contradictions, documented rather than fixed.

---

## 2. What the tests need

| Requirement | Needed? |
|---|---|
| **Roblox Studio** | **Yes.** TestEZ is a Roblox-runtime-only framework. |
| `lune` / `luau` / `lua` / `run-in-roblox` | Not available in this repository, and not needed — but there is **no headless runner here either**. |
| A live DataStore | **No.** Zero specs touch `DataStoreService`. |
| `Enable Studio Access to API Services` | **No.** Zero HTTP calls, zero Marketplace calls. |
| A published place | No. |
| Robux | No. |

The specs are designed to be **headless-safe**: no live server, no
DataStore, no multiplayer.

**Studio-only specs.** Two explicitly branch on `RunService:IsStudio()`:
`BaseLockTimer.spec.lua` and `StudioTestUserIds.spec.lua`. Fourteen others
stage their own `ServerStorage` fakes when the authored asset is absent:
`AnimalOverhead`, `AnimalTemplate`, `ArenaDeployment`, `ArenaSlots`,
`CollectFeedback`, `DynamicSlots`, `EventMutation`, `GearShop`,
`LevelUpPresentation`, `RollController`, `StandMenu`, `CarryService`,
`AnimalWalkHandoff`.

**Timing-sensitive specs.** Ten use `task.wait`, `Heartbeat`, or
`task.defer`: `AnimalWalkHandoff`, `ArenaBattle`, `ArenaDeployment`,
`ArenaResult`, `BaseLockTimer`, `CollectFeedback`, `EggWalkAnimator`,
`LevelUpPresentation`, `StandPresentation`, `TutorialService`.

**Volume:** ~1 180 `it(` calls across the suite.

---

## 3. How to run them

### The procedure

1. **Materialise the merged tree.** The library's sources are spread across
   28 system folders and the specs across per-system `Tests/` folders, but
   Rojo cannot merge two filesystem folders into one instance and the specs
   need `_Helpers.lua` as a *sibling*. So a merged tree of hard links is
   generated first:

   ```bash
   python ReusableSystems/Tools/generate_test_tree.py
   python ReusableSystems/Tools/generate_test_project.py
   ```

   The first script writes `ReusableSystems/Tests/Tree/` — 329 source files
   and 89 specs, each a **hard link** to the one real copy in its owning
   system folder. Nothing is duplicated, so editing a system file is
   immediately visible in the tree. The directory is a build artefact and is
   in `.gitignore`.

2. **Build the test place.**

   ```bash
   rojo build ReusableSystems/test.project.json -o build/lib-tests.rbxlx
   ```

   This has been verified to succeed.

3. **Open the built place in Roblox Studio.**

4. **Press Play** (server). `TestRunner.server.lua` runs automatically when
   the server starts, and TestEZ's `TextReporter` prints the results to the
   **Output** window.

5. **Fix defect 3** (`AnimalXP.spec.lua` returns a table) if you want the
   whole suite to run. Until then, TestEZ's planner will report that spec
   as an error and the other 88 will still run.

> There is **no `rojo serve` / live-sync workflow** documented for the test
> suite — the source repo's workflow is "build, then open in Studio".
> Live-sync works fine with `rojo serve test.project.json` if you prefer
> it; nothing in the suite depends on it. If you use live-sync, re-run
> `generate_test_tree.py` after adding a file to a system.

### The library's own test project

`ReusableSystems/test.project.json` is a **separate** project from the
production `default.project.json` and from the source game's
`test.project.json`. It mounts:

| Roblox path | From |
|---|---|
| `ReplicatedStorage.Config` | the merged tree |
| `ReplicatedStorage.Types` | the merged tree |
| `ReplicatedStorage.Utility` | the merged tree |
| `ReplicatedStorage.ShopAnimations` | the merged tree |
| `ReplicatedStorage.Packages` | the repo's `Packages/` (Fusion, Promise, Signal, TopbarPlus, t) |
| `ServerScriptService.*` | the merged tree |
| `ServerScriptService.Packages.Janitor` | the repo's `ServerPackages/` |
| `ServerScriptService.Packages.ProfileService` | the repo's `src/Vendored/ProfileService.lua` |
| `ServerScriptService.Packages.DevPackages.TestEZ` | the repo's `DevPackages/` |
| `ServerScriptService.TestEZTests` | **all 89 specs + `_Helpers.lua`, flat** |
| `StarterPlayer.StarterPlayerScripts` | the merged tree |

The specs are mounted **flat** into `TestEZTests` on purpose: that is the
layout they were written against, and it is what makes
`require(script.Parent._Helpers)` resolve.

**This project is for the library's own verification. It is not the
production place** — the production `default.project.json` was not modified.

### If you are running the specs in your own project

Copy `Tests/_Helpers.lua` and `Tests/TestRunner.server.lua` next to your
specs, and mount them at `ServerScriptService.TestEZTests` (or wherever
your `require` expects). The runner's require path must match where you
put TestEZ.

---

## 4. The layout

```text
ReusableSystems/
├── Systems/<Name>/Tests/        ← the specs, distributed by owning system
│   ├── EconomyService.spec.lua
│   ├── AnimalService.spec.lua
│   └── …
└── Tests/
    ├── _Helpers.lua             ← shared test utilities
    ├── TestRunner.server.lua    ← the runner (11 lines)
    ├── IntegrationTests/        ← 4 cross-cutting specs
    │   ├── Integration.spec.lua
    │   ├── InteractionLiveness.spec.lua
    │   ├── StandMenu.spec.lua
    │   └── StandPresentation.spec.lua
    └── README.md                ← this file
```

**89 specs total:** 85 under `Systems/*/Tests/`, 4 under
`Tests/IntegrationTests/`.

---

## 5. `_Helpers.lua`

The shared test utilities. Every test that makes Roblox instances goes
through these, so the surface stays small and the tests work in any order.

| Function | Signature | Behaviour |
|---|---|---|
| `MakeRng` | `(seed: number) -> () -> number` | A deterministic Park–Miller LCG: `state = (state * 48271) % 2147483647; return state / 2147483647`. No bitwise ops, no global state. `seed <= 0` → state 1. |
| `FakePlayer` | `(userId: number, name: string?) -> table` | A player stand-in with `UserId`, `Name` (default `'Player'..userId`), `Parent = Players`, and a `notifications` table. `p:Kick(reason)` sets `p._kicked`; `p:IsA(className)` is true only for `'Player'`; `p:IsDescendantOf(parent)` is true only for the `Players` service. |
| `StubRemotes` | `() -> Folder` | Destroys any existing `ReplicatedStorage.Remotes` folder, creates a fresh one with a `RemoteEvent` per name in `Remotes.Names`, and calls `Remotes.SetRemotes(folder)`. |
| `GetServices` | `() -> table` | Force-resolves the singleton services **in dependency order**: `PlayerService`, `EconomyService`, `SlotService`, `BaseService`, `EggService`, `AnimalService`. |
| `WireServices` | `() -> table` | **Idempotent.** Wires the same graph as the bootstrap: Economy → Player → Slot → Base → Egg → Animal, then Phase 2.7 (Modifier, Income) and Phase 2.8 (Sell), then Phase 2.10 (Upgrade). Returns the same table plus `ModifierService`, `SellService`, `IncomeService`, `UpgradeService`. |
| `EnsureCollectors` | `() -> Folder` | Pre-creates `Workspace.Bases.Base_<i>.Collector` for every base the service will register. **Must run before `RegisterBases`** — a base without a Collector is a fatal error. Each collector is a `Part`, `Size = Vector3.new(6,1,6)`, `Anchored`, `CanCollide = false`, `CanTouch = true`, placed 10 studs along −Z from the spawn (a clean 180° yaw, per ADR-004 §D4). |
| `RegisterBasesForTest` | `(services: any, userId: number) -> any` | If no bases are registered, calls `EnsureCollectors()` then `BaseService.RegisterBases(Workspace)`. Assigns the first base whose `state == 'Available'`. Errors `'RegisterBasesForTest: no available base'` if there is none. |

**Note:** `RegisterBasesForTest` uses the global `expect`, which TestEZ
injects — so it is only callable from inside a spec's `it`/`describe` body.

`_Helpers.lua` is not a `.spec` file, so TestEZ does not treat it as a test
module (TestEZ only collects `*.spec` ModuleScripts).

---

## 6. Using the suite in a new project

1. **Copy the specs you want.** They are plain TestEZ modules.
2. **Copy `_Helpers.lua`** alongside them.
3. **Make sure `Remotes` is available.** The specs call
   `StubRemotes()`, which requires `ReplicatedStorage.Utility.Remotes`. If
   your project has not created the remotes yet, `StubRemotes` will do it.
4. **Do not need the whole library.** Most specs stub what they do not
   test. `WireServices()` wires only six services.
5. **Expect some to fail.** The suite was never run. The specs are a
   written record of intended behaviour, not a verified baseline. Treat a
   failing spec as a **question about the code**, not automatically as a
   broken test.

---

## 7. What the suite does not cover

Stated plainly, so you do not assume otherwise:

| Not covered | Where it is actually verified |
|---|---|
| DataStore persistence | Studio playtest, manually. |
| Marketplace receipt grants | Studio playtest, manually. `ShopReceipt.spec.lua` covers the *routing*, not the grant effects. |
| HTTP delivery (`PlayerLogger` webhook) | Studio playtest, manually. `PlayerLogger.spec.lua` explicitly excludes it. |
| The map / Studio assets | Studio playtest, manually. |
| The client UI | Studio playtest, manually. There are no client specs. |
| The admin command set | `AdminFramework.spec.lua` covers the framework, not the 68 commands. |

---

## 8. Reference

| File | What |
|---|---|
| `wally.toml` | `[dev-dependencies] TestEZ = "roblox/testez@^0.4.0"` → resolved to `roblox_testez@0.4.1`. |
| `wally.lock` | The committed source of truth for the resolved version. |
| `test.project.json` | The test place. Adds `ServerScriptService.DevPackages` → `DevPackages` and `ServerScriptService.TestEZTests` → `src/Tests/ServerScriptService/TestEZTests`. |
| `aftman.toml` | Pins TestEZ's host tools: Rojo 7.7.0, Wally 0.3.2, StyLua 2.5.2, Selene 0.31.0. |

`DevPackages/`, `Packages/`, and `ServerPackages/` are **gitignored** — they
are rebuilt by `wally install`.
