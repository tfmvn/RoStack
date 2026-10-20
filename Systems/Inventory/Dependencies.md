# Inventory — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** — the
library's `Source/` tree mirrors it, so `require` calls resolve unchanged
when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Base/SlotService.lua`

```lua
require(ReplicatedStorage.Config.World.Bases)          -- Config/World/Bases.lua
require(ReplicatedStorage.Types.SlotType)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.StandResolver)
```

> The source file writes these as
> `script.Parent.Parent.Parent.ReplicatedStorage.*` (relative form) because
> the file sits three levels deep. The resolved Roblox paths are the ones
> above.

### `ServerScriptService/Action/SlotActionHandler.lua`

```lua
require(ReplicatedStorage.Config.World.Prompts)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Types.SlotType)
require(ServerScriptService.BaseService)               -- NOT in this library
require(ServerScriptService.Base.SlotService)
require(ServerScriptService.Carry.CarryRegistry)       -- Carry system
require(ServerScriptService.Base.NotificationService)  -- Notifications system

-- LAZY (resolved on first dispatch, to break a require cycle):
require(ServerScriptService.EggService)                -- EggsAndHatching system
require(ServerScriptService.AnimalService)             -- Animals system
require(ServerScriptService.SellService)               -- Economy system
```

### `ServerScriptService/SlotMenuService.lua`

```lua
require(ReplicatedStorage.Config.Creatures.Animals)    -- Animals system
require(ReplicatedStorage.Config.Creatures.Progression)-- Upgrades system
require(ReplicatedStorage.Config.World.Bases)           -- BasesAndSlots system
require(ReplicatedStorage.Config.Systems.Security)      -- AdminTools system
require(ReplicatedStorage.Utility.BigNumber)
require(ReplicatedStorage.Utility.AnimalStats)          -- Shared/CommonModules
require(ReplicatedStorage.Utility.Remotes)
require(ReplicatedStorage.Utility.Debug)
require(ReplicatedStorage.Utility.Validation)
require(ReplicatedStorage.Types.SlotType)
require(ServerScriptService.Base.NotificationService)  -- Notifications system
```

### `ServerScriptService/Animal/SlotMath.lua`

```lua
require(ReplicatedStorage.Utility.StandResolver)
```

---

## Other Systems Required

| System | Module(s) | Why | Optional? |
|---|---|---|---|
| **BasesAndSlots** | `Config/World/Bases.lua` | Slot count, slot size/offsets, the `Stands.Labels` block the menu formats with. | **Required** — `Bases.Slots.Count` drives the snapshot range and `Bases.Slots.Count` is the pool size. |
| **Carry** | `ServerScriptService/Carry/CarryRegistry` | The carry gate for `Pickup`/`Hatch`/`Place`, and the source of `item.record.uniqueId` for `Place`. | **Required** for `SlotActionHandler`. |
| **Notifications** | `ServerScriptService/Base/NotificationService` | The one warning channel (`NotifyWarning(player, messageId)`). | **Required** for player feedback. Leaf module (no `ServerScriptService` requires), so it is cycle-free. |
| **Animals** | `Config/Creatures/Animals.lua`, `ServerScriptService.AnimalService` | The animal definition catalogue and the animal record lookup for the menu preview and the `Pickup`/`Place` dispatch. | **Required** for animals; optional if your game has no animals (eggs only). |
| **EggsAndHatching** | `ServerScriptService.EggService` | The egg record lookup, `GrabEgg`, `HatchEgg`, `PlaceEgg`. | **Required** for eggs. |
| **Upgrades** | `Config/Creatures/Progression.lua`, `ServerScriptService.UpgradeService` | `MaxLevel` for the preview, and the paid upgrade transaction. | **Required** for the upgrade menu; optional if you drop the upgrade endpoint. |
| **Economy** | `ServerScriptService.SellService` | The `SellAnimal` transaction. | **Required** for selling. |
| **PlayerData** | `ServerScriptService.PlayerService` | Read-only: the menu preview looks up the animal's `CashPool` in the profile. | **Optional** — the pool shows `'0'` if the profile is unavailable. |
| **ClientPresentation** | `ServerScriptService.StandDisplayService` | Repaints the stand's direct-upgrade readout. | **Optional** — the readout is skipped if unwired. |
| **BaseService** (the `BasesAndSlots` service itself) | `ServerScriptService.BaseService` | Owns the base and slot records; `GetBaseById` for the ownership check. | **Required** — a hard module-load require. |

Everything else is a **leaf dependency** — config and utility modules with no
back-references.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `SlotMenuRequest` | C→S | `{ SlotId: string }` (an `Intent` field is read but only used for the breadcrumb log — it is **not** authoritative). |
| `SlotMenuState` | S→C | The `BuildMenuState` table, or `{ Valid = false, SlotId, Error? }`. |
| `SlotMenuAction` | C→S | `{ SlotId: string, OccupantId: string, Action: 'Upgrade' }`. |
| `SlotMenuResult` | S→C | `{ SlotId, Success: boolean, Error?: string, NewLevel?, Cost? }`. |

`SlotMenuState` (animal variant) is RemoteEvent-safe — strings, numbers,
booleans, plain tables only:

```lua
{
  Valid = true, SlotId = 'p7:123:slot:1', Kind = 'animal',
  ObjectId = 'AN_...', Name = 'Tralalero', Rarity = 'Rare',
  Level = 3, NewLevel = 4,
  CanUpgrade = true, UpgradeCostRaw = '1234', UpgradeButtonText = 'Upgrade $1,234',
  GenRaw = '12.5', GenFormatted = '$12.5/sec',
  PoolRaw = '0', PoolFormatted = '$0',
}
```

`SlotMenuState` (egg variant) omits the animal-only fields **entirely**
(`nil` by construction, not zero):

```lua
{ Valid = true, SlotId = '...', Kind = 'egg', ObjectId = 'EG_...',
  Name = 'Egg', Rarity = 'Common', CanUpgrade = false }
```

The remotes are created at boot from the `Remotes.Names` registry — see
`Shared/CommonModules/Remotes.lua`. Do not hand-author them.

---

## Profile Fields Read / Written

**Written: none.** This system never mutates the profile.

**Read (read-only, through `PlayerService.GetPlayerData(userId)`):**

| Field | Where | Purpose |
|---|---|---|
| `Brainrots` | `SlotMenuService.BuildMenuState` | Find the record whose `Id == occupantId` and `Type == 'Brainrot'`; read its `CashPool` for the pool preview. |

The slot records themselves are **runtime-only** and are not persisted.
Persistence lives in the profile's `Brainrots` / `LuckyBlocks` lists, keyed
by `SlotId`.

---

## Required Studio Assets

**Workspace hierarchy** (resolved by `StandResolver`; see
`Shared/CommonModules/StandResolver.lua`):

```text
Workspace.Map.Bases
└── Base_<n>                        (n = 1..Bases.Count)
    ├── Collector                   BasePart — the cash trigger
    ├── Spawn                       BasePart
    ├── PlayerBoard
    │   └── Main
    │       └── SurfaceGui
    │           └── Frame
    │               ├── Name
    │               └── Avatar
    └── AnimalStands
        └── Stand<k>                (k = 1..Bases.Slots.Count)
            ├── Button
            │   ├── Base            BasePart — the facing target (authoritative)
            │   └── PressPart       BasePart — the animated cash button
            │       └── SurfaceGui
            │           └── Amount  TextLabel
            └── Slot
                ├── Root            BasePart — the placement surface
                └── MenuPart
                    └── MenuGui
                        └── UpgradeButton
                            ├── Level          TextLabel
                            ├── UpgradeAmount  TextLabel
                            └── UIStroke
```

Notes:

- `Stand.Button.Base` is the **facing target** for placed animals/eggs
  (yaw-only, no tilt). When `Base` is absent, `PressPart` is the
  fallback. When neither resolves, the slot part's own rotation is kept.
- `UpgradeButton` is a **direct child of `MenuGui`** in the current
  shape. The legacy `MenuGui → Frame → UpgradeButton` shape is still
  accepted (the lookup is recursive), so old places keep working.
- `MenuPart` / `MenuGui` / `UpgradeButton` are **optional**. A missing
  `MenuPart` warns once per part; a missing `MenuGui` or `UpgradeButton`
  is a silent no-op. The `slotId` attribute stamp is a routing hint
  only — the server revalidates everything regardless.
- The legacy flat workspace (`Workspace.Bases` with a `Slots` folder and
  `Slot<k>` names) is accepted by `StandResolver` as a fallback, and
  `SlotService._stampMenuSlotId` has a legacy recursive search under the
  slot part for it.
- `Collector` must be a `BasePart` for `CollectFeedback` (the Collectors
  system) to find it.

**ServerStorage: none required by this system.** (`CollectFeedback` in the
Collectors system needs `ServerStorage.Assets.Sfx.CashClaim` and
`ServerStorage.Assets.Vfx.CashClaim`; the Items system needs
`ServerStorage.Assets.Ui.GearShop.*`; the Carry system needs
`ServerStorage.Assets.Animations.Player.Grab`.)

---

## External APIs

**None.** No HTTP, no DataStore, no Marketplace, no Open Cloud. This system
is pure in-memory state plus engine instance walking.

---

## Exact Initialization Order

```text
1.  bootstrap.createRemotes()               -- the Remotes folder must exist
2.  SlotService.Init()
3.  BaseService.Init()
4.  BaseService.RegisterBases(workspace)
        -> SlotService.RegisterBase(base)    -- indexes base.slots
        -> SlotService.RegisterArenaSlots(base)
5.  bootstrap wires the display callbacks:
        SlotService.SetOccupiedCountCallback(BaseService.<counter updater>)
        SlotService.SetPoolDisplayCallback(IncomeService.<pool republisher>)
        SlotService.SetStandDisplayCallback(StandDisplayService.<refresher>)
6.  SlotMenuService.Init()                   -- connects SlotMenuRequest / SlotMenuAction
7.  bootstrap injects into SlotMenuService:
        SetPlayerService(PlayerService)
        SetBaseService(BaseService)
        SetSlotService(SlotService)
        SetAnimalService(AnimalService)
        SetEggService(EggService)
        SetModifierService(ModifierService)
        SetUpgradeService(UpgradeService)
        SetStandDisplayService(StandDisplayService)
8.  On PlayerAdded:
        BaseService.AssignBaseForPlayer(userId)
            -> SlotService.SetBaseOwner(userId, base)
            -> SlotService.RebaseSlotIds(base)   -- re-stamp ids + menu buttons
9.  On PlayerRemoving:
        SlotMenuService.ForgetPlayer(userId)
        BaseService.ReleaseBase / CleanupPlayer
            -> SlotService.ClearBaseOwner(userId)
            -> SlotService.UnregisterBase(baseId)
```

**Why the order matters:**

- `RegisterBase` must precede every transition — `findSlotById` resolves
  through `slotById` and nothing else.
- `RebaseSlotIds` must follow the id re-stamp on assignment, or the index
  still holds the old id strings and every transition misses.
- `SlotMenuService.Init` must follow `createRemotes` — otherwise
  `Remotes.GetFolder` throws and the menu is silently dead.
- The three display callbacks are best wired **before** any base is
  registered, so the first `OccupySlot` already repaints.
- The `SlotMenuService` injections must be in place before a player can
  open a menu; `BuildMenuState` returns `{ Valid = false }` when the
  relevant service ref is missing.
