# Carry — engineering notes

## Purpose, in one line

A per-player **single-carry registry** (one egg or one animal) that is the
sole source of truth, plus three event-driven services derived from it: a
gameplay-Tool lock, a reset-button gate, and an authored carry pose.

---

## How it actually works

### The central idea

There is exactly **one** piece of per-player carry state in the whole
game: `CarryRegistry.carriedBy[userId]`. Everything else — "is the tool
locked", "is the reset button disabled", "is the grab pose playing" — is
**recomputed from that state on every change**, never stored separately.

The mechanism for "on every change" is a subscriber list:

```text
CarryRegistry (the only state)
      |
      +-- OnChanged(userId)      fires on committed Set / Clear only
      v
  ToolLockService.Refresh       -> push CarryLock
  ResetProtectionService.Refresh -> push ResetProtection
  PlayerGrabService.syncGrab   -> start/stop the Grab track
```

`_notify(userId)` calls every subscriber through `pcall`, so a broken
subscriber can never break the grab/place/steal/recover path.

### The registry

```lua
carriedBy: { [userId]: CarriedItem }
CarriedItem = { kind, record, originalSlotId, startedAt, steal? }
```

`CarryRegistry.Init()` sets `carriedBy = {}` **and `_subscribers = {}`**.
That second line is the sharpest edge in the system.

`resolveUserId(x)` accepts a `number` (a userId) or an `Instance` that
`IsA('Player')`; anything else → `nil`. So `Get`/`IsCarrying`/`GetKind`
take either form. `Set` and `Clear` take a **number only**.

`Set(userId, item)`:

1. `type(userId) ~= 'number'` → `(false, 'InvalidPlayer')`.
2. `type(item) ~= 'table'` → `(false, 'InvalidPlayer')`. (Note: the error
   code is `InvalidPlayer` even for a bad item — the two checks share a
   code.)
3. Already carrying → `(false, 'PlayerAlreadyCarrying')` + a `Debug.Warn`.
4. `item.kind` is neither `'egg'` nor `'animal'` → `(false,
   'KindMismatch')` + a `Debug.Warn`. **This is the only field of the
   item that is validated.**
5. Commit `carriedBy[userId] = item`.
6. **Unequip the player's tools** (inside a `pcall`): find the player,
   their `Character`, its `Humanoid`, and call `UnequipTools()`. Tools go
   to the `Backpack`, never destroyed.
7. `_notify(userId)`.
8. Return `(true, nil)`.

`Clear(userId)`:

1. Non-number → `(nil, 'InvalidPlayer')`.
2. Not carrying → `(nil, 'NotCarrying')`.
3. Remove, log, `_notify(userId)`, return `(item, nil)`.

The `NotCarrying` result is **only** for a player who isn't carrying. A
`Clear` on a non-number is the `InvalidPlayer` case.

`Snapshot(userId)` returns `{ Kind, Name, Steal }`:

- Not carrying → `{ Kind = nil, Name = nil, Steal = nil }` — **all three
  `nil`, including `Steal`**. Not `false`.
- Carrying an animal → `Name = item.record.displayName`.
- Carrying an egg → `Name = item.record.rarity` (egg records have no
  `displayName`).
- `Steal = item.steal ~= nil` — `true` for a steal carry, `false` for a
  plain carry.

`OnChanged(callback)` inserts the callback and returns an **unsubscribe
function**. The unsubscribe closure is guarded by an `active` flag so
calling it twice is safe.

`ForEach(callback)` walks `carriedBy` with `pairs` and calls
`callback(userId, item)`. A callback that mutates the table during the
walk is the caller's problem.

### The Tool lock

`ToolLockService` derives one boolean:

```lua
locked = CarryRegistry.IsCarrying(userId)
```

It pushes `CarryLock { Locked = boolean }` to the client **only when the
value changed** since the last push (`pushedLocked[userId]`).

The client's `ToolLockController` locks the Backpack/hotbar and force-
unequips. The **server** enforcement is two-layered:

1. `CarryRegistry.Set` unequips at the moment the carry starts.
2. Every server-activated `Tool` (e.g. `BatService`) must gate on
   `CarryRegistry.IsCarrying`.

`IsLocked(userId)` always recomputes live — it never reads the push
cache. The cache is only the "did we already tell the client" flag.

`ForgetPlayer(userId)` drops the cache entry. It does **not** touch the
registry.

### The reset gate

`ResetProtectionService` derives `(protected, reason)`:

```lua
item = CarryRegistry.Get(userId)
if item is not a table          -> (false, nil)
if item.steal ~= nil            -> (true, 'Stealing')
if item.kind == 'animal'        -> (true, 'CarryingAnimal')
if item.kind == 'egg'           -> (true, 'CarryingEgg')
otherwise (unknown kind)        -> (true, 'Carrying')
```

The unknown-kind branch is the **fail-safe**: a registry entry still
means an active carried-object transaction, so the gate stays closed even
on a shape the code does not recognise. But the reason string
`'Carrying'` is **not** in `ResetProtectionService.Reason` — a client that
switches exhaustively on the reason needs a fallback.

It pushes `ResetProtection { Protected = boolean, Reason = string? }` on
change only.

**What it does NOT protect:** slot menus, upgrades, cash collection,
level-up VFX, prompt proximity, and a hold that was started but not
committed (a released hold never reaches the server, so there is nothing
to corrupt).

**It is not the recovery path.** The existing `Died` /
`CharacterRemoving` / `PlayerRemoving` recovery still runs and still owns
the animal. The protection service only disables the reset button; the
recovery's own `CarryRegistry.Clear` re-triggers `Refresh`, which opens
the gate after recovery.

### The grab pose

`PlayerGrabService` keeps one entry per userId:

```lua
entries[userId] = { character, animator, track, txId }
```

`syncGrab(userId)`:

- No registry entry → `stopEntry(userId)`.
- No `Player` object (removed, or a Studio spec) → `stopEntry(userId)`.
- Otherwise → `ensureGrab(player, userId, item)`.

`ensureGrab`:

1. The character must be a live `Instance` with a non-nil `Parent`;
   otherwise warn once (`'no-character'`).
2. It must have a `Humanoid` (`'no-humanoid'`).
3. It must have an `Animator` (`'no-animator'`).
4. **Same live character with a live track** → keep it (update `txId`
   only). No reload pop, and a newer transaction inherits the pose
   without a hitch.
5. Otherwise stop the old entry (never reference a destroyed character's
   track), resolve the asset, `LoadAnimation`, set
   `Priority = Enum.AnimationPriority.Action4`, `Looped = true`, and
   `Play(FADE_SECONDS, 1, 1)`.

The asset is resolved at
`ServerStorage.Assets.Animations.Player.Grab` and must be an
`Animation` with a non-empty `AnimationId`. **The asset is never cloned
and the id is never hardcoded** — the path is a `FindFirstChild` chain.

**Why Action4:** it is the highest non-`Core` priority tier. It outranks
the stock `Animate` script's `Idle`/`Movement` locomotion **and** other
gameplay `Action` tracks (emotes, tool holds), so the carry pose cannot
be overridden while held. `Core` is deliberately unused.

**The authoring assumption:** a correctly authored clip is
**upper-body-only**, so the arms stay raised while the legs keep
walking/running/jumping. The header flags this as an unverified
inspection gap (§19) because the assets are Studio-authored and not in
the repo. If a Studio check shows the legs freezing, the clip carries
lower-body tracks: re-author it without them (preferred) or lower the
priority. **Do not fix it by anchoring or setting CFrames.**

`CharacterAdded` re-syncs (a carry that survives a respawn plays on the
NEW character only). `PlayerRemoving` stops the entry and clears the
warn set.

**Stale-transaction safety:** stop is driven **only** by "the registry is
empty / the character is invalid" — never by a per-transaction callback.
T100 ending while T101 is live leaves the Grab playing; a late T100
cleanup has no handle to stop T101.

`transactionIdFor(item)` builds a diagnostic string
`'<record.uniqueId>@<startedAt>'`, or `'?@?'` when the shape is wrong.

---

## Public API surface

### `ServerScriptService.Carry.CarryRegistry`

```lua
CarryRegistry.Init()
CarryRegistry.OnChanged(callback: (userId: number) -> ()): () -> ()
CarryRegistry.Get(playerOrUserId: any): any?
CarryRegistry.IsCarrying(playerOrUserId: any): boolean
CarryRegistry.GetKind(playerOrUserId: any): string?
CarryRegistry.Set(userId: number, item: any): (boolean, string?)
CarryRegistry.Clear(userId: number): (any?, string?)
CarryRegistry.ForEach(callback: (userId: number, item: any) -> ())
CarryRegistry.Snapshot(userId: number): { Kind: string?, Name: string?, Steal: boolean? }
CarryRegistry.Error: { -- frozen
  InvalidPlayer, AlreadyCarried, PlayerAlreadyCarrying, NotCarrying, KindMismatch
}
```

`CarryRegistry.Error.AlreadyCarried` is declared but **never returned**.
The actual code for "already carrying" is `PlayerAlreadyCarrying`.

### `ServerScriptService.Carry.ToolLockService`

```lua
ToolLockService.Init()
ToolLockService.IsLocked(playerOrUserId: any): boolean
ToolLockService.Refresh(playerOrUserId: any)
ToolLockService.ForgetPlayer(userId: number)
ToolLockService._TestReset()
```

### `ServerScriptService.Carry.ResetProtectionService`

```lua
ResetProtectionService.Init()
ResetProtectionService.IsProtected(playerOrUserId: any): boolean
ResetProtectionService.Refresh(playerOrUserId: any)
ResetProtectionService.ForgetPlayer(userId: number)
ResetProtectionService._TestReset()
ResetProtectionService.Reason: { -- frozen
  CarryingAnimal, CarryingEgg, Stealing
}
```

### `ServerScriptService.Carry.PlayerGrabService`

```lua
PlayerGrabService.Init()
PlayerGrabService.IsPlaying(playerOrUserId: any): boolean
PlayerGrabService._TestReset()
PlayerGrabService._TestEntryCount(): number
```

---

## Invariants the code enforces

1. **At most one carried object per player.** `Set` rejects with
   `PlayerAlreadyCarrying` if there is already an entry.
2. **The carried kind is always `'egg'` or `'animal'`.** Anything else is
   rejected with `KindMismatch`.
3. **The change feed fires only on committed changes.** A rejected `Set`
   never notifies. A `Clear` that removed nothing never notifies.
4. **Subscribers cannot break the carry path.** Every subscriber call is
   `pcall`-guarded.
5. **The derived services never store the derived state.** They recompute
   from the registry on every query. The only cached value is the
   "already pushed this" flag.
6. **Pushes happen on change only.** A `Refresh` that recomputes the same
   value sends nothing.
7. **The server is authoritative.** `IsLocked` / `IsProtected` always
   reflect live registry state; the client mirror is UX.
8. **The tool unequip is non-destructive.** Tools are parked in the
   `Backpack`, never destroyed, and are usable again after the carry.
9. **An unrecognised carry shape stays protected.** The reset gate fails
   closed.
10. **`PlayerGrabService` keeps one track per character.** A new character
    means the old track is stopped and a fresh `LoadAnimation` runs on
    the new `Animator`.
11. **A stale callback cannot stop a newer carry's pose.** Stop is
    registry-driven only.

---

## Failure and edge-case behaviour

| Situation | Result |
|---|---|
| `Set` with a non-number `userId` | `(false, 'InvalidPlayer')` |
| `Set` with a non-table `item` | `(false, 'InvalidPlayer')` |
| `Set` while already carrying | `(false, 'PlayerAlreadyCarrying')` + warn |
| `Set` with a bad `item.kind` | `(false, 'KindMismatch')` + warn |
| `Set` with an item that has no `record` | **succeeds** — only `kind` is validated. `Snapshot` returns a `nil` name; the transaction id is `'?'`. |
| `Set` when the player has no character | **succeeds** — the unequip is `pcall`-guarded and does nothing. |
| `Clear` with a non-number | `(nil, 'InvalidPlayer')` |
| `Clear` on a non-carrying player | `(nil, 'NotCarrying')` |
| `Get`/`IsCarrying`/`GetKind` with a `Player` instance | works (the `UserId` is extracted) |
| `Get`/`IsCarrying`/`GetKind` with a non-Player instance or a string | `nil` / `false` / `nil` |
| `Snapshot` when not carrying | `{ Kind = nil, Name = nil, Steal = nil }` — `Steal` is `nil`, not `false` |
| `Snapshot` of an egg carry | `Name = record.rarity` |
| `Snapshot` of a plain carry | `Steal = false` |
| `Snapshot` of a steal carry | `Steal = true` |
| A subscriber throws | swallowed by `pcall`; the other subscribers still run |
| `Init()` after subscribers registered | the subscriber list is **wiped** |
| `OnChanged` unsubscribe called twice | the second call is a no-op |
| `ToolLockService.Refresh` for a player with no `Player` object | the cache is updated, **no remote traffic** |
| `ToolLockService.Refresh` when the value is unchanged | no push |
| `ToolLockService.Refresh` when `Remotes.FireClient` throws | logged; the cache is still updated, so the **next change** is the next push |
| `ResetProtectionService.Refresh` for an unknown carry kind | `(true, 'Carrying')` — a reason string **not** in `Reason` |
| `ResetProtectionService.IsProtected` for a non-player | `false` |
| `PlayerGrabService` with no `Grab` animation | warns once per user (`'no-asset'`); the carry continues without a pose |
| `PlayerGrabService` with an `Animation` whose `AnimationId` is `''` | warns once (`'bad-id'`) |
| `PlayerGrabService` with no `Animator` on the character | warns once (`'no-animator'`); the carry continues |
| `PlayerGrabService` with a destroyed character | the entry is dropped, the track stopped |
| `PlayerGrabService.IsPlaying` with a non-player | `false` |

---

## Gotchas that would bite you

1. **`CarryRegistry.Init()` wipes the subscriber list.** The three derived
   services defensively re-subscribe on their own `Init` (each stores and
   drops its unsubscribe handle first), so the wrong order is survivable
   *for them*. A fourth subscriber is not protected.
2. **`CarryRegistry.Set` has a side effect outside the registry:** it
   unequips the player's tools. That is a policy decision living in a
   data module. If your game wants some tools to stay equipped, this
   needs to move out.
3. **`Set` only validates `kind`.** `record`, `originalSlotId`, and
   `startedAt` are unvalidated. `Snapshot` and the transaction id both
   degrade silently on a malformed item.
4. **`CarryRegistry.Error.AlreadyCarried` is dead.** Use
   `PlayerAlreadyCarrying`.
5. **`Set` with a bad item returns `InvalidPlayer`,** not an item-specific
   code. Check `PlayerAlreadyCarrying` and `KindMismatch` first when
   writing a caller.
6. **`Snapshot`'s `Steal` is `nil` when not carrying** and `false` when
   carrying normally. A client doing `if snap.Steal then` is fine; a
   client doing `if snap.Steal == false then` will mis-handle the
   not-carrying case.
7. **`ResetProtectionService` can push a reason the client does not
   know** (`'Carrying'`). Always have a default branch.
8. **`ToolLockService` / `ResetProtectionService` are not enforcement.**
   They mirror to the client. Enforcement is `CarryRegistry.Set`'s
   unequip **plus** an `IsCarrying` check in every server-side `Tool`
   activation.
9. **`PlayerGrabService` needs an upper-body-only clip.** Action4 outranks
   locomotion, so lower-body tracks in the clip freeze the legs.
10. **`PlayerGrabService` cannot stop a stale transaction's track.** This
    is deliberate, but it means an orphaned track can outlive the
    transaction that created it.
11. **`Prompts.Carry.Actions` is a shared contract.** The Inventory
    system's `SlotActionHandler` reads it as its server-side allowlist.
    Changing it changes what the server will accept, not just what the
    client draws.
12. **Eggs have no sell path.** `Prompts.Carry.Actions[Egg]` is
    `{ 'Pickup', 'Hatch' }` and there is no `SellEgg` action, prompt,
    button, or remote anywhere.
13. **The registry is not persisted.** A server restart clears every
    carry. The recovery path (death / leave) is what returns the object;
    a hard server crash mid-carry leaves the record in the profile with a
    `SlotId` that no longer resolves — the persistence audit in the
    PlayerData system is what cleans that up.

---

## What to change to reuse it

**Keep (Grade A):**

- The registry shape (`{ kind, record, originalSlotId, startedAt, steal? }`)
  and the `Set`/`Clear` semantics, including the `PlayerAlreadyCarrying`
  and `KindMismatch` rejections.
- The `OnChanged` change feed with `pcall`-guarded subscribers and an
  idempotent unsubscribe.
- The derived-service pattern: **recompute** on query, **push** on
  change, keep only the "already pushed" flag.
- The reset gate's fail-closed unknown-kind branch.
- The grab service's "one track per character" and "stop is
  registry-driven only" rules.
- `Prompts.Carry.Actions` as a config-driven allowlist shared by the
  client UI and the server dispatcher.

**Change (Grade B):**

- The `ServerStorage.Assets.Animations.Player.Grab` path and the
  `Action4` priority (or drop the service).
- `Prompts.CarryVisual.HeadClearanceStuds` and the carry distance/hold
  durations.
- The reason vocabulary (`CarryingAnimal` / `CarryingEgg` / `Stealing`).
- The `p7:` slot-id prefix, if you use `SlotType` (the registry does not
  mint ids itself).

**Delete outright if unused:**

- `PlayerGrabService` entirely, if you have no authored carry animation.
- `ResetProtectionService`, if your game does not let players reset
  mid-carry.
- `ToolLockService`, if your game has no gameplay `Tool` to lock (but
  keep the `Set`-side unequip or move it out).
- `CarryRegistry.Error.AlreadyCarried` (already dead).
