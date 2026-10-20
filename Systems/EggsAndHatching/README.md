# EggsAndHatching

The egg lifecycle end to end: spawning eggs in the world centre,
letting them wander, selling them to players, flying them home,
placing them on a stand, and cracking them open into an animal.

**Portability:** Grade A core (the state machine, the flight/roll
controllers, the hover/placement math, the spawn cap and expiry
lifecycle) + Grade B (the egg catalog, prices, hatch-roll weight
matrix, and the animal rarity ladder are Brainrot Arena content).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

`EggService` is a **thin facade** over thirteen sub-modules. It owns no
logic of its own beyond orchestration and error-string mapping.

The egg lifecycle has **five states** (`EggType.State`):

```text
Available  ->  Traveling  ->  Placed  ->  Opening  ->  Consumed
```

| State | Meaning |
|---|---|
| `Available` | Sitting in the world centre, wanders, has a buy prompt, has a lifetime deadline. |
| `Traveling` | Bought by a player, flying from the centre to the buyer's base. Can be **contested** by another player. |
| `Placed` | Seated on a stand in a base. Has a hatch ("Open") prompt. |
| `Opening` | Being carried, or mid-hatch. The egg is locked. |
| `Consumed` | Hatched. The record is dropped. |

The sub-modules and what each owns:

| Module | Owns |
|---|---|
| `Egg.SpawnService` | The **single authoritative spawn entry point**. The egg registry, the cap, the expiry sweep, persistence restore. |
| `Egg.AmbientService` | The centre wandering loop — one Heartbeat for all eggs, spatial-hash separation, shared walk animator. |
| `Egg.FlightController` | The purchased-egg flight from centre to base, along a pathfinding polyline. |
| `Egg.RollController` | The 3D roulette animation on hatch, and the final reveal. |
| `Egg.GuaranteeService` | The "a Legendary appears every N seconds" timers. |
| `Egg.RareEggNotifier` | The server-wide toast when a high-rarity egg spawns. |
| `Egg.HoverMath` | All the height math — hover, floor, seated, settle. |
| `Egg.ModelBuilder` | Clones the rarity template (or builds a procedural fallback cube). |
| `Egg.Placement` | Where on the centre floor a new egg appears. |
| `Egg.Catalog` | Validation of spawn definitions and spawn origins. |
| `Egg.Constants` | The re-exported tuning surface. |
| `Egg.EggOverhead` | The name/price/trait/mutation billboard above an egg. |
| `Egg.EggSpawned` | A one-shot server-side event fired once per new egg. |

### The three design rules worth knowing up front

1. **The egg flies to the base's Collector, not to a slot.** The landing
   slot is resolved **on arrival** by `CollectorArrival.OnArrival`. The
   flight controller knows nothing about slots.
2. **The centre cap counts the `Normal` pool only.** An `Extra`-pool egg
   (from a guarantee, or an admin spawn) bypasses the cap. A normal
   centre that is already at 10 can therefore hold 11.
3. **A traveling egg can be contested.** Another player can buy an egg
   that is already in flight to someone else's base. The previous
   owner's record is removed and their slot released — **their money is
   not refunded.** That is deliberate: the debit is sunk.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `EggService.Init()` | Server | Initialises `SpawnService`, `ServerLuckService` and `RareEggNotifier`, and wires the three prompt callbacks (Buy / Hatch / Egg Grab). |
| `EggService.Start()` | Server | Background thread that tops the centre up toward `CenterSpawn.MaxCenter` on the `CenterSpawn.Interval` cadence. |
| `EggService.Stop()` | Server | Stops the top-up thread. |
| `EggService.RegisterCenter(workspace)` | Server | Idempotent. Creates `Workspace.EggArea` + `Floor` + `ActiveEggs`, and starts the ambient wander loop. |
| `EggService.ListCenterEggs(): { any }` | Server | The `Available` eggs in the centre. |
| `EggService.GetEgg(uniqueId): any?` | Server | The egg record, or `nil`. |
| `EggService.Purchase(player, uniqueId): any` | Server | `{ success, error?, egg? }`. The whole buy flow. |
| `EggService.HatchEgg(player, uniqueId): any` | Server | `{ success, animalId?, rarity? }`. The whole hatch flow. |
| `EggService.GrabEgg(player, uniqueId): any` | Server | Picks the egg up. |
| `EggService.PlaceEgg(player, uniqueId, destSlotId): any` | Server | Puts the egg on a stand. |
| `EggService.RecoverCarriedEgg(player, reason?): any` | Server | Re-seats a carried egg after a failure. |
| `EggService.RefundHatch(theEgg): any` | Server | Reverts an `Opening` egg to `Placed`. |
| `EggService.SpawnFromPersistence(userId, record, slot): any` | Server | Restores an egg on rejoin. |
| `EggService.DropEggRuntime(uniqueId): boolean` | Server | Removes a runtime egg without touching the profile. |
| `EggService.ForceReleaseBase(baseId)` | Server | Tears down in-flight eggs for a base and refunds them. |
| `EggService.CleanupPlayer(userId)` | Server | On leave: rolls back stealing, releases the base, sweeps the player's placed eggs. |
| `EggService.IsCarrying(playerOrUserId): boolean` | Server | Thin wrapper over `CarryRegistry`. |
| `EggService.SetPlayerService / SetBaseService / SetAnimalService / SetSlotService / SetEconomyService(svc)` | Server | Late-bound dependency injection. |
| `Egg.SpawnService.Request(req): any` | Server | The single spawn entry point. `{ success, egg?, error? }`. |
| `Egg.SpawnService.RegisterCenter(workspace)` | Server | Idempotent folder creation. |
| `Egg.SpawnService.ListAvailable(): { any }` | Server | Rows of `{ UniqueId, Rarity, Price }`. |
| `Egg.SpawnService.CountNormalAvailable(): number` | Server | The centre-cap count (excludes the `Extra` pool). |
| `Egg.SpawnService.ExpireEgg(egg): boolean` | Server | Drops one past-deadline `Available` egg. |
| `Egg.SpawnService.SweepExpired(nowOverride?): number` | Server | Drops every past-deadline `Available` egg; returns the count. |
| `Egg.SpawnService.StartExpirySweep() / StopExpirySweep()` | Server | The one shared sweep loop. |
| `Egg.FlightController.Start(egg, destination, onArrive?): FlightController` | Server | Launches the flight. **Throws (level 2)** on a missing model, unparented model, missing `PrimaryPart`, or missing destination. |
| `Egg.FlightController.Stop(controller)` | Server | Aborts the flight. |
| `Egg.FlightController.IsRunning(controller): boolean` | Server | |
| `Egg.FlightController.SanitizePath(points, a, b): { Vector3 }` | Server | Pure path sanitiser. |
| `Egg.RollController.Start(egg, primaryCFrame, slotCFrame, rolledRarity, winnerDefId, options?): RollController` | Server | Starts the roulette. **Asserts** all five required arguments. |
| `Egg.RollController.RevealFinalAnimal(controller, animal): boolean` | Server | The canonical final-reveal event. Idempotent. |
| `Egg.RollController.Stop(controller)` / `.IsRunning(controller)` | Server | |
| `Egg.RollController.PickOrder(winnerDefId, rng?): { defIds, finalIndex }` | Server | Pure. The decoy sequence. |
| `Egg.RollController.ComputeGroundCFrame(slotCFrame, egg, facingPos?): CFrame` | Server | Pure. Where the winner lands. |
| `Egg.AmbientService.Start(_workspace?): boolean` | Server | Connects the one central Heartbeat. |
| `Egg.AmbientService.Stop()` | Server | |
| `Egg.AmbientService.RegisterModel(model): boolean` | Server | Adds an egg to the wander loop. |
| `Egg.AmbientService.UnregisterModel(model)` | Server | Removes it and restores `CanTouch`/`CanQuery`. |
| `Egg.HoverMath.HoverY / FloorY / SlotFloorY / HoverCFrameOnSlot / GroundedCFrameOnSlot / Settle / BlockHeight / GroundOffset` | Server | All the height math. See [API.md](API.md). |
| `Egg.GuaranteeService.PickDue(nowOverride?): string?` | Server | The rarity whose guarantee is due, or `nil`. |
| `Egg.GuaranteeService.NoteSpawned(rarity)` | Server | Resets that rarity's clock. |
| `Egg.GuaranteeService.GetState(nowOverride?): { any }` | Server | One row per guarantee. |
| `Egg.RareEggNotifier.ShouldNotify(rarity): boolean` | Server | `true` for Legendary, Mythic, Divine and Secret only. |
| `Egg.RareEggNotifier.Start()` | Server | Idempotent. Subscribes to `EggSpawned`. |
| `Egg.EggSpawned.Connect(fn)` / `.Fire(info)` | Server | The spawn event. Payload `{ uniqueId, rarity, origin }`. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/EggService.lua` | `ServerScriptService.EggService` | The facade. |
| `Source/ServerScriptService/Egg/SpawnService.lua` | `ServerScriptService.Egg.SpawnService` | The spawn registry, the cap, the expiry sweep, persistence restore. |
| `Source/ServerScriptService/Egg/AmbientService.lua` | `ServerScriptService.Egg.AmbientService` | The centre wander loop. |
| `Source/ServerScriptService/Egg/FlightController.lua` | `ServerScriptService.Egg.FlightController` | The purchased-egg flight. |
| `Source/ServerScriptService/Egg/RollController.lua` | `ServerScriptService.Egg.RollController` | The 3D hatch roulette. |
| `Source/ServerScriptService/Egg/GuaranteeService.lua` | `ServerScriptService.Egg.GuaranteeService` | The rarity guarantee timers. |
| `Source/ServerScriptService/Egg/RareEggNotifier.lua` | `ServerScriptService.Egg.RareEggNotifier` | The high-rarity toast. |
| `Source/ServerScriptService/Egg/HoverMath.lua` | `ServerScriptService.Egg.HoverMath` | The height math. |
| `Source/ServerScriptService/Egg/ModelBuilder.lua` | `ServerScriptService.Egg.ModelBuilder` | Template cloning + procedural fallback. |
| `Source/ServerScriptService/Egg/Placement.lua` | `ServerScriptService.Egg.Placement` | Centre-floor placement. |
| `Source/ServerScriptService/Egg/Catalog.lua` | `ServerScriptService.Egg.Catalog` | Definition / origin validation. |
| `Source/ServerScriptService/Egg/Constants.lua` | `ServerScriptService.Egg.Constants` | The re-exported tuning surface. |
| `Source/ServerScriptService/Egg/EggOverhead.lua` | `ServerScriptService.Egg.EggOverhead` | The egg billboard. |
| `Source/ServerScriptService/Egg/EggSpawned.lua` | `ServerScriptService.Egg.EggSpawned` | The spawn event. |
| `Source/ReplicatedStorage/Config/Creatures/Eggs.lua` | `ReplicatedStorage.Config.Creatures.Eggs` | The egg config. **Lives in this system** but requires `Config.Creatures.Rarity`, which lives in the **MutationsAndTraits** system. |

---

## Configuration

This system owns a large config module. See **[Config.lua](Config.lua)** for
the consolidated, fully-commented tunables.

The headline numbers:

| Value | Default | Meaning |
|---|---|---|
| `HoverClearance` | `3` | Studs between the egg's bottom face and the surface it hovers over. |
| `EggSize` | `Vector3.new(4,4,4)` | The procedural fallback egg's size. |
| `EggAnimationsEnabled` | `false` | Master switch for the egg walk animation. |
| `Price` | Common 100 / Uncommon 500 / Rare 1000 / Epic 5000 / Mythic 25500 / Legendary 50000 / Divine 100000 / Secret 50000 | The buy price per rarity. |
| `CenterSpawn.CenterMax` | `10` | The normal centre cap. |
| `CenterSpawn.Interval` | `30` | Seconds between top-up attempts. |
| `CenterSpawn.Radius` | `20` | The centre spawn ring radius. |
| `CenterSpawn.MinSpawnSpacing` | `7` | Minimum spacing between two centre eggs. |
| `CenterSpawn.TravelDuration` | `7` | **Legacy, unused** by the flight path (which is speed-derived). |
| `HatchRollWeights` | An 8x8 matrix | Which animal rarity a given egg rarity hatches into. The **diagonal is always non-zero** — every egg has a chance of the same-tier animal. |
| `RollTotalDurationSeconds` | `5.0` | The roulette's total runtime. |
| `RollWinnerDwellSeconds` | `1.0` | How long the winner holds. |
| `RollPreviewCount` | `20` | How many entries pass through the roulette. |
| `RollFirstDecoyIntervalSeconds` | `0.025` | The first decoy's delay; the rest follow an arithmetic progression that sums exactly to `total - dwell`. |
| `RollEntryScale` / `RollExitScale` | `0.1` / `0.1` | Entry/exit scale of a rolling entry. |
| `EggLifetimeSeconds` | Common 300 → Secret 1200 | How long an `Available` egg lives. |
| `ExpirySweepSeconds` | `5` | The sweep cadence. |
| `PurchasedTravelSpeed` | `5` | Studs/second. The flight duration is distance-derived and clamped. |
| `PurchasedTravelMinDuration` / `MaxDuration` | `3` / `15` | The duration clamp. |
| `Guarantees` | Legendary every 600s, Mythic every 1200s | The forced-spawn timers. |
| `Ambient` | ~45 values | The wander tuning (speeds, idle times, separation, blend rates, pose amplitudes). |

---

## Dependencies

See **[Dependencies.md](Dependencies.md)** for the exact require paths,
the remotes, and the profile fields.

The load-bearing ones:

- `ReplicatedStorage.Config.Creatures.Eggs` — the egg config.
- `ReplicatedStorage.Config.Creatures.Rarity` — **from the
  MutationsAndTraits system.** The rarity table.
- `ReplicatedStorage.Config.Creatures.Animals` — **from the Animals
  system.** The animal catalog, used for the hatch roll.
- `ReplicatedStorage.Utility.FloorGeometry` — all floor math.
- `ReplicatedStorage.Utility.EggWalkAnimator` — the shared walk cycle.
- `ReplicatedStorage.Utility.StandResolver` — the slot facing.
- `ReplicatedStorage.Utility.WeightedDraw` — the weighted rarity pick.
- `ReplicatedStorage.Utility.BigNumber` — exact price math.
- `ServerScriptService.Animal.CarryPrompts` / `Animal.CarryController` —
  **from the Animals system.** The prompt installer and the carry rig.
- `ServerScriptService.EconomyService` — the debit and the refund.
- `ServerScriptService.TraitService` — **from the MutationsAndTraits
  system.** The hatch inheritance.

**Remotes:** `EggArrived`, `EggCarried`, `EggPlaced` (all S->C).

**Profile fields read/written:** the egg record's `Id`, `Rarity`,
`Mutations`, `Trait`, `SlotId`/`slotId`, and `Price`.

---

## Initialization Order

```text
1. ReplicatedStorage.Utility.*              -- BigNumber, Debug, FloorGeometry,
                                               EggWalkAnimator, StandResolver,
                                               WeightedDraw, Remotes, Validation
2. ReplicatedStorage.Types.*                -- RarityType, SlotType, EggType,
                                               TransactionReason
3. ReplicatedStorage.Config.Creatures.Rarity      (MutationsAndTraits)
4. ReplicatedStorage.Config.Creatures.Animals     (Animals)
5. ReplicatedStorage.Config.Creatures.Eggs        (this system)
6. ServerScriptService.Egg.*                -- the sub-modules
7. ServerScriptService.EggService
```

Then, in your bootstrap:

```lua
local EggService = require(ServerScriptService.EggService)

EggService.SetPlayerService(PlayerService)
EggService.SetBaseService(BaseService)
EggService.SetAnimalService(AnimalService)
EggService.SetSlotService(SlotService)
EggService.SetEconomyService(EconomyService)

EggService.Init()
EggService.RegisterCenter(workspace)
EggService.Start()
```

**`Init()` before `RegisterCenter()`, and `RegisterCenter()` before
`Start()`.** The top-up thread will spawn eggs, and a spawn needs a
registered centre to know where the floor is.

`EggService.Init()` internally calls `SpawnService.Init()`,
`ServerLuckService.Init()` and `RareEggNotifier.Start()`, and wires the
three prompt callbacks:

- **Buy** → `EggService.Purchase`
- **Hatch** → `SlotActionHandler.Handle(player, { Action = 'Hatch', SlotId = egg.slotId, OccupantId = uniqueId })`
- **Egg Grab** → `SlotActionHandler.Handle(player, { Action = 'Pickup', ... })`

**The `Set*Service` injection must happen before `Init()`** for the
prompt callbacks to reach a wired service.

---

## Data

### The egg record

Created by `SpawnService._spawnCenter`:

| Field | Type | Meaning |
|---|---|---|
| `uniqueId` | `string` | `EG_` + a 10-char base-62 token. |
| `rarity` | `string` | One of the eight rarity ids. |
| `price` | `number` | Resolved from `EggConfig.Price[rarity]`. |
| `state` | `string` | One of the five `EggType.State` values. |
| `ownerUserId` | `number?` | `nil` until bought. |
| `slotId` | `string?` | The stand it is seated on, once placed. |
| `Mutations` | `{ string }` | The mutation ids it carries. |
| `Trait` | `string?` | A forced trait, if the egg was preassigned one. |
| `pool` | `'Normal' \| 'Extra'` | `Extra` bypasses the centre cap. |
| `model` | `Model?` | The world model. |
| `centerCFrame` | `CFrame` | Its last known world transform. |
| `_mutex` | `boolean` | Guards expiry and purchase against each other. |
| `spawnedAt` | `number` | `os.clock()` at spawn. |
| `_expireAt` | `number` | `spawnedAt + LifetimeFor(rarity)`. |
| `controller` | `any?` | The active flight / roll controller. |
| `controllerType` | `string?` | One of `Egg.Constants.ControllerType`. |
| `_aborted` | `boolean` | Set when the egg is torn down mid-flight. |
| `_localFloor` | `number` | The floor height the egg is relative to. |
| `_flightGen` | `number` | Bumped per launch; a stale controller cannot claim the egg. |
| `_refs` | `{ playerService, baseService, animalService, slotService }` | The injected dependencies, captured at spawn. |

### The profile record

Persisted per egg, in the player's egg list. The persisted row uses the
`Id` / `Rarity` / `Mutations` / `Trait` / `slotId` spelling. The
`PersistenceAudit` (PlayerData system) owns cleaning it.

### The guarantee clock

`GuaranteeService` keeps its state **in memory only** — `os.clock()`
based, server-session scoped, **no DataStore**. A server restart resets
every guarantee timer to full.

---

## Known Limitations

- **`EggService` is a very wide hub.** It `require`s 30+ modules across
  a dozen other systems. Copying it means copying a large slice of the
  game. The sub-modules under `Egg/` are individually portable; the
  facade is not.

- **`EggService` requires `EconomyService` directly** (not through
  injection), so the dependency graph is not fully acyclic. The
  `SetEconomyService` injection exists as well, and the *purchase* path
  uses the injected reference; the `ForceReleaseBase` refund path uses
  the direct `require`. A cycle is possible if `EconomyService` ever
  requires `EggService` back.

- **The centre `Floor` is created at runtime with the wrong
  orientation.** `SpawnService.RegisterCenter` creates a
  `40 x 1 x 40` Part, but the production map's floor is a 90°-rotated
  Cylinder, so `Size.Y / 2` is **not** the world half-height. The code
  gets this right by using `FloorGeometry.GetWorldTopY(floor)` rather
  than `Size.Y / 2` — reading it the naive way parks spawns about 80
  studs in the air.

- **`CenterSpawn.TravelDuration` (`7`) is dead.** The flight path is
  speed-derived (`distance / PurchasedTravelSpeed`, clamped to
  `PurchasedTravelMinDuration`..`PurchasedTravelMaxDuration`). The
  constant is kept for back-compat and is misleading.

- **The flight path is computed once, at launch.** The polyline is
  sanitised and never recomputed mid-flight, so an egg will not
  re-route around an obstacle that appears during the flight. It will
  steer straight through it.

- **The flight controller only knows the Collector.** The landing slot
  is resolved **on arrival** by `CollectorArrival.OnArrival`. If that
  module is missing, the egg arrives and nothing is seated.

- **A contested flight does not refund the previous buyer.** The debit
  is sunk. This is by design but it is surprising.

- **`EggService.Start()` can exceed the cap.** It tops up toward
  `CenterSpawn.MaxCenter` for the `Normal` pool, but a
  `GuaranteeService.PickDue()` spawn uses `pool = 'Extra'`, which
  bypasses the cap. A centre at 10 normal eggs can hold 11.

- **`AmbientService` degrades permanently if the centre is not
  registered when it starts.** `Start()` connects the Heartbeat, but
  the area resolves lazily inside `_update`, so a late-replicating
  `EggArea` self-heals. `RegisterModel`, however, returns `false` if the
  area is unavailable at that moment, and the caller (`_spawnCenter`)
  does not retry.

- **`AmbientService.RegisterModel` sets `CanCollide`/`CanTouch`/
  `CanQuery` to `false` on every BasePart.** `UnregisterModel`
  restores `CanTouch` and `CanQuery` to `true` but **not**
  `CanCollide`. A purchased egg therefore keeps `CanCollide = false`.

- **The guarantee clocks are not persisted.** A server restart (or a
  player rejoining) resets them.

- **`EggService` has no sell path.** `SellService.SellEgg` and
  `GetEggSellValue` are `nil` — eggs cannot be sold in this phase.

- **`RollController` requires two `ServerStorage` assets**
  (`Assets.Sfx.Pop` and `Assets.Sfx.Reward`). If they are missing, the
  roll degrades to a **mute roll** with one loud warning per session.

- **The roll audio is prepared in the hatching player's `PlayerGui`**
  (4-deep `Pop` pool on an invisible `RollAudioAnchor`), deliberately
  so nearby players do not hear another player's ticks.

- **The reveal VFX sounds are never played.** They would be audible
  server-wide; the `Sound` instances are created and then destroyed.

- **No `TweenService` anywhere.** The whole system moves things with
  `RunService.Heartbeat` + `model:PivotTo()` / `model:ScaleTo()`. Eggs
  and animals are `Anchored = true` at all times. This is a codebase
  convention, not an oversight.

- **`RollController._applyScale` clamps to `0.001`.** Roblox's
  `Model:ScaleTo` rejects a scale `<= 0`, so the clamp is a
  hard requirement, and the scale is quantised with
  `SCALE_EPSILON = 0.004` per controller+model to stop float drift.

---

## Testing

Fourteen spec files in `Tests/`:

| Spec | Covers |
|---|---|
| `EggService.spec.lua` | The centre folder structure, `GetEgg`, `Purchase` error paths, the hatch-roll diagonal invariant, and the **"every egg recovers 70-85% on immediate hatch-and-sell"** no-money-printer balance simulation, plus `WeightedDraw` determinism. |
| `EggSpawnService.spec.lua` | `Catalog.ValidateDefinition` / `ValidateOrigin`, `Placement.IsFarFromAll` / `PickXZ`, and `SpawnService.Request` (bad definition, bad origin, `Persistence` requires a target slot, `Test` origin spawns, the cap, `DropEgg`). Also covers `AdminService` rank ordering. |
| `EggLifecycle.spec.lua` | The cap target of 10 across canonical readers, positive lifetimes, `ResolvePrice` fallbacks, pool stamping (`Normal` vs `Extra`), cap semantics, expiry (reaps past-deadline `Available` eggs, leaves future ones alone, **never reaps `Traveling` or mutex-held eggs**, frees records whose model is gone), `SweepExpired`, and the ServerLuck HUD format. |
| `EggConsumeOrder.spec.lua` | `RefundHatch` reverting an `Opening` egg to `Placed`, and `ForceReleaseBase` **not** destroying `Placed` eggs (persistence is the source of truth) while destroying `Traveling` eggs and refunding the money. |
| `EggContest.spec.lua` | B contesting A's traveling egg (ownership / slot / profile transfer atomically), the owner re-buying their own traveling egg being rejected **before** the debit, and a `Placed` egg still being unavailable. |
| `EggFlightHandoff.spec.lua` | `FlightController._onComplete` placing the egg at the slot seated CFrame and installing an Open prompt (first-arrival parity with rejoin), **not** changing the state to `Placed` when `OccupySlot` fails (so `ForceReleaseBase` can clean it up), and the hatch prompt callback routing through the registered consumer. |
| `EggFlightPath.spec.lua` | `FlightController.SanitizePath` — a healthy polyline is untouched, consecutive duplicates are dropped, NaN/inf points are dropped, fewer than 2 survivors falls back to the straight line, and the result is deterministic. |
| `EggGuarantee.spec.lua` | Nothing due at boot, a rarity becoming due after its interval, **Legendary outranking Mythic when both are due**, a successful spawn resetting only its own timer, `Remaining` clamping at zero, the revision counter starting at 0 and bumping on reset, and unknown rarities being ignored without throwing. |
| `EggAmbient.spec.lua` | The ambient service exposing **no base/collector targeting surface**, the roam lifecycle surface staying intact, and `Register`/`Unregister` degrading gracefully on garbage input. |
| `EggSpawnNotify.spec.lua` | `RareEggNotifier.ShouldNotify` celebrating Legendary and above only (and rejecting garbage without throwing), the `EggSpawned` event firing once per `Fire` with the payload intact, the `RareEgg_Spawned` catalog entry existing with an `EggName` placeholder, and `RareEggNotifier.Start` being idempotent and never throwing. |
| `HoverMath.spec.lua` | `BlockHeight` (PrimaryPart size, with the `Constants.EggSize.Y` fallbacks), `HoverY`/`FloorY` being exact inverses, the bottom face clearing `HoverClearance`, `SlotFloorY` (and returning 0 with no part), `HoverCFrameOnSlot` (preserving XZ and rotation, deriving Y from the slot **top** so a thicker slot part does not sink the egg), `GroundedCFrameOnSlot` (bottom-flush, zero gap, no hardcoded shift), and `Settle` parking the model and clearing the controller. |
| `RollController.spec.lua` | `ComputeGroundCFrame` (slot rotation, **no 180° flip**, `_localFloor` Y with a `HoverMath.FloorY` fallback, slot XZ preserved), `_TestSilhouette` (blacks out parts, hides identity, keeps geometry and rig, is idempotent and safe on garbage, and **never mutates the source template**), the roll audio rig (a bounded pool + reward under the host folder inheriting `SoundIds`, round-robining `Pop`s and playing `Reward` exactly once without throwing), the rarity explosion mounting on the real animal without mutating the template, and a **missing rig degrading silently to a mute roll with no throw**. |
| `EggWalkAnimator.spec.lua` | The one-time personality roll staying in sane ranges with blend starting at 0, `Advance`/`Pose` blending 0→1 while advancing the phase, the rest pose being zeros + unit stretch, determinism, a coordinated hop (lift >= 0, alternating lean, stretch bracketing 1), `Rest` decaying the blend with a bounded idle offset, `IdlePose` being a stationary wobble, and the scale helpers being nil-model safe and epsilon-quantised. |
| `EggTimerFormat.spec.lua` | The egg timer controller formatting only the rarity word and the timer in colour, and keeping the static words uncoloured for Legendary too. |

**They require Roblox Studio.** There is no headless Luau runner in
this project. See `../../Tests/README.md`.

> **The suite has never been executed as committed.** "14 specs" means
> "14 specs exist that were written against this code", **not** "14 were
> observed passing". `../../Tests/README.md` §1 documents the three
> runner defects that block execution (the `Packages.DevPackages.TestEZ`
> require path, the non-existent `TestEZ.RunBootstrap()`, and
> `AnimalXP.spec.lua` returning a table instead of a function).
> Treat a failing spec as a **question about the code**, not
> automatically as a broken test.
>
> **Helper-path caveat:** five of the fourteen specs require the shared
> helper via `require(script.Parent._Helpers)` or
> `require(ServerScriptService.TestEZTests._Helpers)`. There is only
> **one** `_Helpers.lua`, at `ReusableSystems/Tests/_Helpers.lua` —
> there is **no** `_Helpers.lua` inside `Systems/EggsAndHatching/Tests/`.
> You must mount the shared helper where the spec's require path
> expects it, or the spec errors before it runs.

The shared helpers are in `../../Tests/_Helpers.lua`
(`Helpers.StubRemotes()`, `Helpers.FakePlayer(userId)`,
`Helpers.WireServices()`, `Helpers.EnsureCollectors()`,
`Helpers.RegisterBasesForTest(services, userId)`).

---

## Adapting to a New Game

1. **Copy the sub-modules, not just the facade.** `Egg/` is portable;
   `EggService.lua` is a hub. If you are writing your own egg game,
   take `SpawnService`, `FlightController`, `RollController`,
   `HoverMath`, `ModelBuilder`, `Placement`, `Catalog` and
   `Constants`, and write your own facade.
2. **Keep the five-state machine.** `Available -> Traveling -> Placed
   -> Opening -> Consumed` is the contract every other system reads.
   `Opening` doubles as "in flight (carried)" — `HatchEgg` rejects an
   egg that is not `Placed`.
3. **Keep the `Normal` / `Extra` pool split.** The cap counts `Normal`
   only. Guarantees and admin spawns use `Extra`.
4. **Keep the `pool`, `_mutex` and `_flightGen` fields.** The mutex
   stops the expiry sweep and a purchase racing; the generation
   counter stops a stale flight controller claiming a re-launched egg.
5. **Replace the catalog.** `EggConfig.Price`, `HatchRollWeights`,
   `EggLifetimeSeconds` and `Guarantees` are Brainrot Arena content.
   The **hatch-roll diagonal must stay non-zero** for every egg
   rarity, or some eggs can never hatch a same-tier animal.
6. **Do not move the flight to a slot.** The egg flies to the
   Collector and the slot is chosen on arrival. If you change that, you
   must also handle the contest case (a second buyer taking a
   traveling egg).
7. **Author the `ServerStorage.EggTemplates.<Rarity>` models.** Each
   needs a `Model` child with a `PrimaryPart`. `ModelBuilder` falls
   back to a procedural cube if the template is missing, so a missing
   template is a **silent** downgrade, not an error.
8. **Author `ServerStorage.Assets.Sfx.Pop` and `.Reward`**, or accept a
   mute roll.
9. **Keep the config validator culture.** `EggConfig` should expose
   `Validate(): { string }` and be checked at boot by
   `Shared/Utilities/ConfigValidator.lua`.
