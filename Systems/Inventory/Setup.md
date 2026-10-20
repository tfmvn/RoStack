# Inventory — Setup

Installing the Inventory system into a new Rojo project.

---

## 1. Copy the files

Copy the four source files to their **original Roblox paths** — the
`require` paths inside them are written against those locations.

| From | To |
|---|---|
| `Source/ServerScriptService/Base/SlotService.lua` | `ServerScriptService/Base/SlotService.lua` |
| `Source/ServerScriptService/Action/SlotActionHandler.lua` | `ServerScriptService/Action/SlotActionHandler.lua` |
| `Source/ServerScriptService/SlotMenuService.lua` | `ServerScriptService/SlotMenuService.lua` |
| `Source/ServerScriptService/Animal/SlotMath.lua` | `ServerScriptService/Animal/SlotMath.lua` |

In a Rojo `default.project.json`, the mapping is:

```json
{
  "name": "Inventory",
  "path": "ReusableSystems/Systems/Inventory/Source",
  "tree": {
    "$path": "ServerScriptService"
  }
}
```

(That single mapping puts `Base/`, `Action/`, `Animal/` and
`SlotMenuService.lua` at the right place, because the tree inside
`Source/` already mirrors the Roblox hierarchy.)

---

## 2. Copy the shared dependencies

This system does not ship its own copies of the modules it requires. Copy
them from the library (or write your own equivalents):

| Module | Library source | Roblox destination |
|---|---|---|
| `SlotType` | `ReusableSystems/Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |
| `Validation` | `ReusableSystems/Shared/Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Debug` | `ReusableSystems/Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `StandResolver` | `ReusableSystems/Shared/CommonModules/StandResolver.lua` | `ReplicatedStorage/Utility/StandResolver.lua` |
| `BigNumber` | `ReusableSystems/Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Remotes` | `ReusableSystems/Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Signals` | `ReusableSystems/Shared/Utilities/Signals.lua` | `ReplicatedStorage/Utility/Signals.lua` (required by `Remotes`) |
| `StudioTestMode` | `ReusableSystems/Shared/Utilities/StudioTestMode.lua` | `ReplicatedStorage/Utility/StudioTestMode.lua` (required by `SlotType`) |
| `AnimalStats` | `ReusableSystems/Shared/CommonModules/AnimalStats.lua` | `ReplicatedStorage/Utility/AnimalStats.lua` |

**Config modules** (from other systems, or write your own):

| Module | Library source | Roblox destination |
|---|---|---|
| `Bases` | `ReusableSystems/Systems/BasesAndSlots/Source/ReplicatedStorage/Config/World/Bases.lua` | `ReplicatedStorage/Config/World/Bases.lua` |
| `Prompts` | `ReusableSystems/Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` |
| `Security` | `ReusableSystems/Systems/AdminTools/Source/ReplicatedStorage/Config/Systems/Security.lua` | `ReplicatedStorage/Config/Systems/Security.lua` |
| `Animals` | `ReusableSystems/Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Animals.lua` | `ReplicatedStorage/Config/Creatures/Animals.lua` |
| `Progression` | `ReusableSystems/Systems/Upgrades/Source/ReplicatedStorage/Config/Creatures/Progression.lua` | `ReplicatedStorage/Config/Creatures/Progression.lua` |

**Service modules you must supply or port** (they are not in this
library's `Inventory` folder):

- `ServerScriptService/BaseService` — owns the base and slot records.
  This is the hard dependency; `SlotActionHandler` requires it at module
  load.
- `ServerScriptService/Base/NotificationService` — `NotifyWarning(player, id)`.
- `ServerScriptService/Carry/CarryRegistry` — copy it from
  `ReusableSystems/Systems/Carry/Source/ServerScriptService/Carry/CarryRegistry.lua`.
- `ServerScriptService/EggService`, `ServerScriptService.AnimalService`,
  `ServerScriptService.SellService`, `ServerScriptService.UpgradeService` —
  the dispatch targets. Required **lazily**; the handler resolves them on
  first use.
- `ServerScriptService/StandDisplayService` (optional) — repaints the
  stand's upgrade readout.

---

## 3. Third-party packages (Wally)

**None.** This system has no Wally dependencies.

The wider project does: `ProfileService` (player profiles) and `Janitor`
are needed by the PlayerData system, not by Inventory. See
`../../README.md` for the project-wide package list.

---

## 4. Configuration to tune

There is **no `Config.lua` in this system's folder** — it has no config of
its own. Tune these instead:

| What | Where | Default | Notes |
|---|---|---|---|
| Slot count per base | `Config/World/Bases.lua` → `Bases.Slots.Count` | `8` | The unified pool size. Changing it changes the snapshot array length. |
| Slot part size | `Bases.Slots.Size` | `Vector3.new(3.5, 0.6, 3.5)` | Must match the authored parts. |
| Slot layout | `Bases.Slots.Offsets` | 8-stop ring, radius 12, Y 2 | Generated from `Count`. |
| Action allowlist | `Config/World/Prompts.lua` → `Prompts.Carry.Actions` | Egg `{Pickup, Hatch}`, Animal `{Pickup, SellAnimal}`, Empty/Reserved `{Place}` | **The single source of truth for what actions exist.** Add a key here and both the client UI and the server dispatcher pick it up — but you must also add a dispatch branch in `SlotActionHandler.Handle`, or the request will be rejected as `InvalidAction`. |
| Action labels | `Prompts.Carry.ActionText`, `Prompts.Carry.PerKind` | see the module | Display only. |
| Menu labels | `Bases.Stands.Labels` | `'Upgrade'`, `'Unavailable'`, `'Max Level'`, `'Max'`, `'/sec'`, `'N/A'`, `'Egg'` | The server formats these into the preview. |
| Rate decimals | `Bases.Stands.UpgradeReadout.RateDecimals` | `2` | `$/sec` precision. |
| Menu throttle | `Config/Systems/Security.lua` → `Security.RequestThrottleSeconds` | `0.5` | Per player, per endpoint. |
| Level cap | `Config/Creatures/Progression.lua` → `Progression.MaxLevel` | `100` | The preview clamps to it. |

**Also change:** the slot-id prefix `p7:` in
`ReusableSystems/Shared/Types/SlotType.lua` (`BuildId` / `ParseId`) and
the matching pattern in `Validation.SlotId`. A new game should not ship
someone else's id namespace.

---

## 5. Author the Studio assets

The system walks the Workspace hierarchy but never creates it. Build this
in Studio (see `Dependencies.md` → *Required Studio Assets* for the full
tree):

```text
Workspace.Map.Bases
└── Base_1
    ├── Collector        BasePart
    ├── Spawn            BasePart
    ├── PlayerBoard → Main → SurfaceGui → Frame → {Name, Avatar}
    └── AnimalStands
        └── Stand1
            ├── Button
            │   ├── Base          BasePart
            │   └── PressPart     BasePart
            │       └── SurfaceGui → Amount (TextLabel)
            └── Slot
                ├── Root          BasePart
                └── MenuPart
                    └── MenuGui
                        └── UpgradeButton
                            ├── Level
                            ├── UpgradeAmount
                            └── UIStroke
```

Minimum for a working system: `Stand<k>.Slot.Root` (a `BasePart` — the
placement surface) for each of `Bases.Slots.Count` stands, and
`Stand<k>.Button.PressPart` + `Button.Base` for the cash button and the
facing target.

The `MenuPart → MenuGui → UpgradeButton` chain is optional; without it the
slot menu simply has no entry point. `StandResolver.GetStandParts` also
accepts a flat template where the stand itself is the slot (a runtime
clone carrying `Root`/`MenuPart` directly) — useful if you build stands
at runtime.

---

## 6. Bootstrap

Here is the exact sequence. The requires must be **top-level** for the
services, but the three display callbacks and the `SlotMenuService`
injections happen at boot, before any player joins.

```lua
-- ServerScriptService/Bootstrap.server.lua
local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

-- 1. Remotes folder FIRST — SlotMenuService.Init() needs it.
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Instance.new('Folder')
remotesFolder.Name = 'Remotes'
remotesFolder.Parent = ReplicatedStorage
for _, name in ipairs(Remotes.Names) do
    local ev = Instance.new('RemoteEvent')
    ev.Name = name
    ev.Parent = remotesFolder
end
Remotes.SetRemotes(remotesFolder)

-- 2. Services.
local SlotService = require(ServerScriptService.Base.SlotService)
local BaseService = require(ServerScriptService.BaseService)
local SlotMenuService = require(ServerScriptService.SlotMenuService)
local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)

-- 3. SlotService.
SlotService.Init()

-- 4. Wire the display callbacks BEFORE any base is registered,
--    so the first OccupySlot already repaints.
SlotService.SetOccupiedCountCallback(function(slot, delta)
    -- keep base._occupiedCount in sync
end)
SlotService.SetPoolDisplayCallback(function(slot)
    -- republish the cash-pool attribute + money label
end)
SlotService.SetStandDisplayCallback(function(slot)
    -- repaint the stand's direct-upgrade readout
end)

-- 5. Bases -> SlotService.RegisterBase for each.
BaseService.Init()
BaseService.RegisterBases(workspace)

-- 6. Menu service: connect the remotes, THEN inject the services.
SlotMenuService.Init()
SlotMenuService.SetPlayerService(PlayerService)
SlotMenuService.SetBaseService(BaseService)
SlotMenuService.SetSlotService(SlotService)
SlotMenuService.SetAnimalService(AnimalService)
SlotMenuService.SetEggService(EggService)
SlotMenuService.SetModifierService(ModifierService)
SlotMenuService.SetUpgradeService(UpgradeService)
SlotMenuService.SetStandDisplayService(StandDisplayService)

-- 7. Carry registry (the dispatcher reads it on every action).
CarryRegistry.Init()

-- 8. Per-player.
Players.PlayerAdded:Connect(function(player)
    local base = BaseService.AssignBaseForPlayer(player.UserId)
    -- AssignBaseForPlayer must call:
    --   SlotService.SetBaseOwner(player.UserId, base)
    --   SlotService.RebaseSlotIds(base)   -- after the ids are re-stamped
end)

Players.PlayerRemoving:Connect(function(player)
    SlotMenuService.ForgetPlayer(player.UserId)
    -- BaseService.ReleaseBase / CleanupPlayer must call:
    --   SlotService.ClearBaseOwner(user.UserId)
    --   SlotService.UnregisterBase(baseId)
end)
```

**A `CarryRegistry.Init()` caveat:** `CarryRegistry.Init()` **clears the
registry and its subscriber list**. Any service that subscribed to
`CarryRegistry.OnChanged` (the Carry system's `ResetProtectionService`,
`ToolLockService`, `PlayerGrabService`) must re-subscribe **after** it.
`CarryRegistry.Init` is idempotent-safe for the *carry state* but it does
reset `_subscribers`.

---

## 7. Smoke-test

Do these in order in Studio (Play, not Run):

1. **The remotes exist.** In the Explorer, `ReplicatedStorage.Remotes`
   should contain `SlotMenuRequest`, `SlotMenuState`, `SlotMenuAction`,
   `SlotMenuResult`. If `SlotMenuService.Init` warned
   `'SlotMenuRequest remote missing'`, the folder was created after
   `Init` ran.

2. **The bases register.** Call
   `BaseService.GetAllBases()` from the command bar. For each base,
   `expect(#b.slots).to.equal(Bases.Slots.Count)`. If the count is 0,
   `BaseService.RegisterBases(workspace)` never ran or the stand
   hierarchy does not match `StandResolver`.

3. **The slot index is populated.** Call
   `SlotService._dump()` — it returns the `slotById` table. It should
   have one entry per stand.

4. **The state machine works.** In the command bar, with a base assigned
   to yourself:

   ```lua
   local SlotService = require(game:GetService('ServerScriptService').Base.SlotService)
   local base = require(game:GetService('ServerScriptService').BaseService).GetBaseByOwner(<yourUserId>)
   local slot = base.slots[1]
   print(slot.state)                          -- 'Empty'
   print(SlotService.ReserveSlot(slot.id))    -- true
   print(slot.state)                          -- 'Reserved'
   print(SlotService.OccupySlot(slot.id, 'TEST_OCC', 'egg'))  -- true
   print(slot.state, slot.occupantId)         -- 'Occupied' 'TEST_OCC'
   print(SlotService.ReleaseSlot(slot.id))   -- true
   print(slot.state)                          -- 'Empty'
   ```

   Expected output: `Empty / true / Reserved / true / Occupied TEST_OCC /
   true / Empty`.

5. **The menu preview works.** With an animal on a slot (or the egg
   branch), call
   `require(ServerScriptService.SlotMenuService).BuildMenuState(player, slot.id)`
   from the command bar while playing as the owner. It should return
   `{ Valid = true, Kind = 'animal', ... }`. If it returns
   `{ Valid = false, Error = 'not-owner' }`, the base owner is not stamped
   (`SetBaseOwner` missing) — if it returns `{ Valid = false }` with no
   `Error`, one of the `SlotMenuService.Set*Service` injections is
   missing.

6. **The dispatcher rejects a forged action.** Fire the remote from the
   client (or call `SlotActionHandler.Handle(player, { Action = 'SellEgg',
   SlotId = slot.id })`) — it must return
   `{ success = false, error = 'InvalidAction' }`. Eggs must have no sell
   path.

7. **The console is clean.** No `[SlotMenu] Missing UpgradeButton for
   stand …` warnings if you authored the menu chain, and no
   `[SlotMenu] Missing SlotId for MenuPart under …` warnings.

8. **Run the specs.** See `../../Tests/README.md` for the runner. The four
   specs in `Tests/` (`SlotMath.spec`, `UnifiedSlot.spec`,
   `SlotActionHandler.spec`, `SlotMenuService.spec`) should all pass
   without any Workspace authoring beyond what `_Helpers` builds.
