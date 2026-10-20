# EggsAndHatching — Setup

Installing this system into a new Rojo project. See
[README.md](README.md) for what it does and [Dependencies.md](Dependencies.md)
for the full dependency list.

---

## 1. Copy the files

This system's own `Source/` tree, at the exact Roblox paths:

| From | To |
|---|---|
| `Source/ServerScriptService/EggService.lua` | `ServerScriptService/EggService.lua` |
| `Source/ServerScriptService/Egg/*.lua` (13 files) | `ServerScriptService/Egg/*.lua` |
| `Source/ReplicatedStorage/Config/Creatures/Eggs.lua` | `ReplicatedStorage/Config/Creatures/Eggs.lua` |

Plus the shared modules this system needs from `ReusableSystems/Shared/`:

| From | To |
|---|---|
| `Shared/CommonModules/FloorGeometry.lua` | `ReplicatedStorage/Utility/FloorGeometry.lua` |
| `Shared/CommonModules/EggWalkAnimator.lua` | `ReplicatedStorage/Utility/EggWalkAnimator.lua` |
| `Shared/CommonModules/StandResolver.lua` | `ReplicatedStorage/Utility/StandResolver.lua` |
| `Shared/CommonModules/OwnedObjectIdentity.lua` | `ReplicatedStorage/Utility/OwnedObjectIdentity.lua` |
| `Shared/CommonModules/CenterPartBillboards.lua` | `ReplicatedStorage/Utility/CenterPartBillboards.lua` |
| `Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Shared/Utilities/WeightedDraw.lua` | `ReplicatedStorage/Utility/WeightedDraw.lua` |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Shared/Utilities/Signals.lua` | `ReplicatedStorage/Utility/Signals.lua` |
| `Shared/Utilities/AudioGroups.lua` | `ReplicatedStorage/Utility/AudioGroups.lua` |
| `Shared/Types/EggType.lua` | `ReplicatedStorage/Types/EggType.lua` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage/Types/RarityType.lua` |
| `Shared/Types/TransactionReason.lua` | `ReplicatedStorage/Types/TransactionReason.lua` |

### The cross-system files you also need

This system will not load on its own. These come from other systems in
the library:

| From | To | Needed for |
|---|---|---|
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | `ReplicatedStorage/Config/Creatures/Rarity.lua` | **The rarity table.** `Config/Creatures/Eggs.lua` requires it directly (`require(script.Parent.Rarity)`) — without it the config fails to load. |
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Mutations.lua` | `ReplicatedStorage/Config/Creatures/Mutations.lua` | The mutation ids the egg overhead renders. |
| `Systems/MutationsAndTraits/Source/ServerScriptService/TraitService.lua` | `ServerScriptService/TraitService.lua` | The hatch inheritance. |
| `Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Animals.lua` | `ReplicatedStorage/Config/Creatures/Animals.lua` | The hatch-roll target catalog. |
| `Systems/Animals/Source/ServerScriptService/Animal/CarryPrompts.lua` | `ServerScriptService/Animal/CarryPrompts.lua` | The prompt installer. |
| `Systems/Animals/Source/ServerScriptService/Animal/CarryController.lua` | `ServerScriptService/Animal/CarryController.lua` | The carry rig. |
| `Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` | The carry distance, hold duration and prompt text. |
| `Systems/Carry/Source/ServerScriptService/Carry/CarryRegistry.lua` | `ServerScriptService/Carry/CarryRegistry.lua` | The carry state. |
| `Systems/Inventory/Source/ServerScriptService/Animal/SlotMath.lua` | `ServerScriptService/Animal/SlotMath.lua` | The feet offset for the roulette previews. |
| `Systems/Inventory/Source/ServerScriptService/Action/SlotActionHandler.lua` | `ServerScriptService/Action/SlotActionHandler.lua` | The Hatch / Pickup prompt routing. |
| `Systems/BasesAndSlots/Source/ServerScriptService/StandPresentation.lua` | `ServerScriptService/StandPresentation.lua` | The stand wobble binding. |
| `Systems/Collectors/Source/ServerScriptService/Base/CollectorArrival.lua` | `ServerScriptService/Base/CollectorArrival.lua` | **Resolves the landing slot on arrival.** |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/World/Movement.lua` | `ReplicatedStorage/Config/World/Movement.lua` | The flight agent params. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/Vfx.lua` | `ReplicatedStorage/Config/Presentation/Vfx.lua` | The rarity explosion. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/UI.lua` | `ReplicatedStorage/Config/Presentation/UI.lua` | The overhead config. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage/Config/Systems/Debug.lua` | Debug switches. |
| `Systems/SharedUtilities/Source/ServerScriptService/ServerLuckService.lua` | `ServerScriptService/ServerLuckService.lua` | The luck-weighted centre roll. |
| `Systems/SharedUtilities/Source/ServerScriptService/Utility/PathfindingUtil.lua` | `ServerScriptService/Utility/PathfindingUtil.lua` | The yaw smoothing. |
| `Systems/SharedUtilities/Source/ServerScriptService/Utility/MutationIcon.lua` | `ServerScriptService/Utility/MutationIcon.lua` | The mutation icons. |
| `Systems/Notifications/Source/ServerScriptService/Base/NotificationService.lua` | `ServerScriptService/Base/NotificationService.lua` | The toasts. |
| `Systems/Economy/Source/ServerScriptService/EconomyService.lua` | `ServerScriptService/EconomyService.lua` | The purchase debit and the refund. |

A full working install is easier to get right by copying the **whole**
`ReusableSystems/Shared/` plus the systems listed above. See
[`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) for the closure.

**The paths are not negotiable.** The modules use
`require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Eggs)`
and friends, so a file at the wrong depth breaks the chain with a
`Module not found` error that does not name the file you moved.

---

## 2. Install third-party packages

**None.** This system uses no Wally packages.

---

## 3. Wire the bootstrap

```lua
-- EggsAndHatching
local EggService = require(ServerScriptService.EggService)

-- Injection FIRST: Init() wires the prompt callbacks, and those
-- callbacks reach a wired service.
EggService.SetPlayerService(PlayerService)
EggService.SetBaseService(BaseService)
EggService.SetAnimalService(AnimalService)
EggService.SetSlotService(SlotService)
EggService.SetEconomyService(EconomyService)

EggService.Init()              -- sub-modules + prompt callbacks
EggService.RegisterCenter(workspace)  -- creates Workspace.EggArea
EggService.Start()             -- the centre top-up thread
```

### The exact order

```text
1. ReplicatedStorage.Utility.*  and  ReplicatedStorage.Types.*
2. ReplicatedStorage.Config.*   (Rarity, Mutations, Animals, Eggs, Prompts, Movement, Vfx, UI, Debug)
3. ServerScriptService.Utility.*  (PathfindingUtil, MutationIcon)
4. ServerScriptService.Egg.*    (the sub-modules)
5. ServerScriptService.EggService
6. Set*Service(...)  -- ALL of them, before Init()
7. EggService.Init()
8. EggService.RegisterCenter(workspace)
9. EggService.Start()
```

**The `Set*Service` calls must all come before `Init()`.** `Init()`
wires the Buy / Hatch / Egg-Grab prompt callbacks, and those callbacks
call into `SlotActionHandler` and the economy, which need their peers
wired.

**`RegisterCenter()` before `Start()`.** The top-up thread spawns eggs,
and a spawn needs a registered centre to know the floor height.

---

## 4. Tune the config

Open [Config.lua](Config.lua) for the consolidated, commented view. The
live values live in `ReplicatedStorage/Config/Creatures/Eggs.lua`.

The values you are most likely to change:

| Value | Default | Notes |
|---|---|---|
| `Price` | 100 .. 100000 | A price change breaks the 70-85% hatch-and-sell recovery band. |
| `CenterSpawn.CenterMax` | `10` | The normal centre population target. |
| `CenterSpawn.Interval` | `30` | Seconds between top-up attempts. |
| `CenterSpawn.Radius` | `20` | The spawn ring radius. |
| `CenterSpawn.MinSpawnSpacing` | `7` | The minimum distance between two centre eggs. |
| `HatchRollWeights` | the 8x8 matrix | **The diagonal must stay non-zero.** |
| `EggLifetimeSeconds` | 300 .. 1200 | Per-rarity. |
| `ExpirySweepSeconds` | `5` | The sweep cadence. |
| `PurchasedTravelSpeed` | `5` | The flight is distance-derived from this. |
| `HoverClearance` | `3` | The gap under a hovering egg. |
| `EggAnimationsEnabled` | `false` | The master switch for the walk animation. |
| `Ambient` | ~45 values | The wander feel. |
| `Guarantees` | Legendary 600s, Mythic 1200s | The forced-spawn timers. |

**Two hard rules:**

- The **hatch-roll diagonal must be non-zero** for every egg rarity.
  A zero there means an egg can never hatch a same-tier animal. The
  spec asserts this.
- `CenterSpawnRarityWeights` **aliases**
  `Config.Creatures.Rarity.SpawnWeight` — it is the same table, not a
  copy. Editing one edits both. If you want to tune the two rolls
  independently, replace the alias with a literal table.

---

## 5. Author Studio assets

1. **`ServerStorage.EggTemplates.<Rarity>`** — one `Model` per rarity
   (Common, Uncommon, Rare, Epic, Mythic, Legendary, Divine, Secret).
   Each model needs a `PrimaryPart`. `ModelBuilder` picks a part named
   `'Primary'` if there is one, otherwise the first descendant
   `BasePart`.

   **If a template is missing, `ModelBuilder` falls back to a
   procedural cube — silently.** You will not see an error, you will
   see a plain box. Check the Explorer after the first spawn.

2. **`ServerStorage.Assets.Sfx.Pop`** and
   **`ServerStorage.Assets.Sfx.Reward`** — `Sound` objects. Without them
   the roll is **mute** (one loud session warning, no throw).

3. **`ServerStorage.Assets.Vfx.Explosions.<Rarity>`** — one effect per
   rarity, for the reveal. Optional; the reveal just has no VFX.

4. **`ServerStorage.Assets.OverheadGui.EggOverheadGuiTemplate`** — a
   `BillboardGui` template with a `Container.Content` hierarchy
   containing `Name`, `Price`, `Trait` and `Mutations`, plus a
   **`Mutation1` prototype** inside `Mutations` (one clone is made per
   mutation id and painted by `MutationIcon.PaintIcon`).

5. **`Workspace.Map.CenterPart.BillboardGui.Egg`** — the guarantee-timer
   node. Optional; without it the countdown UI does not update.

6. **The centre floor** — `SpawnService.RegisterCenter` creates
   `Workspace.EggArea.Floor` for you as a `40 x 1 x 40` Part. In the
   source game the real floor is a **90°-rotated Cylinder**, and
   `RegisterCenter` reads the height with
   `FloorGeometry.GetWorldTopY(floor)`, not `Size.Y / 2`. If you author
   your own floor, keep it a rotated cylinder.

---

## 6. Smoke-test it

The fastest check is a server-side script. Put this in a temporary
`ServerScriptService` script and run it in Play:

```lua
local ServerScriptService = game:GetService('ServerScriptService')
local EggService = require(ServerScriptService.EggService)
local SpawnService = require(ServerScriptService.Egg.SpawnService)

-- 1. The centre folders exist.
EggService.RegisterCenter(workspace)
print('floor y =', SpawnService.GetCenterFloorY())
print('active container =', SpawnService.GetActiveContainer():GetFullName())
-- expect .../Workspace.EggArea.ActiveEggs

-- 2. Spawn one egg of a known rarity.
local r = SpawnService.Request({
    definition = { rarity = 'Rare', price = 1000 },
    origin = 'Test',
})
print('spawn ->', r.success, r.egg and r.egg.rarity, r.error)
-- expect true  Rare  nil

-- 3. The registry sees it.
print('available =', SpawnService.CountNormalAvailable())  -- expect 1
print('centre eggs =', #EggService.ListCenterEggs())      -- expect 1

-- 4. The cap works. Spawn 12.
for i = 1, 12 do
    SpawnService.Request({
        definition = { rarity = 'Common', price = 100 },
        origin = 'Test',
    })
end
print('after 13 spawns, normal available =', SpawnService.CountNormalAvailable())
-- expect 10 -- the cap

-- 5. Bad inputs fail loudly but do not throw.
print('bad definition ->', SpawnService.Request({ definition = 'nope', origin = 'Test' }).error)
-- expect 'definition must be a table'
print('bad origin ->', SpawnService.Request({
    definition = { rarity = 'Common', price = 100 }, origin = 'Nope',
}).error)
-- expect 'origin must be Automatic, Admin, Persistence, or Test'

-- 6. Expiry.
print('sweep =', SpawnService.SweepExpired(os.clock() + 10_000))
-- expect 10 -- everything past its deadline
```

**Pass criteria:** the floor Y is a small number (not ~80), the cap
holds at 10, the bad-input calls return error strings rather than
throwing, and the sweep reaps the expired eggs.

### Run the specs

`Tests/` holds 14 spec files. They require **Roblox Studio** — there is
no headless Luau runner in this project.

1. Open the place in Studio.
2. Make sure `ReusableSystems/Tests/_Helpers.lua` and
   `TestRunner.server.lua` are present, and that the spec files are
   mounted where `test.project.json` expects them.
3. Run `TestRunner.server.lua` in Play mode.
4. The TestEZ output window lists each spec and its result.

The shared helpers you will need:

- `Helpers.StubRemotes()` — creates a `ReplicatedStorage.Remotes` folder
  with every remote in `Remotes.Names` and calls
  `Remotes.SetRemotes(folder)`.
- `Helpers.FakePlayer(userId)` — a minimal `Player` stand-in.
- `Helpers.WireServices()` — wires `PlayerService`, `EconomyService`,
  `SlotService`, `BaseService`, `EggService` and `AnimalService` the
  same way the bootstrap does.
- `Helpers.EnsureCollectors()` — pre-creates
  `Workspace.Bases.Base_<i>.Collector` for every base. **This must run
  before `RegisterBases`**, which errors out on a base with no
  Collector.
- `Helpers.RegisterBasesForTest(services, userId)` — assigns a base to
  a test user and returns it.

The specs that need a base (`EggFlightHandoff`, `EggContest`,
`EggConsumeOrder`) all call `EnsureCollectors` / `RegisterBasesForTest`
first.

---

## 7. Optional: make it observable in game

On its own this system produces eggs that nobody can buy or hatch. To
wire it into a playable loop you also need:

- **Economy** — `EconomyService.TrySpendMoney` / `AddMoney` for the
  purchase and the refund. `EggService` requires `EconomyService`
  directly as well as through `SetEconomyService`.
- **Animals** — `AnimalService.CreateFromEgg` is what the hatch calls.
  It must accept `options.spawnCFrameOverride`, `options.TraitResolved`,
  `options.ResolvedTrait` and `options.ResolvedMutations`.
- **PlayerData** — `PlayerService.AddEgg` / `RemoveEgg` / `SetEggSlot` /
  `RemoveEggAtSlot`, and `PersistenceAudit` to clean the records.
- **BasesAndSlots / Collectors** — `BaseService` for the base and the
  stands, `CollectorArrival` to resolve the landing slot, and
  `SlotService` for the slot state machine.
- **Carry** — `CarryRegistry` and `Config.World.Prompts`.
- **Inventory** — `SlotActionHandler`, which routes the Hatch and
  Pickup prompts.
- **Notifications** — `NotificationService`, for the `Buy_Success`,
  `Hatch_Success`, `Pickup_Success` and `RareEgg_Spawned` toasts.

---

## 8. Secrets

**None.** This system uses no API keys, tokens, webhook URLs or
credentials. If you extend it to call a third-party service, use a
placeholder in the repo and supply the real value at runtime through a
Roblox `HttpService` HTTP header or a Studio-only local module —
**never a literal in the source**.
