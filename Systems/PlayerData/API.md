# PlayerData — API

Every public function of the `PlayerData` system, with its exact signature
and its exact return contract.

**Conventions used throughout this library:**

- Server services are **singletons** required as modules. They are frozen
  (`table.freeze`) — you cannot add fields to them.
- Public entry points are `pcall`-wrapped internally. They **return a
  failure value; they do not throw** for expected errors.
- All money and price values are **BigNumber decimal strings** (`'5000'`),
  never Lua numbers.
- `userId` is always a `number` (a Roblox `UserId`), never a string.

---

## `PlayerService`

Required as:

```lua
local PlayerService = require(ServerScriptService.PlayerService)
```

### Lifecycle

#### `PlayerService.Init()`

No-op. `ProfileService` auto-creates its store; there is nothing to
pre-warm. The service is stateless until a profile loads.

Call it once, at bootstrap, before any player joins.

#### `PlayerService.LoadPlayerData(player: Player): boolean`

The whole load pipeline. Returns `true` on success, `false` on failure.

On failure the player is **not** in the service. The caller is expected to
kick them:

```lua
if not PlayerService.LoadPlayerData(player) then
	player:Kick('Could not load your save. Please rejoin.')
	return
end
```

The pipeline is: reserve the slot (`'ForceLoad'`) → clone the template →
`profile:Reconcile()` → ~20 hand-written repair blocks → `PersistenceAudit`.

**This function does not mark the player as loaded.** That is a separate
step (`MarkLoaded`), because the bootstrap also has to wait for base
assignment.

#### `PlayerService.CleanupPlayer(userId: number)`

Releases the profile. Settles any pending cash pools first.

Call on **every** leave path, including failure paths. If it is not called,
the profile stays session-locked and the player cannot rejoin until the lock
expires.

#### `PlayerService.WipeUser(userId: number): boolean`

Erases the profile's persisted fields and resets them to the template.

| | `CleanupPlayer` | `WipeUser` |
|---|---|---|
| Profile | released, data saved | erased |
| Rejoin | same data | fresh template |

`WipeUser` is per-player and does not require a Studio restart — unlike
changing the `ProfileService` store name, which is the older escape hatch.

---

### Reads

#### `PlayerService.GetPlayerData(userId: number): any?`

The profile data table, or `nil` if the player is not loaded.

This is the only way to read the profile. Never cache the returned table
across a frame — it is the live profile data.

#### `PlayerService.GetDataVersion(): string`

The active profile store name (the schema identity). Read-only; the store
itself is never exposed.

The source game's value is `'p7_PlayerData_Money_v1_dev_1'` — the `p7_` prefix is
the source game's identifier and must be renamed for a new game.

#### `PlayerService.GetTutorial(userId: number): any`

The tutorial state table. Returns the default tutorial state for a player
with no loaded profile rather than `nil`.

#### `PlayerService.GetBaseId(userId: number): string?`

The player's assigned base id, or `nil`.

#### `PlayerService.GetAnimals(userId: number): { any }`

The animal list. Returns an empty table (not `nil`) when the player has no
profile.

#### `PlayerService.GetEggs(userId: number): { any }`

The egg list. Returns an empty table (not `nil`) when the player has no
profile.

#### `PlayerService.IsLoaded(userId: number): boolean`

Whether the player's `loadedSignal` has fired.

#### `PlayerService.ConsumeOfflineTimestamp(userId: number): number`

Returns the player's `LastSeen` stamp and clears it, so offline earnings
can be computed against the interval since the last session. Returns `0` for
an unloaded player.

---

### Writes — animals

#### `PlayerService.AddAnimal(userId, slotId, defId, id?, opts?): boolean`

```lua
opts = {
	Level: number?,
	XP: number?,
	CashPool: string?,   -- BigNumber decimal string
	Trait: string?,
	Mutations: { string }?,
}
```

Adds an animal record to the profile and places it in `slotId`.

`id` is the owned-object identity. If omitted, one is generated. When
supplied, it must be valid per `OwnedObjectIdentity` rules.

Returns `false` for a missing profile, an invalid slot id, or a duplicate id.

#### `PlayerService.RemoveAnimal(userId: number, id: string?): boolean`

Removes an animal record. If `id` is omitted, the animal in the player's
first occupied animal slot is removed.

#### `PlayerService.RemoveAnimalAtSlot(userId: number, slotId: string): boolean`

Removes the animal occupying a specific slot.

#### `PlayerService.SetAnimalSlot(userId: number, id: string, newSlotId: string): boolean`

Moves an animal to a different slot. The old slot is released and the new
one occupied.

#### `PlayerService.ApplyLevelUpgrade` *(via the `Upgrades` system)*

Not on `PlayerService`. Level changes go through
`UpgradeService.UpgradeAnimal` — see the
[`Upgrades`](../Upgrades/API.md) API.

---

### Writes — eggs

#### `PlayerService.AddEgg(userId, slotId, rarity, id?, opts?): boolean`

```lua
opts = {
	Mutations: { string }?,
	Trait: string?,
}
```

Adds an egg record and places it in `slotId`.

#### `PlayerService.RemoveEgg(userId: number, id: string?): boolean`

Removes an egg record. If `id` is omitted, the egg in the player's first
occupied egg slot is removed.

#### `PlayerService.RemoveEggAtSlot(userId: number, slotId: string): boolean`

Removes the egg occupying a specific slot.

#### `PlayerService.SetEggSlot(userId: number, id: string, newSlotId: string): boolean`

Moves an egg to a different slot.

#### `PlayerService.SetEggMutations(userId: number, id: string, mutations: any): boolean`

Replaces an egg's mutation list. Goes through the same canonical sanitize
path as `AddEgg`, so the stored list is always canonicalised (sorted,
de-duplicated, validated).

---

### Writes — the egg → animal conversion

#### `PlayerService.ConsumeEggIntoAnimal(userId, eggId?, slotId, defId, animalId, inherit?): boolean`

```lua
inherit = {
	Trait: string?,
	Mutations: { string }?,
}
```

Consumes an egg and produces the animal it hatches into, in one durable step.

**Important edge case:** if the egg record is *already gone* (a double open,
or an interrupted earlier attempt), the animal is **still added** and the
anomaly is logged loudly. The egg was already consumed, so failing here
would destroy a legitimately created animal.

It never removes anything from the animals list and never converts a type in
either direction.

---

### Writes — misc

#### `PlayerService.BumpStat(userId: number, key: string): boolean`

Increments a counter in `profile.Data.Stats` (`EggsPurchased`,
`EggsHatched`, `AnimalsObtained`, `UpgradesApplied`, …).

Safe on a missing profile (returns `false`, never throws). Call it **after**
the commit it counts is durable, exactly once per success.

#### `PlayerService.SetTutorial(userId: number, patch: any): boolean`

Applies a partial patch to the tutorial state.

#### `PlayerService.AssignBase(userId: number, baseId: string): boolean`

Assigns the player to a base.

#### `PlayerService.ReleaseBase(userId: number)`

Releases the player's base. Takes no return value.

---

### Signals and state

#### `PlayerService.GetLoadedSignal(userId: number): any`

The `loadedSignal` for a player. It fires when **both** the data is loaded
**and** the base is assigned. The bootstrap uses it to gate state pushes and
to push the initial `PlayerState`.

#### `PlayerService.MarkLoaded(userId: number)`

Fires the player's `loadedSignal`. Called by the bootstrap after both
`LoadPlayerData` and base assignment have succeeded.

#### `PlayerService.SetAnimalPoolSettlementHandler(fn: ((number, any) -> ())?)`

The hand-off to the income system. The handler is called with
`(userId, pool)` when an animal's cash pool is settled — on sale, on
collect, or on leave.

Pass `nil` to clear it. If you install `Economy`/`Income` and forget this,
cash pools accumulate and are never paid; nothing errors.

---

### Replication

#### `PlayerService.PushState(player: Player, baseSnapshot: any)`

Fires the `PlayerState` remote to that one player.

`baseSnapshot` is optional — omit it and `Slots` in the payload is an empty
table.

```lua
{
	Money        = data.Money,   -- BigNumber decimal STRING
	BaseId       = data.BaseId,
	Slots        = baseSnapshot and baseSnapshot.slots or {},
	CarriedKind  = carry.Kind,
	CarriedName  = carry.Name,
	CarriedSteal = carry.Steal == true,
}
```

#### `PlayerService.Notify(player: Player, category: string, text: string)`

Fires the `Notify` remote with `{ Category = category, Text = text }`.

`NotificationService` owns the message catalogue; use
`NotificationService.NotifyWarning` for a *game* message instead of calling
this directly.

---

## `PersistenceAudit`

Required as:

```lua
local PersistenceAudit = require(ServerScriptService.Base.PersistenceAudit)
```

### `PersistenceAudit.Audit(profileData: any): AuditResult`

Runs the owned-object audit over a profile's data **in place**. It repairs,
quarantines, or re-homes invalid records.

```lua
export type AuditResult = {
	Animals: { any },      -- the cleaned animal list
	Eggs: { any },         -- the cleaned egg list
	Issues: { string },    -- one human-readable line per problem found
	Quarantined: number,   -- how many records were dropped
	Repaired: number,      -- how many were repaired in place
}
```

`PlayerService.LoadPlayerData` calls this automatically. You only call it
directly when auditing a profile outside the normal load path (a migration
tool, for example).

The audit is **not optional** — it is what makes a corrupted profile degrade
gracefully instead of breaking whichever system reads it first.

---

## `OwnedObjectIdentity`

Required as:

```lua
local OwnedObjectIdentity = require(ReplicatedStorage.Utility.OwnedObjectIdentity)
```

A shared utility (it lives in `Shared/CommonModules/`, not in this system).

| Function | Notes |
|---|---|
| `OwnedObjectIdentity.Generate(kind: string): string` | **Asserts** on an invalid kind. `AN_` is the canonical animal prefix. |
| `OwnedObjectIdentity.GenerateUnique(kind: string): string` | **Errors** after 8 collision retries. |
| `OwnedObjectIdentity.IsValid(kind: string, id: string): boolean` | |
| `OwnedObjectIdentity.KindOf(id: string): string?` | Infers the kind from the id prefix. |
| `OwnedObjectIdentity.MigrateLegacyId(id: string): string?` | Rewrites an old-format id. |

---

## The profile schema

The authoritative template is `STUDIO_PROFILE_TEMPLATE` inside
`PlayerService.lua`. (`ReplicatedStorage/Types/PlayerDataType.lua` is
**stale** — do not use it as the schema reference.)

```lua
{
	UserId = 0,
	Money = '0',                    -- BigNumber decimal STRING
	BaseId = nil,
	Loaded = false,
	Rebirth = 0,
	Tutorial = { Completed = false, Step = 'BuyEgg', EggId = nil, AnimalId = nil },
	Multipliers = { Money = 1 },    -- DEPRECATED compat data; always 1
	Stats = { EggsPurchased = 0, EggsHatched = 0, AnimalsObtained = 0, UpgradesApplied = 0 },
	Brainrots = {},                 -- the animal list
	LuckyBlocks = {},               -- the egg list
	GearAutoBuy = {},
	OwnedRobuxGear = {},
	Settings = { Bgm = 1, Sfx = 1, FastMode = false },
	Arena = { Level = 1, XP = 0, Wins = 0, HighestCompleted = 0, PendingEggs = {} },
	RedeemedCodes = {},
	PendingCodeRewards = {},
	DailyRewards = { WeekId = '', Day = 1, LastClaimAt = 0 },
	PlaytimeRewards = { DayId = '', PoolId = '', Claimed = {}, Completed = false },
	LastSeen = 0,
}
```

---

## Remotes used

| Remote | Direction | Payload |
|---|---|---|
| `PlayerState` | server → client | the `PushState` payload above |
| `Notify` | server → client | `{ Category: string, Text: string }` |

Both are created by the bootstrap's `createRemotes()` from
`ReplicatedStorage.Utility.Remotes.Names`.

---

## Error contract summary

| Situation | Behaviour |
|---|---|
| Profile not loaded | `GetPlayerData` → `nil`; mutators → `false`; `GetAnimals`/`GetEggs` → `{}` |
| Invalid slot id / duplicate id | mutator returns `false` |
| `WipeUser` on an unloaded player | `false` |
| `ConsumeEggIntoAnimal` with a missing egg | animal **is** added; anomaly logged |
| `BumpStat` on a missing profile | `false`, no throw |
| Anything unexpected | `pcall`-guarded; returns a failure value, does not throw |

---

## Related

| Document | Contents |
|---|---|
| [`README.md`](README.md) | What the system does |
| [`MEMORY.md`](MEMORY.md) | The non-obvious facts |
| [`Config.lua`](Config.lua) | Every tunable the system reads |
| [`Dependencies.md`](Dependencies.md) | Exact requires, DataStore, Studio assets |
| [`Setup.md`](Setup.md) | How to install it |
| [`../../Tests/README.md`](../../Tests/README.md) | How to run the specs |
