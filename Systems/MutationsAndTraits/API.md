# MutationsAndTraits — API

Every public function of every module in this system. See
[README.md](README.md) for the overview, [MEMORY.md](MEMORY.md) for the
behavioural notes, and [Dependencies.md](Dependencies.md) for the
require paths.

**Failure-mode policy for this system, in one line:** nothing here
**throws** at call time. The only `error()` calls are the require-time
`validate()` functions inside the two config modules. The service layer
never throws, never `assert`s, and never `pcall`s.

---

## `ServerScriptService.TraitService`

Stateless. Server-only. Frozen at return.

### `TraitService.Init()`

Initialises the service. **No-op** — the service holds no state.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none. It cannot fail.

---

### `TraitService.IsValidTrait(traitId: any): boolean`

Is this a real trait id?

- **Parameters:** `traitId` — the candidate id. Any type is accepted.
- **Returns:** `true` if `traitId` is a non-empty string that exists in
  `Traits.Catalog`; `false` otherwise.
- **Failure modes:** never throws. `nil` → `false`. `''` → `false`. A
  non-string → `false`. An unknown string → `false` (unknown ids are
  *data*, not a crash).
- **Note:** `nil` is valid **data** (it means "no trait") but is not a
  valid **id**. Callers distinguish "absent" from "bogus" by context,
  not by this function.

---

### `TraitService.RollTrait(rollOverride: number?): string?`

The authoritative server-side trait roll.

- **Parameters:** `rollOverride` — optional. A number in `[0, 1)` used
  **instead of** `math.random()`. This is the documented test seam;
  production passes `nil`.
- **Returns:** a trait id from `Traits.RollOrder`, or `nil` when the roll
  lands in the implicit no-trait band (the remainder of 100% not
  consumed by any `Chance`).
- **Failure modes:** never throws.
  - If `rollOverride` is not a number, is NaN, is `< 0`, or is `>= 1`,
    it is **ignored** and `math.random()` is used. (`1.0` and `-0.1` are
    both rejected.)
  - Returns `nil` past the last band — this is normal, not an error.
- **Behaviour:** walks `Traits.RollOrder` **in array order** (never
  `pairs()`), advancing a cumulative cursor by `entry.Chance / 100`.
  The first id where `roll < cursor` wins. A trait with `Chance == 0` is
  skipped entirely and does not shift the other bands.
- **Side effects:** `Debug.Log('TR', 'trait rolled', { trait, roll })` on
  a hit.

---

### `TraitService.GetGenerationMultiplier(traitId: string?): number`

The float multiplier for generation (income) math.

- **Parameters:** `traitId` — the trait id, or `nil` for none.
- **Returns:** the trait's `GenerationMultiplier` as a number. `nil` →
  `1`. An unknown id → `1`.
- **Failure modes:** never throws. On an unknown id it emits **one**
  warn-once per id per session
  (`Debug.Warn('TR', 'unknown trait in generation fold; degrading to 1x')`).
- **Note:** delegates to `Traits.GenerationMultiplierFor`. Do not
  reimplement the nil/unknown policy elsewhere.

---

### `TraitService.GetSellMultiplier(traitId: string?): string`

The exact decimal-string multiplier for BigNumber sell math.

- **Parameters:** `traitId` — the trait id, or `nil` for none.
- **Returns:** the trait's `SellMultiplier` **as a string** (`'3'`,
  `'1.2'`, ...). `nil` → `'1'`. An unknown id → `'1'`.
- **Failure modes:** never throws. On an unknown id it emits one
  warn-once per id per session
  (`Debug.Warn('TR', 'unknown trait in sell fold; degrading to 1x')`).
- **Note:** the return type is a **string**, not a number. This is
  deliberate — sell math must be exact.

---

### `TraitService.ResolveInheritance(blockTrait: string?, blockMutations: any, rollOverride: number?): { Trait: string?, Mutations: { string } }`

Resolves an egg opening into the animal's inheritance. **The single
hatch-inheritance decision point.**

- **Parameters:**
  - `blockTrait` — the egg's forced trait id, or `nil`.
  - `blockMutations` — the egg's mutation list (any shape; sanitised).
  - `rollOverride` — optional `[0, 1)` test seam, forwarded to
    `RollTrait`. **Only used on the roll paths** — a forced valid trait
    ignores it entirely.
- **Returns:** a fresh table `{ Trait = string?, Mutations = { string } }`.
  `Mutations` is a **new, sorted, de-duplicated** array; the egg's own
  table is never aliased and never reordered in place.
- **Failure modes:** never throws.
  - `blockTrait` is a **valid** id → used 100%, **no roll performed**.
  - `blockTrait` is a non-empty but **invalid** id →
    `Debug.Warn('TR', 'invalid hidden egg Trait; rolling instead')`,
    then a roll. The egg is **not** destroyed; only the bogus payload
    is ignored.
  - `blockTrait` is `nil` or `''` → a roll.
  - `blockMutations` is not a table → treated as an empty list.
- **Side effects:** `Debug.Log` calls for `'forced trait inherited'`,
  `'opening trait resolved'`, and `'mutations inherited'`.

---

## `ServerScriptService.MutationService`

Stateless. Server-only. Frozen at return.

### `MutationService.Init()`

Initialises the service. **No-op** — the service holds no state.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.

---

### `MutationService.IsValidMutation(mutationId: any): boolean`

Is this a real mutation id?

- **Parameters:** `mutationId` — the candidate id. Any type is accepted.
- **Returns:** `true` if `mutationId` is a non-empty string that exists
  in `Mutations.Catalog`; `false` otherwise.
- **Failure modes:** never throws. `nil` → `false`. `''` → `false`. A
  non-string → `false`. An unknown string → `false`.

---

### `MutationService.SanitizeList(list: any): { string }`

Canonicalises any mutation-list-shaped value.

- **Parameters:** `list` — any value.
- **Returns:** a **fresh** array of unique, valid, non-empty mutation
  ids, **sorted**. A non-table input → `{}`.
- **Failure modes:** never throws. Unknown ids and duplicates are
  **silently dropped** (not an error at this layer — the strict
  duplicate check lives in `ParseListInput`). The input table is never
  mutated.
- **Note:** delegates to `Mutations.SanitizeIds`.

---

### `MutationService.GetGenerationMultiplier(list: any): number`

The multiplicative float fold for generation (income) math.

- **Parameters:** `list` — a mutation list (any shape).
- **Returns:** the product of every sanitized id's
  `GenerationMultiplier`. An empty list → `1`. If the product ends up
  NaN, infinite, or `<= 0` → `1`.
- **Failure modes:** never throws. An id whose multiplier is missing or
  invalid is **skipped** (not treated as 1x) with one warn-once per id
  per session
  (`Debug.Warn('MU', 'unknown mutation in generation fold; skipping')`).
- **Note:** delegates to `Mutations.GenerationFold`.

---

### `MutationService.GetSellMultiplier(list: any): string`

The multiplicative fold for sell math, **exact**.

- **Parameters:** `list` — a mutation list (any shape).
- **Returns:** a decimal **string** — the product of every sanitized
  id's `SellMultiplier`, folded with `BigNumber.MultiplyDecimal` so it
  is exact (no float dust). An empty list → `'1'`.
- **Failure modes:** never throws. `BigNumber.MultiplyDecimal` is
  `pcall`-ed; if it fails (for example because the running product
  exceeds BigNumber's magnitude ceiling) or returns a non-string, that
  id is **skipped** with one warn-once per id per session
  (`Debug.Warn('MU', 'unknown mutation in sell fold; skipping')`). The
  fold returns the partial product of the ids that did succeed.
- **Note:** delegates to `Mutations.SellFold`.

---

### `MutationService.ParseListInput(input: any): (boolean, any)`

Parses admin-command mutation text into a list of ids.

- **Parameters:** `input` — the raw text (or `nil`).
- **Returns:** `(true, list)` on success or `(false, error)` on
  failure. The list is **sorted** and unique.
- **Failure modes:** never throws. Exact results:

  | Input | Result |
  |---|---|
  | `nil` | `(true, {})` |
  | any non-string | `(false, 'invalid-mutations')` |
  | `''`, `'-'`, `'none'` (any case), `'[]'` | `(true, {})` |
  | `'Galactic,Frost'` | `(true, {'Frost', 'Galactic'})` |
  | `'["Galactic", "Frost"]'` | `(true, {'Frost', 'Galactic'})` |
  | `'Galactic Frost'` | `(true, {'Frost', 'Galactic'})` |
  | `'Foo'` (unknown id) | `(false, 'Invalid mutation: "Foo"')` |
  | `'Galactic,Galactic'` | `(false, 'Duplicate mutation: "Galactic"')` |

  Note the **mixed casing**: the non-string case returns the lowercase
  code `'invalid-mutations'`, while the id cases return capitalised
  English with the offending id in double quotes. The spec asserts on
  these exact strings.

---

## `ReplicatedStorage.Config.Creatures.Traits`

Shared (client + server). Frozen at return. `Traits.Catalog` is frozen
separately.

### `Traits.Catalog`

The trait catalog. Shape:

```lua
{
    [traitId] = {
        Chance = 10,                  -- number, 0..100
        GenerationMultiplier = '3',   -- decimal string
        SellMultiplier = '1.2',       -- decimal string
    }
}
```

Shipped contents: `Gold` (10 / `'3'` / `'1.2'`), `Diamond` (4 / `'5'` /
`'1.5'`), `Rainbow` (1 / `'10'` / `'2'`).

**Read-only at runtime** (the table is frozen). Rebalance by editing the
source.

### `Traits.RollOrder`

`{ 'Gold', 'Diamond', 'Rainbow' }` — the deterministic roll order.

**Read-only at runtime.** Every id must exist in `Catalog`, every
`Catalog` entry must appear here, and no duplicates. A violation is a
**require-time error**.

### `Traits.Get(traitId: string): any?`

The canonical definition.

- **Parameters:** `traitId` — the id.
- **Returns:** the catalog entry table, or `nil` if the id is not a
  string or is unknown.
- **Failure modes:** never throws.

### `Traits.GenerationMultiplierFor(traitId: string?): number`

The float multiplier. The single source of truth for trait generation
math — `TraitService.GetGenerationMultiplier` is a delegate.

- **Parameters:** `traitId` — the id, or `nil`.
- **Returns:** the multiplier as a number. `nil` → `1` (no warning). An
  unknown id → `1` plus one warn-once per id per session.
- **Failure modes:** never throws.

### `Traits.SellMultiplierFor(traitId: string?): string`

The exact decimal-string multiplier. The single source of truth for
trait sell math — `TraitService.GetSellMultiplier` is a delegate.

- **Parameters:** `traitId` — the id, or `nil`.
- **Returns:** the multiplier as a **string**. `nil` → `'1'` (no
  warning). An unknown id → `'1'` plus one warn-once per id per
  session.
- **Failure modes:** never throws.

---

## `ReplicatedStorage.Config.Creatures.Mutations`

Shared (client + server). Frozen at return. `Mutations.Catalog` is
frozen separately.

### `Mutations.Catalog`

The mutation catalog. Shape:

```lua
{
    [mutationId] = {
        GenerationMultiplier = '3',   -- decimal string
        SellMultiplier = '2.5',       -- decimal string
    }
}
```

Shipped contents: `Galactic` (`'3'` / `'2.5'`), `Frost` (`'2.5'` /
`'2'`). There is **no `Chance`** — mutation eligibility is event-driven
and owned by the event system, not here.

**Read-only at runtime.** Rebalance by editing the source.

### `Mutations.Get(mutationId: string): any?`

The canonical definition.

- **Parameters:** `mutationId` — the id.
- **Returns:** the catalog entry table, or `nil` if the id is not a
  string or is unknown.
- **Failure modes:** never throws.

### `Mutations.SanitizeIds(list: any): { string }`

Canonicalises any mutation-list-shaped value.

- **Parameters:** `list` — any value.
- **Returns:** a **fresh** array of unique, valid, non-empty ids,
  **sorted**. A non-table input → `{}`.
- **Failure modes:** never throws. Unknown ids and duplicates are
  silently dropped. The input table is never mutated.
- **Note:** `MutationService.SanitizeList` is a delegate to this.

### `Mutations.GenerationFold(list: any): number`

The multiplicative float fold.

- **Parameters:** `list` — any value.
- **Returns:** the product of the sanitized ids' generation multipliers.
  Empty → `1`. NaN / infinite / `<= 0` result → `1`.
- **Failure modes:** never throws. An id with a bad multiplier is
  **skipped** with one warn-once per id per session
  (`Debug.Warn('MU', 'unknown mutation in generation fold; skipping')`).

### `Mutations.SellFold(list: any): string`

The exact multiplicative sell fold.

- **Parameters:** `list` — any value.
- **Returns:** a decimal **string**. Empty → `'1'`.
- **Failure modes:** never throws. `BigNumber.MultiplyDecimal` is
  `pcall`-ed; a failure (e.g. the running product exceeding BigNumber's
  magnitude ceiling) skips that id with one warn-once per id per
  session (`Debug.Warn('MU', 'unknown mutation in sell fold; skipping')`)
  and returns the partial product.

---

## `ReplicatedStorage.Config.Creatures.Rarity`

Shared (client + server). Frozen at return. **No `Validate()`** and no
require-time validation — a malformed table fails silently at use.

### `RarityDefs.Order`

`{ 'Common', 'Uncommon', 'Rare', 'Epic', 'Mythic', 'Legendary',
'Divine', 'Secret' }` — the display order.

**This is not a power ordering.** Mythic sits at index 4 and Legendary
at index 5. Do not compare rarity strength by index.

### `RarityDefs.RarityColor`

`[rarity] -> Color3`. `Common` and `Secret` are both
`Color3.fromRGB(255, 255, 255)`.

### `RarityDefs.RarityDisplayName`

`[rarity] -> string`, e.g. `Common -> 'Common Egg'`. Used as the egg
`Model.Name` at spawn time.

### `RarityDefs.SpawnWeight`

`[rarity] -> number` — the weights for **which rarity a centre egg
spawns as**. The hatch roll uses a separate, far more granular table
(`EggConfig.HatchRollWeights`).

Shipped: `Common 38`, `Uncommon 27`, `Rare 19`, `Epic 13.8`,
`Legendary 2`, `Mythic 0.2`, `Divine 0`, `Secret 0`. Divine and Secret
never appear in the normal roll.

### `RarityDefs.LuckExponentDivisor`

`3` — the shape of the server luck curve. The normal-roll weight
multiplier for a pool tier is `luck^(tierIndex / LuckExponentDivisor)`,
with the tier index following the design pool order `Common(0)` …
`Mythic(5)`. `luck = 1` is the identity.

### `RarityDefs.BaseLevel`

`[rarity] -> number` — the base level an animal of that rarity starts
at (`Common 1` … `Secret 8`). Purely cosmetic in this phase.

### Not exported

`RarityDefs.Rarity` **does not exist**, despite the module header
claiming the enum is re-exported. Require
`ReplicatedStorage.Types.RarityType` for the enum.

---

## `ReplicatedStorage.Config.RarityConfig` (legacy shim)

Deprecated. Same table names as the canonical rarity module but
**different values**: a different `SpawnWeight` table (Common 35,
Uncommon 25, Rare 18, Epic 12, Mythic 6, Legendary 3, Divine 0.8,
Secret 0.2) and a near-black `Secret` colour
(`Color3.fromRGB(1, 1, 1)`).

It exports `Order`, `RarityColor`, `RarityDisplayName`, `SpawnWeight`
and `BaseLevel`. It has **no `LuckExponentDivisor`**.

**Do not use it in new code.** Delete it, or replace its body with
`return require(script.Parent.Creatures.Rarity)`.
