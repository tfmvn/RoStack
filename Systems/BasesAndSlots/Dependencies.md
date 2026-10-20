# BasesAndSlots — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

The shared modules live in the library at `ReusableSystems/Shared/`. Their
Roblox destinations are:

| Library path | Roblox destination |
|---|---|
| `Shared/Types/*.lua` | `ReplicatedStorage.Types.*` |
| `Shared/Utilities/*.lua` | `ReplicatedStorage.Utility.*` |
| `Shared/CommonModules/*.lua` | `ReplicatedStorage.Utility.*` |

---

## Module Requires

### `ServerScriptService/BaseService.lua`

```lua
local Bases = require(script.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local BaseConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Bases)
local BaseType = require(script.Parent.Parent.ReplicatedStorage.Types.BaseType)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Validation = require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local StandResolver = require(script.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local PlayerBoard = require(script.Parent.Base.PlayerBoard)
local DynamicSlotService = require(script.Parent.Base.DynamicSlotService)
```

Lazy / `pcall`'d, **not in this library**:

```lua
local CarryPrompts = require(script.Parent.Animal.CarryPrompts)         -- line 899
local RebirthService = require(script.Parent.Rebirth.RebirthService)   -- lines 748, 1175, 1299, 1353, 1841
local IncomeService = require(script.Parent.IncomeService)             -- lines 1134, 1267
```

`BaseConfig` is a second alias of the *same* module as `Bases` — it is
**not** a different config.

### `ServerScriptService/Base/DynamicSlotService.lua`

```lua
local Bases = require(ReplicatedStorage.Config.World.Bases)
local StandConfig = require(ReplicatedStorage.Config.World.Bases).Stands
local StandLayoutConfig = require(ReplicatedStorage.Config.World.Bases).Layout
local RebirthConfig = require(ReplicatedStorage.Config.Economy.Rebirth)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local StandLayout = require(ReplicatedStorage.Utility.StandLayout)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

Lazy, **not in this library**:

```lua
local SlotService = require(script.Parent.SlotService)                 -- lines 564, 571
local IncomeService = require(script.Parent.Parent.IncomeService)      -- lines 816, 1340, 1361
local CarryPrompts = require(script.Parent.Parent.Animal.CarryPrompts) -- line 828
```

### `ServerScriptService/Base/BaseLockService.lua`

```lua
local BaseLockConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.World.Bases).Lock
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BaseService = require(script.Parent.Parent.BaseService)
local NotificationService = require(script.Parent.NotificationService)          -- NOT in this library
local TutorialSignals = require(script.Parent.Parent.Tutorial.TutorialSignals) -- NOT in this library
local FunnelService = require(script.Parent.Parent.FunnelService)              -- NOT in this library
local LaserAnimation = require(script.Parent.LaserAnimation)
```

The three out-of-library requires are **top-level**: the module will not
load without them. See *Other Systems Required*.

### `ServerScriptService/Base/LaserAnimation.lua`

```lua
local BaseLockConfig = require(ReplicatedStorage.Config.World.Bases).Lock
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService/Base/StandDisplayService.lua`

```lua
local LevelConfig = require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
local BigNumber = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
local Debug = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService/Base/PlayerBoard.lua`

```lua
local StandResolver = require(script.Parent.Parent.Parent.ReplicatedStorage.Utility.StandResolver)
```

### `ServerScriptService/StandPresentation.lua`

```lua
local EggWalkAnimator = require(script.Parent.Parent.ReplicatedStorage.Utility.EggWalkAnimator)
local SlotType = require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local MovementConfig = require(script.Parent.Parent.ReplicatedStorage.Config.World.Movement)
```

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **SharedUtilities** (`ReplicatedStorage.Utility.Debug`, `.StandResolver`, `.StandLayout`, `.BigNumber`, `.Validation`, `.EggWalkAnimator`) | `StandResolver` owns every name lookup and stand ordering; `StandLayout` owns the ring geometry; `Debug` is the only logging path. | **Required.** Without them the modules do not load. |
| **PlayerData** (`ReplicatedStorage.Config.Economy.Money`, `PlayerService`) | `BaseService` reads/writes the `BaseId` profile field via `PlayerService.AssignBase`. | Required for persistence. |
| **Rebirth** (`ReplicatedStorage.Config.Economy.Rebirth`, `RebirthService`) | `DynamicSlotService` reads `RebirthConfig.InitialStands` and `StandsFor(rebirth)` to size the stands. `RebirthService.ResolveRebirthForStands` is the injected unlock resolver. | Required for dynamic stands. |
| **Animals** (`ReplicatedStorage.Config.Creatures.Progression`) | `StandDisplayService` needs the max level to decide between `'MAX'` and a cost. | Required for correct labels. |
| **Inventory / SlotService** (`ServerScriptService.Base.SlotService`) | The persisted-slot authority. `BaseService` calls `RegisterBase`; `DynamicSlotService` calls into it. | Required for slot persistence. |
| **Economy** (`ServerScriptService.IncomeService`) | Cash-pool settlement, called by `BaseService` and `DynamicSlotService`. | Required. |
| **Carry** (`ServerScriptService.Animal.CarryPrompts`) | Carry-prompt cleanup when a base is released. | Required if you have carrying. |
| **Notifications** (`ServerScriptService.Base.NotificationService`) | The toast on a successful lock. | **Required at load time** — the `require` is top-level. Guard it with `pcall` to make it optional. |
| **Tutorials** (`ServerScriptService.Tutorial.TutorialSignals`) | Tutorial progression fired on a successful lock. | **Required at load time** — same. |
| **Analytics** (`ServerScriptService.FunnelService`) | The funnel event on a lock transition. | **Required at load time** — same. |
| **Upgrades** (`ServerScriptService.UpgradeService`) | The upgrade prices `StandDisplayService` paints. | Required for correct labels. |
| **SlotMenus** (`ServerScriptService.Base.SlotMenuService`) | Owns the stand menu and the sell button. `StandDisplayService` deliberately does **not** own it. | Optional, but the two fight over the same buttons if both are present. |

---

## Remotes

**None.** No module in this system fires a remote, and no module listens to
one.

`BaseLockService` is activated by a **server-side `Touched`** connection on
`LazerButton.PressPart` (`BaseLockService.lua:756-759`), not by a remote
event. Its only event surface is `SubscribeLockChanged(fn)`, a plain
callback that receives `{ baseId: string, locked: boolean }`.

`ReplicatedStorage.Utility.Remotes` exists in the shared tree, but nothing
in `BaseService`, `DynamicSlotService`, `BaseLockService`,
`StandDisplayService`, `LaserAnimation`, `PlayerBoard` or
`StandPresentation` touches it. If you are porting this system into a game
that uses remotes, you do **not** need to create any for it.

The remotes other systems use are listed in `ReusableSystems/Shared/CommonModules/Remotes.lua`.

---

## Profile Fields

| Field | Type | Owner | Read/Written | Notes |
|---|---|---|---|---|
| `BaseId` | string | `PlayerData` | **This system writes it** (via `PlayerService.AssignBase`) and **reads it back** in `RestorePlayerBase`. | The assigned base, `Base_<n>`. `nil` until assigned. |
| `Brainrots[].SlotId` | string | **Animals** | This system **mutates it in place** during `RestorePlayerBase` (line 1628) when a record's slot no longer resolves. | Format `p7:<userId>:slot:<index>`. |
| `LuckyBlocks[].SlotId` | string | **Eggs** | Same — re-homed in `RestorePlayerBase`. | An egg pointing at an **arena** slot is rejected and re-homed to a normal slot (lines 1583-1592). |

The base registry and the runtime stands are **not persisted**. They are
rebuilt from the Workspace on every server start. Only the assignments
survive.

---

## Studio Assets

### Workspace — the base container

```text
Workspace
└── Map                              -- optional; a top-level `Bases` is
    └── Bases                        --   also accepted on bare test maps
        ├── Base_1                   -- .. Base_8   (Bases.Count = 8)
        │   ├── Collector            -- BasePart. REQUIRED. Fatal if missing,
        │   │                        --   wrong class, or sharing the Spawn's XZ.
        │   ├── Spawn                -- Part. Auto-created at CFrame.new(i*40, 0.5, 0) if absent.
        │   ├── SpawnLocation        -- SpawnLocation. Auto-created at the Spawn
        │   │                        --   CFrame if absent. The owner's
        │   │                        --   player.RespawnLocation points here.
        │   ├── PlayerBoard          -- display-only
        │   │   └── Main
        │   │       └── SurfaceGui
        │   │           └── Frame
        │   │               ├── Name     -- TextLabel
        │   │               └── Avatar   -- ImageLabel
        │   ├── StandPos             -- DYNAMIC mode: markers only
        │   │   └── StandPos1 .. StandPosN
        │   ├── AnimalStands         -- STATIC mode (alternative to StandPos)
        │   │   └── Stand1 .. StandN
        │   │       ├── Slot         -- or `Root`
        │   │       │   └── Root     -- the displayable part
        │   │       └── Button
        │   │           ├── Base     -- the facing target
        │   │           └── PressPart
        │   ├── ArenaStandPos        -- arena markers
        │   │   └── ArenaStandPos1 .. ArenaStandPosN
        │   ├── LazerButton
        │   │   ├── PressPart        -- BasePart. The lock button. Connected
        │   │   │                    --   server-side on `Touched`.
        │   │   └── BillboardGui
        │   │       └── Timer        -- TextLabel. The countdown.
        │   ├── LazerDoor
        │   │   └── Lazers
        │   │       └── Part         -- the laser. Parts named EXACTLY "Part"
        │   │                        --   are the animated ones; every BasePart
        │   │                        --   under Lazers is lock geometry.
        │   └── Build
        │       └── Hitbox           -- every BasePart under it is lock geometry.
        ├── Base_2
        └── ...                      -- up to Base_8
```

**Timer-label fallbacks** (`BaseLockService._resolveLabel`, line 596), in
order: `LazerButton/BillboardGui/Timer` (canonical) →
`LazerButton/PressPart/BillboardGui/Timer` →
`LazerButton/PressPart/Timer` →
`LazerButton/TestLabel` (legacy) →
`LazerButton/PressPart/TestLabel` (legacy).

**Mode selection** is automatic and mutually exclusive:

| The base contains | Mode | Result |
|---|---|---|
| `StandPos/StandPos<k>` | **Dynamic** | Zero runtime slots until assigned. Clones built from `StandTemplate` on assign. |
| `AnimalStands/Stand<k>` (and no markers) | **Static** | One record per stand, plus part-less records for missing indices. |
| Neither | **Legacy fallback** | `Slots/Slot<n>` parts auto-created, plus a `CashCollector` trigger. |

### ServerStorage — the templates

```text
ServerStorage
└── Assets
    └── Map
        └── Bases
            └── Base
                ├── StandTemplate        -- Model or BasePart. Must resolve
                │                       --   `Slot/Root` and `Button/PressPart`.
                ├── ArenaStandTemplate   -- Model or BasePart.
                └── Ui
                    └── Stand
                        └── UpgradeButtonTemplate   -- TextButton.
```

`DynamicSlotService.GetTemplate()` resolves
`ServerStorage.Assets.Map.Bases.Base.StandTemplate`; the arena variant
resolves `...Base.ArenaStandTemplate`. A missing template **warns at boot**
and **fails each affected base closed at assign time**.

`StandDisplayService` resolves `UpgradeButtonTemplate` under
`...Base.Ui.Stand.`.

### Not in this repository

The Workspace and ServerStorage content above is **Studio-authored**. The
source repo's `src/Workspace/` and `src/StarterGui/` contain only
`.gitkeep`, so the models, GUIs and sounds are not version-controlled and
cannot be extracted from this repository. You must author them.

---

## External APIs

**None.** No HTTP, no DataStore, no Marketplace, no webhooks, no third-party
API keys.

The only Roblox services used are `Workspace`, `ServerStorage`,
`PhysicsService` (collision groups), `Players`, `RunService`
(`os.clock`, `Heartbeat`), and `Players:GetUserThumbnailAsync` (the
PlayerBoard avatar, called on a `task.spawn` thread at
`PlayerBoard.lua:84`).

**`TweenService` is deliberately not used.** The laser transitions are
instant — there is no `TweenService`, no `task.wait` and no `task.delay`
anywhere in this system.

**No credentials of any kind are involved in this system.** There is no API
key, token, or webhook URL to configure. If you later add an analytics or
Discord integration to the lock, keep the secret **out of the repo** — use a
Studio secret or a server-side environment mechanism and document a
placeholder here.

---

## Initialization Order

The exact order the source game's `bootstrap.server.lua` uses:

```text
1.  createRemotes()                                   -- other systems need it
2.  PlayerService.Init()
3.  SlotService.Init()
4.  BaseService.Init()
5.  BaseService.SetPlayerService(PlayerService)
6.  BaseService.SetSlotService(SlotService)
7.  BaseService.SetEggService(EggService)
8.  BaseService.SetAnimalService(AnimalService)
9.  StandPresentation.Init()
10. StandDisplayService.Init()
11. StandDisplayService.SetAnimalService(AnimalService)
12. StandDisplayService.SetUpgradeService(UpgradeService)
13. StandDisplayService.SetSellService(SellService)       -- compat no-op
14. StandDisplayService.SetEggService(EggService)         -- compat no-op
15. StandDisplayService.SetPlayerService(PlayerService)   -- compat no-op
16. SlotMenuService.SetStandDisplayService(StandDisplayService)
17. BaseLockService = require(ServerScriptService.Base.BaseLockService)
18. BaseService.SetBaseLockService(BaseLockService)
19. IncomeService.Init()   + SetPlayerService / SetEconomyService /
                            SetSlotService / SetBaseService / SetAnimalService
20. SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
21. SlotService.SetStandDisplayCallback(StandDisplayService.RefreshSlot)
22. BaseService.RegisterBases(Workspace)
23. BaseLockService.Init()
24. DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
25. DynamicSlotService.SetUnlockResolver(function(userId)
        return RebirthService.ResolveRebirthForStands(userId)
    end)
```

**Why the order matters:**

- `BaseService.Init()` (4) must precede `RegisterBases` (22).
- `RegisterBases` (22) must precede `BaseLockService.Init()` (23) — the lock
  service registers a lock record per base, and creates the collision groups
  from the base count.
- `RegisterBases` (22) must precede `SetUnlockResolver` (25) in practice:
  `RegisterBases` calls `DynamicSlotService.GetTemplate()` in a `pcall` to
  warn early about a missing template.
- `SetUnlockResolver` (25) must precede the first player assignment,
  otherwise the dynamic stand count resolves to nothing.
- `RegisterBases` (22) requires the map to already be in the Workspace.
- The `Set*Service` calls (5-8) must precede the first assignment.
- `StandDisplayService.SetUpgradeService` (12) must precede the first
  `RefreshSlot`, or the cost label is wrong.

### Per player, on join

```text
1.  PlayerService.LoadPlayerData(player)
2.  BaseService.AssignBaseForPlayer(userId)
3.  PlayerService.AssignBase(userId, baseId)
4.  BaseService.PointPlayerToBaseSpawn(player, base)
        on failure:
          BaseService.ReleasePlayerBase(userId)
          PlayerService.CleanupPlayer(userId)
          player:Kick(reason)
5.  ArenaService.EnsureAdventurer
6.  BaseLockService.RefreshCharacter(player)
7.  BaseService.RestorePlayerBase(userId, profileData)
8.  IncomeService.ApplyOfflineEarnings
9.  CodesService.OnPlayerReady
10. PlaytimeRewardsService.OnPlayerReady
11. PlayerService.GetLoadedSignal(userId):Fire()
12. PlayerService.MarkLoaded(userId)
13. BaseService.Snapshot(userId)
14. PlayerService.PushState(player, snapshot)
```

On leave: `BaseService.CleanupPlayer(userId)` (bootstrap line 1204).

On an admin wipe: `BaseService.WipePlayerData(userId)` (bootstrap line 1350),
then re-`AssignBaseForPlayer` + `PointPlayerToBaseSpawn`.

---

## Related documents

- [`README.md`](README.md)
- [`MEMORY.md`](MEMORY.md)
- [`API.md`](API.md)
- [`Setup.md`](Setup.md)
- [`Config.lua`](Config.lua)
