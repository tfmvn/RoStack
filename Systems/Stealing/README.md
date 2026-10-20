# Stealing

Owns **"player B takes an egg or animal from player A's base"** — the steal
request, the atomic reservation, the carry, the delivery, and every way the
transaction can be rolled back.

**Portability:** Grade **A — portable core** for the transaction machinery
(`CanSteal` validation, the `TrySteal` reservation block, the `TryComplete`
profile transfer, the three-tier `RollbackCarried`); Grade **B — game-specific
adapter** for the config values, the notification catalog ids, the record
`state` vocabulary, the Studio SFX name, and the `p7:` slot-id prefix. The
**A** parts are the ordering, the atomicity, and the failure policy — they
encode *rules*, not tuning. The **B** parts are `Config/World/Stealing.lua`,
the `Steal_*` message ids in `Config/Presentation/Messages.lua`, the literal
state strings `'Placed' / 'Slotted' / 'Opening' / 'Carried' / 'Recovering'`,
the `ServerStorage.Assets.Sfx.Stealing` asset name, and the `SlotType`
`'egg' | 'animal'` kinds.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

`StealService` is a **server-authoritative** stealing loop. Player B walks
onto player A's base, sees a **Steal** prompt (non-owners only), presses E,
carries the object with the game's **existing** carry system, walks it to
**B's own collector**, touches it, and ownership transfers A → B with the
object's id and progression intact.

The design principle:

> **The steal reuses the carry system, the slot system, and the profile
> system. It adds no second carry, no second slot, and no second profile.**

- **One carry.** A steal is a `CarryRegistry` item with a `steal` metadata
  table. A normal carry and a steal carry can never coexist — `Set` rejects
  while the player is carrying.
- **One atomic reservation.** `SlotService.DemoteSlotToReserved` is the
  single point where the victim's slot flips `Occupied → Reserved`. Exactly
  one of `{B-steal, C-steal, A-grab}` can win; the losers get `'slot-race'`.
  `CanSteal` and `TrySteal`'s commit block contain **no yields**, so the
  steal-start transaction is atomic.
- **One destination.** The thief's free slot is reserved **at steal start**,
  in the same yield-free block. A steal can never strand its carrier with
  nowhere legal to deliver, and two concurrent steals can never commit into
  one destination.
- **Touch-only delivery.** There is **no Deliver prompt**. The thief
  physically touches their own `Collector` part; the `Touched` connection
  routes to `TryComplete`, which re-validates everything server-side.
- **No duplication, ever.** Before the transfer the record still names A as
  the owner and A's profile still holds it. The transfer order is
  `Occupy(dest) → Add(B) → Remove(A) → release(src) → seat`. Any failure
  before `Remove(A)` leaves A owning everything; any failure after it undoes
  the `Add` before surfacing the error.

Everything is **event-driven**: a prompt `Triggered`, a collector `Touched`,
a death hook, a leave hook. No `Heartbeat`, no polling, no per-player loops,
no `GetDescendants` in any path.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `StealService.SetPlayerService(svc)` | Server | Injects the profile authority. Called once by the bootstrap. |
| `StealService.Init()` | Server | Wires the Steal-prompt callback into `CarryPrompts`. Idempotent-ish (replaces the callback). |
| `StealService.Start()` | Server | Arms one `Touched` connection per base collector. **Must run after `BaseService.RegisterBases`** — it only sees the bases that exist at call time. |
| `StealService.ForgetPlayer(userId)` | Server | Clears the rate-limit window and the walkspeed snapshot. **See Known Limitations — this function currently throws.** |
| `StealService.CanSteal(thiefUserId, occupantId, kind?, thiefPosOverride?)` | Server | Pure validation. No mutation, no yields. Returns `{ok=true, record, slot, ownerId}` or `{ok=false, error=<code>}`. |
| `StealService.TrySteal(player, occupantId, kind?)` | Server | The steal request. Returns `{success=true}` or `{success=false, error=<code>}`. |
| `StealService.TryComplete(player)` | Server | The delivery. Returns `{success=true, slotId}` or `{success=false, error=<code>}`. |
| `StealService.RollbackCarried(thiefUserId, reason?)` | Server | Returns a steal-carried object to its original owner. Returns `{success=true}` / `{success=true, completed=true}` / `{success=true, parked=true}` / `{success=false, error}`. |
| `StealService.RollbackIfStealing(userId, reason?)` | Server | `true` if the user was steal-carrying (and was rolled back); `false` if not — the caller then runs its normal recovery path. |
| `StealService.RollbackStolenTarget(kind, uniqueId, reason?)` | Server | Owner-side hook. `true` if the `(kind, id)` object is currently steal-carried by anyone (and was rolled back home). |
| `StealService.IsStolenRecord(kind, uniqueId)` | Server | `true` if the `(kind, id)` object is currently steal-carried. Scans the carry registry — rare calls only. |
| `StealService.IsStealCarry(playerOrUserId)` | Server | `true` if this player's carry item is a steal in progress. |
| `StealService._TestVictimText(thiefName, animalName, rarity?)` | Server | Test-only seam. Builds the victim robbery text through the real formatter path. |
| `Stealing.Validate()` | Config | Returns an array of human-readable config issues. Empty array = valid. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Steal/StealService.lua` | `ServerScriptService.Steal.StealService` | The whole steal system. |
| `Source/ReplicatedStorage/Config/World/Stealing.lua` | `ReplicatedStorage.Config.World.Stealing` | **This system's config** — cooldown, alert cleanup, thief speed multiplier, camera presentation. |
| `Tests/StealService.spec.lua` | `Tests/ServerScriptService/TestEZTests/StealService.spec.lua` | The spec. Requires the shared `Tests/_Helpers.lua`. |

---

## Configuration

This system **does** own a config module:
`ReplicatedStorage/Config/World/Stealing.lua`. It is reproduced (with the
per-field commentary) in [`Config.lua`](Config.lua).

| Value | Default | Meaning |
|---|---|---|
| `Stealing.Cooldown` | `0.5` | Anti-spam window, in seconds. At most one steal **request** per player per window. |
| `Stealing.AlertCleanupPad` | `0.5` | Extra seconds added to the robbery-alert SFX length before `Debris:AddItem` cleanup. |
| `Stealing.AlertFallbackCleanup` | `3` | Fallback SFX lifetime (seconds) when `Sound.TimeLength` is unreadable. |
| `Stealing.StealSpeedMultiplier` | `0.6` | WalkSpeed multiplier applied to the thief while steal-carrying. Relative, so an admin-set speed survives the round trip. |
| `Stealing.StealPresentation.FOVMultiplier` | `0.9` | Camera FOV multiplier while steal-carrying an **animal**. Read by the **client** `StealPresentationController` (ClientPresentation system), never by the server. |
| `Stealing.StealPresentation.FOVTweenTime` | `0.3` | Seconds for the FOV tween each way. Client-only. |

Values that live in **other** systems' configs but are read by this one:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `Prompts.CarryMaxDistance` | `Config/World/Prompts.lua` (Carry) | `8` | Server-side distance limit for a steal request and for the delivery proximity check. |
| `Prompts.AnimalPickup.MaxActivationDistance` | `Config/World/Prompts.lua` (Carry) | `8` | Distance limit used for **animal** steals (eggs use `CarryMaxDistance`). |
| `Prompts.Steal.*` | `Config/World/Prompts.lua` (Carry) | `'Steal'`, hold `2.5`, 8 studs, `E`, Y offset `0` | The Steal `ProximityPrompt` definition. |
| `Audio.StealAlertSoundName` | `Config/Presentation/Audio.lua` (SharedUtilities) | `'Stealing'` | The `ServerStorage.Assets.Sfx.<name>` template played to the robbed owner. |
| `Debug.Audio.Enabled` | `Config/Systems/Debug.lua` (SharedUtilities) | `false` | Whether the SFX clone is logged. |

`Stealing.Validate()` checks `Cooldown`, `AlertFallbackCleanup`,
`StealSpeedMultiplier`, and both `StealPresentation` fields. It does **not**
validate `AlertCleanupPad` — that value is never sanity-checked anywhere.

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the exact require paths, the
remotes, the profile fields, and the Studio assets. The load-bearing ones:

- `ServerScriptService.Carry.CarryRegistry` — **the one carry state**.
- `ServerScriptService.Base.SlotService` — the slot state machine
  (`DemoteSlotToReserved`, `ReserveSlot`, `OccupySlot`, `ReleaseSlot`,
  `GetFreeSlot`, `RefreshDisplays`).
- `ServerScriptService.BaseService` — base ownership, the `collector` part,
  the base's slot list.
- `ServerScriptService.Animal.CarryController` — the weld/follow behavior
  (unchanged by stealing).
- `ServerScriptService.Animal.CarryPrompts` — the Steal prompt installer and
  the callback registry.
- `ServerScriptService.Animal.AnimalOverhead` — the temporary `STOLEN`
  look on a stolen animal (presentation only).
- `ServerScriptService.Egg.SpawnService` / `ServerScriptService.Egg.HoverMath` /
  `ServerScriptService.AnimalService` — egg and animal seating.
- `ServerScriptService.Arena.ArenaService` — the **raid lock** (an animal
  fighting in an active raid cannot be stolen).
- `ServerScriptService.Base.NotificationService` — the canonical rejection
  and success messages.
- `ServerScriptService.FunnelService` — the `StealSucceeded` analytics step.
- The **profile authority** (`PlayerService`), injected via
  `SetPlayerService` — it supplies `GetEggs` / `GetAnimals` / `AddEgg` /
  `AddAnimal` / `RemoveEgg` / `RemoveAnimal` / `SetEggSlot` /
  `SetAnimalSlot` / `PushState` / `Notify`.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  BaseService.RegisterBases(Workspace)   -- collectors must exist
3.  EggService.RegisterCenter(Workspace)
4.  StealService.SetPlayerService(PlayerService)
5.  StealService.Init()                    -- wires the prompt callback
6.  StealService.Start()                   -- arms the collector Touched routing
7.  ArenaService.SetStealService(StealService)   -- later; arena needs it
```

**The order matters in two places.**

- `Start()` iterates `BaseService.GetAllBases()` **once**. A base that is
  registered *after* `Start()` gets **no** `Touched` routing, so it can
  never be a delivery target. `Start()` is therefore order-dependent on
  `RegisterBases`, and it is **not** re-run when a base is added later.
- `Init()` must run before any `ProximityPrompt` can fire the Steal
  callback. The prompt itself is installed by `CarryPrompts`, not by this
  system; only the callback is.

**On player death** (in `bootstrap.server.lua`):

```text
Humanoid.Died
  -> StealService.RollbackIfStealing(userId, 'death')   -- true: steal, done
  -> else the normal AnimalService / EggService carry recovery
```

**On player leave / owner leave / rebirth:** `RollbackIfStealing` (thief
side) and `RollbackStolenTarget` (owner side) must run **before** the base
teardown, so the object lands home while its slot still exists.

---

## Data

**No profile fields are owned by this system.** The steal moves records
between two players' existing owned-object lists; it never writes a new
field.

### Profile records read

| Call | When | Fields read |
|---|---|---|
| `GetEggs(ownerId)` | `TryComplete` | `Id`, `Rarity`, `Mutations`, `Trait` |
| `GetAnimals(ownerId)` | `TryComplete` | `Id`, `DefId`, `Level`, `XP`, `CashPool`, `Trait`, `Mutations` |

### Profile records written

| Call | When | Fields written |
|---|---|---|
| `AddEgg(thiefId, slotId, rarity, id, opts)` | `TryComplete` | `opts.Mutations`, `opts.Trait` (plus `Rarity`, `Id`, `SlotId` positionally) |
| `AddAnimal(thiefId, slotId, defId, id, opts)` | `TryComplete` | `opts.Level`, `opts.XP`, `opts.CashPool`, `opts.Trait`, `opts.Mutations` |
| `RemoveEgg(ownerId, id)` | `TryComplete` | — |
| `RemoveAnimal(ownerId, id)` | `TryComplete` | — |
| `SetEggSlot(ownerId, id, slotId)` | `RollbackCarried` tier-2 | `SlotId` |
| `SetAnimalSlot(ownerId, id, slotId)` | `RollbackCarried` tier-2 | `SlotId` |

The record **id is preserved** across the transfer — B receives the *same*
`Id` the object had under A. Only `SlotId` legitimately changes.

### Runtime record fields the steal touches

| Field | Set to | When |
|---|---|---|
| `record.state` | `'Opening'` (egg) / `'Carried'` (animal) | steal start |
| `record.state` | `'Placed'` (egg) / `'Slotted'` (animal) | rollback, completion |
| `record.state` | `'Recovering'` | rollback tier-3, animal only |
| `record.carriedBy` | thief userId | steal start; `nil` on every exit |
| `record.stolenBy` | thief userId | steal start; `nil` on every exit. A **cache flag** — `CarryRegistry` is authoritative. |
| `record.originalSlotId` | the victim's slot id | steal start; `nil` on every exit |
| `record.slotId` | the destination slot id | completion / rollback |
| `record.ownerUserId` | the thief | completion only |
| `record.controller` / `record.controllerType` | the carry controller | steal start (`'Carry'`) |
| `record._mutex` | `true` during the commit | steal start / completion |

### `CarryRegistry` item shape for a steal

```lua
{
    kind = 'egg' | 'animal',
    record = <the live runtime record>,
    originalSlotId = <the victim's slot id>,
    startedAt = os.clock(),
    steal = {
        originalOwnerUserId = <number>,
        originalBaseId = <string>,
        destSlotId = <string?>,      -- the reserved destination
        carryCharacter = <Model>,    -- the character this steal attached to
    },
}
```

The **presence** of the `steal` table is what marks the carry as a steal.
`carryCharacter` is the identity guard: a respawned character (same
`UserId`, new `Model`) can never continue or complete a pre-death
transaction — it rolls back instead.

---

## Known Limitations

- **`StealService.ForgetPlayer` throws.** `_thiefSpeed` is declared at
  `StealService.lua:587`, but `ForgetPlayer` (line 442) reads it at line
  444 — **before** the declaration. Lua locals are only in scope from their
  declaration onward, so line 444 indexes a **global** `_thiefSpeed`, which
  is `nil` → `attempt to index global '_thiefSpeed' (a nil value)`. The
  function is never called by the bootstrap, so production never notices;
  the spec calls it in `setup()` (`StealService.spec.lua:215-216`) and that
  call is expected to throw. Fix: move the `local _thiefSpeed` declaration
  up to the internal-state block (line ~115) next to `_lastAttempt`.
- **`StealService.Start()` is one-shot.** It arms `Touched` routing for the
  collectors that exist at the moment it runs. A base registered later
  (a new arena base, a late `RegisterBases`) is **never** a delivery
  target, and there is no `OnBaseRegistered` hook to re-arm it. Calling
  `Start()` again is safe (the `_touchedConnected` map makes it
  idempotent) but must be called manually.
- **The victim is alerted twice on a successful steal.** Once at steal
  start (`_playStealSfxForOwner` + the robbery text) and again at delivery
  completion (`_notify(ownerPlayer, 'Warning', ...)`). The second one is
  intentional ("delivery committed") but the wording is identical, so the
  owner sees the same sentence twice.
- **`_playStealSfxForOwner` parents the SFX clone to the owner's
  `PlayerGui`.** A server-parented `PlayerGui` child replicates to that
  client only — that is the intended "victim hears it, nobody else does"
  mechanism. It is also the only way the sound reaches the victim at all,
  and it means the sound is **not** audible to the thief or to bystanders.
- **The robbery SFX is best-effort.** A missing asset, a malformed asset, a
  `Sound` with an empty `SoundId`, or an offline owner all produce a
  **silent no-op** with a `Debug.Warn`. Only a successful steal start ever
  reaches it, so it fires **exactly once per success**.
- **The victim's `state` string vocabulary is hardcoded.** `'Placed'`,
  `'Slotted'`, `'Opening'`, `'Carried'`, `'Recovering'` are literal strings
  in `StealService`. They must match the strings used by `SpawnService`,
  `AnimalService`, `EggService`, and `AnimalService.PlaceAnimal` /
  `EggService.PlaceEgg`. A new game that renames them breaks stealing
  silently (the state check just never passes).
- **`CanSteal` accepts a `thiefPosOverride`** purely for tests. Nothing in
  production passes it, and it bypasses the HRP read — a caller that
  supplies a position is asserting the thief's location, not measuring it.
- **The distance check uses the *slot part*, not the record's model.** The
  measured distance is `HRP → slot.part.Position`. A model that visually
  overhangs its slot is effectively farther away than it looks.
- **`Prompts.Steal.HoldDuration` is `2.5` seconds** — but the config's own
  comment says *"INSTANT (hold 0)"*. The comment is stale, the value is
  `2.5`. A new game copying the comment will ship the wrong hold time.
- **The steal never re-validates the destination at commit time.** The
  destination is proven free at steal start and reserved atomically; the
  reservation is trusted for the whole carry. If another system force-frees
  a `Reserved` slot, the completion falls back to a fresh `GetFreeSlot` and
  logs a `Debug.Warn` (it does not fail outright) — but the object can land
  in a different slot than the one reserved.
- **`RollbackCarried` tier-3 parks the object without a slot.** An animal
  enters `Workspace/Animals/Recovering` with `state = 'Recovering'`; an egg
  parks `Placed` with `slotId = nil` in the `ActiveEggs` container. Nothing
  is deleted and the profile is kept, so a rejoin respawns from the intact
  profile — but until then the object is un-interactable.
- **The `Debug` tag is `'ST'`, which is not in the documented tag list.**
  `Config/Systems/Debug.lua:51` lists `BS, LB, BR, PS, RM, CL, AO, CP`. If
  `Debug.Tags` is ever set to a non-empty whitelist without adding `'ST'`,
  **every** steal log line is silently dropped.
- **`Stealing.AlertCleanupPad` is never validated** by
  `Stealing.Validate()`. A negative value makes the SFX clone get destroyed
  before it can play.
- **There is no `FailSteal`/cancel entry point.** The only ways out of a
  steal are death, leave, `RollbackIfStealing`, `RollbackStolenTarget`, or
  a successful delivery. A player who wants to drop the stolen object
  cannot.
- **The system assumes exactly one `Collector` per base** and that the
  collector is a `BasePart`. A base whose `collector` is missing or is not
  a `BasePart` can never be a delivery target and is silently skipped by
  `Start()`.

---

## Testing

`Tests/StealService.spec.lua` (1323 lines). It uses the **real** wired
services, real bases, real slots, and real models; only the **profile layer
is faked** (a call-capturing stub injected through
`StealService.SetPlayerService`).

Covered:

- `CanSteal` validation: ok / `own-object` / `wrong-kind` / `invalid-target`
  / `target-gone` / `already-carrying` / `not-stealable-state` / `too-far` /
  `no-destination` / `slot-race`.
- **A locked base still allows steal-start** — the lock is an escape
  restriction, not a pickup restriction.
- Atomicity: a demoted (`Reserved`) slot rejects the second stealer.
- Rollback tier-1 (re-occupy the original slot, prompts restored, registry
  cleared), tier-2 (fallback slot, profile re-pointed, no overwrite), and
  the tier-3 park.
- Rollback releases the reserved destination slot; double rollback is a
  safe no-op; death spam after rollback leaves no steal residue.
- The stolen-animal overhead is restored to its exact prior look.
- `TryComplete` egg transfer A → B under the same `Id`, no duplicate; the
  original slot released; the model re-homed to `ActiveEggs`.
- `TryComplete` animal transfer preserves
  `Level`/`XP`/`CashPool`/`Trait`/`Mutations`/`DefId`/`Id` exactly.
- `TryComplete` failure atomicity: a jammed destination mutates **nothing**
  and the same carry completes cleanly on retry.
- Owner-leave recovery: the object is recovered home **before** the sweep.
- The Steal prompt is installed alongside Pickup, with the
  `stealPrompt` / `ownerUserId` attributes, and replicates **disabled**
  (fail-closed) so the owner never sees a Steal flash.
- `PlaceEgg` rejects a steal-carried egg with `'steal-in-progress'`.
- Completion is touch-only: `CarryPrompts.InstallDeliverPrompt` /
  `RemoveDeliverPrompt` / `SetDeliverPromptCallback` and
  `Prompts.Carry.ActionText.Deliver` are all **absent**.
- The victim robbery text contains the thief and the rarity-colored animal
  in danger red, and escapes markup in names.

Not covered (deliberately): the live-character `TrySteal` happy path (it
needs real `Player` instances and network ownership — it lives in the
multiplayer playtest matrix) and the full `TryComplete` attach path.

The spec requires the shared `Tests/_Helpers.lua` and still requires
**Roblox Studio**. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Keep the transaction order.** `Occupy(dest) → Add(B) → Remove(A) →
   release(src) → seat`. The old order (profiles first) produced a
   split-brain when the seat failed: B's profile owned the `Id` while the
   runtime record still named A. Occupy-first makes a failed seat mutate
   nothing.
2. **Keep the destination reservation at steal start**, not at delivery.
   A steal that only checks capacity at delivery time can strand its
   carrier with nowhere legal to deliver.
3. **Keep `carryCharacter`.** The `UserId` survives respawns; the character
   `Model` instance does not. Without the identity check, a respawned
   player can complete a pre-death transaction.
4. **Keep the steal inside the existing carry system.** A second carry
   state is the single most expensive mistake you can make here — every
   death, leave, and reset path in the game already knows about
   `CarryRegistry`.
5. **Keep completion touch-only.** A Deliver prompt is a second input path
   that has to be guarded, rate-limited, and revoked on every exit.
6. **Rewrite the state vocabulary.** Replace the literal strings
   `'Placed' / 'Slotted' / 'Opening' / 'Carried' / 'Recovering'` with your
   own enum, and update `SpawnService`, `AnimalService`, `EggService`, and
   `AnimalOverhead` to match.
7. **Re-author the robbery SFX** at
   `ServerStorage/Assets/Sfx/<Audio.StealAlertSoundName>`. The system reads
   the name from config and never hardcodes the asset — but a missing asset
   is a silent no-op, so author it.
8. **Port the notification ids.** The system sends
   `Steal_Success`, `Steal_DeliverySuccess`, `Steal_Cooldown`,
   `Steal_OwnAnimal`, `Steal_AlreadyCarrying`, `Steal_BaseFull`,
   `Steal_BaseLocked`, `Steal_TooFar`, `Steal_TargetBusy`,
   `Steal_TargetGone`, and `General_Generic`. Add them all to your message
   catalog, or the notification layer will drop them.
9. **Fix `ForgetPlayer` before you ship it.** Move the `_thiefSpeed`
   declaration up next to `_lastAttempt` (see Known Limitations).
10. **Do not port the `Debug` tag blindly.** Add your own tag to
    `Debug.Tags` if you use a non-empty whitelist, or every steal log line
    disappears.
11. **Decide the raid-lock policy.** The `ArenaService.IsAnimalRaidLocked`
    check is a hard dependency on the Arena system; without it, animals
    mid-raid can be stolen out from under the fight.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
