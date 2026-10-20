# MutationsAndTraits — Dependencies

Exact module paths, cross-system requirements, remotes, profile fields,
and Studio assets. See [README.md](README.md) for the overview and
[API.md](API.md) for signatures.

---

## Module Requires

Verbatim from the source. The `script.Parent...` forms are relative to
each file's own Roblox location.

### `ServerScriptService.TraitService`

```lua
local TraitConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Traits)
local MutationService = require(script.Parent.MutationService)
local Debug = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService.MutationService`

```lua
local MutationConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)
```

### `ReplicatedStorage.Config.Creatures.Traits`

```lua
local Debug = require(script.Parent.Parent.Parent.Utility.Debug)
```

### `ReplicatedStorage.Config.Creatures.Mutations`

```lua
local BigNumber = require(script.Parent.Parent.Parent.Utility.BigNumber)
local Debug = require(script.Parent.Parent.Parent.Utility.Debug)
```

### `ReplicatedStorage.Config.Creatures.Rarity`

```lua
local Rarity = require(script.Parent.Parent.Parent.Types.RarityType)
```

### `ReplicatedStorage.Config.RarityConfig` (legacy shim)

```lua
local Rarity = require(script.Parent.Parent.Types.RarityType)
```

### Resolved absolute paths

| Module | Absolute Roblox path | From library |
|---|---|---|
| `TraitConfig` | `ReplicatedStorage.Config.Creatures.Traits` | `Source/ReplicatedStorage/Config/Creatures/Traits.lua` |
| `MutationConfig` | `ReplicatedStorage.Config.Creatures.Mutations` | `Source/ReplicatedStorage/Config/Creatures/Mutations.lua` |
| `RarityDefs` | `ReplicatedStorage.Config.Creatures.Rarity` | `Source/ReplicatedStorage/Config/Creatures/Rarity.lua` |
| `RarityConfig` (legacy) | `ReplicatedStorage.Config.RarityConfig` | `Source/ReplicatedStorage/Config/RarityConfig.lua` |
| `Debug` | `ReplicatedStorage.Utility.Debug` | `Shared/Utilities/Debug.lua` |
| `BigNumber` | `ReplicatedStorage.Utility.BigNumber` | `Shared/Utilities/BigNumber.lua` |
| `RarityType` | `ReplicatedStorage.Types.RarityType` | `Shared/Types/RarityType.lua` |
| `MutationService` | `ServerScriptService.MutationService` | `Source/ServerScriptService/MutationService.lua` |
| `TraitService` | `ServerScriptService.TraitService` | `Source/ServerScriptService/TraitService.lua` |

**`Shared/CommonModules/*` and `Shared/Utilities/*` both map to
`ReplicatedStorage.Utility.*`.** `Shared/Types/*` maps to
`ReplicatedStorage.Types.*`.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **(this system)** `Shared/Utilities/Debug.lua` | The warn-once channel for unknown trait/mutation ids, and the `Debug.Log`/`Warn` calls in `TraitService`. | **Required** — `Traits.lua` and `Mutations.lua` both require it at load time. |
| **(this system)** `Shared/Utilities/BigNumber.lua` | `Mutations.SellFold` calls `BigNumber.MultiplyDecimal` for the exact sell multiplier. | **Required** — `Mutations.lua` requires it at load time. |
| **(this system)** `Shared/Types/RarityType.lua` | The `Rarity` enum used as the key set of the rarity table. | **Required** by `Config/Creatures/Rarity.lua` and `Config/RarityConfig.lua`. |
| **EggsAndHatching** | Owns `EggService.HatchEgg`, which calls `TraitService.ResolveInheritance` once per hatch. Also owns `Egg.GuaranteeService` (rarity guarantee timers) and `Egg.RareEggNotifier` (rarity-gated toasts). | **Required for the trait to be observable in game**; the modules themselves load without it. |
| **Animals** | Owns `AnimalService.CreateFromEgg`, which writes the resolved `Trait`/`Mutations` onto the new animal, and `AnimalStats.Calculate`, which folds them into income. | **Required for the effects to be visible**; the modules themselves load without it. |
| **Economy** | The sell path folds `TraitService.GetSellMultiplier` and `MutationService.GetSellMultiplier` into the sale price. | **Required for sell value to be correct**; the modules load without it. |
| **PlayerData** | `PersistenceAudit` cleans legacy rows (drops invalid traits and duplicate/invalid mutations) and `PlayerService` persists the two fields. | **Required for persistence correctness**; the modules load without it. |

**The dependency graph between the modules in this system is a single
edge:** `TraitService -> MutationService`. There is no cycle.

---

## Remotes

**None.** This system never fires or listens to a remote.

The *effects* of a trait or mutation reach the client through other
systems' channels:

| Remote | Direction | Payload | Fired by |
|---|---|---|---|
| `PlayerState` | S->C | The full player snapshot, which includes the owned animals and their trait/mutation fields. | `PlayerService.PushState` |
| `AnimalLeveledUp` | S->C | `{ AnimalId, SlotId, OldLevel, NewLevel, LevelsGained }` — no trait fields, but a level-up recomputes income. | `AnimalService` / the upgrade path |
| `CashCollected` | S->C | The collected amount, already trait/mutation-multiplied. | The economy/income system |
| `Notify` | S->C | Notification payloads. `RareEgg_Spawned` is rarity-gated (see `Egg.RareEggNotifier`). | `NotificationService` |

---

## Profile Fields

This system **owns no profile fields**. It reads two fields that
`PlayerData` owns.

| Field | Type | Read by | Written by |
|---|---|---|---|
| `Trait` (runtime) / `trait` (persisted row) | `string?` | `TraitService.IsValidTrait`, `TraitService.Get*Multiplier`, `AnimalStats.Calculate`, `PersistenceAudit` | `AnimalService.CreateFromEgg` (at hatch), `PlayerService` (persistence) |
| `Mutations` (runtime) / `mutations` (persisted row) | `{ string }` | `MutationService.SanitizeList`, `AnimalStats.Calculate`, `PersistenceAudit` | `AnimalService.CreateFromEgg` (at hatch), `PlayerService` (persistence) |

`AnimalStats.Calculate` reads **both** spellings (`Trait` and `trait`,
`Mutations` and `mutations`) so that a runtime record and a persisted row
resolve identically.

`PersistenceAudit` (owned by **PlayerData**) is the enforcement point for
the invariants:

- A legacy row with no trait field **defaults silently** (no warning).
- A row whose trait id is not in the catalog has the trait **cleared**
  (set to `nil`).
- A row with duplicate or unknown mutation ids has those ids **dropped**.
- An egg's **pending** trait survives the clean (an egg can carry a
  forced trait that the animal inherits at open time).

---

## Required Studio Assets

**None.** This system creates no instances, references no templates, and
reads no `ServerStorage` assets.

The only instance-adjacent concern is that the trait/mutation
**overhead GUI** icons live in neighbouring systems:
`ServerStorage.Assets.OverheadGui.EggOverheadGuiTemplate` (for eggs) and
`ServerStorage.Assets.OverheadGui.AnimalOverheadGuiTemplate` (for
animals) both carry a `Mutation1` prototype that is cloned per mutation
id and painted by `ServerScriptService.Utility.MutationIcon.PaintIcon`.
Those templates belong to the **EggsAndHatching** and **Animals**
systems respectively — see their `Dependencies.md`.

---

## External APIs

**None.** No HTTP, no webhooks, no Marketplace, no DataStore. The system
is entirely in-process.

---

## Initialization Order

```text
1. ReplicatedStorage.Utility.Debug          -- no dependencies of its own
2. ReplicatedStorage.Utility.BigNumber      -- no dependencies of its own
3. ReplicatedStorage.Types.RarityType       -- pure data
4. ReplicatedStorage.Config.Creatures.Rarity -- requires RarityType
5. ReplicatedStorage.Config.Creatures.Traits -- requires Debug; runs validate() at require time
6. ReplicatedStorage.Config.Creatures.Mutations -- requires BigNumber + Debug; runs validate() at require time
7. ServerScriptService.MutationService      -- requires Mutations
8. ServerScriptService.TraitService         -- requires Traits + MutationService
```

Then call, in your bootstrap:

```lua
local TraitService = require(script.Parent.TraitService)
local MutationService = require(script.Parent.MutationService)

TraitService.Init()      -- no-op
MutationService.Init()   -- no-op
```

Both `Init()` calls are **no-ops** — the services are stateless. They
exist for symmetry with the other services in the codebase and are safe
to skip.

**There is no ordering constraint beyond "the config modules must be
requirable".** `TraitService` requires `MutationService` at load time, so
`MutationService` must be requirable first; the `require` chain handles
that automatically as long as the files are at the documented paths.

**Require-time failure is the intended failure mode.** `Traits.validate()`
and `Mutations.validate()` call `error(..., 0)` at the bottom of the
module body. A malformed catalog breaks the boot immediately and
loudly, with a `[Traits]` or `[Mutations]` prefixed message — it does not
degrade to a silent 1x.

---

## Third-Party Packages

**None.** This system uses no Wally packages. `BigNumber` and `Debug`
are first-party modules in `ReusableSystems/Shared/Utilities/`.
