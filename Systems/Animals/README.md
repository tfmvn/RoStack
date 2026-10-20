# Animals

Server-authoritative animal ownership, spawning, walking, carrying, level
progression and the live overhead HUD.

**Portability:** **Grade A core** (the derived-stat pipeline, the identity
mint, the pathfinding walk, the carry rig, the level-up celebration, the
overhead renderer) **+ Grade B adapter** (the animal catalog, the trait
folder tree, and the rarity/stat tables are Brainrot Arena content).
**Grade A:** `AnimalService` is a hub over five mostly-portable modules;
`Animal.Weight`/`AnimalStats`/`AnimalWeight` are pure math; the walk and
carry controllers are engine-only but game-agnostic; the overhead renderer
reads a template you author. **Grade B:** `Config.Creatures.Animals`
(the 26-species roster, the per-rarity stat rows, the sell values), the
`ServerStorage.Animals/<Trait>/<Rarity>/<DefId>` Studio tree, and the
`Trait`/`Mutations` inheritance rules (which live in the
MutationsAndTraits system, not here).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

- Owns the **runtime `Animal` records** — one per owned animal, keyed by
  `AN_`-prefixed unique id, in a module-local registry.
- **Creates** an animal from an egg (`CreateFromEgg`) or restores one on
  rejoin (`SpawnFromPersistence`).
- **Walks** a newly-hatched animal from the egg to its slot along a
  `PathfindingService` polyline, then **occupies** the slot on arrival.
- **Carries** an animal on the player's head via a `Motor6D` weld, and
  places it back on any slot the player owns.
- **Derives** Health / Damage / Income from `Level` + the config on every
  read — never stored, never persisted, never accepted from the client.
- **Levels up** animals from XP (and from paid upgrades), with a
  server-driven "bop" celebration and a smooth weight-derived growth.
- **Renders** a live overhead billboard per animal (name, level, income,
  health, damage, rarity, trait, mutations).
- **Validates** the Studio asset tree against the config in both
  directions at boot, so catalog/Studio drift is reported once instead of
  once per failed hatch.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `ServerScriptService.AnimalService` | Module (server) | The hub. Frozen at return. |
| `ServerScriptService.Animal.AnimalOverhead` | Module (server) | The overhead billboard renderer. |
| `ServerScriptService.Animal.CarryController` | Module (server) | The head-weld carry rig. |
| `ServerScriptService.Animal.CarryPrompts` | Module (server) | The `ProximityPrompt` installer. |
| `ServerScriptService.Animal.LevelUpPresentation` | Module (server) | The level-up "bop" + VFX. |
| `ServerScriptService.Animal.WalkController` | Module (server) | The pathfinding walk driver. |
| `ReplicatedStorage.Config.Creatures.Animals` | Config module | The catalog, stats, weights and sell values. |
| `ReplicatedStorage.Utility.AnimalStats` | Shared module | The derived-stat layer (also used by the client). |
| `ReplicatedStorage.Utility.AnimalWeight` | Shared module | The derived-weight / growth layer. |
| `ReplicatedStorage.Utility.OwnedObjectIdentity` | Shared module | The `AN_` id mint. |
| `AnimalService.Init()` | Init | Creates `Workspace.Animals`; runs the one-shot asset validation; wires the prompt callbacks. |
| `AnimalService.Set*Service(svc)` | Injection | `SetPlayerService`, `SetBaseService`, `SetEggService`, `SetSlotService`, `SetModifierService`. |
| `AnimalService.CreateFromEgg(...)` | Transaction | The hatch. Returns `{ success, animalId }`. |
| `AnimalService.SpawnFromPersistence(...)` | Transaction | The rejoin restore. |
| `AnimalService.GrabAnimal` / `PlaceAnimal` | Transaction | The carry. Return `nil` on success or an error string. |
| `AnimalService:AddXP(animalId, amount)` | Transaction | The XP pipeline. Returns a rich result table. **Colon form.** |
| `AnimalService.ApplyLevelUpgrade(uniqueId)` | Transaction | The paid level bump. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/AnimalService.lua` | `ServerScriptService/AnimalService.lua` | The hub: the record registry, creation, carry, XP, cleanup. |
| `Source/ServerScriptService/Animal/WalkController.lua` | `ServerScriptService/Animal/WalkController.lua` | Drives `model:PivotTo` along the pathfinder polyline. |
| `Source/ServerScriptService/Animal/CarryController.lua` | `ServerScriptService/Animal/CarryController.lua` | Welds the carried animal to the player's `Head`. |
| `Source/ServerScriptService/Animal/CarryPrompts.lua` | `ServerScriptService/Animal/CarryPrompts.lua` | Installs/removes every `ProximityPrompt`. |
| `Source/ServerScriptService/Animal/LevelUpPresentation.lua` | `ServerScriptService/Animal/LevelUpPresentation.lua` | The bop celebration + upgrade VFX + growth. |
| `Source/ServerScriptService/Animal/AnimalOverhead.lua` | `ServerScriptService/Animal/AnimalOverhead.lua` | The live overhead billboard. |
| `Source/ReplicatedStorage/Config/Creatures/Animals.lua` | `ReplicatedStorage/Config/Creatures/Animals.lua` | The catalog, stats, weights, sell values, carry re-export. |

Shared modules this system requires (they live in `ReusableSystems/Shared/`
or in sibling systems — see [Dependencies.md](Dependencies.md)):

| Shared module | Roblox destination | Purpose |
|---|---|---|
| `Shared/CommonModules/AnimalStats.lua` | `ReplicatedStorage/Utility/AnimalStats.lua` | Health / Damage / Income derivation. |
| `Shared/CommonModules/AnimalWeight.lua` | `ReplicatedStorage/Utility/AnimalWeight.lua` | Weight + growth derivation. |
| `Shared/CommonModules/StatCalculator.lua` | `ReplicatedStorage/Utility/StatCalculator.lua` | The universal logarithmic stat curve. |
| `Shared/CommonModules/OwnedObjectIdentity.lua` | `ReplicatedStorage/Utility/OwnedObjectIdentity.lua` | The `AN_` id mint and validator. |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` | The `Debug.Log` / `Debug.Warn` wrappers. |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` | The `t`-based validators. |
| `Shared/Utilities/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` | The client remote registry. |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` | Decimal-string money arithmetic + `Format`. |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` | Slot states, occupant kinds, id parsing. |
| `Shared/Types/EggType.lua` | `ReplicatedStorage/Types/EggType.lua` | The egg lifecycle states. |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage/Types/RarityType.lua` | The rarity id enum. |

---

## Configuration

The live config is `ReplicatedStorage/Config/Creatures/Animals.lua`. The
consolidated, commented view is in [Config.lua](Config.lua). The
progression values this system reads live in a **different** module —
`ReplicatedStorage/Config/Creatures/Progression.lua` (owned by the
Upgrades system).

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `Catalog[rarity][defId]` | `Creatures/Animals.lua` | 26 entries across 6 populated tiers | The roster. **Uncommon and Secret are intentionally empty.** |
| `Stats.Health[rarity]` | `Creatures/Animals.lua` | `{ Base, Maximum, Curve }` per tier | The Health curve. Curve is `100` for every tier. |
| `Stats.Damage[rarity]` | `Creatures/Animals.lua` | `{ Base, Maximum, Curve }` per tier | **Derived** — must be exactly Health ÷ 10. |
| `Stats.Income[rarity]` | `Creatures/Animals.lua` | `{ Base, Maximum, Curve = 80 }` per tier | The per-second rate. **Curve is `80`, not `100`.** |
| `WeightByRarity[rarity]` | `Creatures/Animals.lua` | 10/40 … 1200/5000 | The weight range used for growth. |
| `WeightByDefinition` | `Creatures/Animals.lua` | `{}` (empty) | Per-species overrides. **Empty in practice.** |
| `SellBaseValue` / `SellMultiplier` | `Creatures/Animals.lua` | 100…100000, all `'0.75'` | The liquidation value. |
| `MovementSpeed` | `Creatures/Animals.lua` | `10` | The walk speed (studs/s). |
| `BaseHealth` / `BaseDamage` / `DefaultLevel` | `Creatures/Animals.lua` | `5` / `2` / `1` | Legacy creation-time values. |
| `Carry.*` | `Creatures/Animals.lua` | re-export of `World.Prompts` | Max distance, hold duration, prompt text, head clearance. |
| `RarityMultipliers` | `Creatures/Animals.lua` | Health 1.0…16.0, Damage 1.0…25.0 | **RETIRED.** Kept only as the derivation source for the `Stats` Base values. |
| `MaxLevel` | `Creatures/Progression.lua` | `100` | The progression ceiling. |
| `XP.BaseRequired` / `XP.GrowthRate` | `Creatures/Progression.lua` | `200` / `1.12` | `XPRequired(L) = Base * Growth^(L-1)`. |
| `PointsPerLevel` | `Creatures/Progression.lua` | `3` | `P(L) = 3 * (L - 1)`. |

### The 10:1 combat invariant

`Damage` is **always** exactly `Health / 10`, enforced in one place:
`AnimalStats.Calculate` short-circuits `Damage` to `Calculate(animal,
'Health') / 10`. The config's `Stats.Damage` rows are the *documented*
mirror of the Health rows, and `Animals.validateStats()` errors at require
time if a `Damage` row is not `Health / 10` across `Base`, `Maximum` and
`Curve`.

Two independent `Damage` curves cannot hold a ratio across a
nonlinear curve — that drift is what produced the old "~400 HP with ~312
Damage" observations. `AnimalStats.spec.lua` asserts the invariant is
bit-exact across the whole level range for every rarity.

---

## Dependencies

- **Config** — `Config.Creatures.Animals`, `Config.Creatures.Progression`,
  `Config.Creatures.Rarity` (cross-system), `Config.Creatures.Mutations`
  (cross-system), `Config.Creatures.Traits` (cross-system),
  `Config.World.Prompts` (cross-system), `Config.World.Movement`
  (cross-system), `Config.Presentation.UI` (cross-system),
  `Config.Presentation.Vfx` (cross-system).
- **Shared utilities** — `AnimalStats`, `AnimalWeight`, `StatCalculator`,
  `OwnedObjectIdentity`, `Debug`, `Validation`, `Remotes`, `BigNumber`.
- **Types** — `SlotType`, `EggType`, `RarityType`.
- **Sibling systems** — `TraitService` (inheritance), `Carry.CarryRegistry`
  (the carry state), `Arena.ArenaService` (the raid lock),
  `Action.SlotActionHandler` (the prompt router), `Animal.SlotMath`
  (grounding), `Base.NotificationService`, `Tutorial.TutorialSignals`,
  `FunnelService`, `Steal.StealService` (lazily required), and
  `ServerScriptService.Utility.MutationIcon` + `PathfindingUtil`.

Full paths, remotes, profile fields and Studio assets:
[Dependencies.md](Dependencies.md).

---

## Initialization Order

```text
1. ReplicatedStorage.Utility.*  and  ReplicatedStorage.Types.*
2. ReplicatedStorage.Config.*   (Creatures.Animals, Creatures.Progression,
                                World.Prompts, World.Movement,
                                Presentation.UI, Presentation.Vfx)
3. ServerScriptService.Utility.*  (PathfindingUtil, MutationIcon)
4. ServerScriptService.Animal.*  (WalkController, CarryController,
                                CarryPrompts, LevelUpPresentation,
                                AnimalOverhead)
5. ServerScriptService.AnimalService
6. AnimalService.SetPlayerService(PlayerService)
   AnimalService.SetBaseService(BaseService)
   AnimalService.SetEggService(EggService)
   AnimalService.SetSlotService(SlotService)
   AnimalService.SetModifierService(ModifierService)
7. AnimalService.Init()
```

`Init()` is **idempotent** and does four things: create
`Workspace.Animals`; run the one-shot `ValidateTemplates()` +
`ValidateStudioCoverage()` audit (results go to `Debug.Warn`, one line
per issue); call
`LevelUpPresentation.SetWeightProvider(AnimalWeight.GetTargetScale)`;
and install the **Pickup** and **Place** prompt callbacks.

The callbacks route through `SlotActionHandler`, so the callback
installation must come **after** the services the handler needs are
wired.

---

## Data

### The runtime record

```lua
{
    uniqueId      = 'AN_a1B2c3D4e5',   -- the persistence key
    definitionId  = 'Chicken',         -- the catalog id
    displayName   = 'Chicken',
    rarity        = 'Common',
    ownerUserId   = 12345,
    slotId        = 'p7:1:animal:3',   -- nil while Carried
    spawnSlotId   = 'p7:1:lucky:3',    -- where it was hatched
    Level         = 1,
    XP            = 0,                 -- CURRENT progress, not lifetime
    Trait         = 'Gold',            -- string | nil (nil = no trait)
    Mutations     = { 'Galactic' },    -- unique array
    model         = <Model>,
    animations    = { walk = ..., idle = ... },
    baseScale     = 1.0,               -- the template's authored scale
    state         = 'Slotted',         -- 'Slotted' | 'Carried' | 'Recovering'
    carriedBy     = nil,               -- number while Carried
    originalSlotId = nil,              -- string, the recovery hint
    _mutex        = false,
    createdAt     = 1234.5,
    controller    = nil,               -- the walk/carry controller
    controllerType = nil,              -- 'Walk' | 'Carry'
    _refs         = { baseService, playerService, eggService, slotService },
}
```

### What is *not* stored

**Health, Damage, Income, Weight and Scale are derived, never stored and
never persisted.** They are recomputed from `Level` + the definition +
the config on every read, so a level change can never leave a stale
stat behind and rejoin lands at the correct size automatically.

### Carry states

`state` is one of exactly three values: `Slotted`, `Carried`,
`Recovering`. A `Carried` record has `slotId == nil` and carries
`carriedBy` + `originalSlotId` as recovery hints. A `Recovering` record
**preserves** both hints.

### Profile fields

`PlayerService` stores the animal in the `Brainrots` table, keyed by
`Id` (the `AN_` id). The fields read and written are `Id`, `DefId`,
`SlotId`, `Level`, `XP`, `Trait`, `Mutations`, `CashPool`.

---

## Known Limitations

- **The Studio asset tree is mandatory.** `ServerStorage.Animals/<Trait>/<Rarity>/<DefId>`
  must exist for every catalog species, or `CreateFromEgg` fails with
  `template-missing` and **the egg is refunded**. There is no
  procedural fallback for animals (unlike eggs, which do have one).
  The `Normal` variant is the guaranteed fallback for every trait; a
  missing `Gold`/`Diamond`/`Rainbow` variant degrades to `Normal` with
  a warning.
- **`WalkController.lua` carries the comment `# NEED TO REMOVE THIS
  FILE IN FUTURE`** on its first line. The module is live and required;
  the comment refers to a planned consolidation into a shared
  pathfinding module that has not happened.
- **`WalkController.FacingOffset = 0`**, while `Egg.FlightController.FacingOffset = math.pi`.
  The animals face the way they walk; the eggs are flipped 180° because
  their templates are authored with the visual front on local `+Z`.
  `WalkYaw.spec.lua` locks the animal value at `0` with a negative
  control at `math.pi`.
- **`Uncommon` and `Secret` have empty catalog buckets.** `GetRandom`
  returns `nil, nil` for them, and `Get` can never return a `Secret`
  rarity. The `Stats`, `WeightByRarity`, `SellBaseValue` and
  `BaseLevel` tables **do** have rows for both — the data is ready for
  content that has not been authored yet.
- **`WeightByDefinition` is empty** (only commented-out `Mouse` and
  `Dragon` examples), so the per-definition override branch of
  `AnimalWeight.GetRange` is never exercised at runtime.
- **`Animals.RarityMultipliers` and `Animals.GetHealth` /
  `Animals.GetDamage` are RETIRED.** Nothing in the runtime calls them.
  They are kept only as the documented derivation source for the
  `Stats` Base values. **Do not build new systems on them.**
- **`Animals.Carry` is a re-export** of `Config.World.Prompts`, not a
  source of truth. Editing `Animals.Carry.MaxDistance` at runtime does
  nothing — the prompts read `Prompts.CarryMaxDistance` directly.
  `Prompts.Carry.PerKind[Animal]` is the live source of the four prompt
  text strings.
- **`Animals.Stats.Income` uses `Curve = 80`**, while Health and Damage
  use `Curve = 100`. Any doc that says "all stat rows share Curve = 100"
  is wrong.
- **The arena raid lock and the steal flow are read-only here.** The
  `RaidLocked` and `StealInProgress` rejection reasons exist so that a
  raid or a steal transaction cannot be corrupted by a carry; the
  transactions themselves belong to the Arena and Stealing systems.
- **`ArenaService` is required at module scope**, but the comment says
  "Require-safe: ArenaService depends only on ReplicatedStorage modules".
  The dependency is real, not optional.
- **No `TweenService` anywhere.** All movement is
  `RunService.Heartbeat` + `model:PivotTo()` / `model:ScaleTo()`.
- **No `BodyMovers` / `BodyGyro`.** The carried animal rides a
  `Motor6D` on the head, not a physics constraint.

---

## Testing

Eleven spec files in `Tests/`:

| Spec | Covers |
|---|---|
| `AnimalService.spec.lua` | The catalog bucket counts (Common 5, **Uncommon 0**, Rare 4, Epic 5, Mythic 5, Legendary 4, Divine 3, **Secret 0**), every entry having `displayName` / `baseHealth` / `baseDamage`, `RarityMultipliers` monotonicity, `GetHealth` / `GetDamage` / `GetRandom` / `Get`, and the `BaseLevel` table. |
| `AnimalStats.spec.lua` | The config completeness contract for all 8 tiers × 3 stats, Level 1 == `Base` bit-exact, MaxLevel == `Maximum` bit-exact, the logarithmic curve, monotonicity and bounds across the whole 1..100 range, rarity separation, delegation to `StatCalculator`, the **10:1 invariant bit-exact across the whole range**, the Income row set, and the fail-safes (malformed Level, unknown DefId -> 0, programming errors -> throw). |
| `AnimalWeight.spec.lua` | `CalculateWeight` (Base at L1, Maximum at MaxLevel, strictly increasing, capped, malformed levels repaired, unknown defs -> nil), `GrowthAlpha`, `GetGrowthMultiplier`, `GetTargetScale` (relative, never universal, never compounding). |
| `AnimalTemplate.spec.lua` | `GetTemplate` trait+rarity+species resolution, the `Normal` fallback, nil/invalid traits treated as `Normal`, never descending into the species model, the legacy `Animals/<Rarity>/<DefId>` shape, and both validators. |
| `AnimalOverhead.spec.lua` | Exactly one overhead on `CENTER`, the authoritative field values, the `CurrentHealth` override, hiding the Trait / Mutations containers, Mutation1-prototype reconciliation without duplicates, level-up refresh, graceful failure without template/model/anchor, `RemoveForAnimal`, the legacy `OverheadTemplate` migration, the rarity styling, the trait styling with a **shared** Rainbow animation, and the `SetStolen` presentation (including the per-child remembered visibility on restore). |
| `AnimalCarryConfig.spec.lua` | The `Animals.Carry` shape: positive `MaxDistance`, non-negative `HoldDuration`, non-empty prompt texts, non-negative `HeadClearanceStuds`, and the **absence** of the legacy `CarryOffset` / `YawSmoothing` keys. |
| `AnimalType.spec.lua` | The pure record contract: the three carry-state values, `carriedBy` as a number, `originalSlotId` as a string, `slotId == nil` while Carried, and the hints preserved while Recovering. |
| `AnimalWalkHandoff.spec.lua` | `CreateFromEgg` anchoring every part, the slot-standing math, `SpawnFromPersistence` dropping the record and releasing the slot on a missing template, and `ForceReleaseBase` not erroring. |
| `LevelUpPresentation.spec.lua` | Malformed `NotifyLevelUp` never throwing, exactly one celebration per real level change, the paid upgrade path, the merge / per-animal independence of the generation counter, a capped weight still celebrating, the `_TestIsDriving` contract, `Cancel` bumping the generation, a missing VFX asset, the clone-never-mutate rule, the **absent** server audio API (`EnsureLevelUpSfx` and `PlayLevelUpSfx` are `nil`), and the no-Y-ratchet-under-spam guarantee. |
| `WalkYaw.spec.lua` | `WalkController.FacingOffset == 0`, with a negative control at `math.pi`. |
| `AnimalXP.spec.lua` | **Not a TestEZ spec** — see the note below. |

**They require Roblox Studio.** There is no headless Luau runner in this
project. See `../../Tests/README.md`.

> **The suite has never been executed as committed.** "11 specs" means
> "11 specs exist that were written against this code", **not** "11 were
> observed passing". `../../Tests/README.md` §1 documents the three
> runner defects that block execution. Treat a failing spec as a
> **question about the code**, not automatically as a broken test.
>
> **`AnimalXP.spec.lua` is not a TestEZ spec at all.** It returns a
> **table** of `Test*` methods using raw `assert`, imports **no**
> production module, and has no `describe` / `it`. TestEZ 0.4.1 collects
> only modules that return a function, so this file is **never
> collected** and asserts nothing about the codebase. Every claim in it
> is about locally-constructed plain tables. It is dead documentation,
> not a test.
>
> **Helper-path caveat:** `AnimalService.spec.lua` requires
> `script.Parent._Helpers` and `AnimalWalkHandoff.spec.lua` requires
> `ServerScriptService.TestEZTests._Helpers`. There is only **one**
> `_Helpers.lua`, at `ReusableSystems/Tests/_Helpers.lua` — there is
> **no** `_Helpers.lua` inside `Systems/Animals/Tests/`. You must mount
> the shared helper where the spec's require path expects it, or the
> spec errors before it runs.

The shared helpers you will need:

- `Helpers.StubRemotes()` — destroys any existing
  `ReplicatedStorage.Remotes` folder and rebuilds it with one
  `RemoteEvent` per name in `Remotes.Names` (43). **This is
  destructive** and permanently replaces the live remote set for the
  rest of the run.
- `Helpers.WireServices()` — wires the same graph as the bootstrap.
- `Helpers.EnsureCollectors()` — pre-creates
  `Workspace.Bases.Base_<i>.Collector`. **Must run before
  `RegisterBases`**, which errors on a base with no Collector.
- `Helpers.RegisterBasesForTest(services, userId)` — assigns a base to a
  test user and returns it.
- `Helpers.MakeRng(seed)` — a deterministic Park–Miller LCG.
- `Helpers.FakePlayer(userId, name?)` — a minimal `Player` stand-in.

### Two spec assertions that contradict the source

These are **bugs in the specs**, not in the implementation. They are
documented here so nobody "fixes" the source to match them:

1. **`AnimalOverhead.spec.lua` expects `Triceratops` to be `Legendary`.**
   `Triceratops` is in the **Mythic** bucket (`Animals.lua:161`); the
   Mythic colour is `Color3.fromRGB(255, 0, 4)`. The overhead resolves
   rarity via `AnimalConfig.Get(definitionId)`, so the correct
   expectation is `'Mythic'`. This assertion should fail.
2. **`AnimalWalkHandoff.spec.lua`'s two "ForceReleaseBase" tests assert
   nothing.** Both end with `expect(true).to.equal(true)`. The spec
   header promises "`_aborted` flag set and model destroyed"; no such
   assertion exists.

---

## Adapting to a New Game

1. **Replace the catalog.** `Config/Creatures/Animals.lua` is the only
   Brainrot Arena-specific file in this system. Adding a species is one
   table entry; the services do not need to be touched.
2. **Keep the 10:1 invariant.** If you write your own `Stats.Damage`
   rows, make them exactly `Health / 10` in `Base`, `Maximum` **and**
   `Curve`. `Animals.validateStats()` enforces this at require time, and
   `AnimalStats` enforces it at runtime regardless.
3. **Keep the derived-not-persisted rule.** Never add a `Health` field
   to the record or the profile. Level is the only progression state.
4. **Author the Studio tree.** `ServerStorage.Animals/<Trait>/<Rarity>/<DefId>`,
   where the `<DefId>` node **is** the species `Model` (not a folder
   containing one). Every catalog species needs a `Normal` variant.
5. **Author `HumanoidRootPart`.** The model must have one; it becomes
   the `PrimaryPart`. A model without it fails with
   `template-no-humanoidrootpart` and the egg is refunded.
6. **Keep the identity mint.** Use `OwnedObjectIdentity.GenerateUnique`
   with `Kind.Animal`. Never mint an id inline — the id is the
   persistence key, and a rejoin that mints a fresh one makes the
   animal's identity unstable.
7. **Keep the `AN_` / `EG_` separation.** The registry is keyed by id;
   an animal id must never collide with an egg id.
8. **Keep the three carry states** (`Slotted` / `Carried` /
   `Recovering`) and the `originalSlotId` recovery hint.
9. **Keep the carry-reservation invariant.** The source slot is
   `DemoteSlotToReserved`d on grab and is re-occupied on return. A
   same-slot return is `Reserved -> Occupied`; a different-slot return
   is `Reserved -> Empty` plus a fresh `Empty -> Reserved -> Occupied`.
10. **Keep the template resolver's fallback chain** (trait -> `Normal` ->
    legacy flat shape). The legacy shape is what keeps an old Studio
    layout working during migration.
11. **If you change the trait set, you change the folder tree.** The
    resolver maps a gameplay trait value to a folder name in exactly one
    place (`ResolveTraitFolder`). `nil` and `''` both mean `Normal` —
    never the string `'None'`.
12. **Keep `Debug.Log` / `Debug.Warn`.** The central debug logger is
    switched per side; plain `warn()` bypasses it and is a regression.
