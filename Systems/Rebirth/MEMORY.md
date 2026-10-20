# Rebirth — MEMORY

Dense engineering notes for a future agent. Everything here was read
out of the source; nothing is assumed.

---

## Purpose in one line

Own the Rebirth transaction: check a data-driven requirement ladder
against authoritative state, then reset the player's money / animals /
arena / base in a fixed order while granting a permanent money
multiplier.

---

## How it actually works

### Wiring (there is no injection)

`RebirthService` **directly `require`s** every domain authority at the
top of the file (`RebirthService.lua:52-71`). This is unlike every
other service in the library, which uses `Set*Service()` injection.
The require order in `bootstrap.server.lua` is therefore load-bearing.

`RebirthService.Init()` does exactly one thing: it finds the
`RebirthAction` RemoteEvent and connects `OnServerEvent`. It is
idempotent via a module-local `_wired` flag. If the remote is missing
it logs `'RebirthAction remote missing; rebirths disabled'` and the
system is inert — it does **not** throw.

### The remote handler (`RebirthService.lua:1124-1147`)

```lua
local action = if type(payload) == 'table' then payload.Action else nil
if action == 'State' then pushState(...) ; return end
-- default (including empty/missing payloads): attempt the next rebirth
local result = RebirthService.RequestRebirth(player)
```

So **`Action = 'Rebirth'` and a missing `Action` behave identically.**
There is no client-selectable rebirth number.

On failure the handler fires `RebirthResult { Success = false, Error = result.error }`
and then **still pushes a fresh `RebirthState`** (the GUI may be stale).

### The transaction (`RequestRebirth`, `RebirthService.lua:779-1113`)

The order is exact:

1. `Validation.LivePlayer(player)` → else `fail('invalid-player')`.
2. `_busy[userId]` check → else `fail('busy')`. **Set immediately.**
3. `current = GetRebirth(userId)`, `nextIndex = current + 1`,
   `entry = RebirthConfig.Get(nextIndex)` → `fail('maxed')` if nil.
4. `wasFirstEver = (current == 0)` — captured **pre-commit**, used at the
   very end for the `FirstRebirth` funnel step.
5. Funnel log `RebirthAttempted` (scoped by `_key = nextIndex` so
   repeated failures do not spam).
6. `CarryRegistry.IsCarrying(userId)` → `fail('carrying')`.
7. `checkRaidLock(userId)` → `fail('raid-locked')`.
   `checkRaidLock` iterates `AnimalService.ListForPlayer(userId)` and
   asks `ArenaService.IsAnimalRaidLocked(uniqueId)` for each. A raid
   covers the whole run, so **any** locked owned animal blocks.
8. `PlayerService.GetPlayerData(userId)` → `fail('no-profile')` if not a
   table.
9. Money check: `BigNumber.Compare(money, entry.Requirements.Money) >= 0`
   → else `fail('money')`.
10. Arena check: `ArenaProgressionService.GetArenaLevel(userId) >=
    entry.Requirements.ArenaLevel` → else `fail('arena')`.
11. Animal check: `matchAnimals(data.Brainrots, entry.Requirements.Animals)`
    → `fail('animals')` if not all matched. This call also
    `attachTemplateModels` (parks the preview clones) as a side effect.
12. Funnel log `RebirthRequirementReached`.
13. **Commit** — in this order:
    a. **Steal/carry rollback** (recover-then-sweep), `pcall`-guarded:
       `StealService.RollbackIfStealing(userId, 'rebirth')`, then
       `StealService.RollbackStolenTarget(SlotType.OccupantKind.Animal, rec.Id, 'rebirth')`
       for each brainrot, then the same for each `LuckyBlocks` record
       with `SlotType.OccupantKind.Egg`. This must happen **before**
       any runtime object is destroyed, or the thief keeps a dangling
       `destSlot` reservation + speed snapshot and victim rows strand.
    b. **Base reset** (if `reset.Base`) — see below. This is a **hard
       gate**: failure → `fail('reset-failed')` and nothing else runs.
    c. **Animals reset** (if `reset.Animals`) — collect the ids, then
       per id: find the slot, `AnimalService.DestroyRuntimeAnimal(id)`,
       `SlotService.ReleaseSlot(slot.id)`, `PlayerService.RemoveAnimal(userId, id)`.
       Then `data.Brainrots = {}`.
    d. **Arena reset** (if `reset.ArenaLevel`) — `ArenaProgressionService.ResetArena(userId)`.
    e. **Money reset** (if `reset.Money`) —
       `data.Money = BigNumber.sanitize(entry.Rewards.StartingCash) or '0'`.
    f. `data.Rebirth = nextIndex` — **always**, regardless of the flags.
    g. `ModifierService.AddModifier(userId, 'Rebirth', MoneyMultiplier, entry.Rewards.MoneyMultiplier)`.
    h. `RebirthService.RefreshBaseMultiplier(userId)` — the label update.
    i. `EggService.ReconcileAfterBaseSwap(userId)` — re-homes stale egg
       slot ids after the base swap.
14. **Replicate**: `BaseService.Snapshot(userId)` → `PlayerService.PushState(player, snap)`
    → `pushState(player, userId)` (the GUI snapshot) →
    `RebirthResult { Success = true, Rebirth = nextIndex }`.
15. `RebirthService.ValidatePostRebirth(userId)` — diagnostics only.
16. `release()` — clears `_busy[userId]`.
17. Funnel `RebirthSucceeded` (+ `FirstRebirth` if `wasFirstEver`),
    `PlayerLogger.LogMilestone(player, 'RebirthSucceeded', ...)`.
18. Lazy `LeaderboardService.MarkDirty(userId)` and
    `TabListService.MarkDirty()` — both `pcall`-guarded lazy requires.
19. Return `{ success = true, rebirth = nextIndex }`.

### The base reset in detail (`RebirthService.lua:934-1011`)

This is the most subtle part of the system.

- `RebirthService.BeginRebirthBuild(userId, nextIndex)` is called
  **before** the rebuild, so `DynamicSlotService` builds the **new**
  rebirth's stand counts even though the profile still holds the old
  value. `EndRebirthBuild(userId)` is called immediately after the
  rebuild block — on every exit path.
- The rebuild **prefers the player's current base**: it reads
  `BaseService.GetBaseByOwner(userId)`, releases it with
  `BaseService.ReleasePlayerBase(userId)`, then re-acquires the **same
  id** with `BaseService.AssignBaseById(userId, prevBaseId)`. The
  comment calls this "atomically" — a released base is `Available` and
  no other assign can interleave, so a rebirth never migrates the
  player to a different base.
- If the player has **no** base (a retry after a previous
  `reset-failed`), the release is skipped and
  `BaseService.AssignBaseForPlayer(userId)` is used instead. This is
  what makes a retry possible at all.
- After the assign: `PlayerService.AssignBase(userId, base.id)` →
  `BaseService.PointPlayerToBaseSpawn(player, base)` (re-points the
  `RespawnLocation` so the next death respawns at the *current* base,
  never the released one).
- **Stand gate**: `#(base.slots or {})` must be `> 0`. A 0-slot rebuild
  is treated as a content/setup failure (missing template or markers),
  not a valid target, and the whole transaction aborts with
  `reset-failed`.

### `matchAnimals` (`RebirthService.lua:288-346`)

- The pool is every `data.Brainrots` record with `Type == 'Brainrot'`.
- For each requirement rule (`DefId`, `Trait`, `MinimumLevel`):
  - Candidates are records with `rec.DefId == wantDef` **and**
    `traitOf(rec.Trait) == wantTrait`.
  - `traitOf` maps a non-string or empty trait to `'Normal'`.
  - The **highest-level** candidate is chosen (`bestLevel`).
  - `matched` = a candidate exists AND `bestLevel >= MinimumLevel`.
  - On a match the record is **removed from the pool** — so one animal
    can never satisfy two requirements.
- The returned `rows` carry per-requirement progress for the GUI:
  `{ DefId, DisplayName, Trait, MinimumLevel, Matched, BestLevel, TemplateModel }`.
  `TemplateModel` is always `nil` here by construction; the caller
  (`attachTemplateModels`) fills it.
- `DisplayName` comes from `AnimalConfig.Get(wantDef)`'s `displayName`,
  falling back to the DefId.

### `BuildState` (`RebirthService.lua:615-672`)

Read-only snapshot. Returns:

```lua
{
  Current = number,
  Next = number?,        -- nil when maxed
  Maxed = boolean,
  CanRebirth = boolean,
  Money = string, MoneyRequired = string, MoneySatisfied = boolean,
  ArenaLevel = number, ArenaRequired = number, ArenaSatisfied = boolean,
  Animals = { { DefId, DisplayName, Trait, MinimumLevel, Matched, BestLevel, TemplateModel, Rarity? } },
  Unlocks = { { Kind, Amount, GearId?, Name?, TemplateModel? } },
  StartingCash = string,
  MoneyMultiplier = number,
}
```

When `RebirthConfig.Get(nextIndex)` is nil (maxed) it returns early
with just `Current / Next=nil / Maxed=true / CanRebirth=false` — the
other fields are **absent**, not nil-valued.

### The preview store

`ReplicatedStorage/RebirthPreviews/U<userId>/`:

- **Requirement previews**: one clone per `(DefId, Trait)` key, named
  `"<DefId>|<Trait>"`, cloned from
  `AnimalService.GetTemplate(rarity, defId, traitOrNil)`. Reused across
  rebuilds; stale keys pruned. `__`-prefixed keys are never pruned by
  this pass.
- **Unlock previews**: `__Stand` and `__ArenaStand`, cloned from
  `DynamicSlotService.GetTemplate()` / `GetArenaTemplate()` — the
  **same** source the runtime builds stands from, never a second model.
- The folder is created on demand and destroyed by `ForgetPlayer`.
- A failure to resolve a template is a **warning**, and the card
  renders text-only.

### `RebirthUnlocks.BuildForPreview(current, next)` (shared module)

- Returns `{}` unless `next == current + 1` and both are integers
  `>= 1`. So `BuildForPreview(0, 2)`, `(1, 1)`, `(3, 4)`, `(nil, 1)`,
  `(0.5, 1)` all return empty.
- Stand deltas = `StandsFor(current)` vs `entry.Stands`, floored at 0.
  A flat count produces **no card** (never "+0" for a stand).
- Gear unlocks fall out of `GearConfig.GetAll()` — every entry whose
  `RequiredRebirth == nextIndex`, in catalog order.
- Order: Animal stands, Arena stands, then gears.

### `ApplySessionModifiers` (`RebirthService.lua:131-156`)

- Reads the persisted `Rebirth` count.
- `RebirthConfig.Get(current)`; if nil (the count is above the
  configured max, or the entry was removed), falls back to
  `RebirthConfig.Get(RebirthConfig.MaxConfigured())`.
- Adds the `MoneyMultiplier` under the source id `'Rebirth'`.
  `ModifierService.AddModifier` **replaces** an existing
  `(userId, type, sourceId)` triple, so this is idempotent.
- Then calls `RefreshBaseMultiplier(userId)` — which resolves the
  multiplier through `ModifierService.GetMoneyMultiplier` (the exact
  value income uses), formats it, and writes `Mult: 1.5x` onto the
  owner's own base label.

### The base multiplier label

`_multLabel` (`RebirthService.lua:180-202`) resolves
`Base/MoneyMultPart/SurfaceGui/TextLabel`, preferring direct children
and falling back to recursive search. The `SurfaceGui` lookup prefers a
direct child named `SurfaceGui`, then `FindFirstChildWhichIsA('SurfaceGui', true)`.

`formatMultiplier` (`RebirthService.lua:161-173`): `1` → `"1"`,
`2` → `"2"`, `2.5` → `"2.5"`. NaN / infinite / `<= 0` → `1`. The text
is `('Mult: %sx'):format(...)`. **Display only — gameplay never reads
the string.**

### `ValidatePostRebirth` (`RebirthService.lua:698-777`)

Six checks, each of which only **warns**:

| Reason | Meaning |
|---|---|
| `no-base` | `BaseService.GetBaseByOwner(userId)` returned nothing. |
| `base-owner-mismatch` | `base.ownerUserId ~= userId`. |
| `no-stands` | The base has zero slots. |
| `base-binding-mismatch` | `PlayerService.GetBaseId(userId) ~= base.id`. |
| `carry-not-clean` | `CarryRegistry.IsCarrying(userId)` is true — proves a yield interleaved a grab between the entry gate and the teardown. |
| `steal-still-active` | A carry row with a `steal` sub-table involves this player (as thief or as the original owner). |
| `egg-record-unresolved` | A `LuckyBlocks` record's `SlotId` does not resolve via `SlotService._findSlotById`. |

**None of these fail the transaction.** The function is called *after*
the success result is already pushed.

---

## Public API surface (exact)

### `RebirthService`

```lua
RebirthService.Init(): ()
RebirthService.GetRebirth(userId: number): number
RebirthService.BeginRebirthBuild(userId: number, nextIndex: number): ()
RebirthService.EndRebirthBuild(userId: number): ()
RebirthService.ResolveRebirthForStands(userId: number): number
RebirthService.ApplySessionModifiers(userId: number): ()
RebirthService.RefreshBaseMultiplier(userId: number): ()
RebirthService.HideBaseMultiplier(userId: number): ()
RebirthService.HideAllBaseMultipliers(): ()
RebirthService.BuildState(userId: number): { [string]: any }
RebirthService.RequestRebirth(player: Player): { [string]: any }
RebirthService.ValidatePostRebirth(userId: number): ()
RebirthService.ForgetPlayer(userId: number): ()
RebirthService._TestReset(): ()
```

The module returns `table.freeze(RebirthService)`.

### `RebirthConfig` (`ReplicatedStorage/Config/Economy/Rebirth`)

```lua
Rebirth.Get(index: number): RebirthEntry?
Rebirth.MaxConfigured(): number
Rebirth.StandsFor(rebirth: number): { Animal: number, Arena: number }
Rebirth.Validate(): { string }
```

Types:

```lua
export type RebirthAnimalRequirement = { DefId: string, Trait: string?, MinimumLevel: number }
export type RebirthEntry = {
    Requirements: { Money: string, ArenaLevel: number, Animals: { RebirthAnimalRequirement } },
    Rewards: { StartingCash: string, MoneyMultiplier: number },
    Reset: { Money: boolean, Base: boolean, Animals: boolean, ArenaLevel: boolean },
    Stands: { Animal: number, Arena: number },
}
```

### `RebirthUnlocks` (`ReplicatedStorage/Utility/RebirthUnlocks`)

```lua
RebirthUnlocks.Kind = { AnimalStand = 'AnimalStand', ArenaStand = 'ArenaStand', Gear = 'Gear' }
RebirthUnlocks.White: Color3      -- = OverheadConfig.FallbackColor
RebirthUnlocks.ArenaGold: Color3  -- = OverheadConfig.TraitColors.Gold
RebirthUnlocks.DisplayName(entry: UnlockEntry): string
RebirthUnlocks.NameColor(entry: UnlockEntry): Color3
RebirthUnlocks.NumberVisible(entry: UnlockEntry): boolean
RebirthUnlocks.CountText(amount: any): string
RebirthUnlocks.BuildForPreview(currentRebirth: number, nextIndex: number): { UnlockEntry }
RebirthUnlocks.Signature(nextIndex: number, unlocks: { UnlockEntry }): string
```

---

## Invariants the code enforces

1. **Rebirths are sequential.** The server always attempts
   `current + 1`. There is no way to skip.
2. **The client never supplies a number.** `RebirthAction` carries only
   `Action`.
3. **Only one rebirth per player at a time.** `_busy[userId]` is set
   before any work and cleared on every exit path.
4. **A failed base reset aborts everything.** The base rebuild is the
   first destructive step and a hard gate.
5. **The base rebuild prefers the same base id.** A rebirth never
   migrates the player to a different base (unless they had none).
6. **A committed base must have at least one stand.** Zero stands →
   `reset-failed`.
7. **One animal can satisfy at most one requirement.** Matched records
   are consumed from the pool.
8. **A requirement needs a *distinct* animal per rule.** Duplicated
   DefIds in one entry need that many animals.
9. **The highest-level matching candidate is used** for the preview,
   not the first found.
10. **Untraited == `'Normal'`.** A missing/empty trait on either the
    record or the rule maps to `'Normal'`.
11. **The multiplier source id is `'Rebirth'`.** Re-adding replaces,
    so it can never double-count.
12. **The multiplier is re-applied on every join.** It is session-only.
13. **The money reset writes `data.Money` directly** — it does not go
    through `EconomyService` and is not subject to `MaxMoney`.
14. **`data.Rebirth` is always set** to `nextIndex` on a successful
    commit, whatever the `Reset` flags say.
15. **`GetRebirth` fails closed to 0** on a missing profile, a
    non-number, a non-integer, or a negative.
16. **Steal/carry state is resolved before any destruction.**
17. **Eggs survive a rebirth**; their slot ids are re-homed afterwards.
18. **The `Rebirth` config has no gaps** — enforced by `Validate()` and
    by the `current + 1` walk.
19. **Every requirement is AND-ed.** Money, arena, and animals must
    *all* pass.
20. **The failure path still refreshes the GUI state.**

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| `RequestRebirth` on a dead player | `{ success = false, error = 'invalid-player' }` |
| Two concurrent requests | The second gets `'busy'` |
| `current + 1` is not configured | `'maxed'` |
| Player is carrying an animal | `'carrying'` — checked before anything else |
| Any owned animal is raid-locked | `'raid-locked'` |
| No profile | `'no-profile'` |
| Money below the requirement | `'money'` |
| Arena level below the requirement | `'arena'` |
| An animal requirement unmatched | `'animals'` |
| The base rebuild failed | `'reset-failed'` — **and nothing else was touched** |
| `RebirthConfig.Get` returns a bad value | `nil` → the caller fails closed |
| The `RebirthAction` remote is missing | A warning at `Init`; the system is inert |
| `RebirthState` requested by a dead player | Nothing is pushed |
| A preview template cannot be resolved | A warning; the card renders text-only |
| `ModifierService.AddModifier` throws | `pcall`-guarded; the rebirth still succeeds **without** the multiplier |
| `EggService.ReconcileAfterBaseSwap` throws | `pcall`-guarded; the rebirth still succeeds |
| `LeaderboardService` / `TabListService` missing | `pcall`-guarded lazy require; ignored |
| `FunnelService` / `PlayerLogger` missing | `pcall`-guarded; ignored |
| A malformed `Rebirth` field in the profile | `GetRebirth` returns `0` |

**Error codes returned by `RequestRebirth`:**
`'invalid-player'`, `'busy'`, `'maxed'`, `'carrying'`,
`'raid-locked'`, `'no-profile'`, `'money'`, `'arena'`, `'animals'`,
`'reset-failed'`.

---

## Gotchas that would bite you

1. **The require-at-load-time style.** `RebirthService` cannot be
   required before `PlayerService`, `BaseService`, `AnimalService`,
   `SlotService`, `ArenaProgressionService`, `ModifierService`,
   `CarryRegistry`, `ArenaService`, `StealService`, `EggService`,
   `FunnelService`, and `PlayerLogger` all resolve. If you reorder
   your bootstrap, the require itself can fail.

2. **The money reset bypasses `EconomyService`.** No transaction
   record, no `MaxMoney` enforcement, and the HUD only updates because
   `PlayerService.PushState` is called explicitly afterwards.

3. **The multiplier is invisible if `ApplySessionModifiers` is
   missing from your join handler.** The count persists; the effect
   does not.

4. **`RebirthConfig.Get(0)` is `nil`.** Use `StandsFor(0)`.

5. **`StandsFor` returns the highest entry at or below the value**, not
   the exact entry. A player at rebirth 7 (with a 5-entry config) gets
   entry 5's counts.

6. **The `Reset.Base` flag does more than "reset the base".** It
   rebuilds the base with the *new* rebirth's stand counts and
   re-points the `RespawnLocation`. It is the reason the base step
   runs first.

7. **`_pendingBuild` leaks if `EndRebirthBuild` is not called.** It is
   cleared on every exit path of the rebuild block in
   `RequestRebirth`, but if you add an early return inside that block,
   the player keeps the pending override until `ForgetPlayer`.

8. **`RebirthService.ApplySessionModifiers` is called from the join
   handler in the source game, but the module is also responsible for
   `RefreshBaseMultiplier` on that path.** Two effects in one call.

9. **`RebirthConfig.Validate()` never throws.** It returns an array of
   strings. `Config/Creatures/Progression.lua` (the Upgrades system)
   does the opposite — it `error()`s at require time. Do not copy that
   pattern here.

10. **`RebirthUnlocks.BuildForPreview` requires `next == current + 1`.**
    A preview of a non-adjacent rebirth returns an empty list, not an
    error.

11. **The preview clones are replicated to every client.** They live in
    `ReplicatedStorage`, so every player sees every other player's
    parked templates. Do not put anything secret in them.

12. **The `Rebirth` count is not the multiplier.** The multiplier comes
    from `RebirthConfig.Get(current).Rewards.MoneyMultiplier` — which,
    for a count above `MaxConfigured`, is the *last configured* entry's
    multiplier. The two can disagree after a config edit.

13. **`Data.Brainrots = {}` is assigned wholesale** in the animals
    reset, after the per-id removal loop. If the per-id loop somehow
    left a record that the game needs, it is gone.

14. **`checkRaidLock` is O(animals)** and calls into `ArenaService` per
    animal. On a large inventory that is a lot of work per attempt.

15. **`RebirthService.Init()` connects to the remote with a 10-second
    `WaitForChild`.** If the remotes folder is not created first, the
    connect is delayed and a warning is logged.

16. **The `Reset.Animals` wipe does not touch `LuckyBlocks`.** Eggs
    stay. That is intentional but surprising.

---

## What to change to reuse it

- **Requirements:** replace the `ENTRIES` table in
  `ReplicatedStorage/Config/Economy/Rebirth.lua`. Keep the shape
  exactly; `Validate()` will tell you if you got it wrong.
- **No arena:** set `ArenaLevel = 0` everywhere. The check becomes
  vacuous.
- **No animals:** empty the `Animals` arrays. `matchAnimals` over an
  empty rule list returns `allMatched = true`.
- **No traits:** use `Trait = 'Normal'` everywhere.
- **No stands:** delete the `standCount > 0` gate in
  `RebirthService.lua:988`, otherwise the transaction can never
  commit.
- **No eggs:** delete the `EggService.ReconcileAfterBaseSwap` call and
  the `LuckyBlocks` rollback loop.
- **No preview:** delete `attachTemplateModels` + `attachUnlockModels`
  and the `TemplateModel` fields. Pure presentation.
- **No base reset:** set `Reset.Base = false` everywhere. But then the
  stand counts never change — the `Stands` config becomes decorative.
- **No funnel/leaderboard/logger:** delete the three `pcall` blocks at
  the end of `RequestRebirth`. They are already safe to remove.
- **A different money reset:** the `data.Money = ...` line is the only
  place. If you want the money to go through `EconomyService`, replace
  it with an `AddMoney` call — but be aware the balance is being
  *reduced*, and `EconomyService` has no "set" or "subtract" API, only
  `TrySpendMoney`.
- **A different multiplier system:** replace the single
  `ModifierService.AddModifier` call. `ModifierService` is the only
  multiplier authority in this codebase.
- **A different stand model:** `RebirthUnlocks` and
  `RebirthConfig.StandsFor` are coupled to a `{ Animal, Arena }` count
  pair. A third stand kind means changing both, plus
  `DynamicSlotService`.
