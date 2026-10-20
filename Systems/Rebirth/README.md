# Rebirth

**A server-authoritative "reset your progress for a permanent multiplier" system, with a data-driven requirement ladder, a fail-closed reset transaction, and a preview of what each rebirth unlocks.**

**Portability:** Grade **B — game-specific adapter**. The *transaction core* is portable: the sequential requirement check, the per-player mutex, the base-first reset ordering, the multiplier re-application, and the "reset before you ever validate" discipline are all game-agnostic. The Grade-B parts are the requirement ladder itself (money / arena level / specific animals at specific levels), the stand-unlock model, and the preview-clone system, which is deeply tied to this game's Studio asset hierarchy. Nothing here is platform-bound — no Robux, no HTTP, no DataStore of its own.

**Source game:** Brainrot Arena (p-7)

---

## What It Does

The system owns exactly one thing: the **Rebirth transaction**. A player
spends a large amount of money, reaches an arena level, and hands over
specific animals at specific levels; in exchange their money, animals,
arena progress, and base are reset, they get a fresh cash grant, and
every future money gain is multiplied by a permanent factor (1.5x →
3.5x across the shipped ladder).

It does **not** own the domains it resets. Money stays with
`EconomyService`, animals with `AnimalService`, the base with
`BaseService`/`SlotService`, arena progress with
`ArenaProgressionService`, the multiplier with `ModifierService`, and
the profile with `PlayerService`. The Rebirth service orchestrates them
and owns the count `profile.Data.Rebirth`.

Two design points are worth stating up front because they are easy to
assume wrong:

- **The client never picks a rebirth number.** The client fires
  `RebirthAction { Action = 'Rebirth' }` and the server always attempts
  `current + 1`. There is no "rebirth to 5" path.
- **A failed reset is a failure, not a partial success.** The base
  rebuild runs *first* and is a hard gate: if it fails, nothing else is
  touched and the player keeps their animals and money.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `RebirthService.Init()` | server service | Wires the `RebirthAction` remote. Idempotent. Does nothing else — every other dependency is a direct `require` at load time, not an injection. |
| `RebirthService.RequestRebirth(player)` | server service | The transaction. Returns `{ success = true, rebirth = n }` or `{ success = false, error = <code> }`. |
| `RebirthService.BuildState(userId)` | server service | The GUI snapshot. Read-only; safe to call at any time. |
| `RebirthService.ApplySessionModifiers(userId)` | server service | Re-applies the persisted multiplier to `ModifierService`. **Call on every join** — `ModifierService` is session-only. |
| `RebirthService.ResolveRebirthForStands(userId)` | server service | The stand-count resolver. Inject this into `DynamicSlotService.SetUnlockResolver`. |
| `RebirthService.BeginRebirthBuild` / `EndRebirthBuild` | server service | The pending-stand-count override used during a base rebuild. Called by the service itself; exposed for tests. |
| `RebirthService.RefreshBaseMultiplier(userId)` | server service | Writes `Mult: Nx` onto the owner's own base label. Display only. |
| `RebirthService.HideBaseMultiplier(userId)` | server service | Hides one base's multiplier label (release/leave path). |
| `RebirthService.HideAllBaseMultipliers()` | server service | Hides every base's label. Call at server start. |
| `RebirthService.ForgetPlayer(userId)` | server service | Leave cleanup: drops the in-flight flag, the pending build, and the parked preview clones. |
| `RebirthService.ValidatePostRebirth(userId)` | server service | A **diagnostic only**. Logs loudly on a broken post-rebirth state but never blocks or fails the transaction. |
| `RebirthService._TestReset()` | server service | Clears the busy map. Test-only. |
| `RebirthConfig.Get(index)` | config | The requirement/reward entry for rebirth `index`, or `nil`. |
| `RebirthConfig.MaxConfigured()` | config | The highest configured index (0 if none). |
| `RebirthConfig.StandsFor(rebirth)` | config | `{ Animal, Arena }` stand counts for a current rebirth value. |
| `RebirthConfig.Validate()` | config | Returns `{ string }` of issues. **Never throws.** |
| `RebirthUnlocks.BuildForPreview(current, next)` | shared module | The unlock rows the GUI shows. Pure; no Instances. |
| `RebirthAction` | remote (C→S) | `{ Action = 'Rebirth' \| 'State' }`. |
| `RebirthState` | remote (S→C) | The full GUI snapshot. |
| `RebirthResult` | remote (S→C) | `{ Success, Rebirth?, Error? }`. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Rebirth/RebirthService.lua` | `ServerScriptService/Rebirth/RebirthService.lua` | The whole server side. 1178 lines. |
| `Source/ReplicatedStorage/Config/Economy/Rebirth.lua` | `ReplicatedStorage/Config/Economy/Rebirth.lua` | The 5-entry requirement/reward ladder. |
| `Tests/RebirthUnlocks.spec.lua` | (test tree) | Coverage for `RebirthUnlocks` and `StandShowcase`. **Does not cover `RebirthService` itself.** |

Shared modules the system uses (from `ReusableSystems/Shared/`):

| Library file | Roblox destination | Purpose |
|---|---|---|
| `CommonModules/RebirthUnlocks.lua` | `ReplicatedStorage/Utility/RebirthUnlocks.lua` | Pure derivation of "what does this rebirth unlock" for the GUI. |
| `Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` | Decimal-string money comparison. |
| `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` | `Validation.LivePlayer`. |
| `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` | The logging channel. |
| `CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` | The remote registry. |
| `Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` | `SlotType.OccupantKind.Animal` / `.Egg`. |

---

## Configuration

The system has **its own config**: `ReplicatedStorage/Config/Economy/Rebirth.lua`.
It is fully data-driven — every rebirth is one table entry.

Per entry:

```lua
[3] = {
    Requirements = {
        Money = '3000000',        -- BigNumber decimal STRING
        ArenaLevel = 25,          -- integer
        Animals = {               -- may be empty
            { DefId = 'Turtle', Trait = 'Normal', MinimumLevel = 8 },
            { DefId = 'Walrus', Trait = 'Normal', MinimumLevel = 3 },
        },
    },
    Rewards = {
        StartingCash = '150000',  -- BigNumber decimal STRING
        MoneyMultiplier = 2.5,    -- number > 0
    },
    Reset = {
        Money = true, Base = true, Animals = true, ArenaLevel = true,
    },
    Stands = { Animal = 8, Arena = 3 },  -- stands unlocked BY this rebirth
}
```

Plus `InitialStands = { Animal = 6, Arena = 1 }` — the counts for a
player who has never rebirthed (Rebirth 0 has no completable entry, so
it cannot carry stands itself).

The shipped ladder:

| # | Money | Arena | Animals | StartingCash | Multiplier | Stands (Animal/Arena) |
|---|---|---|---|---|---|---|
| 1 | `500000` | 5 | Dog L5 | `25000` | 1.5x | 6 / 2 |
| 2 | `1500000` | 15 | Fox L1, Spider L3 | `50000` | 2.0x | 7 / 2 |
| 3 | `3000000` | 25 | Turtle L8, Walrus L3 | `150000` | 2.5x | 8 / 3 |
| 4 | `4000000` | 40 | Crocodile L6, Scorpion L4 | `200000` | 3.0x | 8 / 3 |
| 5 | `5000000` | 45 | Gorilla L10, Tiger L10 | `250000` | 3.5x | 8 / 3 |

`RebirthConfig.Validate()` (non-throwing) checks: every requirement
field's type, that `Money`/`StartingCash` are strings, that
`ArenaLevel`/`MinimumLevel` are integers `>= 0`/`>= 1`, that
`MoneyMultiplier` is a number `> 0` and not NaN, that `Stands.Animal` /
`Stands.Arena` are integers `>= 0`, and — importantly — that there are
**no gaps** between 1 and `MaxConfigured()`. A gap would strand
progression, because the server always walks `current + 1`.

A consolidated, documented view of these tunables is in
[`Config.lua`](Config.lua).

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the verbatim `require`
paths, the remotes, the profile fields, and the initialization order.

The short version: `RebirthService` **directly requires** (not injects)
`PlayerService`, `AnimalService`, `BaseService`, `SlotService`,
`ArenaProgressionService`, `ModifierService`, `CarryRegistry`,
`ArenaService`, `StealService`, `EggService`, `FunnelService`, and
`PlayerLogger`. That is unusual for this codebase — almost every other
service uses late-bound `Set*Service()` injection — and it means the
require order in `bootstrap.server.lua` matters. See
[`Setup.md`](Setup.md) step 4.

The dependency tree is nonetheless acyclic: nothing in the list requires
`RebirthService` back, except `GearShopService`, which resolves it
lazily inside `GetPlayerRebirth`.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  RebirthService.Init()          -- wires RebirthAction ONLY
3.  --- players may now join ---
```

Per-player, on join:

```text
1.  PlayerService.LoadPlayerData(player)
2.  base assign / restore
3.  RebirthService.ApplySessionModifiers(userId)  -- restores the multiplier
```

Per-player, on leave:

```text
1.  RebirthService.ForgetPlayer(userId)
```

`RebirthService.Init()` is deliberately the **only** initialization
step. There are no setters, because the service resolves everything by
direct require.

`RebirthService.HideAllBaseMultipliers()` is a separate, optional
server-start call (all bases are unowned at boot, so all labels should
start hidden).

---

## Data

### Profile fields

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `Rebirth` | number (integer `>= 0`) | `RebirthService` | Completed rebirth count. `0` = never rebirthed. Read by `GetRebirth`, which **fails closed to 0** on any malformed value. |
| `Money` | string (BigNumber) | `RebirthService` | **Written directly** on reset — it does **not** go through `EconomyService.AddMoney`. That means the reset bypasses the money audit trail and the `MaxMoney` cap. |
| `Brainrots` | array | `RebirthService` | Emptied (`= {}`) when `Reset.Animals` is true. |
| `LuckyBlocks` | array | `RebirthService` (read only) | Read during the steal rollback sweep. **Never reset** — eggs are intentionally preserved across a rebirth. |
| `Multipliers` | table | — | The `Multipliers.Money` compat field is **not** touched by a rebirth. The rebirth multiplier lives in `ModifierService` instead. |

### Session state (not persisted)

| State | Where | Meaning |
|---|---|---|
| `_busy[userId]` | module-local | The per-player transaction mutex. |
| `_pendingBuild[userId]` | module-local | A stand-count override used while the base is rebuilt (the profile still holds the old count until commit). |
| `ModifierService` source `'Rebirth'` | `ModifierService` | The multiplier. In-memory only — it must be re-applied on every join. |

### Replicated preview store

`ReplicatedStorage/RebirthPreviews/U<userId>/` holds parked **clones**
of the requirement templates and stand templates. Clients cannot read
`ServerStorage`, so the visuals ship as replicated clones. The folder
is destroyed on `ForgetPlayer`. Keys are
`<DefId>|<Trait>` for requirements and `__Stand` / `__ArenaStand` for
unlock previews.

---

## Known Limitations

1. **`RebirthService` has no unit tests.** The only spec in this
   system (`RebirthUnlocks.spec.lua`) covers the *presentation
   derivation* and the `StandShowcase` clone helpers. The transaction
   itself — requirement matching, the reset order, the mutex — is
   untested. This is the single biggest gap if you reuse the system.

2. **`RebirthService` requires its dependencies at load time.** Unlike
   every other service in this library, it cannot be required before
   its dependencies exist. That makes it hard to unit-test and hard to
   swap out a domain (e.g. replace the arena with something else)
   without editing the top of the file.

3. **The reset bypasses `EconomyService`.** `data.Money` is assigned
   directly (`RebirthService.lua:1043`). The money is never recorded in
   the transaction log, and `MaxMoney` is not enforced on the *new*
   value. This is intentional (a reset is not a purchase) but it means
   the two money paths have different guarantees.

4. **The multiplier is session-only.** `ModifierService` is in-memory.
   If `ApplySessionModifiers` is not called on every join, a returning
   player's multiplier is `1x` until they rebirth again. Nothing
   detects this.

5. **The `Rebirth` count is not re-validated against the config.** If
   the config is edited to remove entries (say, to 3) while a player is
   at 5, `RebirthConfig.Get(6)` returns `nil` and the player is
   permanently maxed with no way to spend their count. `ApplySessionModifiers`
   falls back to `MaxConfigured()`'s multiplier, but the count stays 5.

6. **`RebirthConfig.Get` is not present for Rebirth 0.** `Get(0)`
   returns `nil` (the guard rejects `index < 1`). Use
   `StandsFor(0)` for the never-rebirthed counts.

7. **The preview store grows with the requirement count.** Every
   distinct `(DefId, Trait)` pair in the ladder parks one clone per
   player. It is pruned on rebuild, but a player who never opens the
   GUI still accumulates them because `attachTemplateModels` runs from
   `BuildState`, which `RequestRebirth` also calls.

8. **`ValidatePostRebirth` is diagnostic only.** It can log six
   different failure reasons, and none of them fail the transaction.
   A rebirth that leaves the player baseless still reports success.

9. **The stand-unlock model assumes a single `Stands` count per kind.**
   There is no notion of stand *variants* or *tiers* — a rebirth grants
   a raw count of stands, and `StandLayoutConfig` decides where they
   go.

10. **The `Reset` flags are all-or-nothing per domain.** A rebirth
    cannot, for example, reset money but keep animals, because the
    reset order is fixed: base → animals → arena → money. (The
    individual flags *can* disable a step, but the order is not
    configurable.)

---

## Testing

`Tests/RebirthUnlocks.spec.lua` — TestEZ, Studio-only (there is no
headless Luau runner in this project). It covers:

- `RebirthUnlocks.BuildForPreview` — the unlock deltas for R0→R1, R1→R2,
  R2→R3, and its rejection of non-sequential / unconfigured /
  malformed inputs.
- `RebirthUnlocks.DisplayName` / `NameColor` / `NumberVisible` /
  `CountText` / `Signature` — the text helpers, with the display
  constants pinned against `Config.Presentation.UI.Overhead`.
- `StandShowcase.StripInteractiveOnly` / `FrontYawOffset` /
  `ClearOutlines` — the clone-only showcase helpers.

The specs need **no DataStore, no published place, and no Robux**.

See [`Setup.md`](Setup.md) step 7 for how to run them, and
[`API.md`](API.md) for the full function list.

---

## Adapting to a New Game

1. **Write your own ladder.** Replace the 5 entries in
   `ReplicatedStorage/Config/Economy/Rebirth.lua` with your own
   requirements and rewards. Keep the shape exactly:
   `Requirements { Money (string), ArenaLevel (int), Animals { { DefId, Trait?, MinimumLevel } } }`,
   `Rewards { StartingCash (string), MoneyMultiplier (number) }`,
   `Reset { Money, Base, Animals, ArenaLevel }`,
   `Stands { Animal, Arena }`. Run `RebirthConfig.Validate()` and make
   it return an empty array.

2. **If your game has no arena level**, set `ArenaLevel = 0` on every
   entry. The check `arenaLevel >= entry.Requirements.ArenaLevel`
   then always passes. Alternatively, repurpose the field for
   whatever gate you have and rename it — the field is read in exactly
   one place (`RebirthService.lua:857`).

3. **If your game has no animals**, empty the `Animals` array on every
   entry. `matchAnimals` over an empty rules list returns
   `allMatched = true` — no change needed.

4. **If your game has no trait concept**, use `Trait = 'Normal'`
   everywhere. `traitOf` maps a missing/empty trait to `'Normal'`, so
   untraited records match.

5. **Keep the entries sequential.** `Validate()` enforces no gaps, and
   the server walks `current + 1`. If you want a rebirth to be
   repeatable, extend the *rewards* rather than adding a second axis.

6. **Wire the multiplier on join.** In your `PlayerAdded` handler, call
   `RebirthService.ApplySessionModifiers(userId)` after the profile
   loads. Without it, a returning player has `1x` income.

7. **Wire the stand resolver.** In your bootstrap:
   ```lua
   DynamicSlotService.SetUnlockResolver(function(userId: number): number
       return RebirthService.ResolveRebirthForStands(userId)
   end)
   ```
   Without it, stands are limited to the marker/bases counts and
   rebirth-gated stands never appear.

8. **Decide what a reset means for your game.** The shipped
   configuration resets money, base, animals, and arena level. If your
   game should keep a collection, set `Reset.Animals = false` — but be
   aware that the *base* reset still destroys the runtime animals that
   were on those stands, so you would need to re-home them.

9. **Decide about eggs.** The shipped config deliberately leaves
   `LuckyBlocks` (eggs) alone across a rebirth and calls
   `EggService.ReconcileAfterBaseSwap` to re-home their slot ids. If
   you have no egg system, drop that call — it is `pcall`-guarded, so
   it is safe, but the eggs you do not have will simply not exist.

10. **Strip the preview system if you do not need it.** The
    `attachTemplateModels` / `attachUnlockModels` machinery and the
    `ReplicatedStorage/RebirthPreviews` folder are **presentation
    only**. Delete `state.Animals[].TemplateModel` and
    `state.Unlocks[].TemplateModel` from the state and the two attach
    helpers, and the core transaction still works.

11. **Re-check the base-must-have-stands gate.** The transaction
    refuses to commit a base with zero stands
    (`RebirthService.lua:988`). If your game has no stands, remove
    that check or you can never rebirth.

---

## See also

- [`MEMORY.md`](MEMORY.md) — engineering notes for a future agent.
- [`API.md`](API.md) — every public function, with failure modes.
- [`Config.lua`](Config.lua) — the consolidated tunables.
- [`Dependencies.md`](Dependencies.md) — requires, remotes, profile fields.
- [`Setup.md`](Setup.md) — install steps into a new Rojo project.
