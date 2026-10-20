# Carry

Owns **"what is this player holding right now"** — the single carried
object (an egg or an animal) — and the three server-side consequences of
holding it.

**Portability:** Grade **A — portable core** for the registry and the
three derived services; Grade **B — game-specific adapter** for the
authored `Grab` animation and the `CarryVisual` tuning. The **A** parts
are `CarryRegistry` (the state + the change feed), `ToolLockService`
(the equipment gate), `ResetProtectionService` (the reset gate), and the
event-driven `PlayerGrabService` *shape*. The **B** parts are
`PlayerGrabService`'s asset path
(`ServerStorage.Assets.Animations.Player.Grab`) and the
`Prompts.CarryVisual.HeadClearanceStuds` value in the config.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

A player can carry **exactly one** object at a time — an egg or an animal.
The design principle the whole system is built around is:

> **There is exactly one source of truth for a carry, and every derived
> state is recomputed from it on change. There is no second boolean that
> can go stale.**

The system is:

- **`CarryRegistry`** — the state. A `{ [userId]: CarriedItem }` table,
  where `CarriedItem = { kind, record, originalSlotId, startedAt, steal? }`.
  It also publishes a **change feed** (`OnChanged`) that fires
  synchronously on every committed `Set` and every `Clear` that actually
  removed an item.
- **`ToolLockService`** — while a player carries anything, they may not
  equip or activate a gameplay `Tool`. Derived from the registry, pushed to
  the client as `CarryLock`.
- **`ResetProtectionService`** — while a player carries anything, the
  client's reset button is greyed out. Derived from the registry, pushed as
  `ResetProtection`.
- **`PlayerGrabService`** — plays the authored "carry" pose on the
  player's character while the carry is live. Derived from the registry,
  driving the existing `Animator` on the character.

All three derived services are **event-driven**: no timers, no polling,
no per-frame loops. Each one subscribes to `CarryRegistry.OnChanged` and
recomputes.

The registry is also what makes **cross-service checks symmetric**:
`EggService.GrabEgg` must reject if the player is carrying an animal, and
`AnimalService.GrabAnimal` must reject if the player is carrying an egg.
With one shared registry, both checks are the same instant lookup.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `CarryRegistry.Init()` | Server | Clears the registry **and the subscriber list**. |
| `CarryRegistry.OnChanged(callback)` | Server | Subscribe to committed carry changes. Returns an unsubscribe function. |
| `CarryRegistry.Get(playerOrUserId)` | Server | The `CarriedItem`, or `nil`. |
| `CarryRegistry.IsCarrying(playerOrUserId)` | Server | `boolean`. |
| `CarryRegistry.GetKind(playerOrUserId)` | Server | `'egg'`, `'animal'`, or `nil`. |
| `CarryRegistry.Set(userId, item)` | Server | Commits a carry. Returns `(boolean, string? error)`. |
| `CarryRegistry.Clear(userId)` | Server | Drops the carry. Returns `(item?, string? error)`. |
| `CarryRegistry.ForEach(callback)` | Server | Iterates every live carry — used by the death / shutdown recovery paths. |
| `CarryRegistry.Snapshot(userId)` | Server | The wire shape `{ Kind, Name, Steal }` for `PlayerState`. |
| `CarryRegistry.Error` | Server | Frozen table of the five error codes. |
| `ToolLockService.Init()` | Server | Subscribes to the registry. |
| `ToolLockService.IsLocked(playerOrUserId)` | Server | Recomputed live from the registry. |
| `ToolLockService.Refresh(playerOrUserId)` | Server | Pushes `CarryLock` **on change only**. |
| `ToolLockService.ForgetPlayer(userId)` | Server | Drops the push cache. |
| `ResetProtectionService.Init()` | Server | Subscribes to the registry. |
| `ResetProtectionService.IsProtected(playerOrUserId)` | Server | Recomputed live. |
| `ResetProtectionService.Refresh(playerOrUserId)` | Server | Pushes `ResetProtection` **on change only**. |
| `ResetProtectionService.ForgetPlayer(userId)` | Server | Drops the push cache. |
| `ResetProtectionService.Reason` | Server | Frozen table of the three reason codes. |
| `PlayerGrabService.Init()` | Server | Subscribes to the registry + connects two `Players` events. |
| `PlayerGrabService.IsPlaying(playerOrUserId)` | Server | Diagnostic query: does the server hold a live Grab track? |
| `PlayerGrabService._TestReset()` | Server | Test seam. |
| `PlayerGrabService._TestEntryCount()` | Server | Test seam. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Carry/CarryRegistry.lua` | `ServerScriptService.Carry.CarryRegistry` | The carry state and the change feed. |
| `Source/ServerScriptService/Carry/ToolLockService.lua` | `ServerScriptService.Carry.ToolLockService` | The gameplay-Tool equipment gate. |
| `Source/ServerScriptService/Carry/ResetProtectionService.lua` | `ServerScriptService.Carry.ResetProtectionService` | The reset gate. |
| `Source/ServerScriptService/Carry/PlayerGrabService.lua` | `ServerScriptService.Carry.PlayerGrabService` | The authored carry pose. |
| `Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage.Config.World.Prompts` | **The Carry system's config** — prompt tuning, the carry action tables, and `CarryVisual`. |

---

## Configuration

This system **does** own a config module: `ReplicatedStorage/Config/World/Prompts.lua`.
It covers every `ProximityPrompt` in the game plus the carry action
tables. The parts that belong to Carry are:

| Value | Default | Meaning |
|---|---|---|
| `Prompts.CarryMaxDistance` | `8` | Server-side distance check for grab/place, in studs. |
| `Prompts.CarryHoldDuration` | `1` | Seconds the player must hold Pick Up / Place. |
| `Prompts.CarryVisual.HeadClearanceStuds` | `2.5` | Vertical clearance between the top of the player's `Head` and the carried animal's pivot. |

And the action tables the rest of the game reads:

| Value | Default | Meaning |
|---|---|---|
| `Prompts.Carry.Actions[Egg]` | `{ 'Pickup', 'Hatch' }` | Which actions exist on an occupied egg slot. **Eggs are not sellable — there is no `SellEgg` anywhere.** |
| `Prompts.Carry.Actions[Animal]` | `{ 'Pickup', 'SellAnimal' }` | Which actions exist on an occupied animal slot. Animals do not open. |
| `Prompts.Carry.Actions.Empty` | `{ 'Place' }` | An empty slot only accepts a Place. |
| `Prompts.Carry.Actions.Reserved` | `{ 'Place' }` | A reserved slot (the player's own carry reservation) accepts a Place back home. |
| `Prompts.Carry.ActionText` | Pickup/Hatch/Place/Steal/Sell labels + keybinds + Y offsets | Display only. |
| `Prompts.Carry.PerKind` | `Grab`/`Place`/`Hatch` text per kind | Display only. |

The per-prompt definitions (`Prompts.AnimalPickup`, `Prompts.EggHatch`,
`Prompts.Steal`, `Prompts.DoorOpen`, `Prompts.AnimalSell`,
`Prompts.Place`, `Prompts.CenterEggBuy`, `Prompts.Arena`,
`Prompts.GearShop`) are also in this module but belong to the systems
that use them.

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ReplicatedStorage.Types.SlotType` — the `OccupantKind` values
  (`'egg'` / `'animal'`).
- `ReplicatedStorage.Utility.Remotes` — the `CarryLock` and
  `ResetProtection` channels.
- `ReplicatedStorage.Utility.Debug` — the logging channel.
- `ServerStorage.Assets.Animations.Player.Grab` — the authored
  animation (`PlayerGrabService` only).

**This system is a dependency of others, not only a dependant.**
`PlayerData`/`PlayerService` requires `CarryRegistry` on cleanup (to
return a carried object), and the Inventory system's
`SlotActionHandler` requires it for the carry gate.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  CarryRegistry.Init()              -- CLEARS the registry and the
                                        subscriber list; do this FIRST
3.  ToolLockService.Init()            -- subscribes to CarryRegistry
4.  ResetProtectionService.Init()     -- subscribes to CarryRegistry
5.  PlayerGrabService.Init()          -- subscribes to CarryRegistry
```

**The order matters in one direction only.** `CarryRegistry.Init()` resets
`_subscribers` to an empty table. Therefore **every** service that
subscribes must do so **after** `CarryRegistry.Init()`. All three derived
services handle this defensively — each stores its unsubscribe handle and
re-subscribes on its own `Init` — but the correct order is registry first.

`PlayerGrabService.Init()` also connects `Players.PlayerAdded` and
`Players.PlayerRemoving` **exactly once** (guarded by a `playersWired`
flag), so calling it twice is safe.

**On player leave:**

```text
CarryRegistry.Clear(userId)        -- the recovery path does this
    -> the change feed fires
    -> ToolLockService.Refresh      -> pushes CarryLock { Locked = false }
    -> ResetProtectionService.Refresh -> pushes ResetProtection { Protected = false }
    -> PlayerGrabService.syncGrab   -> stops the Grab track
ToolLockService.ForgetPlayer(userId)
ResetProtectionService.ForgetPlayer(userId)
```

---

## Data

**No profile fields are read or written by this system.** The carried
object itself lives in the profile's owned-object lists (`Brainrots` /
`LuckyBlocks`) — the registry only holds a **reference** to the live
record.

### `CarriedItem` shape

| Field | Type | Meaning |
|---|---|---|
| `kind` | `'egg' \| 'animal'` | `SlotType.OccupantKind.*`. **Validated by `CarryRegistry.Set`.** |
| `record` | table | The live egg/animal record. `record.uniqueId` is the object id. |
| `originalSlotId` | string | The slot the object came from. Used by `RecoverForPlayer` to put it back. |
| `startedAt` | number | `os.tick()` at grab. Diagnostic only ("stuck carry" detection). |
| `steal` | table? | Present **only** for a steal carry. Its presence is what marks the carry as a steal. |

### Snapshot wire shape (`CarryRegistry.Snapshot`)

```lua
{ Kind = 'animal'?, Name = 'Tralalero'?, Steal = false? }
```

- `Name` is `record.displayName` for an animal, `record.rarity` for an egg
  (egg records have no `displayName`).
- `Steal` is `true` when `item.steal ~= nil`, `false` for a plain carry,
  and **`nil`** when the player is not carrying anything. The distinction
  matters: the client uses `Steal` to suppress the thief's own prompts
  during a steal.

---

## Known Limitations

- **`CarryRegistry.Init()` clears the subscriber list.** Any service that
  subscribed before it loses its subscription silently. The three derived
  services in this system re-subscribe on their own `Init` so the order
  is survivable, but a **fourth** service must be careful.
- **`CarryRegistry.Set` unequips the player's tools as a side effect.**
  It calls `Humanoid:UnequipTools()` inside a `pcall`. Tools are moved to
  the `Backpack`, **never destroyed** — they are usable again once the
  carry ends. But it is surprising for a "registry" to mutate the
  player's inventory, and a caller that sets a carry before the character
  exists silently does nothing.
- **The `Set` tool-unequip is best-effort only.** A forged request or a
  mid-carry re-equip can still put a `Tool` in the player's hand, which
  is why every server-activated `Tool` must **also** gate on
  `CarryRegistry.IsCarrying`. `ToolLockService` is the client-side mirror,
  not the enforcement point.
- **`ToolLockService` and `ResetProtectionService` push on change only.**
  If a client misses the push (it joined late, or the remote errored), it
  stays in the wrong state until the next change. The server-side
  `IsLocked` / `IsProtected` queries are always correct; only the client
  mirror can drift. The failure path is logged
  (`'Refresh: push failed (client syncs on next change)'`).
- **`ResetProtectionService` is not the recovery path.** The existing
  `Died` / `CharacterRemoving` / `PlayerRemoving` recovery still runs and
  still owns the animal. The protection service only *disables the reset
  button*; it never resolves a carry.
- **`ResetProtectionService` is fail-safe in the "stay protected"
  direction for an unknown carry kind.** A registry entry with a kind
  that is neither animal nor egg yields `Protected = true` with reason
  `'Carrying'` — the string `'Carrying'` is **not** in
  `ResetProtectionService.Reason`, so a client that switches on the
  reason must have a fallback.
- **`PlayerGrabService` requires the `Grab` animation to be an
  upper-body-only clip.** The code plays it at `AnimationPriority.Action4`
  (which outranks the stock `Idle`/`Movement` locomotion tracks). If the
  authored clip contains lower-body tracks, the character's legs freeze
  while walking. The header flags this as an unverified inspection gap —
  the assets are Studio-authored and not in the repo. The fix is to
  re-author the clip without lower-body tracks, or to lower the
  priority. **Do not "fix" it by anchoring or setting CFrames.**
- **`PlayerGrabService` cannot stop a stale transaction's track.** Stop
  is driven only by "the registry is empty / the character is invalid" —
  never by a per-transaction callback. If transaction T100 ends while
  T101 is live, T100's late cleanup has no handle to stop T101's track.
  This is deliberate (it prevents a stale callback from killing a newer
  carry's pose) but it means an orphaned track can survive a transaction
  that thinks it stopped.
- **`PlayerGrabService` warns on a missing asset once per user, but the
  warning set is only cleared on a successful Grab start.** A player who
  never successfully starts a carry keeps the one warning.
- **`CarryRegistry.Set` does not validate the item's `record`,
  `originalSlotId`, or `startedAt`.** Only `kind` is validated. A caller
  can `Set` an item with no record, and `Snapshot` will return a `nil`
  name, and `PlayerGrabService`'s transaction id will be `'?'`.
- **`ForEach` iterates a live table.** A callback that calls `Clear` on
  the player it is visiting mutates the table during iteration. The
  recovery paths are written to tolerate this, but a new caller must be
  careful.

---

## Testing

`Tests/CarryRegistry.spec.lua` — the registry only:

- `Set` records the item and `Get` returns it.
- `Set` fails with `PlayerAlreadyCarrying` when already carrying.
- `IsCarrying` flips `false → true → false` across `Set`/`Clear`.
- `Clear` on a non-carrying player returns `NotCarrying`.
- `GetKind` returns the kind or `nil`.
- `Snapshot` returns `Kind`/`Name`/`Steal` all `nil` when not carrying.
- `Snapshot` flags a steal carry (`steal` field present) and resolves
  the animal `displayName` / egg `rarity` as the name.
- `ForEach` iterates every live carry.
- `Init` clears the registry.

`ToolLockService`, `ResetProtectionService`, and `PlayerGrabService`
have **no spec in this library** — their logic is thin wrappers over the
registry, but they are worth testing in a new game because they own the
client-push behaviour (change-only pushes, `ForgetPlayer`).

The spec requires the shared `Tests/_Helpers.lua` and still requires
**Roblox Studio**. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Keep the registry as the only state.** The whole system's value is
   that there is exactly one boolean per player, and everything else is
   derived. If you add a second "is carrying" flag somewhere, the
   staleness bugs come back.
2. **Keep the `OnChanged` feed.** It is what makes the three derived
   services event-driven instead of polling. Extend it if you add a
   fourth consequence.
3. **Re-author `ServerStorage.Assets.Animations.Player.Grab`** as an
   upper-body-only clip, or drop `PlayerGrabService` entirely. It is
   presentation and is the only part of this system that is not
   self-contained.
4. **Change the `p7:` id prefix** in `SlotType` if you use it — the
   registry itself does not mint ids, but `originalSlotId` and
   `record.uniqueId` flow from those systems.
5. **Do not port the `Set`-side `UnequipTools` blindly.** If your game has
   tools that are *meant* to stay equipped while carrying (a shield, a
   pet), the blanket unequip is wrong. Split it into a per-tool policy.
6. **Add a server-side gate on every gameplay `Tool` activation** that
   checks `CarryRegistry.IsCarrying(player)`. The client-side
   `CarryLock` mirror is UX, not enforcement.
7. **Keep the reason vocabulary small** (`CarryingAnimal`,
   `CarryingEgg`, `Stealing`) and give your client a fallback for
   `'Carrying'`.
