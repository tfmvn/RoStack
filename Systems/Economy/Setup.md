# Economy — Setup

Installing the Economy system into a new Rojo project. Steps 1-4 are
the minimum for a working wallet; steps 5-8 add income, modifiers, and
selling.

---

## 1. Copy the files

Copy each file to the Roblox path it occupied in the source game. The
`require` paths inside the copied files only resolve if the **tree
shape** matches.

| Copy from | To | Required? |
|---|---|---|
| `Source/ServerScriptService/EconomyService.lua` | `ServerScriptService/EconomyService.lua` | **Yes** |
| `Source/ServerScriptService/ModifierService.lua` | `ServerScriptService/ModifierService.lua` | Yes (income reads it) |
| `Source/ServerScriptService/IncomeService.lua` | `ServerScriptService/IncomeService.lua` | Optional (pools + offline) |
| `Source/ServerScriptService/SellService.lua` | `ServerScriptService/SellService.lua` | Optional (selling) |
| `Source/ReplicatedStorage/Config/Economy/Money.lua` | `ReplicatedStorage/Config/Economy/Money.lua` | **Yes** |
| `Source/ReplicatedStorage/Config/Economy/Sell.lua` | `ReplicatedStorage/Config/Economy/Sell.lua` | Only with the sell UI |

The `ReplicatedStorage/Config/Economy/` folder must exist even if you
only copy `Money.lua` — `Money.lua` is required by path, not by
discovery.

**Shared modules you also need** (from `ReusableSystems/Shared/`, all
of which go to `ReplicatedStorage/Utility/` except the types):

| Library file | Roblox destination |
|---|---|
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Shared/CommonModules/AnimalStats.lua` | `ReplicatedStorage/Utility/AnimalStats.lua` |
| `Shared/Types/TransactionReason.lua` | `ReplicatedStorage/Types/TransactionReason.lua` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |

Plus their own dependencies (`Signals`, `StudioTestMode`,
`RarityType`, the `t` package, `StatCalculator`, `Rarity` config …) —
see `ReusableSystems/Shared/` and each file's header.

---

## 2. Third-party packages (Wally)

From the source game's `wally.toml`:

```toml
[dependencies]
evaera_cmdr = "evaera/cmdr@1.12.0"     -- only if you also install AdminTools
```

The Economy system itself needs **no** third-party package, but
`Validation.lua` requires `ReplicatedStorage.Packages.t`
(`osyrisrblx/t`), which the source game vendors under `Packages/`.

If you use `PlayerData` as well, you also need:

```toml
[dependencies]
janitor = "kineticwallet/janitor@1.17.0"
```

and the vendored `ProfileService` at
`ServerScriptService/Packages/ProfileService.lua`.

---

## 3. Configuration to tune

Open `ReplicatedStorage/Config/Economy/Money.lua` and adjust:

| Value | Default | When to change it |
|---|---|---|
| `StartingMoney` | `'5000'` | Always — this is your game's opening wallet. |
| `MaxMoney` | `'1000000000000000'` | Only if you expect balances to approach it. |
| `IncomeTickSeconds` | `1` | Leave it. It is a granularity, not a rate. |
| `MaxOfflineSeconds` | `10800` (3 h) | If your game has no offline earnings, set `0`. |
| `OfflineEffectiveness` | `0.5` | If offline should pay as much as online, set `1`. |
| `OfflineHeartbeatSeconds` | `60` | Leave it. |
| `CollectorDebounceSeconds` | `0.25` | A feel knob. |
| `CashPoolAttributeThrottleSeconds` | `1` | Leave it unless the display lags visibly. |

`ReplicatedStorage/Config/Economy/Sell.lua` is presentation only —
replace the numbers freely if you build the sell UI.

**Price ladders** are not in this system. Set them in your own animal
catalogue: a base price per rarity, and a liquidation factor per
rarity. `SellService.GetAnimalBaseSellValue` and
`UpgradeService.GetBasePrice` read the same table.

**Transaction reasons.** If you add a reason, edit
`ReplicatedStorage/Types/TransactionReason.lua` — both the table and
the `_ALL` list. `EconomyService` rejects anything outside that list.

---

## 4. Bootstrap: the exact sequence

Add this to your `ServerScriptService/bootstrap.server.lua` (or
equivalent). The order is load-bearing; each comment says why.

```lua
-- ReplicatedStorage
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

-- --- 1. Remotes first: everything downstream fires to them ---
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Instance.new('Folder')
remotesFolder.Name = 'Remotes'
remotesFolder.Parent = ReplicatedStorage
Remotes.SetRemotes(remotesFolder)

-- --- 2. The wallet authority ---
local EconomyService = require(ServerScriptService.EconomyService)
local ModifierService = require(ServerScriptService.ModifierService)
local IncomeService = require(ServerScriptService.IncomeService)
local SellService = require(ServerScriptService.SellService)
local PlayerService = require(ServerScriptService.PlayerService)   -- PlayerData system

-- --- 3. Economy before PlayerService: the money authority must exist
---     when the profile's reconcile pass seeds the starting balance.
EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)

-- --- 4. PlayerService loads profiles ---
PlayerService.Init()

-- --- 5. Slot / Base / Animal services (BasesAndSlots, Inventory, Animals)
local SlotService = require(ServerScriptService.Base.SlotService)
local BaseService = require(ServerScriptService.BaseService)
local AnimalService = require(ServerScriptService.AnimalService)

SlotService.Init()
BaseService.Init()
BaseService.SetPlayerService(PlayerService)
BaseService.SetSlotService(SlotService)
BaseService.SetAnimalService(AnimalService)

AnimalService.Init()
AnimalService.SetPlayerService(PlayerService)
AnimalService.SetBaseService(BaseService)
AnimalService.SetSlotService(SlotService)

-- --- 6. BaseService enables the post-mutation PlayerState push.
---     Without this, money changes never reach the HUD.
EconomyService.SetBaseService(BaseService)

-- --- 7. Modifiers ---
ModifierService.Init()
IncomeService.SetModifierService(ModifierService)
AnimalService.SetModifierService(ModifierService)

-- --- 8. Income ---
IncomeService.Init()
IncomeService.SetPlayerService(PlayerService)
IncomeService.SetEconomyService(EconomyService)
IncomeService.SetSlotService(SlotService)
IncomeService.SetBaseService(BaseService)
IncomeService.SetAnimalService(AnimalService)

-- --- 9. Removal settlement: a deleted animal's pool becomes money
---     BEFORE the record leaves the profile.
PlayerService.SetAnimalPoolSettlementHandler(IncomeService.SettleAnimalPool)

-- --- 10. Slot transitions re-publish the pool immediately ---
SlotService.SetPoolDisplayCallback(IncomeService.RepublishSlot)

-- --- 11. Selling (skip if you are not shipping a sell flow) ---
SellService.SetPlayerService(PlayerService)
SellService.SetSlotService(SlotService)
SellService.SetBaseService(BaseService)
SellService.SetAnimalService(AnimalService)
SellService.SetEggService(EGG_SERVICE)      -- compat no-op
SellService.SetEconomyService(EconomyService)
SellService.SetIncomeService(IncomeService)
SellService.SetModifierService(ModifierService)
SellService.Init()

-- --- 12. The income loop: AFTER the bases exist, because the
---     collector Touched connections are taken here.
IncomeService.Start()
```

### Per-player join order

```lua
Players.PlayerAdded:Connect(function(player)
    if not PlayerService.LoadPlayerData(player) then
        player:Kick('Failed to load data. Please try again.')
        return
    end

    local base = BaseService.AssignBaseForPlayer(player.UserId)
    if not base then
        PlayerService.CleanupPlayer(player.UserId)
        player:Kick('No base available.')
        return
    end
    PlayerService.AssignBase(player.UserId, base.id)
    BaseService.PointPlayerToBaseSpawn(player, base)

    -- Re-occupy persisted animals/eggs so the slots exist.
    local profileData = PlayerService.GetPlayerData(player.UserId)
    if profileData then
        BaseService.RestorePlayerBase(player.UserId, profileData)
    end

    -- Offline earnings BEFORE the state push, so the client never
    -- sees a pool that omits the offline window.
    IncomeService.ApplyOfflineEarnings(player)

    PlayerService.MarkLoaded(player.UserId)
    PlayerService.PushState(player, BaseService.Snapshot(player.UserId))
end)
```

### Per-player leave order

```lua
Players.PlayerRemoving:Connect(function(player)
    IncomeService.ForgetPlayer(player.UserId)
    ModifierService.ForgetPlayer(player.UserId)
    PlayerService.CleanupPlayer(player.UserId)
end)
```

---

## 5. Studio assets to author

| Asset | Where | Needed by |
|---|---|---|
| A stand with a **cash collector part** | On each base's slot: a `BasePart` the player can touch | `IncomeService` — this IS the collection trigger. Without it, nothing can be collected. |
| A `SurfaceGui` with an `Amount` **TextLabel** on that part | `collector.SurfaceGui.Amount` | The on-part pool display. Optional — a missing chain warns once and the attribute still publishes. |
| A money icon `ImageLabel` | `ReplicatedStorage/Assets/Decals/MoneyIcon` | The `CashCollected` burst icon. Optional — the client falls back. |
| Animal models on the stands | Your animal templates | `SellService.PreviewSell` (the viewport). Optional — the sale works without a model; the preview renders text-only. |
| A sell-confirmation GUI | `StarterGui.Main.SellConfirmation` | The two-step sale. The `Sell` prompt alone does nothing without it. |

Set the collector part's name to whatever you like — the service finds
it through the slot record's `cashCollector` field, not by name. The
`CashPool` **attribute** name, however, is hardcoded.

---

## 6. Smoke test

Do these in order in a Studio test server (with a second client for
the touch test).

**A. The wallet responds.**

1. Join. The HUD shows `$5,000` (the `StartingMoney` seed).
2. Run a Cmdr command that grants money (`/givecash` or your own
   `EconomyService.AddMoney(userId, '100', 'AdminGive')` call).
3. The HUD updates **without** a rejoin. If it does not, `EconomyService.SetBaseService`
   was not called (or was called after the first mutation).

**B. A debit is atomic.**

1. Call `EconomyService.TrySpendMoney(userId, '99999999', 'AdminGive')`.
2. It returns `{ Success = false, Code = 'insufficient' }` and the
   balance is **unchanged**.
3. Call it with a cost you can afford — the balance drops by exactly
   that amount.

**C. Income accumulates.**

1. Place an animal on a stand.
2. Wait ~2 seconds.
3. The stand's amount label shows a growing number.
4. Check the part's `CashPool` attribute in the Studio command bar —
   it matches the label.

**D. Collection transfers.**

1. Walk your character onto the cash collector.
2. The HUD jumps by the pool amount and the label returns to `$0`.
3. Touch it again immediately — **nothing** happens (the debounce).
4. Wait a second and touch it again — still nothing (the pool is
   empty). It should be **silent**; no toast is expected.

**E. Offline earnings.**

1. Join, note the money, leave the server.
2. Wait a few minutes.
3. Rejoin — the stand's pool should be larger than the amount you
   collected, and the money should jump accordingly on the next touch.
4. Rejoin a second time: the offline window must **not** pay twice.
   (It is consumed exactly once via `ConsumeOfflineTimestamp`.)

**F. Selling (if installed).**

1. Touch the `Sell` prompt on an animal → the confirmation GUI opens
   with a price.
2. Click Sell → the money jumps, the animal disappears, the slot
   empties, and a success toast appears.
3. Sell the same animal again (stale confirm) → it fails cleanly with
   no money movement.

**G. The cap.**

1. Temporarily set `Money.MaxMoney = '100'` in the config.
2. Grant `'5000'`. The balance shows `$100`, and the result carries
   `Code = 'cap-exceeded'`. Restore the value afterwards.

---

## 7. Running the tests

The four spec files need Roblox Studio — there is no headless Luau
runner in this project.

1. Copy `Systems/Economy/Tests/*.spec.lua` into your test tree.
2. Copy `ReusableSystems/Tests/_Helpers.lua` alongside them (the specs
   `require(script.Parent._Helpers)`).
3. Wire a TestEZ runner; see `ReusableSystems/Tests/README.md`.
4. Run in Studio with **two** clients if you want the touch path
   (the specs test `TryCollect` directly instead).

The specs need **no DataStore, no published place, and no Robux**.

---

## 8. Trimming the system

You do not have to ship all four services.

| You want | Keep | Drop |
|---|---|---|
| A flat wallet with admin grants | `EconomyService` | `IncomeService`, `ModifierService`, `SellService` |
| Passive income on animals | `EconomyService` + `IncomeService` | `SellService` |
| Selling animals | All four | — |
| Multipliers (events, rebirth bonuses) | `EconomyService` + `ModifierService` | — |

If you drop `IncomeService`, you lose the `CashPool` concept, the
claim locks, the settlement handler, and the sale/collect race
protection. If you keep selling, keep `IncomeService`: `SellService`
**requires** `IncomeService.ConsumePoolForSale` to guarantee the pool
pays exactly once.
