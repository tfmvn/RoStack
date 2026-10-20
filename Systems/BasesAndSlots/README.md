# BasesAndSlots

Owns the base registry, the per-base slot pool, the dynamic stand layout,
and the server-authoritative base lock.

**Portability:** Grade A core (the base registry, the slot pool, the
session-fencing model, the dynamic stand builder, the lock/laser
mechanism) + Grade B (the `Base_<n>` / `StandPos<k>` / `ArenaStandPos<k>`
naming convention, the `p7:<userId>:slot:<n>` id format, and the
`Workspace.Map.Bases` map layout are Brainrot Arena's).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

The system is three cooperating services plus two presentation helpers.

- **`BaseService`** is the single owner of the base registry. It registers
  the world's bases, assigns one to each player, holds the unified slot pool
  (eggs and animals share one pool per base), and fences every async
  operation behind a **session counter** so a stale callback can never
  mutate a base that has since been reassigned.
- **`DynamicSlotService`** builds the runtime stands. The Studio map contains
  *markers* (`StandPos<k>`), not stands; the server clones a
  `StandTemplate` into `Slot<k>` instances and places them on a computed
  ring around the base. A second, separate track builds the **arena row**
  (`ArenaStandPos<k>` → `ArenaStand<k>`) whose records live in
  `base.arenaSlots`, *not* in `base.slots`.
- **`BaseLockService`** implements the server-authoritative base lock: one
  owner presses a button, the base is sealed for 60 seconds, the laser
  barrier goes up, and everyone else is pushed out by per-base Roblox
  **collision groups**. It also owns the laser pose itself, via
  `LaserAnimation`.
- **`StandDisplayService`** paints the upgrade button on each stand menu
  (level readout, next-level cost, `MAX`).
- **`StandPresentation`** drives the idle wobble of eggs standing in their
  slots.
- **`PlayerBoard`** paints the name/avatar board at the base.

The whole system is **server-authoritative**. Clients never send "lock this
base" or "give me a slot" — they send intent, and the server re-resolves
ownership, eligibility and pricing itself.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `BaseService.Init()` | Server | Creates the empty registry. Must run before `RegisterBases`. |
| `BaseService.RegisterBases(workspace)` | Server | Scans `Workspace.Map.Bases` and builds the registry. **Errors** if a base has no Collector. |
| `BaseService.AssignBaseForPlayer(userId)` | Server | Picks a free base for a joining player. Returns the base record, or `nil`. |
| `BaseService.AssignBaseById(userId, baseId)` | Server | Assigns a specific base. Returns the record, or `nil` if the base is not `Available`. |
| `BaseService.ReleasePlayerBase(userId)` | Server | Frees the player's base and everything in it. |
| `BaseService.ReleaseBase(baseId, expectedUserId?)` | Server | Frees a base. `expectedUserId` is an optimistic-concurrency guard. |
| `BaseService.PointPlayerToBaseSpawn(player, base)` | Server | Sets `player.RespawnLocation` to the base's `SpawnLocation`. Does **not** teleport. Returns `false` on failure. |
| `BaseService.RestorePlayerBase(userId, profileData)` | Server | Re-homes persisted slot records onto the current session's slots. |
| `BaseService.GetPlayerBase(userId)` | Server | The player's base record, or `nil`. |
| `BaseService.GetBaseById(baseId)` | Server | One base record, or `nil`. |
| `BaseService.GetBaseByOwner(userId)` | Server | The base owned by a user, or `nil`. |
| `BaseService.GetBaseState(baseId)` | Server | `'Available'`, `'Reserved'` or `'Occupied'`, or `nil` if unknown. |
| `BaseService.GetAllBases()` | Server | `{ [baseId] = record }`. |
| `BaseService.IsBaseOwnedByPlayer(baseId, userId)` | Server | Ownership check. |
| `BaseService.GetSession(baseId)` | Server | The current session counter for a base, or `nil`. |
| `BaseService.IsCurrentSession(baseId, session)` | Server | **The fencing check.** Every async callback must pass this before mutating. |
| `BaseService.ValidateBaseRuntime(baseId)` | Server | Re-validates a base's runtime invariants. Returns a boolean. |
| `BaseService.GetFreeSlot(userId)` | Server | **Deprecated shim** → `SlotService`. A free slot record for the user's base, or `nil`. |
| `BaseService.GetNearestValidSlotForPlayer(userId, playerPos)` | Server | **Deprecated shim** → `SlotService`. The free slot nearest a world position. |
| `BaseService.ReserveSlot(slotId)` / `OccupySlot` / `ReleaseSlot` | Server | **Deprecated shims** → `SlotService`. The slot state machine. |
| `BaseService.DemoteSlotToReserved(slotId)` | Server | **Deprecated shim** → `SlotService`. Occupied → Reserved, without freeing it. |
| `BaseService.FindSlotByOccupant(occupantId)` | Server | **Deprecated shim** → `SlotService`. `(base, slot)` for an occupant id, or `(nil, nil)`. |
| `BaseService.ReleaseReservedSlotForUser(userId, index)` | Server | **Deprecated shim** → `SlotService`. Frees a reserved slot by index. |
| `BaseService.Snapshot(userId)` | Server | `{ slots = {...}, _occupiedCount = number }`, or `nil`. |
| `BaseService.CleanupPlayer(userId)` | Server | Leave-path teardown. |
| `BaseService.WipePlayerData(userId)` | Server | Admin wipe: releases the base, then re-assigns. |
| `BaseService.SetPlayerService` / `SetEggService` / `SetAnimalService` / `SetSlotService` / `SetBaseLockService` | Server | Late-bound injection. See *Initialization Order*. |
| `DynamicSlotService.SetUnlockResolver(fn)` | Server | Injects "how many stands does this user have unlocked". |
| `DynamicSlotService.BuildBaseSlots(base, userId, session)` | Server | Clones and places the `Slot<k>` stands. Returns the count. |
| `DynamicSlotService.ReconcileBaseSlots(base, userId, session)` | Server | Rebuilds only when the desired count changed. |
| `DynamicSlotService.DestroyBaseSlots(base, session)` | Server | Destroys the runtime stands. |
| `DynamicSlotService.BuildArenaStands` / `ReconcileArenaStands` / `DestroyArenaStands` | Server | The same three, for the arena row. |
| `DynamicSlotService.GetTemplate()` / `GetArenaTemplate()` | Server | The `ServerStorage` templates, or `nil`. |
| `DynamicSlotService.GetStandPositions(baseFolder)` / `GetArenaStandPositions(baseFolder)` | Server | The sorted `StandPos<k>` / `ArenaStandPos<k>` markers. |
| `DynamicSlotService.GetDesiredSlotCount(baseFolder, userId)` | Server | `min(unlocked.Animal, Bases.Slots.Count)`. |
| `DynamicSlotService.ArenaSlotIndexBase()` | Server | `1000` — the arena index namespace. |
| `BaseLockService.Init()` | Server | Creates collision groups, registers the bases, starts the timer loop. |
| `BaseLockService.Lock(base)` | Server | Locks a base. Returns `false` if it is already locked and `RefreshOnPress` is off. |
| `BaseLockService.Unlock(baseId)` | Server | Ends the lock early. |
| `BaseLockService.UnlockPurchased(baseId, purchaserUserId?)` | Server | Ends the lock for a paid purchase. |
| `BaseLockService.IsLocked(baseId)` / `GetRemainingTime(baseId)` | Server | The lock state and the seconds left. |
| `BaseLockService.IsPurchasedOpen(baseId)` / `HasPurchasedAccess(baseId, userId)` | Server | The "paid to unlock" grants. |
| `BaseLockService.HandleButtonTouched(rec, hit)` | Server | The server-side `Touched` handler. **No remote is fired.** |
| `BaseLockService.HandleBaseAssigned(userId)` / `HandleBaseReleased(baseId)` | Server | Lifecycle hooks. |
| `BaseLockService.RefreshCharacter(player)` / `ForgetPlayer(player)` | Server | Collision-group assignment for a character. |
| `BaseLockService.SubscribeLockChanged(fn)` | Server | The only event surface — a callback, not a remote. |
| `StandDisplayService.Init()` | Server | Scans the existing stands and paints them. |
| `StandDisplayService.RefreshSlot(slot)` / `RefreshBase(base)` | Server | Repaints one slot / one base. |
| `StandDisplayService.SetAnimalService` / `SetUpgradeService` | Server | Late-bound injection. The other three `Set*` are compat no-ops. |
| `LaserAnimation.Register` / `Snap` / `SetLocked` | Server | The laser pose. **Instant** — no tween. |
| `StandPresentation.Init()` | Server | Starts the shared idle loop. |
| `StandPresentation.Bind(model, occupantKind?)` / `Unbind(model)` / `Rebase(model)` | Server | Binds a model to the loop. |
| `StandPresentation.Hold(model, seconds)` | Server | Freezes a model for a while. |
| `StandPresentation.IsEggKind(kind)` / `IsAnimalKind(kind)` | Server | Kind predicates. |
| `PlayerBoard.Refresh(baseFolder, player)` / `Clear(baseFolder)` | Server | Paints / clears the board. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/BaseService.lua` | `ServerScriptService.BaseService` | The base registry owner. |
| `Source/ServerScriptService/Base/DynamicSlotService.lua` | `ServerScriptService.Base.DynamicSlotService` | The dynamic stand builder. |
| `Source/ServerScriptService/Base/BaseLockService.lua` | `ServerScriptService.Base.BaseLockService` | The server-authoritative base lock. |
| `Source/ServerScriptService/Base/LaserAnimation.lua` | `ServerScriptService.Base.LaserAnimation` | The laser barrier pose. |
| `Source/ServerScriptService/Base/StandDisplayService.lua` | `ServerScriptService.Base.StandDisplayService` | The stand upgrade button painter. |
| `Source/ServerScriptService/Base/PlayerBoard.lua` | `ServerScriptService.Base.PlayerBoard` | The base's name/avatar board. |
| `Source/ServerScriptService/StandPresentation.lua` | `ServerScriptService.StandPresentation` | The egg idle-wobble loop. |
| `Source/ReplicatedStorage/Config/World/Bases.lua` | `ReplicatedStorage.Config.World.Bases` | The canonical config for this system. |
| `Config.lua` | `ReplicatedStorage.Config.World.Bases` *(alternative)* | The same config, with a per-field comment for every tunable. A structural drop-in for the file above. |

---

## Configuration

The canonical config is `ReplicatedStorage/Config/World/Bases.lua`, shipped
verbatim in this library. [`Config.lua`](Config.lua) is the **same module
with a per-field comment for every tunable** — same field paths, same
values, same `Validate*` functions — so it is a structural drop-in for
the shipped file. The services require
`ReplicatedStorage.Config.World.Bases` directly.

| Key | Default | Read by |
|---|---|---|
| `Bases.Server.MaxPlayers` | `5` | the bootstrap only (not this system) |
| `Bases.Count` | `8` | `BaseService.RegisterBases` |
| `Bases.Slots.Count` | `8` | `BaseService`, `DynamicSlotService.GetDesiredSlotCount` |
| `Bases.Slots.Size` | `Vector3.new(3.5, 0.6, 3.5)` | `BaseService` (legacy `Slots` path) |
| `Bases.Slots.Offsets` | 8-stop ring, radius 12, Y 2 | `BaseService` (legacy path) |
| `Bases.Collector.Height` / `PartColor` / `Transparency` | `4` / `(85,255,127)` / `0.6` | `BaseService._ensureCashCollector` (legacy path) |
| `Bases.Lock.LockDurationSeconds` | `60` | `BaseLockService` |
| `Bases.Lock.ButtonDebounceSeconds` | `1` | `BaseLockService.HandleButtonTouched` |
| `Bases.Lock.RefreshOnPress` | `false` | `BaseLockService.Lock` |
| `Bases.Lock.LaserRetractedHeight` | `0.05` | `LaserAnimation` |
| `Bases.Lock.LaserExtendSeconds` / `LaserRetractSeconds` / `LaserStaggerSeconds` | `0.4` / `0.3` / `0.025` | **nothing — dead** |
| `Bases.Stands.AmountLabel.*` | `(120,220,130)`, GothamBold, `'$0'` | `DynamicSlotService.EnsureArenaStandParts` |
| `Bases.Layout.Animal.*` | `RadiusX 30`, `RadiusZ 30`, `-45..45`, `ForwardOffset 0`, `FaceCenter true` | `DynamicSlotService.BuildBaseSlots` |
| `Bases.Layout.Arena.*` | `Z -25`, `Spacing 10`, `FaceCenter true` | `DynamicSlotService.BuildArenaStands` |

Config keys **read by other systems, not by this one** — listed here so you
do not think they are broken:
`Stands.Labels.*` and `Stands.UpgradeReadout.RateDecimals` (read by
`SlotMenuService`), `MoneyPool.*` (read by the client's
`MoneyPoolController`), `Collector.Feel` (read by `Base/CollectFeedback`),
`Spawn.JoinLiftStuds` and `Server.MaxPlayers` (read by the bootstrap).

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the full list. The load-bearing
ones:

- `ReplicatedStorage.Config.World.Bases` — **required**. The config above.
- `ReplicatedStorage.Types.BaseType` / `ReplicatedStorage.Types.SlotType` —
  **required**. The id formats and the state enums.
- `ReplicatedStorage.Utility.StandResolver` — **required**. Every name
  lookup and every stand ordering lives here.
- `ReplicatedStorage.Utility.StandLayout` — **required** by
  `DynamicSlotService`. Pure geometry.
- `ReplicatedStorage.Utility.Debug` — **required**. The only logging path.
- `ReplicatedStorage.Utility.Validation` — required by `BaseService`, but
  see *Known Limitations*: most of its guards do not actually fire.
- `ReplicatedStorage.Utility.BigNumber` — required by `StandDisplayService`
  for the upgrade cost.
- `ReplicatedStorage.Utility.EggWalkAnimator` — required by
  `StandPresentation`.
- `ReplicatedStorage.Config.World.Movement` — required by
  `StandPresentation` (the `StandIdle` tick rate and epsilons). Lives in the
  **SharedUtilities** system, not in this one.
- `ReplicatedStorage.Config.Creatures.Progression` — required by
  `StandDisplayService` (max level). Lives in the **Animals** system.
- `ReplicatedStorage.Config.Economy.Rebirth` — required by
  `DynamicSlotService` (`InitialStands`, `StandsFor`). Lives in the
  **Rebirth** system.

**Not in this library, required at runtime** (the library is a *reference
implementation*, not a self-contained package):

| Module | Why | Optional? |
|---|---|---|
| `ServerScriptService.Base.SlotService` | The persisted-slot authority. `DynamicSlotService` calls into it. | Required for slot persistence. |
| `ServerScriptService.IncomeService` | Cash-pool settlement, called by `DynamicSlotService`. | Required. |
| `ServerScriptService.Animal.CarryPrompts` | Carry-prompt cleanup, called by `BaseService` and `DynamicSlotService`. | Required if you have carrying. |
| `ServerScriptService.Rebirth.RebirthService` | The stand-unlock resolver. | Required. |
| `ServerScriptService.Base.NotificationService` | Toasts on lock. `BaseLockService` requires it at load. | Required — the require is top-level. |
| `ServerScriptService.Tutorial.TutorialSignals` | Tutorial progression on lock. | Required — the require is top-level. |
| `ServerScriptService.FunnelService` | Analytics on lock. | Required — the require is top-level. |
| `ServerScriptService.UpgradeService` | The upgrade prices `StandDisplayService` paints. | Required for correct labels. |

---

## Initialization Order

The exact order the source game's bootstrap uses:

```text
1.  ReplicatedStorage.Utility.Remotes available (other systems need it)
2.  PlayerService.Init()
3.  SlotService.Init()
4.  BaseService.Init()
5.  BaseService.SetPlayerService(PlayerService)
6.  BaseService.SetSlotService(SlotService)
7.  BaseService.SetEggService(EggService)
8.  BaseService.SetAnimalService(AnimalService)
9.  StandPresentation.Init()
10. StandDisplayService.Init()
11. StandDisplayService.SetAnimalService(AnimalService)
12. StandDisplayService.SetUpgradeService(UpgradeService)
13. StandDisplayService.SetSellService(SellService)      -- compat no-op
14. StandDisplayService.SetEggService(EggService)        -- compat no-op
15. StandDisplayService.SetPlayerService(PlayerService)  -- compat no-op
16. SlotMenuService.SetStandDisplayService(StandDisplayService)
17. BaseLockService = require(...)
18. BaseService.SetBaseLockService(BaseLockService)
19. IncomeService.Init() + its Set*Service calls
20. SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
21. SlotService.SetStandDisplayCallback(StandDisplayService.RefreshSlot)
22. BaseService.RegisterBases(Workspace)      -- AFTER the bases exist
23. BaseLockService.Init()                     -- AFTER RegisterBases
24. DynamicSlotService = require(...)
25. DynamicSlotService.SetUnlockResolver(fn)   -- RebirthService.ResolveRebirthForStands
```

Per-player, on join:

```text
1.  PlayerService.LoadPlayerData(player)
2.  BaseService.AssignBaseForPlayer(userId)
3.  PlayerService.AssignBase(userId, baseId)
4.  BaseService.PointPlayerToBaseSpawn(player, base)
       on failure: BaseService.ReleasePlayerBase
                   PlayerService.CleanupPlayer
                   player:Kick(reason)
5.  BaseLockService.RefreshCharacter(player)
6.  BaseService.RestorePlayerBase(userId, profileData)
7.  IncomeService.ApplyOfflineEarnings
```

On leave: `BaseService.CleanupPlayer(userId)`.

**`RegisterBases` must run after the map is in the Workspace**, and
`BaseLockService.Init()` must run after `RegisterBases` — it registers each
base's lock record and creates the collision groups.

---

## Data

### Base record

| Field | Type | Notes |
|---|---|---|
| `id` | string | `Base_<n>`, `n` in 1..99. |
| `index` | number | The 1-based base number. |
| `state` | string | `'Available'` / `'Reserved'` / `'Occupied'` (`BaseType.State`). A base is **`Reserved`** after assignment; it only becomes `Occupied` when a slot is actually filled. |
| `ownerUserId` | number? | `nil` when free. |
| `session` | number | The fencing counter. Bumped on every assignment and release. `0` = never assigned. |
| `dynamicSlots` | boolean | `true` when the base builds runtime `Slot<k>` clones from `StandPos` markers. |
| `standPosCount` | number | How many `StandPos` markers the base has. |
| `spawnCFrame` | CFrame | The `Spawn` part's CFrame. |
| `spawnLocation` | SpawnLocation? | The authored or auto-created `SpawnLocation`. |
| `collector` | BasePart | The cash trigger. Never `nil` — a missing one is fatal. |
| `collectorFacing` | CFrame | The yaw-only facing toward the collector. |
| `folder` | Instance | The `Base_<n>` folder in the Workspace. |
| `slots` | `{ [number] = slotRecord }` | The **unified** pool — eggs and animals both live here. Keyed by the numeric index. |
| `arenaSlots` | `{ any }` | The **arena** track, as an **array**. Separate from `slots`. |
| `_mutex` | boolean | In-flight guard. `true` while a base is being assigned or released. |
| `_occupiedCount` | number | Occupied normal slots. Arena slots never count. |

### Slot record

| Field | Type | Notes |
|---|---|---|
| `id` | string | `p7:<userId>:slot:<index>`. Re-stamped on assignment. |
| `ownerUserId` | number | `0` while unassigned, the owner's id once assigned. |
| `baseId` | string | The owning base. |
| `kind` | string | `SlotType.Kind.Slot` (`'slot'`). |
| `index` | number | 1..99 for the main pool, 1000..1099 for the arena. |
| `state` | string | `'Empty'` / `'Reserved'` / `'Occupied'` (`SlotType.State`). |
| `occupantId` | string? | The animal or egg id. |
| `occupantKind` | string? | `'egg'` / `'animal'` (`SlotType.OccupantKind`). |
| `part` | Instance? | The displayable root part. |
| `cashCollector` | Instance? | The cash trigger part. |
| `stand` | Instance? | The runtime `Slot<k>` / `ArenaStand<k>` stand. |
| `standIndex` | number | The authored `<k>`. For arena records, `index` is the namespaced runtime index and `standIndex` is the authored one. |
| `arenaIndex` | number? | **Arena records only.** The authored arena `<k>`. |
| `arena` | boolean? | **Arena records only.** Always `true`. |
| `_mutex` | boolean | In-flight guard. |
| `offset` | Vector3 | The layout offset. On the dynamic path this is **documentation only** — the real placement comes from `Config.Layout`. |

### Profile fields

This system **reads and writes** one profile field: `BaseId` (a string,
`Base_<n>`), written via `PlayerService.AssignBase` and read back in
`RestorePlayerBase`. The slot records themselves live in the **Egg** and
**Animal** systems' profile lists (`LuckyBlocks[].SlotId`,
`Brainrots[].SlotId`) — this system only re-homes the `SlotId` values.

### Persistence

**None of its own.** The base registry and the runtime stands are rebuilt
from scratch on every server start; only the *assignments* survive, in the
profile.

---

## Known Limitations

- **`Validation.PositiveInteger` and `Validation.ShortString` return
  booleans, and `BaseService` discards them.** `BaseService.lua:1080` calls
  `Validation.PositiveInteger(userId)` as a bare statement, so the check
  never throws. The same pattern appears at several other call sites. The
  *only* validation in `BaseService` that actually throws is
  `Validation.t.instanceOf('Workspace')(workspace)` (`BaseService.lua:356`).
  Do not assume the other guards are protecting you.
- **`BaseLockService` requires three modules that are not in this library**,
  at the top level: `Base/NotificationService`, `Tutorial/TutorialSignals`
  and `FunnelService`. The module will not even load without them, even
  though they are only used for a toast, a tutorial signal and an analytics
  event.
- **A second press on the lock button does nothing at all** — no toast, no
  timer change — because `Bases.Lock.RefreshOnPress` is `false` and
  `HandleButtonTouched` only notifies when `Lock` returns `true`.
- **Purchased-unlock grants are only cleared in `HandleBaseReleased`.** They
  survive a timer expiry and a manual `Unlock`, so a base that a player paid
  to open can stay "purchased open" for a player who is no longer there.
- **The three laser-timing config values are dead.** `LaserExtendSeconds`,
  `LaserRetractSeconds` and `LaserStaggerSeconds` are read by nothing:
  `LaserAnimation` applies the final pose **instantly** (no
  `TweenService`, no stagger, no waits). `LaserAnimation._cancelTween`
  (line 106) is a retained no-op seam.
- **`BaseService`'s header comment says "the 6-base registry"** and
  `BaseLockService`'s says `BaseLock_1..6` / `BaseOwner_1..6` / "all ≤6
  timers", but `Bases.Count` is `8`. `BaseLockService.Init` calls
  `_ensureGroups(math.max(count, 6))` (line 777), so eight groups are
  actually registered. The comments are stale, the behaviour is not.
- **`StandPresentation` is EGG-ONLY.** `StandPresentation._isEggKind`
  (line 85) returns `true` for `nil` (a legacy, unknown kind) and `true`
  only for `SlotType.OccupantKind.Egg`. An animal model bound to it is
  silently ignored.
- **`StandDisplayService` hardcodes the strings** `'MAX'`, `'Unavailable'`
  and `'%d >> %d'`, and formats the cost as `'$' .. BigNumber.Format(cost)`.
  There is no localisation hook.
- **`StandDisplayService` only manages the `UpgradeButton`.** Cloned
  `SellButton` instances are destroyed and authored ones are hidden
  (lines 469–479) — the sell UI belongs to `SlotMenuService`.
- **The arena track has its own slot index namespace** (`1000 + k`) and its
  own record table (`base.arenaSlots`). Arena occupancy does **not** move
  `base._occupiedCount`, and arena records are not returned by
  `GetFreeSlot` / `FindSlotByOccupant`.
- **`BaseService._findSlotById` is exported** despite the underscore
  prefix. It is a raw table lookup with no session or ownership check.
- **The whole slot API in `BaseService` is a deprecated shim.**
  `GetFreeSlot`, `ReserveSlot`, `OccupySlot`, `ReleaseSlot`,
  `FindSlotByOccupant`, `DemoteSlotToReserved`,
  `GetNearestValidSlotForPlayer` and `ReleaseReservedSlotForUser` all log
  a deprecation line and forward to `SlotService`. With no SlotService
  injected they all return `nil` / `false`. Call `SlotService` directly.
- **A base is `Reserved`, not `Occupied`, after assignment.** The
  `Occupied` state is only reached when a slot is actually filled
  (SlotService's occupancy callback, `BaseService.lua:311`). Arena slots
  are explicitly excluded (lines 301–303) and never move
  `_occupiedCount`.
- **`PointPlayerToBaseSpawn` does not teleport.** It only sets
  `player.RespawnLocation`. There is no `PivotTo` and no
  `LoadCharacter` — the player arrives via Roblox's own spawn flow.
- **`StandDisplayService.Init()` is empty** (line 297). The service paints
  on demand; nothing is painted at boot.
- **The dynamic stand count is not capped by the marker count** when the
  unlock resolver is wired — only by `Bases.Slots.Count`. The markers
  anchor the ground plane; the ring is generated from `Config.Layout`.
- **The `Tests/BaseLockTimer.spec.lua` spec is stale.** It asserts
  `LockDurationSeconds == 30` (line 99) while the shipped config says
  `60`. `Tests/Bases.spec.lua:68` correctly asserts `60`. The BaseLockTimer
  spec will fail as shipped.

---

## Testing

`Tests/BaseLifecycle.spec.lua`, `Tests/BaseLockTimer.spec.lua`,
`Tests/BaseService.spec.lua`, `Tests/BaseServiceCollectorFacing.spec.lua`,
`Tests/Bases.spec.lua`, `Tests/DynamicSlots.spec.lua`,
`Tests/LaserAnimation.spec.lua`.

They **require Roblox Studio** (TestEZ); there is no headless Luau runner.
They also require systems that are **not** in this library — the shared
`Tests/_Helpers.lua` requires `SSS.Base.SlotService`, `SSS.EggService`,
`SSS.AnimalService`, `SSS.IncomeService`, `SSS.SellService`,
`SSS.UpgradeService` and `SSS.ModifierService` — so the specs only run in
the full source game, not against this library alone.

---

## Adapting to a New Game

1. **Copy the tree to the documented Roblox paths.** `Source/` mirrors the
   original paths exactly; see the *Files* table above.
2. **Copy `ReplicatedStorage/Config/World/Bases.lua`** and tune it, or use
   the annotated [`Config.lua`](Config.lua) as a drop-in (it lacks the four
   `Validate*` functions — copy them back if your project runs
   `ConfigValidator`).
3. **Author the map.** The hierarchy the server expects is in
   [`Setup.md`](Setup.md) → *Studio assets*. The non-negotiable parts are
   the `Collector` (a `BasePart`, and it must not share its XZ position with
   the `Spawn`) and the `StandPos<k>` / `ArenaStandPos<k>` markers.
4. **Change the id prefix.** `SlotType.BuildId` formats ids as
   `p7:<userId>:slot:<index>`; `p7` is Brainrot Arena's project prefix.
   Change it in `Shared/Types/SlotType.lua` and keep it consistent with the
   `p7_` DataStore prefix in the profile system.
5. **Change `BaseType.BuildId`** if you do not want `Base_<n>`.
6. **Decide what to do with the three out-of-library top-level requires**
   in `BaseLockService` (`NotificationService`, `TutorialSignals`,
   `FunnelService`). Either stub them, or guard the requires with
   `pcall` and the features become optional.
7. **Keep the session-fencing discipline.** Every async callback
   (`task.spawn`, `task.defer`, `Promise` chains, `Debris` waits) must call
   `BaseService.IsCurrentSession(baseId, session)` before it mutates
   anything. This is the single most important invariant in the system.
8. **Wire the bootstrap** in the order above. In particular,
   `RegisterBases` → `BaseLockService.Init` → `SetUnlockResolver`.
9. **Port the tests** and fix the stale `BaseLockTimer` assertion
   (30 → 60) before you trust it.

---

## See Also

- [`MEMORY.md`](MEMORY.md) — the engineering notes for a future agent.
- [`API.md`](API.md) — every public function, with signatures and failure modes.
- [`Dependencies.md`](Dependencies.md) — exact module paths, assets, init order.
- [`Setup.md`](Setup.md) — step-by-step installation into a new Rojo project.
- [`Config.lua`](Config.lua) — the consolidated tunables.
