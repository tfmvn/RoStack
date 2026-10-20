# Collectors — engineering notes

## Purpose, in one line

Two small server modules: one decides where a flying egg actually
**lands** (and refunds it when the base cannot hold it), the other
fires the **cash-claim feedback** (SFX, VFX, button press).

---

## How it actually works

## Part 1 — `CollectorArrival`

### The central idea

> **The landing slot cannot be decided at launch.** The flight takes
> ~7 seconds, and the base can change completely in that time.

So `FlightController` targets the **Collector** (not a slot) and hands
the egg to `CollectorArrival.OnArrival` at flight completion. This
module re-validates against the base's *current* state.

Arrival is **flight completion, not a `.Touched` signal**. Because the
flight's destination *is* the Collector, finishing the flight means
being at it — there is no `Touched` race (an egg clipping a corner of
the Collector part on the way past, or a `Touched` that never fires
because both parts are `CanCollide = false`).

### The seven steps of `OnArrival(egg, refs)`

```text
1. GUARDS
     egg is nil                       -> false
     egg._aborted                     -> false
     egg.model missing / no Parent    -> false
     egg.state ~= nil and
       egg.state ~= Traveling         -> false (warn)
2. OWNER
     egg.ownerUserId (valid)          -> use it
     else SlotType.ParseId(egg.slotId).userId -> use it
     else -> _refundAndDrop(egg, refs, nil, 'no-owner'); return false
3. LANDING SLOT (three tiers, below)
     nil -> _refundAndDrop(egg, refs, userId, 'no-free-slot'); return false
4 + 5. TELEPORT + SETTLE
     HoverMath.Settle(egg, slot)
       -> one PivotTo to the slot's SEATED CFrame (GroundedCFrameOnSlot)
       -> refreshes egg.centerCFrame and egg._localFloor
       -> clears egg.controller / egg.controllerType (a resting egg is static)
     StandPresentation.Bind(egg.model, SlotType.OccupantKind.Egg)
       -> the stand wobble; rest = the settled pose, so it sits alive
6. OCCUPY
     slotService.OccupySlot(slot.id, egg.uniqueId, OccupantKind.Egg)
     false -> warn; LEAVE THE EGG Traveling; DO NOT fire _onArrived;
              return false
7. COMMIT + HAND OFF
     egg.slotId = slot.id
     egg.state  = Constants.State.Placed
     TutorialSignals.Fire('EggPlaced', { EggId, OwnerUserId, SlotId })  (pcall)
     egg._onArrived(egg, slot, slot.id)   (pcall; errors are warned)
     return true
```

**Why step 6 leaves the egg `Traveling` on failure:** the slot changed
between the resolve and the occupy. `Traveling` is what makes
`SpawnService.ForceReleaseBase` willing to clean this egg up later.
Committing `Placed` would strand it forever, because the cleanup path
only tears down `Traveling` / `Opening` eggs.

### The three tiers

**Tier 1 — the reservation is intact.**

```lua
local reserved = slotService._findSlotById(egg.slotId)
if reserved and reserved.part and reserved.state == SlotType.State.Reserved then
    return reserved
end
```

A `Reserved` slot records **no reserver** (`slot.occupantId` is set
only by `OccupySlot`), so `state == Reserved` on the *specifically
named* slot is the strongest check available. That is sufficient
because `Purchase` reserves exactly **one distinct slot per flight**
(`GetFreeSlot` → `ReserveSlot`) and stamps its id on the egg — so no
two in-flight eggs can name the same slot.

**Tier 2 — another slot is free.**

```lua
local fresh = slotService.GetFreeSlot(userId)
if not fresh then return nil end            -- -> Tier 3
if not slotService.ReserveSlot(fresh.id) then return nil end  -- -> Tier 3
-- re-point the SAME persistence record
local rePointed = playerService.SetEggSlot(userId, egg.uniqueId, fresh.id)
if not rePointed and playerService.AddEgg then
    playerService.AddEgg(userId, fresh.id, egg.rarity, egg.uniqueId, {
        Mutations = egg.Mutations,
        Trait = egg.Trait,
    })
end
egg.slotId = fresh.id
return fresh
```

The **re-point, never remove-and-add** rule is the load-bearing part.
The pre-2.5.1 code did `RemoveEgg(oldSlotId)` — a silent no-op,
because records are matched by **Id**, not slot id — then
`AddEgg(fresh.id)`, which minted a **second** record with a new Id.
The stale record survived and came back as a phantom egg on rejoin:
the reported "Animal→Egg conversion". `SetEggSlot` mutates the record
**in place**; the `AddEgg` fallback passes the runtime's own Id
explicitly so it can never mint a duplicate identity.

**Tier 3 — nothing is free.**

`_refundAndDrop(egg, refs, userId, reason)`:

```text
1. Warn 'CollectorArrival: no slot available, refunding'
2. EconomyService.AddMoney(userId, refundStr, TransactionReason.EggRefund)
     refundStr = BigNumber.sanitize(tostring(egg.price))
     nil -> SKIP the refund (warn) rather than corrupt the balance
3. playerService.RemoveEgg(userId, egg.uniqueId)       -- by the record Id
     false -> playerService.RemoveEggAtSlot(userId, egg.slotId)  -- fallback
     false -> warn 'refunded egg had no persistence record to remove'
4. slotService.ReleaseSlot(egg.slotId)   -- release the stale reservation
5. egg.slotId = nil
6. egg._aborted = true
7. egg.controller = nil; egg.controllerType = nil
8. egg.model:Destroy(); egg.model = nil
9. SpawnService.DropEgg(egg.uniqueId)     -- lazy require (breaks the cycle)
10. NotificationService.NotifyWarning(player, 'Buy_ArrivalBaseFull')
```

**The order is load-bearing.** The persistence record is removed
**before** the registry drop (step 3 before step 9), so a player who
rejoins immediately does not get an egg restored onto a slot that was
never occupied.

**The refund is deliberately skippable.** If `egg.price` is malformed,
the money is *not* refunded (the player loses at most one egg's price)
rather than risk corrupting the balance.

**`ReleaseSlot` is safe here** because we are on the failure path: the
egg never occupied the slot, so releasing the stale reservation cannot
evict somebody else's occupant.

### The `refs` argument

`refs` is the egg's `_refs` table — `{ playerService, baseService,
animalService, slotService }` — wired by `SpawnService` at spawn time.
Passing it in rather than requiring the services keeps the module
**testable with fakes** and free of the service require cycle.

`CollectorArrival` is the only consumer of `refs.playerService` and
`refs.slotService`; `baseService` and `animalService` are present in
the table but unused here.

### The lazy require

```lua
local SpawnService = require(script.Parent.Parent.Egg.SpawnService)
SpawnService.DropEgg(egg.uniqueId)
```

inside `_refundAndDrop`. `SpawnService` is required by `EggService`,
which requires this module — a top-level require would close the cycle.

---

## Part 2 — `CollectFeedback`

### The central idea

> **The claim commit is authoritative; the feedback is pure
> presentation and must never delay it.**

`CollectFeedback.Play(player, slot)` fires all three effects with
**zero waits** between the commit and the feedback. It is called by
`IncomeService.TryCollect` **after** `AddMoney` succeeds and the pool
zeroes — so an empty / failed / rejected claim never reaches it. There
is therefore **no silent-feedback path by construction**.

### The three effects

**1. The SFX (synchronous, first).**

A **bounded pool of 4 pre-created `Sound`s** per player, under
`PlayerGui/CashClaimPool` (`CashClaim1` … `CashClaim4`).

```lua
local idx = (_nextIndex[userId] or 0) % #pool + 1
_nextIndex[userId] = idx
local sound = pool[idx]
if sound.SoundId == '' then return end   -- stay mute, never fake a play
sound:Play()
```

Why a pool instead of one restarting instance: a single restarting
`Sound` **drops overlapping claims** and **mutes the first collect
while the asset replicates**. The pool round-robins, so rapid claims
overlap instead of truncating.

`_ensurePool(guiRoot)` is **self-healing**: a missing pool folder is
created, a missing member is recreated, a stale member (empty or
retargeted `SoundId`) is refreshed from the template. The **legacy
`CashClaimSfx` singleton is destroyed** when the pool is ensured.
Same-value `SoundId` sets are no-ops (no reload); only real drift
recopies.

`_copySfxProps` copies `SoundId`, `Volume`, `PlaybackSpeed`,
`RollOffMinDistance`, `RollOffMaxDistance`, `EmitterSize`, forces
`Looped = false` and `PlayOnRemove = false`, and re-stamps
`AudioGroups.AssignSfx(target)`.

The pool lives in the **client's `PlayerGui`** because the client has
to hear it and the template is server-only. The server writes into the
client GUI — unusual, but necessary.

**2. The VFX (asynchronous, last).**

```text
1. Resolve the template: ServerStorage.Assets.Vfx.CashClaim
     the asset IS an Attachment, or FindFirstChildWhichIsA('Attachment')
2. Clone it. The TEMPLATE IS NEVER MUTATED.
3. Collect the "playables": every descendant that is a
   ParticleEmitter / Sound / PointLight / SpotLight / SurfaceLight / Beam
4. Mount: clone.Parent = pressPart
     any Attachment whose parent is not a BasePart -> re-home to pressPart
     any playable whose parent is not a BasePart or Attachment -> re-home
     (the re-homed nodes get their OWN Debris entry, because Debris on
      the clone can no longer reach them)
5. Re-anchor the burst origin:
     up     = pressPart.CFrame.UpVector
     burst  = pressPart.Position + up * (pressPart.Size.Y / 2 + VFX_SURFACE_LIFT)
     yaw    = math.random() * 2pi   (per-claim variation, clone only)
     for each burst attachment:
        attachment.WorldCFrame = CFrame.new(burst) * (yawCf * (wc - wc.Position))
6. RunService.Heartbeat:Wait()      -- replication catch-up
     if pressPart.Parent == nil -> destroy the clone + moved nodes, return
7. Fire each playable:
     ParticleEmitter -> count = the emitter's OWN 'EmitCount' ATTRIBUTE
                          (exact value, never scaled; missing/invalid -> 0)
                          emitter:Emit(count)
                          track emitter.Lifetime.Max for the cleanup
     Sound           -> AudioGroups.AssignSfx(sfx); sfx:Play()
     PointLight /    -> Enabled = true   (clone only)
     SpotLight /
     SurfaceLight
     Beam            -> Enabled = true   (clone only)
8. lifetime = clamp(longestLifetime + VfxCleanupPadding,
                    VfxCleanupMin, VfxCleanupMax)
   Debris:AddItem(clone, lifetime); Debris:AddItem(moved, lifetime)
9. if no emitter fired -> warn 'CashClaim VFX has no ParticleEmitter'
```

Two production bugs the design fixes (both documented in the header):

- **OCCLUSION.** A template attachment kept at its authored local
  offset sits **inside** the opaque `PressPart` mesh, where every
  particle is occluded. The re-anchor step exists for exactly this.
- **REPLICATION RACE.** `Emit` on a brand-new instance in the same
  tick as parenting can be missed by clients it has not replicated to
  yet. One `Heartbeat` closes the race (~16ms).

**3. The button press (synchronous, second).**

Per-`PressPart` state, keyed with **weak keys** so a destroyed stand
does not pin memory:

```lua
type ButtonState = {
    rest: CFrame,        -- the canonical rest transform, cached on first sight
    generation: number,  -- the press generation
    tween: Tween?,
    conn: RBXScriptConnection?,
}
```

The press math is **pure and geometry-relative**:

```lua
function CollectFeedback.ComputePressedCFrame(rest, basePos, fraction?)
    local f = fraction or PRESS_FRACTION            -- 0.45
    local up = rest.UpVector
    local gapVec = basePos - rest.Position
    local travel = -gapVec:Dot(up)                   -- the projected gap
    if not (travel == travel) or travel < MIN_PRESS_TRAVEL then
        return rest                                  -- degenerate: no press
    end
    return rest - up * (travel * f)
end
```

- The travel is along the button's **own local Y**, so a horizontally
  offset `Base` produces a **pure local-Y press** (never sideways).
- A tilted button presses along **its own** Y.
- `Base` level with or above `PressPart` → `travel <= 0` → no press.
- The travel is a **fraction of the live gap**, never a hardcoded
  world offset, so it adapts to any authored button.

The tween chain:

```text
_cancelLocked(state)        -- disconnect the conn, cancel + destroy the tween
state.generation += 1
mine = state.generation
pressPart.CFrame = rest     -- ALWAYS restart from the canonical rest
downTween = TweenService:Create(pressPart, DOWN_INFO, { CFrame = pressed })
downTween.Completed -> if PlaybackState ~= Completed -> return
                       if generation ~= mine or part destroyed -> return
                       task.delay(HOLD_SECONDS, ...):
                          re-check the generation
                          upTween = TweenService:Create(pressPart, UP_INFO, { CFrame = rest })
                          upTween.Completed -> re-check the generation
                                              pressPart.CFrame = rest   -- exact restore
```

Two invariants make this spam-proof:

- **Always restart from `rest`.** The travel always derives from the
  canonical transform, never from a mid-animation pose, so spam can
  never accumulate offsets or strand the button below/above rest.
- **The generation counter.** A stale callback re-checks both the
  generation **and** the tween's `PlaybackState`, so a cancelled tween
  can never move the button after a newer press started.

---

## Public API surface

### `ServerScriptService.Base.CollectorArrival`

```lua
CollectorArrival.OnArrival(egg: any, refs: any): boolean
```

- `egg` — the egg record (`uniqueId`, `ownerUserId`, `slotId`, `state`,
  `model`, `price`, `rarity`, `Mutations`, `Trait`, `_refs`, `_onArrived`).
- `refs` — the egg's `_refs` table (`playerService`, `baseService`,
  `animalService`, `slotService`).
- **Returns** `true` only when the egg ended up `Placed` on a slot.
  Every bail-out returns `false`.
- **Never throws** on the documented paths. (Step 6 calls
  `slotService.OccupySlot` without a nil check, but
  `_resolveLandingSlot` already returned `nil` in that case, so the
  refund path runs first.)

### `ServerScriptService.Base.CollectFeedback`

```lua
CollectFeedback.Init()                                     -- a NO-OP
CollectFeedback.Play(player: Player?, slot: any): { sfx: boolean, vfx: boolean, press: boolean }
CollectFeedback.Warm(player: Player?)
CollectFeedback.ForgetPlayer(userId: number)
CollectFeedback.ComputePressedCFrame(rest: CFrame, basePos: Vector3, fraction: number?): CFrame

-- Test seams
CollectFeedback._TestPress(pressPart: BasePart, base: BasePart): number
CollectFeedback._TestFireVfx(pressPart: BasePart): boolean
CollectFeedback._TestEnsurePool(root: Instance): number
CollectFeedback._TestPlayPool(root: Instance, userId: number?): (boolean, string?)
CollectFeedback._TestReset()
```

---

## Invariants the code enforces

1. **An egg is never left orphaned over the Collector.** Tier 3 always
   refunds, removes the record, destroys the model, drops the registry
   entry, and releases the reservation.
2. **The persistence record's identity is preserved.** Tier 2 mutates
   the record in place. It never removes-and-adds.
3. **The record is removed before the registry drop.** So a rejoin
   cannot restore an egg onto a slot that was never occupied.
4. **The refund is skipped rather than corrupt** when the price is
   malformed.
5. **A failed `OccupySlot` leaves the egg `Traveling`** and does not
   fire `_onArrived`, so the cleanup path can still reclaim it.
6. **The landing transform is the slot's seated CFrame.** The arrival
   path does not re-derive it — `HoverMath.Settle` owns that.
7. **The template assets are never mutated.** Every VFX change is on
   the clone.
8. **Each emitter uses its own `EmitCount` attribute, exactly.**
   Never normalized, never scaled.
9. **Only one press tween per button at a time.** A new press cancels
   the previous one and bumps the generation.
10. **A press always starts from the canonical rest.** Spam cannot
    accumulate offsets.
11. **A stale callback cannot move the button.** The generation and
    the `PlaybackState` are both re-checked.
12. **The press travels along the button's local Y only.** Never
    sideways.
13. **The SFX pool is a fixed bound** (`Audio.Collect.PoolSize`) and
    never grows.
14. **The SFX pool round-robins.** Rapid claims overlap instead of
    truncating.
15. **A stale/empty `SoundId` is refreshed, never replayed mute.**
16. **Each effect is independently nil-safe.** A missing asset or
    part skips that effect only — never the claim, never the others.
17. **`CollectFeedback` fires only on a successful claim.** There is
    no silent-feedback path by construction.
18. **The VFX dispatch never blocks the commit path.** It is
    `task.spawn`ed.

---

## Failure and edge-case behaviour

### `CollectorArrival.OnArrival`

| Situation | Result |
|---|---|
| `egg` is `nil` | `false` |
| `egg._aborted` is set | `false` |
| `egg.model` is `nil` or has no `Parent` | `false` |
| `egg.state` is set and is not `Traveling` | `false` + a warn |
| Neither `ownerUserId` nor a parseable `slotId` | `false`; `_refundAndDrop` runs with `userId = nil` → **no refund is possible**, the model is still destroyed and the egg is dropped |
| `refs.slotService` is `nil` | `false`; `_refundAndDrop` runs (no slot release, no record removal — the `refs.playerService` branch still runs) |
| Tier 1 — the reservation is intact | `true`; lands on the reserved slot; the record is untouched |
| Tier 2 — the reservation is gone, a slot is free | `true`; lands on the new slot; the record is re-pointed; `egg.slotId` updated |
| Tier 2 — `GetFreeSlot` returns `nil` | falls to Tier 3 |
| Tier 2 — `ReserveSlot` returns `false` | falls to Tier 3 |
| Tier 2 — `SetEggSlot` fails and `AddEgg` is absent | the slot is still reserved and `egg.slotId` is updated — the **record is not re-pointed** (silent data drift) |
| Tier 2 — `SetEggSlot` fails and `AddEgg` exists | the record is re-added at the new slot with the runtime's own Id + a warn |
| Tier 3 — a malformed `egg.price` | the refund is **skipped** (warn); the record is still removed and the model destroyed |
| Tier 3 — `RemoveEgg` finds nothing and `RemoveEggAtSlot` finds nothing | a warn ('refunded egg had no persistence record to remove') |
| `OccupySlot` returns `false` | `false`; the egg stays **`Traveling`**; `_onArrived` does **not** fire; the model is **not** destroyed |
| `egg._onArrived` throws | warned ('`_onArrived` errored'); the arrival still returns `true` |
| `TutorialSignals.Fire` throws | swallowed by the `pcall`; the arrival is unaffected |
| The player has left (no `Player` object) | the refund and record removal still run; the `Buy_ArrivalBaseFull` toast is skipped |

### `CollectFeedback.Play`

| Situation | Result |
|---|---|
| `player` is not a `Player` | `{ sfx = false, vfx = false, press = false }` |
| `slot` is not a table | `{ sfx = false, vfx = false, press = false }` |
| The player has no `PlayerGui` | `sfx = false`; the press and VFX still run |
| `slot.cashCollector` is missing / not a `BasePart` / has no `Parent` | no press and no VFX; the SFX still plays |
| `slot.stand` is missing | no press; the VFX still dispatches (the press part was resolved from `slot.cashCollector`) |
| `StandResolver.GetButtonParts` finds no `Base` or no `PressPart` | no press; the VFX still dispatches |
| The SFX template is missing | `sfx = false`; a warn fires **once**; the press and VFX still run |
| A pool member's `SoundId` is `''` | that play is skipped (the pool is still rotated) |
| The VFX template is missing | `vfx = false`; a warn fires **once**; the SFX and press still run |
| The VFX template has no `ParticleEmitter` | `vfx = true` (the template resolved); a warn fires |
| The press part is destroyed during the Heartbeat wait | the clone and the moved nodes are destroyed; the burst does not fire |
| `ComputePressedCFrame` with a degenerate gap | returns `rest` — the press is skipped, the SFX and VFX still play |

### `CollectFeedback.Warm` / `ForgetPlayer`

| Situation | Result |
|---|---|
| `Warm(nil)` | no-op, never throws |
| `Warm` with no `PlayerGui` | no-op |
| `Warm` twice | idempotent (the pool is reused) |
| `ForgetPlayer` with any `userId` | drops the rotation cursor; never throws |

---

## Gotchas that would bite you

1. **`CollectorArrival` hard-requires `EconomyService`** at the top
   level. It is not injected. The module will not load without it.
2. **`CollectorArrival` gets its collaborators from `refs`, not from
   module-level requires.** If you call `OnArrival(egg, nil)` the
   module still runs but has no `slotService` and no `playerService` —
   every arrival ends in the refund path.
3. **`refs.playerService` and `refs.slotService` are read with
   `refs and refs.x`, so a `nil` `refs` is tolerated.** But step 6
   (`slotService.OccupySlot`) is **not** nil-guarded. It is
   unreachable only because `_resolveLandingSlot` returns `nil`
   first.
4. **Tier 3 refunds but does not re-open the purchase.** The player
   has to buy again manually.
5. **`RemoveEgg` is keyed by the record's own Id**, not the slot id.
   The by-slot fallback only exists for the load-time re-keyed case.
6. **`SetEggSlot` mutating in place is the whole point of tier 2.**
   If you rewrite it as remove-and-add you get phantom eggs on rejoin.
7. **The `OccupySlot` race path leaves a `Traveling` egg with a live
   model.** That is intentional (the cleanup path can only reclaim
   `Traveling` eggs) but it means an egg can briefly sit on a slot it
   does not own.
8. **`CollectFeedback.Init()` is an empty function.** Calling it does
   nothing; there is no setup to do.
9. **`CollectFeedback.Play`'s `vfx = true` means "dispatched", not
   "fired".** The burst is `task.spawn`ed and its actual emission is
   asynchronous.
10. **`_ensurePool` destroys the legacy `CashClaimSfx` singleton.**
    Any other code that expects that instance will break.
11. **The SFX pool lives in the client's `PlayerGui`**, created by the
    server. That is unusual but necessary.
12. **`CollectFeedback` never mutates the workspace stand** beyond the
    press — it does move `PressPart`, but only along its own local Y
    and only back to the canonical rest.
13. **The `rest` CFrame is cached on first sight.** If anything else
    in the game moves the button later, the press fights it.
14. **`_buttons` uses weak keys**, so the entries vanish when the
    stand does — but the cached `rest` is then re-derived from
    whatever the part's CFrame is at that moment.
15. **The VFX waits one `Heartbeat`.** It is `task.spawn`ed off the
    commit path, but it is still a yield inside `_playVfx`.
16. **`Debug.Audio.Enabled` gates only the extra log line**, not the
    audio. `CollectFeedback` always plays.
17. **The press tween's `DOWN_INFO` / `UP_INFO` are module-level
    constants** built from `PRESS_SECONDS` / `RELEASE_SECONDS` at load
    time — changing the config at runtime has no effect.
18. **`Bases.Collector.Feel` and `Audio.Collect.PoolSize` live in
    different config modules** (`Config/World/Bases.lua` and
    `Config/Presentation/Audio.lua`). The Feel block was explicitly
    moved out of `AudioConfig.Collect`.

---

## What to change to reuse it

**Keep (Grade A):**

- The three-tier arrival resolution and the "refund rather than
  orphan" contract.
- The tier-2 re-point-the-record rule (identity preserved).
- The tier-3 ordering (remove the record **before** the registry drop).
- The `OccupySlot`-race rule (leave the egg `Traveling`).
- The `refs`-injection pattern (testable, cycle-free).
- The pooled, round-robin, self-healing SFX.
- The geometry-relative press math (`ComputePressedCFrame`).
- The generation-guarded single-tween press.
- The "each effect is independently nil-safe" rule.

**Change (Grade B):**

- The asset paths
  (`ServerStorage.Assets.Sfx.CashClaim`,
  `ServerStorage.Assets.Vfx.CashClaim`).
- The button hierarchy contract
  (`Stand.Button.PressPart` + `Stand.Button.Base`).
- The `Bases.Collector.Feel` and `Audio.Collect.PoolSize` numbers.
- The `p7:` slot-id prefix and the `SlotType` helpers.
- The `Buy_ArrivalBaseFull` notification id and the
  `TransactionReason.EggRefund` reason name.

**Delete outright if unused:**

- `CollectFeedback` entirely, if your game has no per-stand collect
  button.
- The `TutorialSignals.Fire('EggPlaced', …)` call, if you have no
  tutorial layer.
- The VFX emitter `EmitCount` attribute support, if your burst
  emitters are all `Rate = 0` with a fixed `Lifetime` — but note the
  fallback is `Emit(0)`, i.e. **nothing fires**.
