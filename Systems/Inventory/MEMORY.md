# Inventory — engineering notes

## Purpose, in one line

A per-base **unified slot pool** (eggs and animals share it) with a
server-authoritative three-state machine (`Empty / Reserved / Occupied`),
plus the two server endpoints that read and mutate it (the prompt-action
dispatcher and the per-slot upgrade menu).

---

## How it actually works

### The slot record and who owns it

`BaseService` (not in this library) owns the **records**:
`base.slots[1..Bases.Slots.Count]`, one per stand. `SlotService` owns the
**index** and the **transitions**. It never creates a slot record; it
mutates the ones BaseService hands it.

Three indexes, all inside `SlotService`:

| Index | Contents | Used by |
|---|---|---|
| `slotById` | every slot, normal **and** arena | `_findSlotById`, every transition |
| `slotsByBase` | normal slots only | `GetFreeSlot`, `SnapshotBaseSlots`, `FindSlotByOccupant` |
| `arenaSlotsByBase` | arena slots only | `UnregisterArenaSlots`, arena-aware lookups |
| `baseByOwner` | `userId → base` | `GetFreeSlot`, `ReleaseReservedSlotForUser` |

The arena split is the important bit: arena slots join `slotById` (so
transitions and id lookups work on them unchanged) but are **excluded from
`slotsByBase`** so that free-slot search, HUD snapshots, and egg placement
never see them.

### Transitions, exactly

All four write methods take a **slot id**, resolve it, and check the
`_mutex` flag. The mutex is a plain boolean on the record, set to `true`
for the duration of the mutation and back to `false` after — there is no
`task.wait` inside a transition, so it is never actually contended within
a single-threaded Roblox scheduler; it guards against a *re-entrant* call
from a callback fired by the transition (e.g. the display hook re-entering
`ReleaseSlot`).

| Method | Legal from | To | Side effects |
|---|---|---|---|
| `ReserveSlot(id)` | `Empty` | `Reserved` | None. **Already `Reserved` → returns `true` (no-op success).** |
| `DemoteSlotToReserved(id)` | `Occupied` | `Reserved` | Keeps `occupantId`/`occupantKind`. Fires both display hooks. |
| `OccupySlot(id, occId, occKind?)` | `Reserved` | `Occupied` | Sets `occupantId`/`occupantKind`. Fires occupied-count `+1`, then both display hooks. |
| `ReleaseSlot(id)` | anything | `Empty` | Clears `occupantId`/`occupantKind`. **Idempotent on `Empty` (returns `true`).** Fires count `-1` + display hooks *only if* it was `Occupied` or had an occupant. |

The illegal-direction cases all return `false` and change nothing.

`ReleaseReservedSlotForUser(userId, index)` is the odd one out: it takes a
**1-based index into the owner's base**, not a slot id, and it is the only
mutation that **skips the mutex and both display hooks**.

### The demote/reserve dance

"Pick up the thing in slot 3" is `DemoteSlotToReserved(3)` — the slot keeps
naming its occupant so the recovery path knows what was there. "Put it
back in slot 3" is `ReserveSlot(3)` (a no-op because it is already
`Reserved`) then `OccupySlot(3, sameId, sameKind)`. "Put it in slot 4" is
`ReleaseSlot(3)` then `ReserveSlot(4)` + `OccupySlot(4, ...)`.

### Display hooks

Three injectable callbacks, each stored in a **local upvalue** (not on the
frozen module table):

- `SetOccupiedCountCallback(fn)` — `fn(slot, delta)` with delta `+1`/`-1`.
  Keeps `base._occupiedCount` in sync.
- `SetPoolDisplayCallback(fn)` — `fn(slot)`. Republishes the cash-pool
  attribute and the money label. Fired on transitions **into or out of
  `Occupied`** only — `Empty ↔ Reserved` never changes the displayed value
  (both show `0`), so those do not fire it.
- `SetStandDisplayCallback(fn)` — `fn(slot)`. Repaints the stand's
  direct-upgrade readout. Fired on the same transitions **plus**
  `RebaseSlotIds`.

`RefreshDisplays(slotId)` re-derives one slot's presentation through both
display hooks. It is used after multi-step transactions (a steal
completing, a rollback) whose intermediate transitions fired while the
record was still mid-mutation, so the final paint must be re-derived
*after* the record is final. Returns `false` for an unknown slot id.

### Slot id re-stamping

Slot ids are `p7:<userId>:slot:<index>`. The `userId` segment means the
id **changes when the base is assigned to a player**. `RebaseSlotIds(base)`
is the fix-up: it drops every stale `slotById` entry pointing at the slot
under an old id, re-adds it under the new id, re-stamps the Studio
`UpgradeButton`'s `slotId` attribute, and fires the stand display hook.

`UnregisterArenaSlots` deliberately drops entries **by record identity**
(table identity, not id string) because the assign path re-stamps ids
*before* the record array is replaced — key matching would miss.

### The Studio menu button stamp

`_stampMenuSlotId` sets the attribute `slotId` on
`Stand.Slot.MenuPart.MenuGui.UpgradeButton` (the button is a *direct*
child of `MenuGui`; the legacy `MenuGui → Frame → UpgradeButton` shape is
also accepted because the search is recursive). It creates, renames, and
destroys **nothing** — attributes only. Missing parts are a silent no-op,
except a missing `MenuPart` which warns once per part.

The attribute is a **routing hint only**. The server revalidates
ownership and occupancy on every request regardless, so a missing or stale
stamp fails safe (reject).

### The action dispatcher

`SlotActionHandler.Handle(player, request)` where `request` is
`{ Action, SlotId, OccupantId? }`.

Order of checks:

1. `request` is a table → else `InvalidAction`.
2. `Action` and `SlotId` are strings → else `InvalidAction`.
   `Validation.SlotId(slotId)` runs after this.
3. Slot exists (`SlotService._findSlotById`) → else `InvalidSlot`.
4. Slot is on a base the player owns (`BaseService.GetBaseById(slot.baseId)`
   and `base.ownerUserId == player.UserId`) → else `NotOwner`.
5. The action is in the allowlist for the slot's `(occupantKind, state)`
   tuple → else `WrongKind` (no tuple) or `InvalidAction` (action not in
   tuple).
6. **Single-flight gate** for `Pickup`/`Place` only: if one is already in
   flight for this player → `ServiceError` with `detail = 'in-progress'`.
7. Action-specific validation and dispatch.

The allowlist comes from `Prompts.Carry.Actions`:

| State / kind | Allowed actions |
|---|---|
| `Occupied` + `egg` | `Pickup`, `Hatch` |
| `Occupied` + `animal` | `Pickup`, `SellAnimal` |
| `Empty` | `Place` |
| `Reserved` | `Place` |

Dispatch targets (all required **lazily** inside the function to break a
require cycle — `bootstrap` requires `EggService`, which requires this
handler):

| Action | Guard | Target |
|---|---|---|
| `Pickup` | not already carrying; `occupantId == slot.occupantId` | `EggService.GrabEgg` / `AnimalService.GrabAnimal` |
| `Hatch` | egg only; not carrying; occupant match | `EggService.HatchEgg` |
| `Place` | must be carrying; carried kind picks the target | `EggService.PlaceEgg` / `AnimalService.PlaceAnimal` |
| `Sell` | — | **placeholder** → `NotImplemented` |
| `SellAnimal` | occupant match; animal only; **no carry gate** | `SellService.SellAnimal` |

`SellAnimal` deliberately has **no player-level carry gate** — selling a
placed animal while carrying something else is harmless, and the carried
object itself is rejected object-side by `SellService` with `'carried'`.

### Result normalisation

The three services return three different shapes:

- `EggService` → `{ success, error }`
- the animal service → `Error.X | nil` (`nil` = success, a string = failure)
- `SellService` → a table

`normalise()` folds all of them into `{ success, error?, detail? }`:

- `nil` → `{ success = true }`
- a table with `success == false` → `{ success = false, error = 'ServiceError', detail = result.error }`
- a table otherwise → `{ success = true }`
- a string → `{ success = false, error = 'ServiceError', detail = <the string> }`

### The warning mapping

`rejectionReason(action, error, detail)` maps a rejection to a
`WarningMessages` catalogue id. It inspects the **detail string** by
literal equality against a long list of service-specific spellings
(`'too-far'`, `'TooFar'`, `'player-not-live'`, `'PlayerNotLive'`,
`'InvalidPlayer'`, `'invalid-player'`, `'not-carrying'`, `'NotCarried'`,
`'SlotOccupied'`, `'SlotReserved'`, `'slot-race'`, `'in-progress'`,
`'egg-not-found'`, `'AnimalNotFound'`, `'not-found'`, `'not-placed'`,
`'not-slotted'`, `'NotSlotted'`, `'no-slot'`, `'InvalidSlot'`,
`'not-owner'`, `'NotOwner'`, `'steal-in-progress'`, `'StealInProgress'`,
`'carry-mismatch'`, `'carried'`, `'invalid-state'`, `'busy'`, `'RaidLocked'`,
`'pool-busy'`, `'grant-failed'`, `'no-sell-value'`, `'template-missing'`,
`'no-definition'`, `'roll-aborted'`, `'create-failed'`).

Returns `nil` for the paths that stay **silent**: dead-character lockouts
(`'player-not-live'` etc.) and hatch failures that already notified
(`'template-missing'`, `'no-definition'`, `'roll-aborted'`,
`'create-failed'`) — so one hatch failure = one toast.

**Gotcha:** this is a string-equality map over *other services' private
error strings*. Change one of those strings upstream and the toast
silently degrades to `'General_Generic'`.

### The single-flight guard

`activePickPlaceByUserId` — a plain table, set before the dispatch and
cleared in `finish()`. `finish()` is the single exit for every
post-gate path, so the flag is always released (death/leave/respawn
cannot leak it). Hatch and Sell do **not** take the guard.

The reason it exists: the 2-second ProximityPrompt hold already collapses
press-spam client-side (an early release never reaches the server), but
two completed holds racing in the same instant — or a stale prompt closure
firing after a fresh commit — must not double-commit.

### The menu

Two endpoints, both **owner-validated per request** (not admin-gated —
every player uses their own slots' menus).

**`SlotMenuRequest { SlotId }` → `SlotMenuState`** (preview only):

`_resolveSlot` returns `(slot, base)` or `(nil, code)`:

| Code | Meaning |
|---|---|
| `'invalid-player'` | `Validation.LivePlayer(player)` failed. |
| `'invalid-slot'` | `SlotId` is not a non-empty string. |
| `'unavailable'` | `slotServiceRef` or `baseServiceRef` is not wired. |
| `'unknown-slot'` | The slot or its base does not resolve. |
| `'not-owner'` | `base.ownerUserId ~= player.UserId`. |

For an **animal**, the preview resolves: the animal record (via
`AnimalService.Get(occupantId)`), its definition (via
`AnimalConfig.Get(definitionId)` → rarity + fallback display name), its
level (clamped to `1..Progression.MaxLevel`), the effective generation rate
(`AnimalStats.Calculate(like, 'Income') * modifierService.GetMoneyMultiplier(userId)`),
the cash pool (from the profile's `Brainrots` record, matched by `rec.Id ==
occupantId` and `rec.Type == 'Brainrot'`), and the upgrade cost (via
`upgradeServiceRef.GetUpgradeCost(definitionId, level)`).

For an **egg**, the preview resolves the egg record and its rarity. It
returns `CanUpgrade = false` and **no** sell fields, and the animal-only
fields are `nil` **by construction** (the client hides those rows rather
than faking zeros).

`{ Valid = false }` is returned when the slot holds nothing menuable.

**`SlotMenuAction { SlotId, OccupantId, Action = 'Upgrade' }` → `SlotMenuResult`**:

1. `SlotId` and `OccupantId` must both be strings → else `'bad-request'`.
2. `_resolveSlot` → else that code.
3. The slot must be `Occupied` **and** `slot.occupantId == occupantId` →
   else `'stale'` (with a `'Menu_StaleTarget'` toast).
4. `Action` must be `'Upgrade'` → else `'not-supported'`.
5. The occupant must be an **animal** → else `'not-animal'` (egg toast).
6. `upgradeServiceRef.UpgradeAnimal` must exist → else `'unavailable'`.
7. Call it under `pcall`. A non-table or falsy `success` → `'rejected'`
   with **no extra toast** (UpgradeService already notified).
8. On success → `{ SlotId, Success = true, NewLevel, Cost }`, and the
   stand display is refreshed.

Any non-Upgrade action — **including a forged sell confirm** — is
rejected with `'not-supported'` and no money moved. The single sale path
is the Sell prompt → `SlotActionHandler` `'SellAnimal'` → `SellService`.

**Affordability is NOT preview-gated.** The cost stays visible even when
the player cannot afford it; the server rejects short funds at confirm
time.

### The math

`SlotMath.FeetOffsetBelowPrimary(model)`:

- If the model has a `Humanoid` with `HipHeight > 0` → returns
  `-HipHeight * liveScale`, where `liveScale = model:GetScale()` (guarded
  by `pcall`, and only accepted if it is a finite positive number). **Why
  HipHeight and not the geometric bottom:** Roblox places a walking
  character's feet at `HRP - HipHeight`, not at the geometric leg bottom.
  For a standard R15, `HipHeight = 2` but the leg bottom is at localY
  ≈ `-2.99` — using the geometry floats the animal ~1 stud. **Why the
  scale:** `Model:ScaleTo` scales geometry but **not** the `HipHeight`
  float property, so a weight-grown model (`AnimalWeight`, up to +30%)
  would sink by `HipHeight * (scale - 1)` if the template offset were
  reused. Unscaled models report `GetScale() == 1`, so template-scale
  behaviour is unchanged.
- If `HipHeight == 0` → falls through to the **geometric** path (0 means
  "use the rig default", which Roblox resolves to the geometric bottom;
  using 0 would put the HRP *at* the floor).
- Geometric path: the lowest bottom face of any descendant `BasePart`,
  **skipping** fully-invisible parts (`Transparency >= 1`) and parts whose
  parent is an `Accessory`. The `PrimaryPart`'s own bottom face is
  **always** considered, even if it is invisible — it is the rig's
  reference frame, not stray geometry.
- No `PrimaryPart` → `0`.
- No `BasePart` descendants at all → `0` (the PrimaryPart's own bottom
  then applies, so a 2×2×2 HRP at the origin gives `-1`).

`SlotMath.StandingCFrameOnSlot(model, slot)`:

```lua
slotTopY   = slot.part.CFrame.Y + slot.part.Size.Y / 2
targetY    = slotTopY - feetOffset      -- feetOffset is negative
rotation   = StandResolver.GetSlotFacingRotation(slot)
return CFrame.new(part.Position.X, targetY, part.Position.Z) * rotation
```

The X/Z come from the slot part; the Y is the feet-flush value; the
rotation is yaw-only toward the stand's `Button.Base` (falling back to
`PressPart`, then to the slot part's own rotation). No tilt.

---

## Public API surface

### `ServerScriptService.Base.SlotService`

```lua
SlotService.Init()
SlotService.RegisterBase(base: any)
SlotService.RegisterArenaSlots(base: any)
SlotService.UnregisterArenaSlots(baseId: string)
SlotService.UnregisterBase(baseId: string)
SlotService.SetBaseOwner(userId: number, base: any)
SlotService.ClearBaseOwner(userId: number)
SlotService.RebaseSlotIds(base: any)
SlotService.RefreshDisplays(slotId: string): boolean
SlotService.GetFreeSlot(userId: number): any?
SlotService.FindSlotByOccupant(occupantId: string): (any?, any?)
SlotService.GetNearestValidSlotForPlayer(_userId: number, _playerPos: Vector3): any?  -- always nil
SlotService.ReserveSlot(slotId: string): boolean
SlotService.DemoteSlotToReserved(slotId: string): boolean
SlotService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean
SlotService.ReleaseSlot(slotId: string): boolean
SlotService.ReleaseReservedSlotForUser(userId: number, index: number): boolean
SlotService.SnapshotBaseSlots(base: any): { [number]: any }?
SlotService.SetOccupiedCountCallback(fn: (slot: any, delta: number) -> ())
SlotService.SetPoolDisplayCallback(fn: ((slot: any) -> ())?)
SlotService.SetStandDisplayCallback(fn: ((slot: any) -> ())?)
SlotService._findSlotById(slotId: string): any?
SlotService._dump(): { [string]: any }
```

### `ServerScriptService.Action.SlotActionHandler`

```lua
SlotActionHandler.Handle(player: Player, request: any): { [string]: any }
SlotActionHandler.Error: { -- frozen
  InvalidAction, InvalidSlot, NotOwner, NotOccupant, WrongKind,
  AlreadyCarrying, NotCarrying, NotImplemented, ServiceError
}
```

### `ServerScriptService.SlotMenuService`

```lua
SlotMenuService.Init()
SlotMenuService.BuildMenuState(player: Player, slotId: string): { [string]: any }
SlotMenuService.HandleAction(caller: Player, payload: any): { [string]: any }
SlotMenuService.ForgetPlayer(userId: number)
SlotMenuService.SetPlayerService(ps: any)
SlotMenuService.SetBaseService(bs: any)
SlotMenuService.SetSlotService(ss: any)
SlotMenuService.SetAnimalService(svc: any)
SlotMenuService.SetEggService(svc: any)
SlotMenuService.SetModifierService(ms: any)
SlotMenuService.SetSellService(_ss: any)   -- compat shim, does nothing
SlotMenuService.SetUpgradeService(us: any)
SlotMenuService.SetStandDisplayService(sds: any)
```

### `ServerScriptService.Animal.SlotMath`

```lua
SlotMath.FeetOffsetBelowPrimary(model: Model): number
SlotMath.StandingCFrameOnSlot(model: Model, slot: any): CFrame
```

---

## Invariants the code enforces

1. **A slot is in exactly one of `Empty` / `Reserved` / `Occupied`.** Every
   transition validates the source state and returns `false` otherwise.
2. **`Occupied` requires an occupant.** `OccupySlot` sets `occupantId` and
   `occupantKind` in the same critical section as the state change.
3. **`Reserved` may keep an occupant.** `DemoteSlotToReserved` does not
   clear `occupantId` — that is deliberate and load-bearing for
   grab-then-place.
4. **Only `Empty` slots are free.** `GetFreeSlot` skips any slot that is
   not `Empty` **or** that has its `_mutex` held.
5. **Arena slots are never free slots.** They are excluded from
   `slotsByBase` and therefore from `GetFreeSlot`, the HUD snapshot's
   normal-slot range, and egg placement.
6. **The client never decides a value.** The menu preview is computed
   server-side; the client renders strings it is given. A confirm carries
   only ids.
7. **A prompt action must be in the per-(kind, state) allowlist** — the
   same list the client uses to decide which buttons to draw, so an action
   that passed the server check was always visible to the player.
8. **Ownership is re-checked on every request**, never cached from the
   client.
9. **One carry per player.** Enforced by `CarryRegistry`, and checked by
   the dispatcher before every `Pickup` / `Hatch` and required before
   every `Place`.
10. **The occupied-count delta matches the state change.** `+1` only on
    `OccupySlot`, `-1` only on `ReleaseSlot` from a state that was
    occupied or had an occupant.
11. **No money moves on a rejected confirm.** Every reject path returns
    before `UpgradeAnimal` is called.
12. **Upgrades are animal-only.** An egg context rejects before any level
    or money can move.

---

## Failure and edge-case behaviour

| Situation | Result |
|---|---|
| `Handle` with a non-table request | `{ success = false, error = 'InvalidAction' }` + a `'General_Generic'` toast |
| `Handle` with a missing/non-string `Action` or `SlotId` | `InvalidAction` + toast |
| Slot id that resolves to nothing | `InvalidSlot` + an action-specific toast |
| Slot on another player's base | `NotOwner` + an action-specific toast |
| `(kind, state)` tuple has no actions | `WrongKind` + `'General_Generic'` toast |
| Action not in the tuple's list | `InvalidAction` + `'General_Generic'` toast |
| A `Pickup`/`Place` is already in flight | `ServiceError` + `detail = 'in-progress'` + `'General_Cooldown'` toast |
| `Pickup` while carrying | `AlreadyCarrying` + `'Pickup_AlreadyCarrying'` toast |
| `Hatch` while carrying | `AlreadyCarrying` + `'Hatch_AlreadyCarrying'` toast |
| `Place` while not carrying | `NotCarrying` + `'Place_NotCarrying'` toast |
| `OccupantId` mismatch | `NotOccupant` + `'Pickup_TargetGone'` / `'Hatch_InvalidTarget'` / `'Sale_StaleTarget'` |
| `Sell` action | `NotImplemented` |
| `SellEgg` | `InvalidAction` — **no path at all** |
| `SellAnimal` on an egg slot | `WrongKind` |
| The underlying service returns a string error | `ServiceError` + `detail = <string>` |
| `ReserveSlot` on an already-`Reserved` slot | `true` (no-op success) |
| `ReleaseSlot` on an `Empty` slot | `true` (idempotent) |
| `DemoteSlotToReserved` on a non-`Occupied` slot | `false` |
| `OccupySlot` on a non-`Reserved` slot | `false` |
| Any transition with `_mutex` held | `false` |
| `GetFreeSlot` with no base bound to the user | `nil` |
| `GetFreeSlot` with every slot taken | `nil` |
| `RefreshDisplays` with an unknown slot id | `false` |
| `SnapshotBaseSlots` with a base that has no `slots` | `nil` |
| `ReleaseReservedSlotForUser` with no base / bad index / non-`Reserved` slot | `false` |
| `BuildMenuState` on an empty/reserved slot | `{ Valid = false, SlotId }` |
| `BuildMenuState` on a foreign slot | `{ Valid = false, SlotId, Error = 'not-owner' }` |
| `HandleAction` with a non-string `SlotId`/`OccupantId` | `{ SlotId, Success = false, Error = 'bad-request' }` |
| `HandleAction` with a stale occupant | `{ ..., Success = false, Error = 'stale' }` + `'Menu_StaleTarget'` toast |
| `HandleAction` with `Action ~= 'Upgrade'` | `{ ..., Success = false, Error = 'not-supported' }` + `'Menu_StaleTarget'` toast |
| `HandleAction` on an egg | `{ ..., Success = false, Error = 'not-animal' }` + `'Menu_CannotUpgradeEgg'` toast |
| `HandleAction` with `UpgradeService` unwired | `{ ..., Success = false, Error = 'unavailable' }` + `'Menu_UpgradeUnavailable'` toast |
| `UpgradeAnimal` returns a falsy `success` | `{ ..., Success = false, Error = 'rejected' }` — **no toast** (UpgradeService notified) |
| `FeetOffsetBelowPrimary` with no `PrimaryPart` | `0` |
| `FeetOffsetBelowPrimary` with a Humanoid whose `HipHeight == 0` | the geometric path |
| `FeetOffsetBelowPrimary` on a model with no BaseParts | `0` |

Nothing in `SlotActionHandler.Handle` or `SlotMenuService` **throws** — all
validation is internal, and every service call that could throw is
wrapped in `pcall`.

---

## Gotchas that would bite you

1. **`SlotService` is frozen.** The three callbacks live in local
   upvalues because a frozen table cannot be assigned. You cannot read a
   callback back, and calling a setter twice silently replaces the first
   subscriber.
2. **`ReleaseReservedSlotForUser` takes an index, not an id** — and
   bypasses the mutex and the display hooks. It is the one method a
   caller can get subtly wrong without any error.
3. **`GetNearestValidSlotForPlayer` always returns `nil`.** It is a
   deprecated stub.
4. **`findSlotById`'s slow path is a full linear scan** of every base's
   slots. It is only reached when the O(1) index misses — i.e. after a
   re-stamp that was not followed by `RebaseSlotIds`.
5. **`_stampMenuSlotId` warns through the plain `warn` channel**, not the
   gated `Debug` channel, so a missing `MenuPart` is always visible in
   Studio output. The warning set is cleared by `UnregisterBase` (via
   `ClearMenuWarnings`) so the next owner re-warns.
6. **`_stampMenuSlotId` is declared *above* `RebaseSlotIds` on purpose.**
   Lua resolves upvalues lexically — a local declared below is invisible
   to the function above. Moving it breaks the stamping silently.
7. **The `Validation.SlotId` pattern is strict.** Slot ids must match the
   `p7:<userId>:slot:<index>` shape. A new game's id format will be
   rejected until `Validation` and `SlotType` are updated together.
   **Note:** `Validation.SlotId` is called as a *statement* in
   `SlotService` and in `SlotActionHandler` — its boolean return value is
   **discarded**. It is a filter, not a gate. A malformed slot id is not
   rejected by validation; it simply fails the `findSlotById` lookup and
   the call returns `false` / `InvalidSlot` downstream. The same is true
   of `Validation.ShortString(occupantId)` in `OccupySlot` and
   `Validation.PositiveInteger` in `GetFreeSlot` — all of them are
   no-throw predicates whose results are ignored.
8. **`SlotActionHandler` requires `BaseService` at module load.** That is
   the only non-lazy require besides the leaf modules — `BaseService` is a
   hard dependency of this system.
9. **`SlotMenuService.SetSellService` is a no-op compat shim.** It exists
   only so the bootstrap wiring line does not have to change.
10. **The menu's rate limit is `os.clock()`-based** — CPU time, not
    wall time. Under heavy server load the effective window is longer than
    0.5 s of player-perceived time.
11. **`SlotMenuService` builds a synthetic `like` table** for
    `AnimalStats.Calculate`. It is not the live animal record.
12. **The `detail` string vocabulary is duplicated across systems.**
    `SlotActionHandler` hardcodes other services' error strings. Porting
    this handler without also porting those services' strings silently
    degrades every toast to `'General_Generic'`.
13. **`SnapshotBaseSlots` skips absent indices.** A dynamic base with fewer
    than `Bases.Slots.Count` slots leaves holes — the array is sparse,
    not dense. Client code that does `for i = 1, count` must tolerate
    `out[i] == nil`.
14. **`OccupantKind` is `'egg'` / `'animal'` (lowercase), `State` is
    `'Empty'` / `'Reserved'` / `'Occupied'` (capitalised).** They are
    different conventions in the same enum family. `SlotType.State.Empty`
    and `SlotType.OccupantKind.Egg` are the canonical accessors.

---

## What to change to reuse it

**Keep (Grade A):**

- The `Empty / Reserved / Occupied` state machine and the four transition
  methods, with their exact legal-source-state rules and the
  "demote keeps the occupant" behaviour.
- The three-index layout (`slotById` / `slotsByBase` / `arenaSlotsByBase`)
  and the `baseByOwner` lookup.
- `RebaseSlotIds`' stale-drop + re-stamp + menu-attribute behaviour.
- The `SnapshotBaseSlots` wire shape (normal slots first, arena appended
  with `Arena = true`).
- The `SlotMath` feet-offset and standing-CFrame math, including the
  HipHeight and scale branches.
- The dispatcher's *structure*: allowlist → ownership → occupant → carry
  gate → dispatch, with a single-flight guard on the mutating actions.

**Change (Grade B):**

- The `p7:` id prefix and the slot-index namespace (`SlotType.BuildId`,
  `ParseId`, `ArenaSlotIndexBase`, and `Validation.SlotId` together).
- `Prompts.Carry.Actions` — the allowlist — and the action names.
- `Bases.Slots.Count` / `Size` / `Offsets` and the whole `Bases.Stands`
  label block.
- `SlotMenuService.BuildMenuState` — the preview fields. Delete the
  money/level/upgrade parts if your game has no money economy, and delete
  the upgrade confirm if it has no paid upgrades.
- `rejectionReason` — replace the string-equality map with typed codes.
- The `WarningMessages` catalogue ids.
- The Studio hierarchy (see `Setup.md`).

**Delete outright if unused:**

- `GetNearestValidSlotForPlayer` (already a stub).
- `SetSellService` (already a no-op).
- The arena-slot machinery (`RegisterArenaSlots`,
  `UnregisterArenaSlots`, the `arenaSlotsByBase` index) if your game has
  no second slot pool.
- `SlotMath`'s Accessory and `Transparency >= 1` skips if your models are
  simple.
