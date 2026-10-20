# Extraction Manifest

Every file in the source game's `src/` tree, accounted for.

**Source game:** Brainrot Arena — Rojo project `p-7`, branch `main`, commit
`5a1cb35`.

**Audit method.** The `src/` tree was inventoried first (430 files: 421
`.lua`/`.luau` + 9 `.gitkeep` placeholders), then every file was matched
against the library by its original Roblox path. The comparison is
reproducible:

```bash
# every source file
find src -type f | sort

# every library file, normalised back to its original Roblox path
find ReusableSystems/Systems -type f -path '*/Source/*' \
  | sed 's|^ReusableSystems/Systems/[^/]*/Source/||' | sort -u
find ReusableSystems/Shared -type f -name '*.lua' \
  | sed -e 's|^ReusableSystems/Shared/Types/|ReplicatedStorage/Types/|' \
        -e 's|^ReusableSystems/Shared/Utilities/|ReplicatedStorage/Utility/|' \
        -e 's|^ReusableSystems/Shared/CommonModules/|ReplicatedStorage/Utility/|' | sort -u
```

The result: **421 of 421** source `.lua`/`.luau` files are accounted for
(420 `.lua` + 1 `.luau`). The 9 `.gitkeep` placeholders are excluded — they
are empty directory markers, not source.

---

## 1. Summary

| Category | Count |
|---|---|
| Source files in `src/` (`.lua` / `.luau`) | **421** |
| Copied unchanged | **417** |
| Adapted (documented in §3) | **2** |
| Excluded source files | **2** (see §5.7) |
| Library-authored files (no `src/` original) | **28** (see §5.1) |
| Excluded non-source files (`.gitkeep`) | 9 |
| Third-party code, copied verbatim into `Vendored/` | 1 (`src/Vendored/ProfileService.lua` → `ReusableSystems/Vendored/ProfileService.lua`) |

**Nothing from `src/` was left behind without a recorded reason, and nothing
was copied that was not accounted for.**

The arithmetic closes exactly:

```
421 src files  =  417 copied unchanged  +  2 adapted  +  2 excluded
419 library copies  =  417 unchanged  +  2 adapted
419  +  28 authored  +  1 vendored third-party  =  448 library .lua/.luau files
```

### 1.0 The two excluded source files

| `src/` file | Reason | See |
|---|---|---|
| `src/Vendored/ProfileService.lua` | Third-party code — copied verbatim into `ReusableSystems/Vendored/`, not counted as extracted game source. | §1.1, §5.7 |
| `src/Tests/ServerScriptService/TestEZTests/TestRunner.server.lua` | Defective runner — the library ships a **fixed** one. | §5.6, §5.7 |

### 1.1 Why `ProfileService` is third-party, and how it is handled

`src/Vendored/ProfileService.lua` is a **third-party** library (the
standalone ProfileService by MadworkRoblox, MIT) vendored into the source
repo so the build has no Wally dependency on it. It is:

- not part of the game author's own code,
- a moving upstream dependency that should be tracked by version, not
  hand-copied into a documentation library,
- and already available on Wally.

**It is NOT part of the extraction accounting.** It is neither a "copied
game source file" nor an "excluded game source file" — it is third-party
code with its own home.

**How the library handles it:** a **verbatim copy** lives at
`ReusableSystems/Vendored/ProfileService.lua`, with a `README.md` beside it
explaining the licence, the upstream URL, and how to replace it. The copy
exists for one concrete reason: `ReusableSystems/test.project.json` and
`ReusableSystems/Examples/MinimalGame/minimalgame.project.json` both need
a `ProfileService` instance to build, and pointing them at
`../src/Vendored/ProfileService.lua` would make the library depend on the
production source tree — so the library would stop building the moment it
was copied into a different repository.

The file is **byte-identical** to the source game's copy; it was not
modified.

**Action for a new game:** delete `ReusableSystems/Vendored/` and
`wally install` ProfileService instead, or keep the vendored copy. Either
way the only requirement is a module named `ProfileService` at
`ServerScriptService.Packages.ProfileService` — the library's
`Systems/PlayerData/Dependencies.md` records the exact require path.

### 1.2 What was **not** copied from the repository

These are outside `src/` and are not part of the library:

| Path | Why excluded |
|---|---|
| `Packages/`, `ServerPackages/`, `DevPackages/` | Wally install output. Gitignored; rebuilt by `wally install`. |
| `sourcemap.json` | Rojo debug artefact. Gitignored. |
| `.history/` | Editor auto-backup. Committed upstream by mistake; not source. |
| `ignore/prompt.md` | A pasted phase prompt. Not source. |
| `discord_bot/` | A separate Python service. Gitignored; never in `src/`. |
| `Docs/` | The source game's own documentation, 45 files — several of them **stale** (see `MEMORY.md` §7.5). The library's documentation was written from the code instead. |
| `scripts/` | One-off investigation scripts. Not source. |
| `.vscode/` | Editor settings. |

---

## 2. How the library is laid out

Each system owns its files:

```text
Systems/<Name>/
├── Source/<original Roblox path>   ← the implementation, unmodified
└── Tests/<name>.spec.lua           ← the specs that cover it
```

Shared modules that belong to no single system live in one place:

```text
Shared/
├── Types/          → ReplicatedStorage.Types
├── Utilities/      → ReplicatedStorage.Utility
└── CommonModules/  → ReplicatedStorage.Utility
```

**One physical home per file.** Nothing is duplicated. Where two systems use
the same module, the usage is recorded in both systems' `Dependencies.md` and
in `DEPENDENCY_MAP.md` §5 — not by making two copies.

---

## 3. The two adapted files

Both adaptations were required by the rule *"Secrets must never be included
in the library"* and by the rule *"Do not break, rewrite, or otherwise modify
the working production game"*. **The production files were not touched** —
only the library copies differ. Both are also recorded in
`SECURITY_NOTES.md`.

### 3.1 `ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua`

| | |
|---|---|
| **Change** | The `WebhookAttribute` field held a **live Discord webhook URL** as a string literal. It now holds the **attribute name** `'PlayerLoggerWebhookUrl'`. |
| **Why** | (a) A live credential must never ship in a reusable library. (b) The consuming code at `PlayerLogger.lua:267` does `ServerScriptService:GetAttribute(Config.WebhookAttribute)` — it expects a *name*. With a URL in the field, the lookup never matched and Discord delivery was permanently dead. The library copy is therefore also **functionally correct**, where the source was not. |
| **Behaviour delta** | The library copy *can* deliver to Discord if the attribute is set in Studio. The source copy never can. The default (attribute absent) is identical in both: registry-only mode, one warning, no error. |
| **Production file** | Unchanged. `src/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua:30` still holds the URL. **It should be rotated** — see `SECURITY_NOTES.md` §5, S-1. |

### 3.2 `ServerScriptService/Admin/AdminConfig.lua`

| | |
|---|---|
| **Change** | `AdminConfig.Admins` held 5 live `superadmin` entries (2 real userIds + the Studio test ids `0`, `1`, `2`). It is now **empty**. The docstring's claim that "the prod list is intentionally empty here" — which was false — was corrected. |
| **Why** | (a) Real userIds are private identifiers. (b) Granting `superadmin` to userId `0` with **no `IsStudio()` gate** is a privilege-escalation hole in any published place. An empty allowlist is the safe default. |
| **Behaviour delta** | The library copy grants admin to nobody until you add someone. The source copy grants `superadmin` to two named accounts and to three Studio ids. |
| **Production file** | Unchanged. `src/ServerScriptService/Admin/AdminConfig.lua:43-47` still holds the entries. |

### 3.3 Documentation-only additions

Files created by this task, which have no counterpart in `src/`:

| Path | What |
|---|---|
| `ReusableSystems/README.md` | Root entry point. |
| `ReusableSystems/MEMORY.md` | The master engineering knowledge document. |
| `ReusableSystems/SYSTEM_INDEX.md` | Every system in one table. |
| `ReusableSystems/DEPENDENCY_MAP.md` | Dependencies, init order, Mermaid graph. |
| `ReusableSystems/EXTRACTION_MANIFEST.md` | This file. |
| `ReusableSystems/PROJECT_SETUP.md` | Rojo integration. |
| `ReusableSystems/SECURITY_NOTES.md` | Secrets and trust boundaries. |
| `ReusableSystems/Systems/*/{README,MEMORY,Dependencies,Setup,API}.md` | Per-system documentation. |
| `ReusableSystems/Systems/*/Config.lua` | Per-system config consolidation views. |
| `ReusableSystems/Templates/*` | Templates for a new system. |
| `ReusableSystems/Tests/{_Helpers.lua,TestRunner.server.lua,README.md}` | The cross-cutting suite. |
| `ReusableSystems/Examples/*` | A minimal game and an integration walkthrough. |
| `ReusableSystems/library.project.json` | A standalone Rojo project for the library. |

---

## 4. File-by-file manifest

`Original path` is the path in the source game's Roblox tree.
`System` is the owning system in this library.
`Library path` is where it lives now.
`Status` is `copied-unchanged` or `adapted` (§3).

| `ReplicatedStorage/Config/Creatures/Animals.lua` | Animals | `Systems/Animals/Source/ReplicatedStorage/Config/Creatures/Animals.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Creatures/Eggs.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ReplicatedStorage/Config/Creatures/Eggs.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Creatures/Mutations.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Mutations.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Creatures/Progression.lua` | Upgrades | `Systems/Upgrades/Source/ReplicatedStorage/Config/Creatures/Progression.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Creatures/Rarity.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Rarity.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Creatures/Traits.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/Creatures/Traits.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Gear.lua` | Combat | `Systems/Combat/Source/ReplicatedStorage/Config/Economy/Gear.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Money.lua` | Economy | `Systems/Economy/Source/ReplicatedStorage/Config/Economy/Money.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Rebirth.lua` | Rebirth | `Systems/Rebirth/Source/ReplicatedStorage/Config/Economy/Rebirth.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Rewards.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ReplicatedStorage/Config/Economy/Rewards.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Sell.lua` | Economy | `Systems/Economy/Source/ReplicatedStorage/Config/Economy/Sell.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Economy/Shop.lua` | ShopsAndPurchases | `Systems/ShopsAndPurchases/Source/ReplicatedStorage/Config/Economy/Shop.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Presentation/Audio.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/Audio.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Presentation/Messages.lua` | Notifications | `Systems/Notifications/Source/ReplicatedStorage/Config/Presentation/Messages.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Presentation/UI.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/UI.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Presentation/Vfx.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Presentation/Vfx.lua` | copied-unchanged |
| `ReplicatedStorage/Config/RarityConfig.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ReplicatedStorage/Config/RarityConfig.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Systems/Debug.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | copied-unchanged |
| `ReplicatedStorage/Config/Systems/Security.lua` | AdminTools | `Systems/AdminTools/Source/ReplicatedStorage/Config/Systems/Security.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Arena.lua` | Arena | `Systems/Arena/Source/ReplicatedStorage/Config/World/Arena.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/ArenaFeel.lua` | Arena | `Systems/Arena/Source/ReplicatedStorage/Config/World/ArenaFeel.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Bases.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ReplicatedStorage/Config/World/Bases.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Events.lua` | Events | `Systems/Events/Source/ReplicatedStorage/Config/World/Events.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Movement.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ReplicatedStorage/Config/World/Movement.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Prompts.lua` | Carry | `Systems/Carry/Source/ReplicatedStorage/Config/World/Prompts.lua` | copied-unchanged |
| `ReplicatedStorage/Config/World/Stealing.lua` | Stealing | `Systems/Stealing/Source/ReplicatedStorage/Config/World/Stealing.lua` | copied-unchanged |
| `ReplicatedStorage/Types/AnimalDefinitionType.lua` | Shared | `Shared/Types/AnimalDefinitionType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/AnimalType.lua` | Shared | `Shared/Types/AnimalType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/BaseType.lua` | Shared | `Shared/Types/BaseType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/EggType.lua` | Shared | `Shared/Types/EggType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/PlayerDataType.lua` | Shared | `Shared/Types/PlayerDataType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/RarityType.lua` | Shared | `Shared/Types/RarityType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/SlotType.lua` | Shared | `Shared/Types/SlotType.lua` | copied-unchanged |
| `ReplicatedStorage/Types/TransactionReason.lua` | Shared | `Shared/Types/TransactionReason.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/AnimalShowcase.lua` | Shared | `Shared/CommonModules/AnimalShowcase.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/AnimalStats.lua` | Shared | `Shared/CommonModules/AnimalStats.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/AnimalViewport.lua` | Shared | `Shared/CommonModules/AnimalViewport.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/AnimalWeight.lua` | Shared | `Shared/CommonModules/AnimalWeight.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/ArenaUIState.lua` | Shared | `Shared/CommonModules/ArenaUIState.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/AudioGroups.lua` | Shared | `Shared/Utilities/AudioGroups.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/BigNumber.lua` | Shared | `Shared/Utilities/BigNumber.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/CenterPartBillboards.lua` | Shared | `Shared/CommonModules/CenterPartBillboards.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/CmdrTypeUtil.lua` | Shared | `Shared/Utilities/CmdrTypeUtil.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/ConfigValidator.lua` | Shared | `Shared/Utilities/ConfigValidator.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/Debug.lua` | Shared | `Shared/Utilities/Debug.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/EggWalkAnimator.lua` | Shared | `Shared/CommonModules/EggWalkAnimator.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/FloorGeometry.lua` | Shared | `Shared/CommonModules/FloorGeometry.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/NumberUtils.lua` | Shared | `Shared/Utilities/NumberUtils.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/OwnedObjectIdentity.lua` | Shared | `Shared/CommonModules/OwnedObjectIdentity.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/RebirthUnlocks.lua` | Shared | `Shared/CommonModules/RebirthUnlocks.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/Remotes.lua` | Shared | `Shared/CommonModules/Remotes.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/RichTextFormatter.lua` | Shared | `Shared/Utilities/RichTextFormatter.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/ShopAnimations.lua` | Shared | `Shared/CommonModules/ShopAnimations.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/Signals.lua` | Shared | `Shared/Utilities/Signals.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/StandLayout.lua` | Shared | `Shared/CommonModules/StandLayout.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/StandResolver.lua` | Shared | `Shared/CommonModules/StandResolver.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/StandShowcase.lua` | Shared | `Shared/CommonModules/StandShowcase.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/StatCalculator.lua` | Shared | `Shared/CommonModules/StatCalculator.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/StudioTestMode.lua` | Shared | `Shared/Utilities/StudioTestMode.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/Validation.lua` | Shared | `Shared/Utilities/Validation.lua` | copied-unchanged |
| `ReplicatedStorage/Utility/WeightedDraw.lua` | Shared | `Shared/Utilities/WeightedDraw.lua` | copied-unchanged |
| `ServerScriptService/Action/SlotActionHandler.lua` | Inventory | `Systems/Inventory/Source/ServerScriptService/Action/SlotActionHandler.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminArgs.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminArgs.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminAudit.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminAudit.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminConfig.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminConfig.lua` | **adapted** |
| `ServerScriptService/Admin/AdminDelivery.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminDelivery.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminNotify.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminNotify.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminRateLimit.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminRateLimit.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminService.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminService.lua` | copied-unchanged |
| `ServerScriptService/Admin/AdminTargetResolver.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Admin/AdminTargetResolver.lua` | copied-unchanged |
| `ServerScriptService/Animal/AnimalOverhead.lua` | Animals | `Systems/Animals/Source/ServerScriptService/Animal/AnimalOverhead.lua` | copied-unchanged |
| `ServerScriptService/Animal/CarryController.lua` | Animals | `Systems/Animals/Source/ServerScriptService/Animal/CarryController.lua` | copied-unchanged |
| `ServerScriptService/Animal/CarryPrompts.lua` | Animals | `Systems/Animals/Source/ServerScriptService/Animal/CarryPrompts.lua` | copied-unchanged |
| `ServerScriptService/Animal/LevelUpPresentation.lua` | Animals | `Systems/Animals/Source/ServerScriptService/Animal/LevelUpPresentation.lua` | copied-unchanged |
| `ServerScriptService/Animal/SlotMath.lua` | Inventory | `Systems/Inventory/Source/ServerScriptService/Animal/SlotMath.lua` | copied-unchanged |
| `ServerScriptService/Animal/WalkController.lua` | Animals | `Systems/Animals/Source/ServerScriptService/Animal/WalkController.lua` | copied-unchanged |
| `ServerScriptService/AnimalService.lua` | Animals | `Systems/Animals/Source/ServerScriptService/AnimalService.lua` | copied-unchanged |
| `ServerScriptService/Arena/ArenaBattleService.lua` | Arena | `Systems/Arena/Source/ServerScriptService/Arena/ArenaBattleService.lua` | copied-unchanged |
| `ServerScriptService/Arena/ArenaProgressionService.lua` | Arena | `Systems/Arena/Source/ServerScriptService/Arena/ArenaProgressionService.lua` | copied-unchanged |
| `ServerScriptService/Arena/ArenaService.lua` | Arena | `Systems/Arena/Source/ServerScriptService/Arena/ArenaService.lua` | copied-unchanged |
| `ServerScriptService/Base/BaseLockService.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/Base/BaseLockService.lua` | copied-unchanged |
| `ServerScriptService/Base/CollectFeedback.lua` | Collectors | `Systems/Collectors/Source/ServerScriptService/Base/CollectFeedback.lua` | copied-unchanged |
| `ServerScriptService/Base/CollectorArrival.lua` | Collectors | `Systems/Collectors/Source/ServerScriptService/Base/CollectorArrival.lua` | copied-unchanged |
| `ServerScriptService/Base/DynamicSlotService.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/Base/DynamicSlotService.lua` | copied-unchanged |
| `ServerScriptService/Base/LaserAnimation.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/Base/LaserAnimation.lua` | copied-unchanged |
| `ServerScriptService/Base/NotificationService.lua` | Notifications | `Systems/Notifications/Source/ServerScriptService/Base/NotificationService.lua` | copied-unchanged |
| `ServerScriptService/Base/PersistenceAudit.lua` | PlayerData | `Systems/PlayerData/Source/ServerScriptService/Base/PersistenceAudit.lua` | copied-unchanged |
| `ServerScriptService/Base/PlayerBoard.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/Base/PlayerBoard.lua` | copied-unchanged |
| `ServerScriptService/Base/SlotService.lua` | Inventory | `Systems/Inventory/Source/ServerScriptService/Base/SlotService.lua` | copied-unchanged |
| `ServerScriptService/Base/StandDisplayService.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/Base/StandDisplayService.lua` | copied-unchanged |
| `ServerScriptService/BaseService.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/BaseService.lua` | copied-unchanged |
| `ServerScriptService/Carry/CarryRegistry.lua` | Carry | `Systems/Carry/Source/ServerScriptService/Carry/CarryRegistry.lua` | copied-unchanged |
| `ServerScriptService/Carry/PlayerGrabService.lua` | Carry | `Systems/Carry/Source/ServerScriptService/Carry/PlayerGrabService.lua` | copied-unchanged |
| `ServerScriptService/Carry/ResetProtectionService.lua` | Carry | `Systems/Carry/Source/ServerScriptService/Carry/ResetProtectionService.lua` | copied-unchanged |
| `ServerScriptService/Carry/ToolLockService.lua` | Carry | `Systems/Carry/Source/ServerScriptService/Carry/ToolLockService.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/addAdmin.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/addAdmin.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/addAdminServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/addAdminServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/adminLog.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/adminLog.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/adminLogServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/adminLogServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/announce.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/announce.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/announceServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/announceServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/arenaInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/arenaInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/arenaInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/arenaInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/baseInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/baseInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/baseInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/baseInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/bring.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/bring.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/bringServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/bringServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelArena.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelArena.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelArenaServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelArenaServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelCarry.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelCarry.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelCarryServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelCarryServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelSteal.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelSteal.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/cancelStealServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/cancelStealServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/carryInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/carryInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/carryInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/carryInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/clearMoneyMultiplier.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/clearMoneyMultiplier.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/clearMoneyMultiplierServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/clearMoneyMultiplierServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/codeInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/codeInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/codeInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/codeInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/dailyClaim.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/dailyClaim.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/dailyClaimServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/dailyClaimServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/dailyInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/dailyInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/dailyInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/dailyInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/deliverPending.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/deliverPending.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/deliverPendingServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/deliverPendingServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/eggStatus.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/eggStatus.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/eggStatusServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/eggStatusServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/event.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/event.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/eventServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/eventServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/fly.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/fly.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/flyServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/flyServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/forceRebirth.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/forceRebirth.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/forceRebirthServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/forceRebirthServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/getPlayerStats.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/getPlayerStats.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/getPlayerStatsServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/getPlayerStatsServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/getstats.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/getstats.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/getstatsServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/getstatsServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveAllGear.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveAllGear.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveAllGearServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveAllGearServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveAnimal.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveAnimal.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveAnimalServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveAnimalServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveArenaWin.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveArenaWin.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveArenaWinServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveArenaWinServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveArenaXp.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveArenaXp.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveArenaXpServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveArenaXpServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveCash.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveCash.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveCashServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveCashServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveEgg.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveEgg.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveEggServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveEggServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveGear.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveGear.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveGearServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveGearServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveMoney.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveMoney.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/giveMoneyServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/giveMoneyServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/givexp.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/givexp.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/givexpServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/givexpServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/killCenterEgg.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/killCenterEgg.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/killCenterEggServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/killCenterEggServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listAnimals.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listAnimals.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listAnimalsServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listAnimalsServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listCenterEggs.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listCenterEggs.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listCenterEggsServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listCenterEggsServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listCodes.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listCodes.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listCodesServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listCodesServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listGear.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listGear.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listGearServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listGearServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listPlayers.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listPlayers.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/listPlayersServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/listPlayersServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/lockBase.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/lockBase.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/lockBaseServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/lockBaseServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/luck.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/luck.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/luckServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/luckServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/playtimeClaim.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/playtimeClaim.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/playtimeClaimServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/playtimeClaimServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/playtimeInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/playtimeInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/playtimeInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/playtimeInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/ragdoll.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/ragdoll.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/ragdollServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/ragdollServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/rebirthInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/rebirthInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/rebirthInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/rebirthInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/redeemCode.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/redeemCode.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/redeemCodeServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/redeemCodeServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeAdmin.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeAdmin.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeAdminServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeAdminServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeAnimal.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeAnimal.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeAnimalServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeAnimalServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeEgg.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeEgg.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/removeEggServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/removeEggServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetArena.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetArena.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetArenaServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetArenaServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetCash.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetCash.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetCashServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetCashServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetPlayer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetPlayer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/resetPlayerServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/resetPlayerServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/sellAnimal.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/sellAnimal.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/sellAnimalServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/sellAnimalServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setAnimalLevel.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setAnimalLevel.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setAnimalLevelServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setAnimalLevelServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setCash.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setCash.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setCashServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setCashServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setLevel.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setLevel.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setLevelServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setLevelServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setMoney.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setMoney.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setMoneyMultiplier.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setMoneyMultiplier.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setMoneyMultiplierServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setMoneyMultiplierServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/setMoneyServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/setMoneyServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/shutdown.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/shutdown.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/shutdownServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/shutdownServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/slowmode.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/slowmode.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/slowmodeServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/slowmodeServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/spawnEgg.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/spawnEgg.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/spawnEggServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/spawnEggServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/speed.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/speed.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/speedServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/speedServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/standInfo.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/standInfo.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/standInfoServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/standInfoServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/startArena.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/startArena.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/startArenaServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/startArenaServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/takeCash.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/takeCash.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/takeCashServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/takeCashServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/teleportToBase.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/teleportToBase.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/teleportToBaseServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/teleportToBaseServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/tell.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/tell.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/tellServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/tellServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/tp.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/tp.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/tpServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/tpServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/unlockBase.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/unlockBase.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/unlockBaseServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/unlockBaseServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/unragdoll.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/unragdoll.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/unragdollServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/unragdollServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/wipePlayer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/wipePlayer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Commands/wipePlayerServer.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Commands/wipePlayerServer.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/adminTarget.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/adminTarget.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/animalDef.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/animalDef.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/arenaOption.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/arenaOption.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/codeId.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/codeId.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/eggRarity.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/eggRarity.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/gearId.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/gearId.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/mutationList.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/mutationList.lua` | copied-unchanged |
| `ServerScriptService/Cmdr/Server/Types/traitId.lua` | AdminTools | `Systems/AdminTools/Source/ServerScriptService/Cmdr/Server/Types/traitId.lua` | copied-unchanged |
| `ServerScriptService/Codes/CodesService.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ServerScriptService/Codes/CodesService.lua` | copied-unchanged |
| `ServerScriptService/Combat/BatService.lua` | Combat | `Systems/Combat/Source/ServerScriptService/Combat/BatService.lua` | copied-unchanged |
| `ServerScriptService/Combat/RagdollService.lua` | Combat | `Systems/Combat/Source/ServerScriptService/Combat/RagdollService.lua` | copied-unchanged |
| `ServerScriptService/Daily/DailyRewardsService.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ServerScriptService/Daily/DailyRewardsService.lua` | copied-unchanged |
| `ServerScriptService/Daily/DailyRewardsWeek.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ServerScriptService/Daily/DailyRewardsWeek.lua` | copied-unchanged |
| `ServerScriptService/EconomyService.lua` | Economy | `Systems/Economy/Source/ServerScriptService/EconomyService.lua` | copied-unchanged |
| `ServerScriptService/Egg/AmbientService.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/AmbientService.lua` | copied-unchanged |
| `ServerScriptService/Egg/Catalog.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/Catalog.lua` | copied-unchanged |
| `ServerScriptService/Egg/Constants.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/Constants.lua` | copied-unchanged |
| `ServerScriptService/Egg/EggOverhead.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/EggOverhead.lua` | copied-unchanged |
| `ServerScriptService/Egg/EggSpawned.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/EggSpawned.lua` | copied-unchanged |
| `ServerScriptService/Egg/FlightController.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/FlightController.lua` | copied-unchanged |
| `ServerScriptService/Egg/GuaranteeService.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/GuaranteeService.lua` | copied-unchanged |
| `ServerScriptService/Egg/HoverMath.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/HoverMath.lua` | copied-unchanged |
| `ServerScriptService/Egg/ModelBuilder.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/ModelBuilder.lua` | copied-unchanged |
| `ServerScriptService/Egg/Placement.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/Placement.lua` | copied-unchanged |
| `ServerScriptService/Egg/RareEggNotifier.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/RareEggNotifier.lua` | copied-unchanged |
| `ServerScriptService/Egg/RollController.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/RollController.lua` | copied-unchanged |
| `ServerScriptService/Egg/SpawnService.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/Egg/SpawnService.lua` | copied-unchanged |
| `ServerScriptService/EggService.lua` | EggsAndHatching | `Systems/EggsAndHatching/Source/ServerScriptService/EggService.lua` | copied-unchanged |
| `ServerScriptService/Event/EnvironmentModifier.lua` | Events | `Systems/Events/Source/ServerScriptService/Event/EnvironmentModifier.lua` | copied-unchanged |
| `ServerScriptService/Event/EventLights.lua` | Events | `Systems/Events/Source/ServerScriptService/Event/EventLights.lua` | copied-unchanged |
| `ServerScriptService/Event/EventService.lua` | Events | `Systems/Events/Source/ServerScriptService/Event/EventService.lua` | copied-unchanged |
| `ServerScriptService/FunnelService.lua` | Analytics | `Systems/Analytics/Source/ServerScriptService/FunnelService.lua` | copied-unchanged |
| `ServerScriptService/GearShop/GearShopService.lua` | Items | `Systems/Items/Source/ServerScriptService/GearShop/GearShopService.lua` | copied-unchanged |
| `ServerScriptService/IncomeService.lua` | Economy | `Systems/Economy/Source/ServerScriptService/IncomeService.lua` | copied-unchanged |
| `ServerScriptService/Leaderboard/LeaderboardService.lua` | Leaderboards | `Systems/Leaderboards/Source/ServerScriptService/Leaderboard/LeaderboardService.lua` | copied-unchanged |
| `ServerScriptService/ModifierService.lua` | Economy | `Systems/Economy/Source/ServerScriptService/ModifierService.lua` | copied-unchanged |
| `ServerScriptService/MutationService.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ServerScriptService/MutationService.lua` | copied-unchanged |
| `ServerScriptService/PlayerLogger/PlayerLogger.lua` | PlayerLogging | `Systems/PlayerLogging/Source/ServerScriptService/PlayerLogger/PlayerLogger.lua` | copied-unchanged |
| `ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` | PlayerLogging | `Systems/PlayerLogging/Source/ServerScriptService/PlayerLogger/PlayerLoggerConfig.lua` | **adapted** |
| `ServerScriptService/PlayerLogger/PlayerRegistry.lua` | PlayerLogging | `Systems/PlayerLogging/Source/ServerScriptService/PlayerLogger/PlayerRegistry.lua` | copied-unchanged |
| `ServerScriptService/PlayerService.lua` | PlayerData | `Systems/PlayerData/Source/ServerScriptService/PlayerService.lua` | copied-unchanged |
| `ServerScriptService/Playtime/PlaytimeRewardsDay.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ServerScriptService/Playtime/PlaytimeRewardsDay.lua` | copied-unchanged |
| `ServerScriptService/Playtime/PlaytimeRewardsService.lua` | CodesAndRewards | `Systems/CodesAndRewards/Source/ServerScriptService/Playtime/PlaytimeRewardsService.lua` | copied-unchanged |
| `ServerScriptService/Rebirth/RebirthService.lua` | Rebirth | `Systems/Rebirth/Source/ServerScriptService/Rebirth/RebirthService.lua` | copied-unchanged |
| `ServerScriptService/SellService.lua` | Economy | `Systems/Economy/Source/ServerScriptService/SellService.lua` | copied-unchanged |
| `ServerScriptService/ServerLuckService.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/ServerLuckService.lua` | copied-unchanged |
| `ServerScriptService/SettingsService.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/SettingsService.lua` | copied-unchanged |
| `ServerScriptService/Shop/DoorService.lua` | ShopsAndPurchases | `Systems/ShopsAndPurchases/Source/ServerScriptService/Shop/DoorService.lua` | copied-unchanged |
| `ServerScriptService/Shop/ShopService.lua` | ShopsAndPurchases | `Systems/ShopsAndPurchases/Source/ServerScriptService/Shop/ShopService.lua` | copied-unchanged |
| `ServerScriptService/SlotMenuService.lua` | Inventory | `Systems/Inventory/Source/ServerScriptService/SlotMenuService.lua` | copied-unchanged |
| `ServerScriptService/StandPresentation.lua` | BasesAndSlots | `Systems/BasesAndSlots/Source/ServerScriptService/StandPresentation.lua` | copied-unchanged |
| `ServerScriptService/Steal/StealService.lua` | Stealing | `Systems/Stealing/Source/ServerScriptService/Steal/StealService.lua` | copied-unchanged |
| `ServerScriptService/TabList/TabListService.lua` | Leaderboards | `Systems/Leaderboards/Source/ServerScriptService/TabList/TabListService.lua` | copied-unchanged |
| `ServerScriptService/TraitService.lua` | MutationsAndTraits | `Systems/MutationsAndTraits/Source/ServerScriptService/TraitService.lua` | copied-unchanged |
| `ServerScriptService/Tutorial/TutorialService.lua` | Tutorials | `Systems/Tutorials/Source/ServerScriptService/Tutorial/TutorialService.lua` | copied-unchanged |
| `ServerScriptService/Tutorial/TutorialSignals.lua` | Tutorials | `Systems/Tutorials/Source/ServerScriptService/Tutorial/TutorialSignals.lua` | copied-unchanged |
| `ServerScriptService/UpgradeService.lua` | Upgrades | `Systems/Upgrades/Source/ServerScriptService/UpgradeService.lua` | copied-unchanged |
| `ServerScriptService/Utility/MoneyIcon.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/Utility/MoneyIcon.lua` | copied-unchanged |
| `ServerScriptService/Utility/MutationIcon.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/Utility/MutationIcon.lua` | copied-unchanged |
| `ServerScriptService/Utility/PathfindingUtil.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/Utility/PathfindingUtil.lua` | copied-unchanged |
| `ServerScriptService/Utility/WaterHazard.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/Utility/WaterHazard.lua` | copied-unchanged |
| `ServerScriptService/bootstrap.server.lua` | SharedUtilities | `Systems/SharedUtilities/Source/ServerScriptService/bootstrap.server.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ArenaCameraImpacts.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaCameraImpacts.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ArenaController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ArenaHitPresentation.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaHitPresentation.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ArenaResultController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ArenaResultController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/BatController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/BatController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/CodesController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/CodesController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/CodesTopbar.client.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/CodesTopbar.client.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/DailyRewardsController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/DailyRewardsController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/DailyTopbar.client.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/DailyTopbar.client.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/EggTimerController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/EggTimerController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/EventController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/EventController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/EventTransitionController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/EventTransitionController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/GearShopController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/GearShopController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/HUDController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/HUDController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/HudNotificationController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/HudNotificationController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/HudTree.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/HudTree.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/MenuPresentation.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/MenuPresentation.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/MoneyPoolController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/MoneyPoolController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/PlaytimeRewardsController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/PlaytimeRewardsController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/PlaytimeTopbar.client.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/PlaytimeTopbar.client.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/PromptOwnerFilter.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/PromptOwnerFilter.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/RebirthController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/RebirthController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ResetProtectionController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ResetProtectionController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/SellConfirmController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/SellConfirmController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ServerLuckController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ServerLuckController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/SettingsController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/SettingsController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/SettingsTopbar.client.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/SettingsTopbar.client.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ShopController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ShopController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/SlotMenuController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/SlotMenuController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/StealPresentationController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/StealPresentationController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ToastController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ToastController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/ToolLockController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/ToolLockController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/TutorialController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/TutorialController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/UiSoundController.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/UiSoundController.lua` | copied-unchanged |
| `StarterPlayer/StarterPlayerScripts/bootstrap.client.lua` | ClientPresentation | `Systems/ClientPresentation/Source/StarterPlayer/StarterPlayerScripts/bootstrap.client.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AdminFramework.spec.lua` | AdminTools | `Tests/AdminFramework.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalCarryConfig.spec.lua` | Animals | `Tests/AnimalCarryConfig.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalOverhead.spec.lua` | Animals | `Tests/AnimalOverhead.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalService.spec.lua` | Animals | `Tests/AnimalService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalStats.spec.lua` | Animals | `Tests/AnimalStats.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalTemplate.spec.lua` | Animals | `Tests/AnimalTemplate.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalType.spec.lua` | Animals | `Tests/AnimalType.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalWalkHandoff.spec.lua` | Animals | `Tests/AnimalWalkHandoff.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalWeight.spec.lua` | Animals | `Tests/AnimalWeight.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/AnimalXP.spec.lua` | Animals | `Tests/AnimalXP.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/Arena.spec.lua` | Arena | `Tests/Arena.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaBattle.spec.lua` | Arena | `Tests/ArenaBattle.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaDeployment.spec.lua` | Arena | `Tests/ArenaDeployment.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaRaid.spec.lua` | Arena | `Tests/ArenaRaid.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaResult.spec.lua` | Arena | `Tests/ArenaResult.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaSlots.spec.lua` | Arena | `Tests/ArenaSlots.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ArenaUIState.spec.lua` | Arena | `Tests/ArenaUIState.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/BaseLifecycle.spec.lua` | BasesAndSlots | `Tests/BaseLifecycle.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/BaseLockTimer.spec.lua` | BasesAndSlots | `Tests/BaseLockTimer.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/BaseService.spec.lua` | BasesAndSlots | `Tests/BaseService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/BaseServiceCollectorFacing.spec.lua` | BasesAndSlots | `Tests/BaseServiceCollectorFacing.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/Bases.spec.lua` | BasesAndSlots | `Tests/Bases.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/BigNumber.spec.lua` | SharedUtilities | `Tests/BigNumber.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/CarryRegistry.spec.lua` | Carry | `Tests/CarryRegistry.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/CarryService.spec.lua` | Combat | `Tests/CarryService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/CollectFeedback.spec.lua` | Collectors | `Tests/CollectFeedback.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/CollectorArrival.spec.lua` | Collectors | `Tests/CollectorArrival.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ConfigArchitecture.spec.lua` | SharedUtilities | `Tests/ConfigArchitecture.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/DoorService.spec.lua` | ShopsAndPurchases | `Tests/DoorService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/DynamicSlots.spec.lua` | BasesAndSlots | `Tests/DynamicSlots.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EconomyService.spec.lua` | Economy | `Tests/EconomyService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggAmbient.spec.lua` | EggsAndHatching | `Tests/EggAmbient.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggConsumeOrder.spec.lua` | EggsAndHatching | `Tests/EggConsumeOrder.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggContest.spec.lua` | EggsAndHatching | `Tests/EggContest.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggFlightHandoff.spec.lua` | EggsAndHatching | `Tests/EggFlightHandoff.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggFlightPath.spec.lua` | EggsAndHatching | `Tests/EggFlightPath.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggGuarantee.spec.lua` | EggsAndHatching | `Tests/EggGuarantee.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggLifecycle.spec.lua` | EggsAndHatching | `Tests/EggLifecycle.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggService.spec.lua` | EggsAndHatching | `Tests/EggService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggSpawnNotify.spec.lua` | EggsAndHatching | `Tests/EggSpawnNotify.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggSpawnService.spec.lua` | EggsAndHatching | `Tests/EggSpawnService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggTimerFormat.spec.lua` | EggsAndHatching | `Tests/EggTimerFormat.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EggWalkAnimator.spec.lua` | EggsAndHatching | `Tests/EggWalkAnimator.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EventMutation.spec.lua` | Events | `Tests/EventMutation.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/EventService.spec.lua` | Events | `Tests/EventService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/FunnelService.spec.lua` | Analytics | `Tests/FunnelService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/GearShop.spec.lua` | Items | `Tests/GearShop.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/HoverMath.spec.lua` | EggsAndHatching | `Tests/HoverMath.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/HudTree.spec.lua` | SharedUtilities | `Tests/HudTree.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/IncomeService.spec.lua` | Economy | `Tests/IncomeService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/Integration.spec.lua` | (cross-cutting) | `Tests/IntegrationTests/Integration.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/InteractionLiveness.spec.lua` | (cross-cutting) | `Tests/IntegrationTests/InteractionLiveness.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/LaserAnimation.spec.lua` | BasesAndSlots | `Tests/LaserAnimation.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/Leaderboard.spec.lua` | Leaderboards | `Tests/Leaderboard.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/LevelProgression.spec.lua` | Upgrades | `Tests/LevelProgression.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/LevelUpPresentation.spec.lua` | Animals | `Tests/LevelUpPresentation.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ModifierService.spec.lua` | Economy | `Tests/ModifierService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/NotificationService.spec.lua` | Notifications | `Tests/NotificationService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/PersistenceAudit.spec.lua` | PlayerData | `Tests/PersistenceAudit.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/PlayerGrab.spec.lua` | Combat | `Tests/PlayerGrab.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/PlayerLogger.spec.lua` | PlayerLogging | `Tests/PlayerLogger.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/PlayerService.spec.lua` | PlayerData | `Tests/PlayerService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/PromptOwnerFilter.spec.lua` | SharedUtilities | `Tests/PromptOwnerFilter.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/RebirthUnlocks.spec.lua` | Rebirth | `Tests/RebirthUnlocks.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ResetProtection.spec.lua` | Combat | `Tests/ResetProtection.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/RewardSkipAll.spec.lua` | CodesAndRewards | `Tests/RewardSkipAll.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/RichTextFormatter.spec.lua` | SharedUtilities | `Tests/RichTextFormatter.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/RollController.spec.lua` | EggsAndHatching | `Tests/RollController.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/SellConfirmViewport.spec.lua` | SharedUtilities | `Tests/SellConfirmViewport.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/SellService.spec.lua` | Economy | `Tests/SellService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ServerLuckBoost.spec.lua` | SharedUtilities | `Tests/ServerLuckBoost.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ServerLuckService.spec.lua` | SharedUtilities | `Tests/ServerLuckService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ShopConfig.spec.lua` | ShopsAndPurchases | `Tests/ShopConfig.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/ShopReceipt.spec.lua` | ShopsAndPurchases | `Tests/ShopReceipt.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/SlotActionHandler.spec.lua` | Inventory | `Tests/SlotActionHandler.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/SlotMath.spec.lua` | Inventory | `Tests/SlotMath.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/SlotMenuService.spec.lua` | Inventory | `Tests/SlotMenuService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/StandMenu.spec.lua` | (cross-cutting) | `Tests/IntegrationTests/StandMenu.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/StandPresentation.spec.lua` | (cross-cutting) | `Tests/IntegrationTests/StandPresentation.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/StatCalculator.spec.lua` | SharedUtilities | `Tests/StatCalculator.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/StealService.spec.lua` | Stealing | `Tests/StealService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/StudioTestUserIds.spec.lua` | SharedUtilities | `Tests/StudioTestUserIds.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/TabList.spec.lua` | Leaderboards | `Tests/TabList.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/TestRunner.server.lua` | (cross-cutting) | `Tests/TestRunner.server.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/TraitMutation.spec.lua` | MutationsAndTraits | `Tests/TraitMutation.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/TutorialService.spec.lua` | Tutorials | `Tests/TutorialService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/UnifiedSlot.spec.lua` | Inventory | `Tests/UnifiedSlot.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/UpgradeCost.spec.lua` | Upgrades | `Tests/UpgradeCost.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/UpgradeService.spec.lua` | Upgrades | `Tests/UpgradeService.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/WalkYaw.spec.lua` | Animals | `Tests/WalkYaw.spec.lua` | copied-unchanged |
| `Tests/ServerScriptService/TestEZTests/_Helpers.lua` | (cross-cutting) | `Tests/_Helpers.lua` | copied-unchanged |

---

## 5. Verification

### 5.1 Every source file is accounted for

```
$ find src -type f \( -name '*.lua' -o -name '*.luau' \) | wc -l
421
```

| Bucket | Count |
|---|---|
| `src/` `.lua`/`.luau` files, total | **421** |
| …mapped 1:1 into the library | **419** |
| …deliberately **not** copied (see §5.7) | **2** |
| …in the library but with **no** `src/` original (library-authored) | **28** |
| …third-party, copied verbatim into `Vendored/` (see §1.1) | **1** |

The library therefore contains **448** `.lua`/`.luau` files: 419 copies,
28 authored ones, and 1 third-party file. The 28 authored files are:

| Authored file | What it is |
|---|---|
| `Systems/<X>/Config.lua` (×26) | The per-system configuration index required by §4 of the task. One per system — 26 systems, 26 files. |
| `Templates/SystemConfigTemplate.lua` | The template a new system's `Config.lua` is written from. |
| `Tests/TestRunner.server.lua` | The **fixed** test runner. The source game's runner is defective (see §5.6) and is not copied. |

The one third-party file is `Vendored/ProfileService.lua` — a byte-identical
copy of `src/Vendored/ProfileService.lua`, kept so the library's own test
and example projects build without reaching into `src/`. See §1.1.

The `.luau` file in the source tree —
`ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` — is included in the
manifest and in the library.

### 5.2 Every library source file traces back to a source file

```
$ bash ReusableSystems/Tools/verify_fidelity.sh
Fidelity check
  total source files checked : 419
  byte-identical to src/     : 417
  intentionally adapted      : 2
  UNEXPECTEDLY DIFFERENT     : 0
  no matching file in src/   : 0
  authored for the library   : 28
  vendored third-party       : 1 (byte-identical: 1)
  unmapped                   : 0

RESULT: PASS
```

Every one of the 419 copied files is **byte-identical** to its `src/`
original, except the **2** that were deliberately adapted (both for
security reasons — see §3). The script walks the library, normalises each
path back to its original Roblox path, and byte-compares.

**The check covers the spec files too.** All 89 `*.spec.lua` files and
`Tests/_Helpers.lua` are byte-compared against their `src/` originals, so
a spec that drifted from the code it tests would fail the check rather
than pass silently. The script also globs `*.luau`, so
`CmdrBootstrap.luau` is verified.

### 5.3 No shared module is duplicated

Every module in `Shared/` appears exactly once in the manifest, with the
system column reading `Shared`. Every other row's system column names a
single owner. A module used by two systems appears **once** — with one
owner — and the second user is recorded in that system's `Dependencies.md`
and in `DEPENDENCY_MAP.md` §5.

Verified mechanically: mapping every library file back to its `src/`
original produces **419 distinct targets and 0 collisions** — one physical
home per file, as §3 of the task requires.

### 5.4 The production tree is unchanged

```
$ git status --porcelain -- src/ Packages/ DevPackages/ ServerPackages/ \
      default.project.json test.project.json wally.toml wally.lock aftman.toml
(empty)
```

`src/` is byte-identical to commit `5a1cb35`. Every file this task touched
is under `ReusableSystems/`. The only other change to the repository is a
four-line addition to `.gitignore` for the generated test tree.

Two **dev-tooling** files at the repository root were also changed: a
one-line addition to `selene.toml` (excluding `ReusableSystems/Vendored`
and `ReusableSystems/Tests/Tree`) and a new `.styluaignore` with the same
exclusions. Neither is referenced by any Rojo project, so neither can
affect the running game. They exist so that verbatim third-party code is
not reformatted — reformatting it would break the byte-identical
guarantee `Tools/verify_fidelity.sh` enforces. `PROJECT_SETUP.md` §1.1a
has the full list.

### 5.5 Every `require` resolves

```
$ rojo build ReusableSystems/test.project.json -o build/libtests.rbxlx
Building project 'reusable-systems-tests'...    (succeeds)
$ python ReusableSystems/Tools/check_requires.py build/libtests.rbxlx
require check
  library files mapped         : 329
  files present in the build   : 329
  require expressions checked : 1243
  UNRESOLVED (broken)          : 0
  dynamic (unverifiable)       : 10
```

**All 329 mapped files are present in the build and all 1243 `require`
expressions resolve.** The 10 dynamic requires are the ones that cannot
be checked statically — `require(node)`, `require(mod)`,
`require(topbarMod)`, `require(Packages:WaitForChild('Cmdr'))` — each
resolving a runtime variable.

The same check passes on the **production** build
(`build/p7.rbxlx`), which is the meaningful result: the library's
`require` graph is the production game's `require` graph, unchanged.

> **One pre-existing production gap, found by this check and NOT fixed
> here** (per the task's STRICT RULE): the production
> `test.project.json` maps `ServerScriptService/Packages` to the
> `ServerPackages/` folder, but `ProfileService` lives at
> `src/Vendored/ProfileService.lua` and is mapped only in
> `default.project.json`. So the `p-7-tests` build is missing
> `ServerScriptService.Packages.ProfileService` and
> `PlayerService.lua:61` cannot resolve it. This is **pre-existing**: all
> four inputs (`default.project.json`, `test.project.json`, `src/`,
> `ServerPackages/`) are byte-identical to commit `5a1cb35`, so the build
> output is unchanged from HEAD. The **library's** `test.project.json`
> maps it correctly and has 0 broken requires. See `SECURITY_NOTES.md`
> §5 for the full record.

The 5 dynamic requires are requires of a *runtime variable*
(`require(node)`, `require(mod)`, `require(Packages:WaitForChild('Cmdr'))`),
which cannot be resolved statically. They are listed individually in the
script's output.

### 5.6 The test suite: built, not run

- `rojo build ReusableSystems/test.project.json` **succeeds**. The built
  place contains 690 instances, 417 Lua modules, and 89 unique spec
  modules, with `_Helpers.lua` present as a *sibling* of the specs in
  `ServerScriptService.TestEZTests` (so `require(script.Parent._Helpers)`
  resolves).
- The suite was **not executed**. TestEZ is a Roblox-runtime-only
  framework and this repository has no headless Luau runner, so it can
  only be run in Roblox Studio. See `Tests/README.md` §3 for the exact
  procedure and the one remaining spec defect.

### 5.7 The two files that were deliberately not copied

| `src/` file | Reason |
|---|---|
| `src/Vendored/ProfileService.lua` | **Third-party code** (MadworkRoblox's standalone ProfileService, MIT). Not this game's system, so it is not counted as extracted game source. A **verbatim copy** is kept in the library at `ReusableSystems/Vendored/ProfileService.lua` so the library's own test and example projects build without reaching into `src/`. See §1.1. |
| `src/Tests/ServerScriptService/TestEZTests/TestRunner.server.lua` | **Defective.** It requires a path that does not exist (`script.Parent.Parent.Packages.TestEZ`) and calls `TestEZ.RunBootstrap()`, which is not a TestEZ 0.4.1 API. The library has its own **fixed** runner at `ReusableSystems/Tests/TestRunner.server.lua`. |

### 5.8 The library introduces no new lint findings

```
$ python ReusableSystems/Tools/triage_lint.py
STYLUA
  src/ baseline failures      : 77
  library failures            : 75
    pre-existing in src/       : 75
    introduced by extraction   : 0
SELENE
  src/ findings               : 6726
  library findings            : 6723
    pre-existing              : 6723
    LIBRARY-ONLY              : 0
```

The linters were run on the library and on the `src/` baseline, and the
findings were matched **by content** (code + message), not by file, so a
finding counts as pre-existing only if the *same* finding is present in the
original. Every library finding is pre-existing. The count difference is
accounted for by the two excluded files and by the library's own copy of
`PlayerLoggerConfig.lua`, whose formatting drift the security fix removed.

### 5.9 No secrets in the library

```
$ grep -rInE "discord(app)?\.com/api/webhooks/[0-9]{17,}" ReusableSystems/ \
    | grep -v "/Tests/Tree/"
(empty)
```

The only two live secrets in the source game — the Discord webhook URL and
the admin userId allowlist — were **removed** in the library copies and are
recorded in `SECURITY_NOTES.md` §5 (S-1 and S-5). The remaining
`discord.com/api/webhooks/` hits in the library are documentation
placeholders (`…`, `<id>`, `<webhook_token>`) and one URL *pattern* used
for validation, not a value.

---

## 6. How to re-verify all of this

From the repository root:

```bash
# 1. The production game still builds, unchanged.
rojo build default.project.json -o /tmp/prod.rbxlx
rojo build test.project.json      -o /tmp/prod-test.rbxlx

# 2. The library builds standalone.
rojo build ReusableSystems/library.project.json -o /tmp/lib.rbxlx

# 3. The library's test place builds.
python ReusableSystems/Tools/generate_test_tree.py
python ReusableSystems/Tools/generate_test_project.py
rojo build ReusableSystems/test.project.json -o /tmp/lib-tests.rbxlx

# 4. Every library file is byte-identical to its source original.
bash ReusableSystems/Tools/verify_fidelity.sh

# 5. Every require resolves.
python ReusableSystems/Tools/check_requires.py /tmp/lib-tests.rbxlx

# 5b. The self-contained example's requires resolve too.
rojo build ReusableSystems/Examples/MinimalGame/minimalgame.project.json     -o /tmp/minimalgame.rbxlx
python ReusableSystems/Tools/check_requires.py /tmp/minimalgame.rbxlx     --project=ReusableSystems/Examples/MinimalGame

# 6. The library introduces no new lint findings.
python ReusableSystems/Tools/triage_lint.py

# 7. The production tree is untouched.
git status --porcelain -- src/     # → empty
git diff --stat -- src/           # → empty
```
