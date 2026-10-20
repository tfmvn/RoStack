# Combat — API

Every public function of every module in the Combat system. Signatures
are copied from the source; line numbers refer to
`Systems/Combat/Source/`.

Nothing in this system **throws** for a bad argument — every
rejection path returns `false` / `nil` and (in the debug-gated case)
logs a warning.

---

## `ServerScriptService.Combat.BatService`

`Source/ServerScriptService/Combat/BatService.lua`

---

### `BatService.Init()`

```lua
function BatService.Init()
```

**Description.** Connects the `BatSwing` remote to the server swing
handler. Idempotent — a second call returns immediately.

**Parameters.** None.

**Returns.** `nil`.

**Failure modes.**
- The whole body is wrapped in `pcall`. If `Remotes.GetFolder()`
  throws, the error is swallowed and `Init` returns normally with
  **nothing wired** (silent failure).
- If the `BatSwing` RemoteEvent does not appear within **10 s**, or
  is not a `RemoteEvent`, it logs
  `Debug.Warn('Bat', 'BatSwing remote missing; bat hits disabled')`
  and returns. **Bat hits are disabled, not crashed.**
- `_wired` is set to `true` *before* the pcall, so a failed `Init`
  cannot be retried.

**Side effects.** Connects `RemoteEvent.OnServerEvent` to `onSwing`.

---

### `BatService._TestReset()`

```lua
function BatService._TestReset()
```

**Description.** Clears the per-player swing-cooldown table, clears
the ragdoll-immunity table, and resets the hit-SFX cycle counter to
`0` (so the next hit plays `Attack1`).

**Parameters.** None.

**Returns.** `nil`.

**Failure modes.** None — it cannot throw.

**Note.** It does **not** disconnect the remote, does **not**
un-ragdoll anyone, and does **not** reset the SFX template cache.

---

## `ServerScriptService.Combat.RagdollService`

`Source/ServerScriptService/Combat/RagdollService.lua`

---

### `RagdollService.IsRagdolled(player: Player): boolean`

```lua
function RagdollService.IsRagdolled(player: Player): boolean
```

**Description.** Whether `player` currently has an active ragdoll
record.

**Parameters.**
- `player` — the Player instance to test.

**Returns.** `true` if a ragdoll record exists for that Player
instance, `false` otherwise. The record is keyed by **Player
instance**, not by UserId.

**Failure modes.** Returns `false` for a non-Player argument (the
table lookup simply misses). Never throws.

---

### `RagdollService.Ragdoll(player: Player, duration: number): boolean`

```lua
function RagdollService.Ragdoll(player: Player, duration: number): boolean
```

**Description.** Ragdolls `player` for `duration` seconds and
schedules the timed recovery. The ragdoll itself is applied
synchronously (joints released, limbs made collidable, physics state
entered); the *recovery* is scheduled with `task.delay`.

**Parameters.**
- `player` — the Player to ragdoll.
- `duration` — seconds to stay ragdolled. Must be a number `> 0`.

**Returns.** `true` if the ragdoll was applied and the recovery
scheduled; `false` on every rejection.

**Failure modes.** All return `false`, never throw:
- `player` is not an `Instance` of class `Player` → `false`.
- `duration` is not a number, is `NaN`, or is `<= 0` → `false`
  (`duration = tonumber(duration) or 0` then `duration ~= duration
  or duration <= 0`).
- `player.Character` is `nil` → `false`.
- The character has no `Humanoid` or no `HumanoidRootPart` → `false`
  **plus** `Debug.Warn('Bat', 'Ragdoll: character incomplete')`.
- `Humanoid.Health <= 0` → `false`, silent.
- `Humanoid.RigType ~= Enum.HumanoidRigType.R15` → `false` **plus**
  `Debug.Warn('Bat', 'Ragdoll supports R15 rigs only')`.
- The player is **already ragdolled** → `false`, silent. This is the
  no-refresh policy: a repeated hit can never extend the recovery
  timer.

**Important side effect.** If the target is `Jumping` or
`Freefalling`, `applyRagdoll` **blocks** in a `task.wait(0.05)` poll
loop until the humanoid reaches `Landed` or `Running`. The call
therefore does not return promptly for an airborne target.

**Other side effects.** Writes a `{token, character}` record; hooks
`Humanoid.Died:Once` to clear it (token-guarded); schedules
`task.delay(duration, Unragdoll(player, token))`.

---

### `RagdollService.Unragdoll(player: Player, token: number?): boolean`

```lua
function RagdollService.Unragdoll(player: Player, token: number?): boolean
```

**Description.** Ends the ragdoll and restores the character: joints
re-enabled, collision restored, velocities zeroed, network ownership
handed back to the player.

**Parameters.**
- `player` — the Player to recover.
- `token` — optional. When supplied, the record's token must match
  or the call is rejected. Used by the scheduled recovery so a stale
  timer cannot kill a newer ragdoll.

**Returns.**
- `true` if a record existed and was ended (including the case where
  the character was destroyed and nothing was physically restored).
- `false` if there was no record, or the token did not match.

**Failure modes.**
- No record → `false`, nothing happens.
- Token mismatch → `false`, the record is **left intact**.
- The character/humanoid/HRP is gone → the record is dropped and
  `true` is returned, but **the rig is not restored** (there is
  nothing to restore). The caller cannot distinguish this from a
  successful recovery by return value alone.

**Note.** A manual `Unragdoll(player)` with **no** token always ends
the current ragdoll, whatever its token. That is the intended
"admin force-recover" path.

---

### `RagdollService._TestReset()`

```lua
function RagdollService._TestReset()
```

**Description.** Clears every ragdoll record.

**Parameters.** None.

**Returns.** `nil`.

**Failure modes.** None.

**Important.** This does **not** restore the rig. A player who was
ragdolled stays collapsed, and the pending `task.delay` recovery will
still fire — it will find no record and return `false`.

---

## `ReplicatedStorage.Config.Economy.Gear`

`Source/ReplicatedStorage/Config/Economy/Gear.lua`

The gear **catalog**. Pure data + lookups. No requires, no
instances, no side effects. The table is `table.freeze`d on return.

**Types.**

```lua
export type GearEntry = {
    Id: string,
    Name: string,
    Price: string,          -- BigNumber decimal STRING, never a number
    Description: string,
    RequiredRebirth: number,
    ToolName: string,       -- EXACT Tool Instance name
    RobuxOnly: boolean?,
}
```

---

### `Gear.GetAll(): { GearEntry }`

```lua
function Gear.GetAll(): { GearEntry }
```

**Description.** The full gear catalog, **in shop display order**
(array order is the display order).

**Parameters.** None.

**Returns.** The live `ENTRIES` array (the same table every call —
it is frozen, so it cannot be mutated, but it is also not a copy).

**Failure modes.** None.

---

### `Gear.FindGear(id: string): GearEntry?`

```lua
function Gear.FindGear(id: string): GearEntry?
```

**Description.** Finds a catalog entry by its stable `Id`.

**Parameters.**
- `id` — the gear id, e.g. `'SilverBat'`.

**Returns.** The matching `GearEntry`, or `nil` if there is no match.

**Failure modes.** Returns `nil` if `id` is not a string, or if no
entry has that `Id`. Never throws.

---

### `Gear.IsLocked(playerRebirth: number, required: number): boolean`

```lua
function Gear.IsLocked(playerRebirth: number, required: number): boolean
```

**Description.** Whether the gear is still locked for a player with
`playerRebirth` completed rebirths.

**Parameters.**
- `playerRebirth` — the player's completed rebirth count.
- `required` — the entry's `RequiredRebirth`.

**Returns.** `true` when the gear is locked, `false` when it is
unlocked. **`true` means locked** — the name is easy to invert.

**Failure modes.** Returns `true` (locked) if either argument is not
a number — it fails *closed*, so a bad input hides the gear rather
than granting it. Never throws.

---

### `Gear.ValidateList(entries: any, toolProbe: ((string) -> any)?): { string }`

```lua
function Gear.ValidateList(entries: any, toolProbe: ((string) -> any)?): { string }
```

**Description.** Pure validation over an arbitrary entry list.
Returns an array of human-readable issue strings.

**Parameters.**
- `entries` — the list to validate (any table).
- `toolProbe` — optional. A function taking a `ToolName` and
  returning `true` (the Tool exists and is a `Tool`), the string
  `'wrong-class'` (something exists at that name but is not a
  `Tool`), or any falsy value (missing). When omitted, the Tool
  existence check is skipped entirely.

**Returns.** An array of issue strings. **Empty array = valid.**
Issues are reported per entry, e.g.:

- `catalog is not a table`
- `entry 3 is not a table`
- `entry 2 has invalid Id`
- `Duplicate GearId=SilverBat`
- `entry 1 has invalid Name` / `has invalid Description` /
  `has invalid Price` / `has invalid RequiredRebirth` /
  `has invalid ToolName`
- `Missing Tool GearId=SilverBat ToolName=Silver Bat path=ServerStorage.Assets.Ui.GearShop.Tools/Silver Bat`
- `Tool wrong class GearId=... path=... (expected Tool)`

**Failure modes.** Never throws. A non-table `entries` returns
`['catalog is not a table']` immediately.

---

### `Gear.ValidateLive(): { string }`

```lua
function Gear.ValidateLive(): { string }
```

**Description.** `ValidateList` run against the **live**
`ServerStorage.Assets.Ui.GearShop.Tools` hierarchy.

**Parameters.** None.

**Returns.** An array of issue strings; empty when the catalog and
the Studio assets agree.

**Failure modes.** Never throws — the tool probe is `pcall`-wrapped
and returns `false` (missing) on any internal error. Note that this
means a broken probe reports every Tool as *missing*, not as an
error.

---

## `ReplicatedStorage.Config.Economy.Gear.Combat`

The combat tuning table, attached to the `Gear` module as `Gear.Combat`
(`Gear.lua:466`) and frozen before attachment.

**Types.**

```lua
export type BatHitbox = { Size: Vector3, Offset: CFrame }
export type BatKnockback = { Horizontal: number, Vertical: number }

export type BatEntry = {
    GearId: string,
    ToolName: string,
    SwingCooldown: number,
    Hitbox: BatHitbox,
    Knockback: BatKnockback,
    RagdollDuration: number,
    RagdollImmunity: number,
}
```

---

### `Gear.Combat.GetByGearId(gearId: string): BatEntry?`

```lua
function Combat.GetByGearId(gearId: string): BatEntry?
```

**Description.** Combat tuning by the gear's catalog `Id`.

**Parameters.**
- `gearId` — e.g. `'SilverBat'`.

**Returns.** The `BatEntry`, or `nil` if that gear has no combat
tuning (e.g. `'SpeedCoil'`, `'GravityCoil'`, `'CoilCombo'`,
`'InvisibleCloak'`).

**Failure modes.** Returns `nil` for a non-string argument. Never
throws.

---

### `Gear.Combat.GetByToolName(toolName: string): BatEntry?`

```lua
function Combat.GetByToolName(toolName: string): BatEntry?
```

**Description.** Combat tuning by the **granted Tool Instance name**
(e.g. `'Silver Bat'`). This is the entry point the **server** uses
(`BatService.equippedBat`) and the entry point the **client** uses
for its cosmetic local cooldown gate.

**Parameters.**
- `toolName` — the exact `Tool.Name` of the equipped tool.

**Returns.** The `BatEntry`, or `nil` if the tool is not a bat.

**Failure modes.** Returns `nil` for a non-string argument. Never
throws.

---

### `Gear.Combat.All(): { BatEntry }`

```lua
function Combat.All(): { BatEntry }
```

**Description.** All combat entries, in a **fresh array** (unlike
`Gear.GetAll()`, which returns the live frozen table).

**Parameters.** None.

**Returns.** A new array of `BatEntry` values, in declaration order.

**Failure modes.** None.

---

### `Gear.Combat.Validate(): { string }`

```lua
function Combat.Validate(): { string }
```

**Description.** Validates the combat tuning table.

**Parameters.** None.

**Returns.** An array of issue strings; empty when valid. Each issue
is prefixed `Combat.<GearId>`.

Checked:
- `SwingCooldown` must be a number `> 0`.
- `Knockback.Horizontal` must be a number `>= 0`.
- `Knockback.Vertical` must be a number `>= 0`.
- `RagdollDuration` must be a number `> 0`.
- `RagdollImmunity` must be a number `>= 0`.

**Failure modes.** Never throws.

**Not checked** (a real gap):
- `Hitbox.Size` and `Hitbox.Offset` are **not** validated at all. A
  malformed hitbox passes validation and then fails at query time —
  the `GetPartBoundsInBox` call is `pcall`-wrapped, so the swing
  silently misses.
- It is **not** checked that every `GearId` exists in the shop
  catalog, nor that every bat in the catalog has a combat entry.

---

## Data tables (not functions)

### `Gear.Viewport`

```lua
Gear.Viewport = {
    DistanceFactor = 1.4,
    MinDistance = 2,
    Direction = Vector3.new(1, 0.6, 1.6),
}
```

Shop-preview viewport framing, read by `GearShopController` in the
Shops system. Presentation only. Not read by Combat.

### `Gear.Combat` entries

See the table in [`README.md`](README.md) → *Configuration* for the
full per-bat numbers.

---

## Internal functions (not exported)

These are module-locals and are **not** part of the public API, but
they are the things you would need to change to extend the system:

| Function | Module | Line | What it does |
|---|---|---|---|
| `onSwing(player)` | BatService | 170 | The whole swing pipeline. |
| `equippedBat(character)` | BatService | 155 | Resolves the equipped Tool → combat entry. |
| `interruptCarry(target)` | BatService | 128 | Cancels a steal, or recovers the target's own carried animal/egg. |
| `playHitSfx(targetHrp)` | BatService | 102 | Clones, groups, mounts, plays, and Debris-cleans the hit sound. |
| `resolveSfx(index)` | BatService | 65 | Finds and caches `Assets.Sfx.HitSfx.Attack<N>`. |
| `applyRagdoll(character, humanoid, hrp)` | RagdollService | 56 | The verbatim ragdoll core. |
| `applyGetUp(player, character, humanoid, hrp)` | RagdollService | 95 | The verbatim get-up core. |

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
