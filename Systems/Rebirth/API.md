# Rebirth — API

Every public function of every module in the Rebirth system. Signatures
are verbatim from the source. **Nothing here throws** unless stated:
failures are returned as data.

---

## `ServerScriptService.Rebirth.RebirthService`

The single authority for the Rebirth transaction.

### Result shapes

```lua
-- Success
{ success = true, rebirth = number }
-- Failure
{ success = false, error = string }
```

Error codes: `'invalid-player'`, `'busy'`, `'maxed'`, `'carrying'`,
`'raid-locked'`, `'no-profile'`, `'money'`, `'arena'`, `'animals'`,
`'reset-failed'`.

---

### `RebirthService.Init()`

Wires the `RebirthAction` remote. **Idempotent** (a module-local
`_wired` flag).

Waits up to 10 seconds for the `RebirthAction` RemoteEvent. If it does
not appear, it logs `'RebirthAction remote missing; rebirths disabled'`
and the system is inert.

**Returns:** nothing. **Throws:** never (the whole body is
`pcall`-guarded).

---

### `RebirthService.GetRebirth(userId: number): number`

The player's completed rebirth count.

**Returns:** `data.Rebirth` when it is a number, an integer, and
`>= 0`. **Fails closed to `0`** for a missing profile, a non-number, a
fractional value, or a negative.

**Throws:** never.

---

### `RebirthService.RequestRebirth(player: Player): { [string]: any }`

The transaction. Validates every requirement against authoritative
state, then commits the reset in a fixed order.

**Parameters:** `player` — the requester.

**Returns:**
- Success: `{ success = true, rebirth = nextIndex }`.
- Failure: `{ success = false, error = <code> }`.

**Failure codes:**

| Code | Cause |
|---|---|
| `invalid-player` | `Validation.LivePlayer(player)` failed. |
| `busy` | A rebirth is already in flight for this player. |
| `maxed` | `RebirthConfig.Get(current + 1)` is nil — the ladder ends here. |
| `carrying` | `CarryRegistry.IsCarrying(userId)` is true. |
| `raid-locked` | Any owned animal is raid-locked (`ArenaService.IsAnimalRaidLocked`). |
| `no-profile` | `PlayerService.GetPlayerData(userId)` did not return a table. |
| `money` | The wallet is below `Requirements.Money`. |
| `arena` | The arena level is below `Requirements.ArenaLevel`. |
| `animals` | An animal requirement was not matched. |
| `reset-failed` | The base rebuild failed. **Nothing else was touched.** |

**On success** the service also: rolls back any live steal/carry
involving the player, rebuilds the base (same base id, new stand
counts, re-pointed `RespawnLocation`), destroys and removes the
animals, resets the arena, sets `data.Money` to the StartingCash,
increments `data.Rebirth`, applies the `MoneyMultiplier` through
`ModifierService`, refreshes the base multiplier label, re-homes the
egg slot ids, pushes `PlayerState` + `RebirthState` +
`RebirthResult { Success = true, Rebirth = n }`, runs the post-rebirth
validation (diagnostics only), and marks the leaderboards dirty.

**Throws:** never. Every dependency call inside is `pcall`-guarded; a
failure in a non-critical step logs and is ignored.

**Concurrency:** the per-player mutex is set before any work and
cleared on every exit path, including the failure paths.

---

### `RebirthService.BuildState(userId: number): { [string]: any }`

The GUI snapshot. Read-only and side-effect-free apart from parking
the preview clones.

**Parameters:** `userId`.

**Returns:**

```lua
{
    Current = number,          -- completed rebirth count
    Next = number?,            -- nil when maxed
    Maxed = boolean,
    CanRebirth = boolean,      -- money AND arena AND animals
    Money = string,            -- the wallet (BigNumber string)
    MoneyRequired = string,
    MoneySatisfied = boolean,
    ArenaLevel = number,
    ArenaRequired = number,
    ArenaSatisfied = boolean,
    Animals = {
        {
            DefId = string,
            DisplayName = string,   -- the catalogue display name, or the DefId
            Trait = string,         -- 'Normal' when untraited
            MinimumLevel = number,
            Matched = boolean,
            BestLevel = number?,    -- nil when nothing matched
            TemplateModel = Model?, -- a parked clone, or nil
            Rarity = string?,       -- added by attachTemplateModels
        },
    },
    Unlocks = {
        { Kind = 'AnimalStand'|'ArenaStand'|'Gear', Amount = number,
          GearId = string?, Name = string?, TemplateModel = Instance? },
    },
    StartingCash = string,
    MoneyMultiplier = number,
}
```

When the player is maxed, the early return gives only
`Current`, `Next = nil`, `Maxed = true`, `CanRebirth = false` — the
other fields are **absent** (not present-and-nil).

**Throws:** never. Every read is `pcall`-guarded; a missing profile
yields `Money = '0'`, `ArenaLevel = 1`, and no animals.

---

### `RebirthService.ApplySessionModifiers(userId: number)`

Re-applies the persisted money multiplier to `ModifierService` and
refreshes the base label.

**Parameters:** `userId`.

**Behaviour:**
- Reads the count. At `0` it does nothing (no multiplier).
- Uses `RebirthConfig.Get(current)`; if nil (the count is above the
  configured max), falls back to `RebirthConfig.Get(MaxConfigured())`.
- Adds the multiplier under the source id `'Rebirth'`. The add
  **replaces** the previous source, so it is idempotent and can never
  stack.
- Then calls `RefreshBaseMultiplier(userId)`.

**Returns:** nothing. **Throws:** never (the `AddModifier` is
`pcall`-guarded — a failure leaves the player at `1x` and still
succeeds the join).

**Call this on every join.** `ModifierService` is session-only.

---

### `RebirthService.ResolveRebirthForStands(userId: number): number`

The resolver consumed by `DynamicSlotService`.

**Returns:** the pending build override if one is set, else
`GetRebirth(userId)`. Never nil.

**Throws:** never.

---

### `RebirthService.BeginRebirthBuild(userId: number, nextIndex: number)`

Sets the pending stand-count override, so the base rebuild constructs
the **new** rebirth's stand counts even though the profile still holds
the old value.

**Returns:** nothing. **Throws:** never. Non-number arguments are
ignored.

**Must be paired with `EndRebirthBuild`.** The service calls it
immediately after the rebuild block on every exit path.

---

### `RebirthService.EndRebirthBuild(userId: number)`

Clears the pending override.

**Returns:** nothing. **Throws:** never.

---

### `RebirthService.RefreshBaseMultiplier(userId: number)`

Writes the owner's **current authoritative** multiplier (as resolved by
`ModifierService.GetMoneyMultiplier`) onto their own base's
`MoneyMultPart` label and shows it.

**Parameters:** `userId`.

**Behaviour:** the text is `Mult: 1.5x` — `formatMultiplier` renders
`1` as `"1"`, `2` as `"2"`, `2.5` as `"2.5"`, and coerces NaN /
infinite / non-positive to `1`. A base the player does not own is
left alone (ownership is resolved through `BaseService.GetBaseByOwner`,
never by proximity).

**Display only** — the string is never read back by gameplay.

**Returns:** nothing. **Throws:** never.

---

### `RebirthService.HideBaseMultiplier(userId: number)`

Hides one base's multiplier label. Owner-gated like the refresh, and
must be called while the owner still holds the base.

**Returns:** nothing. **Throws:** never.

---

### `RebirthService.HideAllBaseMultipliers()`

Hides every base's multiplier label. Use at server start, when no base
has an owner.

**Returns:** nothing. **Throws:** never.

---

### `RebirthService.ValidatePostRebirth(userId: number)`

A **diagnostic** that checks the post-rebirth runtime state.

**Checks:** a valid owned base; the `PlayerService` base binding
agreeing with it; at least one stand; a clean `CarryRegistry`; no live
steal involving the player; and every persisted egg record resolving to
a live slot.

**Behaviour:** each failure increments a counter and emits a
`'[RebirthLifecycle] POST-REBIRTH VALIDATION FAILED <reason>'` warning.
**It never fails the transaction** — it is called after the success
result has already been pushed.

**Returns:** nothing. **Throws:** never (the whole body is
`pcall`-guarded).

---

### `RebirthService.ForgetPlayer(userId: number)`

Leave cleanup.

**Drops:** the in-flight flag, the pending build override, and the
`ReplicatedStorage/RebirthPreviews/U<userId>/` folder (with its parked
clones).

**Never touches** live animals, the profile, or other players.

**Returns:** nothing. **Throws:** never.

---

### `RebirthService._TestReset()`

Clears the busy map. **Test-only.**

**Returns:** nothing. **Throws:** never.

---

## `ReplicatedStorage.Config.Economy.Rebirth`

The canonical requirement/reward ladder.

### Types

```lua
export type RebirthAnimalRequirement = {
    DefId: string,
    Trait: string?,
    MinimumLevel: number,
}

export type RebirthEntry = {
    Requirements: {
        Money: string,
        ArenaLevel: number,
        Animals: { RebirthAnimalRequirement },
    },
    Rewards: {
        StartingCash: string,
        MoneyMultiplier: number,
    },
    Reset: {
        Money: boolean,
        Base: boolean,
        Animals: boolean,
        ArenaLevel: boolean,
    },
    Stands: {
        Animal: number,
        Arena: number,
    },
}
```

---

### `Rebirth.Get(index: number): RebirthEntry?`

The entry for a rebirth number.

**Parameters:** `index` — 1-based.

**Returns:** the entry table, or `nil` for a non-number, a
non-integer, an index `< 1`, or an unconfigured index.

**Throws:** never.

Note: `Get(0)` is `nil` — Rebirth 0 is not a completable entry. Use
`StandsFor(0)` for the never-rebirthed counts.

---

### `Rebirth.MaxConfigured(): number`

The highest configured index. `0` when there are no entries.

**Returns:** a number. **Throws:** never.

---

### `Rebirth.StandsFor(rebirth: number): { Animal: number, Arena: number }`

The stand counts for a player at a given rebirth value.

**Parameters:** `rebirth` — `0` for a never-rebirthed player.

**Returns:** `{ Animal, Arena }`, never nil. For `rebirth < 1` it
returns `InitialStands`. Otherwise it returns the counts of the
**highest entry at or below** the value, so a player past the end of
the ladder keeps the last configured counts. If that entry has no
`Stands` table, it falls back to `InitialStands`.

**Throws:** never.

---

### `Rebirth.Validate(): { string }`

A non-throwing validation of the whole ladder.

**Checks:** every requirement field's type; that `Money` and
`StartingCash` are strings; that `ArenaLevel` is an integer `>= 0` and
`MinimumLevel` an integer `>= 1`; that `DefId` is a non-empty string
and `Trait` a string or nil; that `MoneyMultiplier` is a number `> 0`
and not NaN; that `Stands.Animal` / `Stands.Arena` are integers `>= 0`;
that `Reset` is a table; and that there are **no gaps** between `1` and
`MaxConfigured()`.

**Returns:** an array of human-readable issue strings. **An empty array
means the ladder is valid.** It never throws and never logs.

---

## `ReplicatedStorage.Utility.RebirthUnlocks`

A pure derivation of "what does this rebirth unlock", for the GUI.
Requires only configs — no Instances, no yields — so it is safe from
the server and from headless specs alike.

### Constants

```lua
RebirthUnlocks.Kind = {
    AnimalStand = 'AnimalStand',
    ArenaStand = 'ArenaStand',
    Gear = 'Gear',
}
RebirthUnlocks.White = OverheadConfig.FallbackColor   -- Color3
RebirthUnlocks.ArenaGold = OverheadConfig.TraitColors.Gold  -- Color3
```

### Type

```lua
export type UnlockEntry = {
    Kind: string,
    Amount: number,
    GearId: string?,
}
```

---

### `RebirthUnlocks.BuildForPreview(currentRebirth: number, nextIndex: number): { UnlockEntry }`

The unlock rows granted by completing `nextIndex`.

**Parameters:** `currentRebirth` — the player's current count;
`nextIndex` — the previewed rebirth.

**Returns:** an array of entries, **never nil**. Order: Animal stands,
Arena stands, then gears in `GearConfig` catalog order. An entry is
`{ Kind = 'AnimalStand', Amount = n }`,
`{ Kind = 'ArenaStand', Amount = n }`, or
`{ Kind = 'Gear', GearId = id, Amount = 1 }`.

**Returns an empty array** when:
- either argument is not a number,
- either argument is not an integer,
- `nextIndex < 1`,
- `nextIndex ~= currentRebirth + 1` (non-sequential),
- `RebirthConfig.Get(nextIndex)` is nil (unconfigured or maxed).

**Stand deltas** are `StandsFor(current)` vs the entry's `Stands`,
floored at 0 — a flat count produces **no card at all**, never a
`+0` card. **Gear unlocks** are every `GearConfig` entry whose
`RequiredRebirth == nextIndex`.

**Throws:** never. The config reads are `pcall`-guarded.

---

### `RebirthUnlocks.DisplayName(entry: UnlockEntry): string`

The card title.

- A gear entry: the canonical `GearConfig` `Name`, falling back to the
  `GearId` itself, then to `'?'`.
- An `AnimalStand` or `ArenaStand` entry: the plain string `'Stand'`.
- Anything else: `'?'`.

**Throws:** never. A nil entry returns `'?'`.

---

### `RebirthUnlocks.NameColor(entry: UnlockEntry): Color3`

The card name color.

- `ArenaStand` → `RebirthUnlocks.ArenaGold`.
- Everything else, including a nil entry → `RebirthUnlocks.White`.

**Throws:** never.

---

### `RebirthUnlocks.NumberVisible(entry: UnlockEntry): boolean`

Whether the card shows a count.

- A gear entry → `false` (a tool unlock is conceptually one item).
- Everything else, including nil → `true`.

**Throws:** never.

---

### `RebirthUnlocks.CountText(amount: any): string`

The `"+N"` card count.

**Returns:** `'+' .. tostring(n)`, where `n` is `tonumber(amount) or 0`
floored, with negatives clamped to `0`. `CountText(nil)` → `'+0'`.

**Throws:** never.

---

### `RebirthUnlocks.Signature(nextIndex: number, unlocks: { UnlockEntry }): string`

A stable change signature for the client's rebuild gate.

**Returns:** `"<nextIndex>:<Kind|GearId|Amount;...>"`. A nil `unlocks`
returns `"<nextIndex>:none"`; a nil `nextIndex` yields `"nil:none"`.

The same inputs always produce the same string, and a different
`nextIndex` always produces a different one — even when the contents
coincide.

**Throws:** never.

---

## `ReplicatedStorage.Utility.StandShowcase`

Used by the Rebirth preview cards. Clone-only helpers — they never
touch a live model.

### `StandShowcase.StripInteractiveOnly(model: Instance): ()`

Removes the UI and prompts from a clone while keeping the geometry.

**Returns:** nothing. **Throws:** never (the specs call it on a
hand-built model).

---

### `StandShowcase.FrontYawOffset(model: Instance): number?`

The yaw offset to the model's front button, or `nil` when no button
can be resolved. **It does not guess.**

**Returns:** a number or `nil`. **Throws:** never.

---

### `StandShowcase.ClearOutlines(card: Instance): ()`

Removes only the children named `ShowcaseOutline*` from a card. Other
children (e.g. the main `ViewportFrame`) are untouched.

**Returns:** nothing. **Throws:** never.

---

## Not part of the public API

| Symbol | Why it is not public |
|---|---|
| `RebirthService`'s `_busy`, `_pendingBuild`, `_wired` | Module-local state. |
| `RebirthService`'s `matchAnimals`, `attachTemplateModels`, `attachUnlockModels`, `previewFolder`, `resolveStandTemplate`, `checkRaidLock`, `pushState`, `formatMultiplier`, `_multLabel` | Module-local functions. `BuildState` and `RequestRebirth` are the public doors. |
| `RebirthConfig.ENTRIES` | The table is private; use `Get` / `MaxConfigured` / `StandsFor`. |
| `RebirthConfig.InitialStands` | Private; use `StandsFor(0)`. |
