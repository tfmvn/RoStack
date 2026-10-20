# ClientPresentation — Setup

How to install the client layer into a new place, in order, with nothing
guessed.

---

## 1. Copy the files

The library tree mirrors the Roblox hierarchy, so a straight copy works.

```text
ReusableSystems/Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/*.lua
  -> StarterPlayer.StarterPlayerScripts/*.lua
```

All 35 files land in the **same folder**. They reference each other with
`require(script.Parent.X)`, so they must be siblings.

| Source file | Roblox destination |
|---|---|
| `bootstrap.client.lua` | `StarterPlayer.StarterPlayerScripts.bootstrap.client` |
| `HUDController.lua` | `StarterPlayer.StarterPlayerScripts.HUDController` |
| `ToastController.lua` | `StarterPlayer.StarterPlayerScripts.ToastController` |
| `HudNotificationController.lua` | `StarterPlayer.StarterPlayerScripts.HudNotificationController` |
| `HudTree.lua` | `StarterPlayer.StarterPlayerScripts.HudTree` |
| `MenuPresentation.lua` | `StarterPlayer.StarterPlayerScripts.MenuPresentation` |
| `UiSoundController.lua` | `StarterPlayer.StarterPlayerScripts.UiSoundController` |
| `PromptOwnerFilter.lua` | `StarterPlayer.StarterPlayerScripts.PromptOwnerFilter` |
| `GearShopController.lua` | `StarterPlayer.StarterPlayerScripts.GearShopController` |
| `ArenaController.lua` | `StarterPlayer.StarterPlayerScripts.ArenaController` |
| `ArenaResultController.lua` | `StarterPlayer.StarterPlayerScripts.ArenaResultController` |
| `ArenaCameraImpacts.lua` | `StarterPlayer.StarterPlayerScripts.ArenaCameraImpacts` |
| `ArenaHitPresentation.lua` | `StarterPlayer.StarterPlayerScripts.ArenaHitPresentation` |
| `SellConfirmController.lua` | `StarterPlayer.StarterPlayerScripts.SellConfirmController` |
| `RebirthController.lua` | `StarterPlayer.StarterPlayerScripts.RebirthController` |
| `SlotMenuController.lua` | `StarterPlayer.StarterPlayerScripts.SlotMenuController` |
| `MoneyPoolController.lua` | `StarterPlayer.StarterPlayerScripts.MoneyPoolController` |
| `CodesController.lua` | `StarterPlayer.StarterPlayerScripts.CodesController` |
| `CodesTopbar.client.lua` | `StarterPlayer.StarterPlayerScripts.CodesTopbar` |
| `DailyRewardsController.lua` | `StarterPlayer.StarterPlayerScripts.DailyRewardsController` |
| `DailyTopbar.client.lua` | `StarterPlayer.StarterPlayerScripts.DailyTopbar` |
| `PlaytimeRewardsController.lua` | `StarterPlayer.StarterPlayerScripts.PlaytimeRewardsController` |
| `PlaytimeTopbar.client.lua` | `StarterPlayer.StarterPlayerScripts.PlaytimeTopbar` |
| `SettingsController.lua` | `StarterPlayer.StarterPlayerScripts.SettingsController` |
| `SettingsTopbar.client.lua` | `StarterPlayer.StarterPlayerScripts.SettingsTopbar` |
| `ShopController.lua` | `StarterPlayer.StarterPlayerScripts.ShopController` |
| `EggTimerController.lua` | `StarterPlayer.StarterPlayerScripts.EggTimerController` |
| `EventController.lua` | `StarterPlayer.StarterPlayerScripts.EventController` |
| `EventTransitionController.lua` | `StarterPlayer.StarterPlayerScripts.EventTransitionController` |
| `ServerLuckController.lua` | `StarterPlayer.StarterPlayerScripts.ServerLuckController` |
| `TutorialController.lua` | `StarterPlayer.StarterPlayerScripts.TutorialController` |
| `ResetProtectionController.lua` | `StarterPlayer.StarterPlayerScripts.ResetProtectionController` |
| `StealPresentationController.lua` | `StarterPlayer.StarterPlayerScripts.StealPresentationController` |
| `ToolLockController.lua` | `StarterPlayer.StarterPlayerScripts.ToolLockController` |
| `BatController.lua` | `StarterPlayer.StarterPlayerScripts.BatController` |

`bootstrap.client.lua` is a **LocalScript** (it has no `ModuleScript`
behaviour — it runs top to bottom on its own). Every other file except
`HudTree.lua` and `MenuPresentation.lua` is a **ModuleScript** that returns
its controller table. `HudTree.lua` and `MenuPresentation.lua` are
**ModuleScripts** too, required by their siblings.

> `bootstrap.client.lua` must be the only script in the folder that runs on
> load by itself. Everything else is a ModuleScript and is inert until
> required.

### The four `*Topbar.client.lua` scripts

These are **LocalScripts**, not ModuleScripts, and they are **not** required
by `bootstrap.client.lua`. They run in their own thread because Roblox
starts every LocalScript in `StarterPlayerScripts` independently. That is
deliberate: the icons must appear at first paint, without waiting for the
bootstrap's `Remotes.WaitForReady()`.

They each need `ReplicatedStorage.Packages.TopbarPlus` to exist. They wait
10s for it, then give up quietly.

---

## 2. Install the non-library dependencies

Three things are **not** in this library and must be installed separately:

| Dependency | What it is | Where it must live |
|---|---|---|
| `TopbarPlus` | A Wally package (Topbar icon library). | `ReplicatedStorage.Packages.TopbarPlus` (the scripts look for `ReplicatedStorage.Packages.TopbarPlus.Icon`). |
| `ShopAnimations` | A third-party menu-animation module providing `Open(frame, 'Pop')` and `Close(frame)`. | `ReplicatedStorage.ShopAnimations` (exactly — `MenuPresentation` requires it by that path). |
| `CmdrClient` | The admin command client. | `ReplicatedStorage.CmdrClient`. The server's Cmdr bootstrap moves it there. `bootstrap.client.lua` does `WaitForChild('CmdrClient')` — **this blocks the whole client boot**. |

The rest — `Remotes`, `Debug`, `AudioGroups`, `BigNumber`, `NumberUtils`,
`ArenaUIState`, `AnimalViewport`, `AnimalShowcase`, `StandShowcase`,
`StandResolver`, `CenterPartBillboards`, `RebirthUnlocks`, `Types.SlotType`
and the whole `Config` tree — are **shared library modules** under
`ReusableSystems/Shared/` and `ReusableSystems/Systems/*/`. See
`Dependencies.md` for the exact require list.

---

## 3. Wire the bootstrap

`bootstrap.client.lua` is already correct for a new game; copy it verbatim.
If you change it, keep these three rules:

1. **`Debug.SyncFromDebugConfig(DebugConfig)` must run before the first
   `Init()`.** It is on line 43, above every controller require.
2. **`Remotes.WaitForReady()` must run before the first `Init()`.** It is on
   line 100, after the requires. It is *unguarded* by design: if the
   `Remotes` folder did not replicate within 10s, the client should hard
   fail rather than silently run with no channels.
3. **Do not move a remote-subscribing controller after
   `SlotMenuController`.** `SlotMenuController.Init()` blocks ~15s waiting
   for `PlayerGui.MainGui`. Everything before it is instant; everything
   after it starts ~15s late.

### The exact structure

```lua
--!strict
--!native

local ReplicatedStorage = game:GetService('ReplicatedStorage')
local StarterGui = game:GetService('StarterGui')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local Debug = require(ReplicatedStorage.Utility.Debug)
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
Debug.SyncFromDebugConfig(DebugConfig)

-- Top-of-file requires (module bodies run here, no Init):
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

Remotes.WaitForReady()

-- Init order (28 controllers). The rest are required inline at their
-- Init site so the require order reads as the init order:
HUDController.Init()
MoneyPoolController.Init()
GearShopController.Init()
-- local ShopController = require(script.Parent.ShopController)
ShopController.Init()
ArenaController.Init()
CodesController.Init()
-- local DailyRewardsController = require(script.Parent.DailyRewardsController)
DailyRewardsController.Init()
-- local PlaytimeRewardsController = require(script.Parent.PlaytimeRewardsController)
PlaytimeRewardsController.Init()
SellConfirmController.Init()
ArenaResultController.Init()
-- local RebirthController = require(script.Parent.RebirthController)
RebirthController.Init()
-- local EggTimerController = require(script.Parent.EggTimerController)
EggTimerController.Init()
-- local EventController = require(script.Parent.EventController)
EventController.Init()
-- local EventTransitionController = require(script.Parent.EventTransitionController)
EventTransitionController.Init()
-- local ServerLuckController = require(script.Parent.ServerLuckController)
ServerLuckController.Init()
-- local TutorialController = require(script.Parent.TutorialController)
TutorialController.Init()
ArenaCameraImpacts.Init()
ArenaHitPresentation.Init()
HudNotificationController.Init()
ToastController.Init()
-- local UiSoundController = require(script.Parent.UiSoundController)
UiSoundController.Init()
-- local SettingsController = require(script.Parent.SettingsController)
SettingsController.Init()
SlotMenuController.Init()
PromptOwnerFilter.Init()
ResetProtectionController.Init()
-- local StealPresentationController = require(script.Parent.StealPresentationController)
StealPresentationController.Init()
-- local ToolLockController = require(script.Parent.ToolLockController)
ToolLockController.Init()
-- local BatController = require(script.Parent.BatController)
BatController.Init()

local _ = CmdrClient
print('[bootstrap.client] Client initialised, awaiting server state.')
```

The full commented source (with the original rationale for every ordering
decision) is in `Source/StarterPlayer/StarterPlayerScripts/bootstrap.client.lua`.
**Copy the file; do not retype it.**

### The CoreGui blockers are commented out — leave them that way

`bootstrap.client.lua` lines 102–116 contain the `SetCoreGuiEnabled`
blockers **fully commented out**, with the reasons inline:

- **Backpack must stay enabled.** Gear Shop Tools live in `Player.Backpack`
  and are equipped through the default hotbar. There is no custom hotbar
  anywhere in the project. Disabling the Backpack makes purchased Tools
  invisible and unequippable.
- **PlayerList must stay enabled.** The TAB player list is Roblox's *native*
  CoreGui, fed by server-side `player.leaderstats`. There is no custom
  player list by design.

Do not re-enable those blockers. If you need a custom hotbar or a custom
player list, build one — do not disable the native ones.

---

## 4. Author the GUIs in Studio

The client layer **does not generate its UI** (the arena raid menu is the one
exception — `ArenaController` builds its own `ScreenGui` in code). Everything
else is Studio-authored content that the client resolves by path.

The **full hierarchy is in `Dependencies.md` → Studio Assets**. It is
reproduced here as a checklist, in the order the controllers need it.

### 4.1 The HUD (needed by almost everything)

Create a `ScreenGui` named **`HUD`** in `StarterGui`.

```text
HUD
├── BottomLeft
│   ├── MoneyCounter          -- TextLabel (or a Frame with a child TextLabel named "Text")
│   └── ServerLuckCounter     -- TextLabel (or a Frame with a child TextLabel named "Text")
├── Left
│   ├── RebirthButton         -- TextButton / ImageButton
│   └── ShopButton            -- TextButton / ImageButton
├── Top
│   └── Tutorial
│       ├── Counter           -- TextLabel, e.g. "3/10"
│       └── Steps             -- TextLabel, the instruction line
├── Center
│   └── Notifications         -- a GuiObject (Frame). PLURAL. This is the notification target.
├── Bottom
│   └── WaveCounter
│       └── Counter           -- TextLabel
└── TutorialSkip              -- TextButton / ImageButton
```

**`HUD.Center.Notifications` is the single most important node.** Without it
every server notification is dropped and `ToastController` prints a loud
warning. There is no generated fallback.

### 4.2 The tutorial checklist

`HUDController` does not own the tutorial list; `TutorialController` does.

```text
HUD.TutorialSteps
├── Title      -- TextLabel
└── Steps
    └── Step1  -- the row template. Step2..Step10 are clones of it.
```

Each row may carry:
- an **indicator** child named one of `Circle`, `Bullet`, `Check`, `Icon`,
  `Marker`, `Dot`, `Indicator`, `State`;
- a **strike** child named one of `Strike`, `Strikethrough`,
  `StrikeThrough`, `Line`, `Bar`.

If neither exists, the client prefixes the row text with `✓ ` / `○ ` and
draws its own `TutorialStrikeLine` frame. The number of rows is derived from
the step table — **never hardcode a row count**.

`HUD.Top.Tutorial` (`Counter` + `Steps`) is the *instruction* line, a
different thing from the checklist.

### 4.3 The main panels

Create a `ScreenGui` named **`Main`**.

```text
Main.Settings
├── TopBar/CloseButton                 -- GuiButton
└── ScrollingFrame
    ├── BackgroundMusic
    │   └── Container
    │       ├── Bar                    -- GuiObject; the fill is X.Scale of its Size
    │       └── Button                 -- GuiButton, the slider knob
    ├── GameSound
    │   └── Container
    │       ├── Bar
    │       └── Button
    └── FastMode
        └── Button                     -- GuiButton
            └── Text                   -- TextLabel, "ON"/"OFF"

Main.Codes
├── TopBar/CloseButton
├── CurrentLevel                       -- TextBox
└── Continue                           -- TextButton, submit

Main.DailyRewards
├── TopBar/CloseButton
├── Items1                             -- children are GuiButtons named "1".."6"
│   └── each: Day (TextLabel), Name (TextLabel), LockedOverlay (GuiObject)
├── Items2                             -- contains the featured/last-day GuiButton
├── Text                               -- TextLabel, the status line
└── Skip                               -- GuiButton, the paid Skip All

Main.PlayTimeRewards
├── TopBar/CloseButton
├── Items                              -- children are GuiButtons named "1".."6"
│   └── each: Timer -> Text (TextLabel)
├── Text                               -- TextLabel, the status line
└── Skip                               -- GuiButton

Main.Shop
├── TopBar/CloseButton
└── ScrollingFrame

Main.Arena
├── Buy1 / Buy2 / Buy3                 -- GuiButton, each with a .TextLabel
├── WarmupLevel/Title                  -- TextLabel
├── LastLevel/Title                    -- TextLabel
└── CloseButton

Main.ArenaResult
├── Name                               -- TextLabel
├── AnimalList
│   └── <N>                            -- one container per row
│       ├── Title, Rarity, Level, XP   -- TextLabels
│       ├── CurrentLevel/Title         -- TextLabel
│       ├── NewLevel/Title             -- TextLabel
│       └── Item/ViewportFrame
└── RightSide
    ├── WaveCounter/Wave               -- TextLabel
    ├── Money                          -- TextLabel
    ├── Eggs
    │   └── ScrollingFrame
    │       └── Template               -- plus a Counter and a ViewportFrame
    ├── NoEggs                         -- TextLabel
    └── Continue                       -- GuiButton

Main.SellConfirmation
├── Sell                               -- TextButton, with a .TextLabel
├── Cancle                             -- TextButton  <-- SPELLED "Cancle", verbatim
├── Name, Level, Generation, Mutations -- TextLabels
├── RarityBox
│   ├── Title                          -- TextLabel
│   └── Gradient                       -- UIGradient, named exactly "Gradient"
└── Item/ViewportFrame

Main.Rebirth
├── TopBar
│   ├── Title                          -- TextLabel
│   └── CloseButton                    -- GuiButton
├── Button                             -- GuiButton, the Rebirth action
└── Contents
    ├── Warning                        -- TextLabel
    ├── Requirements
    │   ├── Items
    │   │   └── Template               -- hidden; cloned per requirement
    │   │       ├── Name, Number       -- TextLabels
    │   │       ├── ImageLabel
    │   │       └── ViewportFrame
    │   └── Bars
    │       ├── Money
    │       │   ├── ProgressBar        -- GuiObject; the fill is X.Scale
    │       │   └── Text              -- TextLabel
    │       └── ArenaLVL
    │           ├── ProgressBar
    │           └── Text
    └── UnlockItems
        └── Template                   -- hidden; cloned per unlock
            ├── Name, Number           -- TextLabels
            ├── ImageLabel
            └── ViewportFrame
```

> **The `Cancle` typo is load-bearing.** `SellConfirmController` looks the
> cancel button up by that exact string. If you "fix" it to `Cancel`
> without changing the lookup, the sell panel cannot be dismissed.

> **Templates must start hidden.** `Requirements.Items.Template` and
> `UnlockItems.Template` are the clones' source; leave them `Visible = false`
> or they render as blank cards.

### 4.4 The gear shop

```text
PlayerGui.GearShop
└── ScrollingFrame
    └── GearTemplate                   -- hidden; cloned per gear
        ├── Name, Description           -- TextLabels
        ├── Button                      -- GuiButton, with a TextLabel
        ├── AutoBuy                     -- GuiButton
        │   ├── AutoBuyImage
        │   ├── Toggle_ON
        │   └── Toggle_OFF
        ├── LockOverlay
        │   └── RebirthCount
        └── ViewportFrame
```

### 4.5 The legacy slot menu

```text
PlayerGui.MainGui                     -- "Main" is also accepted
├── UpgradesFrame
│   ├── Title, Name, CurrentLevel, NewLevel
│   ├── UpgradeButton                  -- with a TextLabel
│   └── CloseMenu
└── SellFrame
    ├── Title, Name, Level, Gen
    ├── SellButton                     -- with a TextLabel
    └── CloseMenu
```

This is the panel `SlotMenuController` owns. It is the one controller that
**blocks ~15s** waiting for it.

---

## 5. Author the World content

```text
Workspace.Map.Bases.<baseId>
├── AnimalStands
│   └── Slot<k>                        -- or Stand<k> in authored bases
│       └── Slot
│           └── MenuPart
│               └── MenuGui            -- SurfaceGui
│                   └── UpgradeButton
├── ArenaAnimalStands
│   └── ArenaStand<k>
├── Adventurer                         -- alias: Adv
└── LazerButton
    └── PressPart

Workspace.Map.Shop.PromptPart/ProximityPrompt
Workspace.Map.CenterPart/BillboardGui
├── Egg                                -- the countdown label + guarantee attributes
└── Event                              -- the countdown label
Workspace.EggArea.ActiveEggs          -- DIRECT Model children only
  └── each egg: BuyPrompt / PickupPrompt / HatchPrompt (ProximityPrompt)
Workspace.ArenaBattles                 -- the replicated combat models
```

`ArenaVFX` is a client-local folder — the client creates it. `Bgm` /
`ArenaBgm` under Workspace are optional fallbacks; `SoundService` is
searched first.

### The audio hierarchy

```text
SoundService
└── GameSound            -- SoundGroup, the master
    └── BgmSound         -- SoundGroup, the BackgroundMusic slider
        ├── Bgm          -- Sound, Looped
        └── ArenaBgm     -- Sound, Looped
```

The sliders drive the **group** masters. Individual `Sound.Volume` stays
authored. `Lighting.MenuDimBlur` (a `BlurEffect`) is created by the client
if it does not exist.

---

## 6. Mirror the replicated assets

The client cannot read `ServerStorage`. The server must mirror these into
`ReplicatedStorage` at boot:

| Asset | Why |
|---|---|
| `Assets.Sfx.*` (`UiHover`, `UiClick`, `UiOpen`, `Pop`, `Approved`, `LevelUp`, `Stealing`, …) | Personal UI sounds, cloned into the local `PlayerGui`. |
| `Assets.Vfx.HitVfx.Attack1` | The arena hit VFX template. The client clones the whole authored hierarchy. |
| `Assets.Arena.Sfx.Attack1..3` | The arena hit sounds, cycled by the server's `SoundIndex`. |
| `GearShopPreviews/<gearId>` | The **only** visual source for gear shop rows and rebirth gear cards. |
| `RebirthPreviews` | The parked stand/animal template clones for the rebirth cards. |
| `ArenaResultModels/Session_<id>` | The captured combat-model clones for the arena result rows. |
| `TutorialBeamTemplate` | The tutorial spotlight beam. If it carries no `Beam`, the client builds a white one in code. |
| `ServerLuck` (attribute) | The luck multiplier. |
| `Event_CurrentId`, `Event_EndAt`, `Event_NextId`, `Event_NextAt`, `Event_Revision` (attributes) | The event countdown. |

---

## 7. Smoke-test

Run a **local server with 2 clients** (Test → Start, 2 players) in this
order.

1. **Boot.** The client console prints
   `[bootstrap.client] Client initialised, awaiting server state.`
   If it does not, look for:
   - `Remotes` folder never replicated → the server did not create it.
   - `CmdrClient` missing → `bootstrap.client.lua` is blocked on
     `WaitForChild('CmdrClient')`.
   - a `... remote missing; ... disabled` warning → that one feature is
     off; the remote name in the message is the one to check.

2. **HUD.** Money shows a value (not `0`, not blank) and the ServerLuck
   counter shows `1.0x` or a real multiplier. A wrong money value means
   the server is not pushing `PlayerState`.

3. **Notifications.** Trigger any server notification (buy an egg). A toast
   appears in the top-centre area. If not, check `HUD.Center.Notifications`
   exists — the console will have warned that the notification was dropped.

4. **Topbar icons.** Four icons appear in the topbar: Settings, Codes,
   Daily, Playtime. Clicking one opens its panel; the topbar `CloseButton`
   closes it. If an icon is missing, check `ReplicatedStorage.Packages.TopbarPlus`.

5. **The settings panel.** Both sliders move, the music gets quieter/louder,
   `FastMode` toggles its label. Close and reopen — the values persist
   (the server stores them).

6. **The arena.** Open the arena from the Adventurer prompt, pick a buy
   option, and confirm the result panel opens and its animal rows show 3D
   models. This exercises `ArenaController`, `ArenaResultController`,
   `AnimalViewport` and `ArenaUIState` together.

7. **The sell flow.** Walk up to a placed animal, hit the Sell prompt, and
   confirm the sell panel opens with the animal's name, level, generation
   and a 3D preview, and that the **Cancle** button closes it.

8. **The money pool.** Collect cash from a base. Icons burst toward the
   money counter and the number counts up.

9. **The tutorial.** Reset the profile so the tutorial is unfinished. The
   spotlight appears on the target and the checklist rows tick off. The
   Skip button works.

10. **Two clients.** Confirm the second player's prompts are hidden for
    the first (a `ProximityPrompt` on the other player's animal) — this is
    `PromptOwnerFilter`.

11. **A steal.** Steal an animal from the other player. The thief's camera
    narrows slightly; the victim's camera does not. Dropping the animal
    restores the camera.

> **Turn on `Config.Systems.Debug.ClientDebug = true`** to get the client's
> diagnostic output. It is off by default. A bare `warn` (not `Debug.Warn`)
> is printed regardless — those are the loud failures.

---

## 8. Add a new controller correctly

1. **Create `YourController.lua`** in `StarterPlayer.StarterPlayerScripts` as
   a **ModuleScript** that returns a table with an `Init()` function. Do
   not run any work at module scope.

2. **Bind the remote, but do not block.** Follow the house pattern:

   ```lua
   local function bind()
       local folder = Remotes.GetFolder()
       local remote = folder:FindFirstChild(Remotes.Names.YourRemote)
       if remote and remote:IsA('RemoteEvent') then
           remote.OnClientEvent:Connect(handler)
       else
           warn('[YourController] YourRemote remote missing; feature disabled')
       end
   end
   ```

   A missing remote must **disable one feature**, not the whole controller
   and not throw.

3. **Resolve GUI lazily, never at `Init`.** Use the `HudTree` resolvers for
   HUD nodes, and `PlayerGui:WaitForChild` inside a `task.spawn` for panels
   — a panel that has not replicated yet must not stall the boot. See
   `ArenaResultController` / `RebirthController` for the canonical
   **UI-first, data-second** split.

4. **Send intent, never decisions.** Fire `{Action='...'}` to the server and
   paint the answer. Never compute a price, a level, a reward, an
   eligibility or an outcome on the client.

5. **Subscribe early.** If the controller must react to a push the instant
   it lands, add it **before** `SlotMenuController.Init()` in
   `bootstrap.client.lua` — and require it at the top of the file, or inline
   at its `Init` site. The house style for the newer controllers is an
   inline `local X = require(script.Parent.X)` immediately above
   `X.Init()`, so the require order reads as the init order.

6. **If the controller needs to block**, append it **after**
   `SlotMenuController.Init()` and document why. Nothing may be added
   between `SlotMenuController.Init()` and the end of the file if it must
   be instant.

7. **If it owns a topbar icon**, add a `YourTopbar.client.lua` LocalScript
   instead of putting the icon in the bootstrap. Follow the four existing
   ones exactly: wait `PlayerGui` (10s) → `Main` (10s) → the panel (10s) →
   `ReplicatedStorage.Packages` (10s) → `TopbarPlus` (10s); reuse the
   `Icon.getIcon(name)` singleton or `Icon.new()`; bind `icon.selected` /
   `icon.deselected`; and route the panel's `TopBar.CloseButton` to
   `MenuPresentation.Close(frame)` **and** `icon:deselect()`.

8. **Use `HudTree` for HUD nodes** so the nested-then-flat fallback keeps
   working. Do not hardcode `PlayerGui.HUD.BottomLeft.MoneyCounter`.

9. **Use `MenuPresentation.Open` / `Close` / `SetVisible`** for any panel
   that is not owned by a topbar icon. The dim overlay and blur are
   reference-counted; using `frame.Visible = true` directly breaks the
   chrome.

10. **Guard one-time button wiring with an attribute** (`UiSoundWired`,
    `ShopSkipWired`, …). The attribute dies with the instance, so a respawn
    re-clone rewires cleanly.

11. **Never create fallback UI.** If the authored panel is missing, log a
    loud warning and make the feature inert. A half-right generated
    substitute is worse than an honest absence.

12. **Add the controller to `Dependencies.md` and `API.md`** in this folder,
    and to the init-order lists in `README.md` and `MEMORY.md`.
