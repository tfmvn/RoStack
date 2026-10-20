# Rebirth — Setup

Installing the Rebirth system into a new Rojo project. The Rebirth
system is **not** a standalone drop-in: it orchestrates eight other
systems. Steps 1-3 are the Rebirth system itself; steps 4-6 are the
surrounding wiring.

---

## 1. Copy the files

| Copy from | To | Required? |
|---|---|---|
| `Source/ServerScriptService/Rebirth/RebirthService.lua` | `ServerScriptService/Rebirth/RebirthService.lua` | **Yes** |
| `Source/ReplicatedStorage/Config/Economy/Rebirth.lua` | `ReplicatedStorage/Config/Economy/Rebirth.lua` | **Yes** |

**Shared modules you also need** (from `ReusableSystems/Shared/`):

| Library file | Roblox destination |
|---|---|
| `CommonModules/RebirthUnlocks.lua` | `ReplicatedStorage/Utility/RebirthUnlocks.lua` |
| `Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Types/SlotType.lua` | `ReplicatedStorage/Types/SlotType.lua` |

`RebirthUnlocks` additionally requires `ReplicatedStorage/Config/Economy/Gear`
and `ReplicatedStorage/Config/Presentation/UI` — those live in the
**Combat** and **SharedUtilities** systems respectively. See
[`Dependencies.md`](Dependencies.md) for the full list.

**You also need these systems present** (the Rebirth service
`require`s them directly):

- **PlayerData** — `ServerScriptService/PlayerService.lua`
- **Animals** — `ServerScriptService/AnimalService.lua`
- **BasesAndSlots** — `ServerScriptService/BaseService.lua`,
  `ServerScriptService/Base/SlotService.lua`,
  `ServerScriptService/Base/DynamicSlotService.lua`
- **Arena** — `ServerScriptService/Arena/ArenaProgressionService.lua`,
  `ServerScriptService/Arena/ArenaService.lua`
- **Economy** — `ServerScriptService/ModifierService.lua`
- **Carry** — `ServerScriptService/Carry/CarryRegistry.lua`
- **Stealing** — `ServerScriptService/Steal/StealService.lua`
- **Eggs** — `ServerScriptService/EggService.lua` (optional)
- **Analytics** — `ServerScriptService/FunnelService.lua` (optional)
- **Logging** — `ServerScriptService/PlayerLogger/PlayerLogger.lua` (optional)
- **Leaderboards** — `ServerScriptService/Leaderboard/LeaderboardService.lua`,
  `ServerScriptService/TabList/TabListService.lua` (optional)

If you are not using eggs, delete the `EggService` require and the
`EggService.ReconcileAfterBaseSwap` call. If you are not using a
funnel, delete the `FunnelService` require and its three `pcall`
blocks. Everything optional is already `pcall`-guarded — but the
`require` at the top of the file is **not**; a missing optional module
is a hard load error.

---

## 2. Third-party packages (Wally)

The Rebirth system itself needs **no** third-party package, but its
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

Open `ReplicatedStorage/Config/Economy/Rebirth.lua`. You must edit
this file to make the system your own — the shipped ladder is tuned
for Brainrot Arena's animal catalogue and arena levels.

The minimum viable edit is to replace the `ENTRIES` table. Keep the
shape exactly:

```lua
[1] = {
    Requirements = {
        Money = '500000',            -- BigNumber STRING
        ArenaLevel = 5,              -- integer
        Animals = {
            { DefId = 'Dog', Trait = 'Normal', MinimumLevel = 5 },
        },
    },
    Rewards = {
        StartingCash = '25000',      -- BigNumber STRING
        MoneyMultiplier = 1.5,       -- number > 0
    },
    Reset = { Money = true, Base = true, Animals = true, ArenaLevel = true },
    Stands = { Animal = 6, Arena = 2 },
}
```

Then sanity-check it:

```lua
local issues = require(ReplicatedStorage.Config.Economy.Rebirth).Validate()
for _, issue in issues do
    warn(issue)
end
```

`Validate()` **never throws** — it returns an array of issue strings.
An empty array means the ladder is well-formed. The most important
issue it can report is a **gap** (`Rebirth gap: [3] missing below max
[5]`) — the server walks `current + 1`, so a gap strands progression
permanently.

A consolidated, documented view of every value is in
[`Config.lua`](Config.lua).

---

## 4. Bootstrap: the exact sequence

The order is load-bearing. `RebirthService` resolves its dependencies
by **direct require**, so it must be required **after** all of them.

```lua
-- ReplicatedStorage
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local ServerScriptService = game:GetService('ServerScriptService')

-- --- 1. Remotes first: everything downstream fires to them ---
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Instance.new('Folder')
remotesFolder.Name = 'Remotes'
remotesFolder.Parent = ReplicatedStorage
Remotes.SetRemotes(remotesFolder)

-- --- 2. The domain authorities, in dependency order ---
local PlayerService = require(ServerScriptService.PlayerService)
local AnimalService = require(ServerScriptService.AnimalService)
local BaseService = require(ServerScriptService.BaseService)
local SlotService = require(ServerScriptService.Base.SlotService)
local ArenaProgressionService = require(ServerScriptService.Arena.ArenaProgressionService)
local ArenaService = require(ServerScriptService.Arena.ArenaService)
local ModifierService = require(ServerScriptService.ModifierService)
local CarryRegistry = require(ServerScriptService.Carry.CarryRegistry)
local StealService = require(ServerScriptService.Steal.StealService)
local EggService = require(ServerScriptService.EggService)
local FunnelService = require(ServerScriptService.FunnelService)
local PlayerLogger = require(ServerScriptService.PlayerLogger.PlayerLogger)

-- --- 3. Rebirth LAST: it requires all of the above ---
local RebirthService = require(ServerScriptService.Rebirth.RebirthService)

-- --- 4. Wire the remote ---
RebirthService.Init()

-- --- 5. Stand unlocks: the base rebuild consults the rebirth count
---     through this resolver (an injected function ref -- no cycle).
local DynamicSlotService = require(ServerScriptService.Base.DynamicSlotService)
DynamicSlotService.SetUnlockResolver(function(userId: number): number
    return RebirthService.ResolveRebirthForStands(userId)
end)

-- --- 6. The native Tab list ranks rebirths-first ---
local TabListService = require(ServerScriptService.TabList.TabListService)
TabListService.SetRebirthService(RebirthService)

-- --- 7. At boot no base has an owner: hide every multiplier label ---
RebirthService.HideAllBaseMultipliers()
```

### Per-player join order

```lua
Players.PlayerAdded:Connect(function(player)
    if not PlayerService.LoadPlayerData(player) then
        player:Kick('Failed to load data. Please try again.')
        return
    end

    local base = BaseService.AssignBaseForPlayer(player.UserId)
    if not base then
        PlayerService.CleanupPlayer(player.UserId)
        player:Kick('No base available.')
        return
    end
    PlayerService.AssignBase(player.UserId, base.id)
    BaseService.PointPlayerToBaseSpawn(player, base)

    -- The rebirth multiplier is SESSION-ONLY (ModifierService is
    -- in-memory). Without this call a returning player has 1x income.
    RebirthService.ApplySessionModifiers(player.UserId)

    PlayerService.MarkLoaded(player.UserId)
    PlayerService.PushState(player, BaseService.Snapshot(player.UserId))
end)
```

### Per-player leave order

```lua
Players.PlayerRemoving:Connect(function(player)
    RebirthService.ForgetPlayer(player.UserId)
end)
```

---

## 5. Studio assets to author

| Asset | Where | Needed by |
|---|---|---|
| Multiplier label | `Base/MoneyMultPart/SurfaceGui/TextLabel` (a `TextLabel`) | `RefreshBaseMultiplier` writes `Mult: 1.5x` here. **Display only** — the multiplier itself is unaffected if it is missing. |
| Stand template | The model `DynamicSlotService.GetTemplate()` returns | The `__Stand` unlock preview clone. |
| Arena stand template | The model `DynamicSlotService.GetArenaTemplate()` returns | The `__ArenaStand` unlock preview clone. |
| Animal templates | The models `AnimalService.GetTemplate(rarity, defId, trait)` returns | The per-requirement preview clones. |

`RebirthService` creates the `ReplicatedStorage/RebirthPreviews` folder
itself (on demand) and destroys it on leave. **Do not author it.**

You also need the **client GUI** for the rebirth screen — a frame that
listens to `RebirthState` and shows the requirements, the unlock cards,
and a Rebirth button that fires `RebirthAction { Action = 'Rebirth' }`.
The server side is complete without it; the game is not.

---

## 6. Smoke test

Do these in order in a Studio test server.

**A. The screen opens.**

1. Open the rebirth GUI. The money, arena level, and animal
   requirements populate.
2. The `Rebirth` button is disabled when a requirement is unmet.
3. The unlock cards show the **deltas** (`+2 Stand`, `+1 Stand`), not
   absolute counts. A rebirth that adds nothing shows no card.

**B. A refusal is a refusal.**

1. Try to rebirth with less money than required.
2. The server answers `RebirthResult { Success = false, Error = 'money' }`.
3. **Nothing changed** — your animals, your base, your money, your
   rebirth count are all identical.
4. The GUI refreshes anyway (the state push happens on failure too).

**C. A successful rebirth.**

1. Meet all three requirements (money, arena level, the animal at the
   right level).
2. Rebirth. The money drops to the StartingCash, your animals are gone,
   your base has been rebuilt, the arena level reset, and the rebirth
   counter incremented.
3. The base's `MoneyMultPart` label now reads `Mult: 1.5x`.
4. **Your income is now 1.5x.** Place an animal and watch the pool grow
   faster.

**D. The multiplier survives a rejoin.**

1. Leave the server and rejoin.
2. The base label still reads `Mult: 1.5x` and income is still 1.5x.
3. If it reverted to `1x`, `ApplySessionModifiers` is not being called
   in your join handler.

**E. The requirement consumed the animal.**

1. If a rebirth requires two animals with the same DefId, you must
   own **two** of them. One animal cannot satisfy both rules.
2. Rebirth → both are consumed.

**F. The base was rebuilt, not moved.**

1. Note your base's position / id before the rebirth.
2. Rebirth. You are on the **same** base, with the new stand count.
3. Your `RespawnLocation` was re-pointed — die and you respawn at the
   current base.

**G. The stand count grew.**

1. At Rebirth 0 you have 6 animal stands + 1 arena stand.
2. After Rebirth 1 you have 6 animal stands + 2 arena stands.
3. At Rebirth 2: 7 + 2. Rebirth 3: 8 + 3.

**H. A guard rails.**

1. Pick up an animal (carry it) and try to rebirth → `Error = 'carrying'`.
2. Start an arena raid, then try to rebirth →
   `Error = 'raid-locked'`.
3. Try to rebirth twice in a row rapidly → the second is `'busy'`.

**I. The base-must-have-stands gate.**

1. Temporarily break the stand template so the rebuilt base has zero
   slots.
2. Rebirth → `Error = 'reset-failed'`, and **your animals and money are
   intact**. Restore the template afterwards.

---

## 7. Running the tests

`Tests/RebirthUnlocks.spec.lua` needs Roblox Studio — there is no
headless Luau runner in this project.

1. Copy `Systems/Rebirth/Tests/*.spec.lua` into your test tree.
2. Copy `ReusableSystems/Tests/_Helpers.lua` alongside them (the specs
   `require(script.Parent._Helpers)`).
3. Wire a TestEZ runner; see `ReusableSystems/Tests/README.md`.
4. Run in Studio.

The specs cover `RebirthUnlocks` and `StandShowcase` only. **The
transaction itself has no automated coverage** — the smoke test in
step 6 is the only verification. If you fork this system, add a spec
for `matchAnimals` and for the reset ordering.

The specs need **no DataStore, no published place, and no Robux**.

---

## 8. Trimming the system

| You want | Keep | Drop |
|---|---|---|
| A plain money/level rebirth | `RebirthService` + `Config/Economy/Rebirth.lua` | The preview machinery, the base label, the funnel/leaderboard calls |
| A rebirth with no stands | The above | `Stands` from every entry, the `DynamicSlotService.SetUnlockResolver` wiring, the `__Stand`/`__ArenaStand` preview clones |
| A rebirth with no animals | The above | The `Animals` arrays (set them empty) |
| A rebirth with no arena | The above | `ArenaLevel = 0` on every entry, `ArenaProgressionService.ResetArena` call, the `ArenaProgressionService` require |
| A rebirth that keeps your collection | The above | `Reset.Animals = false` — **but** the base reset still destroys the runtime animals, so you must re-home them or you will end up with orphan rows |

**Do not trim the base-first ordering.** It is the difference between
"a failed rebirth leaves the player intact" and "a failed rebirth
leaves the player baseless and animalless with no working retry."
