# Inventory — API

Every public function of every module in the Inventory system.

**Nothing in this system throws.** Every failure is a `false` / `nil`
return or an error table. The only `pcall` in the code is around
calls into *other* services (`UpgradeService.UpgradeAnimal`,
`egg._onArrived`) whose implementations are not in this library.

---

## `ServerScriptService.Base.SlotService`

The slot state machine and id index. The module table is
`table.freeze`d; the three callback setters write to local upvalues.

### Lifecycle

#### `SlotService.Init()`
No-op. Present so the bootstrap can call every service's `Init` in one
list. **Returns:** nothing. **Throws:** never.

#### `SlotService.RegisterBase(base: any)`
Indexes a base's normal slots into `slotById` and `slotsByBase`.

- **Parameters:** `base` — a base record with `id`, `slots` (an array of
  slot records), and optionally `arenaSlots`.
- **Returns:** nothing.
- **Failure modes:** silently returns if `base` is nil, has no `id`, or
  has no `slots`. **Idempotent** — re-registering a base that is already
  in `slotsByBase` is a no-op (the arena index is still refreshed).
- **Side effect:** calls `RegisterArenaSlots(base)` at the end.

#### `SlotService.RegisterArenaSlots(base: any)`
Indexes a base's arena slots into `slotById` **only** — arena slots are
deliberately excluded from `slotsByBase`.

- **Parameters:** `base` — a base record with `id` and optionally
  `arenaSlots`.
- **Returns:** nothing.
- **Failure modes:** silently returns if `base` is nil or has no `id`.
  Calls `UnregisterArenaSlots(base.id)` first, so it is safe to call
  repeatedly after a mid-session arena rebuild. Arena records that are not
  tables, or whose `id` is not a string, are skipped.

#### `SlotService.UnregisterArenaSlots(baseId: string)`
Removes a base's arena slots from `slotById`.

- **Parameters:** `baseId` — the base's id.
- **Returns:** nothing.
- **Failure modes:** silently returns if `baseId` is nil.
- **Note:** drops entries **by record identity** (table identity), not by
  id string, because the assign path re-stamps ids before replacing the
  record array.

#### `SlotService.UnregisterBase(baseId: string)`
Removes a base entirely: its normal slots from `slotById` and
`slotsByBase`, its arena slots, its owner bindings, and the suppressed
menu warnings.

- **Parameters:** `baseId` — the base's id.
- **Returns:** nothing.
- **Failure modes:** silently returns if `baseId` is nil. **Idempotent** —
  unregistering an unknown base is a no-op.

#### `SlotService.SetBaseOwner(userId: number, base: any)`
Binds a base to a player. Required before `GetFreeSlot` and
`ReleaseReservedSlotForUser` work for that player.

- **Parameters:** `userId`, `base`.
- **Returns:** nothing.
- **Failure modes:** silently returns if `userId` or `base` is nil/false.

#### `SlotService.ClearBaseOwner(userId: number)`
Drops a player's base binding.

- **Parameters:** `userId`.
- **Returns:** nothing.
- **Failure modes:** silently returns if `userId` is nil/false.

#### `SlotService.RebaseSlotIds(base: any)`
Re-indexes a base's slots after their ids were re-stamped, and re-stamps
the Studio menu button's `slotId` attribute.

- **Parameters:** `base` — a base record with `slots` and optionally
  `arenaSlots`.
- **Returns:** nothing.
- **Failure modes:** silently returns if `base` is nil or has no `slots`.
- **Side effects:** for each slot, drops every stale `slotById` entry that
  points at that slot under an old id, re-adds it under the current id,
  calls `_stampMenuSlotId(slot)`, and fires the stand display callback.
  The same is done for `base.arenaSlots`.
- **Throws:** never — but a malformed stand hierarchy can produce a
  `warn` (`'[SlotMenu] Missing UpgradeButton for stand …'`) or
  `'[SlotMenu] Missing SlotId for MenuPart under …'` (once per part).

#### `SlotService.ClearMenuWarnings()`
Clears the set of already-warned menu-structure gaps so the next owner
re-warns. Called from `UnregisterBase`.

- **Returns:** nothing. **Throws:** never.

### Queries

#### `SlotService.GetFreeSlot(userId: number): any?`
Finds the first usable slot in the player's base.

- **Parameters:** `userId` — the player.
- **Returns:** the slot record, or `nil`.
- **Failure modes:** `nil` when the user has no base bound, or when every
  slot is non-`Empty` or has its `_mutex` held. `Validation.PositiveInteger(userId)`
  is called but its result is **discarded** (it is a filter, not a gate).
- **Note:** the search order is `pairs(base.slots)` order, not numeric
  index order. Do not assume slot 1 is returned first.

#### `SlotService.FindSlotByOccupant(occupantId: string): (any?, any?)`
Finds the slot holding a given egg/animal.

- **Parameters:** `occupantId` — the egg or animal `uniqueId`.
- **Returns:** `(slot, nil)` on a hit, `(nil, nil)` on a miss. The second
  return value is **always `nil`** — the signature is vestigial.
- **Failure modes:** `(nil, nil)` if no slot holds that occupant.
- **Note:** searches normal slots **and** arena slots.

#### `SlotService.GetNearestValidSlotForPlayer(_userId: number, _playerPos: Vector3): any?`
**Deprecated stub. Always returns `nil`.** It exists only so the legacy
`_placeCallback` resolver still compiles. Do not call it.

#### `SlotService._findSlotById(slotId: string): any?`
Resolves a slot id to its record.

- **Parameters:** `slotId`.
- **Returns:** the slot record, or `nil`.
- **Failure modes:** `nil` for a nil slot id or an unknown id. Logs
  `findSlotById: no slot matched` through the `Debug` channel.
- **Performance:** the O(1) `slotById` path handles every normal call. On
  a miss it falls back to a **linear scan** of every base's normal slots
  and then every base's arena slots — that scan exists to survive a
  re-stamped id that was not followed by `RebaseSlotIds`.
- **Public despite the underscore:** used by `SlotActionHandler` and
  `SlotMenuService`.

#### `SlotService._dump(): { [string]: any }`
Test/debug helper. Returns the raw `slotById` table (by reference, not a
copy). Mutating it corrupts the index.

- **Returns:** the live `slotById` table.

### Transitions

All four take a **slot id** and return `boolean`. All four are
**no-throw**. All four check `slot._mutex` and return `false` if it is
held.

#### `SlotService.ReserveSlot(slotId: string): boolean`
`Empty → Reserved`.

- **Returns:** `true` on success.
- **Failure modes:** `false` if the slot is not found, the mutex is held,
  or the state is not `Empty` **and not already `Reserved`**. An
  already-`Reserved` slot returns `true` (a deliberate **no-op success**,
  so "place back on the same slot" does not need a special case).

#### `SlotService.DemoteSlotToReserved(slotId: string): boolean`
`Occupied → Reserved`. **Keeps** `occupantId` and `occupantKind` so
recovery paths know what was on the slot.

- **Returns:** `true` on success.
- **Failure modes:** `false` if the slot is not found, the state is not
  `Occupied`, or the mutex is held.
- **Side effects:** fires the pool display and stand display callbacks.

#### `SlotService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean`
`Reserved → Occupied`.

- **Parameters:** `slotId`, `occupantId` — the egg/animal `uniqueId`,
  `occupantKind` — `'egg'` or `'animal'` (optional; stored as-is).
- **Returns:** `true` on success.
- **Failure modes:** `false` if the slot is not found, the state is not
  `Reserved`, or the mutex is held.
- **Side effects:** sets `occupantId`/`occupantKind`; calls the occupied
  count callback with `+1`; fires the pool and stand display callbacks.
- **Note:** `Validation.SlotId` and `Validation.ShortString` are called
  but their results are **discarded**.

#### `SlotService.ReleaseSlot(slotId: string): boolean`
`anything → Empty`.

- **Returns:** `true` on success.
- **Failure modes:** `false` if the slot is not found or the mutex is
  held. **`Empty` → `Empty` returns `true`** (idempotent no-op).
- **Side effects:** clears `occupantId`/`occupantKind`. Calls the
  occupied count callback with `-1` and fires the display callbacks **only
  if** the slot was `Occupied` **or** had an occupant (a `Reserved` slot
  that still named its occupant is reconciled too).

#### `SlotService.ReleaseReservedSlotForUser(userId: number, index: number): boolean`
Releases a `Reserved` slot in the player's own base.

- **Parameters:** `userId`, `index` — a **1-based index** into
  `base.slots`, *not* a slot id.
- **Returns:** `true` on success.
- **Failure modes:** `false` if the user has no base, the index is out of
  range, or the slot is not `Reserved`.
- **Gotchas:** this method **bypasses the `_mutex`** and does **not** fire
  the display callbacks or the occupied-count callback. It is the only
  mutation in the module with an index-based signature.

### Snapshot

#### `SlotService.SnapshotBaseSlots(base: any): { [number]: any }?`
Builds the wire array of slot snapshots for a base.

- **Parameters:** `base` — a base record with `slots` and optionally
  `arenaSlots`.
- **Returns:** an array of snapshot tables, or `nil` if `base` is nil or
  has no `slots`.
- **Shape:** normal slots occupy indices `1..Bases.Slots.Count` (absent
  indices are **skipped**, so the array can be sparse). Arena slots are
  **appended** after the normal ones, ordered by `arenaIndex` (falling
  back to `index`), each with `Arena = true`.

  ```lua
  { Index = 1, Id = 'p7:123:slot:1', State = 'Occupied',
    OccupantId = 'AN_...', OccupantKind = 'animal',
    Position = Vector3, Arena = true? }
  ```

- **Failure modes:** `nil` for a base with no `slots`. `Position` is `nil`
  when the slot has no part.

### Callbacks

#### `SlotService.SetOccupiedCountCallback(fn: (slot: any, delta: number) -> ())`
Installs the callback fired on transitions that change the base's occupied
count. `delta` is `+1` (on `OccupySlot`) or `-1` (on `ReleaseSlot` from
an occupied/having-occupant state).

- **Returns:** nothing.
- **Failure modes:** none. Setting it twice **replaces** the previous
  callback (there is no list, and no way to read it back — it lives in a
  local upvalue so the frozen module table is not mutated).

#### `SlotService.SetPoolDisplayCallback(fn: ((slot: any) -> ())?)`
Installs the callback that republishes a slot's cash-pool attribute and
money label. Fired on transitions **into or out of `Occupied`** only.

- **Returns:** nothing. **Failure modes:** none. Same replace-only
  semantics as above.

#### `SlotService.SetStandDisplayCallback(fn: ((slot: any) -> ())?)`
Installs the callback that repaints the stand's direct-upgrade readout.
Fired on the same transitions as the pool hook, **plus**
`RebaseSlotIds`.

- **Returns:** nothing. **Failure modes:** none.

---

## `ServerScriptService.Action.SlotActionHandler`

### `SlotActionHandler.Handle(player: Player, request: any): { [string]: any }`
The server-side dispatcher for slot prompt actions.

- **Parameters:**
  - `player` — the acting player.
  - `request` — `{ Action: string, SlotId: string, OccupantId?: string }`.
    `Action` must be one of `'Pickup'`, `'Hatch'`, `'Place'`,
    `'SellAnimal'`, `'Sell'`. `OccupantId` is required for `Pickup`,
    `Hatch`, and `SellAnimal`.
- **Returns:** `{ success: boolean, error?: string, detail?: any }`.
  `error` is one of `SlotActionHandler.Error.*`. `detail` carries the
  underlying service's own error string when `error == 'ServiceError'`.
- **Throws:** **never.** All validation is internal; every downstream
  service call is wrapped.

**The check order:**

| # | Check | Result on failure |
|---|---|---|
| 1 | `request` is a table | `InvalidAction` |
| 2 | `Action` and `SlotId` are strings | `InvalidAction` |
| 3 | The slot exists (`_findSlotById`) | `InvalidSlot` |
| 4 | The slot's base is owned by the player | `NotOwner` |
| 5 | The `(occupantKind, state)` tuple has an action list | `WrongKind` |
| 6 | The action is in that list | `InvalidAction` |
| 7 | No `Pickup`/`Place` already in flight for this player | `ServiceError` + `detail = 'in-progress'` |
| 8 | Action-specific validation | see below |

**Per-action validation and dispatch:**

| Action | Additional checks | Dispatch |
|---|---|---|
| `Pickup` | not carrying (`AlreadyCarrying`); `OccupantId == slot.occupantId` (`NotOccupant`) | `EggService.GrabEgg` or `AnimalService.GrabAnimal` by occupant kind |
| `Hatch` | occupant kind is egg (`WrongKind`); not carrying (`AlreadyCarrying`); occupant match (`NotOccupant`) | `EggService.HatchEgg` |
| `Place` | **must** be carrying (`NotCarrying`); the carried kind selects the target | `EggService.PlaceEgg` / `AnimalService.PlaceAnimal` with `item.record.uniqueId` |
| `Sell` | — | **none** — returns `NotImplemented` |
| `SellAnimal` | occupant match (`NotOccupant`); occupant kind is animal (`WrongKind`); **no carry gate** | `SellService.SellAnimal` |

Any other action string → `InvalidAction`. There is **no `SellEgg` path**
— eggs are not sellable anywhere.

**Notifications:** every rejection fires a `NotificationService.NotifyWarning`
with a catalogue id resolved by the internal `rejectionReason` mapping
(`'Pickup_NotOwner'`, `'Place_NotCarrying'`, `'Sale_StaleTarget'`,
`'General_Cooldown'`, …). Some paths are deliberately **silent**: dead
character lockouts and hatch failures that already notified upstream.

### `SlotActionHandler.Error`
A frozen table of the nine stable error codes:

```lua
{ InvalidAction = 'InvalidAction', InvalidSlot = 'InvalidSlot',
  NotOwner = 'NotOwner', NotOccupant = 'NotOccupant',
  WrongKind = 'WrongKind', AlreadyCarrying = 'AlreadyCarrying',
  NotCarrying = 'NotCarrying', NotImplemented = 'NotImplemented',
  ServiceError = 'ServiceError' }
```

---

## `ServerScriptService.SlotMenuService`

### `SlotMenuService.Init()`
Connects the `SlotMenuRequest` and `SlotMenuAction` remotes.

- **Returns:** nothing.
- **Failure modes:** **never throws.** If `Remotes.GetFolder()` throws
  (the folder is not wired), it warns
  `'SlotMenuService.Init: Remotes folder not wired; menus unavailable'`
  and returns. If either remote is missing or is not a `RemoteEvent`, it
  warns (`'SlotMenuRequest remote missing'` / `'SlotMenuAction remote
  missing'`) and the corresponding endpoint stays dead.
- **Note:** the module is **not** `Init`-guarded — calling `Init` twice
  connects the handlers twice.

### `SlotMenuService.BuildMenuState(player: Player, slotId: string): { [string]: any }`
The authoritative preview for one owned slot.

- **Parameters:** `player`, `slotId`.
- **Returns:** a RemoteEvent-safe table.

  **Animal** (when the slot is `Occupied` with an animal occupant):

  ```lua
  { Valid = true, SlotId = '...', Kind = 'animal', ObjectId = 'AN_...',
    Name = 'Tralalero', Rarity = 'Rare', Level = 3, NewLevel = 4,
    CanUpgrade = true, UpgradeCostRaw = '1234',
    UpgradeButtonText = 'Upgrade $1,234',
    GenRaw = '12.5', GenFormatted = '$12.5/sec',
    PoolRaw = '0', PoolFormatted = '$0' }
  ```

  **Egg**:

  ```lua
  { Valid = true, SlotId = '...', Kind = 'egg', ObjectId = 'EG_...',
    Name = 'Egg', Rarity = 'Common', CanUpgrade = false }
  ```

  The egg variant omits the animal-only fields **entirely** (`nil` by
  construction — the client hides the rows rather than faking zeros), and
  carries **no sell fields** (eggs are not sellable).

  **Invalid**: `{ Valid = false, SlotId = slotId }` or
  `{ Valid = false, SlotId, Error = <code> }`.

- **Failure modes (all return `{ Valid = false }`):**
  - `Error = 'invalid-player'` — `Validation.LivePlayer(player)` failed.
  - `Error = 'invalid-slot'` — `SlotId` is not a non-empty string.
  - `Error = 'unavailable'` — `slotServiceRef` or `baseServiceRef` is not
    wired.
  - `Error = 'unknown-slot'` — the slot or its base does not resolve.
  - `Error = 'not-owner'` — `base.ownerUserId ~= player.UserId`.
  - No `Error` — the slot is not `Occupied`, the occupant id is not a
    string, the object record does not resolve, the definition is
    unknown, or the relevant service ref is missing.

- **Never throws.** Every service call is wrapped in `pcall`.

### `SlotMenuService.HandleAction(caller: Player, payload: any): { [string]: any }`
The confirm endpoint. **Upgrade only.**

- **Parameters:** `caller`, `payload` —
  `{ SlotId: string, OccupantId: string, Action: 'Upgrade' }`.
- **Returns:** `{ SlotId, Success: boolean, Error?: string, NewLevel?: any, Cost?: any }`.
- **Throws:** **never.** `UpgradeService.UpgradeAnimal` is wrapped in
  `pcall`.

| Step | Condition | Result |
|---|---|---|
| 1 | `SlotId` and `OccupantId` are both strings | else `{ Success = false, Error = 'bad-request' }` |
| 2 | The slot resolves and is owned | else `{ Success = false, Error = <resolve code> }` |
| 3 | The slot is `Occupied` **and** `slot.occupantId == occupantId` | else `{ Success = false, Error = 'stale' }` + `'Menu_StaleTarget'` toast |
| 4 | `payload.Action == 'Upgrade'` | else `{ Success = false, Error = 'not-supported' }` + `'Menu_StaleTarget'` toast |
| 5 | The occupant kind is an animal | else `{ Success = false, Error = 'not-animal' }` + `'Menu_CannotUpgradeEgg'` toast |
| 6 | `upgradeServiceRef.UpgradeAnimal` exists | else `{ Success = false, Error = 'unavailable' }` + `'Menu_UpgradeUnavailable'` toast |
| 7 | `UpgradeAnimal` returns a table with `success == true` | else `{ Success = false, Error = 'rejected' }` — **no toast** (UpgradeService already notified) |
| 8 | Success | `{ SlotId, Success = true, NewLevel = upResult.newLevel, Cost = upResult.upgradeCost }` |

**Any non-Upgrade action — including a forged sell confirm — is rejected
with `'not-supported'` and no money moves.** The single sale path is the
animal's Sell prompt → `SlotActionHandler` `'SellAnimal'` →
`SellService.SellAnimal`.

### `SlotMenuService.ForgetPlayer(userId: number)`
Clears the per-player throttle maps for both endpoints.

- **Returns:** nothing. **Failure modes:** none.

### Injection setters

All of these take a service table (or `any`) and store it in a local
upvalue. Calling one twice **replaces** the previous value; there is no
way to read it back.

| Setter | Used for | Missing effect |
|---|---|---|
| `SetPlayerService(ps)` | the profile's `CashPool` lookup | the pool preview shows `'0'` |
| `SetBaseService(bs)` | `GetBaseById` for the ownership check | **every** request returns `{ Valid = false, Error = 'unavailable' }` |
| `SetSlotService(ss)` | `_findSlotById` | same as above |
| `SetAnimalService(svc)` | `Get(occupantId)` for the animal preview | animal slots return `{ Valid = false }` |
| `SetEggService(svc)` | `GetEgg(occupantId)` for the egg preview | egg slots return `{ Valid = false }` |
| `SetModifierService(ms)` | `GetMoneyMultiplier(userId)` for the effective rate | the multiplier falls back to `1` |
| `SetUpgradeService(us)` | `GetUpgradeCost` / `UpgradeAnimal` | `CanUpgrade` is always false; confirms return `'unavailable'` |
| `SetStandDisplayService(sds)` | `RefreshSlot(slot)` after a successful upgrade | the stand readout repaints on the next state push instead |
| `SetSellService(_ss)` | **nothing** | compat shim, a deliberate no-op |

---

## `ServerScriptService.Animal.SlotMath`

Pure geometry. No side effects, no engine mutation, no service
dependencies.

### `SlotMath.FeetOffsetBelowPrimary(model: Model): number`
The local-Y offset from the model's `PrimaryPart` down to the lowest
bottom face of any part in the model. **Negative** (the feet are below the
PrimaryPart).

- **Parameters:** `model` — the model to measure.
- **Returns:** a number. `0` when the model has no `PrimaryPart` or no
  `BasePart` at all.
- **Throws:** never — `model:GetScale()` is wrapped in `pcall` and the
  result is only accepted if it is a finite positive number.
- **Branch order:**
  1. A `Humanoid` with `HipHeight > 0` → `-HipHeight * model:GetScale()`.
     (Roblox places a walking character's feet at `HRP - HipHeight`, not
     at the geometric leg bottom. The scale factor is needed because
     `Model:ScaleTo` scales geometry but not the `HipHeight` float
     property, so a weight-grown model would sink by
     `HipHeight * (scale - 1)`.)
  2. Otherwise the geometric path: the lowest bottom face of any
     descendant `BasePart`, **skipping** fully-invisible parts
     (`Transparency >= 1`) and parts whose parent is an `Accessory`. The
     `PrimaryPart`'s own bottom face is **always** considered, even when
     it is invisible.
- **Example:** R15 with `HipHeight = 2` and unscaled → `-2`. A foot at
  localY `-2` with size `2` → bottom at `-3` → `-3`. A 2×2×2 HRP alone
  → `-1`.

### `SlotMath.StandingCFrameOnSlot(model: Model, slot: any): CFrame`
The `CFrame` at which the model's `PrimaryPart` must be placed so the
model's lowest bottom face lands exactly on the slot's top surface.

- **Parameters:** `model`, `slot` — a slot record with a `part`
  (`BasePart`).
- **Returns:** a `CFrame`.
- **Throws:** never — but it **will error** if `slot.part` is nil
  (`part.Size` on nil). The slot record is expected to carry a part.
- **Math:** `slotTopY = part.CFrame.Y + part.Size.Y / 2`;
  `targetPrimaryY = slotTopY - feetOffset` (the offset is negative, so
  the PrimaryPart is raised by `|feetOffset|`).
- **Orientation:** the X/Z come from the slot part; the rotation is
  `StandResolver.GetSlotFacingRotation(slot)` — yaw-only toward
  `Stand.Button.Base` (falling back to `Button.PressPart`, then to the
  slot part's own rotation). **Never tilts.**
