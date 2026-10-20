# MutationsAndTraits — Setup

Installing this system into a new Rojo project. See
[README.md](README.md) for what it does and [Dependencies.md](Dependencies.md)
for the full dependency list.

---

## 1. Copy the files

This system's own `Source/` tree, at the exact Roblox paths:

| From | To |
|---|---|
| `Source/ServerScriptService/TraitService.lua` | `ServerScriptService/TraitService.lua` |
| `Source/ServerScriptService/MutationService.lua` | `ServerScriptService/MutationService.lua` |
| `Source/ReplicatedStorage/Config/Creatures/Traits.lua` | `ReplicatedStorage/Config/Creatures/Traits.lua` |
| `Source/ReplicatedStorage/Config/Creatures/Mutations.lua` | `ReplicatedStorage/Config/Creatures/Mutations.lua` |
| `Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | `ReplicatedStorage/Config/Creatures/Rarity.lua` |
| `Source/ReplicatedStorage/Config/RarityConfig.lua` | `ReplicatedStorage/Config/RarityConfig.lua` — **optional, see step 5** |

Plus three shared modules from `ReusableSystems/Shared/`:

| From | To |
|---|---|
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage/Types/RarityType.lua` |

In a Rojo project that maps `ReplicatedStorage` and `ServerScriptService`
from disk, this means your `src/` tree should end up like this:

```text
src/
├── ReplicatedStorage/
│   ├── Types/
│   │   └── RarityType.lua
│   ├── Utility/
│   │   ├── BigNumber.lua
│   │   └── Debug.lua
│   └── Config/
│       └── Creatures/
│           ├── Rarity.lua
│           ├── Traits.lua
│           └── Mutations.lua
└── ServerScriptService/
    ├── TraitService.lua
    └── MutationService.lua
```

**The paths are not negotiable.** The modules use
`require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Traits)`
and friends, so a file at the wrong depth breaks the chain with a
`Module not found` error that does not name the file you moved.

**`Shared/CommonModules/*` and `Shared/Utilities/*` both go to
`ReplicatedStorage/Utility/`.** If you already have a
`ReplicatedStorage/Utility/` folder, merge into it — do not create a
second one.

---

## 2. Install third-party packages

**None.** This system requires no Wally packages.

---

## 3. Wire the bootstrap

Add to your server bootstrap (`ServerScriptService/bootstrap.server.lua` or
equivalent):

```lua
-- MutationsAndTraits
local TraitService = require(script.Parent.TraitService)
local MutationService = require(script.Parent.MutationService)

TraitService.Init()      -- no-op (stateless)
MutationService.Init()   -- no-op (stateless)
```

`Init()` is safe to skip — both services are pure functions over their
config. Call them anyway so the wiring is discoverable.

### The exact order

```text
1. ReplicatedStorage.Utility.Debug          (no deps)
2. ReplicatedStorage.Utility.BigNumber      (no deps)
3. ReplicatedStorage.Types.RarityType       (pure data)
4. ReplicatedStorage.Config.Creatures.Rarity
5. ReplicatedStorage.Config.Creatures.Traits
6. ReplicatedStorage.Config.Creatures.Mutations
7. ServerScriptService.MutationService
8. ServerScriptService.TraitService
```

The `require` chain enforces 1-8 by itself as long as the files are at
the right paths. The only hard ordering rule is that
`MutationService` must be requirable before `TraitService` (which
requires it) — again handled automatically.

### How the surrounding systems call it

| Caller | Call |
|---|---|
| `EggService.HatchEgg` | `TraitService.ResolveInheritance(egg.Trait, egg.Mutations, nil)` — **once** per hatch, inside the open mutex. |
| `AnimalService.CreateFromEgg` | Receives the resolved values as `options.ResolvedTrait` / `options.ResolvedMutations` and writes them onto the new animal. |
| `AnimalStats.Calculate` (shared) | `Traits.GenerationMultiplierFor(trait)` and `Mutations.GenerationFold(mutations)` for the income stat. |
| The sell path | `Traits.SellMultiplierFor(trait)` and `Mutations.SellFold(mutations)` — both return **strings**. |
| `PersistenceAudit` (PlayerData) | `TraitService.IsValidTrait` / `MutationService.SanitizeList` to clean legacy rows. |

---

## 4. Tune the config

Open [Config.lua](Config.lua) for the consolidated, commented view. The
live values live in:

- `ReplicatedStorage/Config/Creatures/Traits.lua` — the trait catalog
  and `RollOrder`.
- `ReplicatedStorage/Config/Creatures/Mutations.lua` — the mutation
  catalog.
- `ReplicatedStorage/Config/Creatures/Rarity.lua` — the rarity table.

**The most common tuning mistake:** multipliers are **decimal strings**,
not numbers. Write `'2.5'`, not `2.5`. A number is rejected at require
time by `_isValidMultiplier` and the server will not boot.

Other rules the validators enforce at require time:

- A multiplier string is 1..12 chars, matches `^%d+%.?%d*$`, has value in
  `(0, 1e6]`, and has at most **6 significant digits**.
- A `Chance` is a number in `0..100`; the total across `RollOrder` must
  be `<= 100`.
- Every `Catalog` entry must appear in `RollOrder` and vice-versa.
- The mutation catalog must not be empty.

The two rarest things to touch:

- **Trait `SellMultiplier`.** Deliberately modest (x1.2 / x1.5 / x2)
  next to the income multiplier (x3 / x5 / x10). The flip EV math
  assumes trait sell EV ~= 1.05; raising these invalidates every egg's
  hatch-and-sell EV.
- **`Rarity.SpawnWeight`.** Mythic is `0.2` and Divine/Secret are `0` in
  the canonical table, so Divine and Secret never appear in the normal
  roll.

---

## 5. Decide about the legacy rarity shim

`ReplicatedStorage/Config/RarityConfig.lua` is a **deprecated shim**. It
has the same table names as the canonical module but **different
values** (different `SpawnWeight` table, and a near-black `Secret`
colour). Nothing in new code reads it.

Pick one:

- **Recommended:** delete it. If some other module still requires it,
  make it a straight re-export of the canonical table:
  ```lua
  return require(script.Parent.Creatures.Rarity)
  ```
- **Keep it as-is:** only if you have audited every reader and accept
  the risk of two different rarity tables in one place.

Also: `Rarity.lua`'s header comment claims the `Rarity` enum is
re-exported from it. It is not — there is no `RarityDefs.Rarity` field.
Require `ReplicatedStorage.Types.RarityType` where you need the enum.

---

## 6. Author Studio assets

**None required.** This system creates no instances and references no
templates.

If you also install the **EggsAndHatching** and **Animals** systems, you
will need their overhead GUI templates (which carry the mutation icon
prototype) — see those systems' `Setup.md`.

---

## 7. Smoke-test it

The fastest check is a server-side script. Put this in a temporary
`ServerScriptService` script and run it in Play:

```lua
local TraitService = require(game:GetService('ServerScriptService').TraitService)
local MutationService = require(game:GetService('ServerScriptService').MutationService)

-- 1. The roll seam is deterministic with an override.
--    0.0 is inside Gold's band (Chance 10 -> cursor 0.10).
print('roll 0.0  ->', TraitService.RollTrait(0.0))      -- expect Gold
print('roll 0.99 ->', TraitService.RollTrait(0.99))     -- expect nil (past 0.15)

-- 2. A forced valid trait wins 100% with no roll.
local r = TraitService.ResolveInheritance('Rainbow', {'Frost', 'Galactic'}, 0.0)
print('forced ->', r.Trait, table.concat(r.Mutations, ','))
-- expect Rainbow  Frost,Galactic  (sorted!)

-- 3. An invalid forced trait warns and falls back to a roll.
local r2 = TraitService.ResolveInheritance('NotATrait', {}, 0.0)
print('invalid ->', r2.Trait)  -- expect Gold

-- 4. The folds.
print('gen fold ->', MutationService.GetGenerationMultiplier({'Galactic', 'Frost'}))
-- expect 7.5  (3 * 2.5)
print('sell fold ->', MutationService.GetSellMultiplier({'Galactic', 'Frost'}))
-- expect '5'  (2.5 * 2, exact decimal string)

-- 5. The admin parser.
print('parse ->', MutationService.ParseListInput('["Galactic", "Frost"]'))
-- expect true  Frost,Galactic
print('parse dup ->', MutationService.ParseListInput('Galactic,Galactic'))
-- expect false  Duplicate mutation: "Galactic"
```

**Pass criteria:** all six print the expected values, and the console
shows no red require-time error (a bad catalog would have failed the
server at boot, before any of this ran).

### Run the specs

`Tests/TraitMutation.spec.lua` is the real test. It requires **Roblox
Studio** — there is no headless Luau runner in this project.

1. Open the place in Studio.
2. Make sure the spec file is at `ServerScriptService/Tests/` (or
   wherever your `test.project.json` mounts it) and that
   `ReusableSystems/Tests/_Helpers.lua` and `TestRunner.server.lua` are
   present.
3. Run the `TestRunner.server.lua` script in Play mode.
4. The TestEZ output window lists each spec and its result.

The spec asserts, among other things, that the sell fold returns `'5'`
(not `5.0` and not `5`), that `ResolveInheritance` copies rather than
aliases the mutation list, and that
`BigNumber.MultiplyDecimal` throws on `'1.2345678'`.

---

## 8. Optional: make it observable in game

This system on its own does nothing visible. To see traits and mutations
in a running game you also need:

- **EggsAndHatching** — `EggService.HatchEgg` calls
  `TraitService.ResolveInheritance` and stores the result on the animal.
- **Animals** — `AnimalService.CreateFromEgg` applies
  `options.ResolvedTrait` / `options.ResolvedMutations`; `AnimalStats`
  folds them into the income stat; `AnimalOverhead` renders the trait
  and mutation names above the animal.
- **Economy** — the sell path folds the sell multipliers into the sale
  price.
- **PlayerData** — `PersistenceAudit` cleans legacy rows and
  `PlayerService` persists the two fields.

Copy those systems in as well, or call `TraitService` /
`MutationService` yourself from your own egg-open code.
