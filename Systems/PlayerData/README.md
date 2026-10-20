# PlayerData

Owns the player profile: loading it, reconciling it, exposing it, and
releasing it.

**Portability:** Grade A core (the load/reconcile/audit pipeline) + Grade B
(the schema itself is Brainrot Arena's).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

`PlayerService` is the single owner of the player profile. It:

- Loads the profile through `ProfileService` (session-locked DataStore access).
- **Reconciles** it — `profile:Reconcile()` fills missing keys from the
  template, then ~20 hand-written per-field repair blocks fix wrong-typed
  values that `Reconcile` deliberately leaves alone.
- **Audits** the owned-object lists (`Brainrots`, `LuckyBlocks`) through
  `PersistenceAudit`, which repairs, quarantines, or re-homes invalid
  records before anything else reads them.
- Exposes the profile to other services (`GetPlayerData`), pushes player state
  to clients (`PushState`), and writes to the profile only through a narrow,
  audited set of mutators.
- Releases the profile on leave, settling any pending cash pools.

It is the only module in the game that touches `ProfileService`.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `PlayerService.Init()` | Server | No-op. The service is stateless until a profile loads. |
| `PlayerService.LoadPlayerData(player): boolean` | Server | The whole load pipeline. Returns `false` on failure — the caller must kick the player. |
| `PlayerService.CleanupPlayer(userId)` | Server | Called on leave and on every failure path. Releases the profile. |
| `PlayerService.GetPlayerData(userId): table?` | Server | The profile data, or `nil`. |
| `PlayerService.GetLoadedSignal(userId): Signal` | Server | Fires when the player is fully loaded (data + base assigned). |
| `PlayerService.MarkLoaded(userId)` | Server | Sets `Data.Loaded = true`. |
| `PlayerService.PushState(player, snapshot?)` | Server | Pushes `PlayerState` to the client. |
| `PlayerService.Notify(player, category, text)` | Server | The one notification channel. |
| `PlayerService.BumpStat(userId, statName)` | Server | Increments one of the four lifetime counters. |
| `PlayerService.AssignBase(userId, baseId)` | Server | Writes `Data.BaseId`. |
| `PlayerService.RemoveAnimal(userId, animalId)` | Server | Removes an animal record, settling its cash pool first. |
| `PlayerService.WipeUser(userId)` | Server | Resets every field back to template defaults. |
| `PlayerService.GetDataVersion(): string` | Server | The DataStore name literal. |
| `PlayerService.SetAnimalPoolSettlementHandler(fn)` | Server | Injected by bootstrap so the pool settlement does not require `IncomeService` back. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/PlayerService.lua` | `ServerScriptService.PlayerService` | The profile owner. |
| `Source/ServerScriptService/Base/PersistenceAudit.lua` | `ServerScriptService.Base.PersistenceAudit` | The owned-object list validator. |

---

## Configuration

There is no config module of its own. The tunables it reads live in other
systems' config and are documented there:

| Value | Lives in | Default | Meaning |
|---|---|---|---|
| `Money.StartingMoney` | `Config/Economy/Money.lua` | `'5000'` | First-join wallet seed. |
| `Money.MaxMoney` | `Config/Economy/Money.lua` | `'1000000000000000'` | Anti-exploit cap. Enforced by `EconomyService`, not here. |
| `Debug.SkipPersistence` | `Config/Systems/Debug.lua` | `false` | Studio-only: bypass DataStore entirely. |
| `Debug.AllowStudioTestUserIds` | `Config/Systems/Debug.lua` | `true` | Accept UserIds `0, -1, -2…` in Studio. |

The DataStore name is a **hardcoded literal** in `PlayerService.lua:115`:

```lua
local PROFILE_NAME = 'p7_PlayerData_Money_v1_dev_1'
```

There is no environment-suffix computation. Changing it is a **hard reset**:
the old store is abandoned, not migrated. A new game MUST change this string,
and should compute the environment suffix rather than typing it.

---

## Dependencies

See `Dependencies.md` for the full list. The load-bearing ones:

- `ServerScriptService.Packages.ProfileService` — the vendored session-locked
  DataStore wrapper. **Not included in this library**; install it from Wally
  or vendor it.
- `ReplicatedStorage.Config.Economy.Money` — starting money.
- `ReplicatedStorage.Config.Systems.Debug` — Studio test mode.
- `ServerScriptService.Base.PersistenceAudit` — list auditing.
- `ServerScriptService.Carry.CarryRegistry` — carry state on cleanup.
- `ReplicatedStorage.Utility.Remotes` — the `PlayerState` / `Notify` channels.

**Profile fields it OWNS** (no other system may write them):
`UserId`, `Loaded`, `LastSeen`, `Stats`, `Multipliers` (deprecated compat),
`BaseId` (written via `AssignBase`).

**Profile fields it READS but does not own:** `Money`, `Brainrots`,
`LuckyBlocks`, `Rebirth`, `Tutorial`, `GearAutoBuy`, `OwnedRobuxGear`,
`Settings`, `Arena`, `RedeemedCodes`, `PendingCodeRewards`, `DailyRewards`,
`PlaytimeRewards`.

**Remotes:** `PlayerState` (S→C), `Notify` (S→C).

---

## Initialization Order

`PlayerService` is the first service initialised. In the source game's
bootstrap:

```text
1. createRemotes()                    -- the Remotes folder must exist
2. EconomyService.Init()              -- before PlayerService, so the money
   EconomyService.SetPlayerService()     authority exists when it does
3. PlayerService.Init()
...
later: BaseService.SetPlayerService(PlayerService)
       PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)
```

`PlayerService` never requires `EconomyService` back — it depends on it only
through the injected settlement handler, which is what keeps the graph acyclic.

---

## Data

The profile is stored under the DataStore name above, keyed
`Player_<userId>`. The full schema is in `Dependencies.md` → *Profile Schema*.

The schema is Brainrot Arena's. A new game should expect to write its own
template and its own reconcile blocks; the **mechanism** (template → reconcile
→ per-field repair → audit) is the reusable part.

---

## Known Limitations

- **`ReplicatedStorage/Types/PlayerDataType.lua` is stale.** It declares
  `Cash: number` and four fields; the live schema has `Money: string` and
  twenty. It is required by nothing — it is dead documentation. The library
  copies it verbatim and flags it here rather than silently "fixing" it.
- **No schema version inside `profile.Data`.** Versioning is done by renaming
  the DataStore, which abandons old data. A new game that wants real
  migrations needs a version field and a migration ladder.
- **`Debug.SkipPersistence` shares mutable tables across players.** In that
  mode `Settings`, `Stats`, `Arena`, `DailyRewards`, and `PlaytimeRewards` are
  NOT deep-cloned per player (unlike `Multipliers`, `Tutorial`, and the two
  object lists). A Studio-only footgun.
- **`'ForceLoad'` session mode.** `LoadProfileAsync` uses the `'ForceLoad'`
  release handler, which steals the session lock from a possibly-live session.
  Appropriate for the dev store; questionable for production.
- **`Data.Money` is written directly in two places** that bypass
  `EconomyService`: `WipeUser` and `RebirthService`. Those writes skip the
  audit trail and the `MaxMoney` cap.

---

## Testing

`Tests/PlayerService.spec.lua` and `Tests/PersistenceAudit.spec.lua`.

They stub the profile and the remotes via `_Helpers`; **no DataStore is
touched**. They still require Roblox Studio. See `../../Tests/README.md`.

---

## Adapting to a New Game

1. **Write your own template table.** Keep the shape: flat keys for scalars,
   nested tables for sub-objects, and a `DeepCopy` for nested defaults.
2. **Keep the three-stage load**: `profile:Reconcile()` → per-field repair
   blocks → list audit. `Reconcile` will not fix wrong types, so the repair
   blocks are not optional.
3. **Compute your DataStore name**, including the environment suffix:
   ```lua
   local ENV = RunService:IsStudio() and 'dev' or 'live'
   local PROFILE_NAME = ('%s_PlayerData_v%d_%s'):format(GAME_PREFIX, SCHEMA_VERSION, ENV)
   ```
4. **Add a schema version field** if you want migrations rather than resets.
5. **Drop the `Multipliers` compat field** — it exists only as a Phase 2.7.1
   migration artefact and is always `1`.
