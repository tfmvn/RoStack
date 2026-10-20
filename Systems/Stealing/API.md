# Stealing — API

Every **public** function of every module in this system. Local
(`local function`) helpers are not listed — they are not exported on the
frozen module table and cannot be called from outside.

Both modules return `table.freeze(...)`:
`StealService` at `StealService.lua:1509`, `Stealing` at `Stealing.lua:93`.

**Nothing in this system throws.** Every public function returns a result
table or a boolean. The internal `pcall` wrappers protect the gameplay
paths from a malformed dependency (a missing asset, a bad record, a dead
player). The one exception is `StealService.ForgetPlayer`, which currently
throws — see its entry.

---

## `ServerScriptService.Steal.StealService`

The whole steal system: the request, the atomic reservation, the
delivery, and every rollback exit.

---

### `StealService.SetPlayerService(svc: any)`

Injects the **profile authority**. Source: `StealService.lua:398`.

**Description.** Stores the reference used to read and move profile
records. The authority is *injected*, never `require`d, which is what
keeps the require graph acyclic (`PlayerService` does not require this
module back).

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `svc` | `any` | The profile authority. Must implement `GetEggs`, `GetAnimals`, `AddEgg`, `AddAnimal`, `RemoveEgg`, `RemoveAnimal`, `SetEggSlot`, `SetAnimalSlot`, `PushState`, `Notify`. See [`Dependencies.md`](Dependencies.md) → *The profile authority contract*. |

**Returns.** Nothing.

**Failure modes.** None — it is a plain assignment. Calling it with `nil`
leaves `playerServiceRef` as `nil`, and every profile call is then skipped
silently: a steal can **start** but `TryComplete` will report
`record-gone` and roll back (the `snapshot` stays `nil`). The `Add` /
`Remove` calls are guarded by `if playerServiceRef then`, so a missing
authority never throws — it makes the transfer impossible.

---

### `StealService.Init()`

Wires the Steal prompt callback. Source: `StealService.lua:402`.

**Description.** Registers a single callback with `CarryPrompts` that
routes the `StealPrompt`'s `Triggered` event into `TrySteal`. The prompt
itself is installed by `CarryPrompts.InstallPickupPrompt` → 
`InstallStealPrompt`; this function only connects the callback.

**Parameters.** None.

**Returns.** Nothing.

**Failure modes.** None. Idempotent in the sense that calling it again
simply replaces the callback (there is exactly one). If it is never
called, the prompt still exists but does nothing when triggered.

**Log.** `[ST] Init: steal callback wired (completion is touch-only, no prompt)`.

---

### `StealService.Start()`

Arms the delivery routing. Source: `StealService.lua:413`.

**Description.** Connects one `Touched` handler to every base
**collector** (`base.collector`, which must be a `BasePart`). Each
handler resolves the touching player, requires that the player is
steal-carrying, requires that the collector belongs to that player's
**own** base, and then calls `TryComplete`.

**Parameters.** None.

**Returns.** Nothing.

**Failure modes.**

- **One-shot.** It iterates `BaseService.GetAllBases()` **once**. A base
  registered *after* `Start()` gets no routing and can never be a
  delivery target. There is no re-arm hook.
- A base whose `collector` is missing, or is not a `BasePart`, is
  **silently skipped** (no warning).
- `Start()` is **idempotent**: the `_touchedConnected` map prevents a
  second connection to the same collector, so calling it again is safe
  and is the recommended way to pick up late-registered bases.

**Log.** `[ST] Start: collector touch routing armed`.

---

### `StealService.ForgetPlayer(userId: number)`

Drops the per-player state. Source: `StealService.lua:442`.

**Description.** Clears the rate-limit window (`_lastAttempt`) and the
walk-speed snapshot (`_thiefSpeed`) for one user.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `userId` | `number` | The user to forget. |

**Returns.** Nothing.

**Failure modes.** ⚠️ **This function currently throws.**
`_thiefSpeed` is declared at `StealService.lua:587` but read at line
**444** — before the declaration. Lua locals are only in scope from their
declaration onward, so line 444 indexes a **global** `_thiefSpeed`, which
is `nil`:

```text
attempt to index global '_thiefSpeed' (a nil value)
```

The source game's bootstrap never calls it (so production never notices),
but `StealService.spec.lua:215-216` does call it in `setup()`. **Fix:**
move `local _thiefSpeed: { [number]: number } = {}` up next to
`local _lastAttempt` (around line 115).

---

### `StealService.CanSteal(thiefUserId: number, occupantId: string, kind: string?, thiefPosOverride: Vector3?): { [string]: any }`

The pure validator. Source: `StealService.lua:455`.

**Description.** Answers "may this player steal this object right now?"
**No mutation, no yields.** Every rejection commits **zero** state — no
reservation, no carry, no prompt side effect. `TrySteal` calls this
before any mutation, so a forged request can never leave residue.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `thiefUserId` | `number` | The would-be thief. Must pass `Validation.IsValidPlayerUserId`. |
| `occupantId` | `string` | The target object's unique id (`'EG_…'` / `'AN_…'`). |
| `kind` | `string?` | `'egg'` or `'animal'` (`SlotType.OccupantKind.*`). `nil` → `'wrong-kind'`. |
| `thiefPosOverride` | `Vector3?` | **Test-only seam.** When supplied, it is used as the thief's position instead of reading the live HRP. Nothing in production passes it. |

**Returns.**

On success:

```lua
{ ok = true, record = <the runtime record>, slot = <the slot record>, ownerId = <number> }
```

On failure:

```lua
{ ok = false, error = <code> }
```

**Failure modes (the `error` codes, in check order).**

| Code | Cause |
|---|---|
| `invalid-player` | `thiefUserId` is not a valid player userId. |
| `invalid-target` | `occupantId` is not a non-empty string. |
| `wrong-kind` | `kind` is neither `'egg'` nor `'animal'`. |
| `already-carrying` | The thief is already carrying anything. |
| `target-gone` | The record does not resolve; the slot owner is invalid; the model is missing/unparented; the model has no `PrimaryPart`. |
| `in-progress` | `record._mutex` is set (another transaction holds it). |
| `raid-locked` | **Animals only.** `ArenaService.IsAnimalRaidLocked(occupantId)` — the animal is fighting in an active raid. |
| `not-stealable-state` | Egg must be `'Placed'`; animal must be `'Slotted'` or `'Placed'`. |
| `already-carried` | `record.carriedBy ~= nil` or `record.stolenBy ~= nil`. |
| `not-slotted` | `record.slotId` is not a string, or the slot does not resolve, or the slot has no `part`. |
| `slot-race` | The slot is not `Occupied`, or its occupant id/kind does not match the record. |
| `owner-mismatch` | `record.ownerUserId ~= slot.ownerUserId`. |
| `own-object` | The thief owns the object. **The owner uses the normal grab.** |
| `no-thief-base` | The thief does not own a base (no collector to deliver to). |
| `no-destination` | The thief has no free slot right now (`SlotService.GetFreeSlot` returned `nil`). |
| `no-character` | No live HRP and no `thiefPosOverride`. |
| `too-far` | The distance from the thief to `slot.part.Position` exceeds the limit (8 studs for both kinds today). |

**Not checked here (by design).** The **Base Lock** does not gate
steal-start: the lock is an *escape* restriction enforced physically
(locked lasers collide in the `BaseLock_X` collision group), so a thief
cannot leave a locked base with the object. Never add a locked-base
rejection to this function.

---

### `StealService.TrySteal(player: Player, occupantId: string, kind: string?): { [string]: any }`

The steal request. Source: `StealService.lua:657`.

**Description.** The player-facing entry point. The client sends only the
target id and the claimed kind; everything else (owner, base, slot,
distance, capacity) is resolved and re-validated server-side.

Order of operations:

1. `Validation.LivePlayer` → `invalid-player`.
2. `Validation.CanPlayerInteract` → `player-not-live` (a dead / dying /
   respawning character has zero interaction authority).
3. **Rate limit** (0.5 s) → `rate-limited` + a `Steal_Cooldown` toast.
   The window is consumed by the attempt, successful or not.
4. `occupantId` shape → `invalid-target` + `General_Generic`.
5. `CanSteal` → any of its codes, notified through the mapped
   `Steal_*` catalog id.
6. The thief's base → `no-thief-base`.
7. **The atomic commit block** (no yields):
   `record._mutex = true` → `SlotService.DemoteSlotToReserved(slot.id)`
   (the victim's slot `Occupied → Reserved`) → `SlotService.GetFreeSlot`
   + `SlotService.ReserveSlot(dest.id)` (the thief's destination).
8. Record mutation: `state` → `'Opening'` (egg) / `'Carried'` (animal);
   `carriedBy`, `originalSlotId`, `stolenBy` → the thief;
   `controller` / `controllerType` → the carry controller.
9. `CarryController.Start` (pcall-wrapped) and `CarryRegistry.Set`.
10. Side effects: thief walk-speed slow, the `STOLEN` overhead (animals
    only), prompt removal, `StandPresentation.Unbind` (eggs), the
    `PlayerState` push, the `Steal_Success` toast, and the victim's
    robbery toast + SFX.
11. `record._mutex = false`.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `player` | `Player` | The thief. Must be a live `Player` with a live character. |
| `occupantId` | `string` | The target object's unique id. |
| `kind` | `string?` | The claimed kind: `'egg'` or `'animal'`. Re-validated. |

**Returns.**

```lua
{ success = true }
```

or

```lua
{ success = false, error = <code> }
```

**Failure modes.**

| `error` | Cause | Side effects |
|---|---|---|
| `invalid-player` | Not a live `Player`. | None. No notification. |
| `player-not-live` | Dead / dying / respawning character. | None. No notification. |
| `rate-limited` | A request inside the 0.5 s window. | None (the window is consumed). A `Steal_Cooldown` toast is sent. |
| `invalid-target` | `occupantId` is not a non-empty string. | None. A `General_Generic` toast is sent. |
| `wrong-kind`, `already-carrying`, `target-gone`, `in-progress`, `raid-locked`, `not-stealable-state`, `already-carried`, `not-slotted`, `slot-race`, `owner-mismatch`, `own-object`, `no-destination`, `too-far`, `no-character` | From `CanSteal`. | **Zero state change.** A mapped `Steal_*` toast is sent. |
| `no-thief-base` | The thief lost their base between `CanSteal` and here. | None. A `General_Generic` toast is sent. |
| `carry-failed` | `CarryController.Start` failed, or `CarryRegistry.Set` was rejected (the player started carrying in between). | The victim's slot is re-occupied, the record's state/flags are restored, the destination reservation is released. A `Debug.Warn` is logged. |
| `no-destination` (from the commit block) | The destination could not be reserved. | Same restoration as above. A `Steal_BaseFull` toast is sent. |

**Notification mapping.** The `CanSteal` code is mapped to a catalog id by
the private `_stealRejectReason`:

| Code | Toast id |
|---|---|
| `base-locked` | `Steal_BaseLocked` |
| `no-destination` | `Steal_BaseFull` |
| `own-object` | `Steal_OwnAnimal` |
| `already-carrying` | `Steal_AlreadyCarrying` |
| `too-far` | `Steal_TooFar` |
| `in-progress`, `already-carried`, `slot-race`, `raid-locked` | `Steal_TargetBusy` |
| `target-gone`, `invalid-target`, `not-stealable-state`, `not-slotted`, `owner-mismatch` | `Steal_TargetGone` |
| anything else | `General_Generic` |

`invalid-player` and `rate-limited` never reach the mapper.

**Success side effects.** `Steal_Success` toast with
`{AnimalName, Rarity}`; the victim gets a `Warning` robbery message
("`<ThiefName> stole your <AnimalName>!`", rarity-colored, markup-
escaped) and the robbery SFX; both sides get a `PlayerState` push.

**Log.** `[ST] steal started kind=... uniqueId=... thief=... owner=...`.

---

### `StealService.TryComplete(player: Player): { [string]: any }`

The delivery. Source: `StealService.lua:861`.

**Description.** Transfers the stolen object from the victim to the
thief. **This is the only completion path** — touch-only, no prompt, no
key press. The transfer order is strictly:

```text
Occupy(dest)  ->  Add(B)  ->  Remove(A)  ->  Release(original)  ->  seat
```

Occupying the destination **first** is what makes a failed seat mutate
nothing: the old order left a split-brain where B's profile owned the id
while the runtime record still named A.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `player` | `Player` | The thief. Must be live, and `player.Character` must be the **same Model instance** the steal attached to. |

**Returns.**

```lua
{ success = true, slotId = <the destination slot id> }
```

or

```lua
{ success = false, error = <code> }
```

**Failure modes.**

| `error` | Cause | Side effects |
|---|---|---|
| `invalid-player` | Not a live `Player`. | None. |
| `player-not-live` | Dead / dying / respawning. | None. |
| `not-a-steal` | The player is not carrying a steal. | None. |
| `character-changed` | The player's character is not the one the steal attached to (a respawn). | **The carry is rolled back automatically** (`RollbackCarried(thiefId, 'character-changed')`). The object goes home. |
| `target-gone` | The record is malformed; the runtime record is no longer the same object (a replacement sharing the slot); the model was destroyed mid-carry. | For the destroyed-model case the carry is **rolled back automatically** (`'target-destroyed'`). For the other two, the carry is kept. |
| `in-progress` | `record._mutex` is set. | None. |
| `no-thief-base` | The thief has no base. | None. |
| `no-collector` | The thief's base has no `BasePart` collector. | None — the carry is kept, so the player can retry. |
| `no-character` | No live HRP. | None. |
| `too-far-from-collector` | The HRP is farther from the collector than `collector.Size.Magnitude/2 + PromptConfig.CarryMaxDistance`. | None. |
| `owner-mismatch` | The original owner id is invalid, is the thief, or no longer matches `record.ownerUserId`. | None. |
| `no-slot` | No destination slot is available (the reserved one was lost and no free slot exists). | The carry is **kept** — retryable. A `Steal_BaseFull` toast is sent; both sides are pushed. |
| `slot-race` | `SlotService.OccupySlot(dest)` failed. | **Nothing moved**: both profiles intact, the source slot still `Reserved`, the record untouched, the carry kept — **retryable**. Both sides are pushed. |
| `record-gone` | The original owner's profile record could not be snapshotted. | The fresh reservation is released, both sides are pushed, the carry is kept. |
| `transfer-failed` | `Add(B)` failed, or `Remove(A)` failed. | If `Remove(A)` failed, the `Add(B)` is **undone** first. The carry is kept. Both sides are pushed. |

**Success side effects.** The profile record moves A → B under the **same
id**; the runtime record's `ownerUserId` / `slotId` / `state` follow; the
original slot is released; the model is seated (eggs are re-homed into
`ActiveEggs`, hatched prompts reinstalled; animals use
`AnimalService.SettleModelAtSlot`); both slots' displays are refreshed;
the carry is cleared; the thief's base prompts are re-enabled; the thief
gets a `Steal_DeliverySuccess` toast; the owner gets a `Warning` robbery
message and a push; the funnel logs `StealSucceeded`; the `STOLEN`
overhead is cleared and the thief's walk speed is restored.

**Log.** `[ST] steal complete kind=... uniqueId=... thief=... slotId=...`.

---

### `StealService.RollbackCarried(thiefUserId: number, reason: string?): { [string]: any }`

Returns a steal-carried object to its original owner. Source:
`StealService.lua:1207`.

**Description.** Runtime-only recovery — the profile never moved, so
nothing in the profile is touched (except in tier-2, which re-points the
`SlotId`). Three tiers, tried in order:

| Tier | Condition | Result |
|---|---|---|
| **Post-commit** | `record.ownerUserId == thiefUserId` and `record.slotId` names an `Occupied` slot with this occupant | The transfer already committed. Finish the seating idempotently instead of reverting. Returns `{success=true, completed=true}`. |
| **1** | The original slot is still `Reserved` and still owned by the original owner | Re-occupy it and seat the object there. Returns `{success=true}`. |
| **2** | Any `Empty` slot on the **original owner's** base | Reserve + occupy it, re-point the profile record with `SetEggSlot` / `SetAnimalSlot`, seat the object. Returns `{success=true}`. |
| **3** | Nowhere to seat | Park the object: animals → `state='Recovering'` in `Workspace/Animals/Recovering`; eggs → `state='Placed'` with `slotId = nil` in `ActiveEggs`. Nothing is deleted, the profile is preserved. Returns `{success=true, parked=true}`. |

Tier-1 almost always succeeds, because the original slot stays `Reserved`
for the whole carry. That is also why a rejoining owner auto-skips the
record — `RestorePlayerBase`'s occupied branch finds the `Reserved` slot,
so no second model and no extra code are needed.

Every tier also clears the `STOLEN` overhead and restores the thief's walk
speed, and pushes **both** sides.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `thiefUserId` | `number` | The player carrying the steal. |
| `reason` | `string?` | A diagnostic label only (e.g. `'death'`, `'owner-leaving'`, `'HitByBat'`). It is logged, never behaviour-changing. |

**Returns.**

```lua
{ success = true }                          -- tier-1 or tier-2
{ success = true, completed = true }         -- the post-commit seating path
{ success = true, parked = true }            -- tier-3
{ success = false, error = 'not-a-steal' }   -- not carrying a steal
{ success = false, error = 'target-gone' }   -- the record is not a table
```

**Failure modes.**

- `not-a-steal` — the user is not carrying a steal. **A safe no-op**:
  a second rollback (death + leave racing) returns this and changes
  nothing.
- `target-gone` — the carry's `record` is not a table. The carry is
  cleared and the thief is pushed, so a stale suppression flag cannot
  stick on the client's filter.
- Tier-2's `SetEggSlot` / `SetAnimalSlot` failure is **non-fatal** — the
  runtime is placed anyway and a `Debug.Warn` is logged.
- Tier-3 logs a **loud** `Debug.Warn` — the record is preserved, but the
  object is un-interactable until the owner rejoins.

**Log.** `[ST] > RollbackCarried uniqueId=... reason=...` on entry, then
one of `[ST] < RollbackCarried: post-commit seating finished` /
`... : original slot` / `... : owner fallback slot`, or the tier-3 warn.

---

### `StealService.RollbackIfStealing(userId: number, reason: string?): boolean`

The thief-side hook. Source: `StealService.lua:1463`.

**Description.** If this user is currently steal-carrying, roll the steal
back and report `true`. The caller must then **skip** its generic
owner-assuming recovery (which would misplace the record and profile).

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `userId` | `number` | The player to check. |
| `reason` | `string?` | A diagnostic label, forwarded to `RollbackCarried`. |

**Returns.**

- `true` — the user was steal-carrying; the rollback has already been
  performed.
- `false` — the user was not steal-carrying, **or** `userId` is not a
  number. Run the normal path.

**Failure modes.** None — it never throws and never partially applies.
Note that `false` is returned for a non-number `userId` as well as for
"not stealing"; the two cases are indistinguishable to the caller.

**Callers.** `bootstrap.server.lua` (death at line 1062,
`CharacterRemoving` at 1121, studio command at 1386),
`AnimalService.lua:2882` (`'disconnect'`), `BatService.lua:130`
(`'HitByBat'`).

---

### `StealService.RollbackStolenTarget(kind: string, uniqueId: string, reason: string?): boolean`

The owner-side hook. Source: `StealService.lua:1483`.

**Description.** If the `(kind, uniqueId)` object is currently
steal-carried by **anyone**, roll it back to its owner now and report
`true`. Used by owner-leave sweeps and rebirth **before** the base
teardown, so the sequence is recover-then-sweep: the record lands home
while its slot still exists, and the normal non-destructive sweep (model
destroyed, runtime dropped, profile kept) then leaves a clean rejoin.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `kind` | `string` | `'egg'` or `'animal'`. Must be a string. |
| `uniqueId` | `string` | The object's unique id. Must be a string. |
| `reason` | `string?` | A diagnostic label, forwarded to `RollbackCarried`. |

**Returns.**

- `true` — the object was steal-carried and has been rolled back.
- `false` — no steal-carry matches, **or** the arguments are not strings.

**Failure modes.** None — it never throws. The scan uses
`CarryRegistry.ForEach`, so it visits every live carry; the scan is cheap
but it is **not** a hot path (leave sweeps only).

**Callers.** `AnimalService.lua:2922` (`'owner-leaving'`),
`EggService.lua:906` (`'owner-leaving'`),
`RebirthService.lua:913` / `:918` (`'rebirth'`).

---

### `StealService.IsStolenRecord(kind: string, uniqueId: string): boolean`

Is this object currently steal-carried? Source: `StealService.lua:371`.

**Description.** Scans the carry registry for an item with a `steal`
table whose `kind` and `record.uniqueId` match. The
`CarryRegistry` is authoritative — the record's `stolenBy` field is only
a cache flag.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `kind` | `string` | `'egg'` or `'animal'`. |
| `uniqueId` | `string` | The object's unique id. |

**Returns.** `true` / `false`. Never throws.

**Failure modes.** None. An unknown id, an empty string, or a
non-matching kind simply returns `false`.

**Cost.** It is an **O(carrying players)** scan. The source comments call
it "rare calls only: leave sweeps, restore paths — never hot".

---

### `StealService.IsStealCarry(playerOrUserId: any): boolean`

Is this player's carry a steal in progress? Source: `StealService.lua:391`.

**Description.** A single lookup in the carry registry: the item exists
**and** it has a `steal` table.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `playerOrUserId` | `any` | A `Player` instance **or** a numeric userId (the registry resolves both). |

**Returns.** `true` / `false`. Never throws.

**Failure modes.** None. A `nil`, a bogus value, or a player who is not
carrying all return `false`.

---

### `StealService._TestVictimText(thiefName: string, animalName: string, rarity: string?): string`

The victim-text seam. Source: `StealService.lua:279`.

**Description.** Builds the victim robbery message for explicit values
through the **real** formatter path, with no services involved. Lets a
spec assert that the thief's name and the rarity-coloured animal name
appear, and that markup in a name is escaped.

**Parameters.**

| Name | Type | Meaning |
|---|---|---|
| `thiefName` | `string` | The thief's display name. Escaped. |
| `animalName` | `string` | The stolen object's display name. Escaped and truncated to 40 characters. |
| `rarity` | `string?` | The authoritative rarity. `nil` or an unknown rarity → plain (white) text. |

**Returns.** A RichText string:

```html
<font color="#FF5A5A">Bob stole your </font><font color="#F5C846">Dragon</font><font color="#FF5A5A">!</font>
```

**Failure modes.** None — the whole build is inside a `pcall`, and a
failure falls back to the plain string `'One of your objects was stolen!'`.

---

## `ReplicatedStorage.Config.World.Stealing`

The system's config module. The values are documented in
[`Config.lua`](Config.lua) and in [`README.md`](README.md) → *Configuration*.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `Stealing.Cooldown` | `number` | `0.5` | Anti-spam window between steal requests, in seconds. |
| `Stealing.AlertCleanupPad` | `number` | `0.5` | Extra seconds added to the measured SFX length before cleanup. |
| `Stealing.AlertFallbackCleanup` | `number` | `3` | Fallback SFX lifetime when `TimeLength` is unreadable. |
| `Stealing.StealSpeedMultiplier` | `number` | `0.6` | The thief's relative `WalkSpeed` multiplier while steal-carrying. |
| `Stealing.StealPresentation.FOVMultiplier` | `number` | `0.9` | Client-only camera narrowing. Must satisfy `0 < x < 1`. |
| `Stealing.StealPresentation.FOVTweenTime` | `number` | `0.3` | Client-only tween duration, in seconds. |

---

### `Stealing.Validate(): { string }`

Validates the tunables. Source: `Stealing.lua:59`.

**Description.** A pure self-check. It never throws and never mutates.

**Parameters.** None.

**Returns.** An array of human-readable issue strings. **An empty array
means the config is valid.**

**What it checks.**

- `Cooldown` is a number `>= 0`.
- `AlertFallbackCleanup` is a number `> 0`.
- `StealSpeedMultiplier` is a number `> 0`.
- `StealPresentation` is a table, and inside it:
  - `FOVMultiplier` is a number with `0 < x < 1` (it must *narrow*);
  - `FOVTweenTime` is a number `>= 0`.

**What it does NOT check.**

- **`AlertCleanupPad` is never validated.** A negative value makes the
  robbery SFX clone get destroyed before it can play.
- `NaN` is caught for `Cooldown`, `StealSpeedMultiplier`, `FOVMultiplier`,
  and `FOVTweenTime` (the `x ~= x` check), but **not** for
  `AlertFallbackCleanup`.

**Callers.** The game's config validation pass at boot. It is not called
by `StealService` itself.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
