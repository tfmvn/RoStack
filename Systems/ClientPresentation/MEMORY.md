# ClientPresentation — Engineering Notes

Dense notes for a future agent. Everything here was read out of the source;
nothing is assumed.

---

## Purpose in one line

The client layer of Brainrot Arena: 35 LocalScripts that turn server
snapshots into pixels, and never decide anything themselves.

---

## How the client layer actually works

**Bootstrap.** `bootstrap.client.lua` is the only entry point. It syncs
debug gating, requires every controller module (bodies run, no `Init`),
blocks on `ReplicatedStorage:WaitForChild('CmdrClient')`, blocks on
`Remotes.WaitForReady()`, then calls `Init()` on 28 controllers in a fixed
order. The order exists so remote subscriptions are live *before* any push
can land, and so nothing waits behind `SlotMenuController`'s ~15s `MainGui`
wait. `SlotMenuController` is the only blocking `Init`; everything that
must be instant sits before it.

**Fast-boot topbars.** Four LocalScripts (`SettingsTopbar`, `CodesTopbar`,
`DailyTopbar`, `PlaytimeTopbar`) are deliberately NOT in the bootstrap.
Each `LocalScript` in `StarterPlayerScripts` gets its own thread, so these
bind a TopbarPlus icon as soon as `PlayerGui.Main.<Panel>` and
`ReplicatedStorage.Packages.TopbarPlus` exist. Each is the **single owner**
of its panel's open/close; the matching controller only wires content.

**The rule.** The client never computes a price, a level, a reward,
eligibility, an outcome, or an identity. It sends *intent* and paints what
comes back. The server re-resolves every field. A forging client gains
nothing.

**The no-fallback rule.** `ToastController` creates **no** UI. It delegates
to `HudNotificationController`, which paints the authored
`HUD.Center.Notifications` label. If that is missing, one loud `warn` fires
and the notification is dropped. There is no generated toast stack, no
fallback label, no second ScreenGui. Same posture elsewhere: `RebirthController`
degrades to "no unlock cards" rather than erroring; `SellConfirmController`
is inert without its template.

**Money is a decimal string.** `BigNumber`. Never a float on the wire, never
`tonumber` for display. `BigNumber.Format` / `BigNumber.Divide` are used for
display; the client formats, it never computes value.

---

## Remote contract

Direction: **C→S** = client fires, server resolves. **S→C** = server pushes,
client paints. **B** = broadcast to every client in the server.

| Remote | Dir | Payload | Client sends | Server sends back | Fired by |
|---|---|---|---|---|---|
| `PlayerState` | S→C | `{Money (BigNumber string), BaseId, Slots[] {Id, State='Empty'\|'Reserved'\|'Occupied', OccupantKind='animal'\|'egg', OccupantId}, CarriedKind, CarriedName, CarriedSteal}` | — | per-player snapshot | Server. Drives HUD, money pool, prompt filter, steal camera, slot menu, rebirth refresh. |
| `Notify` | S→C | `{Category, Text}` | — | notification | Server. `ToastController` → `HudNotificationController`. |
| `EggArrived` | S→C | `{SlotId, Rarity}` | — | egg reached a slot | Server → `HUDController.SetSlotEgg`. |
| `AnimalArrived` | S→C | `{SlotId, DisplayName, Rarity}` | — | animal reached a slot | Server → `HUDController.SetSlotAnimal`. |
| `AnimalCarried` | S→C | `{UniqueId, DefinitionId, DisplayName, Rarity}` | — | — | Server. **Handler is a no-op** — wire only. |
| `AnimalPlaced` | S→C | `{UniqueId, SlotId}` | — | — | Server. **Handler is a no-op** — wire only. |
| `EggCarried` | S→C | `{BaseId, SlotId, Rarity}` | — | — | Server. **Handler is a no-op** — wire only. |
| `EggPlaced` | S→C | `{BaseId, SlotId, Rarity}` | — | — | Server. **Handler is a no-op** — wire only. |
| `AnimalLeveledUp` | S→C | `{AnimalId, SlotId, OldLevel, NewLevel, LevelsGained}` | — | — | Server (after the mutation). `SlotMenuController`: menu refresh + a local LevelUp sting. |
| `SlotMenuRequest` | C→S | `{SlotId, Intent}` | `Intent` ∈ `'refresh' \| 'open-upgrade' \| 'refresh-pool' \| 'refresh-push' \| 'refresh-level'` | — | `SlotMenuController`. |
| `SlotMenuState` | S→C | menu snapshot, or `{Valid=false}` | — | — | Server → `SlotMenuController`. |
| `SlotMenuAction` | C→S | `{SlotId, OccupantId, Action='Upgrade'}` | — | — | `SlotMenuController`. Server re-resolves everything. |
| `SlotMenuResult` | S→C | `{SlotId, Success, Error?}` | — | — | Server → `SlotMenuController`. |
| `SellPreviewState` | S→C | `{Valid, AnimalId, Name, Rarity, Trait?, Level, LevelText, GenerationText, Mutations, SellValueRaw?, Model?}` (`{Valid=false, AnimalId, Reason?}` opens nothing) | — | — | Server (after the Sell prompt fires) → `SellConfirmController`. `Model` is the live animal Model for a local viewport clone — never reparented, never mutated. |
| `SellConfirmAction` | C→S | `{AnimalId}` | — | — | `SellConfirmController` Sell button. |
| `SellConfirmResult` | S→C | `{AnimalId, Success, Error?}` | — | — | Server → `SellConfirmController`. |
| `CashCollected` | S→C | `{Amount (string), NewMoney? (string), Icon? (table), Origin? {x,y,z}}` | — | — | Server (after the commit) → `MoneyPoolController`. `Origin` is projected to screen space so icons burst from the button. |
| `ResetProtection` | S→C | `{Protected: boolean, Reason?}` (`'CarryingAnimal'\|'CarryingEgg'\|'Stealing'`, nil when unprotected) | — | — | Server, **on change only** → `ResetProtectionController`. |
| `GearShopAction` | C→S | `{Action='Purchase'\|'Equip'\|'SetAutoBuy', GearId, Enabled?}` | — | — | `GearShopController`. The only client input. |
| `GearShopState` | S→C | `{Money, MoneyText, Rebirth, Gears[] {Id, Name, Description, Price, PriceText, RequiredRebirth, ToolName, Locked, Owned, AutoBuy}}` | — | — | Server (on open + after every mutation) → `GearShopController`. |
| `GearShopResult` | S→C | `{Action, GearId, Success, Error?}` | — | — | Server → `GearShopController`. |
| `ArenaAction` | C→S | `{Action='Start', Option='Buy1'\|'Buy2'\|'Buy3'}` | — | — | `ArenaController`. Buy3 = free stage-1 entry; Buy1 = paid warmup restart; Buy2 = paid direct restart. The server resolves stage and price. |
| `ArenaState` | S→C | `{Progression, Levels, Session?, Loadout?, LastRaid?, Dialogue, Show?}` | — | — | Server (on open + after every mutation) → `ArenaController`, and `SettingsController` (music switching: `Session` present ⇒ arena mode). |
| `ArenaResult` | S→C | `{Action, Success, Error?, SessionId?, RaidComplete?, Outcome? ('Victory'\|'Defeat'), Stage?, MaxStage?, EarnedCash?, EarnedXP?, Animals?[], Eggs?[]}` | — | — | Server → `ArenaResultController`, `ArenaController`, `SettingsController` (`Action=='RaidEnd'` ⇒ back to lobby BGM). `Animals` rows carry `CombatModel` — the captured actual combat-model clone from `ReplicatedStorage.ArenaResultModels/Session_<id>`, the only viewport source. |
| `RebirthAction` | C→S | `{Action='Rebirth'\|'State'}` | — | — | `RebirthController`. The client never selects a rebirth number. |
| `RebirthState` | S→C | `{Current, Next?, Maxed, Money, MoneyRequired, MoneySatisfied, ArenaLevel, ArenaRequired, ArenaSatisfied, Animals[], Unlocks[], StartingCash, MoneyMultiplier, CanRebirth}` | — | — | Server → `RebirthController`. `TemplateModel` = the parked `ReplicatedStorage.RebirthPreviews` clone, the only card viewport source. Gear cards resolve from `ReplicatedStorage.GearShopPreviews` by `GearId`. |
| `RebirthResult` | S→C | `{Success, Rebirth?, Error?}` | — | — | Server → `RebirthController`. A fresh `RebirthState` always follows. |
| `ArenaCombatEvent` | S→C (B) | `{SessionId, StageGeneration?, Event='CombatStarted'\|'CombatantSpawned'\|'Attack'\|'CombatantDied'\|'Victory'\|'Defeat'\|'ArenaHit', ...}` | — | — | Server. The `ArenaHit` packet: `{AttackerId, AttackerTeam, TargetId, TargetTeam, Damage, ImpactPosition (Vector3), AttackIndex (1-5), SoundIndex (1-3), AttackSequence, OwnerUserId}`. Read by `ArenaCameraImpacts` and `ArenaHitPresentation`. |
| `EventTransition` | S→C (B) | `Prepare {Phase='Prepare', Kind='Start'\|'End', EventId, TransitionId, FovMultiplier, FovSeconds, FlashDelaySeconds, FlashInSeconds, FadeOutSeconds, CoverSeconds}` / `Reveal {Phase='Reveal', Kind, EventId, TransitionId}` | — | — | Server → `EventTransitionController`. Unmatched `TransitionId`s are ignored. |
| `BatSwing` | C→S | **no payload** (empty `FireServer`) | — | — | `BatController`. The server resolves the bat, cooldown, hitbox, targets. There is deliberately **no hit-result remote** — the confirmed-hit sound is server-mounted on the target, no hit VFX by design. |
| `CarryLock` | S→C | `{Locked: boolean}` | — | — | Server, on change → `ToolLockController`. |
| `TutorialAction` | C→S | `{Action='State'\|'Continue'}` — **and `'Skip'`** | — | — | `TutorialController`. `Continue` is the locally-observed Arena Continue press; `Skip` is the gated skip intent. Both accepted only while the server holds a matching state. |
| `TutorialState` | S→C | `{Step, EggId?, AnimalId?, SlotId?, BaseId?}` | — | — | Server → `TutorialController`. |
| `CodesAction` | C→S | `{Action='Redeem', Code}` | — | — | `CodesController`. The only client input; the server resolves everything from `CodesConfig`. |
| `CodesResult` | S→C | `{Success, Reason?, Message?, RewardText?}` | — | — | Server → `CodesController`. Player-facing text and SFX travel on `Notify`, not here. |
| `DailyRewardsAction` | C→S | `{Action='State'\|'Claim', Day?}` | — | — | `DailyRewardsController`. A client-sent `Day` is UX/debug only, never authority. |
| `DailyRewardsState` | S→C | `{Day, ClaimableDay?, CanClaim, NextClaimAt, LastClaimAt, DayCount, Days[] {Day, Rewards}}` | — | — | Server → `DailyRewardsController`. |
| `DailyRewardsResult` | S→C | `{Success, Reason?, Message?, Day?, RewardText?}` | — | — | Server → `DailyRewardsController`. |
| `PlaytimeRewardsAction` | C→S | `{Action='State'\|'Claim', Index?}` | — | — | `PlaytimeRewardsController`. A client-sent `Index` is validated but never authoritative. |
| `PlaytimeRewardsState` | S→C | `{PoolId, DayId, Playtime, Completed, Version, Rewards[] {Index, RequiredPlaytime, State, Cash?, Eggs?, Tools?, Animals?}}` | — | — | Server → `PlaytimeRewardsController`. `Version` is the server build tick (ms), monotonic. |
| `PlaytimeRewardsResult` | S→C | `{Success, Reason?, Message?, Index?, RewardText?, State?}` | — | — | Server → `PlaytimeRewardsController`. |
| `SaveSettings` | C→S | `{Bgm?, Sfx?, FastMode?}` | — | — | `SettingsController`, **debounced** — sent on slider release and on toggle, never per pixel. |
| `SettingsState` | S→C | `{Bgm, Sfx, FastMode}` | — | — | Server → `SettingsController`. |
| `ShopAction` | C→S | `{Action='SyncGamepass'}` — and `{Action='FunnelPrompt', GamepassId?/ProductId?}` as an **analytics-only** ping | — | — | `ShopController` (gamepass sync); `DailyRewardsController` / `PlaytimeRewardsController` (funnel ping on the paid Skip). |
| `ShopResult` | S→C | `{Action, Success, Owned?}` | — | — | **In the registry but NOT subscribed by any client script.** `ShopController` never listens to it — purchase feedback travels on `Notify`. |

### Replicated attributes used instead of remotes

| Where | Attribute | Read by |
|---|---|---|
| `ReplicatedStorage` | `ServerLuck` | `ServerLuckController` |
| `ReplicatedStorage` | `Event_CurrentId`, `Event_EndAt`, `Event_NextId`, `Event_NextAt`, `Event_Revision` | `EventController` |
| `Workspace.Map.CenterPart.BillboardGui.Egg` | `Guarantee_<Rarity>_NextAt`, `_Interval`, `_Revision` | `EggTimerController` |
| `ProximityPrompt` | `ownerUserId`, `targetUserId`, `stealPrompt`, `doorPrompt`, `purchaserUserId` | `PromptOwnerFilter` |
| Stand buttons | `slotId`, `maxed` | slot-menu / tutorial resolution |
| Gear rows | `GearId`, `OwnedState`, `AutoBuyState` | `GearShopController` |
| Button wiring guards | `ShopBuyWired`, `ShopToggleWired`, `ShopCloseWired`, `UiSoundWired`, `ShopSkipWired` | prevents double-connect |

---

## Invariants the client enforces

1. **No authority on the client.** No price, level, reward, eligibility, or
   outcome is ever computed locally. Intent only.
2. **The server re-resolves everything it receives.** A forged `Day`, `Index`,
   `Code`, `GearId`, or `Option` is re-derived server-side.
3. **No generated fallback UI.** Missing authored panel ⇒ loud warn + inert
   feature. Never a half-right generated substitute.
4. **A clicked card is never authority.** Daily/Playtime cards stay
   `Active = true` even when locked or claimed — the click reaches the
   server, which rejects it with a warning notification + SFX. Never
   silent, never trusted client-side.
5. **The tutorial never advances itself.** It only *reports* the locally
   observed Arena Continue press and the Skip press through gated intents.
6. **Money converges on the server value.** `MoneyPoolController`
   accumulates `CashCollected.Amount` into a visual pool and converges to
   `NewMoney` / the `PlayerState` push. It never invents a balance.
7. **Steal zoom is thief-only AND animal-only.** `CarriedSteal == true` AND
   `CarriedKind == 'animal'`. Carrying your own animal never zooms; egg
   steals keep the default camera. Other players evaluate their own
   payloads, so the victim and bystanders never zoom.
8. **Camera systems do not overlap.** `ArenaCameraImpacts` bends CFrame;
   `StealPresentationController` bends FOV. They cannot fight.
9. **The base FOV is captured live at steal start**, never assumed to be 70,
   and restored exactly at steal end. Cleanup is idempotent — delivery,
   cancel, drop, death, reset, disconnect all funnel through it.
10. **Menu chrome is reference-counted.** The dim overlay and blur are
    singletons; they fade out only when the last open menu closes. Frames
    destroyed without `Close` are pruned on the next recompute.
11. **The audio hierarchy is exactly one tree.** `SoundService` →
    `GameSound` (SoundGroup, master) → `BgmSound` (SoundGroup) → `Bgm` /
    `ArenaBgm`. Individual `Sound.Volume` stays authored; the sliders drive
    the group masters.
12. **Authored per-track volumes are captured once** and never destroyed by
    transitions. `captureBaseVolume` pins the base on first read — a first
    read after `track.Volume = 0` would lock the base (and every fade
    target) at 0 forever, leaving the track playing but silent.
13. **Exactly one music track plays at a time.** Arena mode crossfades
    (out → 0, swap, in → base, ~1s per leg), never an instant swap, never
    duplicate playback. Missing incoming track ⇒ stay put, never silence
    music by accident.
14. **Only ancestors the client flipped are ever turned back off.**
    `HudTree.EnsureChainVisible` records what it changed;
    `ReleaseChain` restores only those, and only once the ancestor holds no
    other visible `GuiObject` child — shared sections (`Top`, `Center`,
    `Bottom`) are never stolen from other UI.
15. **Notification coalescing.** A single rolling "spam window" in the
    authored HUD; Y-only motion (`_withYOffset`) so repeated notifications
    never stack vertically. Category colour comes from
    `UI.Notify.CategoryColor`.
16. **The tutorial checklist row count follows the step table.** Nothing is
    hardcoded to a fixed count; adding a step is a row-table edit.
17. **A stale snapshot never rolls the UI backwards.** Daily compares
    `WeekId` (zero-padded, chronologically sortable) then `LastClaimAt`;
    Playtime compares `Version` (server build tick, monotonic).
18. **Failed claims change nothing.** The existing authoritative render
    stands. Successful claims carry the complete fresh state in the result
    payload, so the render can neither race nor wait for the state push.
19. **A neutral loading paint, never a fake "Claimed".** Before the first
    snapshot, labels show `'...'` and the status shows `'Loading...'`.
20. **Buttons are wired once per instance.** Attribute guards
    (`UiSoundWired`, `ShopSkipWired`, …) survive re-wiring and die with the
    instance, so a respawn re-clone rewires cleanly via `DescendantAdded`.
21. **The four carry remotes are wired but no-op.** `AnimalCarried`,
    `AnimalPlaced`, `EggCarried`, `EggPlaced` have no-op handlers. The wires
    exist for future feedback, not as a broken feature.
22. **Personal sounds are local-only.** `UiSoundController` and the arena
    hit sounds clone into the local `PlayerGui` (or onto a local anchor
    part). Nothing is `FireAllClients` for UI sounds; each player hears only
    their own.

---

## Error-handling pattern

**The pattern is `pcall` everywhere, plus a `warn` that names the expected
path.** There is no `error()` and no `assert()` in any controller body
(except `MenuPresentation`'s `assert(localPlayer, ...)` and
`UiSoundController`'s `assert(localPlayer, ...)`, both of which fail at
require time if there is no `LocalPlayer`).

Concretely:

- Every `FindFirstChild` / property read is wrapped in `pcall`. A missing
  node yields `nil`, and the caller degrades.
- Every `FireServer` is wrapped in `pcall`. A missing remote means "no
  input", never a crash.
- Every `RemoteEvent.OnClientEvent:Connect` is wrapped in `pcall`.
- Every `tween:Play()`, `Instance:Destroy()`, `Debris:AddItem`,
  `task.delay`, and `task.spawn` body is wrapped.
- **Remote wait:** `folder:WaitForChild(Remotes.Names.X, 10)` inside a
  `pcall`; if it fails or the instance is not a `RemoteEvent`, the
  controller logs a **named** warning and disables that one feature, e.g.
  `'RebirthAction remote missing; rebirths disabled'`. It does not disable
  the whole controller and it does not throw.
- **`Remotes.OnClientEvent(name)`** (the `Signal`-wrapped form) **throws**
  if the remote does not replicate within 10s — it calls `error()` inside
  `Remotes.lua:409`. This is why the `pcall`-style controllers use the
  raw `WaitForChild` form and the `Signal`-style controllers (`ToastController`,
  `StealPresentationController`, `ResetProtectionController`,
  `EventTransitionController`, `PromptOwnerFilter`, `TutorialController`)
  call it inside a `pcall`.
- **Async work is `task.spawn` + `pcall`**, never blocking the caller.
  `RebirthController`, `SettingsController`, `DailyRewardsController`,
  `PlaytimeRewardsController` and `ArenaHitPresentation` all use a
  **UI-first, data-second** split: the panel binds immediately from
  `PlayerGui` alone (never waiting on remotes, profile, base, or animals),
  and the remote subscription is added afterwards. This is deliberate — the
  panel must open even while data is still loading.
- **Generation guards** invalidate stale async work: `paintGeneration` /
  `unlockGeneration` (Rebirth card viewports), `_typeGen` (tutorial
  typewriter), `musicGen` (settings music tweens), `pendingGeneration`
  (HUD / money-pool viewport fills), `expiryPulledFor` (reward countdowns),
  `lastSnapWeekId` / `lastVersion` (reward snapshot ordering).
- **`warn` (not `Debug.Warn`) is used where the failure must be visible
  even with `ClientDebug` off** — e.g. `ToastController` warns that the
  notification was dropped, `ArenaHitPresentation` warns that the VFX mirror
  is missing, `SettingsController` warns that a track has an empty `SoundId`.
  `Debug.Warn` is gated by the debug config; a bare `warn` is not.

---

## Gotchas that will bite you

1. **`SlotMenuController.Init` blocks ~15s.** Anything after it in the
   bootstrap starts late. Put new remote-subscribing controllers before it.
2. **The authored typo `Cancle`.** `SellConfirmation`'s cancel button is
   spelled `Cancle` and the client looks it up by that exact string.
3. **`SetAttribute` returns void.** The trailing `;` after
   `skip:SetAttribute('ShopSkipWired', true)` is **required** — without it
   Lua parses the next line as a call on its result. (The source says this
   was "the original crash".)
4. **The `HudTree` nested-then-flat fallback is a convention, not a
   feature.** Every finder tries the nested path first
   (`HUD.BottomLeft.MoneyCounter`) then the legacy flat path
   (`HUD.MoneyCounter`). Author against the nested path; the flat path
   exists for older Studio versions.
5. **`HUD.Center.Notifications` is plural.** The canonical name is plural;
   `HUD.Center.Notification` (singular) and `HUD.Notifications` are legacy
   fallbacks.
6. **Money is a decimal string everywhere.** `tonumber` on a BigNumber
   string loses precision above 2^53. Use `BigNumber.Format` for display
   and `BigNumber.Divide` for a ratio. `RebirthController` computes the
   money bar as `BigNumber.Divide(state.Money, state.MoneyRequired)`
   because the quotient is small but the operands may not be.
7. **Money bar fraction is display-only.** Satisfied requirements pin to
   full; otherwise the fraction is clamped to `[0,1]`. It never decides.
8. **`ArenaHitPresentation` needs no asset for the damage number.** The
   number is generated in code; only the VFX clone and the sound need
   mirrored assets. Missing mirrors degrade (warn-once) and the hit still
   works.
9. **`ReplicatedStorage` templates cannot play.** A `Sound` under
   `ReplicatedStorage` is a template. `SettingsController` clones it into
   `SoundService` once. `ArenaHitPresentation` clones the SFX onto the
   anchor part instead.
10. **LocalScripts cannot read `ServerStorage`.** Every asset the client
    needs must be mirrored into `ReplicatedStorage` at server boot
    (`Assets.Vfx.HitVfx.Attack1`, `Assets.Arena.Sfx.Attack<n>`,
    `Assets.Sfx.*`).
11. **`ContentProvider:PreloadAsync` in `ArenaHitPresentation`** so the
    first hit sounds identical to the tenth. Async and pcall'd.
12. **The tutorial beam has a procedural fallback.** If
    `ReplicatedStorage.TutorialBeamTemplate` carries no `Beam`, a white
    `Beam` is built in code — and a late-replicating asset template
    **upgrades** the fallback rather than losing to it. Both paths are
    tested by `_TestIsAssetBeam`.
13. **The tutorial's collection tag is per-player.** Tags replicate
    globally, so the client follows only `TutorialTarget_<userId>`. The
    server moves that tag between the player's own models.
14. **`_findStarterInFolder` is scoped to DIRECT Model children** of the
    passed folder. A nested `Base` folder can never leak in. It also
    excludes any model with a `PickupPrompt` or `HatchPrompt` (base-slot
    eggs) and any model whose `BuyPrompt` is missing or disabled.
15. **The tutorial spotlight lifts the ancestor chain.** `ZIndexBehavior`
    is `Sibling`, so a nested button (e.g. `ArenaResult.RightSide.Continue`)
    stays buried under the dimmer unless its parents are lifted to
    `ZIndex = 100` too. The originals are restored on teardown.
16. **The spotlight pivots `AnchorPoint` to (0.5, 0.5)** and compensates
    `Position` so the button does not visibly move — an authored
    `AnchorPoint` of (0,0) would otherwise grow toward the bottom-right.
17. **The tutorial typewrites at 0.03s per character** and plays a `Pop`
    sting per character. The `Approved` sting fires exactly once per real
    step change — never on the initial snapshot, never after a skip.
18. **TopbarPlus `notify()` stacks badge counts.** It must fire exactly
    once per OFF→ON transition, tracked by a `noticeOn` flag. A bare
    `icon:notify()` also clears on icon DESELECT — which would drop the
    alert when the panel closes while the reward is still claimable — so
    the code passes a private never-fired `BindableEvent` and clears only
    via `clearNotices()` on authoritative no-Claimable.
19. **The TopbarPlus alert is derived from the same authoritative snapshot
    as the cards** — never from UI text, never from a drifting local
    boolean, never before the first snapshot.
20. **`SettingsController` re-resolves its GUI refs on every call.** An
    early partial pass (frame present, rows still replicating) must not
    wedge a slider. Wiring itself is once-per-instance (`wiredInputs`).
21. **Slider drags use one global `UserInputService.InputChanged`.**
    Per-slider `draggingBgm` / `draggingSfx` flags decide. `save()` fires
    on `InputEnded`, not per pixel.
22. **`fracFromX` returns `nil` while `AbsoluteSize.X` is 0** (e.g. the
    tick the panel opened). The input is **ignored** — not slammed to 0.
23. **Arena music switches on `ArenaState` having a `Session` table**, not
    on `Action`. Menu open, pre-validation clicks, and rejections carry no
    `Session` and never touch the music.
24. **`RebirthController` renders requirement cards and unlock cards on
    separate generations.** Rebuilding one side must never invalidate the
    other side's in-flight viewport renders.
25. **The unlock card `ImageLabel` mirrors the requirement template's
    `ImageLabel`** — the same Studio asset the animal cards use. No second
    effect, no invented image ids.
26. **The `Rebirth` HUD toggle binds `Activated` only.** Connecting
    `MouseButton1Click` too would fire the toggle twice per physical click
    (net no-op).
27. **`PromptOwnerFilter` also hides every Buy prompt while the local
    player is carrying.** That part depends on `PlayerState`, not on the
    prompt attributes.
28. **`ToolLockController` re-arms the equip guard across respawns.** A
    fresh character otherwise arrives unguarded. Tools are never destroyed,
    moved, or reassigned — the lock is purely temporary.
29. **`CarryLock` locks for ANY carry entry** (steal, own animal/egg
    pickup). Kind and ownership are irrelevant to the client.
30. **The Backpack CoreGui must stay enabled.** Gear Shop Tools live in
    `Player.Backpack` and are equipped through the default hotbar. There
    is no custom hotbar anywhere in the project. The `SetCoreGuiEnabled`
    blockers in `bootstrap.client.lua` are **commented out** — do not
    re-enable them.
31. **The TAB player list is native Roblox leaderstats** (server-side
    `player.leaderstats`). There is no custom player list by design. The
    `PlayerList` CoreGui blocker is also commented out.
32. **`SellConfirmController` and `RebirthController` use two different
    viewport pipelines** (`AnimalViewport` vs `AnimalShowcase` /
    `StandShowcase`). Both clone-and-fit, but they are not the same module.
33. **The tutorial uses `StandResolver.GetStandParts`** to find the real
    runtime `UpgradeButton` across flat runtime clones, nested authored
    stands, and legacy shapes. Do not hardcode a GUI path.
34. **`Debug.IsEnabled(tag)` fails QUIET for an unknown tag.** A tag not in
    `Debug.Tags` simply produces no output — it is not an error.
35. **`Debug.SyncFromDebugConfig` must run before any controller `Init`.**
    `bootstrap.client.lua` does it at line 43, before the first `Init`.
36. **`Remotes.WaitForReady()` on the client `error()`s** if the folder did
    not replicate within 10s. `bootstrap.client.lua` calls it unguarded
    (line 100) — a hard failure, by design.
37. **`Debug.Subsystem.ArenaHitClient` spams a fight** (one line per
    attack). It is off by default for that reason.

---

## The exact PlayerGui hierarchy each controller expects

Author these in Studio. A missing node degrades that one feature; it does
not break the client.

### HUD (canonical — nested first, flat legacy second)

```text
PlayerGui
└── HUD                              (ScreenGui or Frame; must be a GuiObject)
    ├── BottomLeft
    │   ├── MoneyCounter             (TextLabel, or a container with a `Text` TextLabel)
    │   └── ServerLuckCounter        (TextLabel, or a container with a `Text` TextLabel)
    ├── Left
    │   ├── RebirthButton            (GuiButton)
    │   └── ShopButton               (GuiButton)
    ├── Top
    │   └── Tutorial                 (container)
    │       ├── Counter              (TextLabel)  -- "3/10"
    │       └── Steps                (TextLabel)  -- the typewriter instruction line
    ├── Center
    │   └── Notifications            (GuiObject)  -- THE notification target (plural)
    ├── Bottom
    │   └── WaveCounter              (container)
    │       └── Counter              (TextLabel)
    └── TutorialSkip                 (GuiButton)  -- the tutorial skip button
```

Flat legacy fallbacks the resolvers also accept: `HUD.MoneyCounter`,
`HUD.ServerLuckCounter`, `HUD.ServerLuck`, `HUD.RebirthButton`,
`HUD.ShopButton`, `HUD.TutorialSteps` (container with `Steps` → `Step1`
template and a `Title` label), `HUD.Tutorial` (label-ish or container),
`HUD.Center.Notification`, `HUD.Notifications`, `HUD.WaveCounter`.

The tutorial **checklist** lives at `HUD.TutorialSteps` →
`Steps` → `Step1` (the template row) and `HUD.TutorialSteps` → `Title`.
`Step1` is row 1; the rest are clones of it named `Step2`…`Step10`. The
template may carry a text indicator child (named `Circle`, `Bullet`,
`Check`, `Icon`, `Marker`, `Dot`, `Indicator`, or `State`) and a strike
child (named `Strike`, `Strikethrough`, `StrikeThrough`, `Line`, or `Bar`).
When neither exists, the client falls back to prefixing the row text with
`✓ ` / `○ ` and creating a `TutorialStrikeLine` frame on the label.

### Main panels

```text
PlayerGui
└── Main
    ├── Settings
    │   ├── TopBar
    │   │   └── CloseButton          (GuiButton)
    │   └── ScrollingFrame
    │       ├── BackgroundMusic
    │       │   └── Container
    │       │       ├── Bar           (GuiObject; fill is X.Scale of its Size)
    │       │       └── Button        (GuiButton; the slider knob)
    │       ├── GameSound
    │       │   └── Container
    │       │       ├── Bar
    │       │       └── Button
    │       └── FastMode
    │           └── Button            (GuiButton)
    │               └── Text          (TextLabel) -- "ON"/"OFF"
    ├── Codes
    │   ├── TopBar
    │   │   └── CloseButton
    │   ├── CurrentLevel             (TextBox)
    │   └── Continue                 (TextButton) -- submit
    ├── DailyRewards
    │   ├── TopBar
    │   │   └── CloseButton
    │   ├── Items1                   (children GuiButtons named "1".."6")
    │   │   └── each: Day (TextLabel), Name (TextLabel), LockedOverlay (GuiObject)
    │   ├── Items2                   (contains the featured/last-day GuiButton)
    │   ├── Text                     (TextLabel) -- status
    │   └── Skip                     (GuiButton) -- the paid Skip All
    ├── PlayTimeRewards
    │   ├── TopBar
    │   │   └── CloseButton
    │   ├── Items                    (children GuiButtons named "1".."6")
    │   │   └── each: Timer → Text   (TextLabel)
    │   ├── Text                     (TextLabel) -- status
    │   └── Skip                     (GuiButton)
    ├── Shop
    │   ├── TopBar
    │   │   └── CloseButton
    │   └── ScrollingFrame
    ├── Arena
    │   ├── Buy1 / Buy2 / Buy3       (GuiButton, each with a .TextLabel)
    │   ├── WarmupLevel
    │   │   └── Title                (TextLabel)
    │   ├── LastLevel
    │   │   └── Title                (TextLabel)
    │   └── CloseButton
    ├── ArenaResult
    │   ├── Name                     (TextLabel)
    │   ├── AnimalList
    │   │   └── <N>                  (a container per row)
    │   │       ├── Title            (TextLabel)
    │   │       ├── Rarity           (TextLabel)
    │   │       ├── CurrentLevel
    │   │       │   └── Title        (TextLabel)
    │   │       ├── NewLevel
    │   │       │   └── Title        (TextLabel)
    │   │       ├── Level            (TextLabel)
    │   │       ├── XP               (TextLabel)
    │   │       └── Item
    │   │           └── ViewportFrame
    │   └── RightSide
    │       ├── WaveCounter
    │       │   └── Wave             (TextLabel)
    │       ├── Money                (TextLabel)
    │       ├── Eggs
    │       │   └── ScrollingFrame
    │       │       └── Template     (+ Counter, ViewportFrame)
    │       ├── NoEggs               (TextLabel)
    │       └── Continue             (GuiButton)
    ├── SellConfirmation
    │   ├── Sell                     (TextButton, with a .TextLabel)
    │   ├── Cancle                   (TextButton)  <-- AUTHORED TYPO, verbatim
    │   ├── Name                     (TextLabel)
    │   ├── Level                    (TextLabel)
    │   ├── Generation               (TextLabel)
    │   ├── Mutations                (TextLabel)
    │   ├── RarityBox                (Frame)
    │   │   ├── Title                (TextLabel)
    │   │   └── Gradient             (UIGradient, named "Gradient")
    │   └── Item
    │       └── ViewportFrame
    └── Rebirth
        ├── TopBar
        │   ├── Title                (TextLabel)
        │   └── CloseButton          (GuiButton)
        ├── Button                   (GuiButton) -- the Rebirth action
        └── Contents
            ├── Warning              (TextLabel)
            ├── Requirements
            │   ├── Items
            │   │   └── Template     (hidden; cloned per requirement)
            │   │       ├── Name      (TextLabel)
            │   │       ├── Number    (TextLabel)
            │   │       ├── ImageLabel
            │   │       └── ViewportFrame
            │   └── Bars
            │       ├── Money
            │       │   ├── ProgressBar  (GuiObject; fill is X.Scale)
            │       │   └── Text         (TextLabel)
            │       └── ArenaLVL
            │           ├── ProgressBar
            │           └── Text
            └── UnlockItems
                └── Template         (hidden; cloned per unlock)
                    ├── Name          (TextLabel)
                    ├── Number        (TextLabel)
                    ├── ImageLabel
                    └── ViewportFrame
```

### Other PlayerGui roots

```text
PlayerGui
├── GearShop                        (the gear shop panel)
│   └── ScrollingFrame
│       └── GearTemplate            (hidden; cloned per gear)
│           ├── Name
│           ├── Description
│           ├── Button               (GuiButton, with a TextLabel)
│           ├── AutoBuy              (GuiButton)
│           │   ├── AutoBuyImage
│           │   ├── Toggle_ON
│           │   └── Toggle_OFF
│           ├── LockOverlay
│           │   └── RebirthCount
│           └── ViewportFrame
└── MainGui                         (the LEGACY slot menu root; `Main` is also accepted)
    ├── UpgradesFrame
    │   ├── Title, Name, CurrentLevel, NewLevel
    │   ├── UpgradeButton           (with a TextLabel)
    │   └── CloseMenu
    └── SellFrame
        ├── Title, Name, Level, Gen
        ├── SellButton              (with a TextLabel)
        └── CloseMenu
```

### Workspace / ReplicatedStorage

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
│       └── BillboardGui
│           └── Frame
├── ArenaVFX                         (client-local folder the client creates)
├── ArenaBattles                     (the replicated combat models)
├── EggArea
│   └── ActiveEggs                   (direct Model children only)
│       └── each egg: BuyPrompt / PickupPrompt / HatchPrompt (ProximityPrompt)
└── Bgm / ArenaBgm                   (optional; SoundService is searched first)

ReplicatedStorage
├── Remotes                          (the folder; created by the server)
├── Utility/{Remotes,Debug,AudioGroups,BigNumber,AnimalShowcase,AnimalViewport,
│            StandShowcase,StandResolver,ArenaUIState,CenterPartBillboards,RebirthUnlocks}
├── Config/...
├── Packages/TopbarPlus              (Wally package, not in this library)
├── CmdrClient                       (not in this library)
├── Assets
│   ├── Sfx                           (UiHover, UiClick, UiOpen, Pop, Approved, LevelUp, Stealing, ...)
│   ├── Vfx/HitVfx/Attack1           (the arena hit VFX template)
│   └── Arena/Sfx/Attack1..3         (the arena hit sounds)
├── GearShopPreviews/<gearId>        (the only gear visual source)
├── RebirthPreviews                  (the parked stand/animal template clones)
├── ArenaResultModels/Session_<id>   (the captured combat-model clones)
├── TutorialBeamTemplate             (asset 17476697388; a Beam inside it)
├── ServerLuck                       (attribute)
└── Event_CurrentId / Event_EndAt / Event_NextId / Event_NextAt / Event_Revision (attributes)
```

### Audio hierarchy

```text
SoundService
└── GameSound            (SoundGroup — the master)
    └── BgmSound         (SoundGroup — the BackgroundMusic slider)
        ├── Bgm          (Sound, Looped)
        └── ArenaBgm     (Sound, Looped)
```

Individual `Sound.Volume` stays authored. The sliders drive the group
masters: effective music = `GameSound` × `BgmSound` × `Sound`.

---

## What to check first when a panel is dead

1. Is the panel **authored** at the canonical path? (Most "dead panel"
   reports are a missing Studio frame, not a code bug.)
2. Was the controller `Init`ed **before** the remote pushed? Check the
   bootstrap order.
3. Did the remote **exist**? Every controller warns with a named message
   like `'X remote missing; Y disabled'`. Grep the output for `remote
   missing`.
4. Is `Debug.ClientDebug` on? `Debug.Log` output is gated. A bare `warn`
   is not.
5. Is the **ancestor chain** visible? A leaf under a hidden `Top` /
   `Center` / `Bottom` is invisible even when the leaf itself is visible.
   `HudTree.EnsureChainVisible` handles this for features that know they
   need it.
