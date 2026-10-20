# EggsAndHatching — MEMORY

Engineering notes for an agent working on this system. Dense, factual, no
filler. Read [README.md](README.md) for the overview and [API.md](API.md)
for signatures.

---

## Purpose in one line

Own the egg's whole life: spawn it in the world centre, let it wander,
sell it to a player, fly it home, seat it on a stand, and crack it open
into an animal.

---

## How it actually works

### The layer split

`EggService.lua` (1987 lines) is a **facade**. It owns no algorithm. It:

- maps error codes to `{ success = false, error = '...' }` results,
- sequences the sub-modules,
- owns the three prompt callbacks,
- owns the centre top-up thread.

The algorithms live in `ServerScriptService/Egg/*` (13 modules). If you
are writing a different egg game, take `Egg/*` and write your own
facade.

### The state machine

```text
Available  ->  Traveling  ->  Placed  ->  Opening  ->  Consumed
```

- **`Available`** — in the world centre. Wanders. Has a buy prompt. Has a
  deadline (`_expireAt`).
- **`Traveling`** — bought, flying to the buyer's base. **Contestable.**
- **`Placed`** — seated on a stand. Has a hatch ("Open") prompt.
- **`Opening`** — the egg is locked. Used both for "mid-hatch" and for
  "being carried" (`GrabEgg` sets it to `Opening` as its in-flight
  marker, so `HatchEgg` rejects a carried egg).
- **`Consumed`** — hatched. The record is dropped.

The state lives on `egg.state`. Every transition is checked against it.

### The spawn path

`SpawnService.Request(req)` is the **single authoritative spawn entry
point**. Nothing else creates an egg.

```lua
Request { definition = { rarity, price },
          origin = 'Automatic' | 'Admin' | 'Persistence' | 'Test',
          targetSlot?, xz?, adminUserId? }
  -> { success, egg?, error? }
```

The order of operations:

1. `Catalog.ValidateDefinition(definition)` — must be a table, must have
   a string `rarity`, must have a numeric non-negative `price`.
2. `Catalog.ValidateOrigin(origin)` — must be one of the four known
   origins.
3. If `origin == 'Persistence'` → `_spawnPersistence` (needs a
   `targetSlot`; **no cap**).
4. Otherwise → cap check, then `_spawnCenter`.

**The cap.** `CountNormalAvailable()` counts records whose
`pool ~= 'Extra'`. The cap is `Constants.EggCenterMax` (10). An `Admin`
origin **or** an explicit `pool == 'Extra'` bypasses the cap. A guarantee
spawn uses `pool = 'Extra'`, so a centre at 10 normal eggs can hold 11.

**`_spawnCenter` steps:** mint a unique id via
`OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Egg, eggs)`
→ build the model via `ModelBuilder.Build` → name it
`RarityConfig.RarityDisplayName[rarity]` (or `'Egg_' .. uniqueId`) →
pick the XZ via `Placement.PickXZAt` → position it via
`HoverMath.HoverY(centerFloorY, model)` → attach a `ProximityPrompt`
named `'BuyPrompt'` → stamp the record → `EggOverhead.Refresh(egg)` →
`AmbientService.RegisterModel(model)` → fire `EggSpawned`.

### The centre floor — the trap

`SpawnService.RegisterCenter(workspace)` creates:

- `Workspace.EggArea` (Folder)
- `Workspace.EggArea.Floor` — a `40 x 1 x 40` Part, `SmoothPlastic`,
  'Medium stone grey', at `CFrame.new(0,0,0)`
- `Workspace.EggArea.ActiveEggs` (Folder)

The floor height is `FloorGeometry.GetWorldTopY(floor)`, **not**
`floor.Size.Y / 2`. The production map's floor is a 90°-rotated
Cylinder, so `Size.Y` is the cylinder's *length*, and reading the half
height parks the spawns about **80 studs in the air**. This is the single
most important thing to know about `RegisterCenter`.

`RegisterCenter` is **idempotent** — calling it twice is safe.

### The purchase path

`EggService.Purchase(player, uniqueId)`:

1. **Validate the player is live** → `'player-not-live'`.
2. **Not already carrying** → `'carrying'`.
3. **The egg exists** → `'egg-not-found'`.
4. **Not already in progress** → `'in-progress'`.
5. **The egg is `Available`** → `'not-available'`. A `Placed` egg is
   unavailable, and so is a `Traveling` one **to the same player** (the
   owner re-buying their own in-flight egg is rejected **before** the
   debit).
6. **The service is wired** → `'service-not-ready'`.
7. **The price is a valid number** → `'invalid-price'`.
8. **The player can afford it** → `'insufficient-money'`. The debit is
   `economyServiceRef.TrySpendMoney(userId, costStr,
   TransactionReason.EggPurchase)` — an atomic read-compare-write.
9. **The purchase itself succeeded** → `'purchase-failed'`.
10. **The player has a base** → `'no-base'`.
11. **A slot could be reserved** → `'no-slot'`.
12. **The slot was not raced away** → `'slot-race'`.

**The contest.** A `Traveling` egg can be bought by *another* player.
The previous owner's record is removed and their slot released — **and
their money is NOT refunded**. The debit is sunk by design.

**The flight.** The egg flies to the owner's base **Collector**, not to
a slot. The landing slot is resolved **on arrival** by
`CollectorArrival.OnArrival`. The flight controller knows nothing about
slots.

**The generation guard.** `egg._flightGen` is bumped on every launch.
The controller only claims the egg if its generation is still current,
so a stale controller cannot steal a re-launched egg.

**The buy prompt** gets a `purchaserUserId` attribute stamped on it.

**Side effects on success:** `playerServiceRef.BumpStat(userId,
'EggsPurchased')`; `TutorialSignals.Fire('EggPurchased', { UserId,
EggId })`; `FunnelService:LogStep(player, 'Onboarding',
'FirstEggPurchased', nil)` and `('Progression', 'FirstEggPurchased',
nil)`.

### The flight

`FlightController.Start(egg, destination, onArrive?)`:

`destination = { cframe, floorStart, floorEnd }`.

**Duration is distance-derived**, not fixed:

```lua
duration = math.clamp(distance / max(0.001, Constants.EggTravelSpeed),
                       Constants.EggTravelMinDuration,
                       Constants.EggTravelMaxDuration)
```

with `EggTravelSpeed = EggConfig.PurchasedTravelSpeed` (5),
`EggTravelMinDuration` (3), `EggTravelMaxDuration` (15).

**The path** is computed at FLOOR level via
`PathfindingService:CreatePath(Constants.FlightAgentParams)` +
`ComputeAsync`, **one** retry, then a two-point straight-floor
fallback. The polyline is sanitised **once at launch** and never
recomputed, so an egg will not re-route around an obstacle that appears
mid-flight.

**`SanitizePath(points, a, b)`** (pure, exported for the specs):

- drops non-finite points,
- drops consecutive duplicates closer than `SEG_EPSILON = 0.01`,
- guarantees at least 2 points (falls back to `{ a, b }`).

**Per Heartbeat:**

- `t = (os.clock() - startedAt) / duration`,
- arc-length segment lookup along the polyline,
- XZ lerp,
- `floorY` lerp of the waypoint Ys, **capped** at
  `floorStart + MovementConfig.EggFlight.MaxClimbAboveStart`,
- `y = floorY + controller.walkGroundOffset` — a roam-style ground
  contact via `FloorGeometry.GetPivotGroundOffset`. **Not** the +3 hover
  clearance and **not** the Collector's Y.
- yaw smoothing `1 - exp(-YawSmoothing * dt)` via
  `PathfindingUtil.ShortestAngleDelta`,
- `EggWalkAnimator.Advance` (or `.Rest` once `t >= EF.SettleThreshold`),
  then `EggWalkAnimator.Pose` + `ApplyScale`.

A non-finite pose holds the last pose and warns once per flight.

**`_onComplete`** guards in this order: `egg._aborted` → return; model
gone → return; `egg.state ~= nil and egg.state ~= Traveling` → return.
Then it restores the exact scale, `PivotTo(controller.targetCFrame)`,
updates `egg.centerCFrame` and `egg._localFloor = controller.floorEnd`,
and calls `pcall(controller.onArrive, egg, controller)`.

**`FlightController.FacingOffset = math.pi`.** The models are authored
with the visual front on local `+Z`, so the yaw is flipped 180°.
(Contrast: `WalkController.FacingOffset = 0` for animals.)

### The hatch

`EggService.HatchEgg(player, uniqueId)` → `{ success, animalId?,
rarity? }`.

The error vocabulary: `'player-not-live'`, `'carrying'`,
`'egg-not-found'`, `'in-progress'`, `'not-placed'`, `'not-owner'`,
`'no-slot'`, `'slot-state'`, `'slot-race'`, `'no-weights'`,
`'no-definition'`, `'template-missing'`, `'roll-aborted'`, plus the
inner `CreateFromEgg` error.

The sequence:

1. Validate.
2. `DemoteSlotToReserved(egg.slotId)` — the slot is now reserved, not
   occupied, so nothing else can claim it mid-hatch.
3. **Roll the animal rarity** from `EggConfig.HatchRollWeights[egg.rarity]`.
   If the rolled rarity has no catalog definitions, **re-pick up to 8
   times**; if all 8 are empty, fall back to `egg.rarity` itself.
4. `AnimalConfig.GetRandom(rolledRarity)` → `winnerDefId`.
5. `TraitService.ResolveInheritance(egg.Trait, egg.Mutations, nil)` —
   **exactly one roll** of the trait.
6. **Pre-validate the winner's template** — it must exist AND have a
   `HumanoidRootPart`. If not → `RefundHatch` **before** the roulette
   plays. The player never watches an animation that cannot complete.
7. State → `Opening`.
8. Capture `primaryCF` and `groundCF` (via
   `RollController.ComputeGroundCFrame`).
9. **Destroy `egg.model` at click time** — not after the animation.
10. `RollController.Start(...)`.
11. Wait via `RunService.Heartbeat:Wait()` while `RollController.IsRunning`.
12. `RollController._consumeWinnerModel(controller)`.
13. `animalServiceRef.CreateFromEgg(egg, rolledRarity, winnerDefId, {
    spawnCFrameOverride = groundCF,
    TraitResolved = true,
    ResolvedTrait = hatchInheritance.Trait,
    ResolvedMutations = hatchInheritance.Mutations })`.
14. On failure → `RefundHatch`.
15. On success → `RollController.RevealFinalAnimal(rollController, animal)`
    (Reward audio + rarity VFX), state → `Consumed`,
    `SpawnService.DropEgg`, `BumpStat(userId, 'EggsHatched')`,
    `PushState`, `NotifySuccess(player, 'Hatch_Success', { AnimalName,
    Rarity })`, `TutorialSignals.Fire('EggHatched', { UserId, EggId,
    AnimalId })`, `FunnelService:LogStep(player, 'Onboarding',
    'FirstEggHatched', { rarity = rolledRarity })`.

**`RefundHatch(theEgg)`** flips the slot back to `Occupied` with the
egg as the occupant, stops the controller, sets the state to `Placed`,
rebuilds the model via `SpawnService.RebuildEggModel` if needed, calls
`HoverMath.Settle(theEgg, slot)`, and re-binds
`StandPresentation.Bind(theEgg.model, SlotType.OccupantKind.Egg)`.

### The roulette

`RollController.Start(egg, primaryCFrame, slotCFrame, rolledRarity,
winnerDefId, options?)` — **asserts** all five required arguments.

**`PickOrder(winnerDefId, rng?)`** (pure) builds the sequence:

- resolve the rolled rarity by scanning the catalog for the winner's
  `defId` (asserts it is in the catalog),
- build per-rarity sorted `defId` buckets,
- for each of `RollPreviewCount - 1` decoys: a weighted rarity pick
  from `EggConfig.HatchRollWeights[rolledRarity]` (cumulative
  distribution; a `weightTotal <= 0` means "use the rolled rarity"),
  then a random `defId` from that rarity's bucket **with replacement**
  (falling back to a non-empty bucket, then to the winner),
- append the winner **LAST**,
- `finalIndex = #chosen`.

**The timeline.** The total is `EggConfig.RollTotalDurationSeconds`
(5.0). The winner dwells for `RollWinnerDwellSeconds` (1.0). The
remaining 4 s is distributed across the decoys by an **arithmetic
progression** whose first interval is `RollFirstDecoyIntervalSeconds`
(0.025), solved from `_birthTime` so the intervals sum to **exactly**
`total - dwell`.

**The scale curve** per preview entry (`_aliveScale`):

| Phase | Fraction | Easing |
|---|---|---|
| Pop-in | 0.35 | cubic ease-out to a peak of 1.15 |
| Settle | 0.10 | cubic ease-in |
| Hold | 0.30 | — |
| Pop-out | 0.25 | cubic ease-in |

Entry scale `RollEntryScale` (0.1), exit scale `RollExitScale` (0.1).
The winner holds at scale 1.0 (no pop-out) and stays visible.

**The Y bob** is 1.5 Hz, 0.15 stud amplitude, wall-clock based.

**The mystery silhouette** (`_applySilhouette`) — one descendant pass
per shown entry:

- BaseParts (except fully transparent ones) → black + `Enum.Material.Neon`
  + Transparency 0,
- one `Highlight` (black fill, white outline, Occluded) parented to the
  entry,
- Decal / Texture / SurfaceAppearance / Beam / Trail / ParticleEmitter /
  Fire / Smoke / Sparkles / Highlight / PointLight / SpotLight /
  SurfaceLight / BillboardGui / SurfaceGui **destroyed**,
- `SpecialMesh.TextureId` and `MeshPart.TextureID` cleared,
- Humanoid / Animator / Attachments / welds / `Model.Name` **untouched**,
- idempotent via the `SilhouetteApplied` attribute,
- **clone-only** — the source template is never mutated (the spec
  asserts this).

**`_applyScale`** clamps the scale to `<= 0` → `0.001` (Roblox's
`Model:ScaleTo` rejects a scale `<= 0`) and quantises with
`SCALE_EPSILON = 0.004` per controller+model.

**`_previewCFrame`** uses `SlotMath.FeetOffsetBelowPrimary` (cached per
entry, normalised to the unscaled model) so the feet stay planted at any
scale.

**The audio.** `_prepareRollAudio` builds a **4-deep `Pop` pool** on an
invisible `RollAudioAnchor` inside the **hatching player's `PlayerGui`**
— deliberately never in `Workspace`, so nearby players do not hear
another player's ticks — plus a cached `Reward` source. The sources are
`ServerStorage.Assets.Sfx.Pop` and `.Reward`. Missing assets → a
session-once loud warning and a **mute roll** (no throw).

**`RevealFinalAnimal(controller, animal)`** is the canonical final-reveal
event. It is **idempotent** via `controller._revealPlayed`. It plays the
`Reward` sound cloned into the hatching player's `PlayerGui` and the
rarity explosion VFX (`ServerStorage.Assets.Vfx.Explosions.<rarity>`)
in one synchronous block. **The reveal VFX sounds are never played** —
they would be audible server-wide — so the `Sound` instances are created
and then destroyed.

**`ComputeGroundCFrame(slotCFrame, egg, facingPos?)`**:

- the Y comes from `egg._localFloor`, falling back to
  `HoverMath.FloorY(slotCFrame.Y, model)`,
- the rotation comes from the slot, or from
  `StandResolver.YawFacingCFrame(slotCFrame.Position, facingPos)` when
  `facingPos` is given,
- the slot XZ is preserved,
- **no 180° flip** (the spec asserts this explicitly).

### The ambient wander

`AmbientService.Start(_workspace?)` connects **one** central Heartbeat
for all eggs. The area resolves **lazily inside `_update`**, so a
late-replicating `EggArea` self-heals.

`RegisterModel(model)` is idempotent. It requires the area to resolve, a
`Model`, and a `PrimaryPart`. It then:

- anchors all BaseParts and sets
  `CanCollide`/`CanTouch`/`CanQuery` = `false`,
- rolls a random yaw, a walk speed in
  `[MinWalkSpeed, MaxWalkSpeed]`, and a random initial idle,
- captures `baseScale` (the model's own authored scale) and
  `groundOffset` (`FloorGeometry.GetPivotGroundOffset`),
- places the model on a clear sampled surface point (or the clamped
  floor centre as a fallback).

`UnregisterModel(model)` drops the state and restores `CanTouch` and
`CanQuery` to `true` on the descendants — **but not `CanCollide`**.

The internals:

- a **numeric two-level spatial hash grid** (cell = `SeparationRadius`,
  zero string allocation),
- 3x3-cell neighbour separation push,
- `dt` clamped to `1/20`,
- idle writes quantised at `IdleTickRate` Hz behind an `IdleEpsilon`
  deadband,
- a **personality rolled once at registration** — never `math.random()`
  per frame,
- the shared `EggWalkAnimator` supplies the walk cycle,
- `FloorGeometry.ClampToSurface` keeps eggs on the cap ellipse.

### The guarantee timers

`GuaranteeService`:

- `PickDue(nowOverride?)` → the first due entry **in config order**.
- `NoteSpawned(rarity)` → resets that rarity's clock and bumps
  `_revision`.
- `GetState(nowOverride?)` → one row per guarantee:
  `{ Rarity, Interval, Remaining, NextAt, Due, Revision }`.
- `_pushAttributes()` sets `Guarantee_<Rarity>_NextAt` / `_Interval` /
  `_Revision` on the Studio timer node.

The clock is `os.clock()`-based — **server-session scoped, no
DataStore**. A server restart resets every timer to full.

The timer node resolves via
`CenterPartBillboards.FindEggTimerNode(Workspace:FindFirstChild('Map'))`
→ `Map.CenterPart.BillboardGui.Egg`, with a legacy fallback to
`Map.EggTimer`. A missing asset degrades to a one-shot warn.

`Remaining` clamps at zero and never goes negative. Unknown rarities are
ignored without throwing.

**Legendary outranks Mythic when both are due** — the order is the
config order, and the config lists Legendary first.

### The rarity toast

`RareEggNotifier.ShouldNotify(rarity)` returns `true` for **Legendary,
Mythic, Divine and Secret only**. It uses an **explicit enum set**, NOT
an index into `RarityDefs.Order` — because `Order` puts **Mythic below
Legendary** (that is the order in the canonical rarity table).

`RareEggNotifier.Start()` is idempotent and subscribes **exactly once**
to `EggSpawned`. On a high-rarity spawn it fires
`NotificationService.NotifySuccess(player, 'RareEgg_Spawned', { EggName
= eggName })` for **every player in the server**.

### The `EggSpawned` event

`EggSpawned.Connect(fn)` (pcall-wrapped) and `EggSpawned.Fire(info)`,
with the payload `{ uniqueId, rarity, origin }`.

It fires **exactly once per NEW egg** (`Automatic` / `Admin` / `Test`).
A **persistence restore** and a **model rebuild** never fire it.

A listener that throws is **disconnected, never retried**.

### The height math (`HoverMath`)

This module owns **all** the egg height math. Two modes, and conflating
them is the classic bug:

- **HOVER** — the centre / in-flight pose. The egg's bottom face is
  `HoverClearance` (3) studs above the surface.
- **SEATED** — the slot-parking pose. The bottom face is **flush** with
  the slot top. Zero gap.

| Function | Formula |
|---|---|
| `BlockHeight(model?)` | The PrimaryPart's `Size.Y` (NOT `GetExtentsSize`, which a decorative child would inflate). Falls back to `Constants.EggSize.Y`. |
| `HoverY(floorY, model?)` | `floorY + HoverClearance + BlockHeight/2` |
| `FloorY(centreY, model?)` | the exact inverse of `HoverY` |
| `SlotFloorY(slot)` | `part.CFrame.Y + part.Size.Y / 2` (0 with no part) |
| `HoverCFrameOnSlot(slot, model?)` | the slot XZ + `StandResolver.GetSlotFacingRotation(slot)` + the hover Y |
| `GroundOffset(model?)` | the pivot-to-bottom offset measured in **pivot-local** space. Unclamped by design. |
| `GroundedCFrameOnSlot(slot, model?)` | the SEATED pose: bottom flush, zero gap |
| `Settle(egg, slot)` | mutates: `model:PivotTo(groundedCFrame)`, `egg.centerCFrame = cframe`, `egg._localFloor = SlotFloorY(slot)`, `egg.controller = nil`, `egg.controllerType = nil` |

`GroundedCFrameOnSlot` derives the Y from the slot **top**, so a thicker
slot part does not sink the egg, and it handles off-centre pivots.

### The carry and place

`EggService.GrabEgg(player, uniqueId)` — errors: `'player-not-live'`,
`'already-carrying'`, `'egg-not-found'`, `'not-placed'`, `'not-owner'`,
`'no-slot'`, `'no-base'`, `'too-far'` (vs
`PromptConfig.CarryMaxDistance`), `'slot-race'`, `'no-character'`,
`'carry-failed'`.

It sets the state to `Opening` as its in-flight marker, starts
`CarryController.Start` and `CarryRegistry.Set`, fires
`Remotes.FireClient(player, Remotes.Names.EggCarried, { BaseId, SlotId,
Rarity })`, and notifies `'Pickup_Success'`.

`EggService.PlaceEgg(player, uniqueId, destSlotId)` — errors:
`'player-not-live'`, `'not-carrying'`, `'carry-mismatch'`,
`'steal-in-progress'`.

- **Same slot:** `OccupySlot(srcSlotId, ...)` → `HoverMath.Settle` →
  `StandPresentation.Bind` → `InstallHatchPrompt` →
  `RemovePlacePromptsForBase` + `EnablePickupHatchPromptsForBase` →
  fire `EggPlaced` `{ BaseId, SlotId }`.
- **Different slot:** `ReleaseSlot(srcSlotId)` → `ReserveSlot(destSlotId)`
  → `OccupySlot(destSlotId, ...)` → `HoverMath.Settle` →
  `StandPresentation.Bind` → `InstallHatchPrompt` → then
  `playerServiceRef.SetEggSlot(userId, uniqueId, destSlotId)` — which
  **re-points the same record** rather than creating a new one. A
  `false` return is warned loudly.

**Arena slots are rejected** and the egg is recovered instead.

`EggService.RecoverCarriedEgg(player, reason?)` — two tiers:

1. `OccupySlot(originalSlotId)` — put it back where it came from.
2. If that fails, the **first `Empty` slot in the base**, and
   `SetEggSlot` re-points the persistence record.

It re-installs the prompts and **always** restores the base prompts and
pushes the state, even if no slot was found at all.

`EggService.ReconcileAfterBaseSwap(userId)` → `{ rehomed, rebuilt }` —
the post-Rebirth repair. A missing slot → re-home; a missing runtime →
respawn; a destroyed model → rebuild + re-seat + occupy + reinstall the
prompt. It **never throws** (the body is internally pcall'd).

---

## Public API surface

Full signatures in [API.md](API.md). The names:

**`EggService`** — `Init`, `Start`, `Stop`, `RegisterCenter`,
`ListCenterEggs`, `GetEgg`, `DropEggRuntime`, `Purchase`, `HatchEgg`,
`GrabEgg`, `PlaceEgg`, `RecoverCarriedEgg`, `ReconcileAfterBaseSwap`,
`RefundHatch`, `SpawnFromPersistence`, `ForceReleaseBase`,
`CleanupPlayer`, `IsCarrying`, `SetPlayerService`, `SetBaseService`,
`SetAnimalService`, `SetSlotService`, `SetEconomyService`.

**`Egg.SpawnService`** — `Init`, `SetPlayerService`, `SetBaseService`,
`SetAnimalService`, `SetSlotService`, `SetHatchPromptCallback`,
`GetHatchPromptCallback`, `SetEggGrabPromptCallback`,
`SetBuyPromptCallback`, `InstallHatchPrompt`, `RegisterCenter`,
`GetCenterFloorY`, `GetActiveContainer`, `GetCenterAreaCFrame`,
`GetEgg`, `DropEgg`, `RebuildEggModel`, `ListAvailable`, `AllEggs`,
`CountByState`, `CountNormalAvailable`, `ResolvePrice`, `LifetimeFor`,
`Request`, `ExpireEgg`, `SweepExpired`, `StartExpirySweep`,
`StopExpirySweep`, `ForceReleaseBase`, `SetEggAborted`.

**`Egg.FlightController`** — `Start`, `Stop`, `IsRunning`,
`SanitizePath`, plus the fields `YawSmoothing` and `FacingOffset`.

**`Egg.RollController`** — `PickOrder`, `ComputeGroundCFrame`, `Start`,
`RevealFinalAnimal`, `Stop`, `IsRunning`, plus the test seams
`_TestSilhouette`, `_TestPrepareRollAudio`, `_TestRewardSoundId`,
`_TestPlayAudio`.

**`Egg.AmbientService`** — `Init`, `Start`, `Stop`, `RegisterModel`,
`UnregisterModel`.

**`Egg.HoverMath`** — `BlockHeight`, `HoverY`, `FloorY`, `SlotFloorY`,
`HoverCFrameOnSlot`, `GroundOffset`, `GroundedCFrameOnSlot`, `Settle`.

**`Egg.ModelBuilder`** — `Build`, `SlotTargetCFrame`.

**`Egg.Placement`** — `IsFarFromAll`, `PickXZ`, `PickXZAt`.

**`Egg.Catalog`** — `Origin`, `ValidateDefinition`, `ValidateOrigin`.

**`Egg.GuaranteeService`** — `PickDue`, `NoteSpawned`, `GetState`,
`_TestReset`, `_TestSetLastSpawn`.

**`Egg.RareEggNotifier`** — `ShouldNotify`, `Start`.

**`Egg.EggSpawned`** — `Connect`, `Fire`.

**`Egg.EggOverhead`** — `Refresh`.

---

## Invariants the code enforces

1. **Only `SpawnService.Request` creates an egg.** Every path
   (automatic, admin, persistence, test) goes through it.
2. **`Request` validates before it acts**: a bad definition or a bad
   origin fails with an error string, never a throw.
3. **The cap counts the `Normal` pool only.**
4. **The `Persistence` origin bypasses the cap** and requires a
   `targetSlot`.
5. **The flight generation counter** (`egg._flightGen`) stops a stale
   controller from claiming a re-launched egg.
6. **The `_mutex` field** serialises `ExpireEgg` against a concurrent
   purchase.
7. **`ExpireEgg` only touches `Available` eggs** and identity-checks the
   record before dropping it.
8. **The expiry sweep never reaps a `Traveling` or mutex-held egg.**
9. **`SpawnFromPersistence` is the only path that sets the state
   directly to `Placed`.**
10. **The hatch rolls the trait exactly once**, inside
    `TraitService.ResolveInheritance`.
11. **The hatch re-rolls an empty animal rarity up to 8 times**, then
    falls back to the egg's own rarity.
12. **The winner template is validated before the roulette starts** —
    a bad template refunds instead of playing an animation that cannot
    finish.
13. **The egg model is destroyed at click time**, not after the
    animation.
14. **The hatch roll diagonal is always non-zero** — every egg rarity
    has a chance of the same-tier animal.
15. **`RollController.Start` asserts** its five required arguments.
16. **`RevealFinalAnimal` is idempotent.**
17. **The silhouette never mutates the source template.**
18. **The scale is clamped above 0 and epsilon-quantised.**
19. **The prompt installation order matters**: the Pickup prompt wipes
    **all** prompts on the model; the Open prompt wipes only a
    pre-existing Hatch prompt.
20. **A slot is demoted to `Reserved` before the hatch starts**, so
    nothing else can claim it mid-animation.

---

## Failure / edge-case behaviour

| Situation | Behaviour |
|---|---|
| `Purchase` on a non-existent egg | `{ success = false, error = 'egg-not-found' }` |
| `Purchase` on a `Placed` egg | `'not-available'` |
| The owner re-buys their own traveling egg | `'not-available'`, **before** the debit |
| Another player buys a traveling egg | Succeeds. The previous owner's record and slot are released; **no refund** |
| `Purchase` with insufficient funds | `'insufficient-money'`, no debit |
| `Purchase` with no base | `'no-base'` |
| `Purchase` with no free slot | `'no-slot'` |
| The slot is raced between the reserve and the occupy | `'slot-race'` |
| `HatchEgg` on a carried egg | `'not-placed'` (the state is `Opening`) |
| `HatchEgg` on someone else's egg | `'not-owner'` |
| `HatchEgg` with no weights for the rarity | `'no-weights'` |
| `HatchEgg` with an empty rarity bucket (all 8 re-rolls empty) | Falls back to the egg's own rarity |
| `HatchEgg` with no definition in the fallback bucket | `'no-definition'` |
| `HatchEgg` with a missing template | `'template-missing'`, **refunded before the animation** |
| `HatchEgg` when `CreateFromEgg` fails | `RefundHatch` and the inner error is returned |
| `GrabEgg` beyond `CarryMaxDistance` | `'too-far'` |
| `PlaceEgg` onto an arena slot | Rejected; the egg is **recovered** instead |
| `PlaceEgg` with a slot race | `'slot-race'` |
| `ForceReleaseBase` on a `Placed` egg | **Does NOT destroy it** — persistence is the source of truth |
| `ForceReleaseBase` on a `Traveling` egg | Destroys it and **refunds** the money |
| `SpawnService.Request` with a bad definition | `{ success = false, error = 'definition must be a table' }` (and the other definition errors) |
| `SpawnService.Request` with a bad origin | `error = 'origin must be Automatic, Admin, Persistence, or Test'` |
| `SpawnService.Request` with `Persistence` and no slot | `error = 'persistence-requires-target-slot'` |
| `SpawnService.Request` over the cap | `error = 'cap-reached'` |
| `SpawnService.Request` before the centre is registered | `error = 'center-not-registered'` |
| `FlightController.Start` with no model | **Throws** (level 2) |
| `FlightController.Start` with an unparented model | **Throws** (level 2) |
| `FlightController.Start` with no `PrimaryPart` | **Throws** (level 2) |
| `FlightController.Start` with no destination | **Throws** (level 2) |
| A non-finite pose during the flight | Holds the last pose, warns once per flight |
| `RollController.Start` with a missing argument | **Asserts** |
| The `Pop` / `Reward` sounds are missing | One loud session warning; the roll is **mute**, no throw |
| `RareEggNotifier.ShouldNotify` on garbage | `false`, no throw |
| `RareEggNotifier.Start` called twice | Idempotent |
| An `EggSpawned` listener throws | It is **disconnected**, never retried |
| `GuaranteeService.PickDue` with an unknown rarity | Ignored, no throw |
| `AmbientService.RegisterModel` on garbage | `false`, no throw |
| `AmbientService.Start` with no area | `false`; the loop self-heals when the area appears |

**The two throwing functions are `FlightController.Start` (level 2) and
`RollController.Start` (an `assert`).** Everything else returns an error
code or degrades.

---

## Gotchas that would bite you

- **The centre floor is a rotated Cylinder in production.** Using
  `Size.Y / 2` parks the eggs ~80 studs in the air. Always use
  `FloorGeometry.GetWorldTopY`.

- **The egg flies to the Collector, not to a slot.** The slot is
  resolved on arrival by `CollectorArrival.OnArrival`. If you change
  the flight target, you break the arrival path.

- **A traveling egg is contestable, and the loser is not refunded.**
  This is intentional but surprising.

- **`Opening` is overloaded.** It means both "mid-hatch" and "being
  carried". `HatchEgg` rejects anything that is not `Placed`.

- **`HoverMath` has TWO modes** — hover (clearance) and seated (flush).
  `Settle` is the seated one. Using `HoverY` for a slot seat leaves the
  egg floating 3 studs above the stand.

- **`SpawnService.CountNormalAvailable` is the cap counter, not
  `AllEggs`.** `AllEggs` includes `Extra`-pool eggs and the `Placed`
  ones.

- **The guarantee spawn uses `pool = 'Extra'`**, so the centre can hold
  more than 10.

- **`CenterSpawn.TravelDuration` is dead code.** The flight is
  speed-derived.

- **The flight path is computed once.** No mid-flight re-route.

- **`AmbientService.UnregisterModel` does not restore `CanCollide`.**
  A purchased egg keeps `CanCollide = false`.

- **`AmbientService.RegisterModel` does not retry.** If the area is not
  resolved at that instant, it returns `false` and the egg never
  wanders.

- **`ModelBuilder` falls back to a procedural cube** when the template
  is missing. That is a **silent** downgrade, not an error.

- **`RollController` prepares the audio in the hatching player's
  `PlayerGui`**, not in `Workspace`. Do not "fix" that to Workspace —
  it would make every player hear every other player's ticks.

- **The reveal VFX sounds are destroyed, not played.** Deliberate.

- **`EggService` requires `EconomyService` directly** as well as through
  injection. The `ForceReleaseBase` refund path uses the direct
  require. A cycle is possible if `EconomyService` ever requires
  `EggService` back.

- **`SpawnService.Request` is the only spawn path.** If you add a
  second one, the cap, the expiry sweep and the `EggSpawned` event
  will all be inconsistent.

- **`Config.Creatures.Eggs` requires `Config.Creatures.Rarity`**, which
  lives in the **MutationsAndTraits** system's tree, not in this one.
  Copying this system without that one breaks the require chain.

- **The hatch-roll matrix's diagonal must stay non-zero.** An egg
  rarity with a zero on its own diagonal can never hatch a same-tier
  animal.

- **The `Uncommon` and `Secret` animal buckets are empty.** The hatch
  re-rolls around them (up to 8 times), which slightly concentrates
  the surviving rarities.

- **`ResolveInheritance` is called with `nil` for the roll override**,
  so the hatch trait roll is real. There is exactly **one** roll per
  hatch.

---

## To reuse this in a different game

1. **Take `Egg/*`, write your own facade.** The facade is a hub; the
   sub-modules are not.
2. **Keep the five states** and the `Opening` overload. Other systems
   read `egg.state`.
3. **Keep the `Normal` / `Extra` pool split** and the `pool` field.
4. **Keep `_mutex` and `_flightGen`.** They are the two concurrency
   guards.
5. **Keep the flight-to-Collector + slot-on-arrival split**, or
   re-implement the contest handling with it.
6. **Replace the catalog** — `Price`, `HatchRollWeights`,
   `EggLifetimeSeconds`, `Guarantees`, `Ambient` are all content.
7. **Keep the hatch-roll diagonal non-zero.**
8. **Author `ServerStorage.EggTemplates.<Rarity>`** models with a
   `PrimaryPart`.
9. **Author `ServerStorage.Assets.Sfx.Pop` and `.Reward`**, or accept a
   mute roll.
10. **Keep the "no `TweenService`" convention** if you want the
    existing movement code to work: `Heartbeat` + `PivotTo` +
    `ScaleTo`, with everything anchored at all times.
