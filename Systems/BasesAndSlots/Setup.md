# BasesAndSlots — Setup

Step-by-step installation into a **new Rojo project**. Follow it in order;
several steps have a hard ordering dependency.

---

## 0. What you are installing

Seven server modules and one config module. They form the base registry, the
slot pool, the runtime stand builder, the base lock, the laser, the stand
display, the egg idle loop and the player board.

**You also need** (not in this library, but required at runtime):

- `ReplicatedStorage.Types.BaseType`, `ReplicatedStorage.Types.SlotType`
- `ReplicatedStorage.Utility.StandResolver`, `.StandLayout`, `.Debug`,
  `.BigNumber`, `.Validation`, `.EggWalkAnimator`
- `ReplicatedStorage.Config.World.Bases` (shipped here)
- `ReplicatedStorage.Config.World.Movement` (SharedUtilities system)
- `ReplicatedStorage.Config.Creatures.Progression` (Animals system)
- `ReplicatedStorage.Config.Economy.Rebirth` (Rebirth system)
- `ServerScriptService.Base.SlotService`, `ServerScriptService.IncomeService`
- `ServerScriptService.Base.NotificationService`,
  `ServerScriptService.Tutorial.TutorialSignals`,
  `ServerScriptService.FunnelService` — **or stubs, see step 6**

---

## 1. Create the Rojo project

```bash
rojo init
```

Give it a `default.project.json` with at least these mappings:

```json
{
  "name": "my-game",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage",
      "Packages": { "$path": "Packages" }
    },
    "ServerScriptService": {
      "$path": "src/ServerScriptService",
      "Packages": { "$path": "ServerPackages" }
    },
    "StarterPlayer": {
      "StarterPlayerScripts": { "$path": "src/StarterPlayer/StarterPlayerScripts" }
    },
    "StarterGui": { "$path": "src/StarterGui", "$ignoreUnknownInstances": true },
    "Workspace": { "$path": "src/Workspace", "$ignoreUnknownInstances": true }
  }
}
```

The `Packages` / `ServerPackages` mappings are the standard Wally layout
and are required if you use any third-party package (see step 3).

---

## 2. Copy the files

Copy from the library to the paths below. **The paths matter** — the
`require` calls are path-relative and absolute, so a file in the wrong place
will not resolve.

| From | To |
|---|---|
| `Systems/BasesAndSlots/Source/ServerScriptService/BaseService.lua` | `src/ServerScriptService/BaseService.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/Base/DynamicSlotService.lua` | `src/ServerScriptService/Base/DynamicSlotService.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/Base/BaseLockService.lua` | `src/ServerScriptService/Base/BaseLockService.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/Base/LaserAnimation.lua` | `src/ServerScriptService/Base/LaserAnimation.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/Base/StandDisplayService.lua` | `src/ServerScriptService/Base/StandDisplayService.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/Base/PlayerBoard.lua` | `src/ServerScriptService/Base/PlayerBoard.lua` |
| `Systems/BasesAndSlots/Source/ServerScriptService/StandPresentation.lua` | `src/ServerScriptService/StandPresentation.lua` |
| `Systems/BasesAndSlots/Source/ReplicatedStorage/Config/World/Bases.lua` | `src/ReplicatedStorage/Config/World/Bases.lua` |

Copy the shared modules this system needs:

| From | To |
|---|---|
| `Shared/Types/BaseType.lua` | `src/ReplicatedStorage/Types/BaseType.lua` |
| `Shared/Types/SlotType.lua` | `src/ReplicatedStorage/Types/SlotType.lua` |
| `Shared/CommonModules/StandResolver.lua` | `src/ReplicatedStorage/Utility/StandResolver.lua` |
| `Shared/CommonModules/StandLayout.lua` | `src/ReplicatedStorage/Utility/StandLayout.lua` |
| `Shared/CommonModules/EggWalkAnimator.lua` | `src/ReplicatedStorage/Utility/EggWalkAnimator.lua` |
| `Shared/Utilities/Debug.lua` | `src/ReplicatedStorage/Utility/Debug.lua` |
| `Shared/Utilities/BigNumber.lua` | `src/ReplicatedStorage/Utility/BigNumber.lua` |
| `Shared/Utilities/Validation.lua` | `src/ReplicatedStorage/Utility/Validation.lua` |

Note the two library folders collapse into one Roblox folder: `Shared/Types/`
→ `ReplicatedStorage.Types`, and both `Shared/Utilities/` and
`Shared/CommonModules/` → `ReplicatedStorage.Utility`.

Config modules from other systems, if you do not already have them:

| From | To |
|---|---|
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/World/Movement.lua` | `src/ReplicatedStorage/Config/World/Movement.lua` |
| `Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Progression.lua` | `src/ReplicatedStorage/Config/Creatures/Progression.lua` |
| `Systems/Rebirth/Source/ReplicatedStorage/Config/Economy/Rebirth.lua` | `src/ReplicatedStorage/Config/Economy/Rebirth.lua` |

**`Config.lua`** in this system folder is the **same module with a
per-field comment for every tunable** — same field paths, same values,
same `Validate*` functions. Use **either** it or the shipped
`Config/World/Bases.lua`, not both. The shipped file is the recommended
one; the annotated one is easier to tune.

---

## 3. Install the third-party packages (Wally)

This system needs exactly **one** third-party package, transitively:

```toml
[dependencies]
t = "osyrisrblx/t@^2.2.1"
```

`t` is required by `ReplicatedStorage.Utility.Validation` (it uses
`Validation.t.instanceOf('Workspace')`). Nothing else in this system
requires a Wally package.

If you are also pulling in the rest of the library, use the source game's
full set:

```toml
[package]
name = "you/my-game"
version = "0.1.0"
registry = "https://github.com/UpliftGames/wally-index"
realm = "shared"

[dependencies]
Promise = "evaera/promise@^4.0.0"
Signal = "sleitnick/signal@^1.0.0"
Fusion = "elttob/fusion@^0.3.0"
t = "osyrisrblx/t@^2.2.1"
TopbarPlus = "1foreverhd/topbarplus@^3.4.0"

[server-dependencies]
Janitor = "kineticwallet/janitor@^1.0.0"
Cmdr = "evaera/cmdr@~1.12.0"

[dev-dependencies]
TestEZ = "roblox/testez@^0.4.0"
```

Then:

```bash
wally install
```

Wally writes `Packages/`, `ServerPackages/` and `DevPackages/`. The Rojo
mappings from step 1 mount them at `ReplicatedStorage.Packages`,
`ServerScriptService.Packages` and the dev equivalents.

**No credentials, API keys, tokens or webhook URLs are involved in this
system.** If you later add a Discord or analytics integration to the lock,
keep the secret out of the repo: use a Studio-only `Secret` module or a
server-side environment mechanism, and document a placeholder in
`Dependencies.md` rather than the real value.

---

## 4. Configure

Open `src/ReplicatedStorage/Config/World/Bases.lua` and set at least:

| Key | Set to | Note |
|---|---|---|
| `Bases.Count` | the number of bases you authored | **Must** match the Workspace. A missing base folder is fatal. |
| `Bases.Slots.Count` | your slot pool size | Also the cap on the dynamic stand count. |
| `Bases.Server.MaxPlayers` | your player cap | Read by the bootstrap, not by this system. |
| `Bases.Lock.LockDurationSeconds` | your lock duration | Seconds. The label and the timer always agree. |
| `Bases.Lock.RefreshOnPress` | `true` if a second press should restart the timer | `false` (the default) makes a second press a **total no-op**. |
| `Bases.Layout.Animal.*` | your ring geometry | Radii, angles, forward offset. |
| `Bases.Layout.Arena.*` | your arena row | `Z` and `Spacing`. |

`Config.lua` in this system folder documents every field — default, meaning,
valid range, and whether it is safe to change. Read it alongside.

**Do not tune** `Lock.LaserExtendSeconds`, `Lock.LaserRetractSeconds` or
`Lock.LaserStaggerSeconds` — **nothing reads them**. The laser is instant.

**Do not tune** `Collector.Height` / `Collector.PartColor` /
`Collector.Transparency` unless you are using the legacy `Slots/Slot<n>`
fallback. The main game's stands never use them.

---

## 5. Author the Studio assets

This is the biggest task, and it is **not** in this repository. The full
hierarchy is in [`Dependencies.md`](Dependencies.md) → *Studio Assets*. The
short version:

### 5.1 The base container

Create `Workspace.Map.Bases` (a `Folder`) and inside it `Base_1` .. `Base_8`
(or however many `Count` you set). **Each base needs:**

- **`Collector`** — a `BasePart`. **Non-negotiable.** The server fatals
  without it, fatals if it is not a `BasePart`, and fatals if it shares the
  XZ position of the `Spawn`. Its position relative to the `Spawn` is what
  determines the base's orientation, so place it deliberately — the
  convention is 10 studs along `-Z` from the spawn, which yields a clean
  180° yaw.
- **`Spawn`** — a `Part`. Auto-created at `CFrame.new(i*40, 0.5, 0)` if
  absent, but author it so the bases are where you want them.
- **`SpawnLocation`** — a `SpawnLocation`. Auto-created at the `Spawn`
  CFrame if absent. The owner's `player.RespawnLocation` points here.
- **`LazerButton/PressPart`** — a `BasePart`. The lock button. Connected
  server-side on `Touched`; there is no remote to fire.
- **`LazerButton/BillboardGui/Timer`** — a `TextLabel`. The countdown.
- **`LazerDoor/Lazers/Part`** — the laser. Parts named **exactly** `Part`
  are the animated ones; every `BasePart` under `Lazers` becomes lock
  geometry.
- **`Build/Hitbox`** — every `BasePart` under it becomes lock geometry.
  Optional, but without it the build lock is degraded.
- **`PlayerBoard/Main/SurfaceGui/Frame/{Name (TextLabel), Avatar (ImageLabel)}`**
  — optional; the board is display-only and degrades to a skipped write.

### 5.2 The stand markers (dynamic mode)

Create `StandPos` inside each base, with children `StandPos1` .. `StandPosN`.
These are **empty markers** — the server reads their positions and clones a
template over them. They are never mutated.

Create `ArenaStandPos` with `ArenaStandPos1` .. `ArenaStandPosM` for the
arena row.

**Indices are holes, never renumbers.** If `StandPos3` is missing, slot 3
does not exist — slot 4 is still slot 4. The server `warn`s about the gap at
boot.

If you prefer the **static** mode, author `AnimalStands/Stand<k>` models
directly instead of `StandPos` markers; do not author both (the dynamic mode
wins and the static stands are ignored).

### 5.3 The ServerStorage templates

```text
ServerStorage/Assets/Map/Bases/Base/StandTemplate
ServerStorage/Assets/Map/Bases/Base/ArenaStandTemplate
ServerStorage/Assets/Map/Bases/Base/Ui/Stand/UpgradeButtonTemplate
```

`StandTemplate` may be a `Model` or a `BasePart`. It must resolve
`Slot/Root` (the displayable part) and `Button/PressPart` (the cash trigger).
A missing template warns at boot and **fails each affected base closed at
assign time**.

`UpgradeButtonTemplate` must be a `TextButton`. The upgrade labels are
looked up under it as `Level` and `UpgradeAmount` (see
`StandResolver.Names.LevelLabel` / `CostLabel`).

---

## 6. Handle the three out-of-library requires

`BaseLockService.lua:59,60,62` requires these at the top level:

```lua
local NotificationService = require(script.Parent.NotificationService)
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals)
local FunnelService = require(script.Parent.Parent.FunnelService)
```

The module **will not load** without them. You have three options:

1. **Copy those three services from their systems** (Notifications, Tutorials,
   Analytics). Recommended — the lock's toast, tutorial progression and
   funnel event are real features.
2. **Stub them.** Create minimal modules with the exact call shapes the lock
   uses:
   - `NotificationService.NotifySuccess(player, text)` — a no-op stub is fine.
   - `TutorialSignals.Fire(name, ...)` — a no-op stub is fine.
   - `FunnelService.<someEvent>(...)` — check which call the lock makes and
     stub that one.
3. **Guard the requires** with `pcall` and make the features optional:

```lua
local okNotif, NotificationService = pcall(require, script.Parent.NotificationService)
if not okNotif then NotificationService = nil end
```

Then guard the call sites. This is the smallest change but it touches three
places in `HandleButtonTouched` and the unlock path.

---

## 7. Wire the bootstrap

Create `src/ServerScriptService/bootstrap.server.lua` (or add to your
existing one). The exact sequence:

```lua
local SSS = game:GetService('ServerScriptService')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

-- --- 1. The services this system talks to ---------------------------
local PlayerService   = require(SSS.PlayerService)
local SlotService     = require(SSS.Base.SlotService)
local EggService      = require(SSS.EggService)
local AnimalService   = require(SSS.AnimalService)
local IncomeService   = require(SSS.IncomeService)
local UpgradeService  = require(SSS.UpgradeService)
local SellService     = require(SSS.SellService)
local RebirthService  = require(SSS.Rebirth.RebirthService)

-- --- 2. This system -------------------------------------------------
local BaseService         = require(SSS.BaseService)
local BaseLockService     = require(SSS.Base.BaseLockService)
local StandDisplayService = require(SSS.Base.StandDisplayService)
local StandPresentation   = require(SSS.StandPresentation)
local DynamicSlotService  = require(SSS.Base.DynamicSlotService)

-- --- 3. Init --------------------------------------------------------
PlayerService.Init()
SlotService.Init()

BaseService.Init()
BaseService.SetPlayerService(PlayerService)
BaseService.SetSlotService(SlotService)
BaseService.SetEggService(EggService)
BaseService.SetAnimalService(AnimalService)

StandPresentation.Init()

StandDisplayService.Init()
StandDisplayService.SetAnimalService(AnimalService)
StandDisplayService.SetUpgradeService(UpgradeService)
-- compat no-ops, kept for parity with the source game:
StandDisplayService.SetSellService(SellService)
StandDisplayService.SetEggService(EggService)
StandDisplayService.SetPlayerService(PlayerService)

BaseService.SetBaseLockService(BaseLockService)

IncomeService.Init()
IncomeService.SetPlayerService(PlayerService)
IncomeService.SetEconomyService(EconomyService)
IncomeService.SetSlotService(SlotService)
IncomeService.SetBaseService(BaseService)
IncomeService.SetAnimalService(AnimalService)

SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
SlotService.SetStandDisplayCallback(StandDisplayService.RefreshSlot)

-- --- 4. The map must be in the Workspace by now ----------------------
BaseService.RegisterBases(workspace)

-- --- 5. The lock, after the bases exist ------------------------------
BaseLockService.Init()

-- --- 6. The stand-unlock resolver, before the first assignment ------
DynamicSlotService.SetUnlockResolver(function(userId)
    return RebirthService.ResolveRebirthForStands(userId)
end)
```

### 7.1 The per-player join handler

```lua
Players.PlayerAdded:Connect(function(player)
    local userId = player.UserId

    if not PlayerService.LoadPlayerData(player) then
        player:Kick('Could not load your data.')
        return
    end

    local base = BaseService.AssignBaseForPlayer(userId)
    if not base then
        player:Kick('No base available.')
        return
    end
    PlayerService.AssignBase(userId, base.id)

    if not BaseService.PointPlayerToBaseSpawn(player, base) then
        BaseService.ReleasePlayerBase(userId)
        PlayerService.CleanupPlayer(userId)
        player:Kick('Could not spawn you at your base.')
        return
    end

    BaseLockService.RefreshCharacter(player)
    BaseService.RestorePlayerBase(userId, PlayerService.GetPlayerData(userId))
    IncomeService.ApplyOfflineEarnings(userId)
end)

Players.PlayerRemoving:Connect(function(player)
    BaseService.CleanupPlayer(player.UserId)
end)
```

**The order is not negotiable.** `RegisterBases` before
`BaseLockService.Init`; `SetUnlockResolver` before the first assignment;
`Set*Service` before the first use.

---

## 8. Change the id prefix (recommended)

`SlotType.BuildId` formats slot ids as `p7:<userId>:slot:<index>`. `p7` is
Brainrot Arena's project prefix. Change it in
`src/ReplicatedStorage/Types/SlotType.lua` and keep it consistent with the
DataStore prefix used by your profile system.

`BaseType.BuildId` formats base ids as `Base_<n>` (1..99). Change it if you
want a different scheme.

---

## 9. Smoke-test

Start the server (`rojo serve` + a Studio client, or `rojo build` +
`rojo run`).

### 9.1 Boot checks

In the **output** window you should see:

```text
BaseService: Base=Base_1 folder=Workspace.Map.Bases.Base_1 class=Folder children={...}
BaseService: Base=Base_1 Collector instance=... class=Part IsABasePart=true
BS  < RegisterBases done
```

`RegisterBases done` is the line to look for. If you get an `error()` about
the Collector, read the message — it names the exact path it looked at.

**Red flags at boot:**

| Symptom | Cause |
|---|---|
| `Workspace.Map.Bases is missing` | Your container is not where the resolver looks. |
| `Collector is missing` / `shares the XZ position` | The base has no Collector, or the Collector is at the Spawn's XZ. |
| `[DynamicSlots] Base Base_1 missing StandPos3` | A hole in the markers. Harmless, but fix it. |
| A `StandTemplate` warning | The template is missing or in the wrong place. |
| `base has no LazerButton.PressPart; locking unavailable` | The lock button is missing. |
| `base has no LazerDoor.Lazers; laser lock degraded` | The laser is missing. |
| `base button has no BillboardGui/Timer TextLabel` | The countdown will not display. |
| `base has no Build.Hitbox; build lock degraded` | The build lock is degraded. |

### 9.2 Join checks

1. Join with one player. You should be teleported to the base's spawn.
2. The `PlayerBoard` should show your display name and (after a moment) your
   avatar.
3. The base should have `Slots.Count` stands — in dynamic mode, `Slot<k>`
   clones appear under `Base_1/AnimalStands` only **after** you are
   assigned.
4. `BaseService.Snapshot(userId)` should return
   `{ slots = {...}, _occupiedCount = 0 }`.

### 9.3 Lock checks

1. Walk into `LazerButton/PressPart`. The laser should snap up **instantly**
   (no animation) and the `Timer` label should count down from 60.
2. Walk into it again. **Nothing should happen** — no toast, no timer reset.
   That is `RefreshOnPress = false` working as designed, not a bug.
3. Try to walk through the laser. You should be blocked.
4. Wait 60 seconds. The laser should snap back down and you should be able
   through.

### 9.4 Multi-player checks

1. Two players, two different bases. Each should be blocked from the
   other's base while it is locked, and each should pass their own.
2. Have player A lock, then player B try to enter A's base. B should be
   blocked.

### 9.5 Reload checks

1. With an animal in a slot, leave and rejoin. The animal should be back in
   its slot (`RestorePlayerBase` re-homes it).
2. With a **rebirth** that unlocks more stands, rejoin. The extra
   `Slot<k>` stands should appear.
3. Reload the server. The base registry is rebuilt from the Workspace;
   only the *assignments* persist, in the profile.

---

## 10. Run the tests

The specs are in `Systems/BasesAndSlots/Tests/`:

```text
BaseLifecycle.spec.lua
BaseLockTimer.spec.lua
BaseService.spec.lua
BaseServiceCollectorFacing.spec.lua
Bases.spec.lua
DynamicSlots.spec.lua
LaserAnimation.spec.lua
```

They need **Roblox Studio** (TestEZ) — there is no headless Luau runner.
Install TestEZ as a dev dependency (step 3) and mount `DevPackages` in a
`test.project.json`.

**Two things to fix before you trust the suite:**

1. **`Tests/BaseLockTimer.spec.lua:99` asserts
   `LockDurationSeconds == 30`, but the shipped config says `60`.** The spec
   is stale. Update it to match your config (or update the config to 30 if
   that is what you want).
2. **The shared `Tests/_Helpers.lua` requires systems this library does not
   contain** — `SSS.Base.SlotService`, `SSS.EggService`, `SSS.AnimalService`,
   `SSS.IncomeService`, `SSS.SellService`, `SSS.UpgradeService`,
   `SSS.ModifierService`. The specs therefore only run in the **full source
   game**, not against this library alone. If you want them to run
   standalone, you must provide those services or rewrite the helper.

`Tests/_Helpers.EnsureCollectors()` is the piece that makes the specs work
on a bare Workspace: it pre-creates `Base_<i>/Collector` for every base
before `RegisterBases` runs. It also needs `Bases.Count` bases.

---

## 11. Final checklist

- [ ] `wally install` succeeded; `t` is present in `Packages/`.
- [ ] All 7 modules are at the documented paths.
- [ ] `ReplicatedStorage.Types.{BaseType,SlotType}` present.
- [ ] `ReplicatedStorage.Utility.{StandResolver,StandLayout,Debug,BigNumber,Validation,EggWalkAnimator}` present.
- [ ] `ReplicatedStorage.Config.World.{Bases,Movement}` present.
- [ ] `ReplicatedStorage.Config.Creatures.Progression` present.
- [ ] `ReplicatedStorage.Config.Economy.Rebirth` present.
- [ ] `ServerStorage.Assets.Map.Bases.Base.StandTemplate` present.
- [ ] `Workspace.Map.Bases.Base_1..Base_N` each have a `Collector`.
- [ ] `Bases.Count` matches the authored base count.
- [ ] The bootstrap order in step 7 is respected.
- [ ] The three out-of-library requires in `BaseLockService` are satisfied or
      stubbed.
- [ ] The slot id prefix has been changed from `p7`.

---

## Related documents

- [`README.md`](README.md)
- [`MEMORY.md`](MEMORY.md)
- [`API.md`](API.md)
- [`Dependencies.md`](Dependencies.md)
- [`Config.lua`](Config.lua)
