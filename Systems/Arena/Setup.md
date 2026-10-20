# Arena — Setup

Installing the Arena system into a **new** Rojo project.

Read this alongside [README.md](README.md) (what it does),
[Dependencies.md](Dependencies.md) (exact paths), and
[MEMORY.md](MEMORY.md) (why it works the way it does).

> **Before you start:** the Arena system is **server + config only**. It has
> no client code. If you copy only `Systems/Arena/`, you get a server that
> fights correctly and **renders nothing**. See step 8.

---

## 1. Create the project

```bash
mkdir my-arena-game && cd my-arena-game
aftman install                 # rojo 7.7.0, wally 0.3.2 (see the repo's aftman.toml)
rojo init my-arena-game        # writes default.project.json + src/
```

You will need these folders in `src/`:

```text
src/
  ReplicatedStorage/
    Config/
      Creatures/     <- Animals.lua
      Systems/       <- Debug.lua
      World/         <- Arena.lua, ArenaFeel.lua, Prompts.lua
    Types/           <- SlotType.lua, TransactionReason.lua
    Utility/         <- Remotes.lua, Validation.lua, BigNumber.lua, Debug.lua,
                        AnimalStats.lua
  ServerScriptService/
    Arena/           <- ArenaService.lua, ArenaBattleService.lua,
                        ArenaProgressionService.lua
    Animal/          <- AnimalOverhead.lua, SlotMath.lua
    Tutorial/        <- TutorialSignals.lua
    PlayerLogger/    <- PlayerLogger.lua
    Utility/         <- (your existing utility folder)
    bootstrap.server.lua
  StarterPlayer/
    StarterPlayerScripts/   <- ArenaController.lua, ArenaHitPresentation.lua,
                               ArenaCameraImpacts.lua, ArenaResultController.lua
```

---

## 2. Copy the Arena files

From the library root (`ReusableSystems/`), into your `src/`:

```bash
LIB=/c/Users/tfmvn/AnimalArena/ReusableSystems
SRC=./src

mkdir -p $SRC/ServerScriptService/Arena \
         $SRC/ReplicatedStorage/Config/World \
         $SRC/ReplicatedStorage/Config/Creatures \
         $SRC/ReplicatedStorage/Config/Systems \
         $SRC/ReplicatedStorage/Types \
         $SRC/ReplicatedStorage/Utility \
         $SRC/ServerScriptService/Animal \
         $SRC/ServerScriptService/Tutorial \
         $SRC/ServerScriptService/PlayerLogger

# --- the Arena system itself -----------------------------------------
cp $LIB/Systems/Arena/Source/ServerScriptService/Arena/ArenaService.lua \
   $SRC/ServerScriptService/Arena/
cp $LIB/Systems/Arena/Source/ServerScriptService/Arena/ArenaBattleService.lua \
   $SRC/ServerScriptService/Arena/
cp $LIB/Systems/Arena/Source/ServerScriptService/Arena/ArenaProgressionService.lua \
   $SRC/ServerScriptService/Arena/
cp $LIB/Systems/Arena/Source/ReplicatedStorage/Config/World/Arena.lua \
   $SRC/ReplicatedStorage/Config/World/
cp $LIB/Systems/Arena/Source/ReplicatedStorage/Config/World/ArenaFeel.lua \
   $SRC/ReplicatedStorage/Config/World/

# --- shared modules the Arena requires --------------------------------
cp $LIB/Shared/Types/SlotType.lua \
   $LIB/Shared/Types/TransactionReason.lua \
   $SRC/ReplicatedStorage/Types/

cp $LIB/Shared/Utilities/Validation.lua \
   $LIB/Shared/Utilities/BigNumber.lua \
   $LIB/Shared/Utilities/Debug.lua \
   $SRC/ReplicatedStorage/Utility/

cp $LIB/Shared/CommonModules/Remotes.lua \
   $LIB/Shared/CommonModules/AnimalStats.lua \
   $SRC/ReplicatedStorage/Utility/
```

> `Shared/Utilities/` and `Shared/CommonModules/` are split in the library
> only to keep the folders a sane size. **Both** land in
> `ReplicatedStorage/Utility/` in the real game.

### The Arena also needs these from other systems

| Library path | Roblox destination | Why |
|---|---|---|
| `Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Animals.lua` | `ReplicatedStorage/Config/Creatures/Animals.lua` | The enemy + player definition catalog. `ValidateLive()` probes it. |
| `Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` | `Prompts.Arena` — the Adventurer prompt. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage/Config/Systems/Debug.lua` | Gates the Arena telemetry. |
| `Systems/Inventory/Source/ServerScriptService/Animal/SlotMath.lua` | `ServerScriptService/Animal/SlotMath.lua` | Combat-model placement on the arena floor. |
| `Systems/Animals/Source/ServerScriptService/Animal/AnimalOverhead.lua` | `ServerScriptService/Animal/AnimalOverhead.lua` | The floating HP overhead on combat models. |
| `Systems/Tutorials/Source/ServerScriptService/Tutorial/TutorialSignals.lua` | `ServerScriptService/Tutorial/TutorialSignals.lua` | `ArenaStarted` / `ArenaCancelled` / `ArenaEnded` milestones. |
| `Systems/Analytics/Source/ServerScriptService/FunnelService.lua` | `ServerScriptService/FunnelService.lua` | Funnel analytics. |
| `Systems/PlayerLogging/Source/ServerScriptService/PlayerLogger/PlayerLogger.lua` | `ServerScriptService/PlayerLogger/PlayerLogger.lua` | Completion monitoring. |

The last four are **optional** — they are leaf modules and the Arena
degrades gracefully without them. The first three are **required**.

> `FunnelService` and `PlayerLogger` are `require`d by `ArenaService`
> **directly** (not injected). If you skip them, you must either copy them
> or edit the two `require` lines in `ArenaService.lua:96` and `:99`.

---

## 3. Install the third-party packages

The Arena system itself requires **no** Wally packages. The surrounding
game does.

```bash
wally install
```

From the source game's `wally.toml`:

```toml
[dependencies]
Signal = "sleitnick/signal@^1.0.0"
t = "osyrisrblx/t@^2.2.1"
TopbarPlus = "1foreverhd/topbarplus@^3.4.0"

[server-dependencies]
Janitor = "kineticwallet/janitor@^1.0.0"
Cmdr = "evaera/cmdr@~1.12.0"

[dev-dependencies]
TestEZ = "roblox/testez@^0.4.0"
```

**Do not copy `Fusion` or `Promise`** — they are declared in the source
game's `wally.toml` but nothing requires them.

If you are also taking the **PlayerData** system, add `ProfileService`
(via Wally or vendored at `src/Vendored/ProfileService.lua`).

---

## 4. Write `default.project.json`

```json
{
  "name": "my-arena-game",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "$path": "src/ReplicatedStorage",
      "Packages": {
        "$path": "Packages"
      }
    },
    "ServerScriptService": {
      "$className": "ServerScriptService",
      "$path": "src/ServerScriptService",
      "Packages": {
        "$className": "Folder",
        "ProfileService": {
          "$path": "src/Vendored/ProfileService.lua"
        }
      }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "$path": "src/StarterPlayer/StarterPlayerScripts"
      }
    },
    "StarterGui": {
      "$path": "src/StarterGui",
      "$ignoreUnknownInstances": true
    },
    "Workspace": {
      "$path": "src/Workspace",
      "$ignoreUnknownInstances": true
    }
  }
}
```

---

## 5. Install the remote registry

`ReplicatedStorage/Utility/Remotes.lua` is the registry of remote names.
**The server creates the `RemoteEvent`s at boot** — do not hand-author them.

Copy this 18-line function from the source game's
`bootstrap.server.lua:203-222` into your bootstrap:

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local function createRemotes()
    local folder = ReplicatedStorage:FindFirstChild('Remotes')
    if not folder then
        folder = Instance.new('Folder')
        folder.Name = 'Remotes'
        folder.Parent = ReplicatedStorage
    end
    for _, n in pairs(Remotes.Names) do
        if not folder:FindFirstChild(n) then
            local remote = Instance.new('RemoteEvent')
            remote.Name = n
            remote.Parent = folder
        end
    end
    Remotes.SetRemotes(folder)
    return folder
end

createRemotes()
```

The Arena uses four of them: `ArenaAction` (C→S), `ArenaState`,
`ArenaResult`, and `ArenaCombatEvent` (all S→C).

---

## 6. Wire the bootstrap

The Arena services are wired with **setter injection**, not `require`. That
is what keeps the dependency graph acyclic — no service ever requires the
Arena back.

```lua
-- ServerScriptService/bootstrap.server.lua
local ArenaProgressionService = require(script.Parent.Arena.ArenaProgressionService)
local ArenaService            = require(script.Parent.Arena.ArenaService)
local ArenaBattleService      = require(script.Parent.Arena.ArenaBattleService)

-- ... your other services are wired first ...

-- --- Arena ------------------------------------------------------------
-- Order matters: every setter must run BEFORE ArenaService.Init(),
-- because Init() reads battleServiceRef to install the battle
-- callbacks and asserts on the ArenaAction remote.
ArenaProgressionService.SetPlayerService(PlayerService)
ArenaService.SetPlayerService(PlayerService)
ArenaService.SetBaseService(BaseService)
ArenaService.SetAnimalService(AnimalService)
ArenaService.SetSlotService(SlotService)
ArenaService.SetCarryRegistry(CarryRegistry)
ArenaService.SetStealService(StealService)
ArenaService.SetNotificationService(NotificationService)
ArenaService.SetProgressionService(ArenaProgressionService)
ArenaService.SetEconomyService(EconomyService)
ArenaService.SetBattleService(ArenaBattleService)
ArenaBattleService.SetAnimalService(AnimalService)
ArenaService.Init()
```

### Per-player hooks

Three hooks in the source game's bootstrap:

```lua
-- On base assignment (inside your base-assignment path):
pcall(ArenaService.EnsureAdventurer, base)

-- On player ready (after the profile loads):
pcall(function()
    ArenaProgressionService.NormalizeArena(PlayerService.GetPlayerData(player.UserId))
end)

-- On player leave:
pcall(ArenaService.ForgetPlayer, player.UserId)
```

`NormalizeArena` on load lets older saves gain
`{ Level = 1, XP = 0, Wins = 0 }` without touching any other field.

### The services you must have

`ArenaService` requires **ten** injected services to exist before `Init()`.
If any of them is missing, the corresponding feature silently degrades:

| Service | If missing |
|---|---|
| `PlayerService` | Progression reads/writes fail. |
| `BaseService` | The raid cannot find the base → `ResolveArenaTeam` returns empty → `'no-team'`. |
| `SlotService` | Same as above. |
| `AnimalService` | No combat models; no animal XP award. |
| `EconomyService` | **Paid restarts cannot be charged** and the raid payout never lands. |
| `ProgressionService` | The state snapshot falls back to `{ Level = 1, XP = 0, XPRequired = 100, Wins = 0 }`. |
| `BattleService` | `StartArena` returns `'service-not-ready'`. No raids at all. |
| `CarryRegistry` / `StealService` | The start validation loses its carry/steal gate. |
| `NotificationService` | No toasts. |

---

## 7. Configure

Two config modules ship with the system. Tune them in place.

### `ReplicatedStorage/Config/World/Arena.lua`

| Field | Default | Change it when |
|---|---|---|
| `LEVELS` (the catalog) | 50 stages | You want different stages. **Replace the whole array** — keep `Level` contiguous from 1 and keep the `ArenaLevelDef` shape. |
| `MAX_LEVEL` | re-derived as `#LEVELS` | **Never hardcode it.** The literal `10` at line 72 is dead — it is reassigned at line 1057. |
| `MIN_TEAM_SIZE` | `1` | You want to require more than one animal. |
| `MAX_TEAM_SIZE` | `3` | **Only** if you also re-author the `PlayerSpawns` markers. |
| `ANIMAL_XP_MULTIPLIER` | `100` | You want to change the per-animal XP scale. |
| `ATTACK_COOLDOWN` | `1.5` | Rarely — see the note below. |
| `RESTART_WARMUP_PRICE` | `'25000'` | You want to rebalance restart pricing. |
| `RESTART_DIRECT_PRICE` | `'150000'` | Same. |
| `ResultCardCap` | `6` | The result card cannot lay out that many cards. |

> **`ATTACK_COOLDOWN` does not control the attack cadence.** The real pacing
> is `ArenaFeel.Combat.TurnInterval` (1.1s). `ATTACK_COOLDOWN` only stamps
> the diagnostic `NextAttackAt`. Change `TurnInterval` to change how fast
> fights feel.

> **Do not linearize `XPRequired`.** It is
> `floor(5 * 1.25^(L-1) + 0.5)`, and the settle ratios were calibrated
> against it. The source warns that flat 100-per-level "collapsed against
> exponential settles (one full clear capped the whole track)".

### `ReplicatedStorage/Config/World/ArenaFeel.lua`

Pure presentation. Safe to retune freely — with two exceptions:

- **`Combat.EasingStyle` is never read.** `tweenModelTo` hardcodes
  `Enum.EasingStyle.Quad`. Setting it to `'Sine'` changes nothing.
- **The ORDER of `AttackAnims` is a client contract.** The index is
  broadcast to clients as `AttackIndex`. The durations and impact offsets
  are safe to change; reordering the array is not.

### `ReplicatedStorage/Config/World/Prompts.lua`

```lua
Prompts.Arena = {
    ActionText = 'Open Arena',
    ObjectText = 'Adventurer',
    HoldDuration = 0,
    MaxActivationDistance = 12,
    RequiresLineOfSight = false,
    UIOffsetY = 0,
    Keybind = 'E',
}
```

This file lives in the **Carry** system's folder in the library. Copy it to
`ReplicatedStorage/Config/World/Prompts.lua` and keep the `Prompts.Arena`
block (plus whatever else your game needs from it).

### `ReplicatedStorage/Config/Systems/Debug.lua`

```lua
Debug.ServerDebug = true   -- turn this ON while developing
```

Every `Debug.Log` / `Debug.Warn` in the Arena is gated on
`ServerDebug`. **With it off (the default), all Arena telemetry is
invisible** — including genuine config errors. Turn it on while you are
integrating.

---

## 8. Copy the client modules

**This is the step people forget.** The Arena server pushes `ArenaState`,
`ArenaResult`, and `ArenaCombatEvent`, but the UI that renders them lives
in the **ClientPresentation** system:

| Library path | Roblox destination |
|---|---|
| `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaController.lua` | `StarterPlayer.StarterPlayerScripts.ArenaController` |
| `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaHitPresentation.lua` | `StarterPlayer.StarterPlayerScripts.ArenaHitPresentation` |
| `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaCameraImpacts.lua` | `StarterPlayer.StarterPlayerScripts.ArenaCameraImpacts` |
| `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaResultController.lua` | `StarterPlayer.StarterPlayerScripts.ArenaResultController` |
| `Shared/CommonModules/ArenaUIState.lua` | `ReplicatedStorage/Utility/ArenaUIState` |

`ArenaUIState` is the screen-lifecycle coordinator both the controller and
the result controller share. It goes in `ReplicatedStorage/Utility/` (with
the other shared common modules), **not** in `Shared/`.

Alternatively, write your own client modules against the same three
remotes — the payload shapes are documented in
[Dependencies.md](Dependencies.md) → *Remotes*.

---

## 9. Author the Studio assets

### Per base — required

```text
<YourBaseFolder>/
  Adventurer              -- Model or BasePart. The prompt host. Alias: Adv.
  Arena/                  -- Folder. The battle area.
    Center                -- BasePart | Attachment | Model. The area marker.
    PlayerSpawns/
      Position1           -- BasePart | Attachment | Model
      Position2
      Position3
    EnemySpawns/
      Position1           -- BasePart | Attachment | Model
      Position2
      Position3
```

- The spawn markers define where the combat models stand. A `BasePart`
  uses its `CFrame`; an `Attachment` uses its `WorldCFrame`; a `Model` uses
  its `GetPivot()`.
- You need **at least three** `PlayerSpawns` (matching `MaxTeamSize`) and
  as many `EnemySpawns` as the biggest enemy team in your catalog.
- Missing markers fail the battle start **loudly** —
  `ResolveArenaArea` returns `missing = { 'Arena/PlayerSpawns/Position3' }`
  and the start is rejected with `'battle-failed'`.

### Per base — optional

If neither `Adventurer` nor `Adv` exists, the server builds a temporary
code-made brick NPC (a 2×5×2 "Bright blue" part with a billboard and a 5s
START-button self-heal backstop). Author the real NPC for a shipped game.

### Global — hit assets (client presentation)

| Server-side (authoritative) | Client-side (mirrored at boot) |
|---|---|
| `ServerStorage.Assets.Vfx.HitVfx.Attack1` | `ReplicatedStorage.Assets.Vfx.HitVfx.Attack1` |
| `ServerStorage.Assets.Arena.Sfx.Attack1` | `ReplicatedStorage.Assets.Arena.Sfx.Attack1` |
| `ServerStorage.Assets.Arena.Sfx.Attack2` | `ReplicatedStorage.Assets.Arena.Sfx.Attack2` |
| `ServerStorage.Assets.Arena.Sfx.Attack3` | `ReplicatedStorage.Assets.Arena.Sfx.Attack3` |

LocalScripts cannot read `ServerStorage`, so the server mirrors these into
`ReplicatedStorage` once at boot. Copy `mirrorArenaHitAssets()` from the
source game's `bootstrap.server.lua:577-690` — it is a check-then-create
move-a-copy, and a Studio-authored mirror is **never** overwritten.

**Missing sources degrade gracefully**: the client still shows the damage
number and the camera shake, just without the VFX/sound.

### Created by code — you do not author these

| Path | Created by |
|---|---|
| `Workspace.ArenaBattles` | `battleRootFolder()` (`ArenaBattleService.lua:1184`) |
| `ReplicatedStorage.ArenaResultModels` | `keepsakeRoot()` (`ArenaBattleService.lua:2044`) |

### Animal models

Combat models come from the **Animals** system (`AnimalService.Get` for the
live model, `AnimalService.GetTemplate` as the fallback). You do not
author arena-specific models.

---

## 10. Smoke-test it

Build and play:

```bash
rojo build default.project.json -o build/my-arena-game.rbxl
```

Then, in order:

1. **Boot clean.** The Output window should show **no** `[Arena] Config
   issue:` lines. Any line there means your catalog has a problem — most
   likely an `EnemyTeam` `DefinitionId` that does not resolve through
   `ReplicatedStorage.Config.Creatures.Animals`.
2. **The prompt appears.** Walk to your base's Adventurer and confirm the
   `Open Arena` prompt shows. No prompt → the base folder has no
   `Adventurer`/`Adv` and the temporary NPC failed to build.
3. **The menu opens.** Press the prompt. The menu should render with the
   stage list and a START button. **Nothing renders** → you skipped step 8
   (the client modules) or the `ArenaState` remote is not wired.
4. **A raid starts.** Click START. You should see the combat models spawn
   into `Workspace.ArenaBattles/Battle_1/`, the two sides alternate
   attacks, damage numbers appear, and the HP overheads tick down.
   - Models do not spawn → check the `Arena/PlayerSpawns` markers.
   - The battle starts but nothing attacks → `ArenaFeel.Combat.TurnInterval`
     is not being read, or the scheduler is not running.
5. **The raid advances.** Clear stage 1 and confirm stage 2 begins in the
   same session, **with the survivors' HP carried over** and the dead
   ones still dead. This is the single most important behaviour to verify.
6. **Rewards land.** Let the raid end. Check that:
   - The player's money increased by the settled cash.
   - The player's arena XP increased.
   - Each participating animal's XP increased, split proportionally to the
     damage it actually dealt.
7. **The result card shows the real models.** The result panel should show
   the actual combat models — not grey boxes. If they are missing, the
   keepsakes were destroyed before the client cloned them; check the
   `CombatModel` field on the `ArenaResult` payload.
8. **A restart works.** With `LastReached >= 4`, the menu should offer
   `Buy1` (warmup, `$25.0K`) and `Buy2` (direct, `$150.0K`). Buying one
   should start the raid at the resolved stage and deduct the price.
9. **Retreat works.** Press retreat mid-raid. The cleared stages should
   pay, the team should return to their stands, and the Adventurer should
   reappear.
10. **Leaving works.** Leave the server mid-raid. The session should be
    dropped with no further rewards, and no errors in the Output window.

### Turning on the diagnostics

If any step misbehaves, set `Config/Systems/Debug.lua`:

```lua
Debug.ServerDebug = true
```

The Arena emits tagged lines: `Arena`, `ArenaRaid`, `ArenaReward`,
`ArenaXP`, `ArenaDamage`, `ArenaDeath`, `ArenaStart`, `ArenaResult`,
`ArenaResultModel`, `ArenaResultPayload`, `ArenaSlots`, `ArenaCombat`,
`ArenaSlots`.

---

## 11. Run the tests

The system ships seven specs. They need **Roblox Studio** (they stub the
profile and the remotes via `_Helpers`; no DataStore is touched).

```bash
# TestEZ
rojo build test.project.json -o build/my-arena-game-tests.rbxl
```

Or, from the library:

```text
ReusableSystems/Tests/TestRunner.server.lua
```

The runner is:

```lua
local TestEZ = require(script.Parent.Parent.Packages.TestEZ)
TestEZ.RunBootstrap()
```

Copy the Arena specs into your test tree:

```bash
cp $LIB/Systems/Arena/Tests/*.spec.lua \
   $SRC/Tests/ServerScriptService/TestEZTests/Arena/
```

> **`ArenaUIState.spec.lua` will fail** unless you also copy the client
> modules from step 8 (`ArenaController` and `ReplicatedStorage.Utility.ArenaUIState`).
> It is the only Arena spec that reaches into the client.

---

## 12. Environment-specific values

The Arena system needs **no credentials, no webhook URLs, and no API
keys**. Everything external is optional and lives in other systems:

| Value | Where | Notes |
|---|---|---|
| Profile DataStore name | `PlayerService` (PlayerData system) | Hardcoded literal. **Change it** — it carries the schema version and an environment suffix. |
| Discord webhook | `PlayerLogger` (PlayerLogging system) | Keep it as a **Studio attribute**, never in source. See the library's `SECURITY_NOTES.md`. |
| Analytics endpoint | `FunnelService` (Analytics system) | Optional. If you add one, read the key from an environment variable or a Roblox secret — never commit it. |

---

## Related

- [README.md](README.md) — what it does, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics, invariants, gotchas.
- [API.md](API.md) — every public function.
- [Dependencies.md](Dependencies.md) — exact require paths, remotes, profile fields, assets.
- [Config.lua](Config.lua) — the consolidated tunable mirror.
