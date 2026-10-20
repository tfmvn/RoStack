# MutationsAndTraits — MEMORY

Engineering notes for an agent working on this system. Dense, factual, no
filler. Read [README.md](README.md) for the overview and
[API.md](API.md) for signatures.

---

## Purpose in one line

`TraitService` + `MutationService` decide an animal's single optional
Trait and its list of Mutations, and turn them into generation (income)
and sell multipliers.

---

## How it actually works

### The split

There are **two layers**, and knowing which one to call is the single most
important thing about this system.

| Layer | Modules | Runs on |
|---|---|---|
| **Config layer** (the real logic) | `Config.Creatures.Traits`, `Config.Creatures.Mutations` | Client AND server — it is in `ReplicatedStorage`. |
| **Service layer** (thin facade) | `ServerScriptService.TraitService`, `ServerScriptService.MutationService` | Server only. |

The **service layer holds no state and contains no math**. Every function
on it is a one-line delegation to the config layer:

- `TraitService.GetGenerationMultiplier` → `TraitConfig.GenerationMultiplierFor`
- `TraitService.GetSellMultiplier` → `TraitConfig.SellMultiplierFor`
- `MutationService.SanitizeList` → `MutationConfig.SanitizeIds`
- `MutationService.GetGenerationMultiplier` → `MutationConfig.GenerationFold`
- `MutationService.GetSellMultiplier` → `MutationConfig.SellFold`
- `TraitService.IsValidTrait` → `TraitConfig.Get(id) ~= nil`
- `MutationService.IsValidMutation` → `MutationConfig.Get(id) ~= nil`

**Never reimplement a fold.** The source comments say "THE single
definition of ... resolution" on both config modules. A second
implementation is how a client and a server end up disagreeing about an
animal's income.

The only service-layer logic that is NOT a delegation is
`TraitService.RollTrait` (the roll itself) and
`TraitService.ResolveInheritance` (the hatch decision).

### The trait roll

`TraitService.RollTrait(rollOverride)`:

1. `roll = rollOverride` **only if** it is a number, not NaN
   (`rollOverride == rollOverride`), and `>= 0` and `< 1`. Otherwise
   `roll = math.random()`. This is the documented test seam.
2. Walk `TraitConfig.RollOrder` **in order** (never `pairs()` — table
   order must not affect probabilities). Maintain a cumulative cursor:
   `cursor += entry.Chance / 100`.
3. The first id where `roll < cursor` wins.
4. Past the end of the list → return `nil` (no trait).

Consequences worth internalising:

- `Chance` is a **percent number**, and the cursor is `Chance / 100`, so
  the numbers are directly comparable to a `[0,1)` roll.
- A trait with `Chance == 0` is **skipped entirely** (the code checks
  `entry.Chance > 0` before advancing the cursor) — a zero-chance trait
  is unreachable, and a `Chance == 0` trait placed early in `RollOrder`
  does not shift the other bands.
- The **remainder** `100 - sum(Chance)` is the implicit no-trait band.
  With the shipped catalog that is `100 - 15 = 85%`.
- `RollTrait` returns `nil` for no trait, and `nil` is the ONLY
  representation of no trait.

`TraitService.Init()` is a **no-op** (the service is stateless). Same for
`MutationService.Init()`.

### `ResolveInheritance` — the hatch decision

```lua
TraitService.ResolveInheritance(blockTrait, blockMutations, rollOverride)
  -> { Trait: string?, Mutations: { string } }
```

The three cases, exactly:

| `blockTrait` | Behaviour |
|---|---|
| A **valid** trait id | Used **100%**. **No roll is performed at all.** Logs `'forced trait inherited'`. |
| An **invalid but present** (non-empty string) trait id | `Debug.Warn('TR', 'invalid hidden egg Trait; rolling instead')` and then **rolls**. The egg survives; only the bogus payload is ignored. |
| `nil` or `''` | Rolls. |

Then, **independently of the trait**, the mutations are resolved:
`MutationService.SanitizeList(blockMutations)` produces a fresh sorted
unique list, and that list is then **copied again** into a brand-new
array. The egg's live table is never aliased and never reordered in
place. This is deliberate: the animal must never alias the egg's table,
and the egg may be dropped right after.

`rollOverride` is forwarded to `RollTrait` — but note it is **only used
on the roll paths**. A forced valid trait ignores it entirely.

### The mutation folds

`Mutations.SanitizeIds(list)`:

- Non-table input → `{}` (a missing field on a legacy record is normal,
  not an error).
- Keeps only `ipairs` entries that are non-empty strings, not already
  seen, AND exist in the catalog.
- `table.sort(out)` at the end — **always sorted**.
- Returns a **fresh** table. Never aliases the input.

`Mutations.GenerationFold(list)`:

- `result = 1`; for each sanitized id, `result *= tonumber(GenerationMultiplier)`.
- If a multiplier is missing/bad → `_warnUnknown(id, 'generation')` and
  **that id is skipped** (not treated as 1x — it is simply left out of
  the product).
- If the final result is NaN, infinite, or `<= 0` → returns `1`.
- **Float** math. Fine for income rates.

`Mutations.SellFold(list)`:

- `result = '1'` (a **string**); for each id,
  `pcall(BigNumber.MultiplyDecimal, result, mult)`.
- If the pcall fails or the result is not a string → `_warnUnknown(id,
  'sell')` and that id is **skipped**.
- **Exact** decimal math. Chained `MultiplyDecimal` stays exact because
  every config multiplier is a validated terminating decimal.

The skip-on-failure behaviour is not theoretical: `BigNumber.MultiplyDecimal`
enforces a magnitude ceiling, so a *product* that exceeds it throws, the
pcall catches it, and the offending id is dropped with a warning. A
config that looks individually valid can still blow the product ceiling.

`Traits.GenerationMultiplierFor` / `Traits.SellMultiplierFor` are the
trait equivalents, but they are **per-id, not per-list** (a trait is at
most one). `nil` → `1` / `'1'` with no warning. An unknown id → `1` /
`'1'` **plus a warn-once** (`_warnedUnknown[traitId]`, a module-local
table, one warning per id per session).

### `MutationService.ParseListInput` — the admin-command parser

```lua
ParseListInput(input) -> (ok: boolean, listOrError: any)
```

| Input | Result |
|---|---|
| `nil` | `(true, {})` |
| any non-string | `(false, 'invalid-mutations')` |
| `''`, `'-'`, `'none'` (case-insensitive), `'[]'` | `(true, {})` |
| `'Galactic,Frost'` | `(true, {'Frost', 'Galactic'})` — **sorted** |
| `['"Galactic"', "'Frost'"]` (brackets/quotes) | `(true, {'Frost', 'Galactic'})` |
| an unknown id | `(false, 'Invalid mutation: "Foo"')` |
| a repeated id | `(false, 'Duplicate mutation: "Galactic"')` |

Mechanics: strip `[`, `]`, `"`; trim whitespace; split on `[^,%s]+`;
validate each token in order (unknown first, then duplicate); sort the
accepted list. Note the error strings use **capitalised** English
(`'Invalid mutation: "..."'`) while the non-string case uses the
**lowercase code** `'invalid-mutations'`. The spec asserts on these exact
strings.

---

## Public API surface

Full signatures in [API.md](API.md). The names:

**`TraitService`** — `Init`, `IsValidTrait`, `RollTrait`,
`GetGenerationMultiplier`, `GetSellMultiplier`, `ResolveInheritance`.

**`MutationService`** — `Init`, `IsValidMutation`, `SanitizeList`,
`GetGenerationMultiplier`, `GetSellMultiplier`, `ParseListInput`.

**`Traits`** (config) — `Catalog`, `RollOrder`, `Get`,
`GenerationMultiplierFor`, `SellMultiplierFor`.

**`Mutations`** (config) — `Catalog`, `Get`, `SanitizeIds`,
`GenerationFold`, `SellFold`.

**`RarityDefs`** (config) — `Order`, `RarityColor`, `RarityDisplayName`,
`SpawnWeight`, `LuckExponentDivisor`, `BaseLevel`.

---

## Invariants the code enforces

1. **At most one trait.** `Trait` is `string?`, never a list.
2. **No trait is `nil`**, never `'None'`. Enforced by convention only —
   nothing validates a persisted `'None'` string; `PersistenceAudit`
   is what clears it.
3. **Multipliers are decimal strings.** Validated at require time by
   `_isValidMultiplier`: 1..12 chars, matches `^%d+%.?%d*$`, value in
   `(0, 1e6]`, **at most 6 significant digits** (after stripping the dot
   and leading zeros).
4. **`Chance` is a number in `0..100`**, and the total across
   `RollOrder` must be `<= 100`.
5. **Every `Catalog` entry must appear in `RollOrder`** and vice-versa.
   A catalog entry not in `RollOrder` is dead config and is a **require-
   time error** ("catalog entry %s missing from RollOrder").
6. **Mutation ids are unique.** Duplicates are rejected at the boundary
   (`ParseListInput`) and dropped by the sanitizer (persistence path).
7. **Folds are order-independent** because they sort + dedupe first.
8. **The mutation list is never aliased** across the egg → animal
   boundary.
9. **Require-time validation is fail-loud.** `validate()` runs at the
   bottom of both config modules and calls `error(..., 0)` — a malformed
   trait/mutation catalog breaks the server at boot, not silently later.

---

## Failure / edge-case behaviour

| Situation | Behaviour |
|---|---|
| `TraitService.IsValidTrait(nil)` | `false`. (`nil` is valid *data* but not a valid *id*.) |
| `TraitService.IsValidTrait('')` | `false`. |
| `TraitService.IsValidTrait('Gold')` | `true`. |
| `TraitService.IsValidTrait('Nope')` | `false` — data, not a crash. |
| `TraitService.RollTrait()` past the last band | `nil`. |
| `TraitService.RollTrait(1.0)` | The override is **rejected** (must be `< 1`) → `math.random()` is used. |
| `TraitService.RollTrait(-0.1)` | Override rejected → `math.random()`. |
| `TraitService.RollTrait(0/0)` (NaN) | Override rejected → `math.random()`. |
| `TraitService.GetGenerationMultiplier(nil)` | `1`. |
| `TraitService.GetGenerationMultiplier('Nope')` | `1` + one warning. |
| `TraitService.GetSellMultiplier(nil)` | `'1'`. |
| `TraitService.GetSellMultiplier('Nope')` | `'1'` + one warning. |
| `TraitService.ResolveInheritance('Nope', ...)` | Warn, then roll. The egg is not destroyed. |
| `TraitService.ResolveInheritance('Gold', ...)` | `Gold`, no roll. |
| `MutationService.IsValidMutation(nil / '' / 'Nope')` | `false`. |
| `MutationService.SanitizeList(nil)` | `{}` — a fresh empty table. |
| `MutationService.SanitizeList({'Galactic', 'Galactic', 'Nope'})` | `{'Galactic'}` — dupes and unknowns dropped. |
| `MutationService.GetGenerationMultiplier({})` | `1`. |
| `MutationService.GetSellMultiplier({})` | `'1'`. |
| `MutationService.GetSellMultiplier` where the product exceeds BigNumber's magnitude ceiling | The offending id is skipped with a warning; the fold returns the partial product. |
| `MutationService.ParseListInput(nil)` | `(true, {})`. |
| `MutationService.ParseListInput(42)` | `(false, 'invalid-mutations')`. |
| `MutationService.ParseListInput('none')` | `(true, {})`. |

**Nothing in this system throws at call time.** The only `error()` calls
are in the require-time `validate()` functions of the two config
modules. The service layer never throws, never pcalls, and never
`assert`s.

---

## Gotchas that would bite you

- **`TraitService.RollTrait` does NOT roll when the egg has a valid
  forced trait.** If you call `ResolveInheritance` and then separately
  call `RollTrait`, you will roll twice. There is exactly one roll per
  hatch, inside `ResolveInheritance`.

- **The `Traits.lua` header comment lies about the sell multipliers.** It
  says `Gold x3 sell / Diamond x5 sell / Rainbow x10 sell`; the catalog
  says `'1.2' / '1.5' / '2'`. The generation multipliers in the comment
  *are* right. The catalog is the truth.

- **`Rarity.lua`'s header claims the `Rarity` enum is re-exported. It
  is not.** There is no `RarityDefs.Rarity`. Require
  `ReplicatedStorage.Types.RarityType` yourself.

- **`RarityDefs.Order` is not a power ordering.** Mythic is at index 4,
  Legendary at index 5. Indexing `Order` to compare rarity strength
  gives the wrong answer. `RareEggNotifier` uses an explicit enum set
  for exactly this reason.

- **The canonical rarity table and the legacy `Config/RarityConfig.lua`
  shim have DIFFERENT `SpawnWeight` tables.** Canonical: Mythic 0.2,
  Divine 0, Secret 0. Legacy: Mythic 6, Divine 0.8, Secret 0.2. A
  "Mythic is 6%" claim in a design doc is almost certainly reading the
  shim. New code must require
  `ReplicatedStorage.Config.Creatures.Rarity`.

- **Sell multipliers are strings; generation multipliers are numbers.**
  Mixing them up is a type error at the call site, and `tonumber('2.5')`
  on a *sell* path silently reintroduces float dust.

- **The sell fold is order-sensitive in the BigNumber sense, not in the
  result sense.** `MultiplyDecimal` is exact, so `('2.5' * '2')` and
  `('2' * '2.5')` are both exactly `'5'`. The sort exists for
  determinism and for the duplicate check, not for numerical reasons.

- **`Mutations.SanitizeIds` and `MutationService.SanitizeList` return
  DIFFERENT tables** for the same input (the service's is the config's
  return value, which is itself fresh — but they are separate
  invocations, so two calls give two tables). Never compare them by
  identity.

- **`TraitService` requires `MutationService`** (one direction only).
  There is no cycle, but `MutationService` must be requirable first.

- **Both config modules `table.freeze` their `Catalog`**, and the
  modules themselves are frozen. Runtime mutation of a catalog entry is
  impossible. Balance changes are source edits.

- **A trait is rolled at egg-open time and NEVER changes.** There is no
  reroll, no removal, no upgrade path for traits in this phase. Do not
  build UI that implies otherwise.

- **Mutations transfer wholesale from egg to animal** (a defensive
  copy). They are not re-rolled and are not consumed.

---

## To reuse this in a different game

1. **Keep the two-layer split.** Config in `ReplicatedStorage` (shared),
   thin service facade in `ServerScriptService`. This is what lets a
   client compute a previewed income with the same code the server uses.

2. **Keep the multiplier-as-decimal-string rule** for anything that
   touches currency. If your sell path uses floats, it is already wrong.

3. **Keep `nil` = no trait.** Never persist or display `'None'`.

4. **Keep the sort-then-fold rule.** Sanitize (unique + valid + sorted)
   before every fold.

5. **Replace the catalogs.** `Traits.Catalog` and `Mutations.Catalog` are
   the only Brainrot Arena content. The `Chance` / multiplier shape and
   the validation rules stay.

6. **Delete `Config/RarityConfig.lua`** or turn it into a straight
   re-export of `Config/Creatures/Rarity`. Keeping both invites the
   wrong spawn weights being used.

7. **Add a `Validate()` to your rarity module** if you follow the
   `ConfigValidator` convention. The canonical one lacks it.

8. **Keep the "unknown id degrades to 1x with a warn-once" policy.**
   Records are audit-cleaned, so an unknown id is a bug worth hearing
   about — not a crash worth stopping the server for.

9. **If you add a reroll/upgrade path for traits**, remember that the
   trait sell multipliers are deliberately modest (x1.2 / x1.5 / x2 vs
   x3 / x5 / x10 income) because the flip EV math assumes trait sell EV
   ~= 1.05. Raising them invalidates every egg's hatch-and-sell EV.
