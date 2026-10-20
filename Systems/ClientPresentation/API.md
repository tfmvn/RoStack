# ClientPresentation — API

The public surface of every controller in the client layer, grouped by
controller.

**Scope of this document:** what a module *exposes*, what remotes it
listens to / fires, and its lifecycle hooks. Internal helpers are **not**
documented. The `_Test*` members are listed because they are the real
seams the (future) spec files use — they are part of the surface, not
incidental.

**Convention across the whole layer:**

- Every controller is a **ModuleScript** that returns a table.
- Every controller exposes **`Init()`**. It is idempotent (`if wired then
  return end`) and it is the only lifecycle hook.
- `Init()` never throws and never blocks the caller. A missing remote or a
  missing GUI disables that one feature and logs a named warning.
- Controllers do **not** expose `Stop()` / `Destroy()`. Cleanup is internal
  and idempotent.

---

## Table of contents

- [bootstrap.client](#bootstrapclient)
- [HUDController](#hudcontroller)
- [ToastController](#toastcontroller)
- [HudNotificationController](#hudnotificationcontroller)
- [HudTree](#hudtree)
- [MenuPresentation](#menupresentation)
- [UiSoundController](#uisoundcontroller)
- [PromptOwnerFilter](#promptownerfilter)
- [GearShopController](#gearshopcontroller)
- [ArenaController](#arenacontroller)
- [ArenaResultController](#arenaresultcontroller)
- [ArenaCameraImpacts](#arenacameraimpacts)
- [ArenaHitPresentation](#arenahitpresentation)
- [SellConfirmController](#sellconfirmcontroller)
- [RebirthController](#rebirthcontroller)
- [SlotMenuController](#slotmenucontroller)
- [MoneyPoolController](#moneypoolcontroller)
- [CodesController](#codescontroller)
- [DailyRewardsController](#dailyrewardscontroller)
- [PlaytimeRewardsController](#playtimerewardscontroller)
- [SettingsController](#settingscontroller)
- [ShopController](#shopcontroller)
- [EggTimerController](#eggtimercontroller)
- [EventController](#eventcontroller)
- [EventTransitionController](#eventtransitioncontroller)
- [ServerLuckController](#serverluckcontroller)
- [TutorialController](#tutorialcontroller)
- [ResetProtectionController](#resetprotectioncontroller)
- [StealPresentationController](#stealpresentationcontroller)
- [ToolLockController](#toollockcontroller)
- [BatController](#batcontroller)
- [Topbar LocalScripts](#topbar-localscripts)

---

## bootstrap.client

A **LocalScript**, not a module. It exports nothing; it *runs*.

**Lifecycle:** runs once per client, on load.

**What it does, in order:**

1. `require`s `ReplicatedStorage.Utility.Remotes`, `.Debug` and
   `Config.Systems.Debug`, then calls
   `Debug.SyncFromDebugConfig(DebugConfig)` — **before any `Init`**.
2. `require`s 14 controllers at the top of the file and 14 more inline at
   their `Init` site.
3. `require(ReplicatedStorage:WaitForChild('CmdrClient'))` — **blocking**.
4. `Remotes.WaitForReady()` — **blocking**, 10s, hard-fails if the
   `Remotes` folder never replicated.
5. Calls `Init()` on 28 controllers in a fixed order.
6. Prints `[bootstrap.client] Client initialised, awaiting server state.`

**Init order** (see `Dependencies.md` → Initialization Order for the full
list): `HUDController`, `MoneyPoolController`, `GearShopController`,
`ShopController`, `ArenaController`, `CodesController`,
`DailyRewardsController`, `PlaytimeRewardsController`, `SellConfirmController`,
`ArenaResultController`, `RebirthController`, `EggTimerController`,
`EventController`, `EventTransitionController`, `ServerLuckController`,
`TutorialController`, `ArenaCameraImpacts`, `ArenaHitPresentation`,
`HudNotificationController`, `ToastController`, `UiSoundController`,
`SettingsController`, `SlotMenuController`, `PromptOwnerFilter`,
`ResetProtectionController`, `StealPresentationController`, `ToolLockController`,
`BatController`.

**Remotes:** none directly. It gates every other controller's access to
them.

---

## HUDController

The money / base / carry / slot readout. It is the only controller that
**creates** any HUD nodes — the money label, the base label, the carry
label and the slot list are built in code and parented under the authored
`HUD` gui.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `PlayerState`. Idempotent. |
| `SetMoney(money: string)` | `(string) -> nil` | Paints the money label. The string is a BigNumber decimal; it is formatted with `BigNumber.Format` and prefixed with `$`. This is the only place `tonumber` touches the value, and only for display. A missing/empty string falls back to `'0'`. |
| `SetBase(baseId: string?)` | `(string?) -> nil` | Paints `'Base: <id>'`, or `'Base: -'` when `nil`. |
| `SetPlayerState(payload: any)` | `(any) -> nil` | Applies a whole `PlayerState` snapshot: money, base, carry label, slot rows. Called internally by the `PlayerState` handler; exposed so a test can drive it directly. |
| `SetSlotAnimal(slotId: string, displayName: string, rarity: string)` | `(string, string, string) -> nil` | Marks a slot row as an animal and paints its name in the rarity colour. |
| `SetSlotEgg(slotId: string, rarity: string)` | `(string, string) -> nil` | Marks a slot row as an egg and paints it in the rarity colour. |

**Remotes:** listens to `PlayerState` (S→C).

**Lifecycle:** `Init()` subscribes. Everything else is a paint call that is
safe to invoke at any time; a missing `HUD` gui makes every setter a
no-op.

**Test seams:** none — the controller has no `_Test*` members.

---

## ToastController

The server→client notification entry point. It is a **thin router**: it
validates the payload and delegates to `HudNotificationController`.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `Notify`, `AnimalArrived`, `EggArrived`, `AnimalCarried`, `AnimalPlaced`, `EggCarried`, `EggPlaced`. Idempotent. |
| `Push(payload: any)` | `(any) -> nil` | Pushes one notification manually. Expects `{Category, Text}`; anything missing either field is dropped silently. |

**Remotes:** listens to `Notify`, `AnimalArrived`, `EggArrived`,
`AnimalCarried`, `AnimalPlaced`, `EggCarried`, `EggPlaced` (all S→C).

The four carry remotes (`AnimalCarried`, `AnimalPlaced`, `EggCarried`,
`EggPlaced`) are **wired but their handlers are deliberate no-ops** —
the wire exists for future carry feedback.

**Behaviour notes:**

- There is **no generated fallback UI**. If `HUD.Center.Notifications` is
  missing, the notification is dropped and a loud `warn` fires naming the
  expected path. This is intentional — see `MEMORY.md`.
- `Push` does not create anything; it is a pure delegation.

---

## HudNotificationController

The actual notification renderer. It paints into the authored
`HUD.Center.Notifications` object using a rolling "spam window": a new
notification with the same `(Category, Text)` inside the coalescing window
extends the existing one's lifetime instead of stacking.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Resolves the panel and arms the expiry. Idempotent. |
| `Show(category: string, text: string): boolean` | `(string, string) -> boolean` | Shows one notification. Returns `true` when it was rendered, `false` when there is no usable panel (or the call failed). **Never throws.** |

**Remotes:** none. It is driven by `ToastController` (or called directly).

**Behaviour notes:**

- Motion is **Y-only** — repeated notifications never stack vertically.
- The panel is a phase machine: `idle` → `entering` → `visible` → `exiting`.
- Category colours come from `Config.Presentation.UI.Notify.CategoryColor`.
- The panel is resolved lazily and re-resolved if it is replaced.

---

## HudTree

A **path resolver** over `PlayerGui`. It has no `Init()` — it is a pure
utility used by the other controllers. It is the reason the HUD works
with both the nested layout and the older flat layout.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Descend(root: Instance?, ...: string): Instance?` | `(Instance?, string...) -> Instance?` | Walks a child path. Returns `nil` at the first missing or wrong-class node. |
| `Hud(playerGui: Instance?): Instance?` | `(Instance?) -> Instance?` | The `HUD` gui itself. |
| `Text(node: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | The label inside a node: the node itself if it is a `TextLabel`, else its child named `Text`. |
| `Button(node: Instance?): GuiButton?` | `(Instance?) -> GuiButton?` | The button inside a node: the node itself if it is a `GuiButton`, else its child named `Button`. |
| `MoneyText(playerGui: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | `HUD.BottomLeft.MoneyCounter` → `HUD.MoneyCounter`. |
| `LuckText(playerGui: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | `HUD.BottomLeft.ServerLuckCounter` → `HUD.ServerLuckCounter` → `HUD.ServerLuck`. |
| `RebirthButton(playerGui: Instance?): GuiButton?` | `(Instance?) -> GuiButton?` | `HUD.Left.RebirthButton` → `HUD.RebirthButton`. |
| `ShopButton(playerGui: Instance?): GuiButton?` | `(Instance?) -> GuiButton?` | `HUD.Left.ShopButton` → `HUD.ShopButton`. |
| `TutorialRoot(playerGui: Instance?): Instance?` | `(Instance?) -> Instance?` | `HUD.Top.Tutorial` → `HUD.TutorialSteps` → `HUD.Tutorial`. |
| `TutorialCounter(playerGui: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | `HUD.Top.Tutorial.Counter`. |
| `TutorialSteps(playerGui: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | `HUD.Top.Tutorial.Steps`. |
| `NotificationPanel(playerGui: Instance?): GuiObject?` | `(Instance?) -> GuiObject?` | `HUD.Center.Notifications` → `HUD.Center.Notification` → `HUD.Notifications`. |
| `WaveRoot(playerGui: Instance?): Instance?` | `(Instance?) -> Instance?` | `HUD.Bottom.WaveCounter` → `HUD.WaveCounter`. |
| `WaveCounter(playerGui: Instance?): TextLabel?` | `(Instance?) -> TextLabel?` | The wave label inside the wave root. |
| `EnsureChainVisible(node: Instance?): number` | `(Instance?) -> number` | Walks up the ancestor chain and makes every hidden `GuiObject` ancestor visible. Returns the number of ancestors it flipped, and **records them** so they can be restored. |
| `ReleaseChain(node: Instance?)` | `(Instance?) -> nil` | Restores **only** the ancestors `EnsureChainVisible` flipped, and only once the ancestor holds no other visible `GuiObject` child. |

**Remotes:** none.

**Critical contract:** `EnsureChainVisible` / `ReleaseChain` are a
**pair**. Call `ReleaseChain` when the feature is done, or shared HUD
sections (`Top`, `Center`, `Bottom`) stay visible for good. The pair is
also how two features can share a section without stealing it from each
other.

---

## MenuPresentation

The shared menu chrome: the dim overlay, the blur, and the open/close
animation. Any panel that is **not** owned by a topbar icon goes through
it.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Open(frame: GuiObject)` | `(GuiObject) -> nil` | Opens a panel: plays the `UiOpen` sound, shows the singleton dim overlay and the `Lighting.MenuDimBlur` blur, and animates the frame in (`ShopAnimations.Open(frame, 'Pop')`). |
| `Close(frame: GuiObject)` | `(GuiObject) -> nil` | Closes a panel and releases the chrome. |
| `SetVisible(frame: GuiObject, visible: boolean)` | `(GuiObject, boolean) -> nil` | The generic form: shows or hides without assuming which side of the transition you are on. |

**Remotes:** none.

**Behaviour notes:**

- The dim overlay (`PlayerGui.MenuDimGui` → `Dim`) and the blur
  (`Lighting.MenuDimBlur`) are **singletons** and the chrome is
  **reference-counted**: they fade out only when the *last* open menu
  closes. A frame destroyed without `Close` is pruned on the next
  recompute.
- `Open` also plays the `UiOpen` UI sound via `UiSoundController.Play`.
- Constants: dim `DisplayOrder = -10`, dim target transparency `0.55`,
  blur target size `8`, chrome tween `0.25s`.

---

## UiSoundController

Personal UI sound playback. Every sound is a **local clone** into the
local `PlayerGui` — nothing is broadcast, so each player hears only their
own UI.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Wires `MouseEnter` → `UiHover` and `Activated` → `UiClick` on every button, using the `DescendantAdded` hook so late-streamed buttons are wired too. Idempotent. |
| `Play(name: string)` | `(string) -> nil` | Plays one named UI sound. **Never throws**; a missing template or a missing `PlayerGui` is a silent no-op. |

**Remotes:** none.

**Behaviour notes:**

- Button wiring is guarded by the `UiSoundWired` attribute, so the same
  button is never wired twice, and the guard dies with the instance (so a
  respawn re-clone rewires cleanly).
- `Play` clones `ReplicatedStorage.Assets.Sfx.<name>` into the local
  `PlayerGui` and assigns it to the SFX sound group.

---

## PromptOwnerFilter

Hides `ProximityPrompt`s that are not for the local player, and hides
every Buy prompt while the local player is carrying something.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `PlayerState` and starts the 4 Hz filter tick plus the 5 s resync. Idempotent. |
| `SetLocalCarry(carriedKind: string?, _carriedName: string?, carriedSteal: boolean?)` | `(string?, string?, boolean?) -> nil` | Sets the local carry state used by the Buy-prompt rule. `carriedName` is accepted and ignored. Called internally from the `PlayerState` handler; exposed for direct driving. |

**Remotes:** listens to `PlayerState` (S→C).

**Behaviour notes:**

- The prompt attributes it reads: `ownerUserId`, `targetUserId`,
  `stealPrompt`, `doorPrompt`, `purchaserUserId`.
- It re-evaluates the whole workspace on a 0.25 s tick **and** forces a
  full resync every 5 s.
- Hiding a prompt sets `Enabled = false`; it never destroys it.

---

## GearShopController

Renders the gear shop from server snapshots and forwards purchase / equip
/ autobuy intents.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `GearShopState` and `GearShopResult`, resolves the `GearShop` gui, and connects the shop prompt. Idempotent. |

**Remotes:** listens to `GearShopState`, `GearShopResult` (S→C). Fires
`GearShopAction` (C→S) with `{Action='Purchase'|'Equip'|'SetAutoBuy', GearId, Enabled?}`.

**Behaviour notes:**

- The 3D gear model comes **only** from `ReplicatedStorage.GearShopPreviews/<gearId>`.
- Rows are clones of the authored `GearTemplate`. The template must start
  hidden.
- It also traces the player's `Backpack` so an owned gear Tool is visible
  in the shop row.

---

## ArenaController

The arena raid menu. It is the one controller that **builds its own GUI in
code** (`ensureStartGui`) rather than resolving a Studio template — but it
also supports a Studio-authored `Main.Arena` panel.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `ArenaState`, `ArenaResult` and `ArenaCombatEvent`; resolves the start gui; wires the buy buttons. Idempotent. |

**Remotes:** listens to `ArenaState`, `ArenaResult`, `ArenaCombatEvent`
(S→C). Fires `ArenaAction` (C→S) with `{Action='Start', Option='Buy1'|'Buy2'|'Buy3'}`.

**Behaviour notes:**

- The client never selects a stage or a price — it sends the *option* the
  player clicked and the server resolves stage, price and eligibility.
- `Buy3` is the free stage-1 entry; `Buy1` is a paid warmup restart;
  `Buy2` is a paid direct restart.

**Test seams:** `_TestReset()`, `_TestScreen(): string`,
`_TestInjectState(loadout, session)`, `_TestStartState(): string`,
`_TestRowText(member): string`, `_TestPriceText(raw): string`,
`_TestHpFraction(member): number`, `_TestWaveText(session): string?`,
`_TestEarnedText(raid): string`.

---

## ArenaResultController

The end-of-raid result panel (`Main.ArenaResult`).

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `ArenaResult` and resolves the panel lazily. Idempotent. |

**Remotes:** listens to `ArenaResult` (S→C).

**Behaviour notes:**

- The panel is **fully server-driven**: the client never decides which
  animals to show. It picks the top rows from the payload and renders
  them.
- The 3D model for each animal row comes from the payload's
  `CombatModel` — the captured actual combat-model clone from
  `ReplicatedStorage.ArenaResultModels/Session_<id>`. It is cloned into
  the row's `ViewportFrame`; the original is never reparented or mutated.
- Viewport fills are **generation-guarded** so a stale render cannot
  overwrite a newer one.

**Test seams:** `_TestReset()`, `_TestOutcomeMessage(outcome, raidComplete): string`,
`_TestLevelText(level): string`, `_TestMoneyText(raw): string`,
`_TestFormatXP(xp): string`, `_TestLevelGainText(before, after): string`,
`_TestXpGainText(xpGained): string`, `_TestWaveText(stage, maxStage): string?`,
`_TestAcceptResult(payload, lastSession): (boolean, string?)`,
`_TestPickCards(animals): { { [string]: any } }`,
`_TestResolveLevelLabel(cardRoot, name): Instance?`.

---

## ArenaCameraImpacts

The client camera shake. It **bends CFrame**, never FOV — so it cannot
fight `StealPresentationController`.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `ArenaCombatEvent` and starts the impact loop. Idempotent. |

**Remotes:** listens to `ArenaCombatEvent` (S→C, broadcast).

**Behaviour notes:**

- The shake is **distance-aware**: full strength inside
  `CameraShake.FullRange` (15 studs), fading to nothing at
  `CameraShake.MaxRange` (30 studs). Beyond that, no shake and no work.
- Amplitude is clamped to `MaxPosition` (0.18 studs) and `MaxRotation`
  (0.012 rad).
- It reads only the `ArenaHit` variant of `ArenaCombatEvent`.

**Test seam:** `_TestFalloff(distance: number): number`.

---

## ArenaHitPresentation

The client-local hit bundle: VFX + sound + damage number, all from the
single authoritative `ArenaHit` packet.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `ArenaCombatEvent` and preloads the mirrored VFX/SFX assets. Idempotent. |

**Remotes:** listens to `ArenaCombatEvent` (S→C, broadcast).

**Behaviour notes:**

- The **damage number is generated in code** — no Studio asset is needed
  for it. Only the VFX clone and the sound need mirrored assets.
- The VFX template is `ReplicatedStorage.Assets.Vfx.HitVfx.Attack1`; the
  client clones the **entire** authored hierarchy and `Emit()`s every
  `ParticleEmitter` recursively.
- The sounds are `ReplicatedStorage.Assets.Arena.Sfx.Attack1..3`, cycled
  by the packet's `SoundIndex`.
- If the mirrors are missing, the hit still works (the damage number
  still pops) and a warn-once fires.
- `ContentProvider:PreloadAsync` is used so the first hit sounds
  identical to the tenth.

**Test seam:** `_TestVfxCleanup(maxLifetime: number): number`.

---

## SellConfirmController

The two-step sell panel (`Main.SellConfirmation`).

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `SellPreviewState` and `SellConfirmResult`. Idempotent. |

**Remotes:** listens to `SellPreviewState`, `SellConfirmResult` (S→C).
Fires `SellConfirmAction` (C→S) with `{AnimalId}`.

**Behaviour notes:**

- The panel is inert without the Studio template — it never generates a
  substitute.
- The cancel button is looked up by the exact authored name **`Cancle`**.
- The rarity gradient is built from the canonical rarity colour plus
  `SellConfig.RarityGradient.LightenT` / `DarkenT`; the `UIGradient` must
  be named exactly `Gradient`.
- The 3D preview uses the `AnimalViewport` pipeline (clone-and-fit) and
  the `AnimalShowcase` camera set. This is a **different** pipeline from
  the rebirth panel's — do not assume they are interchangeable.
- The panel closes on `SellConfirmResult` or on the sell-config timeout,
  whichever comes first.

**Test seams:** `_TestReset()`, `_TestPending(): string?`,
`_TestFormatMutations(mutations): string`,
`_TestFormatName(displayName, trait): string`,
`_TestSellButtonText(raw): string?`,
`_TestRarityBaseColor(rarity): Color3?`,
`_TestShadeLight(color): Color3`, `_TestShadeDark(color): Color3`,
`_TestRarityGradient(base, times): ColorSequence`.

---

## RebirthController

The rebirth panel (`Main.Rebirth`) — requirements, bars, unlock cards and
the action button.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `RebirthState` and `RebirthResult`, binds the HUD rebirth toggle, resolves the panel. Idempotent. |
| `RequestState()` | `() -> nil` | Fires `RebirthAction` with `{Action='State'}`. No-op if the panel cannot be resolved or the remote is missing. |
| `Attempt()` | `() -> nil` | Fires `RebirthAction` with `{Action='Rebirth'}`. No-op if a request is already in flight. The client never selects a rebirth number — the server decides. |

**Remotes:** listens to `RebirthState`, `RebirthResult` (S→C). Fires
`RebirthAction` (C→S). Also reads `PlayerState` (S→C) to refresh.

**Behaviour notes:**

- The money bar fraction is **display-only**: satisfied requirements pin
  to full, otherwise the fraction is clamped to `[0, 1]`. It never
  decides. The fraction is computed with `BigNumber.Divide`, not
  `tonumber`.
- The unlock card's `ImageLabel` mirrors the requirement template's
  `ImageLabel` — the same Studio asset the animal cards use.
- Requirement cards and unlock cards are rendered on **separate
  generations**, so rebuilding one side never invalidates the other's
  in-flight viewport renders.
- The HUD rebirth toggle binds `Activated` **only**. Connecting
  `MouseButton1Click` as well would fire the toggle twice per click.
- The 3D card models come from `ReplicatedStorage.RebirthPreviews` (the
  parked template clones) and, for gear cards, from
  `ReplicatedStorage.GearShopPreviews` by `GearId`.

---

## SlotMenuController

The per-slot interaction menu (sell / upgrade frames). It owns the
**legacy** `PlayerGui.MainGui` panel.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Resolves `MainGui` (**blocking, ~15 s**), then subscribes to the slot-menu remotes and the `PlayerState` carry state. Idempotent. |

**Remotes:** listens to `SlotMenuState`, `SlotMenuResult`,
`PlayerState`, `AnimalLeveledUp` (S→C). Fires `SlotMenuRequest` (C→S)
with `{SlotId, Intent}` and `SlotMenuAction` (C→S) with
`{SlotId, OccupantId, Action='Upgrade'}`.

**Behaviour notes:**

- This is the **only blocking `Init`** in the layer. Everything before it
  in the bootstrap order is instant; everything after it starts ~15 s
  late. Do not move a controller across it.
- The upgrade button is found through `StandResolver.GetStandParts`, not
  a hardcoded GUI path — it works across flat runtime clones, nested
  authored stands and legacy shapes.
- `AnimalLeveledUp` triggers a menu refresh and a local LevelUp sting.

---

## MoneyPoolController

The cash-collection feedback: icons burst from the collection point and
fly to the money counter, which counts up.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `CashCollected` and `PlayerState`, resolves the money counter, starts the flight loop. Idempotent. |

**Remotes:** listens to `CashCollected`, `PlayerState` (S→C).

**Behaviour notes:**

- The client **accumulates** the collected amounts into a visual pool and
  converges on the server's `NewMoney` / `PlayerState` push. It never
  invents a balance.
- There is a single central Heartbeat for the icon flight — not one per
  icon.
- The burst origin is projected from the packet's `Origin` (a world
  position) into screen space.
- The icon template is resolved from a config-driven key; the templates
  live under the money-pool config's asset paths.
- A missing `HUD` money counter makes the whole controller inert (warn
  once).

---

## CodesController

The redeem-codes panel (`Main.Codes`).

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `CodesResult`, resolves the panel, wires the submit button. Idempotent. |

**Remotes:** listens to `CodesResult` (S→C). Fires `CodesAction` (C→S)
with `{Action='Redeem', Code}`.

**Behaviour notes:**

- The client sends the raw text; the server resolves every code from
  `CodesConfig`. The client never knows whether a code is valid.
- Player-facing text and SFX travel on `Notify`, not on `CodesResult`.
- The submit button is disabled while a request is in flight, with a
  5 s backstop that re-enables it if the result never arrives.

---

## DailyRewardsController

The daily-rewards panel (`Main.DailyRewards`).

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `DailyRewardsState` and `DailyRewardsResult`, resolves the panel, wires the cards and the Skip button. Idempotent. |

**Remotes:** listens to `DailyRewardsState`, `DailyRewardsResult` (S→C).
Fires `DailyRewardsAction` (C→S) with `{Action='State'|'Claim', Day?}` and
`ShopAction` (C→S) with `{Action='FunnelPrompt', ...}` for the paid Skip.

**Behaviour notes:**

- A client-sent `Day` is UX/debug only — never authority. The server
  re-resolves it.
- A locked or already-claimed card is **still clickable**. The click
  reaches the server, which rejects it with a warning notification and a
  SFX. Never silent, never trusted client-side.
- Before the first snapshot, labels show `'...'` and the status shows
  `'Loading...'` — never a fake "Claimed".
- A stale snapshot never rolls the UI backwards: the controller compares
  the zero-padded `WeekId` (chronologically sortable), then
  `LastClaimAt`.
- A failed claim changes nothing — the existing authoritative render
  stands.
- The TopbarPlus alert is derived from the **same authoritative snapshot**
  as the cards, and fires exactly once per OFF→ON transition.
- The panel binds from `PlayerGui` alone first; the remote subscription
  and the content arrive afterwards (UI-first, data-second).

---

## PlaytimeRewardsController

The playtime-rewards panel (`Main.PlayTimeRewards`).

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `PlaytimeRewardsState` and `PlaytimeRewardsResult`, resolves the panel, wires the cards and the Skip button. Idempotent. |

**Remotes:** listens to `PlaytimeRewardsState`, `PlaytimeRewardsResult`
(S→C). Fires `PlaytimeRewardsAction` (C→S) with
`{Action='State'|'Claim', Index?}` and `ShopAction` (C→S) with
`{Action='FunnelPrompt', ...}` for the paid Skip.

**Behaviour notes:**

- The same rules as the daily controller: the client-sent `Index` is
  validated but never authoritative; locked cards stay clickable; a
  failed claim changes nothing; the first paint is `'Loading...'`.
- Snapshot ordering uses `Version` — the server's build tick in
  milliseconds, monotonic.
- The playtime countdown runs on a local thread and is display-only.

---

## SettingsController

The settings panel (`Main.Settings`) — the BGM and SFX sliders, the
FastMode toggle, and the music-track management.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `SettingsState`, resolves the panel, wires the sliders and the toggle, and adopts/plays the music tracks. Idempotent. |

**Remotes:** listens to `SettingsState` (S→C). Fires `SaveSettings`
(C→S) with `{Bgm?, Sfx?, FastMode?}`.

**Behaviour notes:**

- `SaveSettings` is **debounced**: it fires on slider release and on
  toggle, never per pixel of drag.
- The sliders drive the **SoundGroup masters**
  (`GameSound` → `BgmSound`), not the individual `Sound.Volume` values.
- `fracFromX` returns `nil` while `AbsoluteSize.X` is 0 (the tick a panel
  opened). The input is **ignored**, not slammed to 0.
- Slider drags share one global `UserInputService.InputChanged`; per
  slider `draggingBgm` / `draggingSfx` flags decide which one is live.
- The panel's GUI refs are re-resolved on **every** call, so an early
  partial pass (frame present, rows still replicating) cannot wedge a
  slider. Wiring itself is once-per-instance.
- The music hierarchy is `SoundService → GameSound (SoundGroup) →
  BgmSound (SoundGroup) → {Bgm, ArenaBgm}`. Exactly one track plays at a
  time; arena mode crossfades (~1 s per leg), never an instant swap.
- Arena mode is detected by `ArenaState` having a `Session` table — not
  by an `Action` field.
- Authored per-track volumes are captured once (`captureBaseVolume`) and
  never destroyed by a transition.

---

## ShopController

The Robux shop panel (`Main.Shop`) — gamepass purchase and the shop
prompt.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Resolves the panel, connects the shop prompt, binds the HUD shop button, and connects the `MarketplaceService` purchase-finished hook. Idempotent. |
| `DebugDump()` | `() -> nil` | Prints a diagnostic dump of the resolved shop state. Intended for Studio debugging. |
| `DebugButtons()` | `() -> nil` | Prints a diagnostic dump of the wired buttons. Intended for Studio debugging. |

**Remotes:** fires `ShopAction` (C→S) with `{Action='SyncGamepass'}` and
`{Action='FunnelPrompt', GamepassId?/ProductId?}`. It **does not listen to
`ShopResult`** — the `ShopResult` remote exists in the registry but this
controller never subscribes to it. Purchase feedback travels on `Notify`.

**Behaviour notes:**

- The shop button on the HUD opens the panel; the purchase flow goes
  through `MarketplaceService` and the server.
- `MarketplaceService.PromptGamePassPurchaseFinished` re-fires
  `{Action='SyncGamepass'}` so the server re-resolves the gamepass
  entitlement without waiting for a rejoin.
- The `FunnelPrompt` ping is **analytics only** — it tells the server a
  Roblox dialog was shown. A missing remote or a failed ping never
  affects the purchase itself.
- `ToastController` is required **lazily** to avoid a circular require at
  load time.

---

## EggTimerController

The server-authoritative egg guarantee countdown on
`Map.CenterPart.BillboardGui.Egg`.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Resolves the billboard, subscribes to the guarantee attributes, and starts the 4 Hz repaint. Idempotent. |

**Remotes:** none. It reads **attributes**:
`Guarantee_<Rarity>_NextAt`, `Guarantee_<Rarity>_Interval`,
`Guarantee_<Rarity>_Revision` on the billboard.

**Behaviour notes:**

- The countdown is **local display only** — it never decides a spawn.
- The `_Revision` attribute is an out-of-order guard: only a revision
  higher than the highest applied one is used.
- There is a legacy fallback at `Workspace.Map.EggTimer.BillboardGui.Frame`.

**Test seam:** `_TestFormat(rarity, rarityHex, timerHex, timeText): string`.

---

## EventController

The world-event countdown on `Map.CenterPart.BillboardGui.Event`.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Resolves the label, reads the event attributes, and starts the 4 Hz repaint. Idempotent. |

**Remotes:** none. It reads the `ReplicatedStorage` attributes
`Event_CurrentId`, `Event_EndAt`, `Event_NextId`, `Event_NextAt`,
`Event_Revision`.

**Behaviour notes:**

- The countdown is local display only — it never decides an event.
- The `Event_Revision` attribute is an out-of-order guard.

**Test seams:** `_TestText(currentId, nextId, remaining): string`,
`_TestFormatTime(totalSeconds): string`.

---

## EventTransitionController

The event start/stop cinematic — FOV zoom, white flash, fade.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `EventTransition`. Idempotent. |

**Remotes:** listens to `EventTransition` (S→C, broadcast).

**Behaviour notes:**

- The packet has two phases: `Prepare` (flash + fade out, then the FOV
  zoom) and `Reveal` (fade back in).
- A `TransitionId` that does not match the active one is **ignored** — a
  stale transition cannot hijack the current one.
- The base FOV is captured live at transition start and restored exactly
  at the end. Cleanup is idempotent.
- The overlay is created in code (a `Frame` in a `ScreenGui` at
  `DisplayOrder = 100`), because it is a full-screen flash, not authored
  content.

**Test seams:** `_TestIsActive(): boolean`, `_TestActiveId(): number?`,
`_TestTimingsFor(payload): any`, `_TestReset()`.

---

## ServerLuckController

The server-luck display.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Reads the `ServerLuck` attribute, paints the luck label, and subscribes to the attribute's change. Idempotent. |

**Remotes:** none. It reads the `ReplicatedStorage.ServerLuck` **attribute**.

**Behaviour notes:**

- Display only. It never influences a roll.
- The fallback text before the server sets the attribute is `'1.0x'`.

**Test seam:** `_TestFormatLuck(luck: any): string`.

---

## TutorialController

The onboarding guide layer — the spotlight, the arrow, the checklist, the
typewriter, the skip button.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `TutorialState`, resolves the HUD, binds the skip button, and starts the 4 Hz checklist repaint. Idempotent. |
| `BuildFallbackBeam(): Beam?` | `() -> Beam?` | Builds a white `Beam` in code. Used when the replicated template carries no `Beam`. |
| `EnsureAttachment(host: Instance?, name: string): Attachment?` | `(Instance?, string) -> Attachment?` | Gets or creates an `Attachment` on a host part, under the given name. |

**Remotes:** listens to `TutorialState` (S→C). Fires `TutorialAction`
(C→S) with `{Action='State'|'Continue'|'Skip'}`.

**Behaviour notes:**

- The tutorial **never advances itself**. It only *reports* the locally
  observed Arena Continue press and the Skip press, as gated intents.
- The `Skip` intent is accepted only while the server holds a matching
  state.
- The target is found via the `CollectionService` tag
  `TutorialTarget_<userId>`. Tags replicate globally, so the client
  follows only its own.
- The spotlight lifts the whole ancestor chain to `ZIndex = 100` (the HUD
  uses `ZIndexBehavior = Sibling`, so a nested button would otherwise
  stay buried under the dimmer). The originals are restored on teardown.
- The spotlight pivots `AnchorPoint` to `(0.5, 0.5)` and compensates
  `Position` so the button does not visibly move.
- The typewriter runs at 0.03 s per character and plays a `Pop` sting per
  character. The `Approved` sting fires exactly once per real step change
  — never on the initial snapshot, never after a skip.
- If `ReplicatedStorage.TutorialBeamTemplate` carries no `Beam`, a
  fallback beam is built; a late-replicating asset template **upgrades**
  the fallback rather than losing to it.
- `_findStarterInFolder` is scoped to **direct** `Model` children of the
  given folder, and excludes any model with a `PickupPrompt` or
  `HatchPrompt`, and any model whose `BuyPrompt` is missing or disabled.

**Test seams:** `_TestTextFor(step, arenaOpen): string?`,
`_TestFindTutorialLabel(root): GuiObject?`,
`_TestChecklistFor(step): any`,
`_TestFindStarterInFolder(folder, here, userId): Model?`,
`_TestTagNameFor(userId): string`,
`_TestSkipPayload(): any`,
`_TestSetTypeInterval(seconds)`, `_TestTypeText(label, text)`,
`_TestResolveSfx(name, rootOverride): string?`,
`_TestEnsureBeam(): Beam?`,
`_TestBeatFor(step, uiOpen, elapsed): (string?, string?)`,
`_TestUpdateSpotlight(button, uiRoot)`, `_TestClearSpotlight()`,
`_TestIsAssetBeam(): boolean`, `_TestResetBeam()`.

---

## ResetProtectionController

The reset-gate presentation — greys out / restores the reset button from
the server's authoritative push.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `ResetProtection`. Idempotent. |

**Remotes:** listens to `ResetProtection` (S→C) with
`{Protected: boolean, Reason?}`.

**Behaviour notes:**

- The server owns the protected state. The client only presents it. The
  client binds no input and never decides whether a reset is allowed.
- `Reason` is one of `'CarryingAnimal'`, `'CarryingEgg'`, `'Stealing'`,
  or `nil`.

**Test seam:** `_TestIsProtected(): boolean`.

---

## StealPresentationController

The thief-only steal camera.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `PlayerState`. Idempotent. |

**Remotes:** listens to `PlayerState` (S→C).

**Behaviour notes:**

- The zoom applies only when **both** `CarriedSteal == true` **and**
  `CarriedKind == 'animal'`. Carrying your own animal never zooms; an
  egg steal keeps the default camera.
- Other players evaluate their own `PlayerState` payloads, so the victim
  and bystanders never zoom.
- The base FOV is captured **live** at steal start (never assumed to be
  70) and restored exactly at steal end. Cleanup is idempotent — delivery,
  cancel, drop, death, reset and disconnect all funnel through it.
- It bends **FOV**, never CFrame — so it cannot fight
  `ArenaCameraImpacts`.

**Test seams:** `_TestIsActive(): boolean`,
`_TestTargetFov(baseFov: number): number`.

---

## ToolLockController

The carry tool lock — prevents using the hotbar while carrying.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Subscribes to `CarryLock`, arms the equip guard, and re-arms it across respawns. Idempotent. |

**Remotes:** listens to `CarryLock` (S→C) with `{Locked: boolean}`.

**Behaviour notes:**

- The lock applies to **any** carry entry (steal, own animal/egg pickup).
  Kind and ownership are irrelevant to the client.
- The lock is purely temporary. Tools are **never** destroyed, moved or
  reassigned.
- The equip guard is re-armed on respawn — a fresh character otherwise
  arrives unguarded.

**Test seam:** `_TestIsLocked(): boolean`.

---

## BatController

The bat PvP input — an instant local swing animation plus the swing
request.

**Exposes:**

| Member | Signature | Notes |
|---|---|---|
| `Init()` | `() -> nil` | Finds the bat tool, hooks it, and hooks the character. Idempotent. |

**Remotes:** fires `BatSwing` (C→S) with **no payload**.

**Behaviour notes:**

- The server resolves the bat, the cooldown, the hitbox and the targets.
  The client **never** claims a hit.
- There is deliberately **no hit-result remote** — the confirmed-hit
  sound is server-mounted on the target. No client-side hit VFX by design.
- The swing animation is a local `AnimationTrack` on the tool
  (`rbxassetid://79224347193775`).

---

## Topbar LocalScripts

`SettingsTopbar.client.lua`, `CodesTopbar.client.lua`,
`DailyTopbar.client.lua` and `PlaytimeTopbar.client.lua` are
**LocalScripts**, not modules. They export nothing and are **not** in the
bootstrap — each runs in its own thread so the icons appear at first
paint.

**What each one does:**

1. Waits for `PlayerGui` (10 s) → `PlayerGui.Main` (10 s) → the panel
   (10 s).
2. Waits for `ReplicatedStorage.Packages` (10 s) → `TopbarPlus` (10 s).
3. Reuses `Icon.getIcon(name)` if the icon already exists, else creates
   one with `Icon.new()`, `setName(name)` and `setImage(imageId)`.
4. Binds `icon.selected` → open the panel, `icon.deselected` → close it.
5. Binds the panel's `TopBar.CloseButton` → `MenuPresentation.Close(frame)`
   **and** `icon:deselect()`.

**Ownership:** each topbar script is the **single owner** of its panel's
open/close. The matching controller (`SettingsController`,
`CodesController`, `DailyRewardsController`, `PlaytimeRewardsController`)
owns only the panel's *content*.

**Icons:**

| Script | Icon name | Image id | Panel |
|---|---|---|---|
| `SettingsTopbar.client` | `Settings` | `10734950309` | `Main.Settings` |
| `CodesTopbar.client` | `Codes` | `10734983868` | `Main.Codes` |
| `DailyTopbar.client` | `DailyRewards` | `10709789505` | `Main.DailyRewards` |
| `PlaytimeTopbar.client` | `PlaytimeRewards` | `10709805144` | `Main.PlayTimeRewards` |

> The image ids are the source game's own asset uploads. A new game must
> replace them with its own.
