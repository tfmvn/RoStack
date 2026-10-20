# ReusableSystems

A reusable systems library for Roblox games, extracted from **Brainrot Arena**
(the `p-7` project in this repository).

This is a **reference implementation with documentation**, not a package. The
source files are the real, working implementation from Brainrot Arena, copied
without behavioural change. What was added is the *context* that the original
game never needed: what each system does, what it depends on, which parts are
generic, which parts are Brainrot Arena content, and how to lift one into a
different game.

---

## Read This First

Three facts that determine how you use this library:

1. **The production game was not modified.** `src/` is untouched. Everything
   here is a copy. See `EXTRACTION_MANIFEST.md` for the file-by-file audit.

2. **This library is NOT in the Rojo build.** The production `default.project.json`
   does not map `ReusableSystems/`, so it cannot be deployed or shipped by
   accident. A separate `library.project.json` exists for building the library
   standalone — see `PROJECT_SETUP.md`.

3. **Files keep their original Roblox path.** Every file under
   `Systems/<Name>/Source/` sits at the path it occupied in the source game, so
   `require(script.Parent.X)` and `require(ReplicatedStorage.Config.Y)`
   resolve unchanged when you copy the tree to the same place. **Copy to the
   documented destination, or your requires will break.**

---

## Contents

| Document | What it answers |
|---|---|
| [`MEMORY.md`](MEMORY.md) | The master engineering knowledge file. Architecture, every system's behaviour, persistence model, integration steps, engineering rules. **Start here.** |
| [`SYSTEM_INDEX.md`](SYSTEM_INDEX.md) | Every discovered system in one table. Purpose, entry point, config, dependencies, portability, tests. |
| [`DEPENDENCY_MAP.md`](DEPENDENCY_MAP.md) | What depends on what, and the required initialisation order. |
| [`EXTRACTION_MANIFEST.md`](EXTRACTION_MANIFEST.md) | Every source file in `src/`: its original path, its destination here, and whether it was copied, adapted, or excluded. |
| [`PROJECT_SETUP.md`](PROJECT_SETUP.md) | How to add the library to a Rojo project, and how to build it standalone. |
| [`SECURITY_NOTES.md`](SECURITY_NOTES.md) | Secrets, trust boundaries, and what must never be committed. |

---

## Layout

```text
ReusableSystems/
├── Systems/          26 extracted systems, each self-contained
├── Shared/           Types, generic utilities, and modules used by many systems
├── Integrations/     Discord, Marketplace, analytics providers, external services
├── Templates/        Starting points for a new system, and a `wally.toml` template
├── Vendored/         One verbatim third-party file (ProfileService) — see its README
├── Tests/            The cross-cutting test suite + shared helpers
├── Tools/            Verification scripts (fidelity, require resolution, lint triage)
└── Examples/         A minimal game and integration walkthroughs
```

### `Systems/<Name>/`

Each system folder follows the same shape:

```text
Systems/Economy/
├── README.md          What it does, its entry points, its limitations
├── MEMORY.md          Compact notes for a future agent working on THIS system
├── Config.lua         The tunables, consolidated, with every value documented
├── Dependencies.md    Exact module paths, remotes, profile fields, assets
├── Setup.md           Step-by-step installation into a new project
├── API.md             Every public function, with behaviour and failure modes
├── Source/            The implementation, at its original Roblox path
├── Tests/             The spec files that cover it
└── Examples/          Where present, a usage snippet
```

Not every system has every file. A system with no separate config of its own
has no `Config.lua`; a system with no tests has no `Tests/`. Nothing is
created empty to fill a template.

---

## How to Use a System in a New Game

The short version. The long version is in `MEMORY.md` →
*Integration instructions*.

**1. Pick the system.** `SYSTEM_INDEX.md` tells you what each one does and
whether it is portable. The **Portability** column is the important one:

| Grade | Meaning |
|---|---|
| **A — Portable core** | The logic is game-agnostic. Copy it and point it at your own data. |
| **B — Game-specific adapter** | The *content* is Brainrot Arena's (animal catalogues, prices, GUI paths). Keep the shape, replace the content. |
| **C — Platform-bound** | It talks to Roblox services, DataStores, or the Marketplace. These are reusable, but they are not portable in the sense of being self-contained. |

**2. Read its `Dependencies.md`.** This lists the exact module paths, remotes,
profile fields, and Studio assets it needs. Anything you have not already
extracted, you extract too — the dependency is transitive and the map in
`DEPENDENCY_MAP.md` will tell you the closure.

**3. Copy the files.** Take everything under `Systems/<Name>/Source/` and put
it at the Roblox path recorded in `Dependencies.md`. The path is the original
one; that is deliberate.

**4. Copy the config.** `Config.lua` (if present) plus any config files the
system references. Tune the values. `Config.lua` documents, for each value:
its default, its valid range, whether changing it is safe, and whether other
modules depend on it.

**5. Wire the remotes.** If the system uses remotes, they must exist in
`ReplicatedStorage.Remotes` with the exact names from
`Shared/CommonModules/Remotes.lua`. The server creates them at boot from
that registry — copy that mechanism rather than hand-authoring them, or the
names will drift.

**6. Wire the bootstrap.** `Systems/<Name>/Setup.md` gives the exact
`require` + `Set*` + `Init()` sequence, and where it sits relative to the
other systems.

**7. Test it.** `Systems/<Name>/Tests/` holds the spec files that came with
the system. `Tests/README.md` explains how to run them.

---

## A Worked Example

`Examples/IntegrationExamples/` contains a full walkthrough: take the
**Economy** system, stand it up in an empty Rojo project, add **PlayerData**
for persistence, wire the HUD, and prove it works. Read
`Examples/IntegrationExamples/README.md`.

`Examples/MinimalGame/` is a small, runnable Rojo project that mounts a
subset of the library — useful for confirming the wiring before you commit to
a design.

---

## Configuration

Configuration is **not** centralised in one file. That is deliberate, and it
matches the source game, which was already refactored to a domain tree:

```text
ReplicatedStorage/Config/
├── Creatures/    Animals, Eggs, Mutations, Traits, Rarity, Progression
├── Economy/      Money, Sell, Gear, Rebirth, Rewards, Shop
├── Presentation/ UI, Audio, Vfx, Messages
├── Systems/      Debug, Security
└── World/        Arena, ArenaFeel, Bases, Events, Movement, Prompts, Stealing
```

Every domain module exposes `Validate(): { string }` and is checked at boot by
`Shared/Utilities/ConfigValidator.lua`. In Studio a validation failure is a
hard error; in a live server it is a warning, because a bad tuning value must
never crash production.

The four kinds of value, and where each belongs:

| Kind | Where it lives | Example |
|---|---|---|
| **Game design** | The domain config module | `Economy/Money.lua` → `StartingMoney` |
| **Technical** | `Config/Systems/Security.lua` | `RequestThrottleSeconds` |
| **Environment-specific** | The owning module, one place | `Economy/Shop.lua` → `ProductId` |
| **Secrets** | **Never in the repo.** Placeholder only. | Discord webhook URL |

`Templates/SystemConfigTemplate.lua` is the starting point for a new config
domain, including the `Validate()` contract.

`Templates/wally.toml` is a ready-to-copy `wally.toml` for a new game built
on this library: the source game's dependency list with the two **dead**
dependencies (`Fusion`, `Promise` — declared but never required) removed, and
a note about the `ProfileService` choice.

---

## Tests

89 TestEZ spec files came across with the library, plus the shared
`_Helpers.lua` and a **fixed** `TestRunner.server.lua`.

> **The suite has never been executed.** "89 specs" means *89 specs exist
> that were written against this code* — not *89 observed passing*. The
> source game's runner has two blocking defects (a wrong require path and a
> `TestEZ.RunBootstrap()` call that does not exist in TestEZ 0.4.1); both
> are **fixed** in the library's copy, which is a library-authored file. One
> spec defect remains (`AnimalXP.spec.lua` returns a table instead of a
> function). See `Tests/README.md` §1 and `MEMORY.md` §7.1.

**They require Roblox Studio.** There is no headless Luau runner in this
project, and the specs exercise real Roblox instances (`Instance.new`,
`Players`, `TweenService`, `ReplicatedStorage` replication), so they cannot be
run under plain `lua`/`luau`.

What the specs do *not* need: a live DataStore, a published place, or
real Robux. They stub the profile and the remotes through `_Helpers`.

### Running them

```bash
# 1. Materialise a merged Roblox tree (hard links — nothing is duplicated).
python ReusableSystems/Tools/generate_test_tree.py
python ReusableSystems/Tools/generate_test_project.py

# 2. Build the test place.
rojo build ReusableSystems/test.project.json -o build/lib-tests.rbxlx

# 3. Open it in Roblox Studio and press Play (server).
```

`ReusableSystems/test.project.json` is a **separate** project from the
production `default.project.json`. The production Rojo mapping was not
touched.

### `Tools/` — verification scripts

| Script | What it proves |
|---|---|
| `Tools/verify_fidelity.sh` | Every library file is **byte-identical** to its `src/` original (except the 2 documented security adaptations). Covers the source files, the 89 spec files, and the vendored third-party copy. |
| `Tools/check_requires.py` | Every `require` in the library resolves against the built tree. **1 243 checked, 0 broken, 10 dynamic.** Pass `--project <dir>` to check a self-contained project (e.g. the MinimalGame example) instead. |
| `Tools/triage_lint.py` | The library introduces **no new** stylua or selene findings versus the `src/` baseline. |
| `Tools/generate_test_tree.py` | Builds the merged hard-link tree the test project needs. |
| `Tools/generate_test_project.py` | Writes `ReusableSystems/test.project.json`. |

---

## What Is Not Here

- **Studio-authored assets.** `src/StarterGui/` and `src/Workspace/` contain
  only `.gitkeep` in the source repo — every GUI, model, sound, and tool is
  authored inside Roblox Studio and is not version-controlled. The library
  documents the exact hierarchy each system expects (see each system's
  `Dependencies.md` → *Assets*), but the assets themselves are not
  extractable from this repository.
- **The map.** Bases, collectors, stands, the arena area, and the leaderboard
  board are Studio content.
- **Third-party packages.** `Fusion`, `Promise`, `Signal`, `t`, `TopbarPlus`,
  `Cmdr`, and `Janitor` are Wally packages referenced by the host project's
  `wally.toml`, not copied into this library. `ProfileService` is the one
  exception: a verbatim copy lives in `Vendored/ProfileService.lua` so the
  library's own test project and example build without reaching back into
  the production `src/` tree. Delete it and install ProfileService from
  Wally instead — see `Vendored/README.md`.

---

## Conventions Used Here

- **Luau, `--!strict`** on every module, `--!native` on server modules.
- **Every module returns `table.freeze(...)`** — except the handful that
  legitimately hold mutable state (`Debug`, `StudioTestMode`, `Remotes`).
- **Services are singletons** with `Init()` / `Start()` / `Set<Peer>Service()`
  late-bound injection. Injection, not mutual `require`, is what keeps the
  dependency graph acyclic.
- **Server-authoritative.** Clients send intent and ids. Prices, levels,
  outcomes, and eligibility are always re-resolved server-side.
- **Money is a BigNumber decimal string**, never a Lua number.

These are the source game's rules, preserved. `MEMORY.md` →
*Engineering rules* explains each one and why it exists.
