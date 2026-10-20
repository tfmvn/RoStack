# EggsAndHatching — API

Every public function of every module in this system. See
[README.md](README.md) for the overview, [MEMORY.md](MEMORY.md) for the
behavioural notes, and [Dependencies.md](Dependencies.md) for the
require paths.

**Failure-mode policy for this system:** the `EggService` facade returns
`{ success = false, error = '<code>' }` — it does **not** throw. The
sub-modules under `Egg/` mostly return `nil` / `false` and log. The
**two exceptions** are:

- `Egg.FlightController.Start` — **throws (level 2)** on a missing
  model, an unparented model, a missing `PrimaryPart`, or a missing
  destination.
- `Egg.RollController.Start` — **asserts** its five required arguments.

---

## `ServerScriptService.EggService`

The facade. Server-only. Frozen at return.

### `EggService.Init()`

Initialises the sub-modules and wires the prompt callbacks.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** does not throw. Internally calls
  `SpawnService.Init()`, `ServerLuckService.Init()` and
  `RareEggNotifier.Start()`, and installs three callbacks:
  - **Buy** -> `EggService.Purchase`
  - **Hatch** -> `SlotActionHandler.Handle(player, { Action = 'Hatch', SlotId = egg.slotId, OccupantId = uniqueId })`
  - **Egg Grab** -> `SlotActionHandler.Handle(player, { Action = 'Pickup', ... })`
- **Note:** the `Set*Service` injection must be done **before** `Init()`.

---

### `EggService.Start()`

Starts the centre top-up background thread.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** does not throw. The thread runs every
  `Constants.CenterSpawnInterval` seconds and tops the centre up toward
  `Constants.EggCenterMax`. Per slot: if `GuaranteeService.PickDue()`
  returns a rarity, it spawns with `pool = 'Extra'` (**bypassing the
  cap**); otherwise, if `SpawnService.CountNormalAvailable() <
  EggCenterMax`, it applies luck to `EggConfig.CenterSpawnRarityWeights`
  via `ServerLuckService.ApplyLuck`, picks with `WeightedDraw.Choose`,
  and spawns with `pool = 'Normal'`. On success it calls
  `GuaranteeService.NoteSpawned(rarity)`.
- **Note:** `task.wait(0.1)` breather between top-ups.

---

### `EggService.Stop()`

Stops the top-up thread.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** does not throw. Safe to call when not started.

---

### `EggService.RegisterCenter(workspace): any`

Creates the centre folder structure and starts the ambient wander loop.

- **Parameters:** `workspace` — the `Workspace` instance.
- **Returns:** whatever `SpawnService.RegisterCenter` returns.
- **Failure modes:** does not throw. **Idempotent** — calling it twice
  is safe. Creates `Workspace.EggArea`, `Workspace.EggArea.Floor` (a
  `40 x 1 x 40` Part) and `Workspace.EggArea.ActiveEggs`.
- **Note:** the floor height is read with
  `FloorGeometry.GetWorldTopY(floor)`, **not** `Size.Y / 2` — the
  production floor is a 90°-rotated Cylinder.

---

### `EggService.ListCenterEggs(): { any }`

The `Available` eggs in the centre.

- **Parameters:** none.
- **Returns:** an array of egg records (delegates to
  `SpawnService.ListAvailable()`).
- **Failure modes:** does not throw. Returns `{}` when there are none.

---

### `EggService.GetEgg(uniqueId: any): any?`

The egg record.

- **Parameters:** `uniqueId` — the egg's id.
- **Returns:** the egg record, or `nil`.
- **Failure modes:** does not throw. The id is validated with
  `Validation.ShortString`, so a malformed id returns `nil` rather
  than raising.

---

### `EggService.DropEggRuntime(uniqueId: any): boolean`

Removes a runtime egg without touching the profile.

- **Parameters:** `uniqueId` — the egg's id.
- **Returns:** `true` if the egg was dropped, `false` otherwise.
- **Failure modes:** does not throw.

---

### `EggService.Purchase(player: Player, uniqueId: any): any`

Buys an egg.

- **Parameters:** `player` — the buyer. `uniqueId` — the egg's id.
- **Returns:** `{ success = true, egg = <record> }` or
  `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. The exact error codes, in the
  order they are checked:

  | Code | Meaning |
  |---|---|
  | `'player-not-live'` | The player is not a live `Player`. |
  | `'carrying'` | The player is already carrying something. |
  | `'egg-not-found'` | No such egg. |
  | `'in-progress'` | A purchase for this egg is already running. |
  | `'not-available'` | The egg is not `Available` — it is `Placed`, or it is `Traveling` **to this same player**. |
  | `'service-not-ready'` | The economy (or another peer) is not wired. |
  | `'invalid-price'` | The resolved price is not a valid number. |
  | `'insufficient-money'` | The debit was refused. |
  | `'purchase-failed'` | The economy's debit call returned false. |
  | `'no-base'` | The player has no base. |
  | `'no-slot'` | No free slot could be reserved. |
  | `'slot-race'` | The slot was taken between the reserve and the occupy. |

- **Contest:** a `Traveling` egg **can** be bought by another player.
  The previous owner's record is removed and their slot released, and
  **their money is not refunded**.
- **Side effects:** `PlayerService.BumpStat(userId, 'EggsPurchased')`,
  `TutorialSignals.Fire('EggPurchased', { UserId, EggId })`,
  `FunnelService:LogStep(player, 'Onboarding', 'FirstEggPurchased', nil)`
  and `('Progression', 'FirstEggPurchased', nil)`. The buy prompt gets a
  `purchaserUserId` attribute.

---

### `EggService.HatchEgg(player: Player, uniqueId: any): any`

Hatches an egg into an animal.

- **Parameters:** `player` — the owner. `uniqueId` — the egg's id.
- **Returns:** `{ success = true, animalId = '<id>', rarity = '<rarity>' }`
  or `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. The error codes:

  | Code | Meaning |
  |---|---|
  | `'player-not-live'` | Not a live `Player`. |
  | `'carrying'` | The player is already carrying something. |
  | `'egg-not-found'` | No such egg. |
  | `'in-progress'` | A hatch for this egg is already running. |
  | `'not-placed'` | The egg is not `Placed` (a carried egg is `Opening`). |
  | `'not-owner'` | The player does not own the egg. |
  | `'no-slot'` | No slot could be reserved. |
  | `'slot-state'` | The slot state machine rejected the transition. |
  | `'slot-race'` | The slot was taken mid-hatch. |
  | `'no-weights'` | The egg rarity has no hatch-roll weights. |
  | `'no-definition'` | The rolled rarity has no catalog definitions (after 8 re-rolls). |
  | `'template-missing'` | The winner's template is missing or has no `HumanoidRootPart`. **Refunded before the roulette plays.** |
  | `'roll-aborted'` | The roll controller was stopped mid-animation. |

  Plus the inner `AnimalService.CreateFromEgg` error, which is returned
  verbatim (and the egg is refunded).

- **Note:** the trait is rolled **exactly once**, inside
  `TraitService.ResolveInheritance`.

---

### `EggService.GrabEgg(player: Player, uniqueId: any): any`

Picks an egg up.

- **Parameters:** `player` — the picker. `uniqueId` — the egg's id.
- **Returns:** `{ success = true, ... }` or
  `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. Error codes: `'player-not-live'`,
  `'already-carrying'`, `'egg-not-found'`, `'not-placed'`,
  `'not-owner'`, `'no-slot'`, `'no-base'`, `'too-far'` (beyond
  `PromptConfig.CarryMaxDistance`), `'slot-race'`, `'no-character'`,
  `'carry-failed'`.
- **Note:** the egg's state becomes `Opening` (its in-flight marker), so
  `HatchEgg` rejects it until it is placed again.
- **Side effects:** fires `EggCarried` `{ BaseId, SlotId, Rarity }` and
  notifies `'Pickup_Success'`.

---

### `EggService.PlaceEgg(player: Player, uniqueId: any, destSlotId: any): any`

Seats an egg on a stand.

- **Parameters:** `player` — the carrier. `uniqueId` — the egg's id.
  `destSlotId` — the target slot id.
- **Returns:** `{ success = true, ... }` or
  `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. Error codes: `'player-not-live'`,
  `'not-carrying'`, `'carry-mismatch'`, `'steal-in-progress'`.
- **Note:** an **arena slot is rejected** and the egg is recovered
  instead. The same-slot path and the different-slot path differ: the
  different-slot path calls `PlayerService.SetEggSlot` to **re-point the
  same record** (a `false` return is warned loudly).

---

### `EggService.RecoverCarriedEgg(player: Player, reason: string?): any`

Re-seats a carried egg after a failure.

- **Parameters:** `player` — the carrier. `reason` — optional, a label
  for the log.
- **Returns:** a result table.
- **Failure modes:** does not throw. Two tiers: (1) `OccupySlot` on the
  `originalSlotId`; (2) if that fails, the **first `Empty` slot in the
  base**, with `SetEggSlot` re-pointing the persistence record. The
  prompts are re-installed and the base prompts and the player state
  are **always** restored, even when no slot was found.

---

### `EggService.ReconcileAfterBaseSwap(userId: any): { [string]: number }`

The post-Rebirth repair.

- **Parameters:** `userId` — the player whose base was swapped.
- **Returns:** `{ rehomed = <n>, rebuilt = <n> }`.
- **Failure modes:** **never throws** — the body is internally pcall'd.
  A missing slot -> re-home; a missing runtime -> respawn; a destroyed
  model -> rebuild + re-seat + occupy + reinstall the prompt.

---

### `EggService.RefundHatch(theEgg: any): any`

Reverts an `Opening` egg to `Placed`.

- **Parameters:** `theEgg` — the egg record.
- **Returns:** a result table.
- **Failure modes:** does not throw. Flips the slot back to `Occupied`
  with the egg as the occupant, stops the controller, sets the state to
  `Placed`, rebuilds the model via `SpawnService.RebuildEggModel` if
  needed, calls `HoverMath.Settle(theEgg, slot)`, and re-binds
  `StandPresentation.Bind(theEgg.model, SlotType.OccupantKind.Egg)`.

---

### `EggService.SpawnFromPersistence(userId: any, record: any, slot: any): any`

Restores an egg on rejoin.

- **Parameters:** `userId` — the owner. `record` — the persisted egg
  row. `slot` — the slot to seat it on.
- **Returns:** `{ success = true, egg = <record> }` or
  `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. An unknown rarity ->
  `{ success = false, error = 'unknown-rarity' }`.
- **Note:** the `Persistence` origin **bypasses the centre cap**.

---

### `EggService.ForceReleaseBase(baseId: any)`

Tears down the in-flight eggs for a base.

- **Parameters:** `baseId` — the base id.
- **Returns:** nothing.
- **Failure modes:** does not throw. Only **`Traveling` and `Opening`**
  eggs are torn down. A **`Placed` egg is NOT destroyed** — the
  profile is the source of truth. A travelling egg has its persistence
  record removed **first**, its money refunded via
  `EconomyService.AddMoney(userId, refundStr,
  TransactionReason.EggRefund)`, its `_aborted` flag set, its
  controller stopped, its slot released, and its model destroyed.

---

### `EggService.CleanupPlayer(userId: any)`

Runs on player leave.

- **Parameters:** `userId` — the leaving player.
- **Returns:** nothing.
- **Failure modes:** does not throw. Lazily requires
  `Steal.StealService` and calls `RollbackIfStealing(userId,
  'disconnect')` and `RollbackStolenTarget('egg', uniqueId,
  'owner-leaving')`, calls `SpawnService.ForceReleaseBase(base.id)`, and
  sweeps the `Placed` eggs the user owns (unbind the stand wobble,
  destroy the model, `SpawnService.DropEgg`). The **persisted records
  are left intact** so the player can rejoin.

---

### `EggService.IsCarrying(playerOrUserId: any): boolean`

Is this player carrying something?

- **Parameters:** `playerOrUserId` — a `Player` or a userId.
- **Returns:** `true` / `false`.
- **Failure modes:** does not throw. A thin wrapper over
  `CarryRegistry`.

---

### `EggService.SetPlayerService(svc)` / `SetBaseService(svc)` / `SetAnimalService(svc)` / `SetSlotService(svc)` / `SetEconomyService(svc)`

Late-bound dependency injection.

- **Parameters:** `svc` — the peer service.
- **Returns:** nothing.
- **Failure modes:** does not throw. **Call all of them before
  `Init()`.**

---

## `ServerScriptService.Egg.SpawnService`

The single authoritative spawn entry point. Server-only. Frozen at return.

### `SpawnService.Init()`

No-op. The service holds a registry, not per-init state.

- **Parameters / Returns / Failure modes:** none / nothing / does not throw.

### `SpawnService.SetPlayerService / SetBaseService / SetAnimalService / SetSlotService(svc)`

Late-bound dependency injection.

- **Failure modes:** does not throw.

### `SpawnService.Request(req: any): any`

**The** spawn entry point. Nothing else creates an egg.

- **Parameters:** `req` — a table with:
  - `definition` — `{ rarity = <string>, price = <number> }`.
  - `origin` — `'Automatic' | 'Admin' | 'Persistence' | 'Test'`.
  - `targetSlot` — **Persistence only**; the slot to seat the egg on.
  - `xz` — Test/admin only; a fixed XZ on the ring.
  - `adminUserId` — Admin only; for the audit log.
- **Returns:** `{ success = true, egg = <record> }` or
  `{ success = false, error = '<code>' }`.
- **Failure modes:** does not throw. The error codes:

  | Code | Meaning |
  |---|---|
  | `'definition must be a table'` | `definition` is not a table. |
  | `'definition.rarity must be a string'` | |
  | `'definition.price must be a number'` | |
  | `'definition.price must be non-negative'` | |
  | `'origin must be a string'` | |
  | `'origin must be Automatic, Admin, Persistence, or Test'` | |
  | `'persistence-requires-target-slot'` | The `Persistence` origin had no `targetSlot`. |
  | `'cap-reached'` | The normal pool is at the cap. |
  | `'center-not-registered'` | `RegisterCenter` has not been called. |

- **Note:** the `Admin` origin **or** an explicit `pool == 'Extra'`
  bypasses the cap. The `Persistence` origin bypasses the cap too.

### `SpawnService.RegisterCenter(workspace): any`

Creates the centre folders and measures the floor.

- **Failure modes:** does not throw. **Idempotent.**

### `SpawnService.GetCenterFloorY(): number`

The centre floor's world top Y.

- **Failure modes:** does not throw.

### `SpawnService.GetActiveContainer(): Folder`

The `Workspace.EggArea.ActiveEggs` folder.

- **Failure modes:** does not throw. Errors if the centre is not
  registered.

### `SpawnService.GetCenterAreaCFrame(): CFrame`

The centre area's transform.

- **Failure modes:** does not throw.

### `SpawnService.GetEgg(uniqueId: any): any?`

The egg record, or `nil`.

- **Failure modes:** does not throw. The id is validated with
  `Validation.ShortString`.

### `SpawnService.DropEgg(uniqueId: any)`

Removes an egg from the registry and destroys its model.

- **Failure modes:** does not throw.

### `SpawnService.RebuildEggModel(egg: any): boolean`

Rebuilds a destroyed egg model.

- **Returns:** `true` on success, `false` otherwise.
- **Failure modes:** does not throw.

### `SpawnService.ListAvailable(): { any }`

The `Available` eggs.

- **Returns:** an array of `{ UniqueId, Rarity, Price }` rows.
- **Failure modes:** does not throw.

### `SpawnService.AllEggs(): { any }`

Every egg in the registry, in any state.

- **Failure modes:** does not throw.

### `SpawnService.CountByState(state: string): number`

How many eggs are in a given state.

- **Failure modes:** does not throw. An unknown state -> `0`.

### `SpawnService.CountNormalAvailable(): number`

**The cap counter.** Counts the records whose `pool ~= 'Extra'`.

- **Failure modes:** does not throw.

### `SpawnService.ResolvePrice(rarity: string): number`

The price for a rarity.

- **Returns:** `EggConfig.Price[rarity]`, falling back to `100` for an
  unknown rarity.
- **Failure modes:** does not throw.

### `SpawnService.LifetimeFor(rarity: string): number`

The lifetime for a rarity.

- **Returns:** `EggConfig.EggLifetimeSeconds[rarity]`, falling back to
  `300` for an unknown rarity.
- **Failure modes:** does not throw.

### `SpawnService.ExpireEgg(egg: any): boolean`

Drops one past-deadline `Available` egg.

- **Returns:** `true` if the egg was expired.
- **Failure modes:** does not throw. Only touches `Available` eggs, is
  mutex-safe, and identity-checks the record before dropping it. A
  `Traveling` or mutex-held egg is **never** reaped.

### `SpawnService.SweepExpired(nowOverride: number?): number`

Drops every past-deadline `Available` egg.

- **Parameters:** `nowOverride` — optional, the timestamp to compare
  against (the test seam).
- **Returns:** the number of eggs reaped.
- **Failure modes:** does not throw. It collects the due set first, then
  expires them. It also frees past-deadline records whose **model is
  already gone**.

### `SpawnService.StartExpirySweep()` / `SpawnService.StopExpirySweep()`

The one shared sweep loop, at `EggConfig.ExpirySweepSeconds` (5 s).

- **Failure modes:** does not throw. There is exactly **one** loop, not
  one per egg.

### `SpawnService.ForceReleaseBase(baseId: any)`

Tears down the in-flight eggs for a base and refunds them.

- **Failure modes:** does not throw. See `EggService.ForceReleaseBase`.

### `SpawnService.SetEggAborted(uniqueId: any)`

Marks an egg as aborted so a stale controller cannot act on it.

- **Failure modes:** does not throw.

### `SpawnService.SetHatchPromptCallback(fn)` / `GetHatchPromptCallback()` / `SetEggGrabPromptCallback(fn)` / `SetBuyPromptCallback(fn)`

Prompt callback registration.

- `GetHatchPromptCallback()` returns the callback or `nil`.
- `SetBuyPromptCallback` stores the callback **locally** (it is not
  forwarded to `CarryPrompts`).
- **Failure modes:** does not throw.

### `SpawnService.InstallHatchPrompt(egg: any, slot: any?, ownerUserId: number?)`

Installs the Pickup and Open prompts on an egg.

- **Failure modes:** does not throw. **Order matters**: the Pickup
  prompt is installed **first**, then the Open prompt. The Pickup
  installer wipes **all** prompts on the model; the Open installer
  wipes only a pre-existing Hatch prompt.

---

## `ServerScriptService.Egg.FlightController`

Server-only. Frozen at return.

### `FlightController.Start(egg: any, destination: any, onArrive: any?): any`

Launches the flight.

- **Parameters:**
  - `egg` — the egg record (must have a `model` with a `PrimaryPart`).
  - `destination` — `{ cframe, floorStart, floorEnd }`.
  - `onArrive` — optional; called as `onArrive(egg, controller)` when
    the egg lands. It is invoked inside a `pcall`.
- **Returns:** the flight controller.
- **Failure modes:** **THROWS (level 2)** if `egg.model` is missing or
  unparented, if `egg.model.PrimaryPart` is `nil`, or if
  `destination.cframe` is `nil`. These are programming errors, not
  runtime conditions.
- **Note:** the duration is
  `clamp(distance / max(0.001, Constants.EggTravelSpeed),
  Constants.EggTravelMinDuration, Constants.EggTravelMaxDuration)`.

### `FlightController.Stop(controller: any)`

Aborts the flight.

- **Failure modes:** does not throw. Sets `stopped` and `aborted`,
  disconnects the Heartbeat, and best-effort restores the model's
  authored scale via `EggWalkAnimator.RestoreScale`.

### `FlightController.IsRunning(controller: any): boolean`

Is the flight still running? (`not controller.stopped`.)

- **Failure modes:** does not throw.

### `FlightController.SanitizePath(points: any, a: any, b: any): { Vector3 }`

Pure path sanitiser.

- **Parameters:** `points` — the raw path. `a`, `b` — the endpoints
  used for the fallback.
- **Returns:** a sanitised array of at least 2 `Vector3`s.
- **Failure modes:** does not throw. Drops non-finite points and
  consecutive duplicates closer than `SEG_EPSILON = 0.01`. If fewer
  than 2 points survive, falls back to `{ a, b }`. Deterministic.

### `FlightController.YawSmoothing` / `FlightController.FacingOffset`

- `YawSmoothing` = `MovementConfig.YawSmoothing`.
- `FacingOffset` = `math.pi` — the models are authored with the visual
  front on local `+Z`, so the yaw is flipped 180°.

---

## `ServerScriptService.Egg.RollController`

The 3D roulette. Server-only. Frozen at return.

### `RollController.Start(egg: any, primaryCFrame: any, slotCFrame: any, rolledRarity: string, winnerDefId: string, options: any?): any`

Starts the roulette.

- **Parameters:** `egg`, `primaryCFrame`, `slotCFrame`, `rolledRarity`,
  `winnerDefId` — all five **required**. `options` — optional
  `{ rng?, facingPos? }`.
- **Returns:** the roll controller.
- **Failure modes:** **ASSERTS** if any of the five required arguments
  is missing. Does not throw for a missing `ServerStorage` asset — the
  roll degrades to a **mute** roll with one loud session warning.
- **Note:** the driver is a `task.spawn` thread, **not** a Heartbeat
  loop.

### `RollController.RevealFinalAnimal(controller: any, animal: any): boolean`

The canonical final-reveal event.

- **Returns:** `true` if the reveal played, `false` if it was
  idempotently suppressed.
- **Failure modes:** does not throw. **Idempotent** via
  `controller._revealPlayed`. Plays the `Reward` sound cloned into the
  hatching player's `PlayerGui` and the rarity explosion VFX
  (`ServerStorage.Assets.Vfx.Explosions.<rarity>`) in one synchronous
  block. The **reveal VFX sounds are never played** — they would be
  audible server-wide — so the `Sound` instances are destroyed.

### `RollController.Stop(controller: any)` / `RollController.IsRunning(controller: any): boolean`

Stop the roll / is it running (`not controller.stopped`).

- **Failure modes:** does not throw.

### `RollController.PickOrder(winnerDefId: string, rng: any?): any`

Pure. The decoy sequence.

- **Returns:** `{ defIds = { <string>... }, finalIndex = <number> }`.
  The winner is always the **last** entry; `finalIndex = #defIds`.
- **Failure modes:** **asserts** that the winner's `defId` is in the
  catalog.

### `RollController.ComputeGroundCFrame(slotCFrame: any, egg: any, facingPos: any?): CFrame`

Pure. Where the winner lands.

- **Returns:** a `CFrame` with the slot XZ, the slot rotation (or
  `StandResolver.YawFacingCFrame` when `facingPos` is given), and the Y
  from `egg._localFloor` (falling back to `HoverMath.FloorY`).
- **Failure modes:** does not throw. **No 180° flip.**

### Test seams

| Seam | Returns | Notes |
|---|---|---|
| `RollController._TestSilhouette(model: any): number` | The number of parts silhouetted. | Clone-only; never mutates the source template; idempotent; safe on garbage. |
| `RollController._TestPrepareRollAudio(hostFolder: any, position: any): any` | `{ pops, hasReward, anchor }` | Builds the bounded pool + reward under the host folder, inheriting the `SoundIds`. |
| `RollController._TestRewardSoundId(): string?` | The reward sound's id, or `nil`. | |
| `RollController._TestPlayAudio(controller: any, which: string, animal: any?): boolean` | Whether it played. | `which` is `'pop'` or `'reveal'`. |

---

## `ServerScriptService.Egg.AmbientService`

The centre wander loop. Server-only. Frozen at return.

### `AmbientService.Init()`

No-op.

### `AmbientService.Start(_workspace: any?): boolean`

Connects the one central Heartbeat.

- **Returns:** `true` if the loop started, `false` otherwise.
- **Failure modes:** does not throw. The area resolves **lazily inside
  `_update`**, so a late-replicating `EggArea` self-heals.

### `AmbientService.Stop()`

Disconnects the Heartbeat and clears the states.

- **Failure modes:** does not throw.

### `AmbientService.RegisterModel(model: any): boolean`

Adds an egg to the wander loop.

- **Returns:** `true` on success, `false` when the area is
  unavailable or the model is unsuitable (not a `Model`, or no
  `PrimaryPart`).
- **Failure modes:** does not throw. **Idempotent.** It anchors all
  `BasePart`s and sets `CanCollide`/`CanTouch`/`CanQuery = false`. It
  rolls the yaw, the walk speed and the initial idle **once**, captures
  `baseScale` and `groundOffset`, and places the model on a clear
  sampled surface point (or the clamped floor centre as a fallback).
- **Note:** it does **not** retry if the area is unavailable.

### `AmbientService.UnregisterModel(model: any)`

Removes an egg from the wander loop.

- **Failure modes:** does not throw. Restores `CanTouch` and `CanQuery`
  to `true` on the descendants — **but not `CanCollide`**.

---

## `ServerScriptService.Egg.HoverMath`

All the egg height math. Server-only. Frozen at return.

### `HoverMath.BlockHeight(model: any?): number`

The PrimaryPart's `Size.Y`.

- **Returns:** the PrimaryPart's height, falling back to
  `Constants.EggSize.Y` when there is no model or no PrimaryPart.
- **Failure modes:** does not throw. **Not** `GetExtentsSize` — a
  decorative child would inflate that.

### `HoverMath.HoverY(floorY: number, model: any?): number`

The HOVER centre height.

- **Returns:** `floorY + Constants.HoverClearance + BlockHeight(model) / 2`.
- **Failure modes:** does not throw.

### `HoverMath.FloorY(centreY: number, model: any?): number`

The exact inverse of `HoverY`.

- **Failure modes:** does not throw.

### `HoverMath.SlotFloorY(slot: any): number`

The slot part's top surface.

- **Returns:** `part.CFrame.Y + part.Size.Y / 2`, or `0` when the slot
  has no part.
- **Failure modes:** does not throw.

### `HoverMath.HoverCFrameOnSlot(slot: any, model: any?): CFrame`

The hover pose on a slot.

- **Returns:** the slot XZ, the slot rotation (from
  `StandResolver.GetSlotFacingRotation(slot)`), and the hover Y.
- **Failure modes:** does not throw. The Y comes from the slot **top**,
  so a thicker slot part does not sink the egg.

### `HoverMath.GroundOffset(model: any?): number`

The pivot-to-bottom offset, measured in **pivot-local** space.

- **Failure modes:** does not throw. Unclamped by design.

### `HoverMath.GroundedCFrameOnSlot(slot: any, model: any?): CFrame`

The SEATED pose — bottom flush, zero gap.

- **Failure modes:** does not throw. Derives the Y from the slot top
  and handles off-centre pivots. Falls back to half `EggSize` with no
  model.

### `HoverMath.Settle(egg: any, slot: any)`

Parks the egg on its slot.

- **Failure modes:** does not throw. **Mutates** the egg:
  `model:PivotTo(groundedCFrame)`, `egg.centerCFrame = cframe`,
  `egg._localFloor = SlotFloorY(slot)`, `egg.controller = nil`,
  `egg.controllerType = nil`.
- **Note:** this is the SEATED mode, not the hover mode. Do not
  conflate them.

---

## `ServerScriptService.Egg.ModelBuilder`

Server-only. Frozen at return.

### `ModelBuilder.Build(rarity: string, parent: any): Model`

Builds the egg model.

- **Parameters:** `rarity` — the rarity. `parent` — where to parent
  the model.
- **Returns:** the `Model`.
- **Failure modes:** does not throw. Clones the first `Model` child of
  `ServerStorage.EggTemplates.<rarity>` if there is one (picking the
  `PrimaryPart` by name `'Primary'`, else the first descendant
  `BasePart`), anchoring everything and disabling collisions, and
  ensuring a welded `HumanoidRootPart`. **Otherwise it builds a
  procedural fallback** — an `Egg_Procedural` model with one `Part`
  sized `Constants.EggSize`, the rarity's material and colour, a
  `PrimaryPart`, and a welded HRP. A missing template is a **silent**
  downgrade, not an error.

### `ModelBuilder.SlotTargetCFrame(slot: any, model: any?): CFrame`

The seated CFrame on a slot.

- **Failure modes:** does not throw. A thin forward to
  `HoverMath.GroundedCFrameOnSlot`.

---

## `ServerScriptService.Egg.Placement`

Server-only. Frozen at return.

### `Placement.IsFarFromAll(candidate: Vector2, existingBlocks: any, minSpacing: number): boolean`

Is the candidate far enough from every existing block?

- **Failure modes:** does not throw. `true` for an empty list. Blocks
  without a `centerCFrame` are **ignored**.

### `Placement.PickXZ(existingBlocks: any, radius: number, minSpacing: number): Vector2`

Picks a spawn XZ.

- **Failure modes:** does not throw. Three phases: up to
  `Security.Placement.MaxRandomAttempts` random ring retries, then a
  deterministic outward spiral in `minSpacing / 2` steps up to
  `2 x radius`, then a last-resort overlapping ring spot.

### `Placement.PickXZAt(existingBlocks: any, xz: Vector2?, radius: number, minSpacing: number): Vector2`

Picks a spawn XZ, preferring `xz` when it is far enough from all.

- **Failure modes:** does not throw.

---

## `ServerScriptService.Egg.Catalog`

Server-only. Frozen at return.

### `Catalog.Origin`

A frozen table: `{ Automatic = 'Automatic', Admin = 'Admin',
Persistence = 'Persistence', Test = 'Test' }`.

### `Catalog.ValidateDefinition(value: any): (boolean, string?)`

Validates a spawn definition.

- **Returns:** `(true, nil)` or `(false, '<message>')`.
- **Failure modes:** does not throw. The messages:
  `'definition must be a table'`, `'definition.rarity must be a
  string'`, `'definition.price must be a number'`, `'definition.price
  must be non-negative'`.

### `Catalog.ValidateOrigin(value: any): (boolean, string?)`

Validates a spawn origin.

- **Returns:** `(true, nil)` or `(false, '<message>')`.
- **Failure modes:** does not throw. The messages: `'origin must be a
  string'`, `'origin must be Automatic, Admin, Persistence, or Test'`.

---

## `ServerScriptService.Egg.Constants`

The re-exported tuning surface. Frozen at return.

| Field | Source |
|---|---|
| `Constants.State` | `EggType.State` (the five lifecycle states). |
| `Constants.ControllerType` | `{ Flight = 'Flight', AnimalFlight = 'AnimalFlight', Roll = 'Roll' }` — **deliberately no `Bob`**. |
| `Constants.HoverClearance` | `EggConfig.HoverClearance`. |
| `Constants.EggSize` | `EggConfig.EggSize`. |
| `Constants.Price` | `EggConfig.Price`. |
| `Constants.HatchRollWeights` | `EggConfig.HatchRollWeights`. |
| `Constants.CenterSpawnRarityWeights` | `EggConfig.CenterSpawnRarityWeights`. |
| `Constants.RarityMaterial` | `EggConfig.RarityMaterial`. |
| `Constants.EggTravelDuration` | `CenterSpawn.TravelDuration` — **legacy, unused**. |
| `Constants.EggTravelSpeed` | `EggConfig.PurchasedTravelSpeed`. |
| `Constants.EggTravelMinDuration` / `EggTravelMaxDuration` | `EggConfig.PurchasedTravel{Min,Max}Duration`. |
| `Constants.EggCenterMax` | `CenterSpawn.CenterMax`. |
| `Constants.EggMinSpawnSpacing` | `CenterSpawn.MinSpawnSpacing`. |
| `Constants.CenterSpawnRadius` | `CenterSpawn.Radius`. |
| `Constants.CenterSpawnInterval` | `CenterSpawn.Interval`. |
| `Constants.FlightAgentParams` | `MovementConfig.EggFlight`. |
| `Constants.FlightMaxTicks` | `MovementConfig.EggFlight.FlightMaxTicks`. |

---

## `ServerScriptService.Egg.GuaranteeService`

Server-only. Frozen at return.

### `GuaranteeService.PickDue(nowOverride: number?): string?`

The rarity whose guarantee is due.

- **Parameters:** `nowOverride` — optional, the timestamp to compare
  against (the test seam).
- **Returns:** the rarity id, or `nil`.
- **Failure modes:** does not throw. Returns the **first due entry in
  config order** — so **Legendary outranks Mythic** when both are due.
  A due guarantee persists until its rarity actually spawns.

### `GuaranteeService.NoteSpawned(rarity: string)`

Resets that rarity's clock.

- **Failure modes:** does not throw. Bumps `_revision` and pushes the
  UI attributes. An unknown or untracked rarity is **ignored**.

### `GuaranteeService.GetState(nowOverride: number?): { any }`

The guarantee rows.

- **Returns:** one row per guarantee:
  `{ Rarity, Interval, Remaining, NextAt, Due, Revision }`.
  `Remaining` is floored and **never negative**.
- **Failure modes:** does not throw.

### `GuaranteeService._pushAttributes()`

Writes `Guarantee_<Rarity>_NextAt` / `_Interval` / `_Revision` on the
Studio timer node.

- **Failure modes:** does not throw. A missing asset degrades to a
  one-shot warn.

### Test seams

- `GuaranteeService._TestReset()`
- `GuaranteeService._TestSetLastSpawn(rarity, at)`

---

## `ServerScriptService.Egg.RareEggNotifier`

Server-only. Frozen at return.

### `RareEggNotifier.ShouldNotify(rarity: any): boolean`

Is this rarity worth a server-wide toast?

- **Returns:** `true` for **Legendary, Mythic, Divine and Secret**
  only.
- **Failure modes:** does not throw. Garbage input -> `false`. Uses an
  **explicit enum set**, NOT an index into `RarityDefs.Order` — because
  `Order` puts Mythic below Legendary.

### `RareEggNotifier.Start()`

Subscribes to `EggSpawned`.

- **Failure modes:** does not throw. **Idempotent** — exactly one
  subscription. On a high-rarity spawn it fires
  `NotificationService.NotifySuccess(player, 'RareEgg_Spawned', { EggName = eggName })`
  for **every player in the server**.

---

## `ServerScriptService.Egg.EggSpawned`

The spawn event. Server-only. Frozen at return.

### `EggSpawned.Connect(fn: any): any?`

Subscribes to the event.

- **Returns:** the `RBXScriptConnection`, or `nil`.
- **Failure modes:** **pcall-wrapped** — never throws. A listener that
  throws is **disconnected, never retried**.

### `EggSpawned.Fire(info: any)`

Fires the event.

- **Parameters:** `info` — `{ uniqueId, rarity, origin }`.
- **Failure modes:** does not throw. Fires **exactly once per NEW
  egg**. A **persistence restore** and a **model rebuild** never fire
  it.

---

## `ServerScriptService.Egg.EggOverhead`

Server-only. Frozen at return.

### `EggOverhead.Refresh(egg: any): boolean`

Rebuilds the egg's overhead billboard.

- **Returns:** `true` if the overhead was refreshed, `false`
  otherwise.
- **Failure modes:** **total — it never throws.** It is **idempotent**.
  The template is
  `ServerStorage.Assets.OverheadGui.EggOverheadGuiTemplate`, falling
  back to `OverheadGuiTemplate` (one warn-once if neither exists). The
  anchor part is `CENTER` -> `PrimaryPart` -> the first descendant
  `BasePart`. The clone is named `'EggOverheadGui'` and parented
  **under the model** (so carry and place move it for free). It paints
  `Container.Content.Name` (the rarity display name, coloured by
  `RarityConfig.RarityColor[rarity]`), `.Price` (`'$' ..
  BigNumber.Format(tostring(price))`), `.Trait` (hidden when `nil` or
  `''`), and `.Mutations` (one clone of the template's own `Mutation1`
  prototype per mutation id, painted with
  `MutationIcon.PaintIcon(clone, id)`; stale clones hidden; the
  container hidden when empty).
