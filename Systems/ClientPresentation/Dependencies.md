# ClientPresentation — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged when
you copy the tree to the same place.

---

## Module Requires

### `bootstrap.client.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
Debug.SyncFromDebugConfig(DebugConfig)

local HUDController = require(script.Parent.HUDController)
local ToastController = require(script.Parent.ToastController)
local HudNotificationController = require(script.Parent.HudNotificationController)
local PromptOwnerFilter = require(script.Parent.PromptOwnerFilter)
local GearShopController = require(script.Parent.GearShopController)
local ArenaController = require(script.Parent.ArenaController)
local SellConfirmController = require(script.Parent.SellConfirmController)
local ArenaResultController = require(script.Parent.ArenaResultController)
local ArenaCameraImpacts = require(script.Parent.ArenaCameraImpacts)
local ArenaHitPresentation = require(script.Parent.ArenaHitPresentation)
local ResetProtectionController = require(script.Parent.ResetProtectionController)
local CodesController = require(script.Parent.CodesController)
local SlotMenuController = require(script.Parent.SlotMenuController)
local MoneyPoolController = require(script.Parent.MoneyPoolController)
local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))
-- ... ShopController, DailyRewardsController, PlaytimeRewardsController,
-- RebirthController, EggTimerController, EventController,
-- EventTransitionController, ServerLuckController, TutorialController,
-- UiSoundController, SettingsController, StealPresentationController,
-- ToolLockController, BatController (all script.Parent.*)
```

### `HUDController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local UIConfig = require(ReplicatedStorage.Config.Presentation.UI)
local Bases = require(ReplicatedStorage.Config.World.Bases)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
```

### `ToastController.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local HUDController = require(script.Parent.HUDController)
local HudNotificationController = require(script.Parent.HudNotificationController)
```

### `HudNotificationController.lua`

```lua
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local NotificationConfig = require(game:GetService('ReplicatedStorage').Config.Presentation.UI).Notify
local HudTree = require(script.Parent.HudTree)
```

### `HudTree.lua`

No requires. Pure path resolver over `PlayerGui`.

### `MenuPresentation.lua`

```lua
local ShopAnimations = require(ReplicatedStorage.ShopAnimations)
local UiSoundController = require(script.Parent.UiSoundController)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

> `ReplicatedStorage.ShopAnimations` is a **third-party module** (a Roblox
> menu-animation library) and is **not included in this library**.

### `UiSoundController.lua`

```lua
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)
local Debug = require(ReplicatedStorage.Utility.Debug)
```

### `PromptOwnerFilter.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
```

### `GearShopController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local GearConfig = require(ReplicatedStorage.Config.Economy.Gear)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local MenuPresentation = require(script.Parent.MenuPresentation)
```

### `ArenaController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local NumberUtils = require(ReplicatedStorage.Utility.NumberUtils)
local ArenaUIState = require(ReplicatedStorage.Utility.ArenaUIState)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
```

### `ArenaResultController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local Arena = require(ReplicatedStorage.Config.World.Arena)
local ArenaUIState = require(ReplicatedStorage.Utility.ArenaUIState)
local MenuPresentation = require(script.Parent.MenuPresentation)
local AnimalViewport = require(ReplicatedStorage.Utility.AnimalViewport)
```

### `ArenaCameraImpacts.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
```

### `ArenaHitPresentation.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local ArenaPresentationConfig = require(ReplicatedStorage.Config.World.ArenaFeel)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)
```

### `ResetProtectionController.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
```

### `CodesController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
```

### `CodesTopbar.client.lua` / `DailyTopbar.client.lua` / `PlaytimeTopbar.client.lua` / `SettingsTopbar.client.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- at runtime, once TopbarPlus is found:
local Icon: any = require(topbarMod)   -- topbarMod = ReplicatedStorage.Packages.TopbarPlus.Icon
```

> `ReplicatedStorage.Packages.TopbarPlus` is a **Wally package** and is
> **not included in this library**.

### `DailyRewardsController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local NotificationConfig = require(ReplicatedStorage.Config.Presentation.UI).Notify
local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)
-- at runtime, once TopbarPlus is found:
topbarModule = require(mod)
```

### `PlaytimeRewardsController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local NotificationConfig = require(ReplicatedStorage.Config.Presentation.UI).Notify
local ShopConfig = require(ReplicatedStorage.Config.Economy.Shop)
-- at runtime, once TopbarPlus is found:
topbarModule = require(mod)
```

### `EggTimerController.lua`

```lua
local EggConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Eggs)
local RarityConfig = require(game:GetService('ReplicatedStorage').Config.Creatures.Rarity)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local CenterPartBillboards = require(game:GetService('ReplicatedStorage').Utility.CenterPartBillboards)
```

### `EventController.lua`

```lua
local EventConfig = require(ReplicatedStorage.Config.World.Events)
local Debug = require(ReplicatedStorage.Utility.Debug)
local CenterPartBillboards = require(ReplicatedStorage.Utility.CenterPartBillboards)
```

### `EventTransitionController.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local EventConfig = require(ReplicatedStorage.Config.World.Events)
```

### `MoneyPoolController.lua`

```lua
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local BaseConfig = require(game:GetService('ReplicatedStorage').Config.World.Bases)
local BigNumber = require(game:GetService('ReplicatedStorage').Utility.BigNumber)
local HudTree = require(script.Parent.HudTree)
```

### `RebirthController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)
local AnimalShowcase = require(ReplicatedStorage.Utility.AnimalShowcase)
local StandShowcase = require(ReplicatedStorage.Utility.StandShowcase)
local RebirthUnlocks = require(ReplicatedStorage.Utility.RebirthUnlocks)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
```

### `SellConfirmController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local MenuPresentation = require(script.Parent.MenuPresentation)
local BigNumber = require(ReplicatedStorage.Utility.BigNumber)
local TraitConfig = require(ReplicatedStorage.Config.Creatures.Traits)
local AnimalShowcase = require(ReplicatedStorage.Utility.AnimalShowcase)
local AnimalViewport = require(ReplicatedStorage.Utility.AnimalViewport)
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local SellConfig = require(ReplicatedStorage.Config.Economy.Sell)
```

### `ServerLuckController.lua`

```lua
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local HudTree = require(script.Parent.HudTree)
```

### `SettingsController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local MenuPresentation = require(script.Parent.MenuPresentation)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)
```

### `ShopController.lua`

```lua
local Debug = require(game:GetService('ReplicatedStorage').Utility.Debug)
local ShopConfig = require(game:GetService('ReplicatedStorage').Config.Economy.Shop)
local Remotes = require(game:GetService('ReplicatedStorage').Utility.Remotes)
local HudTree = require(script.Parent.HudTree)
local MenuPresentation = require(script.Parent.MenuPresentation)
-- lazily, to avoid a circular require at load time:
local ToastController = require(script.Parent.ToastController)
```

### `SlotMenuController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local AudioGroups = require(ReplicatedStorage.Utility.AudioGroups)
```

### `StealPresentationController.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local SlotType = require(ReplicatedStorage.Types.SlotType)
local StealConfig = require(ReplicatedStorage.Config.World.Stealing)
```

### `ToolLockController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
```

### `TutorialController.lua`

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
local StandResolver = require(ReplicatedStorage.Utility.StandResolver)
local HudTree = require(script.Parent.HudTree)
local EggConfig = require(ReplicatedStorage.Config.Creatures.Eggs)
local RarityDefs = require(ReplicatedStorage.Config.Creatures.Rarity)
```

### `BatController.lua`

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BatConfig = require(ReplicatedStorage.Config.Economy.Gear).Combat
```

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **Remotes** (`ReplicatedStorage.Utility.Remotes`) | Every remote channel. The client is a pure subscriber/requester. | **Required.** Without it the client cannot start. |
| **Debug** (`ReplicatedStorage.Utility.Debug`) | Client debug gating. `bootstrap.client.lua` calls `Debug.SyncFromDebugConfig` before any `Init`. | Required (the module is required unconditionally). |
| **AudioGroups** (`ReplicatedStorage.Utility.AudioGroups`) | Resolves the `SoundService → GameSound → BgmSound` hierarchy for the UI/music sliders and arena hit sounds. | Required by `UiSoundController`, `SettingsController`, `ArenaHitPresentation`, `SlotMenuController`. |
| **BigNumber** (`ReplicatedStorage.Utility.BigNumber`) | Money is a decimal string. The client formats but never computes value. | Required wherever money is displayed. |
| **NumberUtils** (`ReplicatedStorage.Utility.NumberUtils`) | Number formatting used by `ArenaController`. | Required by `ArenaController` only. |
| **ArenaUIState** (`ReplicatedStorage.Utility.ArenaUIState`) | Shared arena-menu state (what the arena panel is showing). | Required by `ArenaController`, `ArenaResultController`. |
| **AnimalViewport** (`ReplicatedStorage.Utility.AnimalViewport`) | Clone-and-fit a 3D animal into a `ViewportFrame`. | Required by `SellConfirmController`, `ArenaResultController`. |
| **AnimalShowcase** (`ReplicatedStorage.Utility.AnimalShowcase`) | Showcase camera for a 3D animal. | Required by `SellConfirmController`, `RebirthController`. |
| **StandShowcase** (`ReplicatedStorage.Utility.StandShowcase`) | Showcase camera for a stand / base model. | Required by `RebirthController` only. |
| **StandResolver** (`ReplicatedStorage.Utility.StandResolver`) | Finds the runtime `UpgradeButton` across flat runtime clones, nested authored stands and legacy shapes. | Required by `SlotMenuController`, `TutorialController`. |
| **CenterPartBillboards** (`ReplicatedStorage.Utility.CenterPartBillboards`) | The `Map.CenterPart.BillboardGui` countdown labels. | Required by `EggTimerController`, `EventController`. |
| **RebirthUnlocks** (`ReplicatedStorage.Utility.RebirthUnlocks`) | The unlock list for the rebirth panel. | Required by `RebirthController` only. |
| **Types.SlotType** (`ReplicatedStorage.Types.SlotType`) | Slot kind enum. | Required by `StealPresentationController` only. |
| **ShopAnimations** (`ReplicatedStorage.ShopAnimations`) | The `Open(frame, 'Pop')` / `Close(frame)` menu animation. | Required by `MenuPresentation` — i.e. by nearly everything. **Third-party; not in this library.** |
| **TopbarPlus** (`ReplicatedStorage.Packages.TopbarPlus`) | Fast-boot topbar icons. | Required by the four `*Topbar.client.lua` scripts. **Wally package; not in this library.** |
| **CmdrClient** (`ReplicatedStorage.CmdrClient`) | Admin command client. | Required by `bootstrap.client.lua` — it does `WaitForChild('CmdrClient')` (blocking). **Not in this library.** |

---

## Remotes

All remotes live in the `Remotes` folder, created by the server at boot from
the `Remotes.Names` registry — see `../../Shared/CommonModules/Remotes.lua`.
**Do not hand-author them.**

Direction: **C→S** = the client fires, the server resolves. **S→C** = the
server pushes, the client paints. **B** = broadcast to every client.

| Remote | Direction | Payload | Fired by |
|---|---|---|---|
| `PlayerState` | S→C | `{Money (BigNumber string), BaseId, Slots[] {Id, State, OccupantKind, OccupantId}, CarriedKind, CarriedName, CarriedSteal}` | Server. Read by `HUDController`, `MoneyPoolController`, `PromptOwnerFilter`, `RebirthController`, `SellConfirmController`, `SettingsController`, `SlotMenuController`, `StealPresentationController`. |
| `Notify` | S→C | `{Category, Text}` | Server. Read by `ToastController`. |
| `EggArrived` | S→C | `{SlotId, Rarity}` | Server. Read by `ToastController`. |
| `AnimalArrived` | S→C | `{SlotId, DisplayName, Rarity}` | Server. Read by `ToastController`. |
| `AnimalCarried` | S→C | `{UniqueId, DefinitionId, DisplayName, Rarity}` | Server. Read by `ToastController` — **handler is a no-op** (wire only). |
| `AnimalPlaced` | S→C | `{UniqueId, SlotId}` | Server. Read by `ToastController` — **handler is a no-op**. |
| `EggCarried` | S→C | `{BaseId, SlotId, Rarity}` | Server. Read by `ToastController` — **handler is a no-op**. |
| `EggPlaced` | S→C | `{BaseId, SlotId, Rarity}` | Server. Read by `ToastController` — **handler is a no-op**. |
| `AnimalLeveledUp` | S→C | `{AnimalId, SlotId, OldLevel, NewLevel, LevelsGained}` | Server. Read by `SlotMenuController`. |
| `SlotMenuRequest` | C→S | `{SlotId, Intent}` | `SlotMenuController`. |
| `SlotMenuState` | S→C | menu snapshot, or `{Valid=false}` | Server. |
| `SlotMenuAction` | C→S | `{SlotId, OccupantId, Action='Upgrade'}` | `SlotMenuController`. |
| `SlotMenuResult` | S→C | `{SlotId, Success, Error?}` | Server. |
| `SellPreviewState` | S→C | `{Valid, AnimalId, Name, Rarity, Trait?, Level, LevelText, GenerationText, Mutations, SellValueRaw?, Model?}` | Server. |
| `SellConfirmAction` | C→S | `{AnimalId}` | `SellConfirmController`. |
| `SellConfirmResult` | S→C | `{AnimalId, Success, Error?}` | Server. |
| `CashCollected` | S→C | `{Amount (string), NewMoney? (string), Icon? (table), Origin? {x,y,z}}` | Server. Read by `MoneyPoolController`. |
| `ResetProtection` | S→C | `{Protected, Reason?}` | Server (on change). Read by `ResetProtectionController`. |
| `GearShopAction` | C→S | `{Action='Purchase'\|'Equip'\|'SetAutoBuy', GearId, Enabled?}` | `GearShopController`. |
| `GearShopState` | S→C | `{Money, MoneyText, Rebirth, Gears[] {Id, Name, Description, Price, PriceText, RequiredRebirth, ToolName, Locked, Owned, AutoBuy}}` | Server. |
| `GearShopResult` | S→C | `{Action, GearId, Success, Error?}` | Server. |
| `ArenaAction` | C→S | `{Action='Start', Option='Buy1'\|'Buy2'\|'Buy3'}` | `ArenaController`. |
| `ArenaState` | S→C | `{Progression, Levels, Session?, Loadout?, LastRaid?, Dialogue, Show?}` | Server. Read by `ArenaController`, `SettingsController`. |
| `ArenaResult` | S→C | `{Action, Success, Error?, SessionId?, RaidComplete?, Outcome?, Stage?, MaxStage?, EarnedCash?, EarnedXP?, Animals?[], Eggs?[]}` | Server. Read by `ArenaResultController`, `ArenaController`, `SettingsController`. |
| `RebirthAction` | C→S | `{Action='Rebirth'\|'State'}` | `RebirthController`. |
| `RebirthState` | S→C | `{Current, Next?, Maxed, Money, MoneyRequired, MoneySatisfied, ArenaLevel, ArenaRequired, ArenaSatisfied, Animals[], Unlocks[], StartingCash, MoneyMultiplier, CanRebirth}` | Server. |
| `RebirthResult` | S→C | `{Success, Rebirth?, Error?}` | Server. |
| `ArenaCombatEvent` | S→C (B) | `{SessionId, StageGeneration?, Event='CombatStarted'\|'CombatantSpawned'\|'Attack'\|'CombatantDied'\|'Victory'\|'Defeat'\|'ArenaHit', ...}` | Server. Read by `ArenaCameraImpacts`, `ArenaController`, `ArenaHitPresentation`. |
| `EventTransition` | S→C (B) | `Prepare{Phase='Prepare', Kind, EventId, TransitionId, FovMultiplier, FovSeconds, FlashDelaySeconds, FlashInSeconds, FadeOutSeconds, CoverSeconds}` / `Reveal{Phase='Reveal', Kind, EventId, TransitionId}` | Server. Read by `EventTransitionController`. |
| `BatSwing` | C→S | *(no payload)* | `BatController`. |
| `CarryLock` | S→C | `{Locked}` | Server (on change). Read by `ToolLockController`. |
| `TutorialAction` | C→S | `{Action='State'\|'Continue'\|'Skip'}` | `TutorialController`. |
| `TutorialState` | S→C | `{Step, EggId?, AnimalId?, SlotId?, BaseId?}` | Server. |
| `CodesAction` | C→S | `{Action='Redeem', Code}` | `CodesController`. |
| `CodesResult` | S→C | `{Success, Reason?, Message?, RewardText?}` | Server. |
| `DailyRewardsAction` | C→S | `{Action='State'\|'Claim', Day?}` | `DailyRewardsController`. |
| `DailyRewardsState` | S→C | `{Day, ClaimableDay?, CanClaim, NextClaimAt, LastClaimAt, DayCount, Days[] {Day, Rewards}}` | Server. |
| `DailyRewardsResult` | S→C | `{Success, Reason?, Message?, Day?, RewardText?}` | Server. |
| `PlaytimeRewardsAction` | C→S | `{Action='State'\|'Claim', Index?}` | `PlaytimeRewardsController`. |
| `PlaytimeRewardsState` | S→C | `{PoolId, DayId, Playtime, Completed, Version, Rewards[] {Index, RequiredPlaytime, State, Cash?, Eggs?, Tools?, Animals?}}` | Server. |
| `PlaytimeRewardsResult` | S→C | `{Success, Reason?, Message?, Index?, RewardText?, State?}` | Server. |
| `SaveSettings` | C→S | `{Bgm?, Sfx?, FastMode?}` | `SettingsController` (debounced). |
| `SettingsState` | S→C | `{Bgm, Sfx, FastMode}` | Server. |
| `ShopAction` | C→S | `{Action='SyncGamepass'}` or `{Action='FunnelPrompt', GamepassId?/ProductId?}` | `ShopController`, `DailyRewardsController`, `PlaytimeRewardsController`. |
| `ShopResult` | S→C | `{Action, Success, Owned?}` | Server. **Not subscribed by any client script** — `ShopController` only fires `ShopAction`; purchase feedback travels on `Notify`. |

### Attributes read instead of remotes

| Where | Attribute | Read by |
|---|---|---|
| `ReplicatedStorage` | `ServerLuck` | `ServerLuckController` |
| `ReplicatedStorage` | `Event_CurrentId`, `Event_EndAt`, `Event_NextId`, `Event_NextAt`, `Event_Revision` | `EventController` |
| `Map.CenterPart.BillboardGui.Egg` | `Guarantee_<Rarity>_NextAt`, `Guarantee_<Rarity>_Interval`, `Guarantee_<Rarity>_Revision` | `EggTimerController` |
| `ProximityPrompt` | `ownerUserId`, `targetUserId`, `stealPrompt`, `doorPrompt`, `purchaserUserId` | `PromptOwnerFilter` |
| Stand button | `slotId`, `maxed` | `SlotMenuController`, `TutorialController` |
| Gear row | `GearId`, `OwnedState`, `AutoBuyState` | `GearShopController` |
| Button wiring guards | `ShopBuyWired`, `ShopToggleWired`, `ShopCloseWired`, `UiSoundWired`, `ShopSkipWired` | `ShopController`, `UiSoundController`, rewards controllers |
| `CollectionService` | `TutorialTarget_<userId>` | `TutorialController` |

---

## Initialization Order

```text
0.  (each LocalScript in StarterPlayerScripts gets its own thread)
    SettingsTopbar.client / CodesTopbar.client / DailyTopbar.client /
    PlaytimeTopbar.client  ->  wait for PlayerGui.Main.<Panel> and
                               ReplicatedStorage.Packages.TopbarPlus,
                               then bind their icon. NOT in the bootstrap.

1.  bootstrap.client.lua runs:
      require(Remotes)
      require(Debug)
      require(Config.Systems.Debug)
      Debug.SyncFromDebugConfig(DebugConfig)      -- MUST be before any Init
      require(all 28 controllers)                  -- module bodies only
      require(ReplicatedStorage:WaitForChild('CmdrClient'))   -- BLOCKING
      Remotes.WaitForReady()                      -- BLOCKING, 10s
2.  Init() is then called on the controllers, in this order:
      1.  HUDController
      2.  MoneyPoolController
      3.  GearShopController
      4.  ShopController
      5.  ArenaController
      6.  CodesController
      7.  DailyRewardsController
      8.  PlaytimeRewardsController
      9.  SellConfirmController
      10. ArenaResultController
      11. RebirthController
      12. EggTimerController
      13. EventController
      14. EventTransitionController
      15. ServerLuckController
      16. TutorialController
      17. ArenaCameraImpacts
      18. ArenaHitPresentation
      19. HudNotificationController
      20. ToastController
      21. UiSoundController
      22. SettingsController
      23. SlotMenuController      <-- the ONLY blocking Init (~15s)
      24. PromptOwnerFilter
      25. ResetProtectionController
      26. StealPresentationController
      27. ToolLockController
      28. BatController
3.  print('[bootstrap.client] Client initialised, awaiting server state.')
```

**Invariant:** `SlotMenuController` is the only controller that blocks. Anything
that must be live immediately (HUD, money pool, notifications) is initialised
**before** it. A new controller that blocks must be appended after
`SlotMenuController`, or must be made non-blocking.

---

## Studio Assets

The client reads a large, specific set of Studio-authored content. **This is
the critical reuse surface** — a new game must author all of it, or the
corresponding feature is inert.

### `PlayerGui` — the HUD

```text
PlayerGui
└── HUD
    ├── BottomLeft
    │   ├── MoneyCounter            (TextLabel, or a container with a `Text` TextLabel)
    │   └── ServerLuckCounter       (TextLabel, or a container with a `Text` TextLabel)
    ├── Left
    │   ├── RebirthButton           (GuiButton)
    │   └── ShopButton              (GuiButton)
    ├── Top
    │   └── Tutorial
    │       ├── Counter             (TextLabel, "3/10")
    │       └── Steps               (TextLabel, the instruction line)
    ├── Center
    │   └── Notifications           (GuiObject — THE notification target; PLURAL)
    ├── Bottom
    │   └── WaveCounter
    │       └── Counter             (TextLabel)
    └── TutorialSkip                (GuiButton)
```

Legacy flat fallbacks also accepted: `HUD.MoneyCounter`,
`HUD.ServerLuckCounter`, `HUD.ServerLuck`, `HUD.RebirthButton`,
`HUD.ShopButton`, `HUD.TutorialSteps`, `HUD.Tutorial`,
`HUD.Center.Notification` (singular), `HUD.Notifications`, `HUD.WaveCounter`.

Tutorial checklist: `HUD.TutorialSteps` → `Steps` → `Step1` (the row template;
`Step2`…`Step10` are clones) and `HUD.TutorialSteps` → `Title`. The row may
carry an indicator child named `Circle` / `Bullet` / `Check` / `Icon` /
`Marker` / `Dot` / `Indicator` / `State` and a strike child named `Strike` /
`Strikethrough` / `StrikeThrough` / `Line` / `Bar`. If neither exists the
client prefixes the text with `✓ ` / `○ ` and draws a `TutorialStrikeLine`
frame itself.

### `PlayerGui` — panels

```text
PlayerGui
├── Main
│   ├── Settings
│   │   ├── TopBar/CloseButton       (GuiButton)
│   │   └── ScrollingFrame
│   │       ├── BackgroundMusic
│   │       │   └── Container
│   │       │       ├── Bar          (GuiObject; fill = X.Scale of its Size)
│   │       │       └── Button       (GuiButton; the slider knob)
│   │       ├── GameSound
│   │       │   └── Container
│   │       │       ├── Bar
│   │       │       └── Button
│   │       └── FastMode
│   │           └── Button           (GuiButton)
│   │               └── Text         (TextLabel, "ON"/"OFF")
│   ├── Codes
│   │   ├── TopBar/CloseButton
│   │   ├── CurrentLevel             (TextBox)
│   │   └── Continue                 (TextButton, submit)
│   ├── DailyRewards
│   │   ├── TopBar/CloseButton
│   │   ├── Items1                   (children GuiButtons named "1".."6")
│   │   │   └── each: Day, Name, LockedOverlay
│   │   ├── Items2                   (contains the featured/last-day GuiButton)
│   │   ├── Text                     (TextLabel, status)
│   │   └── Skip                     (GuiButton, paid Skip All)
│   ├── PlayTimeRewards
│   │   ├── TopBar/CloseButton
│   │   ├── Items                    (children GuiButtons named "1".."6")
│   │   │   └── each: Timer → Text
│   │   ├── Text                     (TextLabel, status)
│   │   └── Skip                     (GuiButton)
│   ├── Shop
│   │   ├── TopBar/CloseButton
│   │   └── ScrollingFrame
│   ├── Arena
│   │   ├── Buy1 / Buy2 / Buy3        (GuiButton, each with a .TextLabel)
│   │   ├── WarmupLevel/Title        (TextLabel)
│   │   ├── LastLevel/Title          (TextLabel)
│   │   └── CloseButton
│   ├── ArenaResult
│   │   ├── Name                     (TextLabel)
│   │   ├── AnimalList
│   │   │   └── <N>
│   │   │       ├── Title, Rarity, Level, XP   (TextLabels)
│   │   │       ├── CurrentLevel/Title         (TextLabel)
│   │   │       ├── NewLevel/Title             (TextLabel)
│   │   │       └── Item/ViewportFrame
│   │   └── RightSide
│   │       ├── WaveCounter/Wave     (TextLabel)
│   │       ├── Money                (TextLabel)
│   │       ├── Eggs
│   │       │   └── ScrollingFrame
│   │       │       └── Template     (+ Counter, ViewportFrame)
│   │       ├── NoEggs               (TextLabel)
│   │       └── Continue             (GuiButton)
│   ├── SellConfirmation
│   │   ├── Sell                     (TextButton, with a .TextLabel)
│   │   ├── Cancle                   (TextButton)  <-- AUTHORED TYPO, verbatim
│   │   ├── Name, Level, Generation, Mutations   (TextLabels)
│   │   ├── RarityBox
│   │   │   ├── Title                (TextLabel)
│   │   │   └── Gradient             (UIGradient, named "Gradient")
│   │   └── Item/ViewportFrame
│   └── Rebirth
│       ├── TopBar
│       │   ├── Title                (TextLabel)
│       │   └── CloseButton          (GuiButton)
│       ├── Button                   (GuiButton, the Rebirth action)
│       └── Contents
│           ├── Warning              (TextLabel)
│           ├── Requirements
│           │   ├── Items/Template   (hidden; cloned per requirement)
│           │   │   ├── Name, Number  (TextLabels)
│           │   │   ├── ImageLabel
│           │   │   └── ViewportFrame
│           │   └── Bars
│           │       ├── Money
│           │       │   ├── ProgressBar   (GuiObject; fill = X.Scale)
│           │       │   └── Text          (TextLabel)
│           │       └── ArenaLVL
│           │           ├── ProgressBar
│           │           └── Text
│           └── UnlockItems/Template (hidden; cloned per unlock)
│               ├── Name, Number      (TextLabels)
│               ├── ImageLabel
│               └── ViewportFrame
├── GearShop
│   └── ScrollingFrame
│       └── GearTemplate             (hidden; cloned per gear)
│           ├── Name, Description     (TextLabels)
│           ├── Button                (GuiButton, with a TextLabel)
│           ├── AutoBuy               (GuiButton)
│           │   ├── AutoBuyImage
│           │   ├── Toggle_ON
│           │   └── Toggle_OFF
│           ├── LockOverlay
│           │   └── RebirthCount
│           └── ViewportFrame
└── MainGui                          (LEGACY slot-menu root; `Main` also accepted)
    ├── UpgradesFrame
    │   ├── Title, Name, CurrentLevel, NewLevel
    │   ├── UpgradeButton            (with a TextLabel)
    │   └── CloseMenu
    └── SellFrame
        ├── Title, Name, Level, Gen
        ├── SellButton               (with a TextLabel)
        └── CloseMenu
```

### `Workspace`

```text
Workspace
├── Map
│   ├── Bases
│   │   └── <baseId>
│   │       ├── AnimalStands
│   │       │   └── Slot<k>  (or Stand<k> in authored bases)
│   │       │       └── Slot
│   │       │           └── MenuPart
│   │       │               └── MenuGui        (SurfaceGui)
│   │       │                   └── UpgradeButton
│   │       ├── ArenaAnimalStands
│   │       │   └── ArenaStand<k>
│   │       ├── Adventurer  (alias: Adv)
│   │       └── LazerButton
│   │           └── PressPart
│   ├── Shop
│   │   └── PromptPart
│   │       └── ProximityPrompt
│   ├── CenterPart
│   │   └── BillboardGui
│   │       ├── Egg                  (countdown label + guarantee attributes)
│   │       └── Event                (countdown label)
│   └── EggTimer                     (LEGACY)
│       └── BillboardGui/Frame
├── ArenaVFX                         (client-local folder the client creates)
├── ArenaBattles                     (the replicated combat models)
├── EggArea
│   └── ActiveEggs                   (DIRECT Model children only)
│       └── each egg: BuyPrompt / PickupPrompt / HatchPrompt (ProximityPrompt)
└── Bgm / ArenaBgm                   (optional; SoundService is searched first)
```

### `ReplicatedStorage`

```text
ReplicatedStorage
├── Remotes                          (the folder; created by the server)
├── Utility/                         (Remotes, Debug, AudioGroups, BigNumber,
│                                    NumberUtils, AnimalShowcase, AnimalViewport,
│                                    StandShowcase, StandResolver, ArenaUIState,
│                                    CenterPartBillboards, RebirthUnlocks)
├── Config/...                       (see the require list above)
├── Types/SlotType.lua
├── Packages/TopbarPlus              (Wally package, NOT in this library)
├── ShopAnimations                   (third-party, NOT in this library)
├── CmdrClient                       (NOT in this library)
├── Assets
│   ├── Sfx                           (UiHover, UiClick, UiOpen, Pop, Approved,
│   │                                  LevelUp, Stealing, ...)
│   ├── Vfx/HitVfx/Attack1           (the arena hit VFX template)
│   └── Arena/Sfx/Attack1..3         (the arena hit sounds)
├── GearShopPreviews/<gearId>        (the ONLY gear visual source)
├── RebirthPreviews                  (the parked stand/animal template clones)
├── ArenaResultModels/Session_<id>   (the captured combat-model clones)
├── TutorialBeamTemplate             (asset 17476697388; contains a Beam)
├── ServerLuck                       (attribute)
└── Event_CurrentId / Event_EndAt / Event_NextId / Event_NextAt / Event_Revision (attributes)
```

### `SoundService` — the audio hierarchy

```text
SoundService
└── GameSound            (SoundGroup — the master)
    └── BgmSound         (SoundGroup — the BackgroundMusic slider)
        ├── Bgm          (Sound, Looped)
        └── ArenaBgm     (Sound, Looped)
```

Individual `Sound.Volume` stays authored. The sliders drive the **group**
masters: effective music volume = `GameSound` × `BgmSound` × `Sound`.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `MarketplaceService` | Gamepass / product purchase flows (`ShopController`, `DailyRewardsController`, `PlaytimeRewardsController` Skip buttons). | Normal Roblox purchase flow. No API key needed. |
| `ContentProvider:PreloadAsync` | Preloading the arena hit VFX + SFX so the first hit sounds identical to the tenth (`ArenaHitPresentation`). | — |
| `Lighting` | `Lighting.MenuDimBlur` (BlurEffect) — the menu blur. The client creates it if absent. | — |
| `UserInputService` | The settings slider drags. | — |
| `ContextActionService` / `ProximityPrompt` | Prompt visibility filtering (`PromptOwnerFilter`) reads prompt attributes; it does not bind input. | — |
| `CollectionService` | The tutorial's per-player target tag. | — |

**No HTTP. No webhooks. No tokens. No credentials.** The client layer
authenticates nothing and stores nothing locally.

`CmdrClient` is an admin command client; it is required but the client layer
never sends admin commands itself.
