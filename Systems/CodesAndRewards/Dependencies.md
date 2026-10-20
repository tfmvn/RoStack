# CodesAndRewards — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

---

## Module Requires

### `ReplicatedStorage/Config/Economy/Rewards.lua`

```lua
require(script.Parent.Parent.Creatures.Eggs)
require(script.Parent.Gear)
require(script.Parent.Parent.Creatures.Animals)
require(script.Parent.Parent.Creatures.Traits)
require(script.Parent.Parent.Parent.Utility.BigNumber)
```

Engine services: none.

### `ServerScriptService/Codes/CodesService.lua`

```lua
require(ReplicatedStorage.Config.Economy.Rewards).Codes
require(ReplicatedStorage.Config.Creatures.Animals)
require(ReplicatedStorage.Config.Creatures.Eggs)
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.Debug)
require(ServerScriptService.Base.NotificationService)
require(ServerScriptService.Utility.MoneyIcon)
require(ServerScriptService.FunnelService)
```

Plus a **lazy** require inside the tool-grant path:

```lua
require(ReplicatedStorage.Config.Economy.Gear)   -- for the tool display name
```

Engine services used: `ReplicatedStorage`, `ServerScriptService`,
`Players` (via `game:GetService('Players')` inside `TryDeliverPending`).

### `ServerScriptService/Daily/DailyRewardsService.lua`

```lua
require(ReplicatedStorage.Config.Economy.Rewards).Daily
require(script.Parent.DailyRewardsWeek)          -- <-- in THIS system folder
require(ReplicatedStorage.Config.Economy.Gear)
require(ReplicatedStorage.Config.Creatures.Animals)
require(ReplicatedStorage.Config.Economy.Rewards).Codes
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.Debug)
require(ServerScriptService.Base.NotificationService)
require(ServerScriptService.Utility.MoneyIcon)
require(ServerScriptService.FunnelService)
```

Engine services used: `Players`, `ReplicatedStorage`, `ServerScriptService`.

> `require(script.Parent.DailyRewardsWeek)` resolves to
> `ServerScriptService.Daily.DailyRewardsWeek`, which **is** in this
> system's `Source/` tree at
> `Source/ServerScriptService/Daily/DailyRewardsWeek.lua`. Because the
> require goes through `script.Parent`, the file must stay a **direct
> child** of `ServerScriptService/Daily/` — moving it elsewhere breaks
> the require.

### `ServerScriptService/Daily/DailyRewardsWeek.lua`

```lua
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local DataStoreService = game:GetService('DataStoreService')

local DailyRewardsConfig = require(ReplicatedStorage.Config.Economy.Rewards).Daily
local Debug = require(ReplicatedStorage.Utility.Debug)
```

Engine services used: `ReplicatedStorage`, `DataStoreService`.

That is the entire require list. Two modules, one of which is a
sub-module of the other.

### `ServerScriptService/Playtime/PlaytimeRewardsService.lua`

```lua
require(ReplicatedStorage.Config.Economy.Rewards).Playtime
require(script.Parent.PlaytimeRewardsDay)
require(ReplicatedStorage.Config.Economy.Gear)
require(ReplicatedStorage.Config.Creatures.Animals)
require(ReplicatedStorage.Config.Economy.Rewards).Codes
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.Debug)
require(ServerScriptService.Base.NotificationService)
require(ServerScriptService.Utility.MoneyIcon)
require(ServerScriptService.FunnelService)
```

Engine services used: `Players`, `ReplicatedStorage`, `ServerScriptService`.

### `ServerScriptService/Playtime/PlaytimeRewardsDay.lua`

```lua
require(ReplicatedStorage.Config.Economy.Rewards).Playtime
require(ReplicatedStorage.Utility.Debug)
```

Engine services used: `ReplicatedStorage`, `DataStoreService`.

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **PlayerData** (`PlayerService`) | `GetPlayerData(userId)` — the profile slice (`RedeemedCodes`, `PendingCodeRewards`, `DailyRewards`, `PlaytimeRewards`), plus `AddEgg` / `AddAnimal` / `RemoveEgg` / `RemoveAnimal` for slot-bound delivery. | **Required.** Without it every claim returns `no-systems`. |
| **Economy** (`EconomyService`) | `GetMoney(userId)` and `AddMoney(userId, amount, 'CodeReward', {ApplyMultiplier=false})`. | **Required.** Cash rewards cannot be granted without it. |
| **Slots** (`SlotService`) | `GetFreeSlot(userId)` and `ReserveSlot(slotId)` / `ReleaseSlot(slotId)`. | **Required for any egg/animal reward.** Without it, slot-bound rewards are always queued. |
| **Eggs** (`EggService`) | `SpawnFromPersistence(userId, record, slot)` — the spawn path that rejoin reconstruction also uses. | **Required for any egg reward.** |
| **Animals** (`AnimalService`) | `SpawnFromPersistence(userId, record, slot)`. | **Required for any animal reward.** |
| **Gear / Shop** (`GearShopService`) | `EnsureGearTool(player, gearId)` — idempotent tool grant. | **Required for any tool reward.** |
| **Notifications** (`NotificationService`) | `GetWarningText(id, data)`, `NotifySuccess(player, id, data)`, `NotifyWarning(player, id, data)`. Every player-facing message and SFX. | **Required** for the message/SFX channel (the services degrade to a message-less result if it is absent). |
| **SharedUtilities** (`MoneyIcon`) | `MoneyIcon.Resolve()` — the icon in the `CashCollected` burst. | Optional (cosmetic — the burst still fires, just without an icon). |
| **SharedUtilities** (`BigNumber`) | `sanitize`, `Format`, `IsZero`. | **Required.** |
| **Analytics** (`FunnelService`) | `LogStep(player, 'Rewards', ...)` for successful redemptions and claims. | **Optional** — it is a leaf module and is always `pcall`-wrapped, so a failure never affects a grant. |

`DailyRewardsWeek` is **not** in this table — it lives in **this** system
(`Source/ServerScriptService/Daily/DailyRewardsWeek.lua`) and is a
required, in-system dependency of `DailyRewardsService`.

### The internal dependency that surprises people

`DailyRewardsService` and `PlaytimeRewardsService` both inject
**`CodesService`** and call its delivery API. There is **one** egg/animal
inventory and **one** pending queue, owned by `CodesService`:

```lua
codesServiceRef.DeliverEggReward(userId, data, label, rarity)
codesServiceRef.DeliverAnimalReward(userId, data, label, defId, trait, level)
codesServiceRef.QueuePendingReward(data, entry)
```

Do not build a second delivery path.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `CodesAction` | C→S | `{ Action = 'Redeem', Code = string }` — the **only** client input to the code system. Any reward/cash/egg/tool field on the payload is ignored. `Code` must be a string of at most 64 characters. |
| `CodesResult` | S→C | `{ Success: boolean, Reason?: string, Message?: string, RewardText?: string }` — per-request outcome for **UI state only** (clear the TextBox on success, restore Continue). Player-facing text + SFX travel on `Notify`, never here. |
| `DailyRewardsAction` | C→S | `{ Action = 'State' \| 'Claim' \| 'ClaimAll', Day?: number }` — `Day` is UX/debug only and is never authoritative. |
| `DailyRewardsState` | S→C | `{ WeekId, PoolId, Day, ClaimableDay?, CanClaim, NextClaimAt, LastClaimAt, DayCount, Days: [{ Day, State, Cash?, Eggs?, Tools?, Animals? }] }` |
| `DailyRewardsResult` | S→C | `{ Success, Reason?, Message?, Day?, RewardText? }` |
| `PlaytimeRewardsAction` | C→S | `{ Action = 'State' \| 'Claim' \| 'ClaimAll', Index?: number }` — `Index` is validated but never authoritative. |
| `PlaytimeRewardsState` | S→C | `{ PoolId, DayId, Playtime, SessionStart, Completed, ClaimedCount, Version, Rewards: [{ Index, RequiredPlaytime, State, Remaining, Cash?, Eggs?, Tools?, Animals? }] }` |
| `PlaytimeRewardsResult` | S→C | `{ Success, Reason?, Message?, Index?, RewardText?, State? }` |
| `CashCollected` | S→C | `{ Amount = string, NewMoney = string, Icon = table? }` — fired on every non-zero cash grant, so the client's money-pool burst and count-up play. Raw BigNumber strings, never formatted; no world `Origin` (same as arena rewards). |
| `Notify` | S→C | `{ Category, Text }` — the one toast channel. `NotificationService` owns it. |

The remotes are created at boot from the `Remotes.Names` registry — see
`Shared/CommonModules/Remotes.lua`. Do not hand-author them.

**`DailyRewardsWeek` fires no remote, listens to no remote, and has no
remote handler.** It is entirely server-side and communicates only by its
return value. The consumer (`DailyRewardsService`) is what talks to the
client, over `DailyRewardsAction` / `DailyRewardsState` /
`DailyRewardsResult` — the same pattern as `PlaytimeRewardsDay`, which
likewise has no remotes of its own.

### Notification ids used

| Id | Used by | Channel |
|---|---|---|
| `Codes_InvalidCode` | `CodesService` | warning |
| `Codes_CodeDisabled` | `CodesService` | warning |
| `Codes_CodeExpired` | `CodesService` | warning |
| `Codes_AlreadyRedeemed` | `CodesService` | warning |
| `Codes_Success` | `CodesService` | success |
| `Codes_PendingDelivered` | `CodesService` | success |
| `Daily_AlreadyClaimed` | `DailyRewardsService` | warning |
| `Daily_NotReady` | `DailyRewardsService` | warning |
| `Daily_Success` | `DailyRewardsService` | success |
| `Playtime_NotReady` | `PlaytimeRewardsService` | warning |
| `Playtime_AlreadyClaimed` | `PlaytimeRewardsService` | warning |
| `Playtime_Success` | `PlaytimeRewardsService` | success |
| `Shop_SkipRequired` | `DailyRewardsService` + `PlaytimeRewardsService` | warning |
| `General_Cooldown` | all three | warning |
| `General_Generic` | all three | warning |

The text lives in `ReplicatedStorage/Config/Presentation/Messages.lua`.

---

## Profile Fields Read / Written

| Field | Type | Read by | Written by | Meaning |
|---|---|---|---|---|
| `RedeemedCodes` | `{[string]: number}` | `CodesService` | `CodesService` | Redemption count per **normalized** code id. `data.RedeemedCodes[norm] = count`. The per-player cap is checked against this. |
| `PendingCodeRewards` | array of `{Code, Kind, Rarity\|DefId, Trait?, Level?}` | `CodesService` | `CodesService` | The FIFO queue of slot-bound rewards awaiting a free base slot. **Shared by all three systems** — Daily and Playtime push into it too. |
| `DailyRewards` | `{WeekId: string, Day: number, LastClaimAt: number}` | `DailyRewardsService` | `DailyRewardsService` | The daily streak slice. `Day` is the **NEXT** claimable day (1..7); `8` = week complete. `LastClaimAt` is unix seconds. |
| `PlaytimeRewards` | `{DayId: string, PoolId: string, Claimed: {[number]: boolean}, Completed: boolean}` | `PlaytimeRewardsService` | `PlaytimeRewardsService` | The playtime course slice. Raw playtime is **not** stored — it is derived from the live session clock. |
| `Money` | string (BigNumber) | `EconomyService` | `EconomyService` | The wallet. Cash rewards land here through `EconomyService.AddMoney`, not by a direct write. |
| `LuckyBlocks` | array of egg records | `CodesService` (diff) | `PlayerService` | Read to diff the minted record id during egg delivery. |
| `Brainrots` | array of animal records | `CodesService` (diff) | `PlayerService` | Read to diff the minted record id during animal delivery. |

**Nothing else is read or written.** The three services never touch
`Settings`, `Arena`, `Stats`, `Tutorial`, `GearAutoBuy`, or
`OwnedRobuxGear`.

**`DailyRewardsWeek` touches no profile at all.** It has no
`PlayerService` reference, no `GetPlayerData` call, and no data
dependency of any kind on a player. The consumer
(`DailyRewardsService`) reads and writes the `DailyRewards` slice.

---

## DataStore

| Store | Key | Value | Owner |
|---|---|---|---|
| `p7_PlaytimeRewards_Daily_v1` | `'CurrentDay'` | `{ DayId, PoolId, PreviousPoolId, SetAt }` | `PlaytimeRewardsDay` (`PlaytimeRewardsDay.lua:45`) |
| `p7_DailyRewards_Weekly_v1` | `'CurrentWeek'` | `{ WeekId, PoolId, PreviousPoolId, SetAt }` | `DailyRewardsWeek` (`DailyRewardsWeek.lua:49`) |

Both names are **hardcoded literals** with no environment suffix. A new game
MUST change both. The weekly store name and key are module-locals in
`DailyRewardsWeek.lua` (lines 49 and 50) — they are not configurable from
outside the file.

The selection runs inside `UpdateAsync`, which is **atomic per key**: several
servers reaching a new day (or week) simultaneously serialize, the loser
re-runs against the winner's committed value and keeps it. Exactly one pool
wins across the whole fleet.

**Fallback:** if the store is unreachable, both selectors fall back to a
**deterministic hash** of the day/week id over the pool catalog, so all
servers still agree.

---

## Initialization Order

The source game's bootstrap does this (all line numbers in
`src/ServerScriptService/bootstrap.server.lua`):

```text
1.  createRemotes()                              -- :222  (the Remotes folder
                                                   --        must exist before
                                                   --        any Init that
                                                   --        WaitForChild's on it)
2.  EconomyService.Init()                        -- :239
    EconomyService.SetPlayerService(PlayerService)
    PlayerService.Init()                          -- :242
    SlotService.Init()                            -- :248
    BaseService.Init()                            -- :250
    EggService.Init()                             -- :256
    AnimalService.Init()                          -- :262
    GearShopService.SetPlayerService/SetEconomyService/Init()   -- :487-489
    NotificationService.Init() + SetPlayerService              -- :392-393

3.  CodesService.SetPlayerService(PlayerService)          -- :541
    CodesService.SetEconomyService(EconomyService)          -- :542
    CodesService.SetSlotService(SlotService)                -- :543
    CodesService.SetEggService(EggService)                  -- :544
    CodesService.SetAnimalService(AnimalService)            -- :545
    CodesService.SetGearShopService(GearShopService)        -- :546
    CodesService.Init()                                     -- :547
        -> CodesConfig.ValidateLive()   (warn-only)
        -> connects Remotes.Names.CodesAction.OnServerEvent

4.  DailyRewardsService.SetPlayerService(PlayerService)    -- :554
    DailyRewardsService.SetEconomyService(EconomyService)    -- :555
    DailyRewardsService.SetGearShopService(GearShopService)  -- :556
    DailyRewardsService.SetCodesService(CodesService)        -- :557
    DailyRewardsService.Init()                               -- :558
        -> DailyRewardsConfig.ValidateLive()  (warn-only)
        -> connects Remotes.Names.DailyRewardsAction
        -> requires ServerScriptService.Daily.DailyRewardsWeek
             (via require(script.Parent.DailyRewardsWeek), at the top
              of DailyRewardsService.lua — NOT deferred)

5.  PlaytimeRewardsService.SetPlayerService(PlayerService)  -- :562
    PlaytimeRewardsService.SetEconomyService(EconomyService)  -- :563
    PlaytimeRewardsService.SetGearShopService(GearShopService)-- :564
    PlaytimeRewardsService.SetCodesService(CodesService)      -- :565
    PlaytimeRewardsService.Init()                             -- :566
        -> PlaytimeRewardsConfig.ValidateLive()  (warn-only)
        -> connects Remotes.Names.PlaytimeRewardsAction
```

**The `SetCodesService` call must come before `Init()`** on the Daily and
Playtime services, because their grant paths call
`codesServiceRef.DeliverEggReward` and would hit a `nil` ref otherwise.

**`CodesService.Init()` must come after `createRemotes()`** — it does
`Remotes.GetFolder():WaitForChild(Remotes.Names.CodesAction, 10)`.

**`DailyRewardsWeek` has no init order of its own.** It has no `Init()`,
no `Start()` and no setters — it is `require`d on demand and every call
is self-contained. The only requirement is a **filesystem** one: the file
must **exist** at `ServerScriptService/Daily/DailyRewardsWeek.lua`
before `DailyRewardsService` is required, because the require is at the
top of that file and is not deferred. There is no runtime handshake.

The DataStore handle is created **lazily** on the first `Current()` call
that misses the cache — there is no boot-time connection and no retry
loop.

### Runtime hooks

| Event | Call | Line |
|---|---|---|
| `Players.PlayerAdded` | `CodesService.OnPlayerReady(player)` | bootstrap `:934` — after base restore + offline earnings, before `MarkLoaded` |
| `Players.PlayerAdded` | `PlaytimeRewardsService.OnPlayerReady(player)` | bootstrap `:938` — starts the session clock + arms the threshold pushes |
| `Players.PlayerRemoving` | `CodesService.ForgetPlayer(userId)` | bootstrap `:1257` |
| `Players.PlayerRemoving` | `DailyRewardsService.ForgetPlayer(userId)` | bootstrap `:1259` |
| `Players.PlayerRemoving` | `PlaytimeRewardsService.ForgetPlayer(userId)` | bootstrap `:1263` |
| A base slot was freed | `CodesService.TryDeliverPending(userId)` | `SellService.lua:507` |
| Admin `/deliverpending` | `CodesService.TryDeliverPending(player.UserId)` | `Cmdr/Server/Commands/deliverPendingServer.lua:35` |
| Robux receipt (Skip Daily) | `DailyRewardsService.GrantSkipAccess(player)` then `ClaimAll` | `ShopService.lua:278` |
| Robux receipt (Skip Playtime) | `PlaytimeRewardsService.GrantSkipAccess(player)` then `ClaimAll` | `ShopService.lua:295` |

**There is no `DailyRewardsService.OnPlayerReady`.** The daily service has
no join hook — the streak is pulled on demand by `GetSnapshot`, and its
slot-bound rewards ride the Codes pending queue.

---

## Studio Assets

### `Workspace`

**None.** No service in this system reads the Workspace.

### `ServerStorage`

**None directly.** The egg / animal / gear assets are resolved by the
**owning** services (`EggService`, `AnimalService`, `GearShopService`),
never by the reward services.

### `StarterGui`

The three reward **panels** (Codes, Daily, Playtime) are client GUI and live
in the `ClientPresentation` system — **not** in this system. The server side
of this system needs no GUI.

`MoneyIcon.Resolve()` reads `Assets.Decals.MoneyIcon` (an `ImageLabel` with a
non-empty `Image`) from `ServerStorage` first, then `ReplicatedStorage`. If
it is missing, the `CashCollected` burst simply has no icon — it does not
break.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `DataStoreService` | `PlaytimeRewardsDay` reads/writes `p7_PlaytimeRewards_Daily_v1`. `DailyRewardsWeek` reads/writes `p7_DailyRewards_Weekly_v1`. | `Enable Studio Access to API Services` in Studio; a published place needs no toggle. |
| `Players` | `GetPlayerByUserId` (pending delivery, state pushes). | — |
| `MarketplaceService` | **Not used by this system.** The skip-all entitlement is granted by the **Shop** system's receipt handler, which calls `GrantSkipAccess`. | — |

No HTTP. No webhooks. **No API keys, tokens, or credentials of any kind.**

### Security note on the redemption codes

The redemption codes are **game content, not secrets** — but they are
environment-specific. The source game's catalog is a committed Lua table
(`Rewards.lua`) and the ids appear in server logs (the `CD` debug tag).

For a new game:

- Author your own catalog in `Rewards.lua` (or inject it from a private
  config module if the codes must not be public).
- Do **not** commit a live catalog to a public repository.
- Remember that a code printed to the log is not a secret. If you need
  secrecy, use a signed/expiring token scheme, not a plain string in a
  config file.
