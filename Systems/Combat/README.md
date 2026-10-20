# Combat

Server-authoritative Bat PvP: swing validation, hitbox, carry
interruption, ragdoll, knockback, and hit SFX.

**Portability:** Grade A core (the swing pipeline, the ragdoll
authority, the catalog/lookup shape) + Grade B (the bat tuning
numbers, the gear catalog, the `p7:` slot ids, the "no damage"
convention).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

`Combat` is two server modules plus one config module:

- **`BatService`** — listens on the `BatSwing` remote. The client
  sends **one** empty event ("I swung"); the server resolves
  everything else: is the swing legal, is the cooldown elapsed, which
  players are in the hitbox, and then per target it interrupts any
  carry, ragdolls, knocks back, and plays one cycled hit SFX.
  All of it happens **synchronously in the swing path** — no waits,
  no polling, no animation gating.
- **`RagdollService`** — the R15 ragdoll authority. `BatService` calls
  `Ragdoll` / `Unragdoll` / `IsRagdolled`; the joint work lives only
  here, and the timed, repeat-safe recovery layer lives only here.
- **`Config/Economy/Gear`** — the gear shop catalog *and*, attached to
  it as `Gear.Combat`, the per-bat combat tuning table. The bat tuning
  is **keyed by GearId AND by the granted Tool Instance name**.

There is **no damage** in this system. A bat hit is knockback +
ragdoll + a stolen carry, never a health reduction.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `BatService.Init()` | Server | Wires `Remotes.Names.BatSwing` → `onSwing`. Idempotent (`_wired` guard). Must be called after the Remotes folder exists. If the remote is missing it warns and **disables bat hits** rather than throwing. |
| `BatService._TestReset()` | Test | Clears the per-player swing-cooldown table, the ragdoll-immunity table, and resets the SFX cycle counter. Does **not** unwire the remote. |
| `RagdollService.IsRagdolled(player)` | Server | `true` if `player` currently has a ragdoll record. |
| `RagdollService.Ragdoll(player, duration)` | Server | Ragdolls `player` for `duration` seconds and schedules the timed recovery. Returns `false` (never throws) on every rejection path. |
| `RagdollService.Unragdoll(player, token?)` | Server | Ends the ragdoll. With a `token`, only if the record's token matches. Returns `true` if a record was ended (or a stale record was dropped). |
| `RagdollService._TestReset()` | Test | Clears all ragdoll records. Does **not** restore the rig — a ragdolled player stays ragdolled. |
| `Gear.GetAll()` | Shared | The gear shop catalog (13 entries, in shop display order). |
| `Gear.FindGear(id)` | Shared | Catalog lookup by `Id`. |
| `Gear.IsLocked(playerRebirth, required)` | Shared | `true` when the player has not reached the required rebirth count. |
| `Gear.ValidateList(entries, toolProbe?)` | Shared | Pure validation over an entry list. Returns an array of issue strings. |
| `Gear.ValidateLive()` | Shared | `ValidateList` against the live `ServerStorage.Assets.Ui.GearShop.Tools` hierarchy. |
| `Gear.Combat.GetByGearId(gearId)` | Shared | Combat tuning by `GearId`. |
| `Gear.Combat.GetByToolName(toolName)` | Shared | Combat tuning by the **granted Tool Instance name** (e.g. `'Silver Bat'`). This is the entry point the server actually uses. |
| `Gear.Combat.All()` | Shared | All combat entries, in a fresh array. |
| `Gear.Combat.Validate()` | Shared | Returns an array of issue strings for the combat table. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Combat/BatService.lua` | `ServerScriptService.Combat.BatService` | The swing pipeline: validation, hitbox, target dedupe, carry interruption, ragdoll, knockback, hit SFX. |
| `Source/ServerScriptService/Combat/RagdollService.lua` | `ServerScriptService.Combat.RagdollService` | R15 ragdoll authority and timed recovery. |
| `Source/ReplicatedStorage/Config/Economy/Gear.lua` | `ReplicatedStorage.Config.Economy.Gear` | Gear shop catalog + the `Combat` sub-table of per-bat tuning. |

---

## Configuration

The system's own config is `ReplicatedStorage/Config/Economy/Gear.lua`. The
consolidated, documented view of its tunables is in
[`Config.lua`](Config.lua).

The combat table (`Gear.Combat`) has one entry per bat Tool:

| GearId | ToolName | SwingCooldown | Hitbox Size | Hitbox Offset | Knockback H/V | RagdollDuration | RagdollImmunity |
|---|---|---|---|---|---|---|---|
| `DefaultBat` | `Default Bat` | 1.0 | (4.5, 5, 5.5) | CFrame(0,0,-2.8) | 60 / 20 | 1.25 | 1.25 |
| `SilverBat` | `Silver Bat` | 0.8 | (5, 5, 6) | CFrame(0,0,-3) | 70 / 25 | 1.5 | 1.25 |
| `GoldBat` | `Gold Bat` | 0.7 | (5, 5, 6) | CFrame(0,0,-3) | 80 / 30 | 1.75 | 1.25 |
| `DiamondBat` | `Diamond Bat` | 0.65 | (5.5, 5.5, 6.5) | CFrame(0,0,-3.2) | 90 / 35 | 2.0 | 1.25 |
| `ObsidianBat` | `Obsidian Bat` | 0.6 | (5.5, 5.5, 6.5) | CFrame(0,0,-3.2) | 100 / 40 | 2.25 | 1.25 |
| `CrystalBat` | `Crystal Bat` | 0.55 | (6, 6, 7) | CFrame(0,0,-3.5) | 115 / 45 | 2.5 | 1.25 |
| `HackerBat` | `Hacker Bat` | 0.6 | (5.5, 5.5, 6.5) | CFrame(0,0,-3.2) | 90 / 35 | 2.0 | 1.25 |
| `GalaxyBat` | `Galaxy Bat` | 0.5 | (6.5, 6.5, 7.5) | CFrame(0,0,-3.7) | 130 / 50 | 2.75 | 1.25 |

`RagdollImmunity` is **1.25 for every bat** — it is a constant in
practice, not a per-tier tuning knob.

The shop catalog (`Gear.GetAll()`) has 13 entries: `SpeedCoil`,
`SilverBat`, `GravityCoil`, `GoldBat`, `CoilCombo`, `DiamondBat`,
`ObsidianBat`, `CrystalBat`, `InvisibleCloak`, `HackerBat`,
`GalaxyBat` (Robux-only), `DefaultBat` (the free starting bat).
Every `Description` is prefixed `PLACEHOLDER:` except `GalaxyBat`'s —
the prices and descriptions are **explicitly marked as not final
balance** in the source header.

`Gear.Viewport` (`DistanceFactor = 1.4`, `MinDistance = 2`,
`Direction = Vector3.new(1, 0.6, 1.6)`) is shop-preview framing read
by `GearShopController` — it belongs to the Shops system, not to
combat, but it lives in the same config module.

Debug gating for this system comes from
`ReplicatedStorage.Config.Systems.Debug` (see
[`Dependencies.md`](Dependencies.md)).

---

## Dependencies

See [`Dependencies.md`](Dependencies.md) for the full list. The
load-bearing ones:

- `ReplicatedStorage.Config.Economy.Gear` — the bat tuning table.
- `ReplicatedStorage.Utility.Remotes` — the `BatSwing` remote.
- `ReplicatedStorage.Utility.Validation` — `LivePlayer` gate.
- `ReplicatedStorage.Utility.AudioGroups` — stamps the hit SFX into
  the `GameSound` group.
- `ServerScriptService.Steal.StealService` — `RollbackIfStealing`,
  used to cancel a steal-in-progress on a hit target.
- `ServerScriptService.Carry.CarryRegistry` — `IsCarrying` (the
  tool lock) and `Get` (to find what the target is holding).
- `ServerScriptService.AnimalService` /
  `ServerScriptService.EggService` — `RecoverCarriedAnimal` /
  `RecoverCarriedEgg`, to return a hit target's own carried object.

**Remotes:** `BatSwing` (C→S, no payload). There is deliberately **no
hit-result remote** — the confirmed-hit sound is server-mounted on the
target's HRP.

---

## Initialization Order

In the source game's bootstrap (`src/ServerScriptService/bootstrap.server.lua`):

```text
1. createRemotes()                  -- the Remotes folder must exist
2. BaseService.RegisterBases(Workspace)
3. BaseLockService.Init()
4. StealService.SetPlayerService(PlayerService)
5. StealService.Init()
6. StealService.Start()
7. BatService.Init()                -- after StealService: a bat hit calls
                                     -- StealService.RollbackIfStealing
8. GearShopService.SetPlayerService(PlayerService)
9. GearShopService.SetEconomyService(EconomyService)
10. GearShopService.Init()          -- grants + equips the Default Bat
```

`BatService` must be initialised **before players join**. The gear
shop granting and equipping the `Default Bat` happens at
`GearShopService.Init()`; the bat swing itself is rejected until a
bat Tool is actually equipped, so ordering 7 and 10 is not load-bearing
for the first swing — but a player cannot swing before their gear
grant lands, so 10 should not be delayed.

`RagdollService` has **no `Init()`**. It is stateless until the first
`Ragdoll()` call, and `BatService` requires it directly at load.

---

## Data

**No persistent data.** This system reads no profile fields and
writes none.

Its runtime state is all in-memory and per-server:

| State | Where | Keyed by | Lifetime |
|---|---|---|---|
| Swing cooldown | `BatService._lastSwing` | `player.UserId` | Until the player leaves (never cleared on leave — see Limitations). |
| Ragdoll immunity | `BatService._nextRagdollAt` | `player.UserId` | Pruned opportunistically on each hit. |
| Ragdoll records | `RagdollService.records` | `Player` (instance) | Until recovery, `Died`, or `_TestReset`. |
| Ragdoll token | `RagdollService.seq` | global counter | Monotonic, never reset. |
| SFX cycle | `BatService._sfxCycle` | global | Cycles 1→2→3→1. |
| SFX templates | `BatService._sfxTemplates` | index 1..3 | Cached until the template's `Parent` becomes nil. |

---

## Known Limitations

- **The Combat system has zero test coverage.** All three spec files
  in `Tests/` (`CarryService.spec.lua`, `PlayerGrab.spec.lua`,
  `ResetProtection.spec.lua`) exercise the **Carry** system
  (`CarryRegistry`, `PlayerGrabService`, `ResetProtectionService`) —
  not `BatService` or `RagdollService`. They were placed here
  during extraction. There is no automated test for the swing
  pipeline, the hitbox, the knockback, the ragdoll, or the SFX cycle.
- **`_lastSwing` is never cleared on player leave.** The cooldown
  table grows one entry per player who ever swung, for the life of
  the server. Same for `_nextRagdollAt` (only pruned when a *new* hit
  lands, and only for users other than the current target).
- **The hitbox is 1.75× the configured size, but the config says
  otherwise.** `BatService.lua:213` multiplies `entry.Hitbox.Size` by
  `1.75` at query time. The config's `Hitbox.Size` values are
  therefore *not* the real hitbox. The offset is not scaled.
- **Knockback is not scaled** by the same factor — the 1.75× applies
  only to the query box.
- **No animation gating.** A swing is resolved on the tick the
  remote fires. The client plays a cosmetic swing animation that
  plays **on swing and on miss alike**; the server never waits for it.
- **`Ragdoll` blocks on a landing wait.** If the target is
  `Jumping` or `Freefalling`, `applyRagdoll` waits on
  `Humanoid.StateChanged` for `Landed`/`Running` before doing
  anything — with a `task.wait(0.05)` poll loop. The swing path is
  therefore **not** fully synchronous in that case, and a target who
  never lands blocks the swing. The header says this is the
  reference implementation's own jump-bug workaround and says
  explicitly not to "fix" it.
- **Ragdoll supports R15 only.** `Ragdoll()` returns `false` and
  warns on any other rig type. On non-Upgraded rigs, joints are
  **not** released (only `AnimationConstraint`s are disabled), so the
  body does not actually go limp.
- **Ragdoll does not restore the pre-ragdoll collision state.** It
  hardcodes: limbs collidable, HRP and `CollisionPart` not collidable.
  A character with a custom collision setup is not restored.
- **`Ragdoll` has a no-refresh policy.** An already-ragdolled player
  is left alone and `Ragdoll()` returns `false`. Repeated hits
  therefore cannot extend the recovery timer; the anti-spam window
  lives in `BatService`'s `_nextRagdollAt` instead.
- **`RagdollService.Unragdoll` returns `true` even when the character
  is gone** (it drops the stale record and returns `true` at
  `RagdollService.lua:190`).
- **`RagdollService._TestReset()` does not un-ragdoll.** It clears the
  records table; the rig stays collapsed and the pending
  `task.delay` recovery will still fire (and find no record).
- **Hit SFX resolution is warn-once and never retried loudly.** If
  `ServerStorage.Assets.Sfx.HitSfx.Attack1..3` is missing, a single
  warning is emitted and every hit plays silently.
- **The SFX hitbox is "front" = negative Z of the attacker's CFrame.**
  The `Hitbox.Offset` CFrames are `CFrame.new(0, 0, -2.8)` etc.,
  multiplied by the attacker's CFrame. Roblox's model `LookVector` is
  **-Z**, so `-3` is forward. This works, but it means the offset
  sign convention is inverted relative to most people reading it.
- **`Combat.Validate()` does not check `Hitbox` at all** — a malformed
  `Hitbox.Size` or `Hitbox.Offset` passes validation and then throws
  at query time (the `GetPartBoundsInBox` call is `pcall`-wrapped, so
  the swing silently does nothing instead).
- **`Gear.ValidateList` and `Gear.ValidateLive` live in the gear
  shop's domain**, not combat's. They are copied into this system
  because the config module is shared.

---

## Testing

`Tests/CarryService.spec.lua`, `Tests/PlayerGrab.spec.lua`,
`Tests/ResetProtection.spec.lua` — **all three test the Carry system,
not Combat.** They stub the remotes via `_Helpers` and require
Roblox Studio. See `../../Tests/README.md`.

There is **no spec for `BatService` or `RagdollService`.** If you
reuse this system you should write one; the seams that make it
testable are `BatService._TestReset()`, `RagdollService._TestReset()`,
and the `_TestEntryCount`-style accessors used elsewhere in the
codebase.

---

## Adapting to a New Game

1. **Copy three files**: `BatService.lua` and `RagdollService.lua` to
   `ServerScriptService/Combat/`, and `Gear.lua` to
   `ReplicatedStorage/Config/Economy/`.
2. **Install the `t` package** — `Validation` re-exports it
   (`Shared/Utilities/Validation.lua:13` requires
   `ReplicatedStorage.Packages.t`).
3. **Author the Studio assets**:
   - `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>` — one `Tool`
     per catalog entry whose `Name` exactly matches `ToolName`.
     `Gear.ValidateLive()` fails loudly for a missing or
     wrong-class Tool.
   - `ServerStorage.Assets.Sfx.HitSfx.Attack1`, `Attack2`, `Attack3`
     (or the flat `Assets.Sfx.AttackN` mirror the boot code also
     accepts) — `Sound` instances, or folders containing one.
4. **Add the `BatSwing` remote** to your remotes registry. The name
   and the empty-payload contract are load-bearing.
5. **Wire the client side yourself.** The client counterpart
   (`StarterPlayerScripts/BatController.lua` in the source game) is
   **not** part of this system. It must: find a `Tool` whose `Name`
   resolves via `Gear.Combat.GetByToolName`, play a local swing
   animation, and `FireServer()` with **no arguments**. The server
   re-validates everything, so the client can lie harmlessly.
6. **Replace the carried-object recovery calls.** `BatService` calls
   `AnimalService.RecoverCarriedAnimal` and
   `EggService.RecoverCarriedEgg` by name. If your game has different
   service names, rename the requires and the two calls.
7. **Decide your damage model.** This system deliberately does no
   damage. Adding it is a change to `onSwing`, and it interacts with
   the ragdoll's `Humanoid.Health <= 0` guards.
8. **Re-tune the 1.75× hitbox multiplier** (or fold it into the
   config's `Hitbox.Size` and delete the multiplier) — the current
   split between config and code is confusing.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
