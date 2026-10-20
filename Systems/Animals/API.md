# Animals — API

Every public function of every module in this system. See
[README.md](README.md) for the overview and [Dependencies.md](Dependencies.md)
for where each module comes from.

---

## Failure-mode policy (read this first)

The system uses **three different error conventions**, and mixing them up
is the most common way to misuse it:

| Layer | Convention |
|---|---|
| **`AnimalService` (the service layer)** | Returns a **string** error code, or `nil` on success. **It does not throw** for any data problem. |
| **`AnimalService:AddXP` / `ApplyLevelUpgrade`** | Returns a **table** `{ success = true, ... }` or `{ success = false, error = '<code>' }`. Never throws. |
| **`AnimalStats` / `AnimalWeight` (the pure math layer)** | **Throws** (`error(...)`) for programming errors only — a bad `statName`, a non-table animal. Returns `0` / `nil` for *data* problems (an unknown `DefId`, an unresolvable level). |
| **`WalkController.Start` / `CarryController.Start` (the controllers)** | **`error(..., 2)`** — level 2, so the traceback points at the caller. These throw for missing models / characters / parts. |
| **`OwnedObjectIdentity.Generate`** | **`assert(...)`** for an invalid kind. `GenerateUnique` **errors** after 8 collision retries. |

**A caveat on `Validation`:** several `AnimalService` entry points call
`Validation.ShortString(...)` / `Validation.PositiveInteger(...)`, which
**assert** on a malformed argument. That is a programming-error path, not
a data path.

---

# `ServerScriptService/AnimalService.lua`

The façade. Everything gameplay-facing goes through here.

## `AnimalService.Error`

A table of **15 stable string constants**. Compare against these, never
against a literal.

```lua
AnimalService.Error = {
    InvalidPlayer        = 'InvalidPlayer',
    AnimalNotFound       = 'AnimalNotFound',
    NotOwner             = 'NotOwner',
    NotSlotted           = 'NotSlotted',
    AlreadyCarried       = 'AlreadyCarried',
    PlayerAlreadyCarrying = 'PlayerAlreadyCarrying',
    InvalidSlot          = 'InvalidSlot',
    InvalidDestination   = 'InvalidDestination',
    SlotOccupied         = 'SlotOccupied',
    SlotReserved         = 'SlotReserved',
    TooFar               = 'TooFar',
    NotCarried           = 'NotCarried',
    RaidLocked           = 'RaidLocked',
    StealInProgress      = 'StealInProgress',
    PlayerNotLive        = 'PlayerNotLive',
}
```

(The source is the authority on the exact set — the 15 shown above are
the ones present in `AnimalService.Error`.)

## Lifecycle

### `AnimalService.Init()`
- **Kind:** lifecycle
- **Description:** Creates `Workspace.Animals`, runs the one-shot asset
  audit, installs the weight provider, and wires the **Pickup** and
  **Place** prompt callbacks.
- **Parameters:** none
- **Returns:** nothing
- **Failure modes:** **Does not throw** for a missing template or a
  missing service — it degrades. `Init()` is **idempotent**; calling it
  twice is safe.
- **Gotcha:** all five `Set*Service` calls must come **before** `Init()`.
  The prompt callbacks route through `SlotActionHandler`, which needs
  its peers wired.

### `AnimalService.SetPlayerService(svc: any)`
### `AnimalService.SetBaseService(svc: any)`
### `AnimalService.SetEggService(svc: any)`
### `AnimalService.SetSlotService(svc: any)`
### `AnimalService.SetModifierService(svc: any)`
- **Kind:** dependency injection
- **Description:** Inject a peer service. The service-injection pattern
  keeps the dependency graph acyclic.
- **Parameters:** `svc` — the peer module
- **Returns:** nothing
- **Failure modes:** never throws. An unwired ref degrades safely:
  `ModifierService` -> 1x XP; `SlotService` -> the slot cannot be
  resolved -> `'slot-not-found'`.
- **Gotcha:** `ModifierService` is optional; everything else is required
  for the full feature set.

## Templates and the catalog

### `AnimalService.GetPoolForRarity(rarity: string): { [string]: any }?`
- **Description:** The catalog bucket for a rarity — `{ [DefId] = definition }`.
- **Parameters:** `rarity` — a rarity id
- **Returns:** the bucket table, or `nil` for a rarity that is not in
  the catalog at all
- **Failure modes:** returns `nil`; does not throw.
- **Gotcha:** `Uncommon` and `Secret` **are in the catalog but are
  empty** (`{}`), so this returns an **empty table**, not `nil`, for
  them. Use `next(pool)` to test for emptiness.

### `AnimalService.ResolveTraitFolder(trait: string?): string`
- **Description:** Maps a trait id to its `ServerStorage.Animals` folder
  name.
- **Parameters:** `trait` — a trait id, or `nil`
- **Returns:** a folder name string (`'Normal'` for `nil` / `''`)
- **Failure modes:** never throws. `nil` and `''` both mean `Normal`.

### `AnimalService.GetTemplatePath(trait: string?, rarity: string, defId: string?): string`
- **Description:** The canonical `ServerStorage.Animals.<Trait>.<Rarity>.<DefId>` path string.
- **Parameters:** `trait`, `rarity`, `defId`
- **Returns:** the dotted path string
- **Failure modes:** never throws.

### `AnimalService.GetTemplate(rarity: string, defId: string, trait: string?): Model?`
- **Description:** Resolves the species model for a rarity + defId +
  trait, falling back from the trait folder to the `Normal` folder.
- **Parameters:** `rarity`, `defId`, `trait` (optional)
- **Returns:** the `Model`, or `nil`
- **Failure modes:** returns `nil`; does not throw.
- **Gotcha:** **the argument order is `(rarity, defId, trait?)`**, not
  `(defId, rarity, ...)`. A missing `Normal` variant breaks **all**
  spawns of that species; a missing *trait* variant degrades to
  `Normal` with a warning.
- **Gotcha:** the legacy flat shape
  `ServerStorage.Animals.<Rarity>.<DefId>` is also supported.

### `AnimalService.ValidateTemplates(): { string }`
- **Description:** Audits the `ServerStorage.Animals` tree and returns
  a list of human-readable problem strings.
- **Parameters:** none
- **Returns:** an array of issue strings (empty = healthy)
- **Failure modes:** never throws. A missing model is a **WARN**, not a
  throw.

### `AnimalService.ValidateStudioCoverage(): { string }`
- **Description:** Cross-checks the catalog against the Studio tree and
  reports catalog species with no model (and models with no catalog
  entry).
- **Parameters:** none
- **Returns:** an array of issue strings
- **Failure modes:** never throws.

## Spawning

### `AnimalService.CreateFromEgg(egg, rarity, predefId, options): any`
- **Description:** The full hatch path — resolves the trait (or honours
  the pre-resolved one), mints an id, clones the template, registers
  the record, and **spawns the walk to the target slot asynchronously**.
- **Parameters:**
  - `egg` — the egg runtime record (table)
  - `rarity` — the rolled rarity id
  - `predefId` — a forced defId, or `nil` to roll
  - `options` — optional table:
    - `spawnCFrameOverride: CFrame?`
    - `Trait: string?`, `Mutations: { string }?`
    - `TraitResolved: boolean?`, `ResolvedTrait: string?`,
      `ResolvedMutations: { string }?`
- **Returns:** `{ success = true, animalId = <string> }` on success, or
  `{ success = false, error = '<code>' }`
- **Failure modes (error codes):** `'no-slot'`, `'slot-not-found'`,
  `'no-definition'`, `'template-missing'`,
  `'template-no-humanoidrootpart'`. **Does not throw.**
- **Gotcha:** the walk is `task.spawn`ed — the function returns
  **before** the animal has arrived. The `AnimalArrived` remote fires
  later.

### `AnimalService.SpawnFromPersistence(userId: number, record: any, slot: any): any`
- **Description:** Re-spawns a persisted animal on rejoin. Mints and
  writes back an id if the stored one is missing or invalid.
- **Parameters:** `userId`, `record` (a `profile.Data.Brainrots` row), `slot`
- **Returns:** the runtime record, or `nil` on failure
- **Failure modes (error codes):** `'defId-not-in-catalog'`,
  `'template-missing'`, `'template-no-humanoidrootpart'`. Does not
  throw.
- **Gotcha:** the restore path places the model **directly** and
  **never fires `AnimalArrived`**.

## Reading

### `AnimalService.Get(uniqueId: string): any?`
- **Description:** The runtime record for an id.
- **Returns:** the record table, or `nil`
- **Failure modes:** returns `nil`; does not throw.

### `AnimalService.GetStandAnimal(stand: Instance?): any?`
- **Description:** The animal seated at a given stand part.
- **Returns:** the record, or `nil`
- **Failure modes:** returns `nil`; does not throw.

### `AnimalService.ValidateStandPlacement(slot: any): boolean`
- **Description:** Whether an animal can be seated at a slot (the slot
  is free, the stand exists, the distances are sane).
- **Returns:** `true` / `false`. Does not throw.

### `AnimalService.ListForPlayer(userId: number): { any }`
- **Description:** Every live runtime record owned by a user.
- **Returns:** a fresh array of record references
- **Failure modes:** never throws; an unknown user returns an empty
  array.

### `AnimalService.GetAll(): { any }`
- **Description:** Every live runtime record. `DebugService` iterates
  this (never a Workspace scan).
- **Returns:** a fresh array of record references
- **Failure modes:** never throws.

### `AnimalService.GetStats(animalId: string): any?`
- **Description:** The derived stat snapshot.
- **Returns:** `{ Health = number, Damage = number }`, or `nil` if the
  animal is unknown
- **Failure modes:** returns `nil`; does not throw.
- **Gotcha:** `Snapshot` returns **only** Health and Damage — not
  Income, Weight or Scale.

### `AnimalService:GetXP(animalId: string): number?`
- **Description:** The animal's **current** XP progress toward the next
  level (not lifetime XP).
- **Returns:** the XP number, or `nil` if the animal is unknown
- **Failure modes:** returns `nil`; does not throw.
- **Gotcha:** declared with a **colon**, so it must be called as
  `AnimalService:GetXP(id)`, not `AnimalService.GetXP(id)`.

### `AnimalService:GetLevel(animalId: string): number?`
- **Description:** The animal's level.
- **Returns:** the level number, or `nil`
- **Failure modes:** returns `nil`; does not throw.
- **Gotcha:** also declared with a **colon**.

## Carrying and placement

### `AnimalService.CanGrabAnimal(player: Player, animalId: string): string?`
- **Description:** Pure validation of a grab — **does not commit**.
- **Parameters:** `player`, `animalId`
- **Returns:** `nil` if the grab is allowed, else an `AnimalService.Error`
  string
- **Failure modes:** never throws; returns the error code.
- **Gotcha:** the same validation is **inlined** in `GrabAnimal`; this
  entry point exists so tests and admin commands can probe without
  committing.

### `AnimalService.CanPlaceAnimal(player: Player, animalId: string, destSlotId: string): string?`
- **Description:** Pure validation of a place — does not commit.
- **Returns:** `nil` if allowed, else an `AnimalService.Error` string
- **Failure modes:** never throws.

### `AnimalService.GrabAnimal(player: Player, animalId: string): string?`
- **Description:** The atomic grab. Validates, commits, and fires
  `AnimalCarried`.
- **Parameters:** `player`, `animalId`
- **Returns:** `nil` on success, else an `AnimalService.Error` string
- **Failure modes:** never throws for a data problem. Possible error
  codes: `InvalidPlayer`, `AnimalNotFound`, `NotOwner`, `NotSlotted`,
  `AlreadyCarried`, `PlayerAlreadyCarrying`, `TooFar`, `RaidLocked`,
  `StealInProgress`, `PlayerNotLive`.
- **Gotcha:** the animal is `pcall`-guarded against the tutorial
  signal — a tutorial failure never breaks the grab.
- **Gotcha:** the source slot stays **`Reserved`** after a grab (the
  carry-reservation invariant).

### `AnimalService.PlaceAnimal(player: Player, animalId: string, destSlotId: string): string?`
- **Description:** The atomic place. Validates, commits, and fires
  `AnimalPlaced`.
- **Parameters:** `player`, `animalId`, `destSlotId`
- **Returns:** `nil` on success, else an `AnimalService.Error` string
- **Failure modes:** never throws. Possible error codes:
  `InvalidPlayer`, `AnimalNotFound`, `NotCarried`, `InvalidSlot`,
  `InvalidDestination`, `SlotOccupied`, `SlotReserved`, `TooFar`,
  `RaidLocked`, `StealInProgress`, `PlayerNotLive`.
- **Gotcha:** a `StealInProgress` animal must be delivered to the
  thief's collector by `StealService` — a normal place is rejected.

### `AnimalService.GetCarriedAnimal(player: Player): any?`
- **Description:** The animal the player is carrying.
- **Returns:** the record, or `nil`
- **Failure modes:** returns `nil`; does not throw.

### `AnimalService.GetCarriedAnimalByUserId(userId: number): any?`
- **Description:** The same, by user id (no `Player` instance needed).
- **Returns:** the record, or `nil`

### `AnimalService.IsCarryingAnimal(player: Player): boolean`
- **Description:** Whether the player is carrying anything.
- **Returns:** `true` / `false`. Does not throw.

### `AnimalService.IsAnimalOwnedByPlayer(animalId: string, player: Player): boolean`
- **Description:** Ownership check.
- **Returns:** `true` / `false`. Does not throw.

### `AnimalService.IsSlotOwnedByPlayer(slotId: string, player: Player): boolean`
- **Description:** Whether the slot belongs to the player's base.
- **Returns:** `true` / `false`. Does not throw.

### `AnimalService.RecoverCarriedAnimal(playerOrUserId: any, reason: string)`
- **Description:** Server-side recovery — returns a carried animal to
  its origin slot. Used on death, on a reset, and on a disconnect.
- **Parameters:** `playerOrUserId` — a `Player` **or** a numeric user id;
  `reason` — a free-form string for the log
- **Returns:** nothing
- **Failure modes:** never throws. An invalid argument type is a
  `Debug.Warn` and a no-op.

## Progress

### `AnimalService:AddXP(animalId: string, amount: number): any`
- **Description:** Adds XP, applies the level curve, and (on a level
  change) fires the celebration + the `AnimalLeveledUp` remote.
- **Parameters:** `animalId`, `amount` — a **non-negative integer**
- **Returns:**
  - Success: `{ success = true, newXP, level, levelsGained, leveledUp,
    atMaxLevel, requestedXP, xpModifier, appliedXP }`
  - Failure: `{ success = false, error = '<code>' }`
- **Failure modes (error codes):** `'invalid-amount'`,
  `'fractional-amount'`, `'negative-amount'`, `'no-animal'`,
  `'invalid-state'`. **Does not throw.**
- **Gotcha:** declared with a **colon** — call it as
  `AnimalService:AddXP(id, n)`.
- **Gotcha:** the level-up **presentation** is `pcall`-guarded — a VFX
  failure logs a warning and never rolls back the XP.

### `AnimalService.ApplyLevelUpgrade(uniqueId: string): any`
- **Description:** The **paid** upgrade path — bumps the level by one,
  syncs the profile, and celebrates exactly like an XP level-up.
- **Parameters:** `uniqueId`
- **Returns:**
  - Success: `{ success = true, oldLevel, newLevel }`
  - Failure: `{ success = false, error = '<code>' }`
- **Failure modes (error codes):** `'no-animal'`, `'invalid-state'`,
  `'invalid-level'`. Does not throw.
- **Gotcha:** `'invalid-state'` when the animal is `Consumed` or
  `Destroyed`; `'invalid-level'` when the level is not a valid
  integer `>= 1` or is already at `MaxLevel`.

## Growth and cleanup

### `AnimalService.ApplyGrowthScale(animal: any): string`
- **Description:** Applies the weight-driven uniform scale to the model.
- **Parameters:** `animal` — the runtime record
- **Returns:** `'applied'`, `'unchanged'`, or `'skipped'`
- **Failure modes:** never throws.
- **Gotcha:** it returns a **string, not a boolean**.
- **Gotcha:** `Model:ScaleTo` accepts a single **uniform** number only.

### `AnimalService.SettleModelAtSlot(animal: any, slot: any)`
- **Description:** Re-seats a model at a slot and re-grounds it.
- **Returns:** nothing. Does not throw.

### `AnimalService.ForceReleaseBase(baseId: string)`
- **Description:** **Destructive.** Wipes every animal on a base —
  destroys the model, drops the registry entry, **and removes the
  persisted profile row**.
- **Parameters:** `baseId`
- **Returns:** nothing
- **Failure modes:** never throws.
- **Gotcha:** this is the **only** path that removes the profile row.
  It skips animals with `stolenBy ~= nil` (a live steal transaction).
- **Gotcha:** it handles **carried** animals too (whose `slotId` is
  `nil`), not just slotted ones.

### `AnimalService.CleanupPlayer(userId: number)`
- **Description:** On leave — destroys the runtime models and drops the
  registry entries, and clears a dangling carry.
- **Parameters:** `userId`
- **Returns:** nothing
- **Failure modes:** never throws.
- **Gotcha:** **this is NOT destructive for slotted animals.** The
  persisted row survives so the rejoin can re-spawn it. Use
  `ForceReleaseBase` for a wipe.

### `AnimalService.DestroyRuntimeAnimal(uniqueId: string): boolean`
- **Description:** Destroys one animal's model and drops its registry
  entry. **Does not** remove the profile row.
- **Returns:** `true` if an animal was destroyed, `false` if not found
- **Failure modes:** never throws.

## Arena deployment

### `AnimalService.IsArenaDeployed(uniqueId: string): boolean`
- **Description:** Whether the animal is currently parked in an arena
  raid.
- **Returns:** `true` / `false`. Does not throw.

### `AnimalService.SetArenaDeployed(uniqueId: string, deployed: boolean): boolean`
- **Description:** Marks/unmarks an animal as arena-deployed.
- **Returns:** `true` if the flag changed, `false` otherwise
- **Failure modes:** never throws; an unknown id returns `false`.

## Test seams

These exist only for the specs. Production paths never call them.

### `AnimalService._TestRegister(record: any): boolean`
- **Description:** Registers a minimal runtime record (must carry
  `uniqueId` + `ownerUserId`) so a spec can exercise `AddXP` without
  spawning a model.
- **Returns:** `true` / `false`

### `AnimalService._TestUnregister(uniqueId: string)`
### `AnimalService._TestArenaParkedCount(): number`
### `AnimalService._TestResetArenaDeployment()`
- **Returns:** nothing / a count, as appropriate. Never throw.

---

# `ServerScriptService/Animal/WalkController.lua`

The pathfinding walker. **No `TweenService` anywhere** — it uses
`RunService.Heartbeat` + `model:PivotTo()`.

## Module fields

| Field | Default | Meaning |
|---|---|---|
| `WalkController.Speed` | `10` | Studs per second. Mirrors `AnimalConfig.MovementSpeed`. |
| `WalkController.AnimationBaseSpeed` | from `Config.World.Movement.AnimalWalk.AnimationBaseSpeed` | The walk animation's nominal speed. |
| `WalkController.YawSmoothing` | from `Config.World.Movement.YawSmoothing` | The yaw lerp factor. |
| `WalkController.WallClockPadding` | from `Config.World.Movement.AnimalWalk.WallClockPadding` | The time budget padding. |
| `WalkController.FacingOffset` | `0` | Radians of yaw offset applied to the facing. |

### `WalkController.Start(animal: any, slot: any): any`
- **Description:** Starts the walk to a slot. Computes a
  `PathfindingService` polyline, then walks it with an arc-length
  cursor and a per-waypoint Y lerp.
- **Parameters:** `animal` — the runtime record (needs a `model` and a
  `PrimaryPart`), `slot` — the target slot
- **Returns:** the controller handle (a table) on success, `nil` on
  failure
- **Failure modes:** **`error(..., 2)`** (level 2) on a missing model, a
  missing `slotId`, or a missing `PrimaryPart`. This is a
  programming-error path.
- **Gotcha:** the module's own header says
  `# NEED TO REMOVE THIS FILE IN FUTURE` (line 2) — it is scheduled
  for deletion.

### `WalkController.Stop(controller: any)`
- **Description:** Stops the walk and releases the heartbeat binding.
- **Returns:** nothing. Does not throw.

### `WalkController.IsRunning(controller: any): boolean`
- **Description:** Whether the controller is currently walking.
- **Returns:** `true` / `false`. Does not throw.

---

# `ServerScriptService/Animal/CarryController.lua`

The carry rig. The carried animal **rides a `Motor6D`** named
`'CarryJoint'` on the player's `Head`. **No `BodyMover` / `BodyGyro`.**

### `CarryController.HeadClearanceStuds`
- **Type:** number
- **Default:** `2.5` (from `Config.World.Prompts.CarryVisual.HeadClearanceStuds`)

### `CarryController.Start(animal: any, userId: number, character: Model, player: Player?): any`
- **Description:** Attaches the animal to the player's head via a
  `Motor6D` and drives the follow.
- **Parameters:** `animal` — the runtime record, `userId`, `character` —
  the player's `Model`, `player` — optional, for the network owner
- **Returns:** the controller handle on success, `nil` on failure
- **Failure modes:** **`error(..., 2)`** (level 2) on a missing model, a
  missing character, a missing `Head`, or a missing `PrimaryPart`.
- **Gotcha:** the `Motor6D` is configured in a fixed 5-step order —
  `Massless` -> `CanCollide = false` -> `Anchored = false` ->
  `PlatformStand = true` -> `SetNetworkOwner(player)` — and the
  `Motor6D` itself is created **last**.

### `CarryController.Stop(controller: any)`
- **Description:** Detaches the animal and cleans up the joint.
- **Returns:** nothing. Does not throw.

### `CarryController.IsRunning(controller: any): boolean`
- **Description:** Whether the carry is active.
- **Returns:** `true` / `false`. Does not throw.

---

# `ServerScriptService/Animal/CarryPrompts.lua`

All the `ProximityPrompt` plumbing. Every function here is a
**registration / removal** helper — none of them mutate gameplay state.

### `CarryPrompts.SetGrabPromptCallback(cb: (Player, string) -> any)`
### `CarryPrompts.SetEggGrabPromptCallback(cb: (Player, string) -> any)`
### `CarryPrompts.SetHatchPromptCallback(cb: (Player, string) -> any)`
### `CarryPrompts.SetSellPromptCallback(cb: (Player, string) -> any)`
- **Description:** Register the callback a prompt invokes.
- **Parameters:** `cb` — the callback, or `nil` to clear
- **Returns:** nothing. Does not throw.

### `CarryPrompts.GetHatchPromptCallback(): ((Player, string) -> any)?`
### `CarryPrompts.GetSellPromptCallback(): ((Player, string) -> any)?`
- **Description:** Read back the registered callback.
- **Returns:** the callback, or `nil` if none is registered

### `CarryPrompts.SetPlacePromptCallback(cb: (Player, string, string) -> any)`
- **Description:** Register the Place callback. The signature carries
  the **source slot id** and the **destination slot id**.
- **Parameters:** `cb(player, sourceSlotId, destSlotId)`
- **Returns:** nothing

### `CarryPrompts.SetStealPromptCallback(cb: (Player, string, string?) -> any)`
- **Description:** Register the Steal callback. The third argument is
  the **optional** occupant id.

### `CarryPrompts.InstallPickupPrompt(model: Model?, occupantId: string?, kind: string?, slot: any?, ownerUserId: number?)`
- **Description:** Installs the **Pickup** prompt on a model.
- **Parameters:** `model`, `occupantId`, `kind` (the occupant kind),
  `slot`, `ownerUserId`
- **Returns:** nothing. Does not throw. A model with no `PrimaryPart`
  is a no-op (warn).

### `CarryPrompts.InstallHatchPrompt(egg: any, slot: any?, ownerUserId: number?)`
- **Description:** Installs the **Hatch** prompt on an egg.
- **Parameters:** `egg` — the egg runtime record, `slot`, `ownerUserId`
- **Returns:** nothing. Does not throw. An egg with no `PrimaryPart` is
  a no-op (warn).

### `CarryPrompts.InstallStealPrompt(model: Model?, occupantId: string?, kind: string?, ownerUserId: number?)`
- **Description:** Installs the **Steal** prompt.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.InstallSellPrompt(model: Model?, occupantId: string?, ownerUserId: number?)`
- **Description:** Installs the **Sell** prompt.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.InstallGrabPrompt(slotPart: BasePart?, occupantId: string?)`
- **Description:** Installs the **Grab** prompt on a slot part.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.InstallPlacePromptOnSlot(slot: any, playerId: number?)`
- **Description:** Installs the **Place** prompt on one slot.
- **Parameters:** `slot`, `playerId` — the owner, or `nil` for a
  neutral slot
- **Returns:** nothing. Does not throw.

### `CarryPrompts.InstallPlacePromptsForBase(base: any, playerId: number?, carriedKind: string?)`
- **Description:** Installs the Place prompts across a whole base.
- **Parameters:** `base`, `playerId`, `carriedKind` — the kind being
  carried, which selects the per-kind prompt text
- **Returns:** nothing. Does not throw.

### `CarryPrompts.RemovePlacePromptsForBase(base: any)`
- **Description:** Removes every Place prompt on a base.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.RemovePromptsFromModel(model: Model?)`
- **Description:** Strips every prompt from a model.
- **Returns:** nothing. Does not throw. A `nil` model is a no-op.

### `CarryPrompts.RemoveStealPromptFromModel(model: Model?)`
- **Description:** Strips just the Steal prompt.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.RemoveAllHatchPrompts(_blocksFolder: Folder?)`
### `CarryPrompts.RemoveAllGrabPrompts(_base: any)`
### `CarryPrompts.RemoveAllPromptsFromBase(_base: any)`
### `CarryPrompts.RemoveAllPromptsFromSlot(_slotPart: BasePart?)`
- **Description:** Bulk removals.
- **Returns:** nothing. Never throw. The leading underscore in the
  parameter names marks them as **unused** in the implementation.

### `CarryPrompts.ForgetSlotsForBase(base: any)`
- **Description:** Drops the internal slot -> prompt registry entries
  for a base.
- **Returns:** nothing. Does not throw.

### `CarryPrompts.DisablePickupHatchPromptsForBase(base: any)`
### `CarryPrompts.EnablePickupHatchPromptsForBase(base: any)`
- **Description:** Toggle the Pickup/Hatch prompts on a base (used
  during a raid lock).
- **Returns:** nothing. Does not throw.

---

# `ServerScriptService/Animal/LevelUpPresentation.lua`

The level-up celebration: the bop, the VFX, the weight growth, and the
`AnimalLeveledUp` remote.

### `LevelUpPresentation.SetWeightProvider(fn: ((any) -> number?)?)`
- **Description:** Injects the weight lookup used to scale the model
  during the growth animation.
- **Parameters:** `fn` — a function taking the animal record and
  returning a weight, or `nil` to clear
- **Returns:** nothing. Does not throw.
- **Gotcha:** a **non-function** value is silently ignored (the
  provider is left unchanged) — it is not an error and is not logged.

### `LevelUpPresentation.PlayUpgradeVfx(model: any)`
- **Description:** Plays the upgrade particle burst on a model.
- **Parameters:** `model` — the animal's `Model`
- **Returns:** nothing. Does not throw.
- **Gotcha:** any `Sound` embedded in the VFX is **destroyed
  unplayed** — it would be audible server-wide. The personal sting
  plays on the owning client instead.

### `LevelUpPresentation.NotifyLevelUp(animal: any, info: any)`
- **Description:** The full celebration — the bop, the VFX, the
  smooth weight growth, and the `AnimalLeveledUp` remote.
- **Parameters:** `animal` — the runtime record, `info` — a table with
  `oldLevel`, `newLevel`, `levelsGained`
- **Returns:** nothing
- **Failure modes:** never throws, but callers `pcall` it anyway.
- **Gotcha:** `info.oldLevel` may be `nil` if the level was unknown.

### `LevelUpPresentation.Cancel(animalId: string)`
- **Description:** Cancels an in-flight celebration and **bumps the
  per-animal generation counter**, so a stale callback cannot resume
  a cancelled bop.
- **Parameters:** `animalId`
- **Returns:** nothing. Does not throw.

### `LevelUpPresentation._TestGeneration(animalId: string): number`
### `LevelUpPresentation._TestIsDriving(animal: any): boolean`
- **Description:** Test seams for the generation counter and the
  "is this celebration currently driving the model" flag.
- **Returns:** a number / a boolean. Never throw.

---

# `ServerScriptService/Animal/AnimalOverhead.lua`

The floating name/level/rarity billboard above each animal.

### `AnimalOverhead.Refresh(animal: any): boolean`
- **Description:** Repaints the overhead for an animal from the
  authoritative record.
- **Parameters:** `animal` — the runtime record
- **Returns:** `true` if an overhead exists (and was refreshed), `false`
  otherwise
- **Failure modes:** never throws. A missing template is a warn-once and
  no overhead.
- **Gotcha:** the overhead must refresh on **every** authoritative
  mutation (a level-up, a weight change) — it does not poll.

### `AnimalOverhead.EnsureForAnimal(animal: any): boolean`
- **Description:** Creates the overhead if it does not exist yet.
- **Returns:** `true` if an overhead is present afterwards, `false`
  otherwise
- **Failure modes:** never throws.

### `AnimalOverhead.RemoveForAnimal(animal: any)`
- **Description:** Destroys the overhead for an animal.
- **Returns:** nothing. Does not throw.

### `AnimalOverhead.SetStolen(animal: any, stolen: boolean): boolean`
- **Description:** Marks the overhead as stolen (repaints the name in
  the stolen colour, `Color3.fromRGB(255, 90, 90)`).
- **Returns:** `true` if the state changed, `false` otherwise
- **Failure modes:** never throws.

### `AnimalOverhead._TestFind(animal: any): Instance?`
### `AnimalOverhead._TestIsStolen(uniqueId: string): boolean`
### `AnimalOverhead._TestReset()`
### `AnimalOverhead._TestRainbowCount(): number`
- **Description:** Test seams.
- **Returns:** an `Instance?` / a boolean / nothing / a count. Never
  throw.

---

# `ReplicatedStorage/Config/Creatures/Animals.lua`

The catalog + the stat tables. **This is a config module, not a service.**

### `Animals.Catalog`
- **Type:** `{ [rarityId] = { [DefId] = definition } }`
- **Default:** 26 species over 6 tiers. `Uncommon` and `Secret` are
  **intentionally empty**.
- **Each definition:** `{ displayName, baseHealth, baseDamage, ... }`
- **Gotcha:** the per-entry `baseHealth` / `baseDamage` vary ~±15% within
  a tier; only the per-tier Health `Base` anchor is preserved exactly.
  The legacy per-tier `baseDamage` anchors are **not** preserved.

### `Animals.Stats`
- **Type:** `{ Health = { [rarity] = { Base, Maximum, Curve } }, Damage = { ... }, Income = { ... } }`
- **Gotcha:** **`Damage` must be exactly `Health / 10`** in `Base`,
  `Maximum` and `Curve`. `validateStats()` **errors at require time**
  otherwise.
- **Gotcha:** `Income`'s `Curve` is **`80`**, not `100`.
- **Gotcha:** Level 1 -> `Base` **exactly**; MaxLevel -> `Maximum`
  **exactly** (boundary fast paths, immune to float dust).

### `Animals.WeightByRarity` — `{ [rarity] = { Base, Maximum } }`
### `Animals.WeightByDefinition` — `{ [DefId] = { Base, Maximum } }` (default `{}`)

### `Animals.SellBaseValue` — `{ [rarity] = number }`
### `Animals.SellMultiplier` — `{ [rarity] = '<decimal string>' }` (default `'0.75'`)
- **Gotcha:** the multiplier is a **decimal string**, not a number.

### `Animals.RarityMultipliers` — `{ Health = { [rarity] = number }, Damage = { [rarity] = number } }`
- **Used by** `GetHealth` / `GetDamage`. The table is **nested per
  stat**, not flat per rarity, and the Health and Damage multipliers
  are **different numbers** (e.g. Mythic is `5.0` Health but `6.5`
  Damage).

### `Animals.MovementSpeed` = `10`
### `Animals.BaseHealth` = `5`
### `Animals.BaseDamage` = `2`
### `Animals.DefaultLevel` = `1`
### `Animals.BaseLevel` = `RarityDefs.BaseLevel` (from `Config.Creatures.Rarity`)

### `Animals.Carry`
- **Type:** the **re-export** of `Config.World.Prompts` (the Carry
  system's config). Not an independent copy.

### `Animals.GetHealth(rarity: string, baseHealth: number): number`
- **Description:** Applies the rarity multiplier to a base health.
- **Returns:** `math.floor(baseHealth * multiplier)`
- **Failure modes:** never throws; an **unknown rarity** falls back to
  a multiplier of `1` (the unmultiplied floor).

### `Animals.GetDamage(rarity: string, baseDamage: number): number`
- **Description:** The same for damage.
- **Returns:** `math.floor(baseDamage * multiplier)`

### `Animals.GetRandom(rarity: string, rng: (() -> number)?): (string?, any?)`
- **Description:** Picks a random species from a rarity bucket.
- **Parameters:** `rarity`, `rng` — an optional RNG (defaults to
  `Random.new()`)
- **Returns:** `(defId, definition)`, or `(nil, nil)` for an unknown or
  **empty** bucket
- **Failure modes:** never throws; returns `(nil, nil)`.
- **Gotcha:** the implementation **sorts** the ids first, then clamps
  the pick — so the result is order-independent.

### `Animals.Get(definitionId: string): (string?, any?)`
- **Description:** The reverse lookup — finds a species by its defId.
- **Returns:** `(rarity, definition)`, or `(nil, nil)` if not found
- **Failure modes:** never throws.
- **Gotcha:** the implementation is a **linear `pairs` scan** over every
  bucket — O(species). Fine at 26, not at 10 000.

---

# `ReplicatedStorage/Utility/AnimalStats.lua`

The derived-stat pipeline. **Health, Damage and Income are never
persisted** — they are recomputed from `Level` + the definition + the
config on every read.

### `AnimalStats.SUPPORTED_STATS`
- **Type:** `{ Health, Damage, Income }` — a set of the three supported
  stat names.

### `AnimalStats.GetStatConfig(rarity: any, statName: string): any?`
- **Description:** The `{ Base, Maximum, Curve }` row for a rarity +
  stat.
- **Parameters:** `rarity`, `statName`
- **Returns:** the row table, or `nil`
- **Failure modes:** **throws** on an unsupported `statName` (a
  programming error). Returns `nil` for an unknown rarity.

### `AnimalStats.Calculate(animal: any, statName: string): number`
- **Description:** The derived value.
- **Parameters:** `animal` — a record with `DefId` and `Level`;
  `statName` — `'Health'`, `'Damage'` or `'Income'`
- **Returns:** the value as a number
- **Failure modes:**
  - **Throws** on a non-table `animal` or an unsupported `statName`
    (programming errors).
  - An **unknown `DefId`** -> a warn-once and **`0`**.
  - A **malformed `Level`** -> repaired through
    `LevelConfig.Normalize(animal.Level, 0)`.
- **Gotcha:** **`Damage` short-circuits to
  `Calculate(animal, 'Health') / 10`** — it never reads the Damage
  curve. That is what makes the 10:1 invariant bit-exact.
- **Gotcha:** `Income` is multiplied by
  `TraitConfig.GenerationMultiplierFor(trait) * MutationConfig.GenerationFold(mutations)`.

### `AnimalStats.Snapshot(animal: any): { Health: number, Damage: number }`
- **Description:** The two combat stats at once.
- **Returns:** `{ Health, Damage }` — **only** those two. Not Income,
  not Weight, not Scale.
- **Failure modes:** never throws for a data problem.

---

# `ReplicatedStorage/Utility/AnimalWeight.lua`

### `AnimalWeight.MaxGrowthScale` = `1.30`
### `AnimalWeight.Curve` = `100`

### `AnimalWeight.GetRange(definitionId: any): { Base: number, Maximum: number }?`
- **Description:** The weight range for a species — the
  per-definition override if there is one, else the per-rarity range.
- **Returns:** `{ Base, Maximum }`, or `nil` when unresolvable
- **Failure modes:** never throws.

### `AnimalWeight.CalculateWeight(definitionId: any, level: any): number?`
- **Description:** The weight at a level.
- **Returns:** the weight, or `nil` when unresolvable
- **Failure modes:** never throws; a malformed level is repaired
  internally.

### `AnimalWeight.GrowthAlpha(definitionId: any, level: any): number?`
- **Description:** The normalised growth `0..1` toward the max weight.
- **Returns:** the alpha, or `nil`

### `AnimalWeight.GetGrowthMultiplier(definitionId: any, level: any): number?`
- **Description:** The scale multiplier derived from the weight.
- **Returns:** the multiplier, or `nil`

### `AnimalWeight.GetTargetScale(animal: any): number?`
- **Description:** The uniform scale the model should have.
- **Parameters:** `animal` — the runtime record
- **Returns:** `animal.baseScale * multiplier`, or `nil` when
  unresolvable
- **Failure modes:** never throws.
- **Gotcha:** the **server-side application** of this value lives in
  `AnimalService.ApplyGrowthScale` (which returns a **string**), not
  here.

---

# `ReplicatedStorage/Utility/OwnedObjectIdentity.lua`

The id mint. Animals use the **`AN_`** prefix.

### `OwnedObjectIdentity.Kind`
- **Type:** `{ Brainrot = 'Brainrot', LuckyBlock = 'LuckyBlock', Animal = 'Animal', Egg = 'Egg' }`

### `OwnedObjectIdentity.PREFIX`
- **Type:** `{ Brainrot = 'BR_', LuckyBlock = 'LB_', Animal = 'AN_', Egg = 'EG_' }`

### `OwnedObjectIdentity.TOKEN_LENGTH` = `10`
### `OwnedObjectIdentity.MAX_COLLISION_RETRIES` = `8`

### `OwnedObjectIdentity.Generate(kind: string): string`
- **Description:** Mints a new id.
- **Parameters:** `kind` — a key of `Kind`
- **Returns:** `'<PREFIX><10-char base-62 token>'`
- **Failure modes:** **asserts** on an invalid kind. Never throws for a
  valid kind.

### `OwnedObjectIdentity.IsValid(id: any, kind: string): boolean`
- **Description:** Whether an id is well-formed for a kind.
- **Returns:** `true` / `false`. Does not throw.

### `OwnedObjectIdentity.GenerateUnique(kind: string, existing: { [string]: any }?): string`
- **Description:** Mints an id that is not already in `existing`.
- **Parameters:** `kind`, `existing` — a set of taken ids (optional)
- **Returns:** a unique id
- **Failure modes:** **`error(...)`** after **8** collision retries.
- **Gotcha:** the **`AN_` prefix is canonical** — a legacy id with a
  different prefix is migrated by `MigrateLegacyId`.

### `OwnedObjectIdentity.KindOf(id: any): string?`
- **Description:** The kind an id belongs to, derived from its prefix.
- **Returns:** the kind, or `nil` if the id is not well-formed

### `OwnedObjectIdentity.MigrateLegacyId(id: any, canonicalKind: string): string?`
- **Description:** Rewrites a legacy id into the canonical prefix.
- **Parameters:** `id`, `canonicalKind`
- **Returns:** the migrated id, or `nil` when there is nothing to
  migrate

---

## Not in this system

For completeness, the things a caller might expect and that are **not
here**:

- **No `TweenService`** — all animation is
  `RunService.Heartbeat` + `PivotTo` / `ScaleTo`.
- **No `BodyMover` / `BodyGyro`** — the carry uses a `Motor6D`.
- **No `Damage` / `Health` storage** — both are derived.
- **No `Income` accumulator inside the animal** — the uncollected cash
  rides in the profile's `CashPool`.
- **No `AnimalService:Update` / `:Tick`** — there is no server loop to
  call; everything is event-driven.
- **No `AnimalService.Create`** — the only spawn paths are
  `CreateFromEgg` and `SpawnFromPersistence`.
- **No sell or steal implementation** — those are separate systems;
  this one only installs the prompts and fires the callbacks.
