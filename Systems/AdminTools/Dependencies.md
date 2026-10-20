# AdminTools — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged
when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Admin/AdminConfig.lua`

None. It is a pure data module. (It `assert`s the rank order at load.)

### `ServerScriptService/Admin/AdminService.lua`

```lua
local AdminConfig = require(script.Parent.AdminConfig)
```

### `ServerScriptService/Admin/AdminArgs.lua`

All at load time, all from `ReplicatedStorage`:

```lua
require(ReplicatedStorage.Config.Creatures.Animals)     -- Get(defId), .Catalog
require(ReplicatedStorage.Config.Creatures.Eggs)        -- .Price
require(ReplicatedStorage.Config.Creatures.Traits)       -- Get(id), .Catalog
require(ReplicatedStorage.Config.Creatures.Mutations)    -- Get(id), .Catalog
require(ReplicatedStorage.Config.Creatures.Rarity)       -- .Order
require(ReplicatedStorage.Config.Creatures.Progression)  -- .MaxLevel
require(ReplicatedStorage.Config.Economy.Gear)           -- FindGear, GetAll
require(ReplicatedStorage.Config.Economy.Rewards)        -- .Codes
require(ReplicatedStorage.Config.Economy.Rebirth)        -- MaxConfigured()
require(ReplicatedStorage.Config.World.Arena)            -- MaxLevel()
```

`ArenaConfig.MaxLevel()` and `RebirthConfig.MaxConfigured()` are called
**inside a `pcall`** at resolve time, with hard fallbacks of **50** and
**3** respectively.

### `ServerScriptService/Admin/AdminTargetResolver.lua`

```lua
local Players = game:GetService('Players')
```

Nothing else. It reads the live player list.

### `ServerScriptService/Admin/AdminRateLimit.lua`

```lua
local Security = require(game:GetService('ReplicatedStorage').Config.Systems.Security)
```

**Snapshotted at module load** into three locals. Runtime edits to
`Security.Admin` have no effect.

### `ServerScriptService/Admin/AdminAudit.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `ServerScriptService/Admin/AdminNotify.lua`

```lua
local BigNumber        = require(ReplicatedStorage.Utility.BigNumber)
local RichTextFormatter = require(ReplicatedStorage.Utility.RichTextFormatter)
local RarityConfig     = require(ReplicatedStorage.Config.Creatures.Rarity)
local PlayerService    = require(ServerScriptService.PlayerService)
```

### `ServerScriptService/Admin/AdminDelivery.lua`

```lua
local Players = game:GetService('Players')
local ServerScriptService = game:GetService('ServerScriptService')

local PlayerService = require(ServerScriptService.PlayerService)
local BaseService   = require(ServerScriptService.BaseService)
```

Lazy, `pcall`-guarded, resolved on first use:

```lua
require(ServerScriptService.Base.SlotService)      -- GetFreeSlot, ReserveSlot, ReleaseSlot
require(ServerScriptService.Codes.CodesService)    -- QueuePendingReward
require(ServerScriptService.EggService)            -- SpawnFromPersistence
require(ServerScriptService.AnimalService)         -- SpawnFromPersistence
```

**`CodesService` is required even though only `QueuePendingReward` is
used.** Without it, `GiveEgg`/`GiveAnimal` return
`{failed=true, error='delivery services unavailable'}`.

### `ServerScriptService/Cmdr/Server/CmdrBootstrap.luau`

```lua
local RunService = game:GetService('RunService')
local ServerScriptService = game:GetService('ServerScriptService')

local Packages = ServerScriptService:WaitForChild('Packages')
local Cmdr = require(Packages:WaitForChild('Cmdr'))

local CommandsFolder = script.Parent:WaitForChild('Commands')
local TypesFolder    = script.Parent:WaitForChild('Types')
```

### `ServerScriptService/Cmdr/Server/Types/*.lua` (8 modules)

All of them:

```lua
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local TypeUtil = require(ReplicatedStorage.Utility.CmdrTypeUtil)
```

Plus the per-type source of truth:

| Type | Extra require |
|---|---|
| `adminTarget` | `game:GetService('Players')` |
| `animalDef` | `ReplicatedStorage.Config.Creatures.Animals` |
| `arenaOption` | — (a hard-coded `{ 'Buy1', 'Buy2', 'Buy3' }`) |
| `codeId` | `ReplicatedStorage.Config.Economy.Rewards` (`.Codes`) |
| `eggRarity` | `ReplicatedStorage.Config.Creatures.Eggs` + `.Rarity` |
| `gearId` | `ReplicatedStorage.Config.Economy.Gear` |
| `mutationList` | `ReplicatedStorage.Config.Creatures.Mutations` |
| `traitId` | `ReplicatedStorage.Config.Creatures.Traits` |

### `ServerScriptService/Cmdr/Server/Commands/*.lua`

The 68 **definition** files require **nothing** — they return a plain
table.

The 68 **Run** files (`*Server.lua`) require the `Admin/*` modules plus
the game services they drive. The full set, with the number of command
files that use each:

| Roblox path | Used by | Optional? |
|---|---|---|
| `ServerScriptService.Admin.AdminService` | **68** (all) | **Required.** |
| `ServerScriptService.Admin.AdminRateLimit` | 45 | Required for those 45 only. |
| `ServerScriptService.Admin.AdminAudit` | 45 | Required for those 45 only. |
| `ServerScriptService.Admin.AdminTargetResolver` | 40 | Required for those 40 only. |
| `ServerScriptService.Admin.AdminNotify` | 27 | Required for those 27 only. |
| `ServerScriptService.Admin.AdminArgs` | 7 | Required for those 7 only. |
| `ServerScriptService.Admin.AdminDelivery` | 2 | Required for those 2 only. |
| `ServerScriptService.Admin.AdminConfig` | 3 | Required for those 3 only. |
| `ServerScriptService.BaseService` | 20 | Required for those 20 only. |
| `ServerScriptService.PlayerService` | 17 | Required for those 17 only. |
| `ServerScriptService.EconomyService` | 7 | Required for those 7 only. |
| `ServerScriptService.AnimalService` | 7 | Required for those 7 only. |
| `ServerScriptService.Rebirth.RebirthService` | 6 | Required for those 6 only. |
| `ServerScriptService.Carry.CarryRegistry` | 5 | Required for those 5 only. |
| `ServerScriptService.Arena.ArenaService` | 5 | Required for those 5 only. |
| `ServerScriptService.Steal.StealService` | 4 | Required for those 4 only. |
| `ServerScriptService.Arena.ArenaProgressionService` | 4 | Required for those 4 only. |
| `ServerScriptService.EggService` | 3 | Required for those 3 only. |
| `ServerScriptService.Egg.SpawnService` | 3 | Required for those 3 only. |
| `ServerScriptService.Base.BaseLockService` | 3 | Required for those 3 only. |
| `ServerScriptService.Playtime.PlaytimeRewardsService` | 2 | Required for those 2 only. |
| `ServerScriptService.ModifierService` | 2 | Required for those 2 only. |
| `ServerScriptService.GearShop.GearShopService` | 2 | Required for those 2 only. |
| `ServerScriptService.Daily.DailyRewardsService` | 2 | Required for those 2 only. |
| `ServerScriptService.Combat.RagdollService` | 2 | Required for those 2 only. |
| `ServerScriptService.Codes.CodesService` | 2 | Required for those 2 only. |
| `ServerScriptService.Base.SlotService` | 2 | Required for those 2 only. |
| `ServerScriptService.TraitService` | 1 | Required for that 1 only. |
| `ServerScriptService.StandPresentation` | 1 | Required for that 1 only. |
| `ServerScriptService.ServerLuckService` | 1 | Required for that 1 only. |
| `ServerScriptService.SellService` | 1 | Required for that 1 only. |
| `ServerScriptService.MutationService` | 1 | Required for that 1 only. |
| `ServerScriptService.Event.EventService` | 1 | Required for that 1 only. |
| `ServerScriptService.Egg.Catalog` | 1 | Required for that 1 only. |
| `ServerScriptService.Base.DynamicSlotService` | 1 | Required for that 1 only. |
| `ServerScriptService.Animal.AnimalOverhead` | 1 | Required for that 1 only. |
| `ReplicatedStorage.Utility.Debug` | 20 | Required for those 20 only. |
| `ReplicatedStorage.Utility.BigNumber` | 6 | Required for those 6 only. |
| `ReplicatedStorage.Utility.Validation` | 5 | Required for those 5 only. |
| `ReplicatedStorage.Utility.RichTextFormatter` | 3 | Required for those 3 only. |
| `ReplicatedStorage.Types.TransactionReason` | 6 | Required for those 6 only. |
| `ReplicatedStorage.Types.RarityType` | 2 | Required for those 2 only. |
| `ReplicatedStorage.Types.SlotType` | 2 | Required for those 2 only. |
| `ReplicatedStorage.Config.Creatures.Progression` | 3 | Required for those 3 only. |
| `ReplicatedStorage.Config.Creatures.Animals` | 2 | Required for those 2 only. |
| `ReplicatedStorage.Config.Creatures.Eggs` | 1 | Required for that 1 only. |
| `ReplicatedStorage.Config.Economy.Gear` | 2 | Required for those 2 only. |
| `ReplicatedStorage.Config.Economy.Rewards` | 1 | Required for that 1 only. |
| `ReplicatedStorage.Config.Economy.Money` | 1 | Required for that 1 only. |

**Every one of these requires is INSIDE the `Run` function**, not at
module load. That is deliberate: a missing service makes that one
command fail at invocation time, and it does **not** break the
bootstrap or the other 67 commands.

The three exceptions — `/setlevel`, `/slowmode`, `/speed` — require
their config/utilities at **module load** (`Progression`, `Debug`).

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **Cmdr** (Wally) | `ServerScriptService.Packages.Cmdr` | The command framework. Version **1.12.0** exactly. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.CmdrTypeUtil` | `FuzzyFilter` / `ExactMatch` / `BestMatch` / `Trimmed` — used by all 8 custom types. | **Required** at type-registration time. |
| **SharedUtilities** | `ReplicatedStorage.Utility.Debug` | Every trace line (`AdminAudit`, and 20 command files). | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.BigNumber` | `AdminNotify.FormatMoney` and 6 command files. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.RichTextFormatter` | `AdminNotify.Escape` and 3 command files. | **Required.** |
| **SharedUtilities** | `ReplicatedStorage.Utility.Validation` | 5 command files. | Required for those 5. |
| **SharedUtilities** | `ReplicatedStorage.Types.TransactionReason` | 6 command files. | Required for those 6. |
| **SharedUtilities** | `ReplicatedStorage.Types.RarityType` | 2 command files (`/setlevel` and one other). | Required for those 2. |
| **SharedUtilities** | `ReplicatedStorage.Types.SlotType` | 2 command files. | Required for those 2. |
| **PlayerData** | `ServerScriptService.PlayerService` | `GetPlayerData`, `AddEgg`, `AddAnimal`, `RemoveEgg`, `RemoveAnimal`, `PushState`, `Notify`. | **Required** for the notify and delivery paths. |
| **BasesAndSlots** | `ServerScriptService.BaseService` | `Snapshot(userId)` — the state pushed after a grant. | Required for the delivery path. |
| **BasesAndSlots** | `ServerScriptService.Base.SlotService` | `GetFreeSlot`, `ReserveSlot`, `ReleaseSlot`. | **Required** for the delivery path. |
| **BasesAndSlots** | `ServerScriptService.Base.BaseLockService` | `/lockbase`, `/unlockbase`. | Required for those 2 commands. |
| **BasesAndSlots** | `ServerScriptService.Base.DynamicSlotService` | 1 command. | Required for that 1. |
| **Codes** | `ServerScriptService.Codes.CodesService` | `QueuePendingReward` (from `AdminDelivery`) and the redeem path. | **Required** for the delivery path. |
| **Economy** | `ServerScriptService.EconomyService` | Money read/write for 7 commands. | Required for those 7. |
| **EggsAndHatching** | `ServerScriptService.EggService` | `SpawnFromPersistence`. | Required for `/giveegg` and `/spawnegg`. |
| **EggsAndHatching** | `ServerScriptService.Egg.SpawnService` | The center-egg registry (`/eggstatus`, `/listcentereggs`, `/killcenteregg`). | Required for those 3. |
| **EggsAndHatching** | `ServerScriptService.Egg.Catalog` | 1 command. | Required for that 1. |
| **Animals** | `ServerScriptService.AnimalService` | `SpawnFromPersistence`, `GetStats`. | Required for the delivery path and `/getstats`. |
| **Animals** | `ServerScriptService.Animal.AnimalOverhead` | 1 command. | Required for that 1. |
| **MutationsAndTraits** | `ServerScriptService.MutationService` | 1 command. | Required for that 1. |
| **MutationsAndTraits** | `ServerScriptService.TraitService` | 1 command. | Required for that 1. |
| **Arena** | `ServerScriptService.Arena.ArenaService` | `CancelArena`, expedition start, 5 commands. | Required for those 5. |
| **Arena** | `ServerScriptService.Arena.ArenaProgressionService` | Stage clears and arena XP, 4 commands. | Required for those 4. |
| **Rebirth** | `ServerScriptService.Rebirth.RebirthService` | `RequestRebirth`, rebirth info, 6 commands. | Required for those 6. |
| **Stealing** | `ServerScriptService.Steal.StealService` | `RollbackCarried` and the carry report. | Required for those 4. |
| **Carry** | `ServerScriptService.Carry.CarryRegistry` | The carry report source of truth. | Required for those 5. |
| **DailyRewards** | `ServerScriptService.Daily.DailyRewardsService` | `Claim` and the daily report. | Required for those 2. |
| **PlaytimeRewards** | `ServerScriptService.Playtime.PlaytimeRewardsService` | The playtime milestone claim and report. | Required for those 2. |
| **ModifierService** | `ServerScriptService.ModifierService` | `AddModifier` / `RemoveModifier` for the admin money multiplier. | Required for those 2. |
| **GearShop** | `ServerScriptService.GearShop.GearShopService` | `EnsureGearTool` — the canonical grant path for gear. | Required for those 2. |
| **Combat** | `ServerScriptService.Combat.RagdollService` | `/ragdoll`, `/unragdoll`. | Required for those 2. |
| **Events** | `ServerScriptService.Event.EventService` | `/event status\|start\|stop`. | Required for that 1. |
| **Sell** | `ServerScriptService.SellService` | The canonical sale price for `/sellanimal`. | Required for that 1. |
| **StandPresentation** | `ServerScriptService.StandPresentation` | `/standinfo`. | Required for that 1. |
| **EggLuck** | `ServerScriptService.ServerLuckService` | `/luck`. | Required for that 1. |

### Systems that call *into* this one

None. The admin framework is a **leaf consumer** — it calls the game,
the game never calls it. The only inbound path is Cmdr's own
RemoteFunction from the client console.

---

## Remotes

The admin system defines **no remotes of its own**.

| Remote | Direction | Payload | Notes |
|---|---|---|---|
| `ReplicatedStorage.CmdrClient.CmdrFunction` | Client → Server | Cmdr's own command envelope | Created by Cmdr's `Initialize.lua`. The client console fires it; the server dispatcher runs the `Run`. |
| `ReplicatedStorage.CmdrClient.CmdrEvent` | Server → Client | Cmdr's own event envelope | Created by Cmdr's `Initialize.lua`. |
| `PlayerService.Notify`'s remote | Server → Client | `{ Category = 'Admin', Text = string }` | **Not owned by this system.** `AdminNotify.Tell` calls `PlayerService.Notify(player, 'Admin', text)` — the same toast channel every gameplay system uses. The category is `'Admin'` so the client can style it differently. |

`Remotes.Names` is **not** consulted by the admin framework — it goes
through `PlayerService.Notify` rather than `Remotes.FireClient`
directly.

### The Cmdr replication contract

Cmdr's `Initialize.lua` does `ReplicatedRoot.Parent = ReplicatedStorage`,
where `ReplicatedRoot` is `script.Parent.CmdrClient`. So:

- `ReplicatedStorage.CmdrClient` **does not exist** until the server has
  required Cmdr.
- The client bootstrap must wait for it:
  `require(ReplicatedStorage:WaitForChild('CmdrClient'))`.
- The default Cmdr activation key is **F2**.

---

## Profile Fields Read / Written

The admin commands **never touch `ProfileService` directly**. Every read
and write goes through `PlayerService`.

### Read

| Field | Read by | Used for |
|---|---|---|
| `profile.Data.Money` | `EconomyService.GetMoney` | `/getplayerstats`, `/givecash`, `/setcash`, `/resetcash`, `/givemoney`, `/setmoney`, `/takecash`. |
| `profile.Data.Brainrots` | `AdminDelivery` (`_idSet` / `_findNew`), `/listanimals`, `/getstats` | The animal records. Each row has `Id` and `SlotId`. |
| `profile.Data.LuckyBlocks` | `AdminDelivery` (`_idSet` / `_findNew`), `/listcentereggs` | The egg records. Each row has `Id` and `SlotId`. |
| `profile.Data.BaseId` | `BaseService.Snapshot` | `/baseinfo`, `/tptobase`. |
| `profile.Data.Arena` (level / XP / wins) | `ArenaProgressionService` | `/arenainfo`, `/givearenawin`, `/givearenaxp`. |
| `profile.Data.Rebirth` (index / progress) | `RebirthService` | `/rebirthinfo`, `/forcerebirth`. |
| `profile.Data.Daily` (streak) | `DailyRewardsService` | `/dailyinfo`, `/dailyclaim`. |
| `profile.Data.Playtime` (minutes, milestones) | `PlaytimeRewardsService` | `/playtimeinfo`, `/playtimeclaim`. |
| `profile.Data.Gear` (owned tool ids) | `GearShopService` | `/listgear`, `/givegear`, `/giveallgear`. |
| `profile.Data.Codes` (redeemed) | `CodesService` | `/redeemcode`, `/codeinfo`, `/deliverpending`. |
| `profile.Data.PendingRewards` | `CodesService.QueuePendingReward` | `/deliverpending` and the `AdminDelivery` queue path. |

**The exact profile key names are the game's, not this system's.** The
admin code reads them through the game services, so the profile schema
can change without touching the admin framework — as long as the
services keep their signatures.

### Write

| Write | Mechanism |
|---|---|
| Money add / set / take / reset | `EconomyService` |
| Animal add / remove | `PlayerService.AddAnimal` / `RemoveAnimal` |
| Egg add / remove | `PlayerService.AddEgg` / `RemoveEgg` |
| Animal level | `AnimalService` |
| Animal XP | `AnimalService` |
| Arena stage / XP | `ArenaProgressionService` |
| Rebirth | `RebirthService.RequestRebirth` — the **full canonical transaction** |
| Daily claim | `DailyRewardsService.Claim` |
| Playtime milestone | `PlaytimeRewardsService` |
| Gear tool | `GearShopService.EnsureGearTool` |
| Code redemption | `CodesService` |
| Money multiplier | `ModifierService.AddModifier` / `RemoveModifier` (source `'AdminOverride'`) |
| **Full data wipe** | `BaseService.WipePlayerData(userId)` + `BaseService.AssignBaseForPlayer(userId)` + `PlayerService.AssignBase(userId, baseId)` — via `/wipeplayer` and `/resetplayer` |
| Pending reward | `CodesService.QueuePendingReward(data, { Code = 'ADMIN', ... })` |

---

## Required Studio Assets

**None.**

The admin framework touches no `Workspace` hierarchy and needs no
authored instances. The commands that *appear* to need world geometry
(`/spawnegg` at "the center", `/tptobase` to a player's base) resolve it
through the game's own services (`EggService.RegisterCenter`,
`BaseService.RegisterBases`), which are initialised by the game
bootstrap, not by this system.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `HttpService` | **Not used.** | — |
| `DataStoreService` | **Not used directly** — the admin code goes through `PlayerService`, which owns the store. The **allowlist is in-memory only** and dies with the server. | — |
| `MessagingService` | **Not used.** There is no cross-server fan-out. | — |
| `MarketplaceService` | **Not used.** | — |
| `HttpService:RequestAsync` | **Not used.** (The PlayerLogging system owns the Discord webhook; there is no webhook here.) | — |

**No credentials, no API keys, no webhook URLs, no endpoints of any kind
appear anywhere in this system.** The only environment-specific data is
the allowlist, which is empty in this library copy.

---

## Initialization Order

```text
1. Wally: install Cmdr 1.12.0
     -> ServerScriptService.Packages.Cmdr
2. Shared modules in place:
     ReplicatedStorage.Utility.CmdrTypeUtil
     ReplicatedStorage.Utility.Debug
     ReplicatedStorage.Utility.BigNumber
     ReplicatedStorage.Utility.RichTextFormatter
     ReplicatedStorage.Utility.Validation
     ReplicatedStorage.Types.{TransactionReason, RarityType, SlotType}
     ReplicatedStorage.Config.Systems.Security
3. Canonical game configs in place:
     ReplicatedStorage.Config.Creatures.{Animals, Eggs, Traits, Mutations,
                                          Rarity, Progression}
     ReplicatedStorage.Config.Economy.{Gear, Rewards, Rebirth, Money}
     ReplicatedStorage.Config.World.Arena
4. ServerScriptService.Admin.*   (8 modules)
     -> AdminArgs requires the 10 config modules at load time
     -> AdminRateLimit snapshots Security.Admin at load time
     -> AdminNotify requires PlayerService at load time
5. ServerScriptService.Cmdr.Server.Types.*   (8 modules)
6. ServerScriptService.Cmdr.Server.Commands.* (136 modules)
7. Game services wired (PlayerService.Init, BaseService.RegisterBases,
   EggService.RegisterCenter, ArenaService, RebirthService, ...)
8. In bootstrap.server.lua:
     require(script.Parent.Cmdr.Server.CmdrBootstrap)
     -> registers the built-ins, the BeforeRun hook, the types, the commands
     -> Cmdr's Initialize.lua creates ReplicatedStorage.CmdrClient
9. On the client (StarterPlayerScripts/bootstrap.client.lua):
     local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))
```

### Why the order matters

- **Step 4 before step 8.** The command `Run` functions require the
  `Admin/*` modules lazily, but the `Types` modules require
  `CmdrTypeUtil` and the configs at load.
- **Step 7 before step 8** is *strongly* recommended. The `Run`
  functions resolve their game services lazily on first use, so an
  early registration is not fatal — it just means the first command of
  a session resolves a cold cache. But the game bootstrap normally
  registers the world (bases, center) and that must exist before any
  command that touches the world.
- **Step 8 before step 9.** Cmdr's `Initialize.lua` is what moves
  `CmdrClient` into `ReplicatedStorage`. Until the server has required
  Cmdr, `ReplicatedStorage.CmdrClient` does not exist and the client
  bootstrap blocks on that `WaitForChild` forever.

---

## Require-cycle notes

The admin framework requires only **leaf** modules:

- `AdminConfig` → nothing.
- `AdminService` → `AdminConfig`.
- `AdminArgs` → 10 config modules (leaves).
- `AdminTargetResolver` → nothing but `Players`.
- `AdminRateLimit` → `Security` (a leaf).
- `AdminAudit` → `Debug` (a leaf).
- `AdminNotify` → `BigNumber`, `RichTextFormatter`, `Rarity`, and
  **`PlayerService`**.
- `AdminDelivery` → `PlayerService`, `BaseService`, and (lazily)
  `SlotService`, `CodesService`, `EggService`, `AnimalService`.

`AdminNotify` and `AdminDelivery` both require `PlayerService` **at
module load**. `PlayerService` must not require any `Admin/*` module —
it does not.

The command `Run` functions require their game services **inside the
function body**, so a game service that (directly or indirectly)
requires a command module cannot form a cycle at load time. They also
mean a missing service fails at invocation rather than at boot.

**Cmdr's own re-parenting** (`RegisterTypesIn` and `RegisterCommand`
set `object.Parent = ReplicatedRoot`) means the source ModuleScripts
**move** to `ReplicatedStorage.CmdrClient` after registration. The
`*Server.lua` halves stay where they are.
