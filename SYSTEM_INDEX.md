# System Index

Every system found in the source game's `src/` tree, in one table.

**Source game:** Brainrot Arena (Rojo project `p-7`), branch `main`, commit
`5a1cb35`.

**Path convention.** The **Main Entry Point** column gives the *original
Roblox path* — the one the module occupied in the source game, and the one
you must reproduce in your project. Every library `Source/` tree mirrors the
original layout, so `require` calls resolve unchanged.

**Portability grades.**

| Grade | Meaning |
|---|---|
| **A** | **Portable core.** Game-agnostic logic. Copy and point it at your own data. |
| **B** | **Game-specific adapter.** The *content* is Brainrot Arena's (catalogues, prices, GUI paths). Keep the shape, replace the content. |
| **C** | **Platform-bound.** Talks to Roblox services, DataStores, or the Marketplace. Reusable, but not self-contained. |

Most systems are a **mix** — e.g. `Economy` is A for the wallet mechanics and
B for the price ladder. The grade column names the dominant part; the
per-system README splits it further.

**Tests.** "N specs" = the number of TestEZ spec files copied with the
system. **See the caveat below — none of them has been observed passing.**

> ⚠️ **The test suite has never been executed.** "N specs" means *specs exist
> that were written against this code*, not *they were observed green*.
>
> The source game's `TestRunner.server.lua` had two blocking defects (a wrong
> require path, and a `TestEZ.RunBootstrap()` call that does not exist in
> TestEZ 0.4.1). **Both are fixed in the library's own copy**, which is a
> library-authored file. One spec defect remains — `AnimalXP.spec.lua`
> returns a table instead of a function — because the specs are
> byte-identical copies.
>
> The suite also **requires Roblox Studio**: TestEZ is a Roblox-runtime-only
> framework and this repository has no headless Luau runner, so the suite
> was built and verified to build, but not run. See `MEMORY.md` §7.1 and
> `Tests/README.md` §1 and §3.

---

## 1. Systems

| System | Purpose | Main Entry Point | Config | Dependencies | Portability | Tests |
|---|---|---|---|---|---|---|
| **PlayerData** | Owns the player profile: load, reconcile, audit, expose, release. The only module touching `ProfileService`. | `ServerScriptService.PlayerService` | `Config/Economy/Money.lua`, `Config/Systems/Debug.lua` (no own config) | ProfileService (external), Economy, Carry, MutationsAndTraits, `Utility/Remotes` | **A** core + **B** schema | 2 specs |
| **Economy** | The wallet. `EconomyService` (authority), `IncomeService` (cash pools), `ModifierService` (multipliers), `SellService` (selling). | `ServerScriptService.EconomyService` | `Config/Economy/Money.lua`, `Config/Economy/Sell.lua` | PlayerData, Animals, Inventory, Upgrades | **A** engine + **B** price ladder | 4 specs |
| **Inventory** | The unified slot pool. Slot occupancy, the slot menu, and slot mutations. | `ServerScriptService.Base.SlotService` | none of its own | PlayerData, Animals, EggsAndHatching, Economy, BasesAndSlots | **A** | 4 specs |
| **Items** | `GearShopService` — the gear catalogue, purchase, and auto-buy. | `ServerScriptService.GearShop.GearShopService` | `Config/Economy/Gear.lua` | PlayerData, Economy, ShopsAndPurchases | **B** catalogue + **A** flow | 1 spec |
| **Animals** | `AnimalService` (3 286 lines) — owning, placing, upgrading, carrying, and presenting animals. | `ServerScriptService.AnimalService` | `Config/Creatures/Animals.lua` | PlayerData, Inventory, Economy, MutationsAndTraits, Carry, Arena, Tutorials, Analytics | **A** engine + **B** catalogue | 11 specs |
| **EggsAndHatching** | `EggService` + 14 modules — spawn, roll, hatch, guarantee, flight, ambient, contest. | `ServerScriptService.EggService` | `Config/Creatures/Eggs.lua` | PlayerData, Animals, MutationsAndTraits, Inventory, Upgrades | **A** engine + **B** catalogue | 14 specs |
| **MutationsAndTraits** | Trait and mutation catalogues and their application. | `ServerScriptService.TraitService`, `ServerScriptService.MutationService` | `Config/Creatures/{Traits,Mutations,Rarity}.lua`, `Config/RarityConfig.lua` | Animals, EggsAndHatching, Events | **B** content + **A** application | 1 spec |
| **Upgrades** | Animal XP, levels, and upgrade cost. | `ServerScriptService.UpgradeService` | `Config/Creatures/Progression.lua` | PlayerData, Animals, Economy, Inventory | **A** | 3 specs |
| **Rebirth** | The prestige loop: the ladder, the requirement check, the grants, the unlocks. | `ServerScriptService.Rebirth.RebirthService` | `Config/Economy/Rebirth.lua` | PlayerData, Economy, Animals, Inventory, Upgrades | **A** engine + **B** ladder | 1 spec |
| **BasesAndSlots** | `BaseService`, base locking, stand display and presentation, dynamic slot unlocking. | `ServerScriptService.BaseService` | `Config/World/Bases.lua` | PlayerData, Inventory, Animals, EggsAndHatching, Collectors, Notifications | **A** core + **B** base layout | 7 specs |
| **Collectors** | The cash-collect interaction: arrival and feedback. | `ServerScriptService.Base.CollectorArrival`, `ServerScriptService.Base.CollectFeedback` | none of its own | Economy, BasesAndSlots, Animals | **A** | 2 specs |
| **Arena** | The wave/raid loop: `ArenaService`, `ArenaBattleService`, `ArenaProgressionService`. | `ServerScriptService.Arena.ArenaService` | `Config/World/Arena.lua`, `Config/World/ArenaFeel.lua` | PlayerData, Animals, Combat, Inventory, Notifications, Analytics, Events | **A** round logic + **B** enemies/maps/rewards | 7 specs |
| **Combat** | The bat and the ragdoll. | `ServerScriptService.Combat.BatService`, `ServerScriptService.Combat.RagdollService` | `Config/Economy/Gear.lua` (combat tuning) | Arena, Carry, Animals, Analytics | **A** mechanics + **B** tuning | 3 specs |
| **Stealing** | Stealing from other players' bases. | `ServerScriptService.Steal.StealService` | `Config/World/Stealing.lua` | BasesAndSlots, Animals, Inventory, Carry, Notifications | **A** state machine + **B** tuning | 1 spec |
| **Carry** | `CarryRegistry`, `PlayerGrabService`, `ResetProtectionService`, `ToolLockService`. | `ServerScriptService.Carry.CarryRegistry` (+3 siblings) | `Config/World/Prompts.lua` | PlayerData, Animals, BasesAndSlots, Combat, Stealing | **A** | 1 spec |
| **ShopsAndPurchases** | `ShopService` — Marketplace receipts, product/gamepass grants. `DoorService` — the unlock door. | `ServerScriptService.Shop.ShopService` | `Config/Economy/Shop.lua` | PlayerData, Economy, Inventory, Items, Animals | **A** receipt handling + **B** product ids | 3 specs |
| **CodesAndRewards** | `CodesService`, `DailyRewardsService`, `PlaytimeRewardsService`, and the two global content-rotation modules `DailyRewardsWeek` and `PlaytimeRewardsDay`. | `ServerScriptService.Codes.CodesService` (+5 siblings) | `Config/Economy/Rewards.lua` | PlayerData, Economy, Inventory, Animals, EggsAndHatching, Items, Analytics | **A** engine + **B** reward tables | 1 spec |
| **Tutorials** | The onboarding step machine and its signals. | `ServerScriptService.Tutorial.TutorialService` | none of its own | PlayerData, Animals, EggsAndHatching, Inventory, Notifications, Analytics | **A** machine + **B** steps | 1 spec |
| **Notifications** | `NotificationService` + the 134-entry message catalogue. | `ServerScriptService.Base.NotificationService` | `Config/Presentation/Messages.lua` | PlayerData, `Utility/Remotes` | **A** | 1 spec |
| **Analytics** | `FunnelService` — Roblox `AnalyticsService` funnel events, 11 funnels. | `ServerScriptService.FunnelService` | none of its own | Roblox `AnalyticsService` | **C** (platform) + **A** catalog | 1 spec |
| **PlayerLogging** | Discord embed logging and a separate all-time player registry DataStore. | `ServerScriptService.PlayerLogger.PlayerLogger` | `PlayerLoggerConfig.lua` (data only) | PlayerData, Roblox `HttpService`, `DataStoreService` | **C** (platform) | 1 spec |
| **AdminTools** | The admin framework (8 modules) + 68 Cmdr commands + 8 argument types. | `ServerScriptService.Admin.AdminService` | `Config/Systems/Security.lua`, `AdminConfig.lua` | Cmdr (external), PlayerData, Animals, Inventory, Economy, Arena, Codes, Daily, Playtime, Rebirth, Stealing, Carry, Events, Notifications, Analytics | **A** framework + **B** commands | 1 spec |
| **SharedUtilities** | `ServerLuckService`, `SettingsService`, `WaterHazard`, `PathfindingUtil`, icon helpers, and the Presentation/Movement/Debug config. | `ServerScriptService.ServerLuckService` (+3 siblings) | `Config/Presentation/{UI,Audio,Vfx}.lua`, `Config/Systems/Debug.lua`, `Config/World/Movement.lua` | PlayerData, Animals, Economy, EggsAndHatching | **A** | 10 specs |
| **ClientPresentation** | The 35-script client layer and its 28-controller bootstrap. | `StarterPlayer.StarterPlayerScripts.bootstrap.client` | `Config/Presentation/{UI,Audio,Vfx}.lua` | `Utility/Remotes`, every server system it mirrors | **B** GUI paths + **A** controller pattern | 0 specs |
| **Events** | The generic event engine: `EventService`, `EnvironmentModifier`, `EventLights`. | `ServerScriptService.Event.EventService` | `Config/World/Events.lua` | Animals, EggsAndHatching, MutationsAndTraits, Notifications, Analytics | **A** engine + **B** event content | 2 specs |
| **Leaderboards** | `LeaderboardService` (OrderedDataStore) and `TabListService`. | `ServerScriptService.Leaderboard.LeaderboardService` | none of its own | PlayerData, Animals, Economy | **C** (platform) + **A** | 2 specs |

---

## 2. Shared modules

Not owned by any one system. Each has exactly one physical home in
`ReusableSystems/Shared/`, and every system that uses it records that in its
`Dependencies.md`.

### `Shared/Types/` → `ReplicatedStorage.Types`

| Module | Purpose | Status |
|---|---|---|
| `SlotType.lua` | Slot id build/parse, `OccupantKind`/`SlotState` enums, `ArenaSlotIndexBase = 1000`. | Live. |
| `AnimalType.lua` | Animal record shape. | Live. |
| `AnimalDefinitionType.lua` | Animal catalogue definition shape. | Live. |
| `EggType.lua` | Egg record shape. | Live. |
| `BaseType.lua` | Base record shape. | Live. |
| `RarityType.lua` | The 8 rarities, including `Secret`. | Live. |
| `TransactionReason.lua` | Closed enum of 17 money-movement reasons. | Live. |
| `PlayerDataType.lua` | **STALE.** Declares `Cash: number` and 4 fields; the live schema has `Money: string` and 19. Required by nothing. | ⚠️ Stale — see `MEMORY.md` §4.5 |

### `Shared/Utilities/` → `ReplicatedStorage.Utility`

| Module | Purpose |
|---|---|
| `BigNumber.lua` | Hand-rolled arbitrary-precision decimal-string arithmetic. No external dependency. |
| `ConfigValidator.lua` | Registry of 19 config domains + cross-config invariants. `ValidateAll()`, `AssertValid()`. |
| `Debug.lua` | `Debug.Log` / `Debug.Warn`, gated by per-side flags + a tag whitelist. Mutable. |
| `Validation.lua` | Type assertion helpers; re-exports the `t` library. |
| `Signals.lua` | Re-exports the `sleitnick/signal` library. |
| `StudioTestMode.lua` | Gates Studio-only test UserIds (0, negatives). Mutable. |
| `NumberUtils.lua` | Number formatting and clamping helpers. |
| `RichTextFormatter.lua` | Rich-text string building for the UI. |
| `WeightedDraw.lua` | Weighted random selection over a weight table. |
| `AudioGroups.lua` | Audio group / volume constants. |
| `CmdrTypeUtil.lua` | Helpers for writing Cmdr argument types. |

### `Shared/CommonModules/` → `ReplicatedStorage.Utility`

| Module | Purpose |
|---|---|
| `Remotes.lua` | **The remote registry.** `Remotes.Names` (47), `Remotes.Ready` signal, `SetRemotes`/`GetFolder`/`WaitForReady`/`FireClient`/`FireAllClients`/`OnClientEvent`. |
| `OwnedObjectIdentity.lua` | Animal/egg id minting and validation (`AN_`/`EG_` + 10 base-62 chars). |
| `AnimalStats.lua` | Per-rarity stat tables and the stat lookup. |
| `AnimalWeight.lua` | Model weight and scale derivation. |
| `AnimalShowcase.lua` | The showcase/stand model builder. |
| `AnimalViewport.lua` | The `ViewportFrame` renderer (shared by the sell and arena-result views). |
| `ArenaUIState.lua` | The client's arena state machine. |
| `CenterPartBillboards.lua` | Billboard attachment for the egg center. |
| `EggWalkAnimator.lua` | The egg's walk animation. |
| `FloorGeometry.lua` | Floor/stand geometry maths. |
| `RebirthUnlocks.lua` | Which rebirth tier unlocks what. |
| `StandLayout.lua` | Stand slot layout maths. |
| `StandResolver.lua` | Resolves a stand slot to a position. |
| `StandShowcase.lua` | The stand showcase model builder. |
| `StatCalculator.lua` | Derived stat computation (income, damage, health). |
| `ShopAnimations.lua` | GUI open/close tween styles. Lives at `ReplicatedStorage.ShopAnimations` in the source game. |

---

## 3. Categories that are ABSENT

The source game has **no implementation** for these. They are listed so
nobody assumes they were overlooked. Nothing was invented to fill them.

| Suggested category | Status | Where the concern actually lives |
|---|---|---|
| **Gamepasses** | **ABSENT as a system.** | Gamepass entitlement is a branch inside `ShopService` and a `Config/Economy/Shop.lua` entry kind. Extracting a separate service would be a rewrite. |
| **Discord** (as a bot) | **ABSENT.** | The `discord_bot/` Python service is gitignored in the source repo and was never in `src/`. Only the **webhook** side (`PlayerLogging`) is in the library. See `Integrations/Discord/`. |
| **A generic combat/damage framework** | **ABSENT.** | Combat is a bat and a ragdoll (`Combat/`). There is no generic damage pipeline, health system, or stat framework. |
| **A generic backpack/bag inventory** | **ABSENT.** | "Inventory" here is the *stand slot pool* (`Inventory/`), not a backpack. |
| **A generic analytics provider abstraction** | **ABSENT.** | `Analytics/` is `FunnelService` calling Roblox `AnalyticsService` directly. There is no provider interface. See `Integrations/AnalyticsProviders/`. |
| **A generic external-service client** | **ABSENT.** | There is no HTTP-client abstraction. See `Integrations/ExternalServices/`. |
| **A generic notification/channel bus** | **ABSENT.** | `NotificationService` posts to the player's HUD directly. There is no pub/sub bus. |
| **A generic quest/achievement system** | **ABSENT.** | Nothing of the kind exists. |
| **A generic gacha/loot-box framework** | **ABSENT.** | The egg roll is specific to `EggsAndHatching`, not a reusable gamine engine. |
| **A generic localisation system** | **ABSENT.** | The 134 `Messages` entries in `Config/Presentation/Messages.lua` are a message catalogue, not a locale system with fallbacks. |

---

## 4. Third-party packages the systems require

Referenced, **not copied** into this library. Install them with Wally.

| Package | Version | Required by | Required? |
|---|---|---|---|
| `ProfileService` | vendored (`src/Vendored/ProfileService.lua`) | `PlayerData` | **Yes** for `PlayerData` |
| `kineticwallet/janitor` | 1.17.0 | `PlayerData`, `Animals`, others | **Yes** |
| `evaera/cmdr` | 1.12.0 | `AdminTools` | **Yes** for `AdminTools` |
| `sleitnick/signal` | 1.5.0 | `Shared/Utilities/Signals.lua` | **Yes** |
| `osyrisrblx/t` | 2.2.1 | `Shared/Utilities/Validation.lua` | **Yes** |
| `1foreverhd/topbarplus` | 3.4.0 | `ClientPresentation` topbar clients | **Yes** for the topbar UI |
| `roblox/testez` | 0.4.1 | the test suite | Dev only |
| `elttob/fusion` | 0.3.0 | **nothing** | ❌ **Dead dependency** |
| `evaera/promise` | 4.0.0 | **nothing** | ❌ **Dead dependency** |

---

## 5. Files

| Path | Count | What |
|---|---|---|
| `Systems/*/Source/` | 294 files | The implementation, at its original Roblox path. |
| `Systems/*/Tests/` | 85 specs | Distributed by owning system. |
| `Tests/` | 2 files | `_Helpers.lua` (copied) and `TestRunner.server.lua` (library-authored, **fixed**). |
| `Tests/IntegrationTests/` | 4 specs | `Integration`, `InteractionLiveness`, `StandMenu`, `StandPresentation`. |
| `Shared/` | 35 files | Types (8), Utilities (11), CommonModules (16). |
| `Systems/*/Config.lua` | 26 files | Library-authored per-system config index — one per system. |
| `Vendored/` | 1 file | A verbatim third-party copy of `ProfileService` (see its `README.md`). |

**Total: 448 `.lua`/`.luau` files** — 419 copies of `src/` originals
(417 byte-identical, 2 adapted for security), 28 library-authored files
(26 per-system `Config.lua`, 1 `Templates/SystemConfigTemplate.lua`,
1 `Tests/TestRunner.server.lua`), and 1 third-party file
(`Vendored/ProfileService.lua`) — plus 147 documentation files.

The file-by-file audit is in [`EXTRACTION_MANIFEST.md`](EXTRACTION_MANIFEST.md).
The two `src/` files deliberately **not** copied are listed in that
document's §5.7 and in `MEMORY.md` §7.6.
