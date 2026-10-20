# Inventory

Owns **slot state** — the unified per-base pool of stands that hold either an
egg or an animal — and the two surfaces that read/write it: the server-side
action dispatcher and the slot menu.

**Portability:** Grade **A — portable core** for the slot state machine and
the action/menu dispatchers; Grade **B — game-specific adapter** for the
money/level/upgrade previews and the warning-message catalogue. The **A**
parts are `SlotService` (the state machine, the id index, the snapshot wire
shape) and `SlotMath` (pure placement geometry). The **B** parts are
`SlotMenuService`'s preview/confirm payloads (BigNumber prices, rebirth
gates, `WarningMessages` ids) and `SlotActionHandler`'s message mapping.

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

The game has **one slot pool per base** (`Bases.Slots.Count = 8` in the
current config), shared by eggs and animals. A slot record moves through a
three-state machine:

```text
Empty ──ReserveSlot──▶ Reserved ──OccupySlot──▶ Occupied
  ▲                        │  ▲                     │
  └──────ReleaseSlot───────┘  └──DemoteSlotToReserved──┘
```

Three modules implement it:

- **`SlotService`** — the single source of truth for slot state. Owns the
  O(1) `slotById` index, the per-slot `_mutex`, the transition methods, and
  the wire-shape snapshot. It does **not** own the slot records themselves
  (`BaseService` does) and it does **not** own the cash-pool values.
- **`SlotActionHandler`** — the server-side dispatcher for slot prompt
  actions (`Pickup`, `Hatch`, `Place`, `SellAnimal`). It validates the
  request against ownership, occupant, and the carry state, then routes to
  the egg/animal/sell services. It is the only path from a prompt to a
  service.
- **`SlotMenuService`** — the server side of the per-slot upgrade menu.
  Two endpoints: a **preview** (authoritative read) and an **Upgrade
  confirm** (the only mutating endpoint). Selling is *not* here — it lives
  on the animal's own Sell prompt and routes through `SlotActionHandler`.
- **`SlotMath`** — pure geometry. Computes where a model's `PrimaryPart`
  must sit so the model's lowest bottom face is flush with the slot's top
  surface, and which way it should face. Shared by the rejoin-spawn path
  and the walk controller so the two can never drift.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `SlotService.Init()` | Server | No-op. |
| `SlotService.RegisterBase(base)` | Server | Idempotent. Indexes `base.slots` and calls `RegisterArenaSlots`. |
| `SlotService.RegisterArenaSlots(base)` | Server | Indexes `base.arenaSlots` into `slotById` but **not** into `slotsByBase`. |
| `SlotService.UnregisterBase(baseId)` | Server | Drops the base's index entries, the owner binding, and the menu warnings. |
| `SlotService.UnregisterArenaSlots(baseId)` | Server | Drops arena index entries **by record identity**, not by id string. |
| `SlotService.SetBaseOwner(userId, base)` | Server | Binds a base to its owner. |
| `SlotService.ClearBaseOwner(userId)` | Server | Drops the owner binding. |
| `SlotService.RebaseSlotIds(base)` | Server | Re-indexes after slot ids are re-stamped on assignment; re-stamps the Studio menu button's `slotId` attribute. |
| `SlotService.RefreshDisplays(slotId)` | Server | Re-paints one slot through both display hooks. Returns `false` for an unknown id. |
| `SlotService.GetFreeSlot(userId)` | Server | First `Empty` slot with no held mutex, or `nil`. |
| `SlotService.FindSlotByOccupant(occupantId)` | Server | `(slot, nil)` or `(nil, nil)`. Searches normal **and** arena slots. |
| `SlotService.GetNearestValidSlotForPlayer(userId, pos)` | Server | **Deprecated stub — always returns `nil`.** |
| `SlotService.ReserveSlot(slotId)` | Server | `Empty → Reserved`. |
| `SlotService.DemoteSlotToReserved(slotId)` | Server | `Occupied → Reserved`, **keeps** `occupantId`/`occupantKind`. |
| `SlotService.OccupySlot(slotId, occupantId, occupantKind?)` | Server | `Reserved → Occupied`; fires the occupied-count callback `+1`. |
| `SlotService.ReleaseSlot(slotId)` | Server | `→ Empty`; fires the occupied-count callback `-1` if it was occupied. |
| `SlotService.ReleaseReservedSlotForUser(userId, index)` | Server | Releases a `Reserved` slot by **1-based index** in the owner's base. |
| `SlotService.SnapshotBaseSlots(base)` | Server | The wire array: normal slots by index, then arena slots appended with `Arena = true`. |
| `SlotService.SetOccupiedCountCallback(fn)` | Server | Bootstrap injection. `fn(slot, delta)` where delta is `+1`/`-1`. |
| `SlotService.SetPoolDisplayCallback(fn)` | Server | Bootstrap injection. `fn(slot)` — republish the cash-pool attribute + money label. |
| `SlotService.SetStandDisplayCallback(fn)` | Server | Bootstrap injection. `fn(slot)` — repaint the stand's direct-upgrade readout. |
| `SlotService._findSlotById(slotId)` | Server | Public-ish (underscore) — used by `SlotActionHandler` and `SlotMenuService`. |
| `SlotService._dump()` | Server | Test/debug: returns the raw `slotById` table. |
| `SlotActionHandler.Handle(player, request)` | Server | The dispatcher. Returns `{ success, error?, detail? }`. **Never throws.** |
| `SlotActionHandler.Error` | Server | Frozen table of the nine stable error codes. |
| `SlotMenuService.Init()` | Server | Connects the `SlotMenuRequest` / `SlotMenuAction` remotes. |
| `SlotMenuService.BuildMenuState(player, slotId)` | Server | The authoritative preview table. |
| `SlotMenuService.HandleAction(caller, payload)` | Server | The confirm endpoint. Returns `{ SlotId, Success, Error? }`. |
| `SlotMenuService.SetPlayerService/SetBaseService/SetSlotService/SetAnimalService/SetEggService/SetModifierService/SetUpgradeService/SetStandDisplayService(ps)` | Server | Bootstrap injections. |
| `SlotMenuService.ForgetPlayer(userId)` | Server | Clears the throttle maps. |
| `SlotMath.FeetOffsetBelowPrimary(model)` | Server/Client | Local-Y offset from the `PrimaryPart` down to the model's lowest bottom face. Negative. |
| `SlotMath.StandingCFrameOnSlot(model, slot)` | Server/Client | The `CFrame` that lands the model flush on the slot. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Base/SlotService.lua` | `ServerScriptService.Base.SlotService` | The slot state machine, id index, and snapshot. |
| `Source/ServerScriptService/Action/SlotActionHandler.lua` | `ServerScriptService.Action.SlotActionHandler` | Server-side prompt-action dispatcher. |
| `Source/ServerScriptService/SlotMenuService.lua` | `ServerScriptService.SlotMenuService` | The server side of the per-slot upgrade menu. |
| `Source/ServerScriptService/Animal/SlotMath.lua` | `ServerScriptService.Animal.SlotMath` | Pure placement geometry. |

---

## Configuration

There is **no config module of its own.** The tunables it reads live in other
systems' configs and are documented there:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `Bases.Slots.Count` | `Config/World/Bases.lua` | `8` | Unified slots per base (eggs + animals share the pool). |
| `Bases.Slots.Size` | `Config/World/Bases.lua` | `Vector3.new(3.5, 0.6, 3.5)` | Authored slot part size. |
| `Bases.Slots.Offsets` | `Config/World/Bases.lua` | 8-stop ring, radius 12, Y 2 | Layout offsets. |
| `Bases.Stands.Labels.*` | `Config/World/Bases.lua` | `'Upgrade'`, `'Unavailable'`, `'Max Level'`, `'Max'`, `'/sec'`, `'N/A'`, `'Egg'`, `'Lv. '` | Menu labels the server formats into the preview. |
| `Bases.Stands.UpgradeReadout.RateDecimals` | `Config/World/Bases.lua` | `2` | Decimals for the `$/sec` rate (trailing zeros trimmed). |
| `Prompts.Carry.Actions` | `Config/World/Prompts.lua` | Egg `{Pickup, Hatch}`, Animal `{Pickup, SellAnimal}`, Empty/Reserved `{Place}` | **The allowlist** the dispatcher enforces. |
| `Prompts.Carry.ActionText` | `Config/World/Prompts.lua` | Pick up/Hatch/Place/Steal/Sell labels | Display labels. |
| `Prompts.Carry.PerKind` | `Config/World/Prompts.lua` | `Grab`/`Place`/`Hatch` text per kind | Display labels. |
| `Security.RequestThrottleSeconds` | `Config/Systems/Security.lua` | `0.5` | The menu's per-player per-endpoint throttle. |
| `Progression.MaxLevel` | `Config/Creatures/Progression.lua` | `100` | The level cap the menu previews against. |

Note the split: **`Bases`, `Prompts`, `Security`, and `Progression` are
owned by other systems** (`BasesAndSlots`, `Carry`, `AdminTools`, `Upgrades`).
This system only reads them.

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ReplicatedStorage.Config.World.Bases` — slot count and stand labels.
- `ReplicatedStorage.Config.World.Prompts` — the per-kind action allowlist.
- `ReplicatedStorage.Types.SlotType` — the state/occupant-kind constants and
  the `p7:<userId>:slot:<index>` id format.
- `ReplicatedStorage.Utility.StandResolver` — resolves the Studio stand
  hierarchy (`Stand.Button.Base`, `Slot.MenuPart.MenuGui.UpgradeButton`).
- `ServerScriptService.BaseService` — **not in this library**; owns the slot
  records and the base table. `SlotActionHandler` and `SlotMenuService`
  require it directly.
- `ServerScriptService.Carry.CarryRegistry` — the carry gate. **In the
  Carry system of this library.**
- `ServerScriptService.EggService` / `AnimalService` / `SellService` — the
  dispatch targets. Required **lazily** inside the handler to break a
  require cycle.
- `ServerScriptService.Base.NotificationService` — the one warning channel.
- `ReplicatedStorage.Utility.Remotes` — `SlotMenuRequest` / `SlotMenuState` /
  `SlotMenuAction` / `SlotMenuResult`.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  SlotService.Init()                      -- no-op, but call it for symmetry
3.  BaseService.Init() → RegisterBases(workspace)
        → SlotService.RegisterBase(base)     -- indexes base.slots
4.  bootstrap wires the three display callbacks:
        SlotService.SetOccupiedCountCallback(BaseService's counter updater)
        SlotService.SetPoolDisplayCallback(IncomeService's pool republisher)
        SlotService.SetStandDisplayCallback(StandDisplayService's refresher)
5.  SlotMenuService.Init()                  -- connects the menu remotes
6.  bootstrap injects into SlotMenuService:
        SetPlayerService / SetBaseService / SetSlotService / SetAnimalService
        / SetEggService / SetModifierService / SetUpgradeService
        / SetStandDisplayService
7.  On player join:
        BaseService.AssignBaseForPlayer(userId)
            → SlotService.SetBaseOwner(userId, base)
            → SlotService.RebaseSlotIds(base)   -- re-stamps ids + menu buttons
```

**Order matters:** `SlotService.RegisterBase` must run before any
transition, because every transition resolves the slot through
`slotById`. `RebaseSlotIds` must run after the ids change, or the index
still points at the old id strings.

`SlotMenuService.Init` must run **after** the `Remotes` folder exists —
otherwise it warns and the menu silently does nothing.

---

## Data

**No profile fields are written by this system.** It reads the profile
read-only, through `PlayerService.GetPlayerData(userId)`, to look up an
animal's `CashPool` for the menu's pool preview.

The slot record itself is **runtime-only** — it is not persisted. Persistence
lives in the profile's owned-object lists (`Brainrots`, `LuckyBlocks`), keyed
by `SlotId`.

### Slot record shape

| Field | Type | Meaning |
|---|---|---|
| `id` | string | `p7:<userId>:slot:<index>`. Re-stamped on owner assignment. |
| `ownerUserId` | number | The slot's owner. |
| `baseId` | string | The owning base. |
| `kind` | `'slot'` | Always the unified keyword. |
| `index` | number | 1-based slot index (arena slots use `1000 + k`). |
| `state` | `'Empty' \| 'Reserved' \| 'Occupied'` | The state machine. |
| `occupantId` | string? | The egg/animal `uniqueId`. **Kept during `Reserved`** after a demote. |
| `occupantKind` | `'egg' \| 'animal' \| nil` | The runtime discriminator. |
| `_mutex` | boolean | Held while a transition runs. |
| `part` | BasePart? | The Studio slot part. |
| `stand` | Instance? | The Studio stand (when the slot is stand-backed). |
| `cashCollector` | Instance? | The cash trigger (used by `CollectFeedback`). |
| `offset` | Vector3 | Layout offset. |
| `arena` | boolean? | Marks an arena slot. |

### Snapshot wire shape (`SlotService.SnapshotBaseSlots`)

Normal slots occupy indices `1..Bases.Slots.Count`; arena slots are
**appended** after them with `Arena = true` (so existing clients that index
numerically are unaffected, and HUD row loops that ignore the tail still
work).

```lua
{ Index = 1, Id = 'p7:123:slot:1', State = 'Occupied',
  OccupantId = 'AN_...', OccupantKind = 'animal',
  Position = Vector3, Arena = false? }
```

---

## Known Limitations

- **`SlotService.ReleaseReservedSlotForUser` takes a 1-based *index*, not a
  slot id**, while every other write method takes a slot id. It also
  **bypasses the `_mutex`** entirely — it does not check `slot._mutex`, does
  not fire the display callbacks, and does not fire the occupied-count
  callback. It only works because a `Reserved` slot is not counted as
  occupied. Easy to misuse.
- **`GetNearestValidSlotForPlayer` is a stub that always returns `nil`.**
  It exists only so the legacy `_placeCallback` resolver still compiles.
  Do not call it.
- **`SlotService` is `table.freeze`d**, and the two callbacks are stored in
  **local upvalues** (not on the module) precisely so the assignment does
  not error on a frozen table. Consequence: `SlotService.SetOccupiedCountCallback`
  can only be called **once per upvalue** — calling it again replaces the
  previous callback, and there is no way to read it back.
- **`findSlotById` has an O(n) slow path** that linearly scans every base's
  slots (and every base's arena slots) when the O(1) index misses. That
  scan exists to survive a re-stamped id. On a busy server with many bases
  a stale-id call is not free.
- **`SlotActionHandler`'s error code and its notification id are two
  different vocabularies.** The returned `error` is one of nine stable
  codes; the toast comes from a *separate* `rejectionReason` mapping that
  inspects the underlying service's `detail` string. The `detail` strings
  are matched by literal equality against a long list of service-specific
  spellings (`'too-far'`, `'TooFar'`, `'player-not-live'`, …) — a service
  that changes its detail string silently loses its specific toast and falls
  back to `'General_Generic'`.
- **The `Sell` action is a permanent placeholder** returning
  `NotImplemented`. The live path is `SellAnimal`.
- **Eggs have no sell path at all.** `Prompts.Carry.Actions[Egg]` contains
  only `Pickup` and `Hatch`; a `SellEgg` request falls through to
  `InvalidAction`.
- **`SlotMenuService` owns Upgrade only.** Selling is on the animal's own
  prompt. A forged sell confirm is rejected with `'not-supported'` — but
  it still shows a `'Menu_StaleTarget'` toast, which is a misleading
  message for that case.
- **The menu preview computes the effective generation rate** as
  `AnimalStats.Calculate(like, 'Income') * modifierService.GetMoneyMultiplier(userId)`.
  It builds a *synthetic* `like` table (`{ DefId, Level, Trait, Mutations }`)
  rather than reading the live animal record's stats. If `AnimalStats`
  grows a new input field, the preview silently uses a stale one.
- **`SlotMenuService` throttles with `os.clock()`**, not `os.time()`. That
  is correct for a per-session throttle (monotonic), but it means the
  throttle window is CPU-time, not wall-time, on a busy server.
- **`SlotMenuService` never notifies on an upgrade rejection** — it relies
  on `UpgradeService` having already notified. If `UpgradeService` is
  unwired, the player gets a rejection with **no** toast.

---

## Testing

Four spec files, all under `Tests/`:

| Spec | Covers |
|---|---|
| `SlotMath.spec.lua` | The feet-offset math: HipHeight branch, scale-awareness, invisible/Accessory skipping, PrimaryPart's own bottom. |
| `UnifiedSlot.spec.lua` | The state machine end to end: Empty→Reserved→Occupied→Empty, demote, place-to-original, place-to-different, in-place open, refund, 6/6 full, mixed kinds. |
| `SlotActionHandler.spec.lua` | Input validation, ownership, the action allowlist, the carry gate, occupant mismatch, the single-flight guard, `SellAnimal` routing, and that `SellEgg` has no path. |
| `SlotMenuService.spec.lua` | The menu preview (animal/egg/empty/foreign), the confirm endpoint, and the stand repaint after an XP level-up. |

They require the shared `Tests/_Helpers.lua` and still require **Roblox
Studio** (they build real instances and call real `TweenService`/`Task`).
See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Keep the three-state machine.** `Empty / Reserved / Occupied` with a
   per-slot `_mutex` is the reusable core. A `Reserved` slot that keeps its
   `occupantId` is what makes "grab then place on a different slot" work.
2. **Keep the `slotById` index and the `RebaseSlotIds` re-stamp.** If your
   game assigns bases after building the stands, slot ids change; without
   `RebaseSlotIds` the index goes stale and every transition fails to find
   the slot.
3. **Change the id prefix.** `SlotType.BuildId` hardcodes `p7:`. A new game
   must change that literal in `Shared/Types/SlotType.lua` — and every
   persisted `SlotId` key with it.
4. **Rewrite the action allowlist.** `Prompts.Carry.Actions` is the single
   source of truth for "which actions exist for this (kind, state) tuple",
   used by both the client UI and the server dispatcher. Keep it in config,
   not in code, if your game adds actions.
5. **Drop the money/level previews if you do not need them.**
   `SlotMenuService.BuildMenuState` is where the game's economy leaks in.
   The dispatcher (`SlotActionHandler`) is the part worth lifting wholesale.
6. **Do not lift `SlotActionHandler`'s `rejectionReason` table as-is.** It
   is a literal string-equality map over other services' error strings.
   Replace it with typed error codes when you port.
7. **Author the Studio hierarchy** the way `StandResolver` expects — see
   `Setup.md`.
