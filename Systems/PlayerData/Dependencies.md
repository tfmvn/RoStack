# PlayerData — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/PlayerService.lua`

```lua
require(ServerScriptService.Packages.ProfileService)   -- vendored, NOT in this library
require(ServerScriptService.Packages.Janitor)          -- Wally package, not in this library
require(ReplicatedStorage.Config.Economy.Money)
require(ReplicatedStorage.Config.Systems.Debug)
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.OwnedObjectIdentity)
require(ReplicatedStorage.Config.Creatures.Progression)
require(ServerScriptService.Base.PersistenceAudit)
require(ServerScriptService.Carry.CarryRegistry)
require(ServerScriptService.MutationService)
require(ReplicatedStorage.Utility.Signals)   -- lazy, inside GetLoadedSignal
```

### `ServerScriptService/Base/PersistenceAudit.lua`

```lua
require(ReplicatedStorage.Config.Creatures.Progression)
require(ReplicatedStorage.Config.Creatures.Traits)
require(ReplicatedStorage.Config.Creatures.Mutations)
require(ReplicatedStorage.Config.Creatures.Animals)
require(ReplicatedStorage.Config.Creatures.Eggs)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.OwnedObjectIdentity)
require(ReplicatedStorage.Utility.Validation)
```

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **Economy** | `StartingMoney` seed; the `Money` field lives in the economy's domain. | Required for the seed; the field itself is plain data. |
| **Carry** (`CarryRegistry`) | Cleanup must know whether the player was carrying something so it can be returned. | Required for correctness on leave. |
| **MutationsAndTraits** (`MutationService`) | Animal records carry traits and mutations; the trait/mutation catalogues are needed to validate them. | Required if your game has traits/mutations. |

Everything else is a **leaf dependency** — config and utility modules with no
back-references.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `PlayerState` | S→C | `{Money (string), BaseId, Slots, CarriedKind, CarriedName, CarriedSteal}` |
| `Notify` | S→C | `{Category, Text}` |

The remotes are created at boot from the `Remotes.Names` registry — see
`Shared/CommonModules/Remotes.lua`. Do not hand-author them.

---

## Profile Schema

The `ProfileService` template (`PlayerService.lua:116-201`). This is
**Brainrot Arena's schema** — replace it for a new game, but keep the shape.

| Key | Type | Default | Owner | Meaning |
|---|---|---|---|---|
| `UserId` | number | `0` | PlayerService | Overwritten on load. |
| `Money` | string (BigNumber) | `'0'` | EconomyService | The wallet. A decimal string, never a number. |
| `BaseId` | string? | `nil` | BaseService | The assigned base, `nil` until assigned. |
| `Loaded` | boolean | `false` | PlayerService | Set `true` by `MarkLoaded`. |
| `Rebirth` | number | `0` | RebirthService | Completed rebirth count. |
| `Tutorial` | table | `{Completed=false, Step='BuyEgg', EggId=nil, AnimalId=nil}` | TutorialService | Onboarding progress. |
| `Multipliers` | table | `{Money=1}` | **Deprecated** | Always `1`. Compat field only. |
| `Stats` | table | `{EggsPurchased=0, EggsHatched=0, AnimalsObtained=0, UpgradesApplied=0}` | PlayerService | Lifetime counters. |
| `Brainrots` | array | `{}` | AnimalService | Owned animal records. |
| `LuckyBlocks` | array | `{}` | EggService | Owned egg records. |
| `GearAutoBuy` | table | `{}` | GearShopService | Per-gear auto-buy preference. |
| `OwnedRobuxGear` | table | `{}` | ShopService | Robux gear entitlement map. |
| `Settings` | table | `{Bgm=1, Sfx=1, FastMode=false}` | SettingsService | Client presentation prefs. |
| `Arena` | table | `{Level=1, XP=0, Wins=0, HighestCompleted=0, PendingEggs={}}` | ArenaProgressionService | Arena progression. |
| `RedeemedCodes` | table | `{}` | CodesService | `[codeId] = count`. |
| `PendingCodeRewards` | array | `{}` | CodesService | FIFO queue of slot-bound rewards. |
| `DailyRewards` | table | `{WeekId='', Day=1, LastClaimAt=0}` | DailyRewardsService | Streak state. |
| `PlaytimeRewards` | table | `{DayId='', PoolId='', Claimed={}, Completed=false}` | PlaytimeRewardsService | Course progress. |
| `LastSeen` | number | `0` | PlayerService | Unix seconds of the last confirmed presence. |

### Record shapes

**Animal** (`Brainrots` entry, written at `PlayerService.lua:821-831`):

| Field | Type | Notes |
|---|---|---|
| `Type` | `'Brainrot'` | Stamped. |
| `SlotId` | string | `p7:<userId>:slot:<index>`. |
| `DefId` | string | Animal definition id. |
| `Id` | string | `AN_` + 10 base-62 chars. |
| `Level` | number | 1..`Progression.MaxLevel`. |
| `XP` | number | Current progress toward the next level. |
| `CashPool` | string (BigNumber) | Accumulated uncollected cash. |
| `Trait` | string? | Trait id. |
| `Mutations` | {string} | Mutation ids. |

**Egg** (`LuckyBlocks` entry, written at `PlayerService.lua:892-899`):

| Field | Type | Notes |
|---|---|---|
| `Type` | `'LuckyBlock'` | Stamped. |
| `SlotId` | string | |
| `Rarity` | string | One of the eight rarities. |
| `Id` | string | `EG_` + 10 base-62 chars. |
| `Mutations` | {string} | |
| `Trait` | string? | **Hidden** pending-trait payload. |

---

## DataStore

| Property | Value |
|---|---|
| Store name | `p7_PlayerData_Money_v1_dev_1` (hardcoded literal) |
| Key format | `Player_<userId>` |
| Release handler | `'ForceLoad'` |
| Scope | unset (a plain string name, not a `{Name=..., Scope=...}` table) |

The store name carries the schema version and a manually-typed environment
suffix. Changing it abandons the old data.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  EconomyService.Init()
3.  EconomyService.SetPlayerService(PlayerService)
4.  PlayerService.Init()
5.  ... other services inject themselves into PlayerService ...
6.  PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)
7.  On PlayerAdded:
      PlayerService.LoadPlayerData(player)   -- must succeed or the player is kicked
      BaseService.AssignBaseForPlayer / AssignBase
      BaseService.PointPlayerToBaseSpawn
      BaseService.RestorePlayerBase
      IncomeService.ApplyOfflineEarnings
      CodesService.OnPlayerReady
      PlaytimeRewardsService.OnPlayerReady
      PlayerService.MarkLoaded  -- fires GetLoadedSignal
      PlayerService.PushState
```

---

## Studio Assets

**None.** `PlayerService` does not read the Workspace or ServerStorage.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `DataStoreService` (via ProfileService) | Profile load/save | `Enable Studio Access to API Services` in Studio; published place needs no toggle. |
| `Players` | Player lifecycle | — |

No HTTP. No Marketplace.
