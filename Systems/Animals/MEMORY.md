# Animals — MEMORY

Engineering notes for a future agent. Dense on purpose. Everything here
was read out of the source, not assumed.

---

## 1. Purpose in one line

Own the server-side lifecycle of an owned animal: create it from an egg
(or restore it on rejoin), walk it to its slot, let the player carry and
place it, level it up, and render its live overhead — with **every**
gameplay number derived from `Level` rather than stored.

---

## 2. How it actually works, step by step

### 2.1 The registry

`AnimalService` keeps a module-local `animals: { [uniqueId]: any }`.
`AnimalService.Init()` creates `Workspace.Animals` (a `Folder`), runs the
one-shot asset audit, wires the weight provider, and installs the prompt
callbacks. `Init()` is idempotent and safe to call from
`CreateFromEgg` (which calls it defensively before parenting a clone).

The record is created in exactly two places: `CreateFromEgg` and
`SpawnFromPersistence`.

### 2.2 Creation — `CreateFromEgg(egg, rarity, predefId?, options?)`

Order of operations (the order matters):

1. `egg.slotId` must exist -> else `{ success = false, error = 'no-slot' }`.
2. Resolve `targetSlot` via `slotServiceRef._findSlotById(egg.slotId)` ->
   else `'slot-not-found'`.
3. Resolve the definition: `predefId` wins **only** if it is actually in
   `AnimalConfig.Catalog[rarity]`; otherwise `AnimalConfig.GetRandom(rarity)`.
   Empty/missing bucket -> `nil, nil` -> `'no-definition'` (and the egg is
   refunded).
4. **Resolve inheritance BEFORE model selection.** `TraitService.ResolveInheritance(egg.Trait, egg.Mutations, nil)`
   — unless `options.TraitResolved == true`, in which case the
   caller-resolved trait/mutations are reused **verbatim**. This is
   critical: `EggService.HatchEgg` pre-resolves the inheritance *before*
   the 5-second roulette so the template check validates the FINAL trait.
   A second roll here would pick a different trait than the one the
   roulette already validated, breaking the hatch after the roll for no
   reason. The template is trait-specific, so it must be chosen with the
   final trait.
5. `AnimalService.GetTemplate(rarity, defId, inheritance.Trait)` -> the
   template. Missing -> `'template-missing'` (egg refunded).
6. Mint the id: `OwnedObjectIdentity.GenerateUnique(OwnedObjectIdentity.Kind.Animal, animals)`
   -> `AN_` + a 10-char base-62 token. Collision-checked against the
   live registry; **throws** after 8 failed attempts.
7. `template:Clone()`, rename to `def.displayName` (the *visible* label in
   Explorer; the `uniqueId` stays the runtime identifier), parent to
   `Workspace.Animals`.
8. `_anchorAll(model)` + `_disableAllCollisions(model)`.
9. The model **must** have a `HumanoidRootPart`; it becomes the
   `PrimaryPart`. Missing -> the model is destroyed and the egg is
   refunded with `'template-no-humanoidrootpart'`.
10. Spawn CFrame precedence: `options.spawnCFrameOverride` (the exact
    CFrame the roulette revealed the winner at — **no** `+2` offset is
    added) -> `egg.model.PrimaryPart.CFrame + (0, 2, 0)` ->
    `targetSlot.part.CFrame + (0, 5, 0)`.
11. `_loadAnimations(model)` -> `{ walk, idle }` tracks.
12. The record is built: `Level = 1`, `XP = 0`, `Trait` / `Mutations`
    from the resolved inheritance, `state = 'Slotted'`,
    `originalSlotId = nil`, `_mutex = true`, `baseScale` captured from
    `model:GetScale()`.
13. `animals[uniqueId] = animal`.
14. `pcall(AnimalOverhead.EnsureForAnimal, animal)` — the overhead is
    created **now**, so it rides the model through the walk.
15. `playerServiceRef.ConsumeEggIntoAnimal(ownerUserId, egg.uniqueId, targetSlot.id, defId, uniqueId, { Trait, Mutations })`
    — the animal row is added **and** the egg row is consumed in the
    **same synchronous mutation**. Splitting them was the window that let
    a phantom egg record survive its own open and come back as a
    "converted" egg on rejoin.
16. `task.spawn(function() AnimalService._walkTo(animal, targetSlot) end)`.
17. Returns `{ success = true, animalId = uniqueId }`.

**The slot is NOT occupied here.** It stays `Reserved` during the walk;
`WalkController._onComplete` calls `OccupySlot` on arrival. Calling
`OccupySlot` twice would fail the second time with
`state = Occupied`.

### 2.3 The walk — `Animal/WalkController`

`WalkController.Start(animal, slot)` **throws (level 2)** if the animal
has no model, no `slotId`, or no `PrimaryPart`.

- `feetOffset = SlotMath.FeetOffsetBelowPrimary(model)` — a **negative**
  number (the HRP sits above the feet).
- `startCFrame = primary.CFrame`;
  `targetCFrame = SlotMath.StandingCFrameOnSlot(model, slot)`.
- The path start and end are the **FEET** positions
  (`+ Vector3.new(0, feetOffset, 0)`), not the HRP positions.
  `PathfindingService` returns waypoints at the agent's HRP Y; using the
  HRP Y for both ends would leave the feet `|feetOffset|` above the
  path's reported Y — floating.
- `PathfindingUtil.AgentParams` drives the agent. The path is computed
  **once**.
- **Fewer than 2 waypoints (or a failed path) -> teleport.** The model
  snaps to the target CFrame, is re-anchored, `OccupySlot` runs and
  `_onArrived` fires. A teleport is the only deterministic outcome; the
  alternative (hold and notify) hangs.
- Otherwise: segment lengths are pre-computed, and
  `duration = totalLength / WalkController.Speed`.
- Per `RunService.Heartbeat` tick: `t = (os.clock() - startedAt) / duration`,
  the arc-length cursor finds the segment at `totalLength * t`, XZ is
  the per-segment lerp, **Y is the same segment's lerp** (per-waypoint Y
  from the polyline — this is what makes the animal walk up stairs
  instead of floating in a straight line), and the yaw eases toward the
  segment direction with `1 - exp(-8 * dt)`.
- `_onComplete` calls `OccupySlot(slotId, uniqueId, SlotType.OccupantKind.Animal)`.
  **If `OccupySlot` returns false it logs a warning and returns without
  firing `_onArrived`** — the slot was not `Reserved` (an admin
  force-released mid-walk), so the animal is visually at the slot but
  the reconcile pass will fix it.

`WalkController.Stop(controller)` is idempotent: sets `stopped` and
`aborted`, disconnects the Heartbeat.

`WalkController.FacingOffset = 0`. The **egg** flight controller uses
`math.pi` (its templates are authored with the visual front on local
`+Z`).

### 2.4 The carry — `GrabAnimal` / `PlaceAnimal`

**`CanGrabAnimal(player, animalId)`** returns `nil` on success or an
error string. Checks, in order: live player -> animal exists -> owner ->
**not raid-locked** -> not already carried -> the player is not already
carrying something -> the animal has a `slotId` -> the slot exists ->
the slot is `Occupied` **and** its occupant is this animal -> the slot's
owner is the player -> the **distance check** (server-side; the
`ProximityPrompt`'s `MaxActivationDistance` is a client hint, not the
security boundary).

**`GrabAnimal`** runs the validation **before any mutation**, so a
rejection has nothing to roll back. Then:

1. `Validation.CanPlayerInteract(player)` — the death/reset lockout.
   Checked **here**, not in `CanGrabAnimal`, so the pure validator stays
   probeable.
2. `animal._mutex = true`.
3. `slotServiceRef.DemoteSlotToReserved(slot.id)` — `Occupied ->
   Reserved`. The slot is held for the player's return. A failure means
   a race -> `InvalidSlot`.
4. The record: `state = 'Carried'`, `carriedBy = player.UserId`,
   `originalSlotId = animal.slotId`, `slotId = nil`.
5. `CarryRegistry.Set(userId, { kind = Animal, record, originalSlotId, startedAt })`.
   On failure the demote is **rolled back** (re-occupy the slot, restore
   the record) and `AlreadyCarrying` is returned.
6. `CarryPrompts.RemovePromptsFromModel(animal.model)`; then
   `InstallPlacePromptsForBase(playerBase, userId, Animal)` on every
   eligible slot of the player's base (all `Empty` slots **plus** the
   source slot, which is now `Reserved` for them); then
   `DisablePickupHatchPromptsForBase(playerBase)` so the carrying player
   is not shown affordances that would be rejected.
7. `CarryController.Start(animal, userId, character, player)` — the
   head weld.
8. `playerServiceRef.PushState(...)`,
   `Remotes.FireClient(player, Remotes.Names.AnimalCarried, {...})`,
   `pcall(NotificationService.NotifySuccess, player, 'Pickup_Success', {...})`.
9. `pcall(TutorialSignals.Fire, 'AnimalPickedUp', {...})`.
10. `animal._mutex = false`.

**`CanPlaceAnimal(player, animalId, destSlotId)`**: live player ->
animal exists -> owner -> the animal **is** `Carried` **by this player**
-> the destination exists -> the destination's owner is the player ->
the destination is not `Occupied` -> a `Reserved` destination is only
allowed if it is `animal.originalSlotId` (the same-slot return path) ->
the destination is `Empty` or `Reserved` -> the distance check.

**`PlaceAnimal`** mirrors the same structure, then the steal check
(a steal-carried animal must be delivered to the thief's collector, so a
normal Place is rejected with `StealInProgress`).

### 2.5 The carry rig — `Animal/CarryController`

`CarryController.Start(animal, userId, character, player?)` **throws
(level 2)** on a missing model, a missing character, a character with no
`Head`, or a model with no `PrimaryPart`.

The rig is the Roblox "rigid accessory" pattern, applied in this exact
order (the order is load-bearing — see the header):

1. `Massless = true` — no mass contribution to the carrier's centre of
   mass.
2. `CanCollide = false` — no self-collision with the carrier's body.
3. `Anchored = false` — **required**; an anchored `PrimaryPart` refuses
   to follow a `Motor6D`.
4. `Humanoid.PlatformStand = true` — the animal's own Humanoid goes
   passive (no jumping/falling/getting-up). The Animator tracks still
   play.
5. `SetNetworkOwner(player)` — the carrying client simulates the
   assembly locally, so the solver produces no correction packets.
   **This must come after the unanchor**, because `SetNetworkOwner`
   rejects anchored parts.
6. **Then** the `Motor6D` is created last, parented to the `Head`,
   named `'CarryJoint'`, with `C0` placing the model
   `HeadClearanceStuds` (2.5) studs above the crown in head-local up.
   The physics engine never sees a partially-configured assembly.

The model is reparented to `Workspace.Animals.Carried_<userId>`.

`Stop(controller)` destroys the `CarryJoint` (guarded by `motor.Parent`
for the race where the engine already destroyed it), re-anchors the
model (which returns ownership to the server automatically — no
`SetNetworkOwner` call needed), sets `PlatformStand = false`, restores
`CanCollide = true`, and stops all animations. `Massless` **stays**
true (harmless for an anchored `PivotTo`).

### 2.6 Level-up — `AddXP(animalId, amount)`

The one canonical XP pipeline. Order:

1. Validate: `amount` must be a number (`'invalid-amount'`), an integer
   (`'fractional-amount'`), non-negative (`'negative-amount'`), and
   finite (`'invalid-amount'`). The amount is checked **before** the
   animal lookup, so `'invalid-amount'` wins over `'no-animal'`.
2. The animal must exist (`'no-animal'`) and not be `Consumed` or
   `Destroyed` (`'invalid-state'`).
3. **The XP modifier is resolved exactly once, here.** This is the ONE
   reader of the XP modifier in the codebase:
   `modifierServiceRef.GetXPModifier(ownerUserId)`. An unwired ref
   resolves to `1x`. `LevelConfig` never sees the modifier — it only
   drains thresholds.
4. `appliedXP = math.floor(requestedXP * xpModifier)`. A shaped value
   that is no longer a finite integer -> `'invalid-amount'` (a grant so
   large that `Normalize` would repair `inf` to 0 fails loudly instead
   of silently granting nothing).
5. `appliedXP == 0` -> a deterministic no-op success
   (`leveledUp = false`).
6. `LevelConfig.Normalize(level, current + appliedXP)` -> the new
   `(newLevel, newXP, levelsGained)`. `Normalize` drains **every**
   crossed threshold, preserves the overflow, repairs a malformed
   runtime pair defensively, and applies the MaxLevel bank cap. **One
   call — the loop is not duplicated here.**
7. The profile record is synced (`rec.Level`, `rec.XP`) so the existing
   ProfileService lifecycle saves both fields.
8. If `levelsGained > 0`: `pcall(LevelUpPresentation.NotifyLevelUp, ...)`,
   `pcall(AnimalOverhead.Refresh, ...)`, and
   `pcall(slotServiceRef.RefreshDisplays, slot.id)` — so a **silent** XP
   level-up (an arena reward, `/givexp`) does not leave stale cost text
   on the stand upgrade readout. All three are pcall-guarded: presentation
   can never break the XP mutation.

The result table carries `success`, `newXP`, `level`, `levelsGained`,
`leveledUp`, `atMaxLevel`, `requestedXP`, `xpModifier`, `appliedXP`.

**XP is CURRENT progress toward the next level, not lifetime XP.**
Level 1 with XP 90 and a requirement of 100, plus 50 XP, gives Level 2
with XP 40.

`ApplyLevelUpgrade(uniqueId)` is the **paid** path: `Level += 1`, XP
untouched. It can never be undone by `Normalize`, because thresholds
strictly increase with level. It syncs the profile and celebrates
exactly like an XP level-up. Errors: `'no-animal'`, `'invalid-state'`,
`'invalid-level'`.

### 2.7 The celebration — `Animal/LevelUpPresentation`

`NotifyLevelUp(animal, info)` where `info` is
`{ oldLevel, newLevel, levelsGained }`. It is wrapped in a `pcall`, so
it **never throws** and never yields the caller.

- The **per-animal generation counter** is bumped. A celebration already
  in flight is superseded: the old loop exits **without restoring**, and
  the new loop owns the restore to the **original** rest pivot (kept in
  `_rest`). Rapid multi-level grants therefore merge into one controlled
  celebration — the animal can never fly up permanently, stack tweens or
  end up offset.
- The `AnimalLeveledUp` remote fires to the **owner only**
  (`{ AnimalId, SlotId, OldLevel, NewLevel, LevelsGained }`), inside its
  own pcall — a missing `Remotes` folder must never break the server
  celebration.
- The celebration thread runs `_runCelebration`: the model grows toward
  the weight-derived scale, then does a procedural **bop**
  (anticipation squash -> launch stretch -> airborne tilt -> fall ->
  landing squash -> settle), the `ServerStorage.Assets.Vfx.Upgrade` effect
  bursts at the apex, and the model is restored to **exactly** the rest
  pivot and scale.

The bop phases come from `Config.Presentation.Vfx.Bop`:
`Anticipation 0.10`, `Launch 0.16`, `Apex 0.06`, `Fall 0.18`,
`Landing 0.08`, `Settle 0.10` -> **0.68 s** total.

`Model:ScaleTo()` accepts a **single uniform number** — per-axis model
scale is not supported, and faking it per-part would fight the `Motor6D`
rig. The squash & stretch read is built from uniform scale pulses plus
vertical motion and a micro-tilt.

**Positional work is skipped** if the animal is mid-walk, carried or
recovering (an active `animal.controller` or a non-`Slotted` state), so
the celebration never fights the `WalkController` or tears a carry weld.
`_TestIsDriving(animal)` is the seam that locks this: a **finished** walk
handle (`controller.stopped == true`) does **not** block the bop; an
**active** carry handle does.

**Server audio is gone.** `LevelUpPresentation.EnsureLevelUpSfx` and
`PlayLevelUpSfx` are `nil` — the personal sting plays on the owning
client, gated on a real level increase. The VFX clone's embedded sounds
are **destroyed unplayed** (they would be audible server-wide). The
clone's `Attachment` is re-homed under the model's `PrimaryPart`
(attachments only resolve under a `BasePart`). The source asset is
**never mutated** — only the clone is.

`Cancel(animalId)` bumps the generation (so a stale loop exits), and
clears `_rest` / `_restScale` / `_restGround`.

### 2.8 The overhead — `Animal/AnimalOverhead`

`Refresh(animal)` returns `true` if the overhead was refreshed. It is
**total** — it never throws (an internal `pcall` catches everything and
warns with an `[AnimalOverhead][Stats]` prefix plus the animal identity).

- The template is `ServerStorage.Assets.OverheadGui.OverheadGuiTemplate`
  (a `BillboardGui`), cached. Missing -> warn-once + skip.
- The anchor is a part named **`CENTER`** if present, else the model's
  `PrimaryPart`. Missing -> warn + skip.
- The clone is named `OverheadGui` and is parented **under the anchor**
  (so carry and place move it for free).
- Exactly **one** overhead per model, enforced by a hierarchy check, not
  by memory.
- A legacy clone named `OverheadTemplate` is **destroyed on sight** (the
  retired template must never coexist with the new GUI).
- The GUI **never touches** `PivotTo` / `ScaleTo` / grounding — position
  drift is impossible by construction.

The fields it paints: `Name` (from `record.displayName` — name only;
Level owns `'Lv. N'`), `Level` (`'Lv. N'`), `Income`
(`AnimalStats.Calculate(record, 'Income')` — the exact call
`IncomeService` ticks on, **including** the trait/mutation folds),
`Rarity` (from `AnimalConfig.Get(definitionId)`, with a record fallback),
`Trait` (hidden when `nil` or `''`), `Stats.Health.Value` /
`Stats.Damage.Value` (via `BigNumber.Format(tostring(math.floor(v)))`),
`Data.Damage` / `Data.Health` / `Data.MaxHealth` (the same snapshot
mirrored into `NumberValue`s), and `Mutations` (one clone of the
template's own `Mutation1` prototype per sanitised mutation id, painted
by `MutationIcon.PaintIcon`).

There is **no mutable combat HP pool** yet (arena combat is not
implemented), so `Data.Health` and `Data.MaxHealth` both carry the
canonical Health. A `record.CurrentHealth` **override** is honoured for
display only.

**The Rainbow trait animation is one shared server `Heartbeat` for every
Rainbow overhead** — never per-animal. `_TestRainbowCount()` counts the
live gradients **plus** the live strokes.

`SetStolen(animal, stolen)` shows `STOLEN` in
`OverheadConfig.StolenTextColor` with **only the name visible**; every
other `Content` GuiObject child is hidden. The **record is untouched** —
`record.displayName` is never rewritten. Restoring is
**per-child remembered visibility**, never a blind `Visible = true`, so a
Trait label that was hidden before the steal stays hidden.

### 2.9 Restore — `SpawnFromPersistence(userId, record, slot)`

- The rarity comes from `AnimalConfig.Get(record.DefId)`. Unknown ->
  the persisted record is **dropped**, the slot released, the owner
  notified, and `'defId-not-in-catalog'` is returned.
- The template is resolved with `record.Trait`. Missing -> the record is
  dropped and `'template-missing'` is returned.
- The id is **read from the record**, not minted. If the record's `Id`
  is not a valid `AN_` id, one is minted and **written back** so the
  next rejoin sees it.
- The model is seated **directly at the slot** — **no walk on rejoin**.
- Every part is anchored and collisions are disabled.

### 2.10 Cleanup

**`CleanupPlayer(userId)`** — on leave:

- A steal-carry is rolled back first (lazily requiring `StealService`).
- A carried animal is recovered (the carry registry is asked; the egg
  carry has its own path in `EggService.CleanupPlayer`).
- Every animal owned by the leaving user has its **model** destroyed
  and its registry entry dropped — but the **persisted record is
  preserved** (`RemoveAnimal` is NOT called here). On rejoin,
  `SpawnFromPersistence` re-spawns it. Without this sweep, a leaving
  player's models linger in `Workspace.Animals` and the next player
  assigned to that base sees ghost models with stale Pickup prompts.
- `Workspace.Animals.Carried_<userId>` is destroyed defensively.

**`ForceReleaseBase(baseId)`** — an admin wipe. This is the
**destructive** path: it removes the animal from the persisted data
(`RemoveAnimal`), wipes the prompts, destroys the model and drops the
registry entry. It handles **both** slotted and carried animals (the
original implementation only iterated `animal.slotId`, which misses
carried animals because `slotId` is `nil` while `Carried` — without the
fix, a wipe-while-carrying leaves an orphan record and an orphan model).
A **stolen** animal (`animal.stolenBy ~= nil`) is **skipped**: an admin
wipe must not destroy a live steal transaction.

---

## 3. The public API surface

### `ServerScriptService.AnimalService` (frozen)

| Function | Signature |
|---|---|
| `Init` | `() -> ()` |
| `SetPlayerService` | `(svc: any) -> ()` |
| `SetBaseService` | `(svc: any) -> ()` |
| `SetEggService` | `(svc: any) -> ()` |
| `SetSlotService` | `(svc: any) -> ()` |
| `SetModifierService` | `(svc: any) -> ()` |
| `IsArenaDeployed` | `(uniqueId: string) -> boolean` |
| `SetArenaDeployed` | `(uniqueId: string, deployed: boolean) -> boolean` |
| `GetPoolForRarity` | `(rarity: string) -> { [string]: any }?` |
| `ResolveTraitFolder` | `(trait: string?) -> string` |
| `GetTemplatePath` | `(trait: string?, rarity: string, defId: string?) -> string` |
| `ValidateTemplates` | `() -> { string }` |
| `ValidateStudioCoverage` | `() -> { string }` |
| `GetTemplate` | `(rarity: string, defId: string, trait: string?) -> Model?` |
| `ApplyGrowthScale` | `(animal: any) -> 'applied' \| 'unchanged' \| 'skipped'` |
| `CreateFromEgg` | `(egg, rarity, predefId?, options?) -> any` |
| `SpawnFromPersistence` | `(userId: number, record: any, slot: any) -> any` |
| `Get` | `(uniqueId: string) -> any?` |
| `GetStandAnimal` | `(stand: Instance?) -> any?` |
| `ValidateStandPlacement` | `(slot: any) -> boolean` |
| `ListForPlayer` | `(userId: number) -> { any }` |
| `CanGrabAnimal` | `(player: Player, animalId: string) -> string?` |
| `CanPlaceAnimal` | `(player: Player, animalId: string, destSlotId: string) -> string?` |
| `GrabAnimal` | `(player: Player, animalId: string) -> string?` |
| `PlaceAnimal` | `(player: Player, animalId: string, destSlotId: string) -> string?` |
| `GetCarriedAnimal` | `(player: Player) -> any?` |
| `IsCarryingAnimal` | `(player: Player) -> boolean` |
| `GetCarriedAnimalByUserId` | `(userId: number) -> any?` |
| `IsAnimalOwnedByPlayer` | `(animalId: string, player: Player) -> boolean` |
| `IsSlotOwnedByPlayer` | `(slotId: string, player: Player) -> boolean` |
| `RecoverCarriedAnimal` | `(playerOrUserId: any, reason: string) -> ()` |
| `SettleModelAtSlot` | `(animal: any, slot: any) -> ()` |
| `ForceReleaseBase` | `(baseId: string) -> ()` |
| `CleanupPlayer` | `(userId: number) -> ()` |
| `GetXP` | `(animalId: string) -> number?` (method: `:`) |
| `GetLevel` | `(animalId: string) -> number?` (method: `:`) |
| `GetStats` | `(animalId: string) -> any?` (method: `:`) |
| `AddXP` | `(animalId: string, amount: number) -> any` (method: `:`) |
| `GetAll` | `() -> { any }` |
| `DestroyRuntimeAnimal` | `(uniqueId: string) -> boolean` |
| `ApplyLevelUpgrade` | `(uniqueId: string) -> any` |
| `_TestRegister` | `(record: any) -> boolean` |
| `_TestUnregister` | `(uniqueId: string) -> ()` |
| `_TestArenaParkedCount` | `() -> number` |
| `_TestResetArenaDeployment` | `() -> ()` |
| `Error` | A table of 15 stable reason strings. |

**The `:` vs `.` distinction is real.** `GetXP`, `GetLevel` and
`AddXP` are declared with `:` — they are called as
`AnimalService:GetXP(id)`. Everything else, **including `GetStats`**,
is `.`.

### `ServerScriptService.Animal.AnimalOverhead`

`Refresh(animal) -> boolean`, `EnsureForAnimal(animal) -> boolean`,
`RemoveForAnimal(animal) -> ()`, `SetStolen(animal, stolen) -> boolean`,
`_TestFind(animal) -> Instance?`, `_TestIsStolen(uniqueId) -> boolean`,
`_TestReset() -> ()`, `_TestRainbowCount() -> number`.

### `ServerScriptService.Animal.CarryController`

`Start(animal, userId, character, player?) -> any`,
`Stop(controller) -> ()`, `IsRunning(controller) -> boolean`.
Module fields: `HeadClearanceStuds` (2.5).

### `ServerScriptService.Animal.CarryPrompts`

`SetGrabPromptCallback(cb)`, `SetEggGrabPromptCallback(cb)`,
`SetPlacePromptCallback(cb)`, `SetHatchPromptCallback(cb)`,
`GetHatchPromptCallback() -> cb?`, `SetStealPromptCallback(cb)`,
`SetSellPromptCallback(cb)`, `GetSellPromptCallback() -> cb?`,
`RemovePromptsFromModel(model)`,
`InstallPickupPrompt(model, occupantId, kind, slot?, ownerUserId?)`,
`InstallHatchPrompt(egg, slot?, ownerUserId?)`,
`InstallStealPrompt(model?, occupantId?, kind?, ownerUserId?)`,
`RemoveStealPromptFromModel(model?)`,
`InstallSellPrompt(model?, occupantId?, ownerUserId?)`,
`InstallPlacePromptOnSlot(slot, playerId?)`,
`InstallPlacePromptsForBase(base, playerId?, carriedKind?)`,
`RemovePlacePromptsForBase(base)`,
`DisablePickupHatchPromptsForBase(base)`,
`EnablePickupHatchPromptsForBase(base)`,
`InstallGrabPrompt(slotPart?, occupantId?)`,
`RemoveAllHatchPrompts(folder?)`, `RemoveAllGrabPrompts(base)`,
`RemoveAllPromptsFromBase(base)`, `RemoveAllPromptsFromSlot(slotPart?)`,
plus the internal `_RegisterPickupPrompt`, `_RegisterHatchPrompt`,
`_UnregisterPromptsForSlot`, `ForgetSlotsForBase`.

### `ServerScriptService.Animal.LevelUpPresentation`

`SetWeightProvider(fn)`, `PlayUpgradeVfx(model)`,
`NotifyLevelUp(animal, info)`, `Cancel(animalId)`,
`_TestGeneration(animalId) -> number`, `_TestIsDriving(animal) -> boolean`.

### `ServerScriptService.Animal.WalkController`

`Start(animal, slot) -> any`, `Stop(controller)`,
`IsRunning(controller) -> boolean`, `_teleportAndArrive(...)`,
`_onComplete(controller)`.
Module fields: `Speed` (10), `AnimationBaseSpeed`, `YawSmoothing`,
`WallClockPadding`, `FacingOffset` (**0**).

### `ReplicatedStorage.Config.Creatures.Animals`

`Catalog`, `Stats.Health/Damage/Income`, `WeightByRarity`,
`WeightByDefinition`, `SellBaseValue`, `SellMultiplier`,
`RarityMultipliers` (retired), `MovementSpeed`, `BaseHealth`,
`BaseDamage`, `DefaultLevel`, `Carry`, `BaseLevel`,
`GetRandom(rarity, rng?) -> (string?, any?)`,
`Get(definitionId) -> (string?, any?)`,
`GetHealth(rarity, baseHealth) -> number` (retired),
`GetDamage(rarity, baseDamage) -> number` (retired).

### `ReplicatedStorage.Utility.AnimalStats`

`GetStatConfig(rarity, statName) -> any?`,
`Calculate(animal, statName) -> number`,
`Snapshot(animal) -> { Health, Damage }`.

### `ReplicatedStorage.Utility.AnimalWeight`

`GetRange(definitionId) -> { Base, Maximum }?`,
`CalculateWeight(definitionId, level) -> number?`,
`GrowthAlpha(definitionId, level) -> number?`,
`GetGrowthMultiplier(definitionId, level) -> number?`,
`GetTargetScale(animal) -> number?`.
Module fields: `MaxGrowthScale` (1.30), `Curve` (100).

---

## 4. Invariants and rules the code enforces

1. **Damage == Health / 10, bit-exact.** Enforced in `AnimalStats` (a
   single short-circuit) *and* at require time in
   `Animals.validateStats()` (over `Base`, `Maximum` and `Curve`).
2. **Level 1 == `Base` exactly; MaxLevel == `Maximum` exactly.** Both
   are fast paths, so the boundary values are immune to float dust.
   Intermediate levels stay strictly inside `(Base, Maximum)`.
3. **Stats are derived, never stored.** No `Health` field on the record
   or in the profile.
4. **Income is the only stat the trait/mutation folds touch.** Health
   and Damage are pure level scaling. The player `MoneyMultiplier` stays
   **outside** — `IncomeService` applies it at the tick.
5. **The id is the persistence key.** It is minted once, collision-
   checked, and read back on rejoin. `AN_` and `EG_` never collide.
6. **The slot is `Reserved` during the walk and `Occupied` after.**
   `OccupySlot` is called exactly once, in `_onComplete`.
7. **The source slot is `Reserved` for the carrier.** A same-slot return
   is `Reserved -> Occupied`; a different-slot return is
   `Reserved -> Empty` plus a fresh `Empty -> Reserved -> Occupied`.
8. **A `Carried` animal has `slotId == nil`** and keeps
   `originalSlotId` as the recovery hint.
9. **The trait is rolled exactly once per hatch.** Either the caller
   pre-resolved it (`options.TraitResolved`) or `CreateFromEgg` rolls it
   — never both.
10. **The trait folder is `Normal` for `nil`, `''` and unknown traits.**
    Never the string `'None'`.
11. **`AddXP` applies the modifier exactly once**, at the single entry
    point. `LevelConfig` never sees it.
12. **The level-up celebration never breaks the level-up.** Every
    presentation call is pcall-guarded.
13. **The generation counter, not the celebration count, is what
    `Cancel` bumps.** `Cancel` bumps it to orphan the in-flight loop.
14. **The overhead never touches transforms.**
15. **The carried model has no prompt.** The Place prompt lives on the
    slot part.

---

## 5. Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `egg.slotId` missing | `CreateFromEgg` -> `'no-slot'` |
| The slot cannot be resolved | `'slot-not-found'` |
| The rarity bucket is empty | `'no-definition'`, **the egg is refunded** |
| The template is missing | `'template-missing'`, **the egg is refunded** |
| The model has no `HumanoidRootPart` | `'template-no-humanoidrootpart'`, the model is destroyed, **the egg is refunded** |
| The persisted `DefId` is not in the catalog | `'defId-not-in-catalog'`, the record is dropped, the slot released, the owner notified |
| The persisted `Id` is not a valid `AN_` id | A new one is minted and **written back** to the record |
| The pathfinder fails or the path is degenerate | **Teleport** to the slot; `OccupySlot` + `_onArrived` run |
| `OccupySlot` returns false at arrival | Warn + return; `_onArrived` does **not** fire |
| The player's character is missing / dead | `TooFar` (no character / no HRP) or `PlayerNotLive` |
| The player is already carrying something | `PlayerAlreadyCarrying` |
| The animal is in an active arena raid | `RaidLocked` |
| The animal is a steal in progress | `StealInProgress` (on place) |
| `CarryRegistry.Set` fails during a grab | The demote is rolled back; `AlreadyCarrying` |
| The player disconnects while carrying | `RecoverCarriedAnimal` returns it to the original slot, or to the first empty slot, or parks it in `Workspace.Animals.Recovering` in state `Recovering` |
| The original slot is gone (base released) | The animal falls back to the first empty slot in the player's **current** base |
| No empty slot anywhere | `state = 'Recovering'`, the model is parked under `Workspace.Animals.Recovering` and **is not destroyed** — it waits |
| `AddXP` with a fractional / negative / infinite amount | `'fractional-amount'` / `'negative-amount'` / `'invalid-amount'` |
| `AddXP` with `amount == 0` | A deterministic no-op success (`leveledUp = false`) |
| `AddXP` on a `Consumed` / `Destroyed` animal | `'invalid-state'` |
| `AddXP` on an unknown id | `'no-animal'` |
| `ApplyLevelUpgrade` at MaxLevel | `'invalid-level'` |
| A malformed `Level` on the record | Repaired through `LevelConfig.Normalize` -> the Level-1 `Base` |
| `Level > MaxLevel` | Clamped to the `Maximum` stat, never NaN |
| An unknown `DefId` in `AnimalStats` | Warn-once, **0** — never NaN, never negative, never a throw |
| An unsupported `statName` | **Throws** (a programming error) |
| A non-table `animal` in `AnimalStats` | **Throws** (a programming error) |
| `GetTemplate` finds nothing | `nil` — never a broken animal |
| The `ServerStorage.Animals` tree is absent | The validators return `{}` (silent); per-spawn warns still fire |
| A trait variant is missing | Falls back to `Normal` with a warning |
| The VFX asset is missing | The celebration still plays, without VFX |
| The overhead template is missing | Warn-once + skip; `Refresh` returns `false` |
| The overhead anchor is missing | Warn + skip; `Refresh` returns `false` |
| `SetStolen` on a record with no model | `false` (the "steal on" call), `true` (the "un-steal" call) |

**The rule of the codebase:** the *service* layer never throws for data
problems — it returns an error string. The *pure math* layer
(`AnimalStats`) throws only for programming errors (an unsupported
`statName`, a non-table animal). The *controllers* throw (level 2) for
programming errors (a missing model, character, Head or PrimaryPart).

---

## 6. Gotchas that would bite you

- **`AnimalService:GetXP` uses a colon.** Four methods do
  (`GetXP`, `GetLevel`, `GetStats`, `AddXP`). Calling
  `AnimalService.GetXP(id)` passes `id` as `self` and silently breaks.
- **`GetTemplate`'s argument order is `(rarity, defId, trait?)`** —
  **rarity first**. Most other catalog lookups in the codebase take the
  id first.
- **`GetRandom` returns `(id, def)`**, and it **sorts** the ids before
  picking, so the result is deterministic for a seeded rng.
- **`Animals.Get(defId)` is a linear `pairs` scan** over the whole
  catalog and returns `(rarity, def)`. It is called on every
  `AnimalStats.Calculate`, which is called on every overhead refresh.
  With 26 entries this is fine; with 1000 it will not be.
- **`AnimalStats.Snapshot` only returns `Health` and `Damage`** — there
  is no `Income` in the snapshot. `Income` is computed separately by
  `IncomeService`.
- **`AnimalStats.Calculate` for `Income` multiplies by the trait and
  mutation generation folds.** A record with `Trait = 'Rainbow'` gets
  10x Income. A spec that asserts "Income at Level 1 == config Base
  exactly" only holds for a trait-less, mutation-less record.
- **`Stats.Income` uses `Curve = 80`**, not `100`.
- **`Animals.Carry` is a re-export.** Mutating it at runtime does
  nothing — `CarryPrompts` reads `Prompts.CarryMaxDistance` directly.
- **`Prompts.Carry.PerKind[SlotType.OccupantKind.Animal]`** is the live
  source of the four prompt-text strings; `Animals.Carry` just mirrors
  them.
- **`ApplyGrowthScale` returns a string**, not a boolean:
  `'applied'`, `'unchanged'` or `'skipped'`. `skipped` covers a missing
  model, an unparented model, an unreadable scale and an unresolvable
  target.
- **`ApplyGrowthScale` must be called with the model already at the
  slot.** It re-derives the ground plane from
  `SlotMath.FeetOffsetBelowPrimary` and does a `ScaleTo` + `PivotTo`
  pair, so calling it mid-walk will fight the walk controller.
- **`WalkController.Start` throws.** `AnimalService._walkTo` is what
  calls it, inside a `task.spawn` — a throw there is logged, not
  propagated.
- **`WalkController._onComplete` does NOT fire `_onArrived` when
  `OccupySlot` fails.** If you are chasing "the animal is at the slot
  but the state never updated", this is the reason.
- **`ForceReleaseBase` is destructive; `CleanupPlayer` is not.** They
  look similar but do opposite things to the profile.
- **`ForceReleaseBase` skips stolen animals.** Do not "fix" that.
- **`CleanupPlayer` does not call `RemoveAnimal`.** The persisted record
  must survive so the rejoin can re-spawn it.
- **`CarryPrompts.InstallPickupPrompt` wipes ALL prompts on the
  model's PrimaryPart** before installing. The Hatch installer only
  wipes a pre-existing Hatch prompt. The order is
  **Pickup first, then Open**.
- **The `ownerUserId` attribute is set unconditionally on the prompt**
  (even when `nil`) so the client-side `PromptOwnerFilter` can tell
  "no owner" from "attribute missing".
- **`AnimalOverhead.Refresh` is idempotent** and can be called on every
  authoritative transition.
- **`LevelUpPresentation.SetWeightProvider` accepts `nil`** to clear
  it; a non-function value must not throw.
- **`LevelUpPresentation.Cancel` bumps the generation**, so a
  generation count of 2 after one celebration + one cancel is
  expected. Do not read the generation as a celebration count.
- **`OwnedObjectIdentity.GenerateUnique` throws** after 8 collision
  attempts. It is the only id mint you should use.
- **`WalkController.lua` says `# NEED TO REMOVE THIS FILE IN FUTURE`** in
  its first line. The file is live. Do not delete it on the strength of
  that comment.
- **There is no `TweenService` and no `BodyMover` anywhere.** If you
  reach for them, you are fighting the architecture.

---

## 7. What to change to reuse it

1. **The catalog** (`Config/Creatures/Animals.lua`) — replace it
   wholesale. Keep the shape: `Catalog[rarity][defId] = { displayName,
   baseHealth, baseDamage }`, `Stats.<stat>[rarity] = { Base, Maximum,
   Curve }`, `WeightByRarity[rarity] = { Base, Maximum }`.
2. **The Studio tree** — author
   `ServerStorage.Animals/<Trait>/<Rarity>/<DefId>` where `<DefId>` **is**
   the species `Model`. Every species needs a `Normal` variant.
3. **The trait folder names** — if your traits are named differently,
   change `ResolveTraitFolder` (the **one** place) and author the
   folders to match. `nil` and `''` must both map to `'Normal'`.
4. **The rarity set** — if you add or remove a rarity, update
   `Stats`, `WeightByRarity`, `SellBaseValue`, `SellMultiplier` and the
   `Catalog` buckets together. `validateStats()` and `validateWeight()`
   will catch a partial edit at require time.
5. **The progression config** — `Config/Creatures/Progression.lua`
   belongs to the Upgrades system, but this system reads it. Change it
   there, not here.
6. **The prompts** — `Config/World/Prompts.lua` belongs to the Carry
   system. `Animals.Carry` is a mirror, not an input.
7. **The overhead template** — author
   `ServerStorage.Assets.OverheadGui.OverheadGuiTemplate` with a
   `Container.Content` hierarchy containing `Name`, `Level`, `Income`,
   `Rarity`, `Trait`, `Stats.{Health,Damage}.Value`, `Mutations` (with a
   `Mutation1` prototype inside) and a `Data` folder with `NumberValue`s
   `Damage`, `Health`, `MaxHealth`.
8. **The upgrade VFX** — author
   `ServerStorage.Assets.Vfx.Upgrade` (an `Attachment` with a
   `ParticleEmitter`, plus optionally a `Sound` which will be **destroyed
   unplayed**).
9. **The wire format** — if you change the remotes, update
   `Remotes.Names` and the client. `AnimalCarried` and
   `AnimalLeveledUp` are the two this system fires.
10. **The service injection** — keep the `Set*Service` pattern. It is
    what keeps the dependency graph acyclic (`AnimalService` needs
    `EggService`, `EggService` needs `AnimalService`, and
    `SlotService`/`BaseService` need both).
11. **Do not port** the retired `RarityMultipliers`, `GetHealth`,
    `GetDamage`, `CarryOffset` or `YawSmoothing`.
12. **Do not port** `AnimalXP.spec.lua` as a test — it is not a test.
