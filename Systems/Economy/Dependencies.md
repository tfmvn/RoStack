# Economy — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/EconomyService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
```

### `ServerScriptService/IncomeService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
require(script.Parent.Parent.ReplicatedStorage.Types.SlotType)
require(script.Parent.Base.CollectFeedback)
require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
require(script.Parent.Utility.MoneyIcon)
```

### `ServerScriptService/ModifierService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
```

### `ServerScriptService/SellService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Animals)
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Progression)
require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
require(script.Parent.Parent.ReplicatedStorage.Utility.Validation)
require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Traits)
require(script.Parent.Parent.ReplicatedStorage.Config.Creatures.Mutations)
require(script.Parent.Animal.CarryPrompts)
require(script.Parent.Base.NotificationService)
require(script.Parent.Action.SlotActionHandler)
require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
require(script.Parent.Parent.ReplicatedStorage.Utility.AnimalStats)
require(script.Parent.Arena.ArenaService)
-- lazy, inside SellAnimal:
require(script.Parent.Codes.CodesService)   -- pcall-guarded
```

### `ReplicatedStorage/Config/Economy/Money.lua`

No requires.

### `ReplicatedStorage/Config/Economy/Sell.lua`

No requires.

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **PlayerData** | `ServerScriptService.PlayerService` | Owns the profile; `GetPlayerData` is the only way the economy reads or writes `Money`. Injected, not required. | **Required** — without it every money call fails with `no-profile`. |
| **Inventory** | `ServerScriptService.Base.SlotService` | `FindSlotByOccupant` resolves an animal to its slot (eligibility, collection, sale). Injected. | **Required** for income and sale. |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `GetAllBases`, `Snapshot`, `GetBaseById` — the collector sweep and the post-mutation push. Injected. | **Required** for collection and the HUD push. |
| **Animals** | `ServerScriptService.AnimalService` | `Get`, `GetCarriedAnimalByUserId`, `IsArenaDeployed`, `GetTemplate`, `DestroyRuntimeAnimal`, `ApplyLevelUpgrade` (the last is UpgradeService's). Injected. | **Required** for income eligibility and sale teardown. |
| **Animals** | `ServerScriptService.Animal.CarryPrompts` | `SetSellPromptCallback`, `_UnregisterPromptsForSlot`. **Required at load time.** | Required — `SellService` cannot be required without it. |
| **Inventory** | `ServerScriptService.Action.SlotActionHandler` | The unified action pipeline the sell confirmation routes through. **Required at load time.** | Required. |
| **Notifications** | `ServerScriptService.Base.NotificationService` | `NotifySuccess` on a committed sale. **Required at load time.** | Required. |
| **Arena** | `ServerScriptService.Arena.ArenaService` | `IsAnimalRaidLocked` — a raid-locked animal cannot be sold. **Required at load time.** | Required. |
| **Collectors** | `ServerScriptService.Base.CollectFeedback` | `Play(player, slot)` — the collection SFX/VFX on a committed claim. **Required at load time.** | Required. |
| **SharedUtilities** | `ServerScriptService.Utility.MoneyIcon` | `Resolve()` — the icon descriptor shipped with `CashCollected`. **Required at load time.** | Required. |
| **MutationsAndTraits** | `Config/Creatures/Traits.lua`, `Config/Creatures/Mutations.lua` | `SellMultiplierFor`, `SellFold` — the sell-value factors. **Required at load time.** | Required. |
| **Animals** | `Config/Creatures/Animals.lua` | `Get`, `SellBaseValue`, `SellMultiplier` — the price ladder. **Required at load time.** | Required. |
| **Upgrades** | `Config/Creatures/Progression.lua` | `MaxLevel` — the level ceiling the sell/upgrade paths validate against. **Required at load time.** | Required. |
| **CodesAndRewards** | `ServerScriptService.Codes.CodesService` | `TryDeliverPending(userId)` after a sale frees a slot. Lazy `require`, `pcall`-guarded. | **Optional** — the sale succeeds without it. |
| **Analytics** | `ServerScriptService.FunnelService` | Not used by this system directly (the sale/collection paths log through `Debug`). | Optional. |

---

## Remotes

| Remote | Direction | Payload shape |
|---|---|---|
| `PlayerState` | S→C | `{ Money (string), BaseId, Slots, CarriedKind, CarriedName, CarriedSteal }`. Pushed by `EconomyService.pushMoneyState` after **every** successful money write, and by `SellService._pushState` after a sale. |
| `CashCollected` | S→C | `{ Amount (string, BigNumber), NewMoney (string?), Icon (table?), Origin ({x,y,z}?) }`. Fired to the collecting player only after a successful claim, and to the seller after a committed sale (there without `Icon`/`Origin`). |
| `SellPreviewState` | S→C | `{ Valid (boolean), AnimalId, SlotId, Name, Rarity, Trait?, Level, LevelText, GenerationText, Mutations, SellValueRaw?, Model? }` on success; `{ Valid = false, AnimalId, Reason? }` on failure. `Model` is the live animal Model instance (the client clones it). |
| `SellConfirmAction` | C→S | `{ AnimalId (string) }`. The GUI's Sell button. |
| `SellConfirmResult` | S→C | `{ AnimalId, Success (boolean), Error (string?) }`. |

Remote names come from `ReplicatedStorage.Utility.Remotes` (the
`Remotes.Names` registry). The server creates the events at boot from
that registry — **do not hand-author them**.

`IncomeService` has **no** remote of its own. The client reads the pool
through the `CashPool` **attribute** on each slot's cash collector part
(attributes replicate for free), and touch collection is resolved
entirely server-side.

---

## Profile Fields

### Written by this system

| Field | Type | Writer | Notes |
|---|---|---|---|
| `Money` | string (BigNumber) | `EconomyService` | The wallet. A decimal string, never a number. **Also written directly by `PlayerService.WipeUser` and `RebirthService` — both bypass the audit trail and the `MaxMoney` cap.** |
| `Brainrots[].CashPool` | string (BigNumber) | `IncomeService` | The per-animal uncollected cash. Zeroed only after the money lands. |
| `LastSeen` | number (unix seconds) | `IncomeService._tickPlayer` | Refreshed at most every `OfflineHeartbeatSeconds`. Consumed exactly once via `PlayerService.ConsumeOfflineTimestamp`. |

### Read by this system

| Field | Type | Reader | Notes |
|---|---|---|---|
| `Multipliers.Money` | number | `EconomyService.AddMoney` | **Deprecated compat field.** Always `1` in legitimate profiles. Only consulted when `opts.ApplyMultiplier` is not explicitly `false` (the default is `true`). |
| `Brainrots[]` | array | `IncomeService`, `SellService` | The animal records. `Id`, `Type`, `DefId`, `Level`, `Trait`, `Mutations`, `CashPool` are read. |

### Owned elsewhere (read here, written elsewhere)

| Field | Owner |
|---|---|
| `Stats.UpgradesApplied` | `UpgradeService` (via `PlayerService.BumpStat`). Not written by the Economy system. |
| `Rebirth` | `RebirthService` — also writes `Money` directly during a rebirth reset. |
| `Brainrots[].Id / DefId / Level / Trait / Mutations` | `AnimalService` / `PlayerService`. |

---

## Required Studio Assets

The Economy system reads the Workspace and ServerStorage in exactly two
places, both in `IncomeService`.

| Asset | Path shape | Used for | If missing |
|---|---|---|---|
| Cash collector part | `Base.slots[i].cashCollector` — a `BasePart` on the player's stand | The `Touched` connection, the `CashPool` attribute, and the display label | No collection is possible. The part is the trigger; the attribute is the client-visible pool. |
| Display label | `cashCollector.SurfaceGui.Amount` (TextLabel) — MAIN GAME shape. Legacy fallback: `cashCollector.CollectorGui.MoneyLabel` (TextLabel). | Mirroring the pool into the stand's amount label | Warns **once per part**; the attribute still publishes, so the pool is still correct. Only the on-part number is missing. |
| Animal models | The stand's animal model (an `Instance` reference on the runtime record) | `SellService.PreviewSell` ships the live model to the client for the viewport | `PreviewSell` logs a warn; the confirmation GUI renders text-only. The sale itself still works. |
| Money icon | `ReplicatedStorage.Assets.Decals.MoneyIcon` (an `ImageLabel`) — read by `ServerScriptService.Utility.MoneyIcon.Resolve()` | The icon descriptor shipped with `CashCollected` | `MoneyIcon.Resolve()` returns `nil`; the client falls back to its default icon. |

The `CashPool` attribute name and the label paths are **hardcoded** in
`IncomeService.lua:215-260`. Change both together if your world uses
different names.

**No DataStore, no Marketplace, no HTTP.** The economy writes into
`PlayerService`'s profile; it has no persistence of its own.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `Players` | `GetPlayerByUserId` (the post-mutation push), `GetPlayers` (the income tick's player list) | — |
| `DataStoreService` | **Indirect only**, through `PlayerService`'s profile | `Enable Studio Access to API Services` in Studio. |

No HTTP requests. No Marketplace calls. No `HttpService`.

---

## Initialization Order

```text
1.  ReplicatedStorage.Remotes folder created (bootstrap.createRemotes)
2.  EconomyService.Init()
3.  EconomyService.SetPlayerService(PlayerService)
4.  PlayerService.Init()
5.  SlotService.Init()
6.  BaseService.Init() ; BaseService.SetPlayerService / SetSlotService /
    SetEggService / SetAnimalService
7.  EggService.Init() + its setters
8.  AnimalService.Init() + its setters
9.  EconomyService.SetBaseService(BaseService)     -- enables pushMoneyState
10. ModifierService.Init()
11. IncomeService.SetModifierService(ModifierService)
12. AnimalService.SetModifierService(ModifierService)
13. SellService.SetPlayerService / SetSlotService / SetBaseService /
    SetAnimalService / SetEggService / SetEconomyService /
    SetIncomeService / SetModifierService
14. SellService.Init()        -- wires the Sell prompt + SellConfirmAction
15. IncomeService.Init()
16. IncomeService.SetPlayerService / SetEconomyService / SetSlotService /
    SetBaseService / SetAnimalService
17. PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)
18. SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)
19. RebirthService.Init()     -- registers the 'Rebirth' MoneyMultiplier source
20. --- players may now join ---
21. IncomeService.Start()     -- AFTER the bases/collectors exist
```

Per-player, on `PlayerAdded` (order matters):

```text
1. PlayerService.LoadPlayerData(player)     -- Money seeded from
                                              Money.StartingMoney
2. BaseService.AssignBaseForPlayer / AssignBase / PointPlayerToBaseSpawn
3. BaseService.RestorePlayerBase(userId, profileData)
4. IncomeService.ApplyOfflineEarnings(player)  -- BEFORE the state push, so
                                                 the client never sees a pool
                                                 that omits offline earnings
5. RebirthService.ApplySessionModifiers(userId) -- restores the multiplier
6. PlayerService.MarkLoaded
7. PlayerService.PushState(player, BaseService.Snapshot(userId))
```

On leave:

```text
IncomeService.ForgetPlayer(userId)     -- debounce + fractional remainders
ModifierService.ForgetPlayer(userId)   -- every source for the player
```
