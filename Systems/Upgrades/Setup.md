# Upgrades — Setup

Installing the Upgrades system into a new Rojo project. Steps 1-4 are
the system itself; steps 5-6 add the UI and the request path.

---

## 1. Copy the files

| Copy from | To | Required? |
|---|---|---|
| `Source/ServerScriptService/UpgradeService.lua` | `ServerScriptService/UpgradeService.lua` | **Yes** |
| `Source/ReplicatedStorage/Config/Creatures/Progression.lua` | `ReplicatedStorage/Config/Creatures/Progression.lua` | **Yes** |

**Shared modules you also need** (from `ReusableSystems/Shared/`):

| Library file | Roblox destination |
|---|---|
| `Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `Types/TransactionReason.lua` | `ReplicatedStorage/Types/TransactionReason.lua` |

**You also need these systems present:**

- **Economy** — `ServerScriptService/EconomyService.lua` (the debit)
- **Animals** — `ServerScriptService/AnimalService.lua` (the runtime
  record and `ApplyLevelUpgrade`) and
  `ReplicatedStorage/Config/Creatures/Animals.lua` (the rarity +
  `SellBaseValue` base price)
- **Inventory** — `ServerScriptService/Base/SlotService.lua` (the slot
  check)
- **BasesAndSlots** — `ServerScriptService/BaseService.lua` (base
  ownership + the snapshot)
- **PlayerData** — `ServerScriptService/PlayerService.lua`
- **Notifications** — `ServerScriptService/Base/NotificationService.lua`

Optional (delete the require **and** the call if you do not have
them — the require is unconditional):

- **Arena** — `ServerScriptService/Arena/ArenaService.lua` (the raid
  lock)
- **Tutorials** — `ServerScriptService/Tutorial/TutorialSignals.lua`
- **Analytics** — `ServerScriptService/FunnelService.lua`

---

## 2. Third-party packages (Wally)

The Upgrades system itself needs **no** third-party package, but its
dependencies do:

```toml
[dependencies]
janitor = "kineticwallet/janitor@1.17.0"   -- only if you install PlayerData
```

and the vendored `ProfileService` at
`ServerScriptService/Packages/ProfileService.lua`.

`Validation.lua` requires `ReplicatedStorage.Packages.t`
(`osyrisrblx/t`), which the source game vendors under `Packages/`.

---

## 3. Configuration to tune

Open `ReplicatedStorage/Config/Creatures/Progression.lua`:

| Value | Default | When to change it |
|---|---|---|
| `MaxLevel` | `100` | Always — this is your game's level ceiling. |
| `XP.BaseRequired` | `200` | If your XP track is faster or slower. |
| `XP.GrowthRate` | `1.12` | **Read the warning below.** |
| `PointsPerLevel` | `3` | If you have a points system. |
| `AdminLevelCap` | `99` | The `/setlevel` ceiling. |

> **The `GrowthRate` trap.** `UpgradeService` `assert`s at require
> time that `Progression.XP.GrowthRate == 1.12` and implements the
> same curve with exact `28/25` integer math. If you change the
> growth rate you **must**:
> 1. change `Progression.XP.GrowthRate`;
> 2. rewrite `UpgradeService.GetUpgradeCost`'s integer math for the
>    new fraction (numerator/denominator, and the `10^(d*k)` scaling
>    factor `d`);
> 3. update the `assert` in `UpgradeService.lua:69-72`.
>
> Skip any of the three and the server **fails to load** (or, worse,
> silently forks the upgrade economy from the XP curve). The comment
> in `Progression.lua` says exactly this: "Do NOT retune without
> updating UpgradeService + re-verifying the whole economy curve."

**The base price** lives in the Animals system, not here:
`ReplicatedStorage/Config/Creatures/Animals.lua` →
`Animals.SellBaseValue[rarity]`. It is **the same table the sale
formula uses**, so retuning it moves both curves. If you want the
upgrade price to be independent of the sale price, change the one
line `UpgradeService.lua:139`:

```lua
local base = AnimalConfig.SellBaseValue[rarity]
-- -> local base = YourOwnPriceTable[rarity]
```

A consolidated, documented view of every value is in
[`Config.lua`](Config.lua).

---

## 4. Bootstrap: the exact sequence

```lua
-- ReplicatedStorage
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

-- --- 1. Remotes first ---
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Instance.new('Folder')
remotesFolder.Name = 'Remotes'
remotesFolder.Parent = ReplicatedStorage
Remotes.SetRemotes(remotesFolder)

-- --- 2. The domain services ---
local PlayerService = require(ServerScriptService.PlayerService)
local SlotService = require(ServerScriptService.Base.SlotService)
local BaseService = require(ServerScriptService.BaseService)
local AnimalService = require(ServerScriptService.AnimalService)
local EconomyService = require(ServerScriptService.EconomyService)

-- --- 3. The upgrade authority ---
local UpgradeService = require(ServerScriptService.UpgradeService)

-- --- 4. Wire all FIVE refs. Missing any one makes every upgrade
---     return 'service-unavailable'.
UpgradeService.SetPlayerService(PlayerService)
UpgradeService.SetSlotService(SlotService)
UpgradeService.SetBaseService(BaseService)
UpgradeService.SetAnimalService(AnimalService)
UpgradeService.SetEconomyService(EconomyService)

-- --- 5. The readouts (optional but the player needs them) ---
SlotMenuService.SetUpgradeService(UpgradeService)
StandDisplayService.SetUpgradeService(UpgradeService)
```

There is **no `UpgradeService.Init()`** — the service has no state to
create and no remote of its own.

---

## 5. The request path

`UpgradeService` has **no remote of its own**. In the source game the
request arrives through the slot menu:

```lua
-- Client -> server
Remotes.FireServer(Remotes.Names.SlotMenuAction, {
    SlotId = slotId,
    OccupantId = animalId,
    Action = 'Upgrade',
})
```

`SlotMenuService` validates that the target is an animal (not an egg),
calls `UpgradeService.UpgradeAnimal(player, animalId)`, and fires
`SlotMenuResult` with `NewLevel` and `Cost` on success.

If you do not have `SlotMenuService`, write your own handler:

```lua
Remotes.Names.UpgradeAction = 'UpgradeAction'   -- add to the registry
-- ... create the RemoteEvent at boot from the registry ...
Remotes.OnServerEvent(Remotes.Names.UpgradeAction, function(player, payload)
    if type(payload) ~= 'table' then return end
    local result = UpgradeService.UpgradeAnimal(player, payload.AnimalId)
    Remotes.FireClient(player, Remotes.Names.UpgradeResult, result)
end)
```

**Never** let the client send a cost or a level. The service ignores
anything but the animal id.

---

## 6. Studio assets to author

**None for the server side.** `UpgradeService` reads no Workspace or
ServerStorage hierarchy.

For the player-facing side you need the slot-menu GUI with an
upgrade button, a level readout, and the cost — but that belongs to
the **Inventory** system (`SlotMenuService`) and the **Animals**
system (`StandDisplayService`), not to this one.

One indirect dependency: `AnimalService.ApplyLevelUpgrade` triggers
the level-up presentation (the happy bop and the Upgrade VFX) and
refreshes the overhead. Both are `pcall`-guarded, so a missing asset
means "no celebration", not "no upgrade".

---

## 7. Smoke test

Do these in order in a Studio test server.

**A. The price is exact and readable.**

1. Open the slot menu on a Common animal. The button reads
   `$100` — the base price, exactly.
2. Upgrade it. The button now reads `$112` (the Level-2 price).
3. Upgrade twice more: `$125.44`, then `$140.4928`. The decimals are
   **exact** — no `125.4400000001`.

**B. The debit is exact.**

1. Give yourself exactly `100`. Upgrade a Level-1 Common.
2. The wallet goes to exactly `0` — not `-0`, not `0.0000001`.
3. Give yourself `99`. Try again → the upgrade is refused and the
   wallet is still `99`.

**C. The dynamic shortfall message.**

1. Give yourself `50` and try to upgrade a Level-1 Common (cost 100).
2. The warning says "you need $50 more" — **server-calculated**,
   never from the client.

**D. Everything else is preserved.**

1. Note the animal's XP progress and its uncollected cash.
2. Upgrade it.
3. The XP is the same, the cash is the same, the slot is the same, the
   id is the same, and the level went up by exactly 1.

**E. The level cap.**

1. Set the animal's level to 99 (admin). Upgrade it → it becomes 100.
2. Try again → the button is gone / the upgrade is refused with
   "Max Level", and **the money is untouched**.

**F. The slot check.**

1. Pick the animal up (carry it) and try to upgrade it → refused.
2. Walk the animal off its stand (or release the base) and try again
   → refused. The animal must be on a live, owned, `Occupied` slot.

**G. A raid lock.**

1. Start an arena raid on the animal and try to upgrade it → refused
   with the "Busy" message. The raid's frozen snapshot is not
   corrupted.

**H. The multiplier does not apply.**

1. Give yourself a 5x money multiplier (an event, a rebirth, a code).
2. Upgrade an animal. The cost is **unchanged**.

**I. The counter.**

1. Upgrade three animals once each. `Stats.UpgradesApplied` is `3`.
2. A rejected upgrade does **not** increment it.

---

## 8. Running the tests

Three spec files, all TestEZ, all Studio-only (there is no headless
Luau runner in this project).

1. Copy `Systems/Upgrades/Tests/*.spec.lua` into your test tree.
2. Copy `ReusableSystems/Tests/_Helpers.lua` alongside them (the specs
   `require(script.Parent._Helpers)`).
3. Wire a TestEZ runner; see `ReusableSystems/Tests/README.md`.
4. Run in Studio.

`UpgradeService.spec.lua` needs the **real** `EconomyService`,
`AnimalService`, and `ModifierService` plus hand-rolled
player/slot/base fakes, and it uses the `AnimalService._TestRegister`
seam to create runtime animals without spawning models. If you
replaced `AnimalService`, that spec will not work as written.

`UpgradeCost.spec.lua` and `LevelProgression.spec.lua` are pure —
no services, no fakes.

The specs need **no DataStore, no published place, and no Robux**.

---

## 9. Trimming the system

| You want | Keep | Drop |
|---|---|---|
| A plain paid upgrade | `UpgradeService` + `Progression.lua` | Everything in the "optional" row of step 1 |
| No XP track | `MaxLevel` and `PointsPerLevel` only | `XP`, `GetXPRequired`, `Normalize` — but `AnimalService` reads them too, so edit that as well |
| No points system | — | `PointsPerLevel = 0` |
| No arena | — | The `ArenaService` require and the raid-lock check |
| No tutorial layer | — | The `TutorialSignals` require and the `Fire` call |
| No funnel analytics | — | The `FunnelService` require and its `pcall` block |

**Do not trim the spend-then-mutate order or the exact-decimal
engine.** They are the difference between "the cost is always exactly
right" and "the cost drifts".
