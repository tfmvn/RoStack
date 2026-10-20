# Collectors — API Reference

Every public function of every module in the Collectors system. The
system has two modules: `ServerScriptService.Base.CollectorArrival` and
`ServerScriptService.Base.CollectFeedback`.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[Dependencies.md](Dependencies.md) · [Setup.md](Setup.md)

**Failure-mode convention.**

- `CollectorArrival.OnArrival` never throws on the documented paths;
  every bail-out returns `false`.
- `CollectFeedback` never throws. `Play` returns a table of booleans;
  every other function returns a value or nothing.

---

## `ServerScriptService.Base.CollectorArrival`

### `CollectorArrival.OnArrival(egg, refs)`

Lands an egg that has just reached its owner's Collector.

- **Parameters:**
  - `egg: any` — the egg record. The fields it reads are
    `uniqueId`, `ownerUserId`, `slotId`, `state`, `model`, `price`,
    `rarity`, `Mutations`, `Trait`, `_aborted`, `_refs`, `_onArrived`.
  - `refs: any` — the egg's `_refs` table
    (`{ playerService, baseService, animalService, slotService }`).
    Read with `refs and refs.x`, so a `nil` `refs` is tolerated (but
    then every arrival lands in the refund path).
- **Returns:** `boolean` — `true` only when the egg ended up **`Placed`**
  on a slot. Every bail-out returns `false`.
- **Failure modes:**
  | Condition | Result |
  |---|---|
  | `egg` is `nil` | `false` |
  | `egg._aborted` is set | `false` |
  | `egg.model` is `nil` or has no `Parent` | `false` |
  | `egg.state` is set and is not `Constants.State.Traveling` | `false` + a warn |
  | The owner cannot be resolved | `false`; the refund is **impossible** (`userId = nil`) but the model is still destroyed and the egg dropped |
  | No slot can hold the egg (Tier 3) | `false`; the cash is refunded, the record removed, the model destroyed, the reservation released, the `Buy_ArrivalBaseFull` toast sent |
  | `OccupySlot` fails after a successful resolve | `false`; the egg is left **`Traveling`** and `_onArrived` does **not** fire |
  | `egg._onArrived` throws | warned; the arrival still returns `true` |
- **Side effects on success:**
  - the egg is teleported into the slot (one `PivotTo`, via
    `HoverMath.Settle`),
  - the stand wobble is bound (`StandPresentation.Bind`),
  - the slot becomes `Occupied`,
  - `egg.slotId` is set and `egg.state` becomes
    `Constants.State.Placed`,
  - `TutorialSignals.Fire('EggPlaced', { EggId, OwnerUserId, SlotId })`
    is called (pcall-guarded),
  - `egg._onArrived(egg, slot, slot.id)` is called (pcall-guarded).
- **Side effects on a Tier-3 bail-out:** `EconomyService.AddMoney`
  with `TransactionReason.EggRefund`, `playerService.RemoveEgg` (by
  the record's own Id, with a by-slot fallback), `slotService.ReleaseSlot`,
  `egg.model:Destroy()`, `SpawnService.DropEgg(egg.uniqueId)`, and the
  `Buy_ArrivalBaseFull` toast.

---

## `ServerScriptService.Base.CollectFeedback`

### `CollectFeedback.Init()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Note:** this is an **empty function**. It exists so a bootstrap can
  call every service's `Init()` uniformly. There is no setup to do.

---

### `CollectFeedback.Play(player, slot)`

Fires all three claim effects. **Call this only on a successful claim
commit.**

- **Parameters:**
  - `player: Player?` — the collecting player.
  - `slot: any` — the slot record. The fields it reads are
    `slot.cashCollector` (a `BasePart`) and `slot.stand` (an
    `Instance`).
- **Returns:** `{ sfx: boolean, vfx: boolean, press: boolean }`.
  - `sfx` — the pooled `Sound` was played.
  - `vfx` — the VFX was **dispatched** (the template resolved). The
    burst itself is asynchronous, so this does **not** mean particles
    emitted.
  - `press` — the button press tween was started.
- **Failure modes:** never throws.
  | Condition | Result |
  |---|---|
  | `player` is not a `Player` | `{ false, false, false }` |
  | `slot` is not a table | `{ false, false, false }` |
  | The player has no `PlayerGui` | `sfx = false`; the press and VFX still run |
  | `slot.cashCollector` is missing / not a `BasePart` / has no `Parent` | no press and no VFX; the SFX still plays |
  | `slot.stand` is missing | no press; the VFX still dispatches |
  | `StandResolver.GetButtonParts` finds no `Base` or no `PressPart` | no press; the VFX still dispatches |
  | The SFX asset is missing | `sfx = false`; a warn fires **once** per server session |
  | The VFX asset is missing | `vfx = false`; a warn fires **once** per server session |
  | The VFX template has no `ParticleEmitter` | `vfx = true`; a warn fires |
  | The projected press gap is below `MinPressTravel` | no press; the SFX and VFX still play |
- **Ordering:** the SFX plays **first and synchronously** (never
  blocked by presentation), then the button press (synchronous), then
  the VFX is **dispatched asynchronously** via `task.spawn` so its
  internal `Heartbeat` replication catch-up never delays the claim
  path.

---

### `CollectFeedback.Warm(player)`

Pre-creates the player's SFX pool.

- **Parameters:** `player: Player?`.
- **Returns:** nothing.
- **Failure modes:** never throws. `nil` or a non-`Player` → no-op. A
  missing `PlayerGui` → no-op.
- **Side effects:** creates `PlayerGui/CashClaimPool` with
  `Audio.Collect.PoolSize` `Sound` children (named `CashClaim1` …
  `CashClaim4` by default). Idempotent — warming twice reuses the
  pool. It also **destroys** a legacy `CashClaimSfx` singleton if one
  is present.
- **Why:** it gives replication + asset download a head start, so the
  first claim does not create-and-play in the same tick.

---

### `CollectFeedback.ForgetPlayer(userId)`

Drops the per-player pool rotation cursor.

- **Parameters:** `userId: number`.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Side effect:** `_nextIndex[userId] = nil`. It does **not** destroy
  the pool folder — that disappears with the player's `PlayerGui`.

---

### `CollectFeedback.ComputePressedCFrame(rest, basePos, fraction?)`

The **pure** press-transform math. Exposed for testing and for reuse
by other presentation code.

- **Parameters:**
  - `rest: CFrame` — the button's canonical rest transform.
  - `basePos: Vector3` — the live position of the `Base` part.
  - `fraction: number?` — the fraction of the gap to travel.
    Defaults to `Bases.Collector.Feel.PressFraction` (`0.45`).
- **Returns:** `CFrame` — the pressed transform, or `rest` unchanged
  when the press is degenerate.
- **Failure modes:** never throws. Returns `rest` when:
  - the projected gap is below `Bases.Collector.Feel.MinPressTravel`
    (`0.05` studs),
  - the projected gap is negative or NaN (the `Base` is level with or
    above the `PressPart`).
- **Behaviour:** the travel is along the **button's own local
  `UpVector`**, so a horizontally offset `Base` produces a pure
  local-Y press (never sideways) and a tilted button presses along its
  own Y.

---

## Test seams

These are `TEST-ONLY` in the source. They are public so the specs can
drive them, but they are not part of the runtime API.

### `CollectFeedback._TestPress(pressPart, base)`

Runs one press cycle against explicit parts.

- **Parameters:** `pressPart: BasePart`, `base: BasePart`.
- **Returns:** `number` — the press **generation** after the press
  (`0` if the part was not registered).
- **Failure modes:** never throws. A degenerate gap returns the
  generation unchanged.

---

### `CollectFeedback._TestFireVfx(pressPart)`

Fires the VFX rig against an explicit part.

- **Parameters:** `pressPart: BasePart`.
- **Returns:** `boolean` — `true` when at least one emitter fired.
- **Failure modes:** a non-`Instance` or a non-`BasePart` → `false`.
  A missing template → `false`.

---

### `CollectFeedback._TestEnsurePool(root)`

Ensures the SFX pool under an explicit container.

- **Parameters:** `root: Instance` — production passes the player's
  `PlayerGui`; a spec can pass any `Instance`.
- **Returns:** `number` — the pool member count.
- **Failure modes:** a non-`Instance` → `0`.

---

### `CollectFeedback._TestPlayPool(root, userId?)`

Plays one pool member under an explicit container.

- **Parameters:** `root: Instance`, `userId: number?` — defaults to
  `0`.
- **Returns:** `(boolean played, string? memberName)`.
- **Failure modes:** a non-`Instance` → `(false, nil)`. A missing
  asset → `(false, nil)` — the pool is still rotated.

---

### `CollectFeedback._TestReset()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effects:** cancels every live tween, clears the button-state
  table, clears the rotation cursors, and drops the cached SFX/VFX
  template refs so the next call resolves them fresh. It does **not**
  reset the "warned once" flags.

---

## Private / internal

Not part of the public surface, but named here so a reader does not
mistake them for API.

### `CollectorArrival`

| Function | Purpose |
|---|---|
| `_resolveOwner(egg)` | `egg.ownerUserId` (validated) → else `SlotType.ParseId(egg.slotId).userId` → else `nil`. |
| `_resolveLandingSlot(egg, refs, userId)` | The three-tier resolution. Returns the slot, or `nil` (→ Tier 3). |
| `_refundAndDrop(egg, refs, userId, reason)` | The Tier-3 teardown: refund → remove the record → release the reservation → destroy the model → drop from the registry → toast. |

### `CollectFeedback`

| Function | Purpose |
|---|---|
| `_resolveSfxSource()` | `ServerStorage.Assets.Sfx.CashClaim` → a `Sound` (directly, or the first `Sound` descendant). Cached; re-resolved if destroyed. |
| `_resolveVfxTemplate()` | `ServerStorage.Assets.Vfx.CashClaim` → an `Attachment` (directly, or the first `Attachment` descendant). Cached; re-resolved if destroyed. |
| `_copySfxProps(target, source)` | Copies the SFX props and stamps the global SFX `SoundGroup`. |
| `_ensurePool(guiRoot)` | Creates / repairs the pool folder and its members. Self-healing. |
| `_playFromPool(guiRoot, userId)` | Round-robin play. Returns `(played, memberName)`. |
| `_playSfx(player)` | `_playFromPool` against the player's `PlayerGui`. |
| `_playVfx(pressPart)` | The whole VFX rig: clone → mount → re-anchor → Heartbeat → emit → Debris. |
| `_cancelLocked(state)` | Disconnects the callback and cancels + destroys the tween. Does **not** bump the generation. |
| `_pressButton(pressPart, base)` | The press state machine (cancel → bump → snap to rest → tween down → hold → tween up → exact restore). |
