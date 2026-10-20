# Stealing — engineering notes

## Purpose, in one line

`StealService` moves an egg or animal from player A's base to player B's
base, server-authoritatively, by reusing the game's existing carry, slot,
and profile systems — with no second carry, no second slot, no second
profile, and no lost/duplicated item on any failure path.

Source game: Brainrot Arena (`p-7`). Files: `Source/ServerScriptService/Steal/StealService.lua`
(1509 lines), `Source/ReplicatedStorage/Config/World/Stealing.lua` (93 lines).

---

## How it actually works, step by step

### 0. The Steal prompt

The prompt is **not** installed by this system. `CarryPrompts.InstallPickupPrompt`
(the single funnel every slotted object goes through) calls
`CarryPrompts.InstallStealPrompt(model, occupantId, kind, ownerUserId)`
(`CarryPrompts.lua:334`). The Steal prompt:

- is named `StealPrompt`, binds `E`, `MaxActivationDistance = 8`,
  `HoldDuration = 2.5`, `RequiresLineOfSight = false`, `UIOffsetY = 0`;
- is installed **disabled** (`prompt.Enabled = false`,
  `CarryPrompts.lua:479`) — fail-closed, so the owner never sees a Steal
  flash before the client `PromptOwnerFilter` tick;
- carries `ownerUserId` and `stealPrompt = true` attributes;
- fires `_stealCallback(player, occupantId, stealKind)`.

`StealService.Init()` (line 402) is what connects that callback:

```lua
CarryPrompts.SetStealPromptCallback(function(player, occupantId, kind)
    StealService.TrySteal(player, occupantId, kind)
end)
```

`kind` is normalized in `CarryPrompts` to `'egg'` or `'animal'`
(`CarryPrompts.lua:452`).

### 1. `TrySteal(player, occupantId, kind)` — line 657

Order of gates, **exactly**:

1. `Validation.LivePlayer(player)` → `'invalid-player'`.
2. `Validation.CanPlayerInteract(player)` → `'player-not-live'`. The `Player`
   instance survives death, so the *current character* must be live. This
   check is FIRST — before the rate limit and before any state read.
3. **Rate limit** (line 672): `os.clock()` vs `_lastAttempt[thiefId]`, window
   `StealConfig.Cooldown` (0.5 s) → `'rate-limited'` + `NotifyWarning('Steal_Cooldown')`.
   `_lastAttempt[thiefId] = now` is set on **every** attempt, success or
   failure.
4. `occupantId` must be a non-empty string → `'invalid-target'` +
   `General_Generic`.
5. `CanSteal(thiefId, occupantId, kind)` — pure, no mutation, no yields.
   Any rejection → `_stealRejectReason(code)` → a canonical `Steal_*` catalog
   id (or `General_Generic`).
6. Re-read `BaseService.GetBaseByOwner(thiefId)` → `'no-thief-base'`.

### 2. `CanSteal(thiefUserId, occupantId, kind, thiefPosOverride?)` — line 455

Pure. Returns `{ ok = true, record, slot, ownerId }` or
`{ ok = false, error = <code> }`. Check order:

| # | Check | Error code |
|---|---|---|
| 1 | `Validation.IsValidPlayerUserId(thiefUserId)` | `invalid-player` |
| 2 | `occupantId` non-empty string | `invalid-target` |
| 3 | `kind` is `'egg'` or `'animal'` | `wrong-kind` |
| 4 | `CarryRegistry.IsCarrying(thiefUserId)` | `already-carrying` |
| 5 | record resolves (`SpawnService.GetEgg` / `AnimalService.Get`) | `target-gone` |
| 6 | `record._mutex` | `in-progress` |
| 7 | `ArenaService.IsAnimalRaidLocked(occupantId)` (animals only) | `raid-locked` |
| 8 | state: egg must be `'Placed'`; animal must be `'Slotted'` or `'Placed'` | `not-stealable-state` |
| 9 | `record.carriedBy ~= nil or record.stolenBy ~= nil` | `already-carried` |
| 10 | `record.slotId` is a string; slot resolves with a `part` | `not-slotted` |
| 11 | `slot.state == 'Occupied' and slot.occupantId == record.uniqueId and slot.occupantKind == kind` | `slot-race` |
| 12 | `slot.ownerUserId` is a valid userId | `target-gone` |
| 13 | `record.ownerUserId == slot.ownerUserId` | `owner-mismatch` |
| 14 | `slot.ownerUserId ~= thiefUserId` | `own-object` |
| 15 | thief owns a base | `no-thief-base` |
| 16 | `SlotService.GetFreeSlot(thiefUserId)` is non-nil | `no-destination` |
| 17 | HRP (or `thiefPosOverride`) → `slot.part.Position` ≤ max distance | `too-far` |
| 18 | model is a parented `Model` with a `PrimaryPart` | `target-gone` |
| — | no HRP and no override | `no-character` |

**Distance**: `_maxDistanceFor(kind)` (line 145) returns
`PromptConfig.AnimalPickup.MaxActivationDistance` (8) for animals and
`PromptConfig.CarryMaxDistance` (8) for eggs. Both are 8 today.

**Base Lock is NOT a gate.** The comment at lines 549-554 is explicit: the
lock is an escape restriction enforced physically (locked lasers collide in
the `BaseLock_X` collision group), so a thief cannot leave a locked base
with the item. Never re-add a locked-base rejection.

**The `own-object` check must stay above every mutating step.** `CanSteal` is
pure and `TrySteal` mutates only after `check.ok`, so a rejection commits
ZERO state (no reservation, no carry, no prompt side effects). The spec
asserts this explicitly (`StealService.spec.lua:478-511`).

### 3. The atomic commit block — `TrySteal`, lines 706-751

```lua
record._mutex = true
if not SlotService.DemoteSlotToReserved(slot.id) then
    record._mutex = false
    return { success = false, error = 'slot-race' }
end
```

`DemoteSlotToReserved` is the **atomic reservation primitive**: `Occupied →
Reserved`. Exactly one of `{B-steal, C-steal, A-grab}` can win; the losers
get `'slot-race'`. There are **no yields** before or during, and
`CarryController.Start` is yield-free, so nothing can interleave between the
reservation and the carry attach.

Then, in the same yield-free block, the **destination** is reserved:

```lua
local destSlot = SlotService.GetFreeSlot(thiefId)
if not destSlot or destSlot.state ~= SlotType.State.Empty then ... 'no-destination' end
if not SlotService.ReserveSlot(destSlot.id) then ... 'no-destination' end
destSlotId = destSlot.id
```

`destSlotId` is stored in the carry item's `steal.destSlotId`. The
`Empty`-state re-check exists because `ReserveSlot` is a no-op success on an
already-`Reserved` slot (that path belongs to same-slot returns).

`_failStealStart(err)` (line 723) is the local rollback helper: release the
destination, re-`Occupy` the victim's slot, restore `record.state` to
`'Placed'`/`'Slotted'`, clear `carriedBy` / `originalSlotId` / `stolenBy` /
`_mutex`, return `{ success = false, error = err }`.

### 4. Carry attach and commit — lines 753-848

```lua
record.state = 'Opening'   -- egg
record.state = 'Carried'   -- animal
record.carriedBy = thiefId
record.originalSlotId = slot.id
record.stolenBy = thiefId
record.controller = nil
record.controllerType = nil

local okStart, controller = pcall(CarryController.Start, record, thiefId, character, player)
```

Then `CarryRegistry.Set(thiefId, { kind, record, originalSlotId, startedAt, steal = {...} })`.
If `Set` fails (the player started carrying in between), `CarryController.Stop`
runs and `_failStealStart('carry-failed')` restores everything.

Then the side effects, in order:

- `_slowThiefForSteal(thiefId)` — snapshots `Humanoid.WalkSpeed` into
  `_thiefSpeed[thiefId]` and sets `WalkSpeed = snapshot * 0.6`. **Relative**,
  so an admin-set speed survives the round trip. A missing/invalid
  snapshot means the thief is never slowed and the restore is a no-op.
- `_applyStealPresentation(record, kindStr)` — `AnimalOverhead.SetStolen(record, true)`
  for animals only. The animal's name label becomes `STOLEN` (red); the
  record's `displayName` is never changed.
- `CarryPrompts.RemovePromptsFromModel(model)` — the carried model shows no
  prompts.
- `CarryPrompts.DisablePickupHatchPromptsForBase(thiefBase)` — the thief's
  own base has no Pickup/Hatch prompts while carrying.
- `StandPresentation.Unbind(model)` for eggs.
- `_push(player)` — `playerServiceRef.PushState(player, BaseService.Snapshot(player.UserId))`.
  This is what makes the client see `CarriedSteal = true` (via
  `CarryRegistry.Snapshot`).
- `NotificationService.NotifySuccess(player, 'Steal_Success', { AnimalName, Rarity })`.
- The victim: `_notify(ownerPlayer, 'Warning', _victimRobberyText(...))` and
  `_playStealSfxForOwner(ownerId)`; then `_push(ownerPlayer)`.
- `record._mutex = false` — released at the very end.

### 5. Delivery — touch-only

`StealService.Start()` (line 413) connects one `Touched` handler per base
**collector** (a `BasePart` named by `base.collector`). Idempotent via
`_touchedConnected[collector]`. The handler:

1. resolves the player from the hit (`_playerFromHit` walks up the
   ancestry looking for a `Player`);
2. `StealService.IsStealCarry(player)` — must be a steal carry;
3. the collector's base must be the **thief's own** base
   (`BaseService.GetBaseByOwner(player.UserId).id == _collectorBaseId[collector]`);
4. `StealService.TryComplete(player)`.

There is **no Deliver prompt**. `CarryPrompts.InstallDeliverPrompt`,
`RemoveDeliverPrompt`, `SetDeliverPromptCallback`, and
`Prompts.Carry.ActionText.Deliver` were all **removed** — the spec asserts
their absence (`StealService.spec.lua:1287-1290`).

### 6. `TryComplete(player)` — line 861

Order of gates:

1. `Validation.LivePlayer` → `invalid-player`.
2. `Validation.CanPlayerInteract` → `player-not-live`.
3. `CarryRegistry.Get(thiefId)` has a `steal` table → `not-a-steal`.
4. **`player.Character == item.steal.carryCharacter`** → else
   `RollbackCarried(thiefId, 'character-changed')` and `character-changed`.
   This is the respawn guard: same `UserId`, new `Model`.
5. `record` is a table with a string `uniqueId` → `target-gone`.
6. `record._mutex` → `in-progress`.
7. **Liveness**: `_resolveRecord(kindStr, record.uniqueId) == record` →
   else `target-gone`. A replacement sharing the slot can never be
   transferred.
8. Model still parented → else `RollbackCarried('target-destroyed')` +
   `target-gone`.
9. Thief's base and collector exist → `no-thief-base` / `no-collector`.
10. **Server-side proximity**: `HRP → collector.Position` ≤
    `collector.Size.Magnitude / 2 + PromptConfig.CarryMaxDistance` → else
    `too-far-from-collector`. Neither the prompt range nor `Touched` alone
    is the authority.
11. `item.steal.originalOwnerUserId` is a number and ≠ the thief, and
    `record.ownerUserId == origOwner` → else `owner-mismatch`.
12. **Destination**: use the slot reserved at steal start if it is still
    `Reserved` and still owned by the thief; otherwise fall back to a fresh
    `GetFreeSlot` + `ReserveSlot` (and update `item.steal.destSlotId`).
    Neither available → `no-slot` (+ `Steal_BaseFull` + push both sides).
13. `record._mutex = true`; `_failComplete(err)` releases the fresh
    reservation, clears the mutex, and pushes **both** sides.

Then the transfer, in this exact order:

```lua
-- 1. Snapshot A's profile record BEFORE removal.
--    Egg:    { Rarity, Mutations, Trait }
--    Animal: { DefId, Level, XP, CashPool, Trait, Mutations }
-- 2. Seat the destination FIRST (OccupySlot(fresh.id, uniqueId, kind)).
--    Failure here mutates NOTHING -> 'slot-race', retryable.
-- 3. Add(B)  -> AddEgg / AddAnimal with the snapshot.
--    Failure -> 'transfer-failed' (nothing moved).
-- 4. Remove(A) -> RemoveEgg / RemoveAnimal.
--    Failure -> UNDO the Add (Remove from B) and return 'transfer-failed'.
-- 5. Release the ORIGINAL slot (Reserved -> Empty). Failure is non-fatal.
-- 6. Stop the carry, flip the runtime record:
--        record.ownerUserId = thiefId
--        record.slotId      = fresh.id
--        record.state       = 'Placed' (egg) / 'Slotted' (animal)
-- 7. Seat the model:
--        Egg:    re-home into SpawnService.GetActiveContainer(),
--                HoverMath.Settle, StandPresentation.Bind,
--                SpawnService.InstallHatchPrompt(record, freshSlot, thiefId)
--        Animal: AnimalService.SettleModelAtSlot(record, freshSlot)
-- 8. SlotService.RefreshDisplays(origSlotId) and (fresh.id).
-- 9. CarryRegistry.Clear(thiefId).
-- 10. CarryPrompts.EnablePickupHatchPromptsForBase(thiefBase).
-- 11. record._mutex = false.
-- 12. Push the thief and the owner; notify the owner (robbery text).
-- 13. NotificationService.NotifySuccess(player, 'Steal_DeliverySuccess', {...}).
-- 14. FunnelService:LogStep(player, 'Social', 'StealSucceeded', { kind }).
-- 15. _clearStealPresentation(record); _restoreThiefSpeed(thiefId).
-- 16. return { success = true, slotId = fresh.id }
```

**Why occupy-first** (comment at lines 1020-1036): the old order
(profiles → release orig → occupy fresh) left a split-brain when `Occupy`
failed — B's profile owned the `Id` while the runtime record still named A,
was still carried, and the source slot was already `Empty`. That state
rejects upgrades on both sides, strands B's profile `SlotId` on a `Reserved`
slot, and mis-seats any later rollback onto the wrong base.

### 7. `RollbackCarried(thiefUserId, reason?)` — line 1207

Runtime-only (the profile never moved). Sequence:

1. `CarryRegistry.Get` must have a `steal` table → else `not-a-steal`.
2. `record` must be a table → else clear the carry, push, `target-gone`.
3. Stop the carry controller; `CarryRegistry.Clear(thiefUserId)`.
4. Release the destination reservation — **only if the slot is still
   `Reserved`** (never touch an `Occupied` slot).
5. Push the thief immediately (drops the client's steal suppression).
6. `record.stolenBy = nil`, `record.carriedBy = nil`,
   `record.state = 'Placed'`/`'Slotted'`.
7. `CarryPrompts.RemovePlacePromptsForBase(thiefBase)` +
   `CarryPrompts.EnablePickupHatchPromptsForBase(thiefBase)`.
8. **Post-commit guard** (lines 1315-1339): if
   `record.ownerUserId == thiefUserId` and `record.slotId` names an
   `Occupied` slot with this occupant, the transfer already committed —
   finish the seating idempotently instead of reverting. Returns
   `{ success = true, completed = true }`.
9. **Tier-1** (line 1341): the original slot is still `Reserved` and still
   owned by the original owner → `OccupySlot` it, seat, refresh displays,
   push both, restore speed → `{ success = true }`.
10. **Tier-2** (line 1363): any `Empty` slot on the **original owner's**
    base → `ReserveSlot` + `OccupySlot`, re-point the profile record with
    `SetEggSlot` / `SetAnimalSlot` (failure is a warning only), seat →
    `{ success = true }`.
11. **Tier-3** (line 1408): nowhere to seat → `record.slotId = nil`;
    animals go to `state = 'Recovering'` and their model is reparented into
    `Workspace/Animals/Recovering`; eggs park `state = 'Placed'` with no
    slot in the `ActiveEggs` container. Prompts are removed. A loud
    `Debug.Warn`. → `{ success = true, parked = true }`.

Every tier ends with `_clearStealPresentation` + `_restoreThiefSpeed`.

**Tier-1 almost always succeeds** because the original slot stays `Reserved`
for the whole carry. That is also why a rejoining owner auto-skips the
record: `RestorePlayerBase`'s occupied branch finds a `Reserved` slot — no
second model, no extra code.

### 8. Hooks

| Hook | Called by | Purpose |
|---|---|---|
| `RollbackIfStealing(userId, reason?)` | `bootstrap.server.lua:1062` (`Humanoid.Died`), `:1121` (`CharacterRemoving`), `:1386` (studio cmd) | Thief side. `true` means "was a steal, already handled" — the caller must skip the generic owner-assuming recovery. |
| `RollbackStolenTarget(kind, uniqueId, reason?)` | `AnimalService.lua:2922` (`'owner-leaving'`), `EggService.lua:906` (`'owner-leaving'`), `RebirthService.lua:913/918` (`'rebirth'`) | Owner side. Recovers the object home **before** the base teardown. |

---

## Public API surface (exact)

### `StealService` (module `ServerScriptService.Steal.StealService`)

```lua
StealService.SetPlayerService(svc: any)                              -- line 398
StealService.Init()                                                   -- line 402
StealService.Start()                                                  -- line 413
StealService.ForgetPlayer(userId: number)                             -- line 442
StealService.CanSteal(
    thiefUserId: number,
    occupantId: string,
    kind: string?,
    thiefPosOverride: Vector3?
): { [string]: any }                                                   -- line 455
StealService.TrySteal(player: Player, occupantId: string, kind: string?): { [string]: any }  -- line 657
StealService.TryComplete(player: Player): { [string]: any }            -- line 861
StealService.RollbackCarried(thiefUserId: number, reason: string?): { [string]: any }  -- line 1207
StealService.RollbackIfStealing(userId: number, reason: string?): boolean  -- line 1463
StealService.RollbackStolenTarget(kind: string, uniqueId: string, reason: string?): boolean  -- line 1483
StealService.IsStolenRecord(kind: string, uniqueId: string): boolean  -- line 371
StealService.IsStealCarry(playerOrUserId: any): boolean                -- line 391
StealService._TestVictimText(thiefName: string, animalName: string, rarity: string?): string  -- line 279
```

The module returns `table.freeze(StealService)` (line 1509).

### `Stealing` (config module `ReplicatedStorage.Config.World.Stealing`)

```lua
Stealing.Cooldown: number                      -- 0.5
Stealing.AlertCleanupPad: number               -- 0.5
Stealing.AlertFallbackCleanup: number          -- 3
Stealing.StealSpeedMultiplier: number          -- 0.6
Stealing.StealPresentation: {
    FOVMultiplier: number,                     -- 0.9
    FOVTweenTime: number,                      -- 0.3
}
Stealing.Validate(): { string }                -- line 59
```

Returns `table.freeze(Stealing)` (line 93).

### Private (NOT exported — do not call)

`_playerFromHit`, `_characterHrp`, `_maxDistanceFor`, `_resolveRecord`,
`_thiefCollector`, `_notify`, `_stealRejectReason`, `_stealDisplayName`,
`_stealRarity`, `_victimRobberyTextFor`, `_victimRobberyText`, `_push`,
`_playStealSfxForOwner`, `_slowThiefForSteal`, `_restoreThiefSpeed`,
`_applyStealPresentation`, `_clearStealPresentation`, and the local
`_failStealStart` / `_failComplete` / `_seatDestination` / `_seatAt` /
`_pushRestored` closures.

---

## Invariants the code enforces

1. **One carry.** A steal is a `CarryRegistry` item with a `steal` table.
   `CanSteal` rejects if `CarryRegistry.IsCarrying(thiefUserId)`.
2. **One profile copy.** Before the transfer, A's profile holds the record
   and `record.ownerUserId == A`. B receives nothing until `Add(B)` runs.
3. **Same id across the transfer.** B's record has the same `Id`. Only
   `SlotId` changes.
4. **Atomic steal-start.** `DemoteSlotToReserved` + `ReserveSlot(dest)` run
   with **no yields** between them, so exactly one racer wins.
5. **A steal-carry can never be placed.** The Place paths in `EggService` /
   `AnimalService` reject a steal item with `'steal-in-progress'` (the spec
   asserts this for `PlaceEgg`).
6. **The original slot stays `Reserved` for the whole carry.** That is what
   makes tier-1 rollback almost always succeed.
7. **A dead/dying/respawning player has zero interaction authority.**
   `Validation.CanPlayerInteract` gates both `TrySteal` and `TryComplete`.
8. **The completing character must be the same Model instance.** Guarded by
   `item.steal.carryCharacter`.
9. **Every exit restores the thief's WalkSpeed** to the captured pre-steal
   value (or leaves it alone if there was no snapshot).
10. **Every exit clears `carriedBy`, `stolenBy`, `originalSlotId` and the
    `steal` table** (the carry is cleared from the registry).
11. **The destination slot is never overwritten.** It is `Reserved` (not
    `Occupied`) and `OccupySlot` is only called on it by this system.
12. **No silent remove-then-fail.** If `Remove(A)` fails, the `Add(B)` is
    undone before the error surfaces.
13. **The `Debug` tag is `'ST'`.**

---

## Failure / edge-case behaviour

| Situation | Result |
|---|---|
| Non-live `Player` | `{success=false, error='invalid-player'}` (no notification) |
| Dead / dying / respawning player | `{success=false, error='player-not-live'}` (no notification) |
| Two requests inside 0.5 s | `{success=false, error='rate-limited'}` + `Steal_Cooldown` toast. **The window is consumed by the first attempt, success or failure.** |
| Stealing your own object | `{success=false, error='own-object'}` + `Steal_OwnAnimal`. **Zero state change.** |
| Target already carried / in flight / opening | `not-stealable-state` / `already-carried` → `Steal_TargetBusy` |
| Target in an active arena raid | `raid-locked` → `Steal_TargetBusy` |
| Victim's slot was demoted by someone else | `slot-race` → `Steal_TargetBusy` |
| Thief's base is full | `no-destination` → `Steal_BaseFull`. Checked **before** any mutation, and again atomically at commit. |
| Thief's base vanished between start and delivery | `no-thief-base` |
| Thief's collector missing / not a `BasePart` | `no-collector` |
| Thief too far from the collector | `too-far-from-collector` (radius = `collector.Size.Magnitude/2 + 8`) |
| Thief respawned mid-carry | `character-changed` → the carry is **rolled back automatically** |
| Model destroyed mid-carry | `target-gone` → the carry is **rolled back automatically** |
| No free slot at delivery | `no-slot` + `Steal_BaseFull`. **The carry is kept** — retryable. |
| Destination `OccupySlot` fails at delivery | `slot-race`. **Nothing moved** (profiles intact, source slot still `Reserved`, carry kept) — retryable. |
| `Add(B)` fails | `transfer-failed`. Nothing moved. |
| `Remove(A)` fails | `transfer-failed`. The `Add(B)` is **undone**. A still owns everything. |
| `ReleaseSlot(original)` fails | **Non-fatal** — a `Debug.Warn` only. The transfer stands. |
| The owner is offline | No victim alert, no SFX. `Debug.Log('owner offline, robbery alert skipped')`. The steal still succeeds. |
| The SFX asset is missing / malformed / empty `SoundId` | Silent no-op + `Debug.Warn`. The steal still succeeds. |
| The victim's base is destroyed mid-carry | Tier-2/tier-3 rollback: the object is re-homed or parked; the profile is preserved. |
| A second `RollbackCarried` for the same carry | `{success=false, error='not-a-steal'}` — a safe no-op. |
| `RollbackCarried` with a non-table record | Clears the carry, pushes, `{success=false, error='target-gone'}`. |

### Notification mapping (`_stealRejectReason`, line 184)

| Error code | Catalog id |
|---|---|
| `base-locked` | `Steal_BaseLocked` |
| `no-destination` | `Steal_BaseFull` |
| `own-object` | `Steal_OwnAnimal` |
| `already-carrying` | `Steal_AlreadyCarrying` |
| `too-far` | `Steal_TooFar` |
| `in-progress`, `already-carried`, `slot-race`, `raid-locked` | `Steal_TargetBusy` |
| `target-gone`, `invalid-target`, `not-stealable-state`, `not-slotted`, `owner-mismatch` | `Steal_TargetGone` |
| anything else | `General_Generic` |

Codes that **never** reach this mapper: `invalid-player` and `rate-limited`
(the latter is notified directly as `Steal_Cooldown` at the call site).

Codes the mapper does **not** cover (so they fall to `General_Generic`):
`wrong-kind`, `no-thief-base`, `no-character`, `not-a-steal`,
`character-changed`, `no-collector`, `too-far-from-collector`, `no-slot`,
`record-gone`, `transfer-failed`, `carry-failed`, `player-not-live`.

### Error codes returned by `TrySteal`

`invalid-player`, `player-not-live`, `rate-limited`, `invalid-target`,
`wrong-kind`, `already-carrying`, `target-gone`, `in-progress`,
`raid-locked`, `not-stealable-state`, `already-carried`, `not-slotted`,
`slot-race`, `owner-mismatch`, `own-object`, `no-thief-base`,
`no-destination`, `no-character`, `carry-failed`.

### Error codes returned by `TryComplete`

`invalid-player`, `player-not-live`, `not-a-steal`, `character-changed`,
`target-gone`, `in-progress`, `no-thief-base`, `no-collector`,
`no-character`, `too-far-from-collector`, `owner-mismatch`, `no-slot`,
`slot-race`, `record-gone`, `transfer-failed`.

---

## Gotchas that would bite you

1. **`StealService.ForgetPlayer` throws** — `_thiefSpeed` is declared at
   line 587 but read at line 444, so line 444 indexes a **global** that is
   `nil`. Production never calls it (only the spec does, at
   `StealService.spec.lua:215-216`). Move the declaration up next to
   `_lastAttempt` (line 115) to fix.
2. **`Start()` is one-shot.** Only the collectors that exist when it runs
   get `Touched` routing. A base registered later is never a delivery
   target. There is no re-arm hook.
3. **`_playStealSfxForOwner` parents the clone to the victim's `PlayerGui`.**
   That is the "only the victim hears it" mechanism, not a bug — but it means
   the sound does not exist for the thief or for bystanders, and it depends
   on the owner having a `PlayerGui` and being online.
4. **The victim is notified twice** on a successful steal (start + delivery)
   with the same robbery sentence. The second one is at
   `StealService.lua:1167`.
5. **`record.stolenBy` is a cache flag, not the authority.** The
   `CarryRegistry` item's `steal` table is authoritative. `CanSteal` checks
   `stolenBy` only as a "is it in flight" guard.
6. **`_stealRejectReason` has no mapping for `wrong-kind`, `no-character`,
   `no-thief-base`, or `player-not-live`** — they surface as
   `General_Generic`. If you add a new `CanSteal` code, add a mapping.
7. **`Prompts.Steal.HoldDuration` is `2.5`, not `0`.** The config comment
   says *"INSTANT (hold 0)"* — the comment is stale. The value wins.
8. **`Stealing.AlertCleanupPad` is not validated** by `Stealing.Validate()`.
   A negative value destroys the SFX clone before it plays.
9. **`Debug` tag `'ST'` is not in the documented tag list**
   (`Config/Systems/Debug.lua:51` lists `BS, LB, BR, PS, RM, CL, AO, CP`).
   A non-empty `Debug.Tags` whitelist without `'ST'` silently drops every
   steal log line.
10. **The distance check measures to `slot.part.Position`, not to the
    model's visual bounds.** A model that overhangs its slot is effectively
    farther away than it looks.
11. **`_resolveRecord` uses `SpawnService.GetEgg` / `AnimalService.Get`.**
    A record that exists in the profile but not in the runtime registry is
    `target-gone` — the steal refuses, it does not "repair" the record.
12. **`_thiefCollector` returns `(base, nil)` when the collector is not a
    `BasePart`.** `TryComplete` then fails with `no-collector`, and the
    carry stays until a rollback. A malformed base silently bricks
    delivery.
13. **The `steal` metadata table's `carryCharacter` is the ONLY respawn
    guard.** `UserId` survives respawns; the `Model` instance does not.
    Drop this field and a respawned player can complete a pre-death
    transaction.
14. **`CarryRegistry.Set` unequips the player's tools** as a side effect
    (it calls `Humanoid:UnequipTools()`). A steal therefore unequips the
    thief's tool.
15. **The `_mutex` flag is a plain boolean on the record**, not a real
    mutex. It is set and cleared manually on every path; a thrown error
    between set and clear would leave it stuck (the code avoids this by
    keeping the mutating block yield-free and wrapped in `pcall`).
16. **The `Egg` state's steal value is `'Opening'`** — the same value the
    owner's own grab uses, so `Hatch`/`Sell` reject it for free. The
    animal's steal value is `'Carried'`.
17. **`RollbackCarried` never deletes and never duplicates.** Tier-3 parks
    the object; the profile stays intact so a rejoin respawns it.
18. **`CanSteal`'s `thiefPosOverride` is a test-only seam** that bypasses
    the HRP read. Nothing in production passes it.

---

## What to change to reuse it

| Change | Where | Why |
|---|---|---|
| Replace the state strings | `StealService.lua:490,494,729,732,754,756,1121,1124,1254,1257,1417,1433` and the `SpawnService` / `AnimalService` / `EggService` / `AnimalOverhead` equivalents | `'Placed' / 'Slotted' / 'Opening' / 'Carried' / 'Recovering'` are literals, not an enum. |
| Replace the `slotId` prefix | `ReplicatedStorage/Types/SlotType.lua` (`BuildId`) | The `p7:` prefix flows into `record.slotId` and `originalSlotId`. |
| Replace the notification ids | `Config/Presentation/Messages.lua` | The system sends `Steal_Success`, `Steal_DeliverySuccess`, `Steal_Cooldown`, `Steal_OwnAnimal`, `Steal_AlreadyCarrying`, `Steal_BaseFull`, `Steal_BaseLocked`, `Steal_TooFar`, `Steal_TargetBusy`, `Steal_TargetGone`, `General_Generic`. A missing id is dropped by the notification layer. |
| Re-author the SFX | `ServerStorage/Assets/Sfx/Stealing` | The name comes from `Audio.StealAlertSoundName`; a missing asset is a silent no-op. |
| Replace the `Debug` tag | `StealService.lua` (all `Debug.Log('ST', ...)` / `Debug.Warn('ST', ...)`) | `'ST'` is not in the documented tag list. |
| Provide the profile authority | `StealService.SetPlayerService(...)` | Needs `GetEggs`, `GetAnimals`, `AddEgg`, `AddAnimal`, `RemoveEgg`, `RemoveAnimal`, `SetEggSlot`, `SetAnimalSlot`, `PushState`, `Notify`. All are called inside `pcall` except the transfer calls, which are checked for a `false` return. |
| Provide the arena raid lock | `ArenaService.IsAnimalRaidLocked(uniqueId)` | Or delete the check (animals mid-raid become stealable). |
| Provide `StandPresentation` / `AnimalOverhead` / `HoverMath` | the eggs/animals systems | Egg unbinding/binding, the `STOLEN` overhead, and the egg seating math. |
| Provide the `Collector` part | `BaseService.RegisterBases` | A base without a `BasePart` collector is never a delivery target. |
| Fix `ForgetPlayer` | `StealService.lua:442-445` + `:587` | Move the `_thiefSpeed` declaration up. |
| Re-arm collector routing for late bases | `StealService.Start()` | Call it again after a late `RegisterBases` — it is idempotent. |

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
