# Combat — engineering notes

Server-authoritative Bat PvP: the client says "I swung", the server
decides everything. No damage, ever.

---

## Purpose

One line: turn a single empty client event into a validated hit
(pipeline) plus a timed R15 ragdoll (authority), with zero client
trust and no damage.

---

## How it actually works

### `BatService` — the swing pipeline

`BatService.Init()` (line 304) connects `Remotes.Names.BatSwing`
`OnServerEvent` to `onSwing(player)`. The remote fires with **no
arguments**; the only client input is *who fired*.

`onSwing` (line 170) is a straight-line sequence of early returns.
Order matters — each check is a gate:

1. `Validation.LivePlayer(player)` — false → return.
2. `player.Character` exists → else return.
3. `character:FindFirstChildOfClass('Humanoid')` exists **and**
   `Health > 0` → else return.
4. `character:FindFirstChild('HumanoidRootPart')` exists and
   `IsA('BasePart')` → else return.
5. `equippedBat(character)` (line 155) — takes
   `character:FindFirstChildOfClass('Tool')` (the **first** Tool
   child, which is the equipped one), then
   `BatConfig.GetByToolName(tool.Name)`. If the Tool name is not in
   the combat table → return. **The server never trusts a
   client-sent bat id** — the identity is derived from the equipped
   Tool's own Name.
6. `RagdollService.IsRagdolled(player)` → return. You cannot swing
   while ragdolled.
7. `CarryRegistry.IsCarrying(player.UserId)` → return. This is the
   **global tool lock**: a carrying/stealing player cannot swing.
8. Cooldown: `os.clock() - _lastSwing[uid] < entry.SwingCooldown` →
   return. Otherwise `_lastSwing[uid] = os.clock()`.

Then the **hit window** is a single immediate spatial query:

```lua
local size  = entry.Hitbox.Size * 1.75          -- 1.75x, offset NOT scaled
local box   = attackerHrp.CFrame * entry.Hitbox.Offset
local parts = Workspace:GetPartBoundsInBox(box, size, params)
```

`params` is `OverlapParams` with `FilterType = Exclude` and the
attacker's own `character` added to the filter. The call is
`pcall`-wrapped — a failure yields an empty part list, i.e. a
silent miss, never a throw.

**Target resolution and dedupe** (line 226): for each returned part,
walk up the ancestor chain calling `Players:GetPlayerFromCharacter`
until a Player is found. This is why *any* body part of a player
counts, and why a player with 12 body parts is one target. Dedupe by
Player via a `seen` set. Skip `target == player`. Skip targets whose
Humanoid is missing or `Health <= 0`.

**Per target** (line 245), in this exact order:

1. **Carry interruption** — `interruptCarry(target)` (line 128):
   - `StealService.RollbackIfStealing(uid, 'HitByBat')` → if true, a
     steal was in progress and was rolled back. Done.
   - else `CarryRegistry.Get(uid)`; if the item is a plain carry
     (not steal-flagged): `kind == SlotType.OccupantKind.Animal` →
     `AnimalService.RecoverCarriedAnimal(uid, 'HitByBat')`;
     `kind == Egg` → `EggService.RecoverCarriedEgg(target,
     'HitByBat')`. Both are `pcall`-wrapped. The function returns
     `true` in all three cases *regardless of whether the recovery
     actually succeeded*.
2. **Ragdoll**, immunity-gated. `_nextRagdollAt[target.UserId]` is
   the timestamp until which the target is immune. If
   `os.clock() >= immuneUntil`:
   - opportunistic prune: every *other* entry whose timestamp has
     passed is deleted from `_nextRagdollAt`;
   - `RagdollService.Ragdoll(target, entry.RagdollDuration)`; if it
     returns `true`, set
     `_nextRagdollAt[uid] = now + RagdollDuration + RagdollImmunity`.
   - If the target is immune, the ragdoll is skipped **but the
     knockback still applies**.
3. **Knockback** — a flat (XZ-only) vector from attacker to target:
   `flat = Vector3.new(tPos.X - aPos.X, 0, tPos.Z - aPos.Z)`. If the
   flat magnitude is `< 1e-3` (attacker and target share XZ), fall
   back to the attacker's `CFrame.LookVector` flattened; if *that* is
   also degenerate, fall back to `Vector3.new(0, 0, -1)`. Then
   `hrp.AssemblyLinearVelocity = flat.Unit * kb.Horizontal +
   Vector3.new(0, kb.Vertical, 0)`. **Knockback values are not
   scaled by the 1.75× hitbox multiplier.**
4. **Hit SFX** — `playHitSfx(hrp)` (line 102). A module-global
   counter `_sfxCycle` cycles 1→2→3→1. The template is resolved
   once and cached in `_sfxTemplates[1..3]`. The template is cloned,
   stamped with `AudioGroups.AssignSfx`, **parented to the target's
   HRP**, played, and `Debris:AddItem(clone, 6)`.

There is **no hit VFX by design** and **no hit-result remote by
design** — the confirmed-hit sound is server-mounted on the target, so
everyone hears it and the client needs no round trip.

### `RagdollService` — the authority

`RagdollService.Ragdoll(player, duration)` (line 124):

- Rejects (returns `false`, never throws): not a Player instance;
  `duration` not a number / NaN / `<= 0`; no `Character`; no
  Humanoid; no HRP; `Humanoid.Health <= 0`; `Humanoid.RigType ~=
  R15` (warns); **already ragdolled** (no-refresh policy).
- `applyRagdoll(character, humanoid, hrp)` (line 56) — the reference
  ragdoll core, verbatim:
  1. If the humanoid state is `Jumping` or `Freefalling`, connect to
     `Humanoid.StateChanged` and **block** in a `task.wait(0.05)`
     poll loop until the signal fires on `Landed` or `Running`.
     (This is the reference's own jump-bug workaround. The header
     says do not "fix" it.)
  2. `hrp:SetNetworkOwner(nil)` → `task.wait()` →
     `humanoid:ChangeState(Physics)`, `AutoRotate = false`,
     `PlatformStand = true`,
     `SetStateEnabled(GettingUp, false)`.
  3. Disable every `AnimationConstraint` except one named `Root`.
     (On non-Upgraded rigs with `Motor6D` joints, the joints are
     **not** released — the body does not actually go limp.)
  4. `task.wait(0.1)`; then for every direct `BasePart` child:
     limbs get `CanCollide = true, Massless = false`;
     `HumanoidRootPart` and `CollisionPart` get `CanCollide = false`.
  5. `PlatformStand = true` again.
- A record `{token = seq, character = character}` is stored in
  `records[player]`. `seq` is a module-global monotonic counter.
- `humanoid.Died:Once` clears the record **only if the token still
  matches** (so a stale death callback cannot clear a newer ragdoll).
- `task.delay(duration, function() RagdollService.Unragdoll(player,
  token) end)` schedules the timed recovery.
- Returns `true`.

`RagdollService.Unragdoll(player, token?)` (line 176):

- No record → return `false`.
- `token` given and mismatched → return `false` (a stale scheduled
  recovery cannot kill a newer ragdoll).
- Record dropped. If the character/humanoid/HRP are gone → return
  `true` **without** restoring anything (stale record cleanup).
- Otherwise `applyGetUp(player, character, humanoid, hrp)` (line 95):
  `PlatformStand = false`; `hrp.Orientation = Vector3.zero`;
  re-enable `GettingUp`; `ChangeState(GettingUp)`; every direct
  `BasePart` child gets `CanCollide = false` except `CollisionPart`
  which gets `CanCollide = true`; zero all linear and angular
  velocities; `AutoRotate = true`; re-enable every non-`Root`
  `AnimationConstraint`; `task.wait()`; `hrp:SetNetworkOwner(player)`.
- Returns `true`.

`RagdollService.IsRagdolled(player)` (line 49) — `records[player] ~=
nil`.

---

## Public API surface (exact)

### `ServerScriptService.Combat.BatService`

```lua
function BatService.Init()          -- void; idempotent
function BatService._TestReset()    -- void; clears _lastSwing, _nextRagdollAt, resets _sfxCycle
```

No other exported functions. Everything else is a local.

### `ServerScriptService.Combat.RagdollService`

```lua
function RagdollService.IsRagdolled(player: Player): boolean
function RagdollService.Ragdoll(player: Player, duration: number): boolean
function RagdollService.Unragdoll(player: Player, token: number?): boolean
function RagdollService._TestReset()    -- void
```

### `ReplicatedStorage.Config.Economy.Gear`

```lua
Gear.GetAll(): { GearEntry }
Gear.FindGear(id: string): GearEntry?
Gear.IsLocked(playerRebirth: number, required: number): boolean
Gear.ValidateList(entries: any, toolProbe: ((string) -> any)?): { string }
Gear.ValidateLive(): { string }
Gear.Combat.GetByGearId(gearId: string): BatEntry?
Gear.Combat.GetByToolName(toolName: string): BatEntry?
Gear.Combat.All(): { BatEntry }
Gear.Combat.Validate(): { string }
```

`Gear.Viewport` is a plain data table (not a function).
`Gear` is `table.freeze`d at the end; `Gear.Combat` is frozen before
it is attached.

---

## Invariants the code enforces

- **The server never trusts the client about which bat.** Identity
  comes from `equippedBat()` → the equipped Tool's own `Name` →
  `Combat.GetByToolName`. The client sends nothing but its identity.
- **Only the equipped Tool counts.** `character:FindFirstChildOfClass('Tool')`
  returns the first Tool child — the equipped one. A bat in the
  Backpack is not in the Character.
- **One hit window per swing.** Exactly one
  `GetPartBoundsInBox` call, at swing time. There is no swept
  volume, no persistence of the box, no per-frame query.
- **The attacker is excluded from their own hitbox** via
  `OverlapParams` (`FilterType = Exclude`, attacker character added).
- **A player is hit at most once per swing**, regardless of how many
  body parts the query returned.
- **Dead targets are not hit** (`Humanoid.Health > 0` required).
- **A ragdolled attacker cannot swing.**
- **A carrying/stealing attacker cannot swing** (server-side tool
  lock, checked per swing — not just at carry start).
- **Cooldown is per attacker, per bat** — it uses the *current* bat's
  `SwingCooldown`. Switching bats does not reset the timer, but it
  does change the threshold: `_lastSwing` is a single timestamp per
  player, so swapping from a 1.0s bat to a 0.5s bat does not let you
  swing early.
- **Ragdoll never refreshes.** A second `Ragdoll()` on an already
  ragdolled player is a no-op returning `false`; the recovery timer
  is never extended by repeated hits.
- **Knockback applies even when the ragdoll is skipped** (immunity
  window) or when `Ragdoll()` itself fails.
- **Ragdoll requires R15.**
- **Ragdoll recovery is token-guarded**: a stale `task.delay`
  callback cannot clear a newer ragdoll record.
- **The SFX cycle is exactly 1→2→3→1**, shared across all players
  (it is a module-global, not per attacker).
- **Hit SFX is mounted on the target, not the attacker**, and is
  `Debris`-cleaned after 6 seconds.

---

## Failure and edge-case behaviour

| Situation | Behaviour |
|---|---|
| `BatSwing` remote missing at `Init()` | One `Debug.Warn('Bat', 'BatSwing remote missing; bat hits disabled')`. No throw. The service is otherwise inert. |
| Remote fires for a player with no Character | Silent return. |
| No Tool equipped, or the Tool name is not in the combat table | Silent return. |
| Attacker is ragdolled | Silent return. |
| Attacker is carrying/stealing | Silent return + `Debug.Log`. |
| Swing inside the cooldown | Silent return + `Debug.Log`. |
| `GetPartBoundsInBox` throws | `pcall`-wrapped → empty list → silent miss. |
| Hit SFX template missing | One warn-once (`_sfxWarned`), then every hit plays silently. `playHitSfx` returns `nil`. |
| Hit SFX template's `Parent` becomes nil | The cached template is re-resolved on the next call (`resolveSfx` re-checks `cached.Parent ~= nil`). |
| `Ragdoll` on a non-R15 rig | `false` + `Debug.Warn('Bat', 'Ragdoll supports R15 rigs only')`. |
| `Ragdoll` on a dead player | `false`, silent. |
| `Ragdoll` with `duration <= 0` / NaN / non-number | `false`, silent. |
| `Ragdoll` on a player with no Humanoid/HRP | `false` + `Debug.Warn('Bat', 'Ragdoll: character incomplete')`. |
| `Ragdoll` on an already-ragdolled player | `false`, silent (no-refresh policy). |
| `Unragdoll` on a player with no record | `false`. |
| `Unragdoll` with a mismatched token | `false`, record left intact. |
| `Unragdoll` when the character was destroyed | `true`, record dropped, **no rig restore**. |
| Target is mid-air when hit | `applyRagdoll` **blocks** on `Landed`/`Running` — the swing path stalls. |
| `CarryRegistry.Get` throws | `pcall`-wrapped → `item` stays `nil` → `interruptCarry` returns `false`. |
| `AnimalService.RecoverCarriedAnimal` throws | `pcall`-wrapped → `interruptCarry` still returns `true` (it reports "something was interrupted" optimistically). |
| `StealService.RollbackIfStealing` returns false and the target holds a steal-flagged item | `interruptCarry` returns `false` (the `item.steal ~= nil` branch short-circuits). |

---

## Gotchas that would bite you

1. **`Tests/` in this system tests the Carry system.** All three
   specs (`CarryService`, `PlayerGrab`, `ResetProtection`) require
   `ServerScriptService.Carry.*`. There is **no** automated test for
   `BatService` or `RagdollService`.
2. **The hitbox in the config is not the hitbox in the world.**
   `BatService.lua:213` multiplies `Hitbox.Size` by `1.75`. The
   config's `Hitbox.Size` is a base number, and the `Hitbox.Offset`
   is *not* scaled. If you retune `Hitbox.Size` expecting the
   in-world box to shrink, it will not.
3. **`Hitbox.Offset` is negative-Z forward.** `CFrame.new(0, 0, -3)`
   multiplied by the attacker's CFrame points forward because
   Roblox's `LookVector` is `-Z`. The sign reads backwards to a
   casual reader.
4. **`Ragdoll` is not synchronous in the air.** The `Jumping`/
   `Freefalling` landing wait uses a `task.wait(0.05)` poll loop
   inside `applyRagdoll`, so a bat swing can stall the server thread
   for an unbounded time if the target never lands.
5. **`RagdollService._TestReset()` does not un-ragdoll anyone.** It
   clears `records` only. The rig stays collapsed, and the pending
   `task.delay` recovery will fire, find no record, and return
   `false`.
6. **`Unragdoll` returns `true` for a destroyed character.** `true`
   means "a record was ended", not "the rig was restored".
7. **The collision restore is hardcoded.** The ragdoll makes limbs
   collidable and HRP/`CollisionPart` non-collidable; the get-up
   makes everything non-collidable except `CollisionPart`. A
   character with a bespoke collision setup is not restored to it.
8. **On non-Upgraded rigs the body does not go limp.** Only
   `AnimationConstraint`s are disabled; `Motor6D` joints are left
   intact. The `Ragdoll()` call still returns `true`.
9. **`_lastSwing` and `_nextRagdollAt` are never cleaned on player
   leave.** They leak one entry per player who ever swung, for the
   life of the server. `_nextRagdollAt` is only pruned when a *new*
   hit lands and only for *other* users.
10. **`_sfxCycle` is a module-global shared by all players.** Two
    players swinging at once will interleave the 1→2→3 cycle; there
    is no per-attacker SFX selection.
11. **`Gear.Combat` has entries for only 8 of the 13 catalog gears.**
    `SpeedCoil`, `GravityCoil`, `CoilCombo`, `InvisibleCloak` have
    **no** combat entry. Equipping one of those gives a player a Tool
    the server does not recognise as a bat → **no swing at all**.
    (`CoilCombo` and `InvisibleCloak` are not bats, so this is
    probably intentional, but it means "has a Tool" ≠ "has a bat".)
12. **`Gear.ValidateLive()` is the only thing that checks the Studio
    Tool assets exist.** `Gear.Combat.Validate()` does **not** check
    `Hitbox` at all, and does not check that every combat `GearId`
    exists in the shop catalog (or vice versa). A `Combat` entry for
    a gear nobody can obtain is silently dead.
13. **Every `Description` in the gear catalog is a `PLACEHOLDER:`
    string.** The source header says the prices and descriptions are
    "initial values, not final balance".
14. **`GalaxyBat` is `RobuxOnly = true` with `Price = '0'`.** It is
    granted by a Marketplace receipt, never by the shop. Its grant
    "fails loudly and receipts retry" if the Studio Tool asset is
    missing.
15. **`Debug` gating.** Both `Debug.Log` and `Debug.Warn` calls
    obey `ReplicatedStorage.Config.Systems.Debug.ServerDebug`, which
    defaults to `false` — so in production you see **no** combat
    logging at all, not even the warnings.
16. **`Validation.LivePlayer` throws on `nil`.** `BatService`
    guards with `if not Validation.LivePlayer(player) then return
    end`, but a `nil` player reaching the remote handler would
    already have failed at the `player.Character` access — the
    remote passes a real Player, so this is only a concern if you
    call `onSwing` directly in a test.

---

## What to change to reuse it

**Must change:**

- The **require paths** for `StealService`, `CarryRegistry`,
  `AnimalService`, `EggService` (lines 46–49 of `BatService.lua`) if
  your service names differ.
- The **recovered-object calls** in `interruptCarry` — same two
  functions, different names.
- The **client counterpart**. The client `BatController` is NOT in
  this system. It must find the equipped Tool, play a local
  animation, and `FireServer()` with no arguments.
- The **remote name** must be `BatSwing` in your remotes registry
  (or change `Remotes.Names.BatSwing`).
- **Studio assets**: `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>`
  (one `Tool` per catalog entry, `Name` exactly matching `ToolName`)
  and `ServerStorage.Assets.Sfx.HitSfx.Attack1..3`.

**Should change:**

- The **hitbox multiplier** — fold `1.75` into the config's
  `Hitbox.Size` and delete the multiplier, or make the multiplier a
  config field.
- The **`p7:` slot id prefix** if your game uses a different prefix
  (only matters transitively, via `CarryRegistry` / `SlotType`).
- The **damage model** — this system does no damage. If you want
  damage, it belongs in `onSwing` and must respect the ragdoll's
  `Health <= 0` guards.
- The **R15-only restriction** — if you support R6, the ragdoll needs
  a different joint-release path.

**Safe to keep as-is:**

- The whole swing pipeline shape (validate → query → dedupe →
  interrupt → ragdoll → knockback → sfx).
- The ragdoll core and its timing/token discipline.
- The `pcall`-everything tolerance policy.
- The `Debug.Log`/`Debug.Warn` tagging (`'Bat'`).
- The `Gear.Combat` lookup-by-tool-name convention.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
