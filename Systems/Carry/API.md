# Carry — API Reference

Every public function of every module in the Carry system.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[Dependencies.md](Dependencies.md) · [Setup.md](Setup.md) ·
[Config.lua](Config.lua)

**Failure-mode convention.** No function in this system **throws**. Every
error path returns a value:
- `CarryRegistry.Set` / `Clear` → `(success, errorCode)`.
- The three derived services → a boolean, or nothing at all.
- Internal calls that could fail (remote fires, animation loads) are
  `pcall`-guarded and logged.

---

## `ServerScriptService.Carry.CarryRegistry`

The single source of truth for "what is this player holding".

### `CarryRegistry.Init()`

Resets the registry.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect (important):** resets **both** `carriedBy` **and the
  subscriber list**. Any service that called `OnChanged` before this
  loses its subscription silently.

---

### `CarryRegistry.OnChanged(callback)`

Subscribe to committed carry changes.

- **Parameters:** `callback: (userId: number) -> ()`.
- **Returns:** an **unsubscribe function** `() -> ()`. Calling it twice
  is a no-op (guarded by an `active` flag).
- **Failure modes:** none. If `callback` throws when it is later
  invoked, the throw is swallowed by a `pcall` — the other subscribers
  still run.
- **Fires:** only on **committed** changes — a successful `Set`, and a
  `Clear` that actually removed an item. A rejected `Set` and a
  no-op `Clear` do **not** fire it.

---

### `CarryRegistry.Get(playerOrUserId)`

The live carried item.

- **Parameters:** `playerOrUserId: any` — a `number` userId, or a
  `Player` instance.
- **Returns:** the `CarriedItem` table, or `nil` if the player is not
  carrying anything.
- **Failure modes:** a non-Player instance or a string → `nil`
  (no throw).

---

### `CarryRegistry.IsCarrying(playerOrUserId)`

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** `boolean`. `false` for a non-player argument.
- **Failure modes:** none.

---

### `CarryRegistry.GetKind(playerOrUserId)`

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** `'egg'`, `'animal'`, or `nil`.
- **Failure modes:** a non-player argument → `nil`.

---

### `CarryRegistry.Set(userId, item)`

Commits a carry. **This is the write path** — the Inventory system's
dispatcher, `EggService`, `AnimalService`, and `StealService` all call
it.

- **Parameters:**
  - `userId: number` — **must be a number**. A `Player` instance is
    **not** accepted here (unlike `Get`/`IsCarrying`/`GetKind`).
  - `item: any` — must be a table. Only `item.kind` is validated;
    `record`, `originalSlotId` and `startedAt` are not.
- **Returns:** `(boolean ok, string? errorCode)`.
- **Error codes** (from `CarryRegistry.Error`):
  - `'InvalidPlayer'` — `userId` is not a number, **or** `item` is not a
    table. (The same code is used for both.)
  - `'PlayerAlreadyCarrying'` — the player already has an entry.
  - `'KindMismatch'` — `item.kind` is neither `'egg'` nor `'animal'`.
- **Failure modes:** never throws. On success it returns `(true, nil)`.
- **Side effects on success:**
  1. Commits `carriedBy[userId] = item`.
  2. **Unequips the player's tools** — finds the player, their
     `Character`, its `Humanoid`, and calls `UnequipTools()` inside a
     `pcall`. Tools move to the `Backpack`; they are **never
     destroyed**. If the player has no character, the unequip silently
     does nothing and the `Set` still succeeds.
  3. Fires the change feed.

---

### `CarryRegistry.Clear(userId)`

Drops the carry. **This is the release path.**

- **Parameters:** `userId: number` — **must be a number**.
- **Returns:** `(CarriedItem?, string? errorCode)`.
- **Error codes:**
  - `'InvalidPlayer'` — `userId` is not a number → returns `(nil,
    'InvalidPlayer')`.
  - `'NotCarrying'` — the player had no entry → returns `(nil,
    'NotCarrying')`.
- **Failure modes:** never throws. On success it returns the removed
  item and `nil`.
- **Side effects on success:** removes the entry and fires the change
  feed. (That is what stops the Grab track, unlocks the tool, and
  re-enables the reset button.)

---

### `CarryRegistry.ForEach(callback)`

Iterates every live carry.

- **Parameters:** `callback: (userId: number, item: any) -> ()`.
- **Returns:** nothing.
- **Failure modes:** none — but the callback is **not** `pcall`-guarded,
  so a throwing callback propagates to the caller of `ForEach`.
- **Gotcha:** it iterates a **live** table with `pairs`. A callback that
  calls `Clear` on the player it is visiting mutates the table during
  iteration. The recovery paths in the source game are written to
  tolerate this; a new caller must be careful.

---

### `CarryRegistry.Snapshot(userId)`

The wire shape for `PlayerState`.

- **Parameters:** `userId: number` — **must be a number**.
- **Returns:** `{ Kind: string?, Name: string?, Steal: boolean? }`.
  - Not carrying → `{ Kind = nil, Name = nil, Steal = nil }` — **all
    three `nil`**. `Steal` is `nil`, **not** `false`.
  - Carrying an animal → `Name = item.record.displayName`.
  - Carrying an egg → `Name = item.record.rarity` (egg records have no
    `displayName`).
  - `Steal = item.steal ~= nil` — `true` for a steal carry, `false` for
    a plain carry.
- **Failure modes:** none.

---

### `CarryRegistry.Error`

A frozen table of the error codes. **Not a function.**

| Code | Returned by | Notes |
|---|---|---|
| `InvalidPlayer` | `Set`, `Clear` | Also used for a non-table `item`. |
| `AlreadyCarried` | — | **DEAD. Never returned.** The real code is `PlayerAlreadyCarrying`. |
| `PlayerAlreadyCarrying` | `Set` | The player already has an entry. |
| `NotCarrying` | `Clear` | The player had no entry. |
| `KindMismatch` | `Set` | `item.kind` is not `'egg'` or `'animal'`. |

---

## `ServerScriptService.Carry.ToolLockService`

The gameplay-Tool equipment gate.

### `ToolLockService.Init()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** subscribes to `CarryRegistry.OnChanged`. If it was
  already subscribed, it drops the old subscription first (the handle is
  stored) and re-subscribes.

---

### `ToolLockService.IsLocked(playerOrUserId)`

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** `boolean` — recomputed **live** from the registry. It
  never reads the push cache.
- **Failure modes:** a non-player argument → `false`.

---

### `ToolLockService.Refresh(playerOrUserId)`

Pushes the lock state to the client **if it changed**.

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** nothing.
- **Failure modes:** none. If the player object cannot be resolved, the
  cache is updated but **no remote traffic** is produced. If
  `Remotes.FireClient` throws, the error is logged; the cache is still
  updated, so the **next change** is the next push.
- **Payload:** `{ Locked = boolean }` on `Remotes.Names.CarryLock`.

---

### `ToolLockService.ForgetPlayer(userId)`

- **Parameters:** `userId: number`.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** drops the "already pushed" cache entry for that user.
  It does **not** touch the registry and does **not** push anything.

---

### `ToolLockService._TestReset()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** clears the push cache (and the subscription handle)
  for test isolation.

---

## `ServerScriptService.Carry.ResetProtectionService`

The reset-button gate.

### `ResetProtectionService.Init()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** subscribes to `CarryRegistry.OnChanged` (dropping any
  prior subscription first).

---

### `ResetProtectionService.IsProtected(playerOrUserId)`

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** `boolean` — recomputed **live** from the registry.
- **Failure modes:** a non-player argument → `false`.

---

### `ResetProtectionService.Refresh(playerOrUserId)`

Pushes the protection state to the client **if it changed**.

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** nothing.
- **Failure modes:** none. Unresolvable player → cache updated, no
  remote traffic. A throwing `FireClient` is logged; the cache is still
  updated.
- **Payload:** `{ Protected = boolean, Reason = string? }` on
  `Remotes.Names.ResetProtection`.
- **Reason derivation:**
  | Registry state | `(protected, reason)` |
  |---|---|
  | no entry | `(false, nil)` |
  | `item.steal ~= nil` | `(true, 'Stealing')` |
  | `item.kind == 'animal'` | `(true, 'CarryingAnimal')` |
  | `item.kind == 'egg'` | `(true, 'CarryingEgg')` |
  | any other kind | `(true, 'Carrying')` — **fail-closed**, and `'Carrying'` is **not** in `ResetProtectionService.Reason`. |

---

### `ResetProtectionService.ForgetPlayer(userId)`

- **Parameters:** `userId: number`.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** drops the push cache entry. It does **not** touch the
  registry.

---

### `ResetProtectionService._TestReset()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.

---

### `ResetProtectionService.Reason`

A frozen table of the reason codes. **Not a function.**

| Code | Meaning |
|---|---|
| `CarryingAnimal` | The player is carrying an animal. |
| `CarryingEgg` | The player is carrying an egg. |
| `Stealing` | The player is carrying a stolen object. |

**Absent:** the `'Carrying'` fallback reason that `Refresh` can emit for
an unrecognised carry kind. Clients must have a default branch.

---

## `ServerScriptService.Carry.PlayerGrabService`

The authored carry pose.

### `PlayerGrabService.Init()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effects:**
  - Subscribes to `CarryRegistry.OnChanged` (dropping any prior
    subscription first).
  - Connects `Players.PlayerAdded` → `CharacterAdded` (re-sync) and
    `Players.PlayerRemoving` (stop + clear the warn set). The wiring is
    guarded by a `playersWired` flag, so calling `Init` twice is safe.

---

### `PlayerGrabService.IsPlaying(playerOrUserId)`

- **Parameters:** `playerOrUserId: any` — a `number` userId or a
  `Player` instance.
- **Returns:** `boolean` — whether the server currently holds a live
  Grab track for that player.
- **Failure modes:** a non-player argument → `false`.

---

### `PlayerGrabService._TestReset()`

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** none.
- **Side effect:** stops every tracked track and clears the entry table.

---

### `PlayerGrabService._TestEntryCount()`

- **Parameters:** none.
- **Returns:** `number` — how many entries the service is tracking.
- **Failure modes:** none.

---

## Private / internal

Not part of the public surface, but named here so a reader does not
mistake them for API.

| Function | Module | Purpose |
|---|---|---|
| `resolveUserId(playerOrUserId)` | all four | Accepts a `number` or a `Player` instance; returns a `number?`. |
| `resolveAsset()` | `PlayerGrabService` | `FindFirstChild` chain to `ServerStorage.Assets.Animations.Player.Grab`; returns `Animation?`. The asset is **never cloned** and the `AnimationId` is **never hard-coded**. |
| `ensureGrab(player, userId, item)` | `PlayerGrabService` | Starts or reuses the Grab track. Same character + live track → keep (no reload pop). |
| `syncGrab(userId)` | `PlayerGrabService` | Registry-driven: no entry / invalid character → stop; otherwise `ensureGrab`. |
| `stopEntry(userId)` | `PlayerGrabService` | Stops the track and drops the entry. |
| `warnOnce(userId, step, message)` | `PlayerGrabService` | Warns at most once per user per step. Steps: `no-character`, `no-humanoid`, `no-animator`, `no-asset`, `bad-id`, `load-failed`, `play-failed`, `sync-failed`. |
| `clearWarns(userId)` | `PlayerGrabService` | Clears the per-user warn set. |
| `transactionIdFor(item)` | `ResetProtectionService`, `PlayerGrabService` | Diagnostic string `'<record.uniqueId>@<startedAt>'`, or `'?@?'` on a malformed item. |
| `compute(userId)` | `ResetProtectionService` | Derives `(protected, reason)` from the registry. |
| `_notify(userId)` | `CarryRegistry` | Calls every subscriber through a `pcall`. |
