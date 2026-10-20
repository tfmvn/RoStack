# Project Setup

How to get this library into a Roblox project, and how to build it on its
own.

---

## 1. The Rojo projects in this repository

There are **four** Rojo project files. **Three of them are the source
game's**; only the last one is the library's, and only the last one was
added by this task.

| File | Place name | Purpose | Maps | Added by this task? |
|---|---|---|---|---|
| `default.project.json` | `p-7` | **The production game.** | `src/` | **No** — untouched. |
| `test.project.json` | `p-7-tests` | The production game + the source game's test tree. | `src/` + `src/Tests/` + `DevPackages/` | **No** — untouched. |
| `ReusableSystems/test.project.json` | `reusable-systems-tests` | **The library's own test place.** | The merged tree in `ReusableSystems/Tests/Tree/` + the repo's `Packages/`, `ServerPackages/`, `DevPackages/` | **Yes** |
| `ReusableSystems/library.project.json` | `reusable-systems` | **This library, standalone, browse-only.** | `ReusableSystems/` | **Yes** |

### 1.1 The library is NOT in the production build

`default.project.json` does **not** map `ReusableSystems/`. Verified:

```bash
$ grep -c ReusableSystems default.project.json
0
```

The library therefore cannot be deployed, published, or shipped merely
because it exists in the repository. **The production Rojo mapping was not
altered by this task** — `default.project.json` and `test.project.json` are
both byte-identical to commit `5a1cb35`.

Verified across the whole production surface:

```bash
$ git status --porcelain -- src/ Packages/ DevPackages/ ServerPackages/ \
      default.project.json test.project.json wally.toml wally.lock aftman.toml
(empty)
```

### 1.1a Dev-tooling files changed alongside the library

Two **development-tooling** files at the repository root were touched. They
are not referenced by any Rojo project and cannot affect the running game:

| File | Change | Why |
|---|---|---|
| `.gitignore` | Added `ReusableSystems/Tests/Tree/` | The generated test tree is hard links to the per-system `Source/` trees. It is rebuilt by `ReusableSystems/Tools/generate_test_tree.py` and must not be committed. |
| `selene.toml` | Added `ReusableSystems/Vendored` and `ReusableSystems/Tests/Tree` to `exclude` | `Vendored/` holds verbatim third-party code. Reformatting it or "fixing" its lint findings would break the byte-identical guarantee that `Tools/verify_fidelity.sh` enforces. |
| `.styluaignore` | **New file** | The same reason, for StyLua. StyLua has no `exclude` key in `stylua.toml`, so it uses a separate ignore file. |

Nothing under `src/`, `Packages/`, `ServerPackages/`, `DevPackages/`,
`default.project.json`, `test.project.json`, `wally.toml`, `wally.lock`, or
`aftman.toml` was modified. See the verification block above.

### 1.2 Building the library standalone

```bash
rojo build library.project.json -o build/reusable-systems.rbxl
```

This produces a **browse-only** place: the whole `ReusableSystems/` tree
mapped into a single `ReusableSystems` folder. Open it in Studio to read the
code and the documentation in a real editor.

> ⚠️ **It does not run.** The library's `Source/` trees preserve each file's
> *original* Roblox path (`Systems/Economy/Source/ServerScriptService/…`),
> so in the browse place the modules are not at the paths their `require`
> calls expect. The browse place is for reading, not for playing.
>
> To get a **runnable** build, use `Examples/MinimalGame/` — it has a real
> project file and a real bootstrap.

---

## 2. Adding the library to a new game

### 2.1 The approach: copy, don't mount

**The recommended approach is to copy the files you need into your own
`src/` tree**, preserving the sub-paths, and commit them.

Why copying beats mounting:

- **Rojo cannot merge two directories into one instance.** The library
  splits `ReplicatedStorage/Utility/` across `Shared/Utilities/` and
  `Shared/CommonModules/`, and splits `ReplicatedStorage/Config/` across
  20 different system folders. A single `$path` cannot express that.
- **A copied tree is a normal tree.** Your `src/` looks like every other
  Roblox project, `default.project.json` needs no exotic mappings, and
  Studio's live-sync works.
- **You will edit it anyway.** You will rename `Brainrot` to whatever your
  game calls its creatures, and you will retune every price. A vendored copy
  is far easier to edit than a mounted one.

### 2.2 The steps

**Step 1 — copy the system folders you want.**

Each system's `Dependencies.md` has an explicit table:

| Library path | Roblox destination |
|---|---|
| `Source/ServerScriptService/EconomyService.lua` | `ServerScriptService.EconomyService` |
| `Source/ReplicatedStorage/Config/Economy/Money.lua` | `ReplicatedStorage.Config.Economy.Money` |

Copy **the whole `Source/` tree** of each system you take, into a directory
that mirrors the Roblox path.

```bash
# example: take Economy + PlayerData
mkdir -p mygame/src/ServerScriptService/Base
mkdir -p mygame/src/ReplicatedStorage/Config/Economy
mkdir -p mygame/src/ReplicatedStorage/Config/Systems
mkdir -p mygame/src/ReplicatedStorage/Utility
mkdir -p mygame/src/ReplicatedStorage/Types

cp -r ReusableSystems/Systems/Economy/Source/ServerScriptService/EconomyService.lua \
      mygame/src/ServerScriptService/
cp -r ReusableSystems/Systems/Economy/Source/ServerScriptService/IncomeService.lua \
      mygame/src/ServerScriptService/
cp -r ReusableSystems/Systems/Economy/Source/ServerScriptService/ModifierService.lua \
      mygame/src/ServerScriptService/
cp -r ReusableSystems/Systems/Economy/Source/ServerScriptService/SellService.lua \
      mygame/src/ServerScriptService/
cp -r ReusableSystems/Systems/Economy/Source/ReplicatedStorage/Config/Economy/Money.lua \
      mygame/src/ReplicatedStorage/Config/Economy/
cp -r ReusableSystems/Systems/Economy/Source/ReplicatedStorage/Config/Economy/Sell.lua \
      mygame/src/ReplicatedStorage/Config/Economy/

cp -r ReusableSystems/Systems/PlayerData/Source/ServerScriptService/PlayerService.lua \
      mygame/src/ServerScriptService/
cp -r ReusableSystems/Systems/PlayerData/Source/ServerScriptService/Base/PersistenceAudit.lua \
      mygame/src/ServerScriptService/Base/

cp -r ReusableSystems/Shared/Types/*.lua        mygame/src/ReplicatedStorage/Types/
cp -r ReusableSystems/Shared/Utilities/*.lua    mygame/src/ReplicatedStorage/Utility/
cp -r ReusableSystems/Shared/CommonModules/*.lua mygame/src/ReplicatedStorage/Utility/
```

> **Note the last three lines.** `Shared/Types/` → `ReplicatedStorage/Types/`,
> and **both** `Shared/Utilities/` and `Shared/CommonModules/` →
> `ReplicatedStorage/Utility/`. They merge into one folder because that is
> where they lived in the source game. `ShopAnimations.lua` is the
> exception — it goes to `ReplicatedStorage/ShopAnimations.lua`, not into
> `Utility/`.

**Step 2 — install the third-party packages.**

```bash
cd mygame
wally install
```

From the source game's `wally.toml`:

```toml
[dependencies]
Signal = "sleitnick/signal@1.5.0"
t = "osyrisrblx/t@2.2.1"
Janitor = "kineticwallet/janitor@1.17.0"
Cmdr = "evaera/cmdr@1.12.0"
TopbarPlus = "1foreverhd/topbarplus@3.4.0"

[dev-dependencies]
TestEZ = "roblox/testez@^0.4.0"
```

**Do not copy `Fusion` or `Promise`** — they are declared in the source
game's `wally.toml` but nothing requires them. They are dead dependencies.

**Step 3 — add `ProfileService` if you are taking PlayerData.**

```bash
# Either via Wally:
#   ProfileService = "LiteralIsaac/ProfileService@..."  (or your fork)
# Or vendor it:
mkdir -p mygame/src/Vendored
cp path/to/ProfileService.lua mygame/src/Vendored/ProfileService.lua
```

and in your `default.project.json`:

```json
"ServerScriptService": {
  "$className": "ServerScriptService",
  "$path": "src/ServerScriptService",

  "Packages": {
    "$className": "Folder",
    "ProfileService": {
      "$className": "ModuleScript",
      "$path": "src/Vendored/ProfileService.lua"
    }
  }
}
```

**Step 4 — write your `default.project.json`.**

```json
{
  "name": "my-game",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "$path": "src/ReplicatedStorage"
    },
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "$path": "src/ServerScriptService"
    },
    "StarterPlayer": {
      "$className": "StarterPlayer",
      "StarterPlayerScripts": {
        "$className": "StarterPlayerScripts",
        "$path": "src/StarterPlayer/StarterPlayerScripts"
      }
    },
    "StarterGui": {
      "$className": "StarterGui",
      "$path": "src/StarterGui",
      "$ignoreUnknownInstances": true
    },
    "Workspace": {
      "$className": "Workspace",
      "$path": "src/Workspace",
      "$ignoreUnknownInstances": true
    }
  }
}
```

**Step 5 — install the remote registry.**

`Shared/CommonModules/Remotes.lua` → `ReplicatedStorage/Utility/Remotes.lua`.
Both the client and the server read it, and the server creates the 47
remotes at boot from `Remotes.Names`. **Do not hand-author the remotes** —
copy the registry mechanism or the names will drift.

> **Important:** the `Remotes` module has **no** creation function. Creating
> the folder and the 47 `RemoteEvent`s is a **local `createRemotes()`
> inside `bootstrap.server.lua`** (`bootstrap.server.lua:203-222`). Copy
> that function into your bootstrap — it is 20 lines and it is the only
> thing that keeps the client and server registries in sync.
>
> The `Remotes` module exposes: `Names`, `Ready` (a Signal), `SetRemotes`,
> `GetFolder`, `WaitForReady`, `FireClient`, `FireAllClients`,
> `OnClientEvent`.

**Step 6 — wire the bootstrap.**

Follow the order in [`DEPENDENCY_MAP.md`](DEPENDENCY_MAP.md) §2. The
essential shape:

```lua
-- ServerScriptService/bootstrap.server.lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)

-- copy createRemotes() from the library's bootstrap.server.lua:203-222
local function createRemotes() … end
createRemotes()

local EconomyService = require(script.Parent.EconomyService)
local PlayerService  = require(script.Parent.PlayerService)

EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)
PlayerService.Init()
-- … the rest, in the documented order
```

**Step 7 — author the Studio assets.**

None of the GUI, models, sounds, tools, or the map are in this repository.
Each system's `Dependencies.md` → *Assets* lists the exact hierarchy it
expects. Budget real time for this.

**Step 8 — change the environment-specific values.**

See [`SECURITY_NOTES.md`](SECURITY_NOTES.md) §4 for the full list. The
non-negotiables:

- [ ] The profile DataStore name — with an environment suffix.
- [ ] Every `ProductId` and gamepass id.
- [ ] The admin allowlist (already empty in this library).
- [ ] The Discord webhook — as a **Studio attribute**, never in source.

**Step 9 — run the tests.**

See [`Tests/README.md`](Tests/README.md). They need Roblox Studio.

---

## 3. The MinimalGame example

`Examples/MinimalGame/` is a **runnable** Rojo project that mounts the
smallest useful subset of the library:

```text
PlayerData + Economy + the shared utilities they need
```

It exists so you can confirm the wiring before committing to a design.

```bash
cd ReusableSystems/Examples/MinimalGame
./setup.sh          # copies the needed library files into ./src
rojo build minimalgame.project.json -o build/minimalgame.rbxl
```

Open `build/minimalgame.rbxl` in Studio, press **Play**, and you get a
player with a persisted BigNumber wallet, a starting balance, and a HUD
showing the money. No gameplay — just the data spine, working.

See `Examples/MinimalGame/README.md`.

---

## 4. The IntegrationExamples example

`Examples/IntegrationExamples/` is a **walkthrough**, not a project. It
takes the Economy system and stands it up in an empty project step by step:
what to copy, what to change, how to wire the bootstrap, how to add a HUD,
and how to prove it works.

See `Examples/IntegrationExamples/README.md`.

---

## 5. Adding a new system to the library

1. Copy `Templates/SystemREADME.md` to `Systems/<Name>/README.md`.
2. Copy `Templates/SystemConfigTemplate.lua` to `Systems/<Name>/Config.lua`.
3. Put the source under `Systems/<Name>/Source/<original Roblox path>`.
4. Put the specs under `Systems/<Name>/Tests/`.
5. Add a row to `SYSTEM_INDEX.md`.
6. Add the file to `EXTRACTION_MANIFEST.md` §4.
7. Update `DEPENDENCY_MAP.md` §5 if you use or provide a shared module.
8. Write `Dependencies.md` and `Setup.md`.

---

## 6. Tooling

The source repo pins its tools with `aftman.toml`:

| Tool | Version |
|---|---|
| Rojo | 7.7.0 |
| Wally | 0.3.2 |
| StyLua | 2.5.2 |
| Selene | 0.31.0 |

```bash
aftman install          # once
rojo build default.project.json -o build/game.rbxl
wally install
stylua --check src
selene src
```

**The formatting and lint baselines are not clean in the source game.**
`stylua --check src` fails on 5 config files and `selene src` reports 6
errors and 12 warnings. All are pre-existing and were deliberately **not**
fixed by this extraction — see `MEMORY.md` §7.2 for the list.
