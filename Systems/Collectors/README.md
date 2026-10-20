# Collectors

Two server-side modules that own **"what happens when something arrives
at a collector"**:

1. **`CollectorArrival`** — where an egg that has just flown to its
   owner's Collector actually **lands**. It re-validates against the
   base's state *at the moment of arrival* and picks one of three
   landing tiers. If the base cannot hold the egg, the egg is
   **refunded**, not orphaned.
2. **`CollectFeedback`** — the instant **cash-collection** feedback:
   the SFX, the VFX burst, and the button press on the stand.

**Portability:** Grade **A — portable core** for both modules. The
three-tier arrival resolution (reservation intact → re-point to a free
slot → refund and drop) and the "refund rather than orphan" contract
are game-agnostic. Grade **B — game-specific adapter** for the Studio
asset paths (`ServerStorage.Assets.Sfx.CashClaim`,
`ServerStorage.Assets.Vfx.CashClaim`), the button geometry contract
(`Stand.Button.PressPart` / `Stand.Button.Base`), the `p7:` slot-id
prefix, and the `Bases.Collector.Feel` / `Audio.Collect.PoolSize`
tuning values. The **A** parts are the tier resolution, the
persistence re-point, the refund ordering, the pooled SFX
round-robin, the generation-guarded press tween, and the
geometry-relative press math. The **B** parts are the asset paths, the
stand hierarchy, and the tuning numbers.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

### `CollectorArrival` — the three landing tiers

An egg's flight lasts `EggTravelDuration` seconds (7 at the time of
writing), and a base can change a lot in 7 seconds: the owner can grab
an egg off a slot, place an animal, fill the base, or have their
reservation released by an admin command. **So the landing slot cannot
be decided at launch.** `FlightController` targets the Collector and
hands the egg to `CollectorArrival.OnArrival` at flight completion;
this module re-validates against the base's *current* state.

| Tier | Condition | What happens |
|---|---|---|
| **1** | The launch-time reservation (`egg.slotId`) still exists **and** is still `Reserved` | The egg lands there. The persistence record is **left alone**. |
| **2** | The reservation is gone, but another slot is free | The egg lands on the free slot. The **same** persistence record is **re-pointed** to it (identity preserved — never remove-and-add). `egg.slotId` is updated. |
| **3** | Nothing is free | The egg is **refunded**, its persistence record is **removed**, the model is destroyed, the egg is dropped from the spawn registry, the stale reservation is released, and the player gets the `Buy_ArrivalBaseFull` toast. **The egg is never left orphaned over the Collector.** |

Tier 3's *ordering* is load-bearing: the persistence record is
removed **before** the registry drop, so a player who rejoins
immediately does not get an egg restored onto a slot that was never
occupied.

Arrival is **flight completion**, not a `.Touched` signal. Because the
flight's destination *is* the Collector, finishing the flight means
being at it — there is no `Touched` race (an egg clipping a corner of
the Collector part on the way past, or a `Touched` that never fires
because both parts are `CanCollide = false`).

### `CollectFeedback` — the cash-claim presentation

One call — `CollectFeedback.Play(player, slot)` — fires all three
effects **synchronously**, with **zero waits** between the commit and
the feedback:

- **CashClaim SFX** — a **bounded pool of 4 pre-created `Sound`s**
  per player, under `PlayerGui/CashClaimPool`. Each successful claim
  **round-robins** to the next member, so rapid claims overlap
  instead of truncating. Every play re-validates `SoundId` against the
  template (a stale/empty instance is refreshed, never replayed mute).
  The legacy `CashClaimSfx` singleton is destroyed when the pool is
  ensured.
- **CashClaim VFX** — a per-claim **clone** of the
  `CashClaim` attachment, mounted to `Stand.Button.PressPart` (the
  template is never mutated). The burst origin is **re-anchored just
  above the button's live top surface** so particles escape the opaque
  mesh. Every descendant emitter fires with **its own authored
  `EmitCount` attribute** (exact value, fallback `0`).
- **Button press** — `Stand.Button.PressPart` moves toward
  `Stand.Button.Base` along the button's **own local Y**, by a
  **fraction of the live projected gap** (never a hardcoded world
  offset). **One `TweenService` tween per button at a time**: a new
  claim cancels the previous tween, bumps the press generation, snaps
  to the canonical rest CFrame, and tweens down.

`CollectFeedback` fires **only** on a successful authoritative claim
commit. Empty / failed / rejected claims never reach it — so there is
**no silent-feedback path by construction**.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `CollectorArrival.OnArrival(egg, refs)` | Server | The arrival entry point. Returns `true` when the egg ended up `Placed`. |
| `CollectFeedback.Init()` | Server | **A no-op.** Present for symmetry with the other services. |
| `CollectFeedback.Play(player, slot)` | Server | Fires all three effects. Returns `{ sfx, vfx, press }`. |
| `CollectFeedback.Warm(player)` | Server | Pre-creates the player's SFX pool (call at join). |
| `CollectFeedback.ForgetPlayer(userId)` | Server | Drops the pool rotation cursor. |
| `CollectFeedback.ComputePressedCFrame(rest, basePos, fraction?)` | Server | **Pure** press-transform math. Exposed for testing and reuse. |
| `CollectFeedback._TestPress(pressPart, base)` | Server | Test seam — runs one press cycle against explicit parts. Returns the press generation. |
| `CollectFeedback._TestFireVfx(pressPart)` | Server | Test seam — fires the VFX rig against an explicit part. |
| `CollectFeedback._TestEnsurePool(root)` | Server | Test seam — ensures the pool under an explicit container. Returns the member count. |
| `CollectFeedback._TestPlayPool(root, userId?)` | Server | Test seam — plays one pool member. Returns `(played, memberName)`. |
| `CollectFeedback._TestReset()` | Server | Test seam — cancels every tween and drops the cached refs. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Base/CollectorArrival.lua` | `ServerScriptService.Base.CollectorArrival` | The three-tier egg arrival + refund-and-drop path. |
| `Source/ServerScriptService/Base/CollectFeedback.lua` | `ServerScriptService.Base.CollectFeedback` | The cash-claim SFX / VFX / button-press feedback. |

---

## Configuration

This system **does not own a config module** — there is no
`Config.lua` in this folder and no config in its `Source` tree. Its
tunables live in **other systems'** config trees:

| Value | Owned by | Roblox path | Default |
|---|---|---|---|
| `Bases.Collector.Feel.PressFraction` | **BasesAndSlots** | `ReplicatedStorage/Config/World/Bases.lua` | `0.45` |
| `Bases.Collector.Feel.MinPressTravel` | **BasesAndSlots** | same | `0.05` |
| `Bases.Collector.Feel.PressSeconds` | **BasesAndSlots** | same | `0.05` |
| `Bases.Collector.Feel.HoldSeconds` | **BasesAndSlots** | same | `0.05` |
| `Bases.Collector.Feel.ReleaseSeconds` | **BasesAndSlots** | same | `0.1` |
| `Bases.Collector.Feel.VfxSurfaceLift` | **BasesAndSlots** | same | `0.25` |
| `Bases.Collector.Feel.VfxCleanupPadding` | **BasesAndSlots** | same | `0.75` |
| `Bases.Collector.Feel.VfxCleanupMin` | **BasesAndSlots** | same | `1.0` |
| `Bases.Collector.Feel.VfxCleanupMax` | **BasesAndSlots** | same | `5.0` |
| `Audio.Collect.PoolSize` | **SharedUtilities** | `ReplicatedStorage/Config/Presentation/Audio.lua` | `4` |
| `Debug.Audio.Enabled` | **SharedUtilities** | `ReplicatedStorage/Config/Systems/Debug.lua` | `false` |
| `Bases.Collector.PartColor` / `.Height` / `.Transparency` / `.AmountTextColor` / `.PoolChip` | **BasesAndSlots** | `ReplicatedStorage/Config/World/Bases.lua` | — |
| `TransactionReason.EggRefund` | **Shared** | `ReplicatedStorage/Types/TransactionReason.lua` | — |

`Bases.Collector.Feel` was moved out of `AudioConfig.Collect` — the
comment in `Bases.lua` says so explicitly: *"The SFX pool size stays in
Presentation.Audio (Audio.Collect.PoolSize)."* The SFX pool size and
the press feel are deliberately in **different** config modules.

---

## Dependencies

See `Dependencies.md` for the exact require paths. The load-bearing
ones:

- `ServerScriptService.Egg.HoverMath` — `Settle` (the single
  `PivotTo` into the slot's seated CFrame).
- `ServerScriptService.StandPresentation` — `Bind` (the stand wobble).
- `ServerScriptService.Egg.Constants` — `Constants.State.Traveling` /
  `.Placed`.
- `ServerScriptService.Egg.SpawnService` — `DropEgg` (required **lazily**
  inside `_refundAndDrop` to break a require cycle).
- `ReplicatedStorage.Utility.StandResolver` — `GetButtonParts`.
- `ReplicatedStorage.Utility.AudioGroups` — `AssignSfx`.
- `ServerScriptService.EconomyService` — the refund (**required at the
  top level**, not injected).

`CollectorArrival` takes its collaborators through the **`refs`
argument** (`egg._refs`: `playerService`, `baseService`,
`animalService`, `slotService`), not through module-level requires.
That is what keeps it testable with fakes and free of the service
require cycle.

---

## Initialization Order

`CollectorArrival` has **no** init function — it is invoked by
`FlightController._onComplete`.

`CollectFeedback` has an `Init()` that is **an empty function**. The
only real setup is:

```text
1.  Player joins
      -> CollectFeedback.Warm(player)     -- pre-create the SFX pool
2.  Player leaves
      -> CollectFeedback.ForgetPlayer(userId)
3.  On a successful claim commit
      -> CollectFeedback.Play(player, slot)
```

`Warm` is optional but recommended: creating the pool at join gives
replication + asset download a head start, so the first success does
not create-and-play in the same tick.

---

## Data

**Neither module reads or writes any profile field directly.**

`CollectorArrival` **mutates** the profile through `PlayerService` (it
does not own the profile):

| Call | When | Effect |
|---|---|---|
| `playerService.SetEggSlot(userId, egg.uniqueId, newSlotId)` | Tier 2 | Re-points the **same** record to the new slot. Identity preserved. |
| `playerService.AddEgg(userId, slotId, rarity, uniqueId, { Mutations, Trait })` | Tier 2 fallback | Only if `SetEggSlot` failed (the record was genuinely missing). Passes the runtime's own Id explicitly so it can never mint a duplicate. |
| `playerService.RemoveEgg(userId, egg.uniqueId)` | Tier 3 | Removes the record **by its own Id** (the persistence key). |
| `playerService.RemoveEggAtSlot(userId, egg.slotId)` | Tier 3 fallback | Only if `RemoveEgg` found nothing. |

`CollectFeedback` owns **no** persistent state. Its runtime state is:

| State | Shape | Meaning |
|---|---|---|
| `_nextIndex` | `{ [userId]: number }` | The SFX pool round-robin cursor. |
| `_buttons` | `{ [BasePart]: ButtonState }` (weak keys) | Per-button press state: `rest`, `generation`, `tween`, `conn`. |
| `_sfxSource` / `_vfxTemplate` | cached `Sound?` / `Instance?` | Resolved template refs, re-resolved if destroyed. |

### The `slot` shape that `CollectFeedback.Play` expects

```lua
slot.cashCollector   -- BasePart (the collector part itself)
slot.stand           -- Instance (the stand model)
```

`Play` reads `slot.cashCollector` to find the press part and
`slot.stand` to resolve `Button.Base` / `Button.PressPart` through
`StandResolver.GetButtonParts`.

---

## Known Limitations

- **`CollectorArrival` requires `EconomyService` at the top level.**
  It is a hard `require`, not an injection. The module fails to load
  if `EconomyService` is missing — even when the refund path is never
  taken.
- **`CollectorArrival` calls `slotService.OccupySlot` without a nil
  check** on `slotService` (step 6). If `refs.slotService` is `nil`,
  the earlier `_resolveLandingSlot` returns `nil` and the module
  takes the refund path — so this is unreachable in practice, but the
  asymmetry is real: `_resolveLandingSlot` nil-checks, step 6 does
  not.
- **Tier 3 refunds but does not re-open the purchase.** The player gets
  their cash back and a `Buy_ArrivalBaseFull` toast; they must buy
  again manually. There is no automatic retry.
- **Tier 3's refund is skipped if the price is malformed.**
  `BigNumber.sanitize(tostring(egg.price))` returning `nil` skips the
  refund entirely (with a warn). The player loses at most one egg's
  price — deliberately, so a bad price can never corrupt the balance.
- **Tier 2 can still fail.** `GetFreeSlot` can return `nil` (base
  full) or `ReserveSlot` can return `false` (a race). Both fall
  through to Tier 3.
- **The `OccupySlot` race leaves the egg `Traveling`.** If the slot
  changes between the resolve and the occupy, the egg is **not**
  committed to `Placed` and `_onArrived` does **not** fire. This is
  deliberate — `Traveling` is what makes `SpawnService.ForceReleaseBase`
  willing to clean the egg up later. Committing `Placed` would strand
  it forever.
- **`CollectorArrival` does not own the flight.** It has no reference
  to the flight controller and never reads the controller record.
- **`CollectFeedback.Play` returns `vfx = true` when the *template
  resolves*, not when particles actually emit.** The burst itself is
  dispatched asynchronously via `task.spawn`, so the return value says
  "dispatched", not "fired".
- **`CollectFeedback.Play`'s VFX dispatch is asynchronous but its SFX
  and press are synchronous.** The order is deliberate: the SFX plays
  first and synchronously (never blocked by presentation), then the
  button press, then the VFX asynchronously.
- **`CollectFeedback.Play` returns `{ sfx = false, vfx = false,
  press = false }` for a bad `player` or a non-table `slot`** — and it
  never throws.
- **The VFX does one `RunService.Heartbeat:Wait()`.** This is the
  replication catch-up: `Emit` on a brand-new instance in the same
  tick as parenting can be missed by clients it has not replicated to
  yet. It is ~16ms and imperceptible, but it *is* a yield inside the
  VFX path — which is why the VFX is `task.spawn`ed off the commit
  path.
- **`CollectFeedback.Play` needs the claim to have already
  committed.** It is called by `IncomeService.TryCollect` *after*
  `AddMoney` succeeds and the pool zeroes. Empty / failed / rejected
  claims never reach it.
- **The press math is degenerate-safe but not size-safe.** If the
  projected gap is below `MinPressTravel` (`0.05` studs) the press is
  skipped entirely — but the SFX and VFX still play.
- **A `Base` that is level with or above the `PressPart` produces no
  press.** `travel` would be `<= 0`, so `ComputePressedCFrame` returns
  the rest transform.
- **The press never goes sideways.** The travel is computed along the
  button's own local `UpVector`, so a horizontally offset `Base`
  produces a pure local-Y press.
- **Only one tween per button at a time.** A new claim cancels the
  previous tween, disconnects its callback, bumps the generation, and
  **snaps to the canonical rest CFrame** before tweening down. Spam
  can therefore never accumulate offsets or strand the button.
- **The generation counter is per button.** A stale callback re-checks
  both the generation **and** the tween's `PlaybackState`, so a
  cancelled tween can never move the button after a newer press
  started.
- **`_buttons` uses weak keys**, so a destroyed stand does not pin
  memory. But the `rest` CFrame is cached on **first sight** — if
  something else in the game moves the button later, the press will
  fight it.
- **The SFX pool is per player and lives in their `PlayerGui`.** The
  server writes into the client's `PlayerGui` (creating `Sound`
  instances there). That is unusual but necessary: the `Sound` must
  exist on the client to be heard, and the template is server-only.
- **The SFX pool size is a fixed bound.** `POOL_SIZE = 4` and it
  never grows. If a player could legitimately collect more than 4
  times simultaneously, voices would be reused and a claim would cut
  off the previous one. The shipped tuning assumes collections at most
  ~1/s apart (the income tick).
- **The legacy `CashClaimSfx` singleton is destroyed** when the pool is
  ensured. Any other code that expects that singleton will break.
- **Missing assets are warns, not errors.** A missing
  `ServerStorage.Assets.Sfx.CashClaim` means claims run **mute**; a
  missing `ServerStorage.Assets.Vfx.CashClaim` means claims run
  without VFX. Each is warned **once** per server session.
- **The VFX template must contain at least one `ParticleEmitter`.** If
  it does not, a warn fires
  (`'CashClaim VFX has no ParticleEmitter — investigate asset
  reference/path'`). The clone still mounts and is still cleaned up.
- **Lights and beams are switched on** for the burst lifetime
  (`Enabled = true` on the clone only; the template is untouched).
- **The VFX cleanup lifetime is
  `clamp(longestEmitterLifetime + VfxCleanupPadding, VfxCleanupMin,
  VfxCleanupMax)`** — i.e. between 1.0 and 5.0 seconds by default.
- **`CollectFeedback.Init()` does nothing.** It exists so a bootstrap
  can call every service's `Init()` uniformly.

---

## Testing

### `Tests/CollectorArrival.spec.lua`

Covers the three tiers and the surrounding contract:

- **Landing CFrame** — the egg lands on the slot's **seated** CFrame
  (`GroundedCFrameOnSlot`): bottom-flush on the slot's top surface,
  zero gap, in the slot's rotation.
- **Tier 1** — the reservation is intact: the egg lands on the
  reserved slot, the slot is `Occupied`, and the **persistence record
  is unchanged**.
- **Tier 2** — the reservation is gone but another slot is free: the
  egg lands on the free slot, the **same** persistence record is
  re-pointed (identity preserved — never remove-and-add), and
  `egg.slotId` is updated.
- **Tier 3** — no free slot: the cash is refunded at the full price,
  the persistence record is **removed** (no phantom egg on rejoin), the
  model is destroyed, the egg is dropped from the spawn registry, the
  stale reservation is released (the slot is back to `Empty`), and
  arrival returns `false`.
- **Owner resolution** — falls back to `SlotType.ParseId(egg.slotId).userId`
  when `ownerUserId` is missing.
- **OccupySlot race** — when `OccupySlot` fails after a successful
  resolve, the egg stays **`Traveling`** (not `Placed`) and
  `_onArrived` does **not** fire.

The spec uses the real `SlotService` (via `Helpers.WireServices`) and a
**fake `PlayerService`** backed by in-memory record lists, so the
persistence assertions are **state-based** (one record, same Id, right
`SlotId`) rather than call-based.

### `Tests/CollectFeedback.spec.lua`

- **`ComputePressedCFrame`** — moves toward `Base` along local Y by a
  fraction of the gap; never moves sideways when `Base` is offset
  horizontally; respects the button's own orientation (a tilted button
  presses along its own Y); returns rest for degenerate gaps (`Base`
  level with or above `PressPart`); honours an explicit fraction.
- **`Play`** — never throws on bad input and reports nothing fired;
  skips gracefully when the assets are missing (no `ServerStorage`
  setup).
- **Button spam determinism** — bumps exactly one generation per press
  on a single button; returns exactly to rest after rapid spam with no
  drift; never travels below the pressed transform or above rest.
- **VFX rig** — mounts clones under `PressPart` with the burst **above
  the button's top surface**.
- **SFX pool** — creates a bounded pool of **4** and warming is
  idempotent; round-robins rapid plays across distinct members (no
  restart truncation); refreshes a stale member `SoundId` instead of
  replaying mute; removes the legacy singleton when the pool is
  ensured; `Warm(nil)` and `ForgetPlayer` never throw.

Both specs require the shared `Tests/_Helpers.lua` and still require
**Roblox Studio**. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Keep the tier structure.** The point of the three tiers is that
   the world can change during the flight. If your flight is instant,
   you can still keep tier 1 as the fast path and tier 3 as the
   safety net.
2. **Keep the "refund, never orphan" contract.** A tier-3 arrival that
   leaves the egg floating over the Collector is a support ticket. If
   your game has no money, replace the refund with a "return to the
   player's inventory" or a "retry next tick" instead.
3. **Re-point the record, never remove-and-add.** Tier 2 must mutate
   the existing record's slot. Minting a new record creates a phantom
   on rejoin. If your persistence layer has no in-place setter, add
   one before porting this.
4. **Keep the record removal keyed by the record's own Id**, not by
   the slot id. The by-slot fallback is only for the load-time
   re-keyed case.
5. **Port the press geometry as-is.** `ComputePressedCFrame` is pure
   and geometry-relative; it adapts to any button the player authors.
   Change `PressFraction` and `MinPressTravel` in
   `Bases.Collector.Feel` to taste.
6. **Author the two assets** at
   `ServerStorage.Assets.Sfx.CashClaim` (a `Sound`, or a container with
   a `Sound` inside) and `ServerStorage.Assets.Vfx.CashClaim` (an
   `Attachment`, or a container with one inside). Both resolvers accept
   either shape.
7. **Give each VFX emitter an `EmitCount` attribute.** The value is
   used **exactly** — it is never scaled or normalized. An emitter
   without the attribute fires `Emit(0)`, i.e. nothing.
8. **Author your stand button as
   `Stand.Button.PressPart` + `Stand.Button.Base`.** `StandResolver`
   resolves them by name; a missing `Base` means no press.
9. **Decide whether the SFX pool lives in the `PlayerGui`.** It must,
   if you want the client to hear it — the server creates the `Sound`
   instances there. `Audio.Collect.PoolSize` controls the bound.
10. **Consider dropping `CollectFeedback` entirely** if your game has
    no per-stand collect button. It is presentation, and it is
    independently discardable (the claim commit is owned by
    `IncomeService`).
