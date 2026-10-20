# Upgrades — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/UpgradeService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
require(script.Parent.Base.NotificationService)
require(script.Parent.Arena.ArenaService)
require(script.Parent.Tutorial.TutorialSignals)
require(script.Parent.FunnelService)
```

### `ReplicatedStorage/Config/Creatures/Progression.lua`

No requires.

---

## Other Systems Required

### Injected at runtime (late-bound — `Set*Service`)

| System | Module | Method used | Why | Optional? |
|---|---|---|---|---|
| **PlayerData** | `ServerScriptService.PlayerService` | `GetPlayerData`, `PushState`, `BumpStat` | Reads the wallet for the shortfall, pushes the fresh state, and bumps the `UpgradesApplied` counter. | **Required** — without it every upgrade is `service-unavailable`. |
| **Inventory** | `ServerScriptService.Base.SlotService` | `FindSlotByOccupant` | Resolves the animal to its live slot; the slot's `state` / `occupantId` / `ownerUserId` are all validated. | **Required** |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `GetBaseById`, `Snapshot` | Base ownership (defense in depth) and the post-upgrade state push. | **Required** (even though the base check is written as "if the method exists" — `_wired()` demands the ref). |
| **Animals** | `ServerScriptService.AnimalService` | `Get`, `ApplyLevelUpgrade` | The runtime record and the level mutation. | **Required** |
| **Economy** | `ServerScriptService.EconomyService` | `TrySpendMoney` | The atomic debit. | **Required** |

All five must be set. `_wired()` (`UpgradeService.lua:246-252`) returns
`false` if any is missing, and the transaction returns
`'service-unavailable'`.

### Required at load time (direct `require`)

| System | Module | Why | Optional? |
|---|---|---|---|
| **Animals** | `ReplicatedStorage.Config.Creatures.Animals` | `Get` (the rarity) and `SellBaseValue[rarity]` (the base price). | **Required** |
| **Upgrades** | `ReplicatedStorage.Config.Creatures.Progression` | `MaxLevel`, `XP.GrowthRate` (the assert). | **Required** |
| **SharedUtilities** | `ReplicatedStorage.Utility.BigNumber` | The exact decimal arithmetic. | **Required** |
| **SharedUtilities** | `ReplicatedStorage.Utility.Validation` | `Validation.LivePlayer`. | **Required** |
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | The `'UP'` logging channel. | **Required** |
| **SharedUtilities** | `ReplicatedStorage.Types.TransactionReason` | `TransactionReason.AnimalUpgrade`. | **Required** |
| **Notifications** | `ServerScriptService.Base.NotificationService` | `NotifyWarning` / `NotifySuccess`. | **Required** at load — the require is unconditional. |
| **Arena** | `ServerScriptService.Arena.ArenaService` | `IsAnimalRaidLocked`. | **Optional in practice** — the require is unconditional, but the check is a single call you can delete. |
| **Tutorials** | `ServerScriptService.Tutorial.TutorialSignals` | `Fire('AnimalUpgraded', ...)`. | **Optional in practice** — the require is unconditional; the `Fire` is `pcall`-guarded. |
| **Analytics** | `ServerScriptService.FunnelService` | `LogStep` and `LevelBand`. | **Optional in practice** — the require is unconditional; every call is `pcall`-guarded. |

### Consumers (you must wire these)

| Consumer | What it needs | How |
|---|---|---|
| `SlotMenuService` | The cost for the confirm dialog and the upgrade action | `SlotMenuService.SetUpgradeService(UpgradeService)` |
| `StandDisplayService` | The next cost for the stand readout | `StandDisplayService.SetUpgradeService(UpgradeService)` |
| `AnimalService` | The `MaxLevel` cap | Reads `Progression` directly — no wiring needed. |

---

## Remotes

| Remote | Direction | Payload shape |
|---|---|---|
| `SlotMenuAction` | C→S | `{ SlotId, OccupantId, Action = 'Upgrade' }`. **The upgrade has no remote of its own** — it is reached through the slot menu. `SlotMenuService` routes it to `UpgradeService.UpgradeAnimal` and fires `SlotMenuResult` (with `NewLevel` and `Cost` on success). |
| `SlotMenuResult` | S→C | The menu's result. Owned by `SlotMenuService`, not by `UpgradeService`. |

`UpgradeService` itself fires **no** remote. Its only outbound
communication is `PlayerService.PushState` (which sends `PlayerState`).

Remote names come from `ReplicatedStorage.Utility.Remotes` (the
`Remotes.Names` registry). The server creates the events at boot from
that registry — **do not hand-author them**.

---

## Profile Fields

### Written by this system

| Field | Type | Writer | Notes |
|---|---|---|---|
| `Money` | string (BigNumber) | `EconomyService.TrySpendMoney` (called by `UpgradeService`) | Debited by the exact cost. The reason is `TransactionReason.AnimalUpgrade`. **Not written directly by `UpgradeService`.** |
| `Brainrots[].Level` | number (integer) | `AnimalService.ApplyLevelUpgrade` (called by `UpgradeService`) | The only field the upgrade changes. The service mirrors the new level into the profile record itself. |
| `Stats.UpgradesApplied` | number | `PlayerService.BumpStat` (called by `UpgradeService`) | The lifetime counter, bumped **once per committed upgrade**. |

### Read by this system

| Field | Type | Reader | Notes |
|---|---|---|---|
| `Money` | string (BigNumber) | `UpgradeService._upgradeShortfall` | The wallet, for the "you need $X more" message. |
| `Multipliers.Money` | number | — | **Never read.** The upgrade cost ignores it (the spec proves a legacy `Multipliers.Money = 10` changes nothing). |

### Untouched by design

`Brainrots[].XP`, `Brainrots[].CashPool`, `Brainrots[].Id`,
`Brainrots[].DefId`, `Brainrots[].SlotId`, `Brainrots[].Trait`,
`Brainrots[].Mutations`. The spec asserts every one of these is
preserved across an upgrade.

**Not persisted:** the cost. There is no `rec.UpgradeCost` field —
the spec asserts it is `nil` after an upgrade. The next cost is
always re-derived from the persisted `Level`.

---

## Required Studio Assets

**None.** `UpgradeService` reads no Workspace or ServerStorage
hierarchy at all. The animal models, stands, and the slot-menu GUI
belong to the **Animals** and **Inventory** systems, not to this one.

The one presentation dependency is indirect: `AnimalService`'s
`ApplyLevelUpgrade` calls `LevelUpPresentation.NotifyLevelUp` (the
happy bop and the Upgrade VFX) and `AnimalOverhead.Refresh`. Both are
`pcall`-guarded, so a missing asset degrades gracefully — the level
still applies.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `Players` | Implicitly, through the `Player` argument to `UpgradeAnimal`. | — |
| `DataStoreService` | **Indirect only**, through `PlayerService`'s profile. | `Enable Studio Access to API Services` in Studio. |

No HTTP requests. No Marketplace calls. No `HttpService`.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  UpgradeService.SetPlayerService(PlayerService)
3.  UpgradeService.SetSlotService(SlotService)
4.  UpgradeService.SetBaseService(BaseService)
5.  UpgradeService.SetAnimalService(AnimalService)
6.  UpgradeService.SetEconomyService(EconomyService)
7.  SlotMenuService.SetUpgradeService(UpgradeService)      -- the player's UI
8.  StandDisplayService.SetUpgradeService(UpgradeService)   -- the stand readout
9.  --- players may now join ---
```

There is **no `UpgradeService.Init()`** and **no `ForgetPlayer()`** —
the service holds no per-player state of its own. (The per-animal
`_mutex` lives on the AnimalService runtime record and is cleaned up
with it.)

The ordering constraint is only that `UpgradeService` must be
**required** after `Progression` and `Animals` — which is automatic,
since it requires them itself. The `assert` on
`Progression.XP.GrowthRate == 1.12` runs at that require, so a
mispatched config takes the server down at boot, not at the first
upgrade.
