# BasesAndSlots — MEMORY

Dense engineering notes for a future agent. Real names, real line numbers,
real numbers. If something is absent, it is absent.

---

## 1. Purpose in one line

Own the world's bases, the per-base slot pool, the runtime stand layout, and
the server-authoritative base lock.

---

## 2. How it actually works, step by step

### 2.1 Boot: `BaseService.RegisterBases(workspace)` — `BaseService.lua:354`

1. `Validation.t.instanceOf('Workspace')(workspace)` — the **only** validation
   call in the file that actually throws.
2. `StandResolver.GetBasesFolder(workspace)` resolves the container:
   `Workspace.Map.Bases` first, then a top-level `Workspace.Bases` (bare
   test/dev workspaces only). If neither exists →
   **`error()`** naming the authoritative path (lines 366–375). The server
   **never creates** `Workspace.Bases`.
3. For `i = 1..Bases.Count` (8):
   - `BaseType.BuildId(i)` → `Base_<i>`. If the folder is missing, an empty
     `Folder` named `Base_<i>` is created — and then the Collector lookup
     fatals. A missing base folder is therefore a *fatal* error, not a skip.
   - Boot diagnostics `do` block (lines 397–429): prints the folder's direct
     children with class names, and the Collector's class /
     `IsABasePart` / `Anchored` / `CanTouch` / `CanCollide`. One `print` per
     base at boot, always on, never per-frame.
   - `Spawn`: authored `Part` is reused; otherwise one is created at
     `CFrame.new(i * 40, 0.5, 0)`, size `6,1,6`.
   - `SpawnLocation`: authored `SpawnLocation` reused; otherwise created at
     the `Spawn` CFrame, `CanCollide=false`, `CanQuery=false`,
     `CanTouch=false`, `Neutral=false`, `Enabled=true`,
     `AllowTeamChangeOnTouch=false`. Stored on `base.spawnLocation`.
     A `SpawnLocation` child that is not a `SpawnLocation` is discarded with
     a warn.
   - `_resolveCollector(baseFolder, spawn.CFrame.Position)` (line 125) →
     `(BasePart, CFrame)`. **Three fatal cases**, all `error()`:
     1. no `Collector` child → error naming the path;
     2. `Collector` is not a `BasePart` → error;
     3. `Collector` shares the Spawn's XZ position (within tolerance) →
        error "shares the XZ position".
     The returned CFrame is **yaw-only** (facing the collector), used as the
     rotation for every slot.
   - **Three mutually exclusive slot modes**, chosen by what the base folder
     contains:
     - **Dynamic** (`StandPos/StandPos<k>` markers present, `#markers > 0`):
       **ZERO slots are created**. The base holds no runtime slots until it is
       assigned. A gap check warns once per boot for each missing
       `StandPos<n>` in `1..max` — *holes, never renumbers*
       (`StandPos3` always means slot 3). The same rule applies to
       `ArenaStandPos<n>`.
     - **Static** (`AnimalStands/Stand<k>` present, no markers): one record
       per stand, plus **part-less records for the missing indices**
       `1..Bases.Slots.Count` so snapshots stay dense and a missing stand is
       loud rather than silently shifting every higher stand down an index
       (that shift would corrupt the Stand↔slot mapping persistence relies
       on). Nothing is auto-created.
     - **Legacy fallback** (neither): a `Slots` folder is created and
       `Slot<n>` parts are created at `Spawn.CFrame + Bases.Slots.Offsets[n]`
       with the collector-facing yaw. `_ensureCashCollector` (line 217)
       creates/attaches the `CashCollector` touch volume
       (`Height=4`, `Transparency=0.6`, `PartColor=(85,255,127)`).
       Authored `Slot<n>` parts keep their Studio position — only the yaw is
       rewritten.
   - The base record is created (fields in §4) and pushed to
   `slotServiceRef.RegisterBase(base)` when a SlotService was injected.
4. If any base is dynamic → `pcall(DynamicSlotService.GetTemplate)` so a
   missing template warns once at boot. Same for the arena template.
5. `pcall(require, script.Parent.Rebirth.RebirthService)` →
   `HideAllBaseMultipliers()` if available. **Lazy + pcall'd**: Rebirth is
   not in this library.

### 2.2 Assignment: `AssignBaseForPlayer(userId)` — `BaseService.lua:1078`

1. If the player already owns a base → that base is returned unchanged.
2. Otherwise scan `bases` for the first `state == 'Available'`, set
   `ownerUserId = userId`, `state = 'Occupied'`, **bump `base.session`**,
   and rebuild every slot's `id` to
   `SlotType.BuildId(userId, SlotType.Kind.Slot, slot.index)` (lines 1111,
   1118). Registered-but-unassigned slots carry `BuildId(0, ...)` — userId
   `0` — so the id only becomes the owner's once assigned.
3. Dynamic bases: `DynamicSlotService.BuildBaseSlots(base, userId, session)`
   clones the template into `Slot<k>` instances and places them.
4. `PointPlayerToBaseSpawn(player, base)` teleports the player and sets
   `player.RespawnLocation = base.spawnLocation`.

`AssignBaseById(userId, baseId)` (line 1228) is the same but with an
explicit base; it returns `nil` if that base is not `Available`.

`ReleasePlayerBase` / `ReleaseBase` bump the session again, which is what
invalidates every in-flight async callback for that base.

### 2.3 Session fencing — the central invariant

`base.session` is a monotonically increasing counter. `_bumpSession(base)`
(line 832) is called on every assign, release, cleanup and wipe.

The pattern used everywhere:

```lua
local session = base.session
task.spawn(function()
    -- ... await something ...
    if not BaseService.IsCurrentSession(baseId, session) then
        return  -- the base changed hands; drop this work
    end
    -- mutate
end)
```

`GetSession(baseId)` (line 803) returns the current counter or `nil`.
`IsCurrentSession(baseId, session)` (line 816) compares.
`DynamicSlotService.checkSession(base, session, tag, op)` (line 234) is the
local equivalent.

**If you add any async work that mutates a base, you must fence it.** This
is the single most important rule in the system.

### 2.4 Dynamic stands: `DynamicSlotService`

- `GetTemplate()` (line 277) resolves
  `ServerStorage.Assets.Map.Bases.Base.StandTemplate` — a `Model` or a
  `BasePart`. It must contain `Slot/Root` and `Button/PressPart`.
- `GetStandPositions(baseFolder)` (line 353) returns the `StandPos<k>`
  markers, **sorted by parsed index** (never by descendant order).
- `GetDesiredSlotCount(baseFolder, userId)` (line 364) →
  `min(unlocked.Animal, Bases.Slots.Count)`. `unlocked.Animal` comes from
  the **injected resolver** (`SetUnlockResolver`, line 91) — in the source
  game that is `RebirthService.ResolveRebirthForStands(userId)`.
- `BuildBaseSlots(base, userId, session)` (line 582) clones the template per
  slot, places it, and writes the records.
- Placement: the ring is computed in the base's **Center frame**:
  `Config.Layout.Animal` = `RadiusX 30`, `RadiusZ 30`,
  `RightStartAngle -45`, `RightEndAngle 45`, `ForwardOffset 0`,
  `FaceCenter true`. The LEFT arc mirrors the right one automatically
  (`180 - angle`). A single stand sits at the arc midpoint.
  `measureFrontOffset` (line 139) reads the template's own front offset so
  the clone's *visible* front, not its pivot, is what faces the centre.
  `orientTowardCenter` (line 180) then builds the CFrame.
- `ReconcileBaseSlots` (line 901) only rebuilds when the desired count
  changed — this is the cheap path called on every refresh.
- `DestroyBaseSlots(base, session)` (line 798) removes the clones.
- Records are built by `buildRecord` (line 463) — same shape as the static
  path's records.

### 2.5 Arena stands — a **separate track**

- Markers: `ArenaStandPos/ArenaStandPos<k>`.
- Container: `ArenaAnimalStands/ArenaStand<k>`.
- Template: `ServerStorage.Assets.Map.Bases.Base.ArenaStandTemplate`.
- Index namespace: `SlotType.ArenaSlotIndexBase` = **1000**, so the runtime
  index is `1000 + k` (k = 1..99 → 1001..1099). `SlotType.BuildId` asserts
  the index is in `1..99` **or** `1000..1099`.
- Records live in **`base.arenaSlots`**, NOT in `base.slots`. This is
  deliberate: every `base.slots` reader (capacity, HUD snapshots, egg
  placement) stays normal-only.
- `buildArenaRecord` (line 493) adds `arenaIndex`, `arena = true`, and
  `offset = Vector3.new(0, 2, 0)`.
- Arena occupancy does **not** move `base._occupiedCount`.
- `RebirthConfig.InitialStands = { Animal = 6, Arena = 1 }`; rebirths 1..5
  grant animal stands `{6,7,8,8,8}` and arena stands `{2,2,3,3,3}`.
- `EnsureArenaStandParts(stand)` (line 1056) creates the
  `SurfaceGui/Amount` TextLabel when the template lacks one:
  `TextColor (120,220,130)`, `Font GothamBold`, initial text `'$0'`.

### 2.6 The lock: `BaseLockService`

- `Init()` (line 767):
  - `_ensureGroups(math.max(baseCount, 6))` (line 777) creates the Roblox
    `PhysicsService` collision groups `BaseLock_<i>` and `BaseOwner_<i>`
    for `i = 1..count`, and sets their collision so only the owner passes
    through their own base's lock.
  - `_registerBase(base)` (line 665) per base: collects the lock geometry
    (every `BasePart` under `LazerDoor/Lazers` and under `Build/Hitbox`)
    and the timer label.
  - Starts **one** Heartbeat loop, `_update()` (line 632), which walks the
    lock records and unlocks any whose `expiresAt` has passed.
- `Lock(base)` (line 397):
  - if already locked and `Bases.Lock.RefreshOnPress` is `false` → returns
    **`false`**, no timer change.
  - otherwise `expiresAt = os.clock() + Bases.Lock.LockDurationSeconds`
    (60) and returns `true`.
- `HandleButtonTouched(rec, hit)` (line 524): the **server-side `Touched`
  handler** — there is **no remote**. It:
  1. resolves the player from the hit part (`_playerFromHit`, line 512);
  2. rejects anyone who is not the base owner;
  3. applies a per-button debounce of `Bases.Lock.ButtonDebounceSeconds` (1s);
  4. calls `Lock`;
  5. **only if `Lock` returned `true`** does it notify:
     `NotificationService.NotifySuccess` and `TutorialSignals.Fire`.
     A rejected press is a **total no-op — no toast**.
- `_applyGeometry(rec, locked)` (line 307) moves the laser parts and sets the
  label text (the remaining seconds) via `_setLabel` (line 332).
- `LaserAnimation` (line 118 `Register`, 141 `Snap`, 172 `SetLocked`) applies
  the laser pose. **It is INSTANT**: `_poseFor` (line 78) computes the final
  CFrame and the part is set directly. There is **no `TweenService`, no
  `task.wait`, no stagger**. `_cancelTween` (line 106) is a retained no-op
  seam from the old animated implementation.
  The pose is **bottom-anchored**: `_groundPoint` (line 71) never moves, so
  the laser grows out of the floor rather than scaling about its centre.
  Retracted height = `Bases.Lock.LaserRetractedHeight` = `0.05`.
- Collision groups: `_setCharacterGroup(player, group)` (line 191) sets the
  player's character collision group; `_wantedGroup(userId)` (line 221)
  returns the owner's group so the owner passes their own lock and nobody
  else does. `_clearCharConns` (line 203) disconnects on leave.
- `SubscribeLockChanged(fn)` (line 113) is the only event surface — a plain
  callback, **not** a remote. `_fireLockChanged(baseId, locked)` (line 125).
- Purchased unlocks: `_refreshPurchasers` (line 249) recomputes the set of
  users who paid to open the base. `IsPurchasedOpen(baseId)` (line 360) and
  `HasPurchasedAccess(baseId, userId)` (line 377) read it.
  **The grant set is cleared ONLY in `HandleBaseReleased` (line 580)** — not
  on timer expiry, not on manual `Unlock`.
- `HasPurchasedAccess` is also consulted by the lock's geometry so a
  purchaser can enter a base that is locked by its owner.

### 2.7 Stand display: `StandDisplayService`

- `Init()` (line 297) is empty. The service scans on demand.
- `RefreshSlot(slot)` (line 379) / `RefreshBase(base)` (line 489) paint the
  upgrade button on each stand menu.
- The only managed button is **`UpgradeButton`**. Cloned `SellButton`
  instances are **destroyed** and authored ones are **hidden**
  (lines 469–479) — the sell UI belongs to `SlotMenuService`.
- `MANAGED_ATTR = 'StandMenuManaged'` (line 154) marks the clones this
  service owns.
- The text is **hardcoded**: `'MAX'`, `'Unavailable'`, `'%d >> %d'`, and
  `'$' .. BigNumber.Format(cost)`. There is no localisation hook.
- `SetSellService` / `SetEggService` / `SetPlayerService` (lines 75, 81, 86)
  are **compat no-ops** — they take a parameter and ignore it.
- `SetAnimalService` / `SetUpgradeService` (lines 67, 71) are real.

### 2.8 Stand presentation: `StandPresentation`

- `Init()` (line 162) starts **one** Heartbeat connection for the whole
  registry. The loop runs at `MovementConfig.StandIdle.TickRate` = **30 Hz**
  (the idle motion itself is ~0.45 Hz).
- Epsilon deadbands: `POSE_EPSILON = 0.004` (studs),
  `LEAN_EPSILON = 0.004` (radians). A write is skipped when neither moved
  enough — roughly a third of ticks near motion extrema.
- **EGG-ONLY.** `_isEggKind` (line 85) returns `true` for `nil` (legacy
  unknown kind) and `true` only for `SlotType.OccupantKind.Egg`. An animal
  bound to it is silently ignored.
- `Bind(model, occupantKind?)` / `Unbind(model)` / `Rebase(model)` /
  `Hold(model, seconds)`.
- Requires `ReplicatedStorage.Utility.EggWalkAnimator`.

### 2.9 Player board: `PlayerBoard`

- `Refresh(baseFolder, player)` (line 53) paints the name and avatar.
- The avatar thumbnail is fetched on a **`task.spawn` thread** so it never
  blocks assignment, and there is a **live-player re-check** before
  painting (lines 97–99) — a player who left mid-fetch is not painted.
- `Clear(baseFolder)` (line 115) blanks it.

### 2.10 The base state machine — `Reserved`, not `Occupied`

`BaseType.State` has three values: `Available`, `Reserved`, `Occupied`.

- `Available` — free. Set at registration (line 684) and on release
  (lines 1394, 1700, 1872).
- `Reserved` — claimed by a player. Set by `AssignBaseForPlayer`
  (line 1105) and `AssignBaseById` (line 1251). **The base stays
  `Reserved` after assignment** — it does NOT become `Occupied`.
- `Occupied` — set **only** from the SlotService occupancy callback
  (line 311): `SetOccupiedCountCallback` increments
  `base._occupiedCount` and flips `Reserved` → `Occupied` on a positive
  delta.

**Arena slots are explicitly excluded** from that callback
(lines 301–303): `if slot.arena == true then return end`. Arena occupancy
is team membership, not base capacity, so it must never move
`_occupiedCount` or flip the base state.

Consequence: a freshly assigned base with an empty pool reports
`'Reserved'`, not `'Occupied'`. Any code that branches on
`GetBaseState(baseId) == 'Occupied'` will be wrong.

### 2.11 The slot API in `BaseService` is a **deprecated shim**

`GetFreeSlot`, `GetNearestValidSlotForPlayer`, `ReserveSlot`,
`DemoteSlotToReserved`, `OccupySlot`, `ReleaseSlot`,
`FindSlotByOccupant` and `ReleaseReservedSlotForUser` (lines 1420–1502)
all do the same thing: call `deprecate(method)` (line 1416), which logs
`Debug.Log('BS', 'DEPRECATION: <name> called via BaseService; route to
SlotService instead')`, and then **forward to `slotServiceRef`**.

If no SlotService is injected, every one of them returns its "no" value
(`nil` or `false`).

`SlotService` is the source of truth. `BaseService` keeps the surface
for one release so the existing call sites keep compiling.

`BaseService._findSlotById` (line 1478) is **exported despite the
underscore** and is a raw lookup with no session check, no ownership
check and no validation. Without a SlotService it falls back to a
`SlotType.ParseId`-based scan that matches `s.id == slotId` and warns on
a miss.

### 2.12 `PointPlayerToBaseSpawn` does NOT teleport

`PointPlayerToBaseSpawn(player, base)` (line 1207) **only sets
`player.RespawnLocation = base.spawnLocation`**. There is no
`PivotTo`, no `LoadCharacter`, no `Character:PivotTo`. The player is
moved to the base by Roblox's own spawn flow on the next character
load.

The docstring says so explicitly: *"on any failure returns false and
leaves any previous RespawnLocation untouched (callers must NOT call
LoadCharacter in that case)."*

**Failure modes:** `false` if the player is not a `Player`, the base
record is malformed, `base.spawnLocation` is not a `SpawnLocation`, or
the pad has been destroyed (no parent). On failure the previous
`RespawnLocation` is left alone.

### 2.13 The dynamic stand count is NOT capped by the marker count

`GetDesiredSlotCount` (line 364):

```
if #markers == 0 then return 0 end
if unlocked ~= nil then
    return math.min(unlocked.Animal, Bases.Slots.Count)
end
return math.min(#markers, Bases.Slots.Count)
```

With the unlock resolver wired, the marker count is **not** a cap — the
markers only anchor the ground plane, and the generated ring replaces
their positions. Without a resolver, the marker count **is** the cap.

`BuildBaseSlots` still refuses to build with **zero** markers, and warns
`ZERO StandPos markers found`.

The arena equivalent (`GetDesiredArenaStandCount`, line 1016) caps at
`SlotType.MaxArenaStands` = **99**, not at `Bases.Slots.Count`.

---

## 3. Public API surface (exact)

### `BaseService` (`ServerScriptService/BaseService.lua`)

```lua
BaseService.Init()                                              -- 264
BaseService.SetPlayerService(svc: any)                         -- 266
BaseService.SetEggService(svc: any)                            -- 270
BaseService.SetAnimalService(svc: any)                         -- 274
BaseService.SetBaseLockService(svc: any)                       -- 281
BaseService.SetSlotService(svc: any)                           -- 287
BaseService.RegisterBases(workspace: Instance)                 -- 354
BaseService.GetBaseById(baseId: string): any?                  -- 757
BaseService.GetBaseByOwner(userId: number): any?               -- 762
BaseService.GetPlayerBase(userId: number): any?                -- 771
BaseService.IsBaseOwnedByPlayer(baseId: string, userId: number): boolean  -- 778
BaseService.GetBaseState(baseId: string): string?              -- 786
BaseService.GetAllBases(): { [string]: any }                   -- 794
BaseService.GetSession(baseId: string): number?                -- 803
BaseService.IsCurrentSession(baseId: string, session: number): boolean    -- 816
BaseService.ValidateBaseRuntime(baseId: string): boolean       -- 936
BaseService.AssignBaseForPlayer(userId: number): any?          -- 1078
BaseService.PointPlayerToBaseSpawn(player: Player, base: any): boolean    -- 1207
BaseService.AssignBaseById(userId: number, baseId: string): any?          -- 1228
BaseService.ReleasePlayerBase(userId: number): boolean         -- 1314
BaseService.ReleaseBase(baseId: string, expectedUserId: number?): boolean -- 1323
BaseService.GetFreeSlot(userId: number): any?                  -- 1420
BaseService.GetNearestValidSlotForPlayer(userId: number, playerPos: Vector3): any?  -- 1430
BaseService.ReserveSlot(slotId: string): boolean              -- 1438
BaseService.DemoteSlotToReserved(slotId: string): boolean     -- 1446
BaseService.OccupySlot(slotId: string, occupantId: string, occupantKind: string?): boolean -- 1454
BaseService.ReleaseSlot(slotId: string): boolean              -- 1462
BaseService.FindSlotByOccupant(occupantId: string): (any?, any?)  -- 1470
BaseService._findSlotById(slotId: string): any?                -- 1478  (underscore-prefixed but EXPORTED)
BaseService.ReleaseReservedSlotForUser(userId: number, index: number): boolean  -- 1504
BaseService.RestorePlayerBase(userId: number, profileData: any) -- 1539
BaseService.WipePlayerData(userId: number)                     -- 1670
BaseService.Snapshot(userId: number): { slots: any, _occupiedCount: number }?  -- 1736
BaseService.CleanupPlayer(userId: number)                     -- 1784
```

**Not exported** (module-local — do not call, do not document as public):
`_resolveCollector` (125), `_ensureCashCollector` (217), `_bumpSession`
(832), `_resetSlotsAndSweep` (845), `deprecate` (1416), `COLLECTOR_RECIPE`
(89).

### `DynamicSlotService` (`ServerScriptService/Base/DynamicSlotService.lua`)

```lua
DynamicSlotService.SetUnlockResolver(fn: ((number) -> number)?)  -- 91
DynamicSlotService.GetTemplate(): Instance?                       -- 277
DynamicSlotService.GetStandPositions(baseFolder: Instance?): { Instance }  -- 353
DynamicSlotService.GetDesiredSlotCount(baseFolder: Instance?, _userId: number?): number  -- 364
DynamicSlotService.PlaceAtCFrame(clone: Instance, target: CFrame): boolean  -- 410
DynamicSlotService.PlaceAtStandPos(clone: Instance, marker: Instance): boolean  -- 433
DynamicSlotService.ArenaSlotIndexBase(): number                  -- 459
DynamicSlotService.BuildBaseSlots(base: any, userId: number, session: number): number   -- 582
DynamicSlotService.DestroyBaseSlots(base: any, session: number): number  -- 798
DynamicSlotService.ReconcileBaseSlots(base: any, userId: number, session: number): number -- 901
DynamicSlotService.GetArenaTemplate(): Instance?                 -- 983
DynamicSlotService.GetArenaStandPositions(baseFolder: Instance?): { Instance }  -- 1008
DynamicSlotService.GetDesiredArenaStandCount(baseFolder: Instance?, _userId: number?): number  -- 1016
DynamicSlotService.EnsureArenaStandParts(stand: Instance): boolean  -- 1056
DynamicSlotService.BuildArenaStands(base: any, userId: number, session: number): number  -- 1152
DynamicSlotService.DestroyArenaStands(base: any, session: number): number  -- 1351
DynamicSlotService.ReconcileArenaStands(base: any, userId: number, session: number): number -- 1424
DynamicSlotService._TestReset()                                  -- 1480
```

**Not exported:** `resolveUnlocked` (100), `baseFrame` (118),
`measureFrontOffset` (139), `orientTowardCenter` (180), `layoutCenter` (197),
`checkSession` (234), `ensureContainer` (254), `templatePath` (270),
`markerWorldCFrame` (386), `buildRecord` (463), `buildArenaRecord` (493),
`rebuildArenaRecords` (523), `refreshArenaRecords` (562),
`arenaTemplatePath` (976), `mkArenaPart` (1030).

### `BaseLockService` (`ServerScriptService/Base/BaseLockService.lua`)

```lua
export type LockRecord = { ... }                                -- 69-83
BaseLockService.SubscribeLockChanged(fn: (any) -> ())          -- 113
BaseLockService.RefreshCharacter(player: Player?)               -- 270
BaseLockService.ForgetPlayer(player: Player?)                   -- 294
BaseLockService.IsLocked(baseId: string): boolean               -- 344
BaseLockService.GetRemainingTime(baseId: string): number        -- 349
BaseLockService.IsPurchasedOpen(baseId: string): boolean        -- 360
BaseLockService.HasPurchasedAccess(baseId: string, userId: number): boolean  -- 377
BaseLockService.Lock(base: any): boolean                        -- 397
BaseLockService.Unlock(baseId: string)                          -- 447
BaseLockService.UnlockPurchased(baseId: string, purchaserUserId: number?)  -- 486
BaseLockService.HandleButtonTouched(rec: LockRecord, hit: Instance)  -- 524
BaseLockService.HandleBaseAssigned(userId: number)              -- 567
BaseLockService.HandleBaseReleased(baseId: string)              -- 580
BaseLockService.Init()                                          -- 767
```

**Not exported:** `_lockGroup` (133), `_ownerGroup` (137), `_ensureGroups`
(144), `_collectBaseParts` (176), `_setCharacterGroup` (191),
`_clearCharConns` (203), `_wantedGroup` (221), `_refreshPurchasers` (249),
`_applyGeometry` (307), `_setLabel` (332), `_fireLockChanged` (125),
`_playerFromHit` (512), `_resolveLabel` (596), `_update` (632),
`_registerBase` (665).

### `LaserAnimation` (`ServerScriptService/Base/LaserAnimation.lua`)

```lua
export type LaserOriginal = { ... }                             -- 48-51
LaserAnimation._TestReset()                                     -- 61
LaserAnimation.Register(baseId: string, laserParts: { BasePart })  -- 118
LaserAnimation.Snap(baseId: string, laserParts: { BasePart }, locked: boolean)  -- 141
LaserAnimation.SetLocked(baseId: string, laserParts: { BasePart }, locked: boolean)  -- 172
```

**Not exported:** `_groundPoint` (71), `_poseFor` (78), `_fullPose` (89),
`_capture` (96), `_cancelTween` (106).

### `StandDisplayService` (`ServerScriptService/Base/StandDisplayService.lua`)

```lua
StandDisplayService.SetAnimalService(svc: any)                  -- 67
StandDisplayService.SetUpgradeService(svc: any)                 -- 71
StandDisplayService.SetSellService(_svc: any)                   -- 75  (no-op)
StandDisplayService.SetEggService(_svc: any)                    -- 81  (no-op)
StandDisplayService.SetPlayerService(_svc: any)                 -- 86  (no-op)
StandDisplayService.Init()                                      -- 297 (empty)
StandDisplayService.RefreshSlot(slot: any)                      -- 379
StandDisplayService.RefreshBase(base: any)                      -- 489
```

**Not exported:** `_writeLabels` (100), `_resolveAnimal` (119), `warnOnce`
(159), `templateRoot` (167), `resolveTemplate` (181), `managedButtons` (213),
`authoredButton` (225), `fitButton` (238), `removeObsoleteLayout` (254),
`cloneButton` (269), `upgradeLabelsOf` (301), `paintUpgrade` (323).

### `StandPresentation` (`ServerScriptService/StandPresentation.lua`)

```lua
StandPresentation.IsEggKind(kind: any): boolean                 -- 95
StandPresentation.IsAnimalKind(kind: any): boolean               -- 99
StandPresentation.Init()                                        -- 162
StandPresentation.Bind(model: any, occupantKind: any?)          -- 187
StandPresentation.Unbind(model: any)                            -- 223
StandPresentation.Rebase(model: any)                            -- 237
StandPresentation.Hold(model: any, seconds: number)             -- 262
StandPresentation._TestCount(): number                          -- 276
```

**Not exported:** `_isEggKind` (85), `_update` (121).

### `PlayerBoard` (`ServerScriptService/Base/PlayerBoard.lua`)

```lua
PlayerBoard.Refresh(baseFolder: Instance?, player: Player?)     -- 53
PlayerBoard.Clear(baseFolder: Instance?)                        -- 115
```

**Not exported:** `_keyFor` (36), `_rememberDefaults` (40).

### `Config.World.Bases` (`ReplicatedStorage/Config/World/Bases.lua`)

```lua
Bases.ValidateBase(base: any): { string }    -- 121
Bases.ValidateStands(stands: any): { string } -- 283
Bases.ValidateLayout(layout: any): { string } -- 407
Bases.Validate(): { string }                 -- 427
```

---

## 4. Invariants and rules enforced

1. **A base always has a Collector.** Missing, wrong class, or degenerate
   placement is fatal. The Collector's XZ must differ from the Spawn's —
   the Collector encodes the base's orientation, so the server refuses to
   guess one.
2. **Slot indices never shift.** A missing `StandPos<k>` / `Stand<k>` is a
   *hole*, not a renumber. `StandPos3` always means slot 3. The static path
   compensates by registering part-less records so snapshots stay dense.
3. **A base in dynamic mode holds zero runtime slots while unassigned.**
   Clones are built on assign and destroyed on release, so a new owner can
   never inherit the previous owner's state.
4. **`base.session` is bumped on every assign / release / cleanup / wipe.**
   Every async callback must re-check it.
5. **The arena track is separate.** Arena records live in `base.arenaSlots`
   with index `1000 + k`. `base.slots` readers never see them.
6. **The lock is server-side and touch-driven.** No remote is fired by any
   module in this system.
7. **Only the owner passes their own lock.** Collision groups
   `BaseLock_<i>` / `BaseOwner_<i>` per base.
8. **One lock timer per base.** A second press cannot stack timers; with
   `RefreshOnPress = false` it does nothing at all.
9. **The laser pose is bottom-anchored and instant.** The ground point
   never moves; the part is set directly, not tweened.
10. **The stand idle loop is a single connection for the whole registry**,
    at 30 Hz, with epsilon deadbands.
11. **Slot ids are re-stamped on assignment** to
    `p7:<userId>:slot:<index>`; while unassigned they are
    `p7:0:slot:<index>`.

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `Workspace.Map.Bases` missing | `error()` naming the authoritative path. The server does NOT create a top-level `Workspace.Bases`. |
| `Base_<i>` folder missing | An empty Folder is created, then the Collector lookup **fatals**. |
| `Collector` missing | `error()` naming the path. |
| `Collector` not a `BasePart` | `error()`. |
| `Collector` shares the Spawn's XZ | `error()` — "shares the XZ position". |
| `Spawn` missing | Auto-created at `CFrame.new(i*40, 0.5, 0)`, size `6,1,6`. |
| `SpawnLocation` missing | Auto-created at the `Spawn` CFrame, `CanCollide/CanQuery/CanTouch = false`. |
| `SpawnLocation` present but the wrong class | Discarded with a warn; a new one is created. |
| A `StandPos<n>` index is missing | `warn` once at boot. The index stays a hole. |
| A `Stand<k>` is missing (static path) | `warn`, and a part-less record is registered for that index. |
| `StandTemplate` missing | `warn` at boot; **each affected base fails closed at assign time**. |
| `GetTemplate` returns nil | `BuildBaseSlots` returns 0 — the base ends up with no slots. |
| `AssignBaseForPlayer` with no free base | Returns `nil`. The caller must handle it (the bootstrap kicks the player). |
| `AssignBaseById` on a non-`Available` base | Returns `nil`. |
| `PointPlayerToBaseSpawn` failure | Returns `false`; the bootstrap then releases the base, cleans the player up, and kicks. |
| `Lock` on an already-locked base | Returns `false`; no timer change, no notification. |
| `HandleButtonTouched` from a non-owner | Ignored silently. |
| `HandleButtonTouched` within the 1 s debounce | Ignored. |
| `HandleButtonTouched` that `Lock` rejects | **Total no-op — no toast, no tutorial signal, no analytics.** |
| Lock timer expires | `_update` unlocks it, applies the geometry, fires `SubscribeLockChanged`. |
| `UnlockPurchased` with a `nil` purchaser | Unlocks for all purchasers. |
| A purchased-unlock grant after the timer expires | **The grant survives** — it is only cleared in `HandleBaseReleased`. |
| `GetFreeSlot` with a full pool | Returns `nil`. |
| `OccupySlot` on a non-empty slot | Returns `false`. |
| `RestorePlayerBase` with a `SlotId` that no longer resolves | The record is re-homed to a free slot and `record.SlotId` is **mutated in place** (line 1628). |
| `RestorePlayerBase` with an egg pointing at an **arena** slot | Rejected and re-homed to a normal slot (lines 1583–1592). |
| `Snapshot` for a player with no base | Returns `nil`. |
| `Snapshot` shape | `{ slots = {...}, _occupiedCount = number }`. Arena entries are appended with an `Arena = true` marker. |

---

## 6. Gotchas that will bite you

1. **`Validation.PositiveInteger` and `Validation.ShortString` RETURN
   BOOLEANS.** `BaseService` calls them as bare statements (e.g. line 1080
   `Validation.PositiveInteger(userId)`), so the result is **discarded and
   the guard never throws**. `Validation.t.instanceOf('Workspace')` is the
   only check in `BaseService` that actually throws. Do not assume the
   other guards protect you.
2. **`LaserExtendSeconds` / `LaserRetractSeconds` / `LaserStaggerSeconds`
   are dead.** Nothing reads them. `LaserAnimation` is instant.
3. **`BaseLockService` has three top-level requires that are NOT in this
   library**: `Base/NotificationService`, `Tutorial/TutorialSignals`,
   `FunnelService`. The module will not load without them.
4. **A second lock press is silent.** `RefreshOnPress = false` and
   `HandleButtonTouched` only notifies when `Lock` returns `true`. A player
   who presses again sees nothing at all.
5. **Purchased grants outlive the lock.** Cleared only in
   `HandleBaseReleased`.
6. **`StandPresentation` is egg-only**, and treats `nil` kind as an egg.
7. **`StandDisplayService` destroys cloned `SellButton`s** and hides
   authored ones (lines 469–479). If you add a sell button to the stand
   menu, this service will remove it.
8. **The stand display text is hardcoded English** — `'MAX'`,
   `'Unavailable'`, `'%d >> %d'`.
9. **Arena records are invisible to `base.slots` readers.** If you add a
   feature that counts a player's animals, decide explicitly whether arena
   stands count.
10. **The header comments are stale.** `BaseService.lua:7` says "the
    6-base registry" and `BaseLockService.lua:11-12` says
    `BaseLock_1..6` / `BaseOwner_1..6` / "all ≤6 timers", but
    `Bases.Count` is **8** and `_ensureGroups(math.max(count, 6))` creates
    8 groups. The behaviour is right; the comments are not.
11. **`Tests/BaseLockTimer.spec.lua:99` asserts `LockDurationSeconds == 30`**
    while the config says **60** (`Bases.lua:187`).
    `Tests/Bases.spec.lua:68` correctly asserts 60. The BaseLockTimer spec
    is stale and will fail as shipped.
12. **`Tests/BaseService.spec.lua:9,25`** prose says "single 6-slot pool"
    while the asserts use `Bases.Slots.Count` (= 8).
13. **`BaseService._findSlotById` is exported** despite the underscore. It
    is a raw table lookup with no session or ownership check — do not use it
    from outside.
14. **`RegisterBases` uses `Bases.Count` (8), not the number of folders it
    found.** Extra `Base_<n>` folders beyond 8 are ignored; missing ones
    fatal.
15. **`base.slots` is keyed by NUMBER, but slot `id` is a STRING.** Both
    are present; `slots[standIndex]` with `slot.id = 'p7:...'`. Do not
    confuse the two.
16. **The `Tests/_Helpers.lua` shared helper requires systems this library
    does not contain** (`SlotService`, `EggService`, `AnimalService`,
    `IncomeService`, `SellService`, `UpgradeService`, `ModifierService`), so
    the specs cannot run against this library in isolation.
17. **`BaseService`'s slot API is a deprecated shim.** `GetFreeSlot`,
    `ReserveSlot`, `OccupySlot`, `ReleaseSlot`, `FindSlotByOccupant` and
    friends all forward to `SlotService` and log a deprecation line. With
    no SlotService injected, they all return `nil`/`false`. Call
    `SlotService` directly in new code.
18. **A base is `Reserved`, not `Occupied`, after assignment.** The
    `Occupied` state is only reached when a slot is actually filled
    (via SlotService's occupancy callback). Arena slots never trigger
    it. Do not branch on `state == 'Occupied'`.
19. **`PointPlayerToBaseSpawn` does not teleport.** It sets
    `player.RespawnLocation`. There is no `PivotTo` and no
    `LoadCharacter`.
20. **`StandDisplayService.Init()` is empty.** The service paints on
    demand; nothing happens at boot.
21. **The dynamic stand count is not capped by the marker count** when
    the unlock resolver is wired — only by `Bases.Slots.Count`. Markers
    anchor the ground plane; the ring is generated.
22. **`Bases.Slots.Offsets` is not used for placement in the dynamic
    path.** It is only copied onto the record as `slot.offset`
    (documentation). The real placement comes from `Config.Layout`.

---

## 7. What to change to reuse it

| To change | Where | Note |
|---|---|---|
| The project prefix in slot ids | `Shared/Types/SlotType.lua` `BuildId` | `p7:<userId>:slot:<index>` → your prefix. Keep it consistent with the DataStore prefix. |
| The base id format | `Shared/Types/BaseType.lua` `BuildId` | `Base_<n>`, n = 1..99. |
| The number of bases | `Config/World/Bases.lua` `Bases.Count` | Must match the authored map. |
| The slot pool size | `Config/World/Bases.lua` `Bases.Slots.Count` | Also the cap on the dynamic count. |
| The arena index namespace | `Shared/Types/SlotType.lua` `ArenaSlotIndexBase` | Currently 1000. `BuildId` asserts `1000..1099`. |
| The map layout | `Config/World/Bases.lua` `Bases.Layout.*` | Ring radii, angles, arena row Z and spacing. |
| The lock duration | `Config/World/Bases.lua` `Bases.Lock.LockDurationSeconds` | 60. |
| The lock button behaviour | `Config/World/Bases.lua` `Bases.Lock.RefreshOnPress` | `false` → a second press is a no-op. |
| The container path | `Shared/CommonModules/StandResolver.lua` `GetBasesFolder` | `Workspace.Map.Bases`, falling back to `Workspace.Bases`. |
| The out-of-library requires | `Base/BaseLockService.lua:59,60,62` | `NotificationService`, `TutorialSignals`, `FunnelService`. Guard with `pcall` to make them optional. |
| The stand text | `Base/StandDisplayService.lua` `_writeLabels` (100) | `'MAX'`, `'Unavailable'`, `'%d >> %d'`, `'$' .. BigNumber.Format(cost)`. |
| The slot id userId at registration | `BaseService.lua:569,602,660` | `BuildId(0, ...)` → `BuildId(userId, ...)` on assignment. |
| The `Snapshot` shape | `BaseService.lua:1736` | `{ slots = {...}, _occupiedCount = number }`; arena entries carry `Arena = true`. |

---

## 8. Companion documents

- [`README.md`](README.md) — the overview, entry-point table, and limitations.
- [`API.md`](API.md) — every public function, with parameters and failure modes.
- [`Dependencies.md`](Dependencies.md) — exact module paths, remotes, assets, init order.
- [`Setup.md`](Setup.md) — step-by-step installation into a new Rojo project.
- [`Config.lua`](Config.lua) — the consolidated tunables.
