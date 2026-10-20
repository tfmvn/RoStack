# BasesAndSlots — API

Every public function of every module in this system, with its exact
signature, what it does, its parameters, its return value, and how it
fails.

**Conventions used below:**

- **Throws** — the function calls `error()`; the caller must `pcall` it.
- **Never throws** — the function swallows its own errors (usually with a
  `pcall` inside) and returns a fallback value.
- **Deprecated shim** — the function forwards to `SlotService` and logs a
  deprecation line. It is not the source of truth.
- Line numbers refer to the shipped `Source/` tree.

---

## `ServerScriptService/BaseService`

The base registry owner. A singleton; `require` it once and keep the
reference.

### Injection

```lua
BaseService.Init()                                        -- 264
BaseService.SetPlayerService(svc: any)                   -- 266
BaseService.SetEggService(svc: any)                      -- 270
BaseService.SetAnimalService(svc: any)                   -- 274
BaseService.SetBaseLockService(svc: any)                 -- 281
BaseService.SetSlotService(svc: any)                     -- 287
```

| Function | Description |
|---|---|
| `Init()` | Creates the empty registry and installs the SlotService occupancy callback (only if a SlotService has already been injected). No-op if called twice. |
| `SetPlayerService(svc)` | Injects the profile owner, used to read/write `BaseId` and to release the profile base on release. |
| `SetEggService(svc)` | Injects the egg authority, used to spawn persisted eggs during `RestorePlayerBase`. |
| `SetAnimalService(svc)` | Injects the animal authority, used to spawn persisted animals during `RestorePlayerBase`. |
| `SetBaseLockService(svc)` | Injects the lock service. `AssignBaseForPlayer` / `AssignBaseById` / `ReleaseBase` call `HandleBaseAssigned` / `HandleBaseReleased` through it. |
| `SetSlotService(svc)` | Injects the slot authority. **The whole slot API below is a shim over this.** `SetSlotService` also installs `SetOccupiedCountCallback`, which is what moves the base between `Reserved` and `Occupied`. |

**Failure modes:** none of these throw. `SetSlotService` after
`AssignBaseForPlayer` means the base never leaves `Reserved`.

### Registration

```lua
BaseService.RegisterBases(workspace: Instance)           -- 354
```

Scans the base container and builds the registry.

| Parameter | Type | Meaning |
|---|---|---|
| `workspace` | `Instance` | The Workspace. Must be a `Workspace` instance. |

**Returns:** nothing.

**Failure modes:**

- `workspace` is not a `Workspace` → **throws** (via
  `Validation.t.instanceOf('Workspace')`).
- No `Workspace.Map.Bases` and no top-level `Workspace.Bases` → **throws**
  with a message naming the authoritative path. The server does **not**
  create the container.
- A base folder with no `Collector` → **throws** (naming the path).
- A `Collector` that is not a `BasePart` → **throws**.
- A `Collector` that shares the Spawn's XZ position → **throws**
  ("shares the XZ position").
- A missing `StandPos<n>` / `ArenaStandPos<n>` → `warn`, not fatal; the
  index stays a hole.
- A missing `StandTemplate` → `warn` at boot (inside a `pcall`); each
  affected base then fails closed at assign time.

**Side effects:** creates missing `Spawn`, `SpawnLocation`, `Slots`,
`Slot<n>` and `CashCollector` instances; rotates authored `Slot<n>` parts
to the collector-facing yaw; pushes each base to `SlotService.RegisterBase`.

**Order:** must run **after** the map is in the Workspace and **before**
`BaseLockService.Init()`.

### Lookups

```lua
BaseService.GetBaseById(baseId: string): any?             -- 757
BaseService.GetBaseByOwner(userId: number): any?          -- 762
BaseService.GetPlayerBase(userId: number): any?           -- 771
BaseService.IsBaseOwnedByPlayer(baseId: string, userId: number): boolean  -- 778
BaseService.GetBaseState(baseId: string): string?         -- 786
BaseService.GetAllBases(): { [string]: any }              -- 794
```

| Function | Description | Returns |
|---|---|---|
| `GetBaseById(baseId)` | The base record, or `nil` if the id is unknown. | The record table, or `nil`. Never throws. |
| `GetBaseByOwner(userId)` | The base owned by a user. | The record, or `nil`. Never throws. |
| `GetPlayerBase(userId)` | An alias of `GetBaseByOwner`. | The record, or `nil`. |
| `IsBaseOwnedByPlayer(baseId, userId)` | Ownership check. | `true` only if the base exists **and** `base.ownerUserId == userId`. Non-string/non-number arguments → `false`. |
| `GetBaseState(baseId)` | The base's lifecycle state. | `'Available'`, `'Reserved'`, `'Occupied'`, or `nil` if the base is unknown. |
| `GetAllBases()` | The whole registry. | `{ [baseId] = record }`. **This is the live table, not a copy** — mutating it mutates the registry. Never throws. |

### Session fencing

```lua
BaseService.GetSession(baseId: string): number?           -- 803
BaseService.IsCurrentSession(baseId: string, session: number): boolean  -- 816
```

| Function | Description | Returns |
|---|---|---|
| `GetSession(baseId)` | The base's current ownership session counter. `0` means never assigned. | The number, or `nil` if the base is unknown. |
| `IsCurrentSession(baseId, session)` | The fencing check. `true` iff `session` is still the base's live session. | `true` / `false`. On a mismatch it `Debug.Warn`s with both numbers. Never throws. |

**Use this before every async mutation of a base.** A callback holding a
stale session must return without touching anything.

### Runtime validation

```lua
BaseService.ValidateBaseRuntime(baseId: string): boolean   -- 936
```

Checks the base's runtime invariants: the state matches ownership, every
slot's `ownerUserId` matches the base's owner (or is `0` when
unassigned), no slot has a stuck `_mutex`, no slot carries a runtime
occupant while the base is unassigned, and no slot part has a stray
`ProximityPrompt`.

| Parameter | Type | Meaning |
|---|---|---|
| `baseId` | `string` | The base to check. |

**Returns:** `true` when clean, `false` when at least one problem was
found. An unknown base id → `false` plus a `warn`.

**Failure modes:** never throws. Every problem is reported through
`Debug.Warn` (one line per problem). Called on assign, release, cleanup
and wipe.

### Assignment and release

```lua
BaseService.AssignBaseForPlayer(userId: number): any?     -- 1078
BaseService.AssignBaseById(userId: number, baseId: string): any?  -- 1228
BaseService.ReleasePlayerBase(userId: number): boolean   -- 1314
BaseService.ReleaseBase(baseId: string, expectedUserId: number?): boolean  -- 1323
BaseService.PointPlayerToBaseSpawn(player: Player, base: any): boolean  -- 1207
```

| Function | Description |
|---|---|
| `AssignBaseForPlayer(userId)` | Finds the first `Available`, unlocked base, claims it for `userId`, and returns the record. If the player already owns a base, that base is returned unchanged. |
| `AssignBaseById(userId, baseId)` | The same, but for a specific base. Returns `nil` if that base is not `Available` or is mutexed, or if the player already owns a base. |
| `ReleasePlayerBase(userId)` | Releases the player's base. Delegates to `ReleaseBase(bid, userId)`. |
| `ReleaseBase(baseId, expectedUserId)` | Releases a base: unlocks it, destroys the runtime stands, sweeps the slots, clears the owner, sets the state back to `Available`, bumps the session, and unregisters it from SlotService. |
| `PointPlayerToBaseSpawn(player, base)` | **Sets `player.RespawnLocation` to the base's `SpawnLocation`.** It does **not** teleport the player. |

**Returns:**

| Function | Returns |
|---|---|
| `AssignBaseForPlayer` | The base record, or `nil` if no base is available. |
| `AssignBaseById` | The base record, or `nil` if the base is unavailable or the player already owns one. |
| `ReleasePlayerBase` | `true` on success, `false` if the player had no base. |
| `ReleaseBase` | `true` on success, `false` if the base is unknown, the `expectedUserId` does not match the current owner, or the base is mutexed. |
| `PointPlayerToBaseSpawn` | `true` on success, `false` if the player is not a `Player`, the base record is malformed, the base has no valid `SpawnLocation`, or the pad has been destroyed. |

**Failure modes:** none of these throw.

**Important side effects of a successful assignment:**

- `base.state` is set to **`Reserved`**, not `Occupied`. It only becomes
  `Occupied` when a slot is actually occupied, via SlotService's
  occupancy callback.
- `base.session` is bumped (`_bumpSession`).
- Every slot's `id` is re-stamped to
  `SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)` — including
  the arena records.
- The `AnimalStands` runtime clones are built (dynamic mode).
- The arena stands are built if the base carries `ArenaStandPos` markers.
- `SlotService` is re-registered / re-based, and every slot's displays are
  refreshed.
- `PlayerBoard.Refresh` paints the new owner.
- `RebirthService.RefreshBaseMultiplier` is called (lazy `pcall`).
- `BaseLockService.HandleBaseAssigned(userId)` is called (lazy `pcall`).

**A failed `PointPlayerToBaseSpawn` leaves the previous
`RespawnLocation` untouched.** The caller must not call `LoadCharacter`
after a failure.

### Slot API (deprecated shims)

> **All of these forward to `SlotService` and log a deprecation line
> (`Debug.Log('BS', 'DEPRECATION: ...')`).** `SlotService` is the source
> of truth. When no SlotService is injected, every one of them returns its
> "no" value.

```lua
BaseService.GetFreeSlot(userId: number): any?                                   -- 1420
BaseService.GetNearestValidSlotForPlayer(userId: number, playerPos: Vector3): any?  -- 1430
BaseService.ReserveSlot(slotId: string): boolean                                -- 1438
BaseService.DemoteSlotToReserved(slotId: string): boolean                       -- 1446
BaseService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean  -- 1454
BaseService.ReleaseSlot(slotId: string): boolean                                -- 1462
BaseService.FindSlotByOccupant(occupantId: string): (any?, any?)                 -- 1470
BaseService.ReleaseReservedSlotForUser(userId: number, index: number): boolean  -- 1504
```

| Function | Description | Returns (no SlotService injected) |
|---|---|---|
| `GetFreeSlot(userId)` | A free slot in the user's base. | `nil` |
| `GetNearestValidSlotForPlayer(userId, playerPos)` | The free slot nearest a world position. | `nil` |
| `ReserveSlot(slotId)` | `Empty` → `Reserved`. | `false` |
| `DemoteSlotToReserved(slotId)` | `Occupied` → `Reserved`, without freeing it. | `false` |
| `OccupySlot(slotId, occupantId, occupantKind)` | Claims a slot for an occupant. `occupantKind` is `'egg'` or `'animal'`. | `false` |
| `ReleaseSlot(slotId)` | Frees a slot. | `false` |
| `FindSlotByOccupant(occupantId)` | The `(base, slot)` pair holding an occupant. | `nil, nil` |
| `ReleaseReservedSlotForUser(userId, index)` | Frees a reserved slot by index. | `false` |

None of these throw.

```lua
BaseService._findSlotById(slotId: string): any?    -- 1478
```

**Not part of the supported API** despite being exported. A raw slot
lookup by id, with **no session check, no ownership check and no
validation**. It forwards to `SlotService._findSlotById` when available;
without a SlotService it falls back to a `SlotType.ParseId`-based scan
that matches `s.id == slotId` and warns on a miss.

### Restore, wipe, snapshot, cleanup

```lua
BaseService.RestorePlayerBase(userId: number, profileData: any)  -- 1539
BaseService.WipePlayerData(userId: number)                       -- 1670
BaseService.Snapshot(userId: number): { slots: any, _occupiedCount: number }?  -- 1736
BaseService.CleanupPlayer(userId: number)                       -- 1784
```

| Function | Description |
|---|---|
| `RestorePlayerBase(userId, profileData)` | Re-homes the player's persisted egg and animal records onto the current session's slots. Eggs are restored first, animals second. Every record is either spawned or named in a `Debug.Warn` saying exactly why it was not. Nothing is ever auto-destroyed. |
| `WipePlayerData(userId)` | The admin-only wipe. Destroys the runtime on the base, clears the persisted lists, and delegates the profile reset to `PlayerService.WipeUser`. |
| `Snapshot(userId)` | Builds the wire snapshot for the `PlayerState` push. |
| `CleanupPlayer(userId)` | The leave path. **Non-destructive** — the persisted animals and eggs are left alone so `RestorePlayerBase` can bring them back. It releases the in-memory base so another player can take it. |

**Returns:**

| Function | Returns |
|---|---|
| `RestorePlayerBase` | Nothing. |
| `WipePlayerData` | Nothing. If the player has no base, it still calls `PlayerService.WipeUser` and returns. |
| `Snapshot` | `{ slots = <array>, _occupiedCount = <number> }`, or `nil` if the player has no base. |
| `CleanupPlayer` | Nothing. Returns early if the player has no base. |

**The `Snapshot` slot array** — each entry:

| Field | Type | Notes |
|---|---|---|
| `Index` | number | The slot index. |
| `Id` | string | `p7:<userId>:slot:<index>`. |
| `State` | string | `'Empty'` / `'Reserved'` / `'Occupied'`. |
| `OccupantId` | string? | The animal or egg id. |
| `OccupantKind` | string? | `'egg'` / `'animal'`. |
| `Position` | Vector3? | The slot part's world position. |
| `Arena` | boolean | Present (and `true`) **only** on arena entries. |

**Failure modes:** none of these throw. `Snapshot` returns `nil` for a
player with no base; `RestorePlayerBase` warns per record it cannot place.

**`RestorePlayerBase` re-homing rules:**

- A record whose `SlotId` no longer resolves (a base layout change) is
  **re-homed to a free slot**, and its persisted `SlotId` is **mutated in
  place** (line 1628) to point at where it actually respawned.
- An **egg** pointing at an **arena** slot is **rejected** and re-homed to
  a normal slot (lines 1583-1592).

---

## `ServerScriptService/Base/DynamicSlotService`

The dynamic stand builder.

### Injection

```lua
DynamicSlotService.SetUnlockResolver(fn: ((number) -> number)?)   -- 91
```

| Parameter | Type | Meaning |
|---|---|---|
| `fn` | `((number) -> number)?` | Given a `userId`, returns the player's **rebirth count**. The service turns that into `{Animal, Arena}` unlock counts via `RebirthConfig.StandsFor(rebirth)`. `nil` clears the resolver. |

**Returns:** nothing. A non-function, non-nil argument is **ignored**
(the previous resolver stays).

**Failure modes:** never throws. If the resolver throws or returns a
non-number or a negative number, the service falls back to the
"no resolver" behaviour (marker counts only, no unlock cap).

**The resolver is the whole point of the dynamic system.** Without it,
the stand count is `min(#markers, Bases.Slots.Count)`. With it, the count
is `min(unlocked.Animal, Bases.Slots.Count)` — the marker count is **not**
a cap, because the generated ring replaces the marker positions.

### Templates

```lua
DynamicSlotService.GetTemplate(): Instance?                -- 277
DynamicSlotService.GetArenaTemplate(): Instance?           -- 983
```

| Function | Description | Returns |
|---|---|---|
| `GetTemplate()` | Resolves `ServerStorage.Assets.Map.Bases.Base.StandTemplate`, caching it. A `Model` or a `BasePart`. | The instance, or `nil`. Never throws. |
| `GetArenaTemplate()` | Resolves `ServerStorage.Assets.Map.Bases.Base.ArenaStandTemplate`. | The instance, or `nil`. Never throws. |

### Queries

```lua
DynamicSlotService.GetStandPositions(baseFolder: Instance?): { Instance }        -- 353
DynamicSlotService.GetArenaStandPositions(baseFolder: Instance?): { Instance }   -- 1008
DynamicSlotService.GetDesiredSlotCount(baseFolder: Instance?, _userId: number?): number  -- 364
DynamicSlotService.GetDesiredArenaStandCount(baseFolder: Instance?, _userId: number?): number  -- 1016
DynamicSlotService.ArenaSlotIndexBase(): number                -- 459
```

| Function | Description | Returns |
|---|---|---|
| `GetStandPositions(baseFolder)` | The `StandPos<k>` markers under the base, **sorted by parsed index** (never by descendant order). | An array of instances; empty if the folder is `nil` or has no markers. |
| `GetArenaStandPositions(baseFolder)` | The `ArenaStandPos<k>` markers, sorted the same way. | An array of instances. |
| `GetDesiredSlotCount(baseFolder, _userId)` | How many animal stands the base should have right now. | `0` if there are no markers. With a resolver: `min(unlocked.Animal, Bases.Slots.Count)`. Without: `min(#markers, Bases.Slots.Count)`. |
| `GetDesiredArenaStandCount(baseFolder, _userId)` | How many arena stands the base should have. | `0` if there are no markers. With a resolver: `min(unlocked.Arena, SlotType.MaxArenaStands)` — `MaxArenaStands` is **99**. Without: `#markers`. |
| `ArenaSlotIndexBase()` | The arena slot index namespace. | `1000`. The runtime index is `1000 + k`. |

### Positioning

```lua
DynamicSlotService.PlaceAtCFrame(clone: Instance, target: CFrame): boolean    -- 410
DynamicSlotService.PlaceAtStandPos(clone: Instance, marker: Instance): boolean  -- 433
```

| Function | Description | Returns |
|---|---|---|
| `PlaceAtCFrame(clone, target)` | Pivots a runtime clone onto an explicit world CFrame. This is the **generated-layout** path. | `true` on success, `false` if `target` is not a CFrame or the `PivotTo` throws (which `warn`s). |
| `PlaceAtStandPos(clone, marker)` | Pivots a clone **exactly** onto its marker — position *and* rotation, no offsets. The **legacy marker** path. | `true` on success, `false` if the marker has no usable transform (which `warn`s and skips the slot) or the `PivotTo` throws. |

`markerWorldCFrame` resolves the marker's transform by type: a
`BasePart` → `CFrame`; an `Attachment` → `WorldCFrame`; anything else
pivotable → `GetPivot()`.

### Building

```lua
DynamicSlotService.BuildBaseSlots(base: any, userId: number, session: number): number   -- 582
DynamicSlotService.ReconcileBaseSlots(base: any, userId: number, session: number): number  -- 901
DynamicSlotService.DestroyBaseSlots(base: any, session: number): number                -- 798
DynamicSlotService.BuildArenaStands(base: any, userId: number, session: number): number  -- 1152
DynamicSlotService.ReconcileArenaStands(base: any, userId: number, session: number): number  -- 1424
DynamicSlotService.DestroyArenaStands(base: any, session: number): number              -- 1351
```

| Parameter | Type | Meaning |
|---|---|---|
| `base` | `any` | The base record. Must be a table with a string `id`. |
| `userId` | `number` | The new owner. Used to stamp the slot ids. |
| `session` | `number` | The session the caller captured. **If it does not match `base.session`, the call is refused.** |

**Returns:** the number of stands / records in effect after the call.

**Failure modes (all of them return `0` and warn):**

- `base` is not a table, or `base.id` is not a string → `0`.
- **Stale session** → `0` plus
  `Refused stale session callback (build|destroy|reconcile)`. The
  service compares `base.session` with the passed `session` itself, so
  it is safe to call from any deferred context.
- No `base.folder` → `0`.
- The template is missing or unusable → `0` plus
  `the StandTemplate is unusable; ZERO slots built`. **The base fails
  closed.**
- No `StandPos` markers → `0` plus
  `ZERO StandPos markers found` (the build is skipped).
- The desired count is `<= 0` → `0` plus
  `Invalid desired slot count`.

**`BuildBaseSlots`** also creates the `AnimalStands` folder if the base
does not have one (with a `warn`), and attaches the cash triggers through
`IncomeService.EnsureCollectorsForSlots` (lazy `pcall`).

**`ReconcileBaseSlots`** removes the extras above the desired count —
but **only unoccupied ones**. An occupied slot is **never** destroyed; the
service warns `Attempted to remove occupied SlotId ... refusing
destructive removal.` If the surviving count already equals the desired
count, it returns immediately without rebuilding.

**`DestroyBaseSlots`** detaches the cash triggers
(`IncomeService.ForgetCollectorsForSlots`) and the carry prompts
(`CarryPrompts.ForgetSlotsForBase`) **before** destroying the clones,
because after the destruction the slot ids are unrecoverable.

**The arena track** mirrors the same three. `BuildArenaStands` also calls
`refreshArenaRecords` even when it builds nothing, so the records always
follow the live clones. `ReconcileArenaStands` refuses to destroy an
occupied arena stand (`animal still seated`).

### Arena parts

```lua
DynamicSlotService.EnsureArenaStandParts(stand: Instance): boolean   -- 1056
```

Ensures a runtime arena stand carries the structural pieces the other
systems resolve through `StandResolver`:

- `Slot/MenuPart/MenuGui`
- `Button/Base` and `Button/PressPart`
- `SurfaceGui/Amount` — created with `TextColor (120,220,130)`,
  `Font GothamBold`, initial text `'$0'` when the template does not
  provide one.

Anything the authored template already provides is reused untouched; only
**missing** pieces are created in code, tagged with the attribute
`ArenaAutoPart = true`. Idempotent.

**Returns:** `true` on success, `false` only when the stand has no
resolvable root part at all. **Never throws** (the whole body is inside a
`pcall`).

### Test seam

```lua
DynamicSlotService._TestReset()   -- 1480
```

Drops the clone-tracking tables and the template caches. Test-only. Never
throws.

---

## `ServerScriptService/Base/BaseLockService`

The server-authoritative base lock.

### Type

```lua
export type LockRecord = {
    baseId: string,
    baseIndex: number,
    folder: Instance,
    button: BasePart?,
    label: TextLabel?,
    labelDefault: string?,
    laserParts: { BasePart },
    laserBaseline: { [BasePart]: { transparency: number, collide: boolean } },
    lockParts: { BasePart },
    locked: boolean,
    expiresAt: number,
    lastDebounce: number,
    lastLabelSecond: number?,
}
```

### Lifecycle

```lua
BaseLockService.Init()                                -- 767
```

Creates the collision groups, registers a lock record for every base, and
starts the single Heartbeat timer loop.

**Returns:** nothing. **Idempotent** — a second call returns immediately
(`_started` guard).

**Ordering:** must run **after** `BaseService.RegisterBases`. It calls
`BaseService.GetAllBases()` to enumerate the bases.

**Collision groups:** `_ensureGroups(math.max(count, 6))` creates
`BaseLock_<i>` and `BaseOwner_<i>` for `i = 1..count` (at least 6), and
wires the collision matrix so the owner passes their own base's lock and
nobody else does.

**Per base it registers:**

- the button (`LazerButton/PressPart`, a `BasePart`),
- the timer label (`LazerButton/BillboardGui/Timer`, with the legacy
  fallbacks),
- the laser parts (every `BasePart` under `LazerDoor/Lazers`; the ones
  named exactly `Part` are the animated ones),
- the lock geometry (every `BasePart` under `LazerDoor/Lazers` **and**
  under `Build/Hitbox`).

Each missing piece is reported with a `Debug.Warn` — never silently.

**A freshly registered base starts unlocked**: the geometry is applied in
the unlocked state, the laser is snapped retracted, and the label is
reset to its authored default.

**It also connects** `Players.PlayerAdded` (→ `CharacterAdded` →
`task.defer` → `RefreshCharacter`), the existing players, and
`Players.PlayerRemoving` (→ `ForgetPlayer`).

### Events

```lua
BaseLockService.SubscribeLockChanged(fn: (any) -> ())     -- 113
```

| Parameter | Type | Meaning |
|---|---|---|
| `fn` | `(any) -> ()` | Called with `{ baseId: string, locked: boolean }` on every lock transition. |

**Returns:** nothing. **Never throws.** A non-function argument is
ignored. Registering the same function twice is a no-op (idempotent per
function). Each listener is invoked inside a `pcall`, so a throwing
listener cannot break the lock.

Fired from `Lock` and `Unlock`, which cover button presses, timer
expiry, releases, and purchase grants.

### Queries

```lua
BaseLockService.IsLocked(baseId: string): boolean         -- 344
BaseLockService.GetRemainingTime(baseId: string): number  -- 349
BaseLockService.IsPurchasedOpen(baseId: string): boolean  -- 360
BaseLockService.HasPurchasedAccess(baseId: string, userId: number): boolean  -- 377
```

| Function | Returns |
|---|---|
| `IsLocked(baseId)` | `true` only if the base has a lock record **and** `rec.locked == true`. Unknown base → `false`. |
| `GetRemainingTime(baseId)` | The seconds left, `math.max(0, expiresAt - os.clock())`. `0` if the base is unknown **or not locked**. |
| `IsPurchasedOpen(baseId)` | `true` if **any** purchased door-access grant is held for the base. A non-string id → `false`. |
| `HasPurchasedAccess(baseId, userId)` | `true` if that specific player holds a grant. A non-string id or non-number userId → `false`. |

None of these throw.

### Lock transitions

```lua
BaseLockService.Lock(base: any): boolean                            -- 397
BaseLockService.Unlock(baseId: string)                              -- 447
BaseLockService.UnlockPurchased(baseId: string, purchaserUserId: number?)  -- 486
```

| Function | Description | Returns |
|---|---|---|
| `Lock(base)` | Starts the lock. Sets `expiresAt = os.clock() + LockDurationSeconds`, paints the duration immediately, applies the geometry, snaps the lasers, refreshes the owner's collision group, refreshes the paid grant-holders, fires `SubscribeLockChanged`, and logs the funnel event. | `true` if the lock was started. `false` if `base` is malformed, the base has no lock record, or the base is already locked and `RefreshOnPress` is off. |
| `Unlock(baseId)` | The full unlock sequence: state, geometry, visuals, timer label, owner character group, `SubscribeLockChanged`, grant-holder groups. **Idempotent** — unlocking an unlocked base is a no-op. | Nothing. |
| `UnlockPurchased(baseId, purchaserUserId)` | Records a paid door-access grant (if a `purchaserUserId` is given) and then unlocks the base. The owner can always re-lock afterwards — the grant is a per-buyer passthrough, never an owner-lock override. **Idempotent**: repeat receipts re-insert the same key, and calling it on an already-open base still records the grant. | Nothing. |

**`Lock` returns `false` (and changes nothing) on a re-press while
already locked, when `Bases.Lock.RefreshOnPress` is `false`** — the
shipped default. There is still only ever one timer per base.

**Grants are cleared only in `HandleBaseReleased`** — not on timer
expiry, not on a manual `Unlock`, not on a button press.

### The button

```lua
BaseLockService.HandleButtonTouched(rec: LockRecord, hit: Instance)   -- 524
```

The server-side `Touched` handler. **There is no remote involved.**

| Parameter | Type | Meaning |
|---|---|---|
| `rec` | `LockRecord` | The base's lock record. |
| `hit` | `Instance` | The part that was touched. |

**Returns:** nothing. **Never throws** — the notification and tutorial
calls are `pcall`'d.

**Order of checks:**

1. **Debounce** — if `os.clock() - rec.lastDebounce <
   Bases.Lock.ButtonDebounceSeconds` (1 s), return silently.
2. **Resolve the player** from the hit part (walking up the parents
   looking for a character). No player → return silently.
3. **Ownership** — re-read live from `BaseService.GetBaseById`. A
   non-owner (including a touch on an unowned base, where
   `ownerUserId` is `nil`) is **fully silent**: no warning UI, no
   warning SFX, no state change.
4. **Lock** — if `Lock` returns `true`, notify:
   `NotificationService.NotifySuccess(player, 'Lock_Success', { Duration = LockDurationSeconds })`
   and `TutorialSignals.Fire('BaseLocked', { UserId = ..., BaseId = ... })`.

**A press that `Lock` rejects is a total no-op** — no toast, no tutorial
signal, no analytics.

### Ownership lifecycle

```lua
BaseLockService.HandleBaseAssigned(userId: number)   -- 567
BaseLockService.HandleBaseReleased(baseId: string)   -- 580
```

| Function | Description |
|---|---|
| `HandleBaseAssigned(userId)` | A fresh assignment carries no lock: refreshes the player's character group so a stale owner-group from a previous base cannot linger. |
| `HandleBaseReleased(baseId)` | **Clears every purchased-access grant for the base**, then unlocks it. A new assignment starts with a clean door slate. |

Neither throws. `HandleBaseReleased` with a non-string or empty id is
skipped for the grant clearing, but the unlock still runs.

### Character collision

```lua
BaseLockService.RefreshCharacter(player: Player?)   -- 270
BaseLockService.ForgetPlayer(player: Player?)       -- 294
```

| Function | Description |
|---|---|
| `RefreshCharacter(player)` | Re-applies the correct collision group to the player's live character, and keeps late-added parts (accessories, tools) in sync via a `DescendantAdded` connection. Idempotent per character. |
| `ForgetPlayer(player)` | Disconnects the character's collision connections. |

**Returns:** nothing. **Never throws.** A `nil` or non-`Player` argument is
ignored. `RefreshCharacter` on a player with no `Character` still clears
the old connections and returns.

---

## `ServerScriptService/Base/LaserAnimation`

The laser barrier pose. **Instant** — no tween, no stagger, no waits.

### Type

```lua
export type LaserOriginal = { ... }   -- 48-51
```

### API

```lua
LaserAnimation.Register(baseId: string, laserParts: { BasePart })                        -- 118
LaserAnimation.Snap(baseId: string, laserParts: { BasePart }, locked: boolean)           -- 141
LaserAnimation.SetLocked(baseId: string, laserParts: { BasePart }, locked: boolean)      -- 172
LaserAnimation._TestReset()                                                             -- 61
```

| Function | Description |
|---|---|
| `Register(baseId, laserParts)` | Captures the authored state of each part once, then snaps it to the **retracted** pose. A freshly registered base always starts unlocked. |
| `Snap(baseId, laserParts, locked)` | Snaps the parts to a state instantly. `locked = true` → the full authored pose; `false` → the retracted pose. |
| `SetLocked(baseId, laserParts, locked)` | The same as `Snap`, with the same final Size/CFrame math. It is what `BaseLockService` calls. |
| `_TestReset()` | Test-only. Clears the captured originals and the generation counters. |

**Returns:** nothing. **Never throws.**

**Failure modes:** a non-string `baseId` returns immediately. A part that
is not a `BasePart`, has no parent, or was never captured is skipped
silently. The final `part.Size` / `part.CFrame` assignment is `pcall`'d.

**The pose is bottom-anchored.** `_groundPoint` (line 71) never moves, so
the laser grows *out of* the floor rather than scaling about its centre.
The retracted height is `Bases.Lock.LaserRetractedHeight` (`0.05`).

**`_cancelTween` (line 106) is a retained no-op** — a seam left over
from the old animated implementation. `TweenService` is not used
anywhere in this system.

---

## `ServerScriptService/Base/StandDisplayService`

Paints the stand's upgrade button.

### Injection

```lua
StandDisplayService.SetAnimalService(svc: any)     -- 67
StandDisplayService.SetUpgradeService(svc: any)    -- 71
StandDisplayService.SetSellService(_svc: any)      -- 75   -- compat NO-OP
StandDisplayService.SetEggService(_svc: any)       -- 81   -- compat NO-OP
StandDisplayService.SetPlayerService(_svc: any)    -- 86   -- compat NO-OP
```

`SetSellService`, `SetEggService` and `SetPlayerService` take a parameter
and **ignore it entirely**. They exist so the bootstrap stays
source-compatible with the source game. `SetAnimalService` and
`SetUpgradeService` are real.

**Returns:** nothing. Never throws.

### Lifecycle and painting

```lua
StandDisplayService.Init()          -- 297
StandDisplayService.RefreshSlot(slot: any)   -- 379
StandDisplayService.RefreshBase(base: any)   -- 489
```

| Function | Description |
|---|---|
| `Init()` | **Empty.** The service paints on demand, not at boot. |
| `RefreshSlot(slot)` | Paints one slot's upgrade button: the level readout, the next-level cost, or `'MAX'`. |
| `RefreshBase(base)` | Repaints **every** slot of a base — normal **and** arena. The arena upgrade readouts paint through this exact path. |

**Returns:** nothing. **Never throws** — the body is `pcall`'d.

**Failure modes:** a `slot` that is not a table returns immediately. A
`base` that is not a table, or has no `slots` table, returns immediately.

**Button ownership.** The only managed button is **`UpgradeButton`**.
Cloned `SellButton` instances are **destroyed** and authored ones are
**hidden** (lines 469-479) — the sell UI belongs to `SlotMenuService`.
Managed clones carry the attribute `StandMenuManaged = true`.

**The button set is chosen by the OCCUPANT, not the stand type:** an
animal → Upgrade only (full coverage); an egg, an empty slot, or anything
else → no managed button.

**The text is hardcoded** — `'MAX'`, `'Unavailable'`, `'%d >> %d'`, and
`'$' .. BigNumber.Format(cost)`. There is no localisation hook.

---

## `ServerScriptService/Base/PlayerBoard`

Paints the base's name/avatar board.

```lua
PlayerBoard.Refresh(baseFolder: Instance?, player: Player?)   -- 53
PlayerBoard.Clear(baseFolder: Instance?)                      -- 115
```

| Function | Description |
|---|---|
| `Refresh(baseFolder, player)` | Paints the display name and the avatar. A `nil` or non-`Player` argument falls back to `Clear` semantics. |
| `Clear(baseFolder)` | Restores the Studio-authored defaults (or blanks them if there are none). |

**Returns:** nothing. **Never throws.**

**Failure modes:** a `baseFolder` that is not an `Instance` returns
immediately. A base with no `PlayerBoard/Main/SurfaceGui/Frame` returns
without writing. Every missing piece degrades to a skipped write.

**The avatar is fetched on a `task.spawn` thread**, so it never blocks
assignment. Before painting, it re-checks that the player is still live
(`Players:GetPlayerByUserId`), that the board key is still cached, and
that the `ImageLabel` is still parented — so a late result can never
paint over a new owner.

The board path is `PlayerBoard/Main/SurfaceGui/Frame/{Name (TextLabel),
Avatar (ImageLabel)}`.

---

## `ServerScriptService/StandPresentation`

The egg idle-wobble loop.

### Predicates

```lua
StandPresentation.IsEggKind(kind: any): boolean     -- 95
StandPresentation.IsAnimalKind(kind: any): boolean   -- 99
```

| Function | Returns |
|---|---|
| `IsEggKind(kind)` | `true` for `SlotType.OccupantKind.Egg` **and for `nil`** (the legacy, unknown-kind path). `false` for `'animal'` and anything else. |
| `IsAnimalKind(kind)` | `true` only for `SlotType.OccupantKind.Animal`. |

Neither throws.

### Lifecycle

```lua
StandPresentation.Init()                                    -- 162
StandPresentation.Bind(model: any, occupantKind: any?)      -- 187
StandPresentation.Unbind(model: any)                        -- 223
StandPresentation.Rebase(model: any)                        -- 237
StandPresentation.Hold(model: any, seconds: number)         -- 262
StandPresentation._TestCount(): number                      -- 276
```

| Function | Description |
|---|---|
| `Init()` | Starts the **one** Heartbeat connection for the whole registry. **Idempotent** — a second call returns immediately. |
| `Bind(model, occupantKind)` | Binds a model to the loop, snapshotting its current pivot and scale as the eternal rest baseline. Call it right after every egg settle. Re-binding overwrites cleanly — it never accumulates. |
| `Unbind(model)` | Unbinds a model and clears any hold. |
| `Rebase(model)` | Re-snapshots the rest pivot and scale **without** resetting the wobble personality (no pose pop). Used after a level-up celebration changed the resting scale. |
| `Hold(model, seconds)` | Pauses the wobble writes for `seconds`. |
| `_TestCount()` | The number of currently bound models. Test-only. |

**Returns:** nothing (except `_TestCount`, which returns a number).
**Never throws** — every body is `pcall`'d.

**Failure modes:** a non-`Model`, a model with no parent, or an
explicit `'animal'` kind makes `Bind` a **silent no-op**. `Unbind`,
`Rebase` and `Hold` on an unbound model are no-ops.

**EGG-ONLY.** An explicit `'animal'` kind is rejected, so animals can
never enter the egg idle path even if a caller mis-wires. A `nil` kind
**binds** (the legacy egg paths and the unit tests pass no kind).

**The loop** runs at `MovementConfig.StandIdle.TickRate` = **30 Hz**
(the idle motion itself is ~0.45 Hz), and skips a write when neither the
bob nor the lean moved by at least `PoseEpsilon` (0.004 studs) or
`LeanEpsilon` (0.004 radians). A tick that throws is caught and logged
(`stand loop failed gracefully (wobble skipped this tick)`); the loop
keeps running.

---

## `ReplicatedStorage/Config/World/Bases`

The config module. It is data plus four validators.

```lua
Bases.ValidateBase(base: any): { string }    -- 121
Bases.ValidateStands(stands: any): { string } -- 283
Bases.ValidateLayout(layout: any): { string } -- 407
Bases.Validate(): { string }                 -- 427
```

| Function | Description | Returns |
|---|---|---|
| `ValidateBase(base)` | Validates the `Server` / `Count` / `Slots` / `Collector` section. | An array of error strings. **Empty means valid.** |
| `ValidateStands(stands)` | Validates the `Stands` section (labels, upgrade readout, amount label). | An array of error strings. |
| `ValidateLayout(layout)` | Validates the `Layout` section (the animal ring and the arena row). | An array of error strings. |
| `Validate()` | Runs all three. | An array of error strings. |

None of them throw — they collect problems and return them. The boot-time
`ConfigValidator` turns a non-empty array into a hard error in Studio and
a warning on a live server.

---

## Related documents

- [`README.md`](README.md)
- [`MEMORY.md`](MEMORY.md)
- [`Dependencies.md`](Dependencies.md)
- [`Setup.md`](Setup.md)
- [`Config.lua`](Config.lua)
