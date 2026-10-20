# Animals — Setup

Installing this system into a new Rojo project. See
[README.md](README.md) for what it does and [Dependencies.md](Dependencies.md)
for the full dependency list.

---

## 1. Copy the files

This system's own `Source/` tree, at the exact Roblox paths:

| From | To |
|---|---|
| `Source/ServerScriptService/AnimalService.lua` | `ServerScriptService/AnimalService.lua` |
| `Source/ServerScriptService/Animal/*.lua` (5 files) | `ServerScriptService/Animal/*.lua` |
| `Source/ReplicatedStorage/Config/Creatures/Animals.lua` | `ReplicatedStorage/Config/Creatures/Animals.lua` |

Plus the shared modules this system needs from `ReusableSystems/Shared/`:

| From | To |
|---|---|
| `Shared/CommonModules/AnimalStats.lua` | `ReplicatedStorage/Utility/AnimalStats.lua` |
| `Shared/CommonModules/AnimalWeight.lua` | `ReplicatedStorage/Utility/AnimalWeight.lua` |
| `Shared/CommonModules/StatCalculator.lua` | `ReplicatedStorage/Utility/StatCalculator.lua` |
| `Shared/CommonModules/OwnedObjectIdentity.lua` | `ReplicatedStorage/Utility/OwnedObjectIdentity.lua` |
| `Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |
| `Shared/Types/EggType.lua` | `ReplicatedStorage/Types/EggType.lua` |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage/Types/RarityType.lua` |

### The cross-system files you also need

This system will not load on its own. These come from other systems in
the library:

| From | To | Needed for |
|---|---|---|
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | `ReplicatedStorage/Config/Creatures/Rarity.lua` | **Required by `Animals.lua` itself** (`require(script.Parent.Rarity)`). Without it the config fails to load. Also supplies the rarity colours and `BaseLevel`. |
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Traits.lua` | `ReplicatedStorage/Config/Creatures/Traits.lua` | The trait generation fold (`AnimalStats` Income). |
| `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Mutations.lua` | `ReplicatedStorage/Config/Creatures/Mutations.lua` | The mutation generation fold and the overhead icons. |
| `Systems/MutationsAndTraits/Source/ServerScriptService/TraitService.lua` | `ServerScriptService/TraitService.lua` | The inheritance roll and `IsValidTrait`. |
| `Systems/Upgrades/Source/ReplicatedStorage/Config/Creatures/Progression.lua` | `ReplicatedStorage/Config/Creatures/Progression.lua` | The level curve, `MaxLevel`, `Normalize`. |
| `Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` | The prompt text, the carry distance, the head clearance. |
| `Systems/Carry/Source/ServerScriptService/Carry/CarryRegistry.lua` | `ServerScriptService/Carry/CarryRegistry.lua` | The carry state. |
| `Systems/Inventory/Source/ServerScriptService/Animal/SlotMath.lua` | `ServerScriptService/Animal/SlotMath.lua` | The grounding math. |
| `Systems/Inventory/Source/ServerScriptService/Action/SlotActionHandler.lua` | `ServerScriptService/Action/SlotActionHandler.lua` | The Pickup / Place prompt router. |
| `Systems/BasesAndSlots/Source/ServerScriptService/StandPresentation.lua` | `ServerScriptService/StandPresentation.lua` | Required by `LevelUpPresentation`. |
| `Systems/Arena/Source/ServerScriptService/Arena/ArenaService.lua` | `ServerScriptService/Arena/ArenaService.lua` | The raid lock. Required at module scope. |
| `Systems/PlayerData/Source/ServerScriptService/PlayerService.lua` | `ServerScriptService/PlayerService.lua` | `ConsumeEggIntoAnimal`, `RemoveAnimal`, `PushState`. |
| `Systems/EggsAndHatching/Source/ServerScriptService/EggService.lua` | `ServerScriptService/EggService.lua` | `RefundHatch` on a failed hatch. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/World/Movement.lua` | `ReplicatedStorage/Config/World/Movement.lua` | The walk tuning. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/UI.lua` | `ReplicatedStorage/Config/Presentation/UI.lua` | The overhead config (trait colours, the stolen colour, the rainbow period). |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/Vfx.lua` | `ReplicatedStorage/Config/Presentation/Vfx.lua` | The bop phase durations + the upgrade VFX. |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage/Config/Systems/Debug.lua` | The debug switches. |
| `Systems/SharedUtilities/Source/ServerScriptService/Utility/PathfindingUtil.lua` | `ServerScriptService/Utility/PathfindingUtil.lua` | The pathfinding agent params. |
| `Systems/SharedUtilities/Source/ServerScriptService/Utility/MutationIcon.lua` | `ServerScriptService/Utility/MutationIcon.lua` | The mutation icons on the overhead. |
| `Systems/Notifications/Source/ServerScriptService/Base/NotificationService.lua` | `ServerScriptService/Base/NotificationService.lua` | The toasts. |
| `Systems/Tutorials/Source/ServerScriptService/Tutorial/TutorialSignals.lua` | `ServerScriptService/Tutorial/TutorialSignals.lua` | The `AnimalPickedUp` signal. |
| `Systems/Analytics/Source/ServerScriptService/FunnelService.lua` | `ServerScriptService/FunnelService.lua` | The funnel events. |
| `Systems/Stealing/Source/ServerScriptService/Steal/StealService.lua` | `ServerScriptService/Steal/StealService.lua` | The steal rollback (lazily required). |

A full working install is easier to get right by copying the **whole**
`ReusableSystems/Shared/` plus the systems listed above. See
[`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) for the closure.

**The paths are not negotiable.** The modules use
`require(script.Parent.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)`
and friends, so a file at the wrong depth breaks the chain with a
`Module not found` error that does not name the file you moved.

---

## 2. Install third-party packages

**None directly.** This system uses no Wally packages.

The shared modules it requires do:
`Shared/Utilities/Validation.lua` re-exports **`osyrisrblx/t`**, so
`t` must be installed:

```toml
# wally.toml
[dependencies]
t = "osyrisrblx/t@^1.0.0"
```

`Shared/Utilities/BigNumber.lua` is vendored in the library (no
package needed).

---

## 3. Wire the bootstrap

```lua
-- Animals
local AnimalService = require(ServerScriptService.AnimalService)

-- Injection FIRST: Init() wires the prompt callbacks, and those
-- callbacks reach a wired service.
AnimalService.SetPlayerService(PlayerService)
AnimalService.SetBaseService(BaseService)
AnimalService.SetEggService(EggService)
AnimalService.SetSlotService(SlotService)
AnimalService.SetModifierService(ModifierService)

AnimalService.Init()
```

### The exact order

```text
1. ReplicatedStorage.Utility.*  and  ReplicatedStorage.Types.*
2. ReplicatedStorage.Config.*   (Creatures.Animals, Creatures.Progression,
                                Creatures.Rarity, Creatures.Traits,
                                Creatures.Mutations, World.Prompts,
                                World.Movement, Presentation.UI,
                                Presentation.Vfx, Systems.Debug)
3. ServerScriptService.Utility.*  (PathfindingUtil, MutationIcon)
4. ServerScriptService.Animal.*  (WalkController, CarryController,
                                CarryPrompts, LevelUpPresentation,
                                AnimalOverhead)
5. ServerScriptService.AnimalService
6. Set*Service(...)  -- ALL of them, before Init()
7. AnimalService.Init()
```

**All five `Set*Service` calls must come before `Init()`.** `Init()`
installs the Pickup and Place prompt callbacks, and those callbacks
route through `SlotActionHandler`, which needs its peers wired.

`Init()` is idempotent, so calling it again is safe.

---

## 4. Tune the config

Open [Config.lua](Config.lua) for the consolidated, commented view. The
live values live in `ReplicatedStorage/Config/Creatures/Animals.lua`
(and in `Creatures/Progression.lua` for the level curve).

The values you are most likely to change:

| Value | Default | Notes |
|---|---|---|
| `Catalog` | 26 species over 6 tiers | **The roster.** Every entry needs a matching Studio model. |
| `Stats.Health[rarity]` | 5…1152 Base | The Health curve. `Maximum = Base * 10`. |
| `Stats.Damage[rarity]` | Health ÷ 10 | **Derived.** Never tune it independently. |
| `Stats.Income[rarity]` | 8…8000 Base | The per-second rate. **Curve is `80`, not `100`.** |
| `WeightByRarity[rarity]` | 10/40 … 1200/5000 | The growth range. |
| `SellBaseValue` | 100…100000 | The liquidation value. |
| `SellMultiplier` | `'0.75'` | A decimal **string**. Must terminate. |
| `MovementSpeed` | `10` | The walk speed. |
| `MaxLevel` | `100` | The progression ceiling. |
| `XP.BaseRequired` | `200` | XP for Level 1 -> 2. |
| `XP.GrowthRate` | `1.12` | **PINNED** — `UpgradeService` asserts this at load. |

**Two hard rules:**

- The **Damage row must be exactly Health ÷ 10** in `Base`, `Maximum`
  and `Curve`. `Animals.validateStats()` errors at require time
  otherwise. Tune Health; Damage follows.
- The **hatch-roll diagonal** (in the Eggs system's config) must stay
  non-zero for every egg rarity, or some eggs can never hatch an
  animal of a tier you actually have. With `Uncommon` and `Secret`
  empty, the Uncommon and Secret egg rows will re-roll (up to 8 times)
  and concentrate the surviving rarities.

---

## 5. Author Studio assets

1. **`ServerStorage.Animals.<Trait>.<Rarity>.<DefId>`** — the species
   models. The `<DefId>` node **is** the species `Model`.

   - The `<Trait>` folder is one of `Normal`, `Gold`, `Diamond`,
     `Rainbow`. `Normal` is the **guaranteed** fallback for every
     species; a missing `Normal` variant breaks **all** spawns of that
     species; a missing trait variant degrades to `Normal` with a
     warning.
   - Every model needs a **`HumanoidRootPart`** (it becomes the
     `PrimaryPart`).
   - The legacy flat shape `ServerStorage.Animals.<Rarity>.<DefId>` is
     also supported.

   **There is no procedural fallback for animals.** A missing template
   is a hard failure with a refund — you will see
   `template-missing` in the log and the player gets their egg back.

2. **`ServerStorage.Assets.OverheadGui.OverheadGuiTemplate`** — a
   `BillboardGui` with a `Container.Content` hierarchy containing
   `Name`, `Level`, `Income`, `Rarity`, `Trait`,
   `Stats.Health.Value`, `Stats.Damage.Value`, a `Mutations` container
   holding a **`Mutation1` prototype**, and a `Data` folder with
   `NumberValue`s named `Damage`, `Health`, `MaxHealth`.

   The module clones the template and paints the fields; you only
   author the layout. Missing template -> a warn-once and no overhead.

3. **`ServerStorage.Assets.Vfx.Upgrade`** — optional. An `Attachment`
   with a `ParticleEmitter`. Any embedded `Sound` will be **destroyed
   unplayed** (it would be audible server-wide) — the personal sting
   plays on the owning client instead.

4. **The bases** — owned by the BasesAndSlots system, but the animals
   need it: each base's **stand** parts (the animals are seated under
   `slot.stand`) and the **Collector** parts (the egg lands there).

---

## 6. Smoke-test it

The fastest check is a server-side script. Put this in a temporary
`ServerScriptService` script and run it in Play:

```lua
local ServerStorage = game:GetService('ServerStorage')
local AnimalService = require(ServerScriptService.AnimalService)
local AnimalConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Animals)

-- 1. The folder exists.
AnimalService.Init()
print('animals folder =', workspace:FindFirstChild('Animals') ~= nil)
-- expect true

-- 2. The catalog resolves.
local rarity, def = AnimalConfig.Get('Chicken')
print('Chicken ->', rarity, def and def.displayName)
-- expect Common  Chicken

-- 3. The empty buckets really are empty.
print('Uncommon =', AnimalConfig.GetRandom('Uncommon'))
print('Secret   =', AnimalConfig.GetRandom('Secret'))
-- expect nil  nil  (twice)

-- 4. The asset tree audit runs (a missing model is a WARN, not a throw).
for _, issue in ipairs(AnimalService.ValidateTemplates()) do
    print('TEMPLATE ISSUE:', issue)
end
for _, issue in ipairs(AnimalService.ValidateStudioCoverage()) do
    print('COVERAGE ISSUE:', issue)
end

-- 5. The template resolver finds the model.
local template = AnimalService.GetTemplate('Common', 'Chicken', nil)
print('template =', template and template:GetFullName())
-- expect ServerStorage.Animals.Normal.Common.Chicken

-- 6. The derived stats (no model needed).
local stats = require(game:GetService('ReplicatedStorage').Utility.AnimalStats)
print('L1  =', stats.Calculate({ DefId = 'Chicken', Level = 1 }, 'Health'))
print('L100=', stats.Calculate({ DefId = 'Chicken', Level = 100 }, 'Health'))
print('Dmg =', stats.Calculate({ DefId = 'Chicken', Level = 1 }, 'Damage'))
-- expect 5 / 50 / 0.5
```

**Pass criteria:** the folder exists, `Chicken` resolves to `Common`,
the two empty buckets return `nil`, the template audit prints no
issues, the template resolves, and Level 1 == `Base` exactly with
Damage == Health ÷ 10.

### Run the specs

`Tests/` holds 11 spec files. They require **Roblox Studio** — there
is no headless Luau runner in this project.

1. Open the place in Studio.
2. Make sure `ReusableSystems/Tests/_Helpers.lua` and
   `TestRunner.server.lua` are present, and that the spec files are
   mounted where `test.project.json` expects them
   (`ServerScriptService.TestEZTests`).
3. Run `TestRunner.server.lua` in Play mode.
4. The TestEZ output window lists each spec and its result.

> **The suite has never been executed as committed.** See
> `../../Tests/README.md` §1 for the three runner defects. Treat a
> failing spec as a **question about the code**, not automatically as a
> broken test.

**Two known spec bugs** (in the specs, not the source):

- `AnimalOverhead.spec.lua` expects `Triceratops` to be `Legendary`. It
  is **Mythic** (`Animals.lua:161`).
- `AnimalWalkHandoff.spec.lua`'s two "ForceReleaseBase" tests assert
  nothing (`expect(true).to.equal(true)`).

**`AnimalXP.spec.lua` is not a TestEZ spec at all** — it returns a
table, so TestEZ never collects it.

**Helper-path caveat:** `AnimalService.spec.lua` requires
`script.Parent._Helpers` and `AnimalWalkHandoff.spec.lua` requires
`ServerScriptService.TestEZTests._Helpers`. There is only **one**
`_Helpers.lua`, at `ReusableSystems/Tests/_Helpers.lua` — there is
**no** `_Helpers.lua` inside `Systems/Animals/Tests/`. Mount the shared
helper where the spec's require path expects it, or the spec errors
before it runs.

The shared helpers you will need:

- `Helpers.StubRemotes()` — destroys any existing
  `ReplicatedStorage.Remotes` folder and rebuilds it with one
  `RemoteEvent` per name in `Remotes.Names` (43). **Destructive.**
- `Helpers.WireServices()` — wires the same graph as the bootstrap.
- `Helpers.EnsureCollectors()` — pre-creates
  `Workspace.Bases.Base_<i>.Collector`. **This must run before
  `RegisterBases`**, which errors out on a base with no Collector.
- `Helpers.RegisterBasesForTest(services, userId)` — assigns a base to
  a test user and returns it.
- `Helpers.MakeRng(seed)` — a deterministic Park–Miller LCG.
- `Helpers.FakePlayer(userId, name?)` — a minimal `Player` stand-in.

---

## 7. Optional: make it observable in game

On its own this system produces animals that nobody can obtain. To wire
it into a playable loop you also need:

- **EggsAndHatching** — `EggService.HatchEgg` calls
  `AnimalService.CreateFromEgg` and needs
  `options.spawnCFrameOverride`, `options.TraitResolved`,
  `options.ResolvedTrait` and `options.ResolvedMutations`.
- **PlayerData** — `PlayerService.ConsumeEggIntoAnimal`,
  `AddAnimal`, `RemoveAnimal`, `GetPlayerData`, `PushState`.
- **BasesAndSlots / Inventory** — `BaseService`, `SlotService`,
  `SlotActionHandler`.
- **Carry** — `CarryRegistry` and `Config.World.Prompts`.
- **Notifications** — `NotificationService`, for the `Pickup_Success`,
  `Place_Success` and `Arrival_Success` toasts.
- **Arena** — `ArenaService`, for the raid lock.
- **Economy** — `IncomeService` reads `AnimalStats.Calculate(record,
  'Income')`; `SellService` reads the sell values.

---

## 8. Secrets

**None.** This system uses no API keys, tokens, webhook URLs or
credentials. If you extend it to call a third-party service, use a
placeholder in the repo and supply the real value at runtime through a
Roblox `HttpService` HTTP header or a Studio-only local module —
**never a literal in the source**.
