# MutationsAndTraits

Owns the two intrinsic "affix" systems on top of an owned object — a
**Trait** (at most one, rolled or forced) and **Mutations** (zero or more) —
plus the rarity tier table that both the egg and animal worlds read.

**Portability:** Grade A core (the trait roll, the mutation list/fold
algebra, the rarity table shape) + Grade B (the trait/mutation catalogs
themselves — Gold/Diamond/Rainbow and Galactic/Frost are Brainrot Arena
content).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

This system is three parts:

1. **`TraitService`** — rolls exactly zero or one trait, and resolves the
   trait + mutation pair that an egg hands to its animal at hatch time.
2. **`MutationService`** — validates, sanitizes and folds lists of mutation
   ids into generation and sell multipliers.
3. **`Config/Creatures/Rarity.lua`** — the canonical rarity tier table
   (order, colours, display names, spawn weights, luck curve, base levels).

The two services are **stateless pure functions over data**. They hold no
player state, own no instances, and talk to no remotes. All the actual
arithmetic lives in the config modules (`Traits.lua`, `Mutations.lua`), so
shared clients (e.g. `AnimalStats` on the client) can fold the same
multipliers without requiring a server module.

The rule the whole system rests on: **multipliers commute and there is no
ordering significance**, so every fold sorts and de-duplicates its id list
first. Insertion order can never change a result.

The second rule: **a trait is `nil` when there is none** — never the string
`'None'`. `nil` is the only representation of "no trait", everywhere.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `TraitService.Init()` | Server | No-op. The service is stateless. |
| `TraitService.RollTrait(rollOverride: number?): string?` | Server | Rolls one trait id, or `nil` for no trait. `rollOverride` is the test seam (a `[0,1)` value replaces `math.random()`). |
| `TraitService.IsValidTrait(traitId: any): boolean` | Server | `nil` → `false`. A non-nil unknown id → `false` (data problem, not a crash). |
| `TraitService.GetGenerationMultiplier(traitId: string?): number` | Server | Float multiplier for income math. `nil` → `1`. |
| `TraitService.GetSellMultiplier(traitId: string?): string` | Server | Exact decimal-string multiplier for BigNumber sell math. `nil` → `'1'`. |
| `TraitService.ResolveInheritance(blockTrait: string?, blockMutations: any, rollOverride: number?): { Trait: string?, Mutations: { string } }` | Server | The single hatch-inheritance decision. A valid forced trait is used 100% with **no roll**; an invalid forced trait warns and falls back to a roll; `nil` rolls. |
| `MutationService.Init()` | Server | No-op. The service is stateless. |
| `MutationService.IsValidMutation(mutationId: any): boolean` | Server | Type check + catalog lookup. |
| `MutationService.SanitizeList(list: any): { string }` | Server | Fresh sorted array of unique, valid, non-empty ids. Non-table input → `{}`. |
| `MutationService.GetGenerationMultiplier(list: any): number` | Server | Multiplicative fold over the sanitized list. Empty → `1`. |
| `MutationService.GetSellMultiplier(list: any): string` | Server | Exact BigNumber fold. Empty → `'1'`. |
| `MutationService.ParseListInput(input: any): (boolean, any)` | Server | Parses a user-typed list (`"Galactic, Frost"`). Returns `(ok, list)` or `(false, errorMessage)`. |
| `Traits.Get(traitId: string): any?` | Shared | The canonical catalog entry, or `nil`. |
| `Traits.GenerationMultiplierFor(traitId: string?): number` | Shared | Float multiplier. `nil` → `1`; unknown → `1` + a warn-once. |
| `Traits.SellMultiplierFor(traitId: string?): string` | Shared | Decimal-string multiplier. `nil` → `'1'`; unknown → `'1'` + a warn-once. |
| `Mutations.Get(mutationId: string): any?` | Shared | The canonical catalog entry, or `nil`. |
| `Mutations.SanitizeIds(list: any): { string }` | Shared | Fresh sorted array of unique valid ids. |
| `Mutations.GenerationFold(list: any): number` | Shared | Multiplicative float fold. Empty → `1`. |
| `Mutations.SellFold(list: any): string` | Shared | Exact BigNumber fold. Empty → `'1'`. |
| `RarityDefs.Order` / `.RarityColor` / `.RarityDisplayName` / `.SpawnWeight` / `.BaseLevel` / `.LuckExponentDivisor` | Shared | The rarity table (see [Config.lua](Config.lua)). |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/TraitService.lua` | `ServerScriptService.TraitService` | Trait rolling + hatch inheritance resolution. |
| `Source/ServerScriptService/MutationService.lua` | `ServerScriptService.MutationService` | Mutation validation, sanitizing and folding (server facade). |
| `Source/ReplicatedStorage/Config/Creatures/Traits.lua` | `ReplicatedStorage.Config.Creatures.Traits` | The trait catalog + the canonical multiplier folds. |
| `Source/ReplicatedStorage/Config/Creatures/Mutations.lua` | `ReplicatedStorage.Config.Creatures.Mutations` | The mutation catalog + the canonical list/multiplier folds. |
| `Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | `ReplicatedStorage.Config.Creatures.Rarity` | **Canonical** rarity tier table. |
| `Source/ReplicatedStorage/Config/RarityConfig.lua` | `ReplicatedStorage.Config.RarityConfig` | **Legacy shim** — see [Known Limitations](#known-limitations). |

---

## Configuration

This system owns its config outright. See **[Config.lua](Config.lua)** for the
consolidated, fully-commented tunables — the trait catalog, the mutation
catalog, the rarity table, and the rarity-guarantee hooks that live in
neighbouring systems.

The short version:

| Group | Module | Nature |
|---|---|---|
| Trait catalog | `Config/Creatures/Traits.lua` | `Catalog` (3 entries) + `RollOrder` + the multiplier folds. |
| Mutation catalog | `Config/Creatures/Mutations.lua` | `Catalog` (2 entries) + the list/fold functions. |
| Rarity table | `Config/Creatures/Rarity.lua` | Order, colours, display names, spawn weights, luck curve, base levels. |

**Multipliers are decimal STRINGS, not Lua numbers.** `'3'`, `'1.5'`, `'2.5'`.
Sell math is BigNumber-exact and a float would corrupt it (`1.1 * 2.5` is
`2.7500000000000004`). The generation path converts with `tonumber` because
rates are floats anyway.

**Chances are percent NUMBERS** (`0..100`). Floats are fine — chances only
partition a roll and never touch currency.

---

## Dependencies

See **[Dependencies.md](Dependencies.md)** for the exact require paths, the
remotes, and the profile fields.

Load-bearing:

- `ReplicatedStorage.Config.Creatures.Traits` — the trait catalog.
- `ReplicatedStorage.Config.Creatures.Mutations` — the mutation catalog.
- `ReplicatedStorage.Types.RarityType` — the `Rarity` enum.
- `ReplicatedStorage.Utility.BigNumber` — exact decimal multiplication.
- `ReplicatedStorage.Utility.Debug` — the warn-once channel.

**No remotes.** The system is entirely server-side and local; it never talks
to a client. The *effects* of a trait or mutation (income, sell value) travel
over other systems' channels.

**Profile fields read:** `Trait` (string or `nil`) and `Mutations` (array of
strings) on an animal/egg record. These are owned by `PlayerData` /
`PersistenceAudit`, not by this system.

---

## Initialization Order

```text
1. ReplicatedStorage.Config.Creatures.Rarity     -- pure data, no deps
2. ReplicatedStorage.Config.Creatures.Traits     -- requires Debug
3. ReplicatedStorage.Config.Creatures.Mutations  -- requires BigNumber + Debug
4. ServerScriptService.TraitService.Init()       -- no-op, but call it
5. ServerScriptService.MutationService.Init()    -- no-op, but call it
```

Both services are **stateless**, so there is no ordering constraint beyond
"the config modules must be requirable". The `Init()` calls exist for
symmetry with the other services and are safe to skip.

`TraitService` requires `MutationService` (one direction only), so
`MutationService` must be requirable first. There is no cycle.

---

## Data

Nothing in this system persists anything itself. The two fields it owns
conceptually are:

| Field | Type | Where it lives | Meaning |
|---|---|---|---|
| `Trait` | `string?` | On the animal/egg record, persisted in the profile | The trait id, or `nil` for none. Exactly zero or one. |
| `Mutations` | `{ string }` | On the animal/egg record, persisted in the profile | Zero or more mutation ids, unique, sorted. |

**Case convention.** The runtime record uses `Trait` / `Mutations`; the
persisted row may use `trait` / `mutations`. `AnimalStats.Calculate` reads
both spellings. `MutationConfig.SanitizeIds` does not care about case — it
is a catalog lookup on the exact id.

**Trait lifecycle.** Rolled at egg open time (or forced 100% by a hidden
preassigned egg trait), then **never changes**. An animal never gains,
loses, or rerolls a trait. There is no reroll/remove/upgrade UI in this
phase.

**Mutation lifecycle.** An egg carries N unique mutations (possibly zero).
On open, **all** of them transfer to the animal (defensive copy). Animals
never gain/lose/reroll mutations after creation.

---

## Known Limitations

- **`Config/RarityConfig.lua` is a stale shim that CONFLICTS with the
  canonical `Config/Creatures/Rarity.lua`.** Both are copied into this
  library. They agree on `Order`, `RarityColor` and `RarityDisplayName`
  but they differ in two places. **`Secret`'s colour** is
  `Color3.fromRGB(255,255,255)` (white) in the canonical table and
  `Color3.fromRGB(1,1,1)` (near-black) in the legacy shim. And their
  **`SpawnWeight` tables differ**:

  | Rarity | Canonical `Config/Creatures/Rarity.lua` | Legacy `Config/RarityConfig.lua` |
  |---|---|---|
  | Common | 38 | 35 |
  | Uncommon | 27 | 25 |
  | Rare | 19 | 18 |
  | Epic | 13.8 | 12 |
  | Mythic | 0.2 | 6 |
  | Legendary | 2 | 3 |
  | Divine | 0 | 0.8 |
  | Secret | 0 | 0.2 |

  The canonical table makes Mythic the ~0.2% chase and zeroes Divine/Secret
  (they never appear in the normal roll); the legacy table gives Mythic 6%
  and lets Divine/Secret spawn. **Only the canonical path is read by new
  code.** A new game must delete the shim, not keep both.

- **The canonical rarity module has no `Validate()`** and no require-time
  validation, unlike `Traits.lua` / `Mutations.lua`. A malformed rarity
  table fails silently at use, not at require time.

- **The header comment in `Traits.lua` is WRONG about the sell
  multipliers.** It advertises `Gold 10% x3 gen x3 sell`, `Diamond 4% x5
  gen x5 sell`, `Rainbow 1% x10 gen x10 sell`, but the actual catalog
  says:

  | Trait | Chance | GenerationMultiplier | SellMultiplier |
  |---|---|---|---|
  | Gold | 10 | `'3'` | `'1.2'` |
  | Diamond | 4 | `'5'` | `'1.5'` |
  | Rainbow | 1 | `'10'` | `'2'` |

  The **generation** multipliers match the comment; the **sell**
  multipliers do not. The catalog is the source of truth (the code
  reads `entry.SellMultiplier`, never the comment). The comment is
  stale from before the "traits are keeper value, not flip value"
  rebalance. Trust the table.

- **`Rarity.lua`'s header says the `Rarity` enum is "re-exported here so
  callers do not need to require the Types module" — it is NOT.** The
  module only does `local Rarity = require(...)` internally; there is no
  `RarityDefs.Rarity` field. Callers must require
  `ReplicatedStorage.Types.RarityType` themselves.

- **`RarityDefs.Order` is NOT sorted by power.** It is
  `Common, Uncommon, Rare, Epic, Mythic, Legendary, Divine, Secret` —
  **Mythic sits BELOW Legendary**. The source's own `RareEggNotifier`
  comments call this out and use an explicit enum set rather than an
  Order index. Do not index into `Order` to compare rarity strength.

- **`TraitService.ResolveInheritance` resolves the trait and the mutations
  together but the mutation list is not "rolled"** — it is the egg's list,
  sanitized. The function name is about *inheritance*, not about chance.

- **The `Chance` values only partition a roll.** `Traits.validate()`
  enforces `total Chance <= 100` and errors at require time if it is
  exceeded — but the remainder (100 − total) is the implicit "no trait"
  bucket and is not configurable.

- **No maximum mutation count.** There is no cap in the catalog, no cap in
  the sanitization, and no cap in the fold. A list of N valid ids multiplies
  N times. In practice only 2 exist.

- **The `MutationService.ParseListInput` splitter is permissive.** It
  splits on `[^,%s]+`, so `Galactic,Frost`, `Galactic Frost` and
  `Galactic,Frost,` all parse. It also accepts the literal `-` as "empty"
  (a common CLI convention for "none").

- **Sell multipliers for traits are deliberately modest** compared to
  generation multipliers (Rainbow is x10 income but only x2 sell). The
  reason is in the source comments: flip EV math assumes trait sell EV ≈
  1.05, and raising these invalidates every egg's hatch-and-sell EV.

---

## Testing

`Tests/TraitMutation.spec.lua` — one spec file covering both services, the
config modules, `BigNumber.MultiplyDecimal`, and the economy integration.

It covers, among other things:

- The trait roll distribution and the `rollOverride` seam.
- `ResolveInheritance` in all three modes: forced-valid (100%, **no roll
  performed**), forced-invalid (warn + roll fallback), and `nil` (roll).
- That the returned mutation list is a **defensive copy** and is sorted, and
  that the egg's own list is **never reordered in place**.
- That `BigNumber.MultiplyDecimal` **throws** on `'abc'`, `'1.2.3'`, `'0'`,
  `'-2'` and `'1.2345678'` (more than 6 significant digits).
- The economy end-to-end: a Common L1 animal at 2/s with Gold (x3) and
  Galactic (x3) earns 18/s, so the cash pool is `'180'` after 10 seconds
  (vs `'20'` untraited); offline income compounds wallet x5, offline x0.5
  and 100 seconds to `'6250'` for a Diamond (x5) / Frost (x2.5) animal.
- That a sale of 100 base value at 0.75 liquidation with Rainbow (x2),
  Galactic (x2.5) and Frost (x2) yields 750 + a 500 pool = `'1250'`, and
  that legacy 5x / 10x multipliers are **ignored** by the trait/mutation
  path.
- That `SellService.SellEgg` and `GetEggSellValue` are **`nil`** — the
  egg sell path does not exist in this phase.
- That upgrade + XP preserve `Trait` and `Mutations`.
- `PersistenceAudit` cleaning: legacy rows default silently, an invalid
  trait is cleared, duplicate/invalid mutations are dropped, and an egg's
  pending trait survives.

**They require Roblox Studio.** There is no headless Luau runner in this
project. See `../../Tests/README.md`.

> **The suite has never been executed as committed.** "1 spec file"
> means "specs exist that were written against this code", **not** "they
> were observed passing". `../../Tests/README.md` §1 documents the three
> runner defects that block execution (the `Packages.DevPackages.TestEZ`
> require path, the non-existent `TestEZ.RunBootstrap()`, and
> `AnimalXP.spec.lua` returning a table instead of a function). Treat a
> failing spec as a **question about the code**, not automatically as a
> broken test.

---

## Adapting to a New Game

1. **Copy the config, then replace the content.** `Traits.lua` and
   `Mutations.lua` are the only Brainrot Arena-specific parts. Keep the
   `Catalog` + `RollOrder` shape and the multiplier-string convention.
2. **Keep the multiplier-as-string rule.** If your sell path uses floats,
   change it to BigNumber first — the sell fold already assumes exact
   decimals and the `validate()` guard enforces it.
3. **Keep the `nil`-means-none rule for traits.** Never persist, display, or
   roll the string `'None'`.
4. **Keep the sort-then-fold rule.** Any new fold must sanitize (unique +
   valid + sorted) before multiplying, or two code paths will disagree on
   the same list.
5. **Delete `Config/RarityConfig.lua`.** It is a deprecated shim with
   conflicting spawn weights. If you keep it, make it a straight
   re-export of the canonical table.
6. **Add a `Validate()` to your rarity module** if you follow the
   `ConfigValidator` convention — the canonical one does not have one.
7. **Keep the warn-once policy.** Unknown trait/mutation ids degrade to 1x
   with a single warning, not an error. Records are audit-cleaned, so an
   unknown id means a bug worth hearing about, not a crash worth stopping
   the server for.
