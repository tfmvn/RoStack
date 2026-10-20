# ClientPresentation

The whole client layer: bootstrap, HUD, menus, notifications, arena impact
presentation, tutorial, and the fast-boot topbar icons.

**Portability:** Grade A core (the presentation *mechanism* — bootstrap
ordering, remote-driven rendering, viewport/showcase pipelines, notification
queue, menu chrome, prompt filtering) + Grade B (the concrete Studio-authored
GUI hierarchy, the Arena/egg/animal domain vocabulary, the remotes'
payload shapes, and the TopbarPlus dependency).

**Source game:** Brainrot Arena (`p-7`).

**Docs in this folder:**

| Doc | What it is for |
|---|---|
| [README.md](README.md) | This file — what it is, what the files are, how it fits together. |
| [MEMORY.md](MEMORY.md) | Dense engineering notes for a future agent: the exact remote contract, the invariants, the error-handling pattern, and the gotchas. |
| [Dependencies.md](Dependencies.md) | Verbatim `require` paths, the full remote inventory, the full `PlayerGui` hierarchy, external APIs. |
| [Setup.md](Setup.md) | Numbered install steps, the exact bootstrap wiring, the GUIs to author, the smoke test, how to add a controller. |
| [API.md](API.md) | The public surface of each controller: what it exposes, what remotes it uses, its lifecycle hooks. |
| [Config.lua](Config.lua) | A catalogue of the client-side tunables (the client owns no live config module of its own). |

---

## What It Does

35 Luau files under `Source/StarterPlayer/StarterPlayerScripts/`. They form
the entire client of the game — there is no other client code.

They are:

- **28 bootstrap-initialised controllers** — one per feature, each owning a
  slice of the UI and a set of remote subscriptions.
- **4 standalone fast-boot topbar LocalScripts** — deliberately *not* wired
  through `bootstrap.client.lua`, so their icons appear before the slow
  bootstrap finishes.
- **3 shared helper modules** — `HudTree` (HUD path resolution),
  `MenuPresentation` (menu open/close chrome), and `bootstrap.client.lua`
  itself.

The architectural rule the whole tree obeys:

> **The client is presentation-only. The server decides everything.**

No client here computes a price, grants a reward, decides eligibility, owns
an outcome, or resolves an identity. A client only ever sends *intent*
(`{Action='Claim'}`, `{Action='Rebirth'}`) and paints whatever the server
pushes back. The server re-resolves every field it needs; a client that
forges a payload gains nothing.

A second rule, equally consistent:

> **The client creates as little UI as possible.**

Panels are Studio-authored. `ToastController` deliberately creates **no** UI
at all — it delegates to `HudNotificationController`, which paints the
authored `HUD.Center.Notifications` label and, if that is missing, warns
loudly and drops the notification rather than inventing a fallback stack.

---

## Entry Points

There is exactly one entry point: `StarterPlayer.StarterPlayerScripts.bootstrap.client.lua`
(a LocalScript, so it runs automatically).

It does three things, in this order:

1. Requires `ReplicatedStorage.Utility.Remotes`, `ReplicatedStorage.Utility.Debug`,
   and `ReplicatedStorage.Config.Systems.Debug`, then calls
   `Debug.SyncFromDebugConfig(DebugConfig)` **before any controller `Init`** —
   so every controller's `Debug.Log`/`Debug.Warn` already obeys the
   `ClientDebug` flag.
2. Requires every controller module (a plain `require`, so the module bodies
   run, but **no `Init` yet**), then blocks on
   `ReplicatedStorage:WaitForChild('CmdrClient')` — the Cmdr client half.
3. Calls `Remotes.WaitForReady()` (blocks until the server has replicated
   the `Remotes` folder, up to 10s), then calls `Init()` on each controller
   in the fixed order below.

The **controller init order** is the load-bearing part:

| # | Controller | Why it sits here |
|---|---|---|
| 1 | `HUDController` | Base HUD; subscribes to `PlayerState` first. |
| 2 | `MoneyPoolController` | Early — `CashCollected` must never wait behind a GUI resolution. |
| 3 | `GearShopController` | Early — must subscribe before any gear push lands. |
| 4 | `ShopController` | Early — `ShopButton` binding must be instant. |
| 5 | `ArenaController` | Early — the Adventurer prompt can fire before `MainGui` resolves. |
| 6 | `CodesController` | Early — the player can submit a code the instant `PlayerGui` exists. |
| 7 | `DailyRewardsController` | Early — the state subscription must exist before any push lands. |
| 8 | `PlaytimeRewardsController` | Early — threshold pushes fire while the panel is closed. |
| 9 | `SellConfirmController` | Early — a `SellPreviewState` fired before this subscription existed caused a ~20s confirmation delay. |
| 10 | `ArenaResultController` | Early — the `RaidEnd` result must open the panel instantly. |
| 11 | `RebirthController` | Early — the HUD toggle must bind before the blocking `MainGui` wait. |
| 12 | `EggTimerController` | Early — server-authoritative egg guarantee timers. |
| 13 | `EventController` | Early — world-event countdown. |
| 14 | `EventTransitionController` | Early — the transition cinematic subscription must exist before any transition lands. |
| 15 | `ServerLuckController` | Early — luck display. |
| 16 | `TutorialController` | Early — must subscribe before any tutorial push lands. |
| 17 | `ArenaCameraImpacts` | Presentation from the same `ArenaHit` packet. |
| 18 | `ArenaHitPresentation` | Presentation from the same `ArenaHit` packet. |
| 19 | `HudNotificationController` | Must exist before `ToastController` forwards to it. |
| 20 | `ToastController` | Forwards `Notify` to `HudNotificationController`. |
| 21 | `UiSoundController` | Early enough that hover/click feedback exists from first paint. |
| 22 | `SettingsController` | **Before** `SlotMenuController` — `SlotMenu`'s `Init` blocks ~15s on its `MainGui` wait, and the sliders/music must not sit behind it. |
| 23 | `SlotMenuController` | **The one blocking controller.** Its `Init` waits on `PlayerGui.MainGui` (~15s). |
| 24 | `PromptOwnerFilter` | Prompt visibility filtering. |
| 25 | `ResetProtectionController` | Reset-gate presentation. |
| 26 | `StealPresentationController` | Thief-only steal camera. |
| 27 | `ToolLockController` | Carry tool lock. |
| 28 | `BatController` | Bat PvP input. |

Then: `print('[bootstrap.client] Client initialised, awaiting server state.')`

**The ordering rationale, in the source's own words:** controllers 1–22 are
initialised early so their remote subscriptions exist *before* any server
push can land, and so they never wait behind `SlotMenuController`'s blocking
`MainGui` resolution. `SlotMenuController` is last among the blockers
because it is the only one that waits.

### Standalone fast-boot topbar scripts

These four are **deliberately not** wired through `bootstrap.client.lua`.
Each `LocalScript` in `StarterPlayerScripts` runs on its own thread, so these
bind their icon as soon as their only real dependencies exist — without
waiting on `CmdrClient` replication, the `Remotes` folder, the profile, the
base, or any server system.

| Script | Icon name | Image asset | Owns open/close of |
|---|---|---|---|
| `SettingsTopbar.client.lua` | `Settings` | `10734950309` | `PlayerGui.Main.Settings` |
| `CodesTopbar.client.lua` | `Codes` | `10734983868` | `PlayerGui.Main.Codes` |
| `DailyTopbar.client.lua` | `DailyRewards` | `10709789505` | `PlayerGui.Main.DailyRewards` |
| `PlaytimeTopbar.client.lua` | `PlaytimeRewards` | `10709805144` | `PlayerGui.Main.PlayTimeRewards` |

Each is a **single owner** of its panel's open/close: the icon's
`selected`/`deselected` signals drive the panel, and the panel's
`TopBar.CloseButton` hides it *and deselects the icon* so the two controls
never disagree. The matching controller (`SettingsController`,
`CodesController`, `DailyRewardsController`, `PlaytimeRewardsController`)
never shows or hides its panel — it only wires content.

---

## Files

| Library path | Roblox destination | Purpose | Remotes used | PlayerGui hierarchy expected |
|---|---|---|---|---|
| `Source/StarterPlayer/StarterPlayerScripts/bootstrap.client.lua` | `StarterPlayer.StarterPlayerScripts.bootstrap.client` | The client entry point. Syncs debug config, waits for `CmdrClient` + `Remotes`, then `Init`s all 28 controllers in order. | `Remotes.WaitForReady()` (folder) | — |
| `.../HudTree.lua` | `…StarterPlayerScripts.HudTree` | Single source of truth for resolving the authored HUD tree (nested path first, legacy flat fallback). Also owns ancestor-chain visibility (`EnsureChainVisible` / `ReleaseChain`). | — | `HUD.BottomLeft.MoneyCounter(.Text)`, `HUD.BottomLeft.ServerLuckCounter(.Text)`, `HUD.Left.RebirthButton`, `HUD.Left.ShopButton`, `HUD.Top.Tutorial(.Counter/.Steps)`, `HUD.Center.Notifications`, `HUD.Bottom.WaveCounter(.Counter)` + flat legacy equivalents |
| `.../MenuPresentation.lua` | `…StarterPlayerScripts.MenuPresentation` | Shared menu open/close: `UiOpen` sting, singleton dim overlay (`MenuDimGui`/`Dim`), singleton `BlurEffect` (`MenuDimBlur`), `ShopAnimations.Open/Close(frame,'Pop')`, reference-counted across open menus. | — | `PlayerGui` (creates `MenuDimGui` itself) |
| `.../HUDController.lua` | `…StarterPlayerScripts.HUDController` | Paints the HUD from `PlayerState`: money counter, slot rows, carry state, slot rarity colours. | `PlayerState` (S→C) | `HUD.BottomLeft.MoneyCounter(.Text)`, HUD slot rows |
| `.../MoneyPoolController.lua` | `…StarterPlayerScripts.MoneyPoolController` | Absorbs `CashCollected` into the HUD money counter: pooled icon burst + count-up converging on the authoritative `PlayerState` value. | `CashCollected` (S→C), `PlayerState` (S→C) | `HUD.BottomLeft.MoneyCounter(.Text)`; `Workspace.Map.CenterPart` cash trigger |
| `.../ServerLuckController.lua` | `…StarterPlayerScripts.ServerLuckController` | Displays the server-authoritative luck value from a replicated attribute. | — (reads `ReplicatedStorage.ServerLuck` attribute) | `HUD.BottomLeft.ServerLuckCounter(.Text)` |
| `.../HudNotificationController.lua` | `…StarterPlayerScripts.HudNotificationController` | The notification queue: paints the authored `HUD.Center.Notifications` label, with coalescing, per-category colour, duration, and a rolling "spam window" for Y-only motion. | — (called by `ToastController`) | `HUD.Center.Notifications` (plural canonical; `HUD.Center.Notification`, `HUD.Notifications` legacy) |
| `.../ToastController.lua` | `…StarterPlayerScripts.ToastController` | Forwards the `Notify` remote to `HudNotificationController`; also carries the arrival hooks that feed HUD slot state. | `Notify`, `AnimalArrived`, `EggArrived`, `AnimalCarried`, `AnimalPlaced`, `EggCarried`, `EggPlaced` (all S→C) | none of its own — delegates |
| `.../UiSoundController.lua` | `…StarterPlayerScripts.UiSoundController` | Personal UI sounds: wires every `GuiButton` under `PlayerGui` to `UiHover`/`UiClick` (attribute-deduped, `DescendantAdded` for late UI), and exposes `Play(name)`. | — | `PlayerGui` (any `GuiButton`); reads `ReplicatedStorage.Assets.Sfx` |
| `.../PromptOwnerFilter.lua` | `…StarterPlayerScripts.PromptOwnerFilter` | Hides `ProximityPrompt`s whose `ownerUserId` / `targetUserId` / `purchaserUserId` do not match the local player; hides every Buy prompt while the local player is carrying. | `PlayerState` (S→C) | — (reads `Workspace` prompt attributes) |
| `.../ResetProtectionController.lua` | `…StarterPlayerScripts.ResetProtectionController` | Greys out / restores the reset button from the server's protected-state push. | `ResetProtection` (S→C) | reset button in the authored HUD |
| `.../ToolLockController.lua` | `…StarterPlayerScripts.ToolLockController` | While the server reports `CarryLock`, hides the Backpack hotbar and unequips any equipped Tool; guards `Character.ChildAdded` so a mid-lock equip is dropped at once. | `CarryLock` (S→C) | — (touches `StarterGui` Backpack CoreGui) |
| `.../StealPresentationController.lua` | `…StarterPlayerScripts.StealPresentationController` | Thief-only camera FOV narrowing while the local player is steal-carrying an *animal*. | `PlayerState` (S→C) | — |
| `.../BatController.lua` | `…StarterPlayerScripts.BatController` | Instant local bat swing animation + swing request. Never claims a hit. | `BatSwing` (C→S, no payload) | — |
| `.../ShopController.lua` | `…StarterPlayerScripts.ShopController` | Robux Shop open/close (via the HUD `ShopButton`), gamepass entitlement sync, `SkipDaily` / `SkipPlaytime` funnel prompts. | `ShopAction` (C→S) — fires only; it does **not** listen to `ShopResult` (feedback travels on `Notify`) | `HUD.Left.ShopButton` (flat `HUD.ShopButton` fallback), `PlayerGui.Main.Shop` (+ `TopBar.CloseButton`, `ScrollingFrame`) |
| `.../GearShopController.lua` | `…StarterPlayerScripts.GearShopController` | Gear shop panel: renders server snapshots, forwards purchase / equip / auto-buy, presents Tool previews. | `GearShopAction` (C→S), `GearShopState` (S→C), `GearShopResult` (S→C) | `PlayerGui.GearShop` → `ScrollingFrame` → `GearTemplate` (Name, Description, `Button`+`TextLabel`, `AutoBuy`→`AutoBuyImage`/`Toggle_ON`/`Toggle_OFF`, `LockOverlay`→`RebirthCount`, `ViewportFrame`); `Workspace.Map.Shop.PromptPart`→`ProximityPrompt`; `ReplicatedStorage.GearShopPreviews` |
| `.../ArenaController.lua` | `…StarterPlayerScripts.ArenaController` | Arena menu: renders the server snapshot, forwards start / cancel, drives the wave counter and the pre/post-level titles. | `ArenaAction` (C→S), `ArenaState` (S→C), `ArenaResult` (S→C), `ArenaCombatEvent` (S→C) | `PlayerGui.Main.Arena` → `Buy1`/`Buy2`/`Buy3` (each with a `.TextLabel`), `WarmupLevel`→`Title`, `LastLevel`→`Title`, `CloseButton`; `HUD.Bottom.WaveCounter(.Counter)` |
| `.../ArenaResultController.lua` | `…StarterPlayerScripts.ArenaResultController` | End-of-raid result panel: final animal rows, egg rewards, wave/money totals, the Continue button, and the captured combat-model viewports. | `ArenaResult` (S→C) | `PlayerGui.Main.ArenaResult` → `Name`; `AnimalList.<N>` → `Title`, `Rarity`, `CurrentLevel.Title`, `NewLevel.Title`, `Level`, `XP`, `Item.ViewportFrame`; `RightSide` → `WaveCounter.Wave`, `Money`, `Eggs`→`ScrollingFrame`→`Template`(+`Counter`,`ViewportFrame`), `NoEggs`, `Continue`; `ReplicatedStorage.ArenaResultModels/Session_<id>` |
| `.../ArenaCameraImpacts.lua` | `…StarterPlayerScripts.ArenaCameraImpacts` | Distance-aware camera punch from the authoritative `ArenaHit` packet. Owns CFrame, never FOV. | `ArenaCombatEvent` (S→C) | — |
| `.../ArenaHitPresentation.lua` | `…StarterPlayerScripts.ArenaHitPresentation` | The impact bundle: one-shot VFX clone + positional SFX + damage-number bop, all starting in the same callback with zero waits. | `ArenaCombatEvent` (S→C) | `Workspace.ArenaBattles` (target models); `ReplicatedStorage.Assets.Vfx.HitVfx.Attack1`; `ReplicatedStorage.Assets.Arena.Sfx.Attack<n>` |
| `.../SellConfirmController.lua` | `…StarterPlayerScripts.SellConfirmController` | The two-step sell confirmation: renders the server preview (name, rarity, trait, level, generation, mutations, sell value) and the live animal viewport. | `SellPreviewState` (S→C), `SellConfirmAction` (C→S), `SellConfirmResult` (S→C), `PlayerState` (S→C) | `PlayerGui.Main.SellConfirmation` → `Sell` (TextButton, `.TextLabel`), `Cancle` (TextButton — **authored typo, used verbatim**), `Name`/`Level`/`Generation`/`Mutations` (TextLabels), `RarityBox` (Frame)→`Title` (TextLabel) + `UIGradient` named `Gradient`, `Item` (Frame)→`ViewportFrame` |
| `.../SlotMenuController.lua` | `…StarterPlayerScripts.SlotMenuController` | The legacy slot interaction menu (Upgrade / Sell frames) driven by `SlotMenu*` remotes. | `SlotMenuRequest` (C→S), `SlotMenuState` (S→C), `SlotMenuAction` (C→S), `SlotMenuResult` (S→C), `PlayerState` (S→C), `AnimalLeveledUp` (S→C) | `PlayerGui.MainGui` (canonical) or `PlayerGui.Main` → `UpgradesFrame` {Title, Name, CurrentLevel, NewLevel, `UpgradeButton` (TextLabel), `CloseMenu`}, `SellFrame` {Title, Name, Level, Gen, `SellButton` (TextLabel), `CloseMenu`}; `Workspace.Map.Bases.<baseId>` → stands → `Slot.MenuPart.MenuGui` (SurfaceGui) → `UpgradeButton` (legacy: `MenuGui.Frame.UpgradeButton` / `.SellButton`) |
| `.../CodesController.lua` | `…StarterPlayerScripts.CodesController` | Owns the authored `Main.Codes` content: the code `TextBox` and the `Continue` submit button. | `CodesAction` (C→S), `CodesResult` (S→C) | `PlayerGui.Main.Codes` → `Continue` (TextButton), `CurrentLevel` (TextBox), `TopBar.CloseButton` |
| `.../DailyRewardsController.lua` | `…StarterPlayerScripts.DailyRewardsController` | Owns the authored `Main.DailyRewards` content: day cards, status text, countdown, and the TopbarPlus claimable alert. | `DailyRewardsAction` (C→S), `DailyRewardsState` (S→C), `DailyRewardsResult` (S→C), `ShopAction` (C→S, `FunnelPrompt` analytics ping) | `PlayerGui.Main.DailyRewards` → `Items1` (GuiButtons named `1`..`6`), `Items2` (featured card), per-card `LockedOverlay`/`Day`/`Name`, `Text` (status), `Skip` (GuiButton) |
| `.../PlaytimeRewardsController.lua` | `…StarterPlayerScripts.PlaytimeRewardsController` | Owns the authored `Main.PlayTimeRewards` content: milestone cards, per-card timer text, status text, and the TopbarPlus alert. | `PlaytimeRewardsAction` (C→S), `PlaytimeRewardsState` (S→C), `PlaytimeRewardsResult` (S→C), `ShopAction` (C→S, `FunnelPrompt` analytics ping) | `PlayerGui.Main.PlayTimeRewards` → `Items` (GuiButtons named `1`..`6`), per-card `Timer`→`Text`, `Text` (status), `Skip` (GuiButton) |
| `.../RebirthController.lua` | `…StarterPlayerScripts.RebirthController` | Owns the authored `Main.Rebirth` panel: title, warning, money/arena requirement bars, requirement cards, unlock-preview cards, and the HUD toggle. | `RebirthAction` (C→S), `RebirthState` (S→C), `RebirthResult` (S→C), `PlayerState` (S→C) | `PlayerGui.Main.Rebirth` → `TopBar`{`CloseButton`,`Title`}, `Contents`{`Warning`, `Requirements`{`Items`→`Template`{`Name`,`Number`,`ImageLabel`,`ViewportFrame`}, `Bars`{`Money`{`ProgressBar`,`Text`}, `ArenaLVL`{`ProgressBar`,`Text`}}}, `UnlockItems`→`Template`{`Name`,`Number`,`ImageLabel`,`ViewportFrame`}}, `Button`; `HUD.Left.RebirthButton`; `ReplicatedStorage.RebirthPreviews`; `ReplicatedStorage.GearShopPreviews` |
| `.../SettingsController.lua` | `…StarterPlayerScripts.SettingsController` | Owns the authored `Main.Settings` panel: BGM / SFX sliders, the FastMode toggle, persistence, and the lobby↔arena music crossfade. | `SaveSettings` (C→S), `SettingsState` (S→C), `ArenaState` (S→C), `ArenaResult` (S→C) | `PlayerGui.Main.Settings` → `ScrollingFrame` → `BackgroundMusic`{`Container`{`Bar`,`Button`}}, `GameSound`{`Container`{`Bar`,`Button`}}, `FastMode`→`Button`→`Text`; `TopBar.CloseButton`; `SoundService` → `GameSound` (SoundGroup) → `BgmSound` (SoundGroup) → `Bgm` / `ArenaBgm` |
| `.../EggTimerController.lua` | `…StarterPlayerScripts.EggTimerController` | Local countdown for the server-authoritative egg guarantee timers. Never decides spawns. | — (reads `Workspace.Map.CenterPart.BillboardGui.Egg` attributes) | `Workspace.Map.CenterPart.BillboardGui.Egg` (legacy `Workspace.Map.EggTimer.BillboardGui.Frame`) |
| `.../EventController.lua` | `…StarterPlayerScripts.EventController` | Local countdown for the world-event timer, from server timestamps only. | — (reads `ReplicatedStorage.Event_*` attributes) | `Workspace.Map.CenterPart.BillboardGui.Event` |
| `.../EventTransitionController.lua` | `…StarterPlayerScripts.EventTransitionController` | The event start/stop cinematic: FOV zoom + white flash + fade, driven by the broadcast transition packets. | `EventTransition` (S→C, broadcast) | — |
| `.../TutorialController.lua` | `…StarterPlayerScripts.TutorialController` | The tutorial guide layer: instruction typewriter, quest checklist, beam, white highlight, in-place UI emphasis, and the gated Skip intent. | `TutorialAction` (C→S), `TutorialState` (S→C) | `HUD.Top.Tutorial`{`.Counter`, `.Steps`}, `HUD.TutorialSteps` → `Steps` → `Step1` template, `HUD.TutorialSkip`; `ReplicatedStorage.TutorialBeamTemplate`; `Workspace.EggArea.ActiveEggs`; `Workspace.Map.Bases.<baseId>`; `PlayerGui.Main.Arena`, `PlayerGui.Main.ArenaResult` |
| `.../SettingsTopbar.client.lua` | `…StarterPlayerScripts.SettingsTopbar.client` | Fast-boot TopbarPlus `Settings` icon. **Not** wired through bootstrap. | — | `PlayerGui.Main.Settings` (+ `TopBar.CloseButton`); `ReplicatedStorage.Packages.TopbarPlus` |
| `.../CodesTopbar.client.lua` | `…StarterPlayerScripts.CodesTopbar.client` | Fast-boot TopbarPlus `Codes` icon. **Not** wired through bootstrap. | — | `PlayerGui.Main.Codes` (+ `TopBar.CloseButton`); `ReplicatedStorage.Packages.TopbarPlus` |
| `.../DailyTopbar.client.lua` | `…StarterPlayerScripts.DailyTopbar.client` | Fast-boot TopbarPlus `DailyRewards` icon. **Not** wired through bootstrap. | — | `PlayerGui.Main.DailyRewards` (+ `TopBar.CloseButton`); `ReplicatedStorage.Packages.TopbarPlus` |
| `.../PlaytimeTopbar.client.lua` | `…StarterPlayerScripts.PlaytimeTopbar.client` | Fast-boot TopbarPlus `PlaytimeRewards` icon. **Not** wired through bootstrap. | — | `PlayerGui.Main.PlayTimeRewards` (+ `TopBar.CloseButton`); `ReplicatedStorage.Packages.TopbarPlus` |

### Count discrepancy

The extraction brief described this system as "40 client scripts". The tree
actually contains **35** `.lua` files (18,908 lines). This document documents
all 35. Nothing is missing.

---

## Configuration

The client layer has **no config module of its own**. Every tunable it reads
lives in a config owned by another system, and is documented there. The
client-side subset:

| Value | Lives in | Meaning |
|---|---|---|
| `UI.RarityColor` | `Config/Presentation/UI.lua` | Rarity → colour, for the HUD and card outlines. |
| `UI.Notify.*` | `Config/Presentation/UI.lua` | Notification duration, coalescing window, max text length, category colours, and the HUD motion timings (`DisplayDuration`, `EnterOffsetPx`, `ExitOffsetPx`, `DropSeconds`, `ExitSeconds`, `ExitCancelSeconds`, `ExitCancelDelaySeconds`, `RestoreBufferSeconds`). |
| `UI.Toast.*` | `Config/Presentation/UI.lua` | Toast enter/exit motion. |
| `UI.HUD.*`, `UI.SlotRow.*` | `Config/Presentation/UI.lua` | HUD anchor/position/size/padding and slot row geometry. |
| `UI.Overhead.*` | `Config/Presentation/UI.lua` | Overhead trait/mutation colours, rainbow period. |
| `Audio.Notification.SuccessCueName` / `ErrorCueName` | `Config/Presentation/Audio.lua` | Which SFX a notification category plays. |
| `Audio.StealAlertSoundName` | `Config/Presentation/Audio.lua` | Steal alert sting. |
| `Audio.Collect.PoolSize` | `Config/Presentation/Audio.lua` | Cash-collect sound pool size. |
| `Audio.LevelUp.*` | `Config/Presentation/Audio.lua` | Level-up VFX/SFX asset names. |
| `Audio.Arena.*` | `Config/Presentation/Audio.lua` | Arena VFX/SFX roots, attack asset name, SFX slot prefix. |
| `Vfx.*` | `Config/Presentation/Vfx.lua` | Level-up / egg-roll / hygiene VFX lifetimes, cleanup caps, burst counts, bop and tilt tuning. |
| `Debug.ClientDebug` | `Config/Systems/Debug.lua` | Master gate for client `Debug.Log`/`Debug.Warn`. `false` by default. |
| `Debug.Tags` | `Config/Systems/Debug.lua` | Per-tag whitelist — a tag not in the list fails **quiet**. |
| `Debug.Audio.Enabled` | `Config/Systems/Debug.lua` | Verbose client audio-path trace. |
| `Debug.Subsystem.ArenaHitClient` | `Config/Systems/Debug.lua` | Per-hit verification logs (one line per attack — spams a fight). |
| `Debug.DrawPaths` | `Config/Systems/Debug.lua` | Debug path drawing. |
| `Config.World.ArenaFeel` | `Config/World/ArenaFeel.lua` | Damage-number styling, hit-VFX asset name, SFX slot count/prefix, anchor size, camera-punch tuning. |
| `Config.World.Stealing.StealPresentation` | `Config/World/Stealing.lua` | `FOVMultiplier` + `FOVTweenTime` for the steal camera. |
| `Config.World.Events` | `Config/World/Events.lua` | Event transition timings. |
| `Config.World.Bases` | `Config/World/Bases.lua` | Base/slot geometry, read by the HUD and money pool. |
| `Config.Creatures.Rarity` | `Config/Creatures/Rarity.lua` | Rarity colours, order, display names. |
| `Config.Creatures.Eggs` | `Config/Creatures/Eggs.lua` | Egg catalog, starter rarity, guarantee intervals. |
| `Config.Creatures.Traits` | `Config/Creatures/Traits.lua` | Trait display for the sell preview. |
| `Config.Economy.Gear` | `Config/Economy/Gear.lua` | Gear catalog + the `Combat` (bat) tuning. |
| `Config.Economy.Sell` | `Config/Economy/Sell.lua` | Sell-confirmation copy/formatting. |
| `Config.Economy.Shop` | `Config/Economy/Shop.lua` | `DeveloperProducts.SkipDaily` / `SkipPlaytime` ProductIds, gamepass ids. |

Because the client owns no config of its own, this library ships
**`Config.lua` as a catalogue** rather than a live tunable module — see
[Config.lua](Config.lua).

---

## Dependencies

See [Dependencies.md](Dependencies.md) for the verbatim require paths, the
full remote inventory, the complete `PlayerGui` hierarchy, and the external
APIs.

The load-bearing non-library dependencies:

- `ReplicatedStorage.Utility.Remotes` — the remote registry (in
  `ReusableSystems/Shared/CommonModules/Remotes.lua`).
- `ReplicatedStorage.Utility.Debug` — the debug gate.
- `ReplicatedStorage.ShopAnimations` — the Pop open/close animation module.
  **Not in this library.**
- `ReplicatedStorage.Packages.TopbarPlus` — the TopbarPlus package.
  **Not in this library.**
- `ReplicatedStorage.CmdrClient` — the Cmdr client half. **Not in this
  library.**
- `ReplicatedStorage.Utility.AudioGroups` — the `GameSound` / `BgmSound`
  SoundGroup masters. **Not in this library.**
- `ReplicatedStorage.Utility.AnimalShowcase`, `.AnimalViewport`,
  `.StandShowcase`, `.StandResolver`, `.ArenaUIState`, `.CenterPartBillboards`,
  `.RebirthUnlocks` — shared presentation helpers. **Not in this library.**

---

## Initialization Order

```text
StarterPlayerScripts (each LocalScript runs on its own thread)
├─ SettingsTopbar.client.lua   ─┐
├─ CodesTopbar.client.lua       │  fast-boot topbar icons: bind as soon as
├─ DailyTopbar.client.lua       │  PlayerGui.Main.<Panel> and
├─ PlaytimeTopbar.client.lua   ─┘  ReplicatedStorage.Packages.TopbarPlus exist
└─ bootstrap.client.lua
   1. require Utility.Remotes
   2. require Utility.Debug + Config.Systems.Debug
   3. Debug.SyncFromDebugConfig(DebugConfig)      -- before any Init
   4. require all controller modules (no Init yet)
   5. require ReplicatedStorage:WaitForChild('CmdrClient')   -- BLOCKS
   6. Remotes.WaitForReady()                                 -- BLOCKS (10s)
   7. HUDController.Init()
   8. MoneyPoolController.Init()
   9. GearShopController.Init()
  10. ShopController.Init()
  11. ArenaController.Init()
  12. CodesController.Init()
  13. DailyRewardsController.Init()
  14. PlaytimeRewardsController.Init()
  15. SellConfirmController.Init()
  16. ArenaResultController.Init()
  17. RebirthController.Init()
  18. EggTimerController.Init()
  19. EventController.Init()
  20. EventTransitionController.Init()
  21. ServerLuckController.Init()
  22. TutorialController.Init()
  23. ArenaCameraImpacts.Init()
  24. ArenaHitPresentation.Init()
  25. HudNotificationController.Init()
  26. ToastController.Init()
  27. UiSoundController.Init()
  28. SettingsController.Init()
  29. SlotMenuController.Init()      -- the ONE blocking Init (~15s MainGui wait)
  30. PromptOwnerFilter.Init()
  31. ResetProtectionController.Init()
  32. StealPresentationController.Init()
  33. ToolLockController.Init()
  34. BatController.Init()
  35. print('[bootstrap.client] Client initialised, awaiting server state.')
```

---

## Known Limitations

- **`ToastController` has no fallback UI.** If `HUD.Center.Notifications` is
  missing, notifications are dropped and one loud `warn` fires. This is
  deliberate — a silent fallback stack is worse than a visible gap — but it
  means the authored HUD is a hard dependency of the whole notification path.
- **The `SellConfirmation` panel's cancel button is authored as `Cancle`**
  (sic). The client looks it up by that exact misspelling. A new game must
  either keep the typo or change the code.
- **`SlotMenuController` blocks for ~15 seconds.** Its `Init` waits on
  `PlayerGui.MainGui`. Everything that must be instant is deliberately
  initialised *before* it. If you add a controller, decide explicitly whether
  it belongs before or after that line.
- **Four remotes are subscribed but intentionally do nothing.**
  `AnimalCarried`, `AnimalPlaced`, `EggCarried`, `EggPlaced` have
  no-op handlers in `ToastController`. The wires exist so future carry
  feedback has a landing point. Do not read them as unimplemented features
  that are broken — they are placeholders.
- **`SettingsController.FastMode` has no gameplay effect anywhere in the
  project.** The toggle persists and paints, and nothing reads it. The
  source says so explicitly.
- **The tutorial's "BuyEgg" target is chosen client-side by proximity.**
  The server tracks the per-player `TutorialTarget_<userId>` tag for tracked
  models, but the *first* egg target is resolved by the client scanning
  `Workspace.EggArea.ActiveEggs` for the nearest starter-rarity egg with a
  live `BuyPrompt`. The client is trusted here only for *which thing to
  point at*, never for anything the server acts on.
- **`SellConfirmController` and `RebirthController` use two different
  viewport pipelines** (`AnimalViewport` vs `AnimalShowcase`/`StandShowcase`).
  Both clone-and-fit, but the pipelines are not the same module.
- **Music tracks are found by a three-place search** (`SoundService`, then
  `Workspace`, then the server-mirrored `ReplicatedStorage.Assets.Sfx`).
  A `ReplicatedStorage` template cannot play, so it is cloned into
  `SoundService` once.
- **`MenuPresentation` requires `ShopAnimations` to be present.** If
  `ShopAnimations.Open/Close` throws, the frame is shown/hidden instantly as
  a fallback, and a warning is logged.
- **No tests ship with this system.** The extraction brief noted `Tests/`
  would be "none yet for this system" — confirmed: there is no `Tests/`
  directory under `ClientPresentation/`. The controllers do expose
  `_Test*` seams (see [API.md](API.md)) that a future spec suite can drive.

---

## Testing

**None included.** The controllers were written with test seams
(`_TestIsLocked`, `_TestTargetFov`, `_TestChecklistFor`,
`_TestFindStarterInFolder`, `_TestTagNameFor`, `_TestSkipPayload`,
`_TestSetTypeInterval`, `_TestTypeText`, `_TestResolveSfx`,
`_TestEnsureBeam`, `_TestBeatFor`, `_TestUpdateSpotlight`,
`_TestClearSpotlight`, `_TestIsAssetBeam`, `_TestResetBeam`,
`_TestVfxCleanup`), but no spec files exist.

The seams are deliberately pure where possible: `_TestChecklistFor(step)`
is a pure function of the step string, `_TestTargetFov(baseFov)` is pure
arithmetic, `_TestFindStarterInFolder(folder, here, userId)` takes the
folder as an argument so a spec never touches live `Workspace`. A future
suite can drive all of these without a server.

The library-wide harness lives in `../../Tests/` (`TestRunner.server.lua`,
`_Helpers.lua`, `IntegrationTests/`) and is **TestEZ**-based. There is no
`Tests/README.md` in this library — the per-system convention is simply
`Systems/<System>/Tests/<Name>.spec.lua`, which is where a future
`ClientPresentation/Tests/` suite would go.

---

## Adapting to a New Game

1. **Author the GUIs first.** Almost nothing works without the Studio
   hierarchy. `Dependencies.md` → *Studio Assets* has the full tree for
   every panel; author against it exactly, including the nested-vs-flat
   fallback conventions if you want the legacy path to work.
2. **Copy `HudTree` and `MenuPresentation` unchanged.** They are the two
   pieces of infrastructure everything else assumes. Change the path tables
   in `HudTree` if your HUD is structured differently.
3. **Keep the bootstrap order.** The invariant is: *anything that subscribes
   to a remote goes before `SlotMenuController`*. If you add a controller
   that subscribes to a remote, put it in the early block. If it does not
   subscribe, it can go after.
4. **Keep the trust model.** Your new controllers must send intent only.
   If you find yourself computing a price, a level, or a reward on the
   client, that logic belongs on the server.
5. **Do not add generated fallback UI.** The codebase's stance is that a
   missing authored panel should warn loudly, not silently render something
   half-right. Keep that.
6. **Copy the fast-boot pattern for any new topbar icon.** A standalone
   `LocalScript` that waits only on `PlayerGui.Main.<Panel>` and
   `ReplicatedStorage.Packages.TopbarPlus` binds in milliseconds, versus
   waiting for the whole game to boot.
7. **Decide the `Remotes` registry as one change.** Every remote name and
   payload shape is documented in `Shared/CommonModules/Remotes.lua`; add
   yours there, not inline.
8. **Write the server side first.** The client is a projection of a server
   snapshot. If you find yourself inventing a payload the server does not
   send, stop — the server is the missing half.
