# PlayerData — Memory

What a future maintainer must know about `PlayerData` that is **not** obvious
from reading the code. Everything here was verified against the source.

**Source game:** Brainrot Arena (`p-7`).
**Portability:** Grade A core (the load/reconcile/audit pipeline) + Grade B
(the profile schema is Brainrot Arena's content).

---

## 1. The load pipeline is a *sequence*, not a call

`PlayerService.LoadPlayerData(player)` is the only way a profile enters the
service. It does five things in a fixed order:

1. **Reserve the slot.** `PROFILE_STORE:LoadProfileAsync('Player_' .. tostring(userId), 'ForceLoad')`.
   The key is `'Player_<userId>'` — note the **literal `Player_` prefix**, not
   a bare userId.
2. **Clone the template** into `profile.Data`. `table.clone` for the top level,
   then *explicit* clones for `Multipliers` and `Tutorial` — the nested tables
   that would otherwise be shared between every player.
3. **Reconcile.** `profile:Reconcile()` fills missing keys from the template.
4. **Repair.** ~20 hand-written per-field blocks fix values that
   `Reconcile` deliberately leaves alone (wrong types, stale shapes, values
   outside their legal range).
5. **Audit.** `PersistenceAudit` walks the owned-object lists (`Brainrots`,
   `LuckyBlocks`) and repairs, quarantines, or re-homes invalid records
   **before anything else reads them**.

`Reconcile` runs *before* the repair blocks and the audit. A field that
`Reconcile` "fixed" by inserting the template value can still be wrong-typed,
and the repair block is what catches it.

**`LoadPlayerData` returns a `boolean`, not the data.** The data comes from
`GetPlayerData(userId)`. A failed load must leave the player *out* of the
service entirely — the caller is expected to kick them.

---

## 2. `profile:Reconcile()` is not enough on its own

`ProfileService`'s `Reconcile()` only fills in **missing** keys. It does not
fix a key that exists with the wrong type, the wrong shape, or a value outside
its legal range.

That is why there are ~20 hand-written repair blocks after the reconcile. They
exist because a profile written by an older build of the game can contain
`Money = 5000` (a Lua number) where the current build expects
`Money = '5000'` (a BigNumber decimal string), and `Reconcile` will happily
leave the number in place.

**Do not delete the repair blocks thinking `Reconcile` covers them.**

---

## 3. `Money` is a string, and the repair blocks enforce it

`profile.Data.Money` is a BigNumber decimal **string** (`'5000'`). A Lua
number above 2^53 silently loses precision, which is the entire reason
`BigNumber` exists.

`EconomyService` reads and writes this field but does not own its *type*;
`PlayerService`'s repair blocks are what guarantee it is a string. If you
write to `data.Money` directly anywhere, you break the invariant that the
whole economy depends on.

The same applies to every other BigNumber field in the profile.

---

## 4. `Multipliers` is deprecated compat data

`profile.Data.Multipliers = { Money = 1 }` exists so that profiles written by
older builds still reconcile. It is **always 1** in a legitimate profile and
**no system writes any other value**.

`EconomyService.AddMoney` still consults it (the `ApplyMultiplier` option
defaults to `true`), but every live income/XP transaction passes
`{ ApplyMultiplier = false }`, so the multiplier path can never shape a
reward. `MultiplierService` (the modern system) keeps its state in memory
only and never persists.

**Do not add new code that writes `Multipliers`.** It is a compat shim, and
the `Money = 1` invariant is load-bearing for the reconcile pass.

---

## 5. `PersistenceAudit` is not optional

The audit runs inside the load pipeline, before other systems can read the
profile. It exists because the owned-object lists (`Brainrots`, `LuckyBlocks`,
`OwnedRobuxGear`) can contain records that are:

- **malformed** (missing required fields, wrong types),
- **duplicated** (two records for the same owned object),
- **re-homeable** (a valid record whose owning base no longer exists).

Each is handled differently: repaired in place, quarantined, or moved to a
different owner. The audit is the reason a corrupted profile degrades
gracefully instead of breaking whichever system reads it first.

`PersistenceAudit` also owns the **owned-object identity** rules
(`OwnedObjectIdentity`): the `AN_` prefix for animals, the id format, and the
8-attempt uniqueness retry.

---

## 6. The profile schema is Brainrot Arena content, not infrastructure

The `STUDIO_PROFILE_TEMPLATE` (the shape a brand-new profile gets) contains
fields that are **this game's** and will not all make sense in a new game:

| Field | Game-specific? |
|---|---|
| `Money`, `BaseId`, `Rebirth`, `LastSeen` | No — core |
| `Stats` (counters) | No — core, but the counters are yours |
| `Settings` (`Bgm`, `Sfx`, `FastMode`) | No — core, but the options are yours |
| `Tutorial` (`Step = 'BuyEgg'`) | **Yes** — the step names are this game's |
| `Brainrots` | **Yes** — the animal list, named for this game |
| `LuckyBlocks` | **Yes** — the egg list, named for this game |
| `GearAutoBuy`, `OwnedRobuxGear` | **Yes** — the gear catalogue |
| `Arena` (`Level`, `XP`, `Wins`, `PendingEggs`) | Partly — the arena is this game's |
| `DailyRewards`, `PlaytimeRewards` | Partly — the reward tables are yours |
| `RedeemedCodes`, `PendingCodeRewards` | No — core, but the code catalogue is yours |

`Money` is the only field that is unambiguously infrastructure.

---

## 7. The DataStore name is a placeholder

```lua
local PROFILE_NAME = 'p7_PlayerData_Money_v1_dev_1'
```

The `p7_` prefix is the **source game's** identifier. A new game must rename
it. Renaming a DataStore orphans every existing profile, so do it *before*
you ship, not after.

The old DataStore is deliberately left in place (a standing instruction on
the source project: "don't delete the old DataStore itself, just change the
name"). That is a source-project decision, not something to copy.

---

## 8. `PlayerService` is the ONLY module that touches `ProfileService`

`ServerScriptService.Packages.ProfileService` is required by exactly one
file: `PlayerService.lua`.

Every other system goes through `PlayerService` mutators
(`AddAnimal`, `RemoveAnimal`, `AddEgg`, `ConsumeEggIntoAnimal`,
`SetAnimalSlot`, `BumpStat`, `AssignBase`, `WipeUser`, …). That is deliberate:
it is what makes the profile a single-writer surface and keeps the audit and
the repair blocks in one place.

**If you are tempted to `require` ProfileService somewhere else — don't.**
Add a mutator to `PlayerService` instead.

---

## 9. `PushState` and the `PlayerState` wire format

`PlayerService.PushState(player, baseSnapshot?)` fires the `PlayerState`
remote to that one player. The payload is:

```lua
{
	Money        = data.Money,   -- BigNumber decimal STRING
	BaseId       = data.BaseId,
	Slots        = baseSnapshot and baseSnapshot.slots or {},
	CarriedKind  = carry.Kind,
	CarriedName  = carry.Name,
	CarriedSteal = carry.Steal == true,
}
```

`baseSnapshot` is optional. Omit it and `Slots` is an empty table — that is
normal for a game that has no base system.

The `Carried*` fields come from `CarryRegistry`. `PlayerService` requires
`CarryRegistry` at load time, so the carry system is a **hard** dependency of
the push format even if you never install a carry feature.

---

## 10. `CleanupPlayer` vs `WipeUser` — they are not the same

| | `CleanupPlayer(userId)` | `WipeUser(userId)` |
|---|---|---|
| When | player leaves | admin command / reset |
| Profile | **released** | **erased** |
| Data | saved | gone |
| Rejoin | profile reloads with the same data | fresh template |

`CleanupPlayer` must be called on every leave path, including failure paths.
If it is not called, the profile stays session-locked and the player cannot
rejoin for the lock duration.

---

## 11. `GetLoadedSignal` is a late `require`

```lua
local Signals = require(script.Parent.Parent.ReplicatedStorage.Utility.Signals)
```

is **inside** `GetLoadedSignal`, not at the top of the file. That is a
deliberate lazy require to break a circular dependency. Do not hoist it.

---

## 12. `SetAnimalPoolSettlementHandler` is the income hand-off

`PlayerService.SetAnimalPoolSettlementHandler(fn)` is how the income system
pays out an animal's cash pool. The handler receives
`(userId, pool)` and is called when a pool is settled (on sale, on collect,
or on leave).

If you install `Economy`/`Income` but forget this setter, cash pools
accumulate and are never paid. `PlayerService` does not error — the pools
just silently grow.

---

## 13. The `_Test*` seams exist and are used

`PlayerService` exposes test seams (`_TestReset`, and friends) that the
library's specs rely on. `Systems/PlayerData/Tests/` has two specs:
`PlayerService.spec.lua` and `PersistenceAudit.spec.lua`.

**Neither spec has ever been executed as committed** — see
[`../../Tests/README.md`](../../Tests/README.md) for the three runner defects
that block the suite. Treat "N cases" in a system's docs as "N cases written
against this code", not "N observed passing".

---

## 14. Known issues in this system (recorded, not fixed)

| Issue | Where | Note |
|---|---|---|
| `PlayerDataType.lua` is stale — it does not match the live template | `ReplicatedStorage/Types/PlayerDataType.lua` | Do not use it as the schema reference. `STUDIO_PROFILE_TEMPLATE` in `PlayerService.lua` is authoritative. |
| The `DataStore` name embeds the source game's `p7_` prefix | `PlayerService.lua` | Rename before shipping a new game. |
| `Tutorial.Step = 'BuyEgg'` is this game's step name | template | Replace with your own. |

These are recorded in [`../../SECURITY_NOTES.md`](../../SECURITY_NOTES.md) §5.
They were **not** fixed, because this task is an extraction, not a production
change.

---

## Document map

| Document | Contents |
|---|---|
| [`README.md`](README.md) | What the system does, entry points, file list |
| [`MEMORY.md`](MEMORY.md) | This file — the non-obvious facts |
| [`Config.lua`](Config.lua) | Every tunable the system reads, with ranges |
| [`Dependencies.md`](Dependencies.md) | Exact requires, remotes, profile fields, DataStore |
| [`Setup.md`](Setup.md) | How to install it in a new game |
| [`API.md`](API.md) | Every public function, with signatures |
| [`../../Tests/README.md`](../../Tests/README.md) | How to run the specs, and what is not covered |
