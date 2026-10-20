# Analytics — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/FunnelService.lua`

```lua
require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
```

That is the **only** require. `FunnelService` is a leaf module: it
cannot form a require cycle, and nothing may require it from the
bottom.

Roblox services are obtained at runtime, not via `require`:

```lua
local Players = game:GetService('Players')                     -- module load
game:GetService('AnalyticsService')                            -- lazily, inside _defaultSend
```

---

## Other Systems Required

| System | Why | Optional? |
|---|---|---|
| **SharedUtilities** (`ReplicatedStorage.Utility.Debug`) | The only logging path. `Debug.Warn` is used for dropped steps and failed sends. | **Required.** Without it the module fails to load. |

**No other system is required by `FunnelService`.** In particular it
does **not** require `PlayerService`, `EconomyService`, or any
gameplay service — that is deliberate, and it is what keeps the
module cycle-free.

### Systems that call *into* this one (callers, not dependencies)

| System | Call |
|---|---|
| `Tutorials` | `FunnelService:LogStep(player, 'Onboarding', 'TutorialStarted' / 'TutorialCompleted' / 'TutorialSkipped', nil)` |
| `Arena` | `'Arena/ArenaStarted'`, `'Arena/StageProgressed'` (scoped), `'Arena/ArenaCompleted'` |
| `Rebirth` | `'Rebirth/RebirthAttempted'`, `'Rebirth/RebirthRequirementReached'`, `'Rebirth/RebirthSucceeded'` (all scoped) |
| `Upgrades` | `'Upgrade/FirstAnimalUpgraded'`, `'Upgrade/UpgradeSucceeded'`, `'Progression/FirstAnimalUpgraded'` |
| `Economy` | `'Progression/FirstRebirth'`, `'Progression/FirstEggPurchased'` |
| `ShopsAndPurchases` | `'Monetization/ShopItemPrompted'`, `'Monetization/PurchaseConfirmed'`, `'Monetization/ItemGranted'`, `'GalaxyBat/*'`, `'Gamepass/*'` |
| `CodesAndRewards` | `'Rewards/CodeRedeemed'`, `'Rewards/DailyRewardClaimed'`, `'Rewards/PlaytimeRewardClaimed'` |
| `Events` | `'Event/EventParticipated'` (scoped), `'Event/MutationReceived'` |
| `Inventory`, `Items`, `Collectors`, `Stealing`, `BasesAndSlots`, `Animals`, `EggsAndHatching`, `ClientPresentation`, `PlayerData`, `SharedUtilities` | Additional `LogStep` call sites. |

These are all **optional** from `FunnelService`'s point of view —
`FunnelService` works with zero callers.

---

## Remotes

**None.** `FunnelService` creates no remotes and listens to none. It
is a pure server-to-Roblox-telemetry bridge.

The one implicit channel is the Roblox-internal
`AnalyticsService` funnel pipeline, which the platform owns.

---

## Profile Fields Read / Written

**None.** `FunnelService` never touches `ProfileService`, never reads
`profile.Data`, and never writes to it.

The only player identity it uses is `player.UserId`, read
defensively inside a `pcall` (`_userIdOf`).

---

## Required Studio Assets

**None.** `FunnelService` reads no Workspace hierarchy, no
ServerStorage folder, and no Studio-authored instance.

---

## External APIs

| API | Use | Permissions |
|---|---|---|
| `AnalyticsService:LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName)` | Non-onboarding funnel events. | None — telemetry only. Works without any game-settings toggle. |
| `AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)` | The single `Onboarding` funnel. | None. |
| `Players` | `GetPlayers()`, `PlayerAdded`, `PlayerRemoving`. | — |

**No HTTP. No DataStore. No Marketplace.**

### Creator Hub dashboard

Analytics events only attribute in the Creator Hub when a funnel with
the **same name and the same step order** exists in the dashboard.
This is manual setup, not an API call. The service is safe to run with
no dashboard: the send is `pcall`-guarded and the failure is a
`Debug.Warn`.

---

## Initialization Order

```text
1. FunnelService.Start()
     - registers a session for every player already in the server
     - Players.PlayerAdded   -> FunnelService.RegisterSession(player)
     - Players.PlayerRemoving -> FunnelService.ForgetPlayer(userId)
2. Gameplay commit path:
     FunnelService:LogStep(player, '<funnel>', '<step>', metadata)
     (auto-registers a session if the player has none yet)
```

`Start()` is **optional** — `LogStep` lazily calls
`RegisterSession` when a session is missing. It is still worth calling
at boot so the session stamp is set at join time rather than at first
event.

`ForgetPlayer` on `PlayerRemoving` is what bounds memory: it drops
the session stamp and every dedupe key prefixed `"<userId>:"`.
