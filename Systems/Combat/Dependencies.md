# Combat — Dependencies

Exact, copy-pasteable. Every path is the **original Roblox path** —
the library's `Source/` tree mirrors it, so `require` calls resolve
unchanged when you copy the tree to the same place.

---

## Module Requires

### `ServerScriptService/Combat/BatService.lua`

```lua
require(game:GetService('ReplicatedStorage').Utility.Validation)
require(game:GetService('ReplicatedStorage').Utility.Remotes)
require(game:GetService('ReplicatedStorage').Utility.Debug)
require(game:GetService('ReplicatedStorage').Config.Economy.Gear).Combat
require(game:GetService('ReplicatedStorage').Types.SlotType)
require(game:GetService('ReplicatedStorage').Utility.AudioGroups)
require(script.Parent.RagdollService)                              -- same folder
require(script.Parent.Parent.Steal.StealService)                   -- ServerScriptService.Steal.StealService
require(game:GetService('ServerScriptService').Carry.CarryRegistry)
require(game:GetService('ServerScriptService').AnimalService)
require(game:GetService('ServerScriptService').EggService)
```

Line references: `BatService.lua:38-49`.

### `ServerScriptService/Combat/RagdollService.lua`

```lua
require(game:GetService('ReplicatedStorage').Utility.Debug)
```

Line reference: `RagdollService.lua:37`. `RagdollService` has **no
other dependencies** — not even `Players` is required (it uses the
`Player` instance as a table key).

### `ReplicatedStorage/Config/Economy/Gear.lua`

**No requires.** The gear catalog is pure data. It attaches
`Gear.Combat` to itself and freezes both tables.

---

## Other Systems Required

| System | Module | Why | Optional? |
|---|---|---|---|
| **Stealing** | `ServerScriptService.Steal.StealService` | `RollbackIfStealing(userId, reason)` cancels a steal-in-progress when the victim is bat-hit. | **Required** for the carry-interruption step. Without it, a thief can be knocked back while still holding the stolen object. The require is unconditional and top-level, so a missing module is a load-time error. |
| **Carry** | `ServerScriptService.Carry.CarryRegistry` | `IsCarrying(userId)` — the server-side tool lock (a carrying player cannot swing). `Get(userId)` — reads what the hit target is holding. | **Required**, top-level require. |
| **Animals** | `ServerScriptService.AnimalService` | `RecoverCarriedAnimal(userId, reason)` — returns the hit target's own carried animal to its original slot. | **Required** for the animal-carry branch of `interruptCarry`. Top-level require. |
| **EggsAndHatching** | `ServerScriptService.EggService` | `RecoverCarriedEgg(player, reason)` — returns the hit target's own carried egg. | **Required** for the egg-carry branch of `interruptCarry`. Top-level require. |
| **ShopsAndPurchases** | `ServerScriptService.GearShop.GearShopService` | Grants and equips the `Default Bat` on join; owns purchases. Combat only *reads* the shared `Gear` config. | **Optional for the combat pipeline** — a player with no bat Tool cannot swing, so it is required in practice for the feature to be usable. Combat does not require it. |
| **SharedUtilities** | `ReplicatedStorage.Config.Systems.Debug` | `Debug.ServerDebug` gates all combat logging. Read by the `Debug` utility, not directly by Combat. | Required for logging; behaviour is correct without it. |

Everything else is a **leaf dependency** — config and utility modules
with no back-references.

### Not included in this library

- `ReplicatedStorage.Packages.t` — required by
  `Shared/Utilities/Validation.lua` (which Combat uses). A **Wally
  package** (`osyrisrblx/t`); vendor it or install it via Wally.
- The **client** `BatController` (`StarterPlayerScripts/BatController.lua`).
  It lives in the source game's client tree, **not** in this system's
  `Source/`. See *Client Counterpart* below.

---

## Remotes

| Remote | Direction | Payload |
|---|---|---|
| `BatSwing` | C→S | **None.** `FireServer()` with zero arguments. The event means "I swung"; the server resolves the bat, cooldown, hitbox, and targets itself. |

There is **deliberately no hit-result remote**. The confirmed-hit
sound is server-mounted on the target's `HumanoidRootPart` and
`Debris`-cleaned after 6 s, so everyone in range hears it and the
client performs no additional round trip. The source config's
comment states: "no hit-result remote exists by design".

Remote name and contract live in
`ReplicatedStorage/Utility/Remotes.lua` (`Remotes.Names.BatSwing`,
line 214). The remotes folder is created at boot by
`bootstrap.createRemotes()`; **do not hand-author it**.

### Client Counterpart (not in this system)

The source game's client controller
(`StarterPlayerScripts/BatController.lua`) does:

1. Requires `ReplicatedStorage.Utility.Debug`,
   `ReplicatedStorage.Utility.Remotes`, and
   `ReplicatedStorage.Config.Economy.Gear` (the `.Combat` sub-table).
2. On a configured bat Tool's `Activated`:
   - local input gate against `entry.SwingCooldown` (cosmetic only —
     the server re-validates);
   - plays a local swing animation
     (`AnimationId = 'rbxassetid://79224347193775'`, `Priority =
     Action`, `Looped = false`, `track:Play(0.05)`) — the animation
     plays **on swing AND on miss**;
   - `FireServer()` with no payload.
3. Wires `Tool.Activated` on the equipped Tool only; backpack copies
   need no hook.

A new game must write its own client controller with this contract.

---

## Profile Fields Read / Written

**None.** The Combat system reads no profile fields and writes no
profile fields. It has no dependency on `PlayerService` at all.

It touches player state only through live instances:
`player.Character`, `player.Character:FindFirstChildOfClass('Humanoid')`,
`player.Character:FindFirstChild('HumanoidRootPart')`, and the
`Tool` child of the Character.

---

## Required Studio Assets

### `ServerStorage.Assets.Ui.GearShop.Tools/<ToolName>`

One `Tool` instance per gear catalog entry, whose `Name` **exactly**
matches the entry's `ToolName`:

```
ServerStorage
└── Assets
    └── Ui
        └── GearShop
            └── Tools
                ├── Speed Coil
                ├── Silver Bat
                ├── Gravity Coil
                ├── Gold Bat
                ├── Coil Combo
                ├── Diamond Bat
                ├── Obsidian Bat
                ├── Crystal Bat
                ├── Invisible Cloak
                ├── Hacker Bat
                ├── Galaxy Bat
                └── Default Bat
```

`Gear.ValidateLive()` reports a **missing** or **wrong-class**
(wrong-class = exists but is not a `Tool`) entry as an issue string.
`Default Bat` and `Galaxy Bat` are called out in the source config:
without the Tool asset, the grant "fails loudly and receipts retry".

The `Tool` also needs its own `Grip`/animation setup for the client
swing animation to look right; that is client-side presentation.

### `ServerStorage.Assets.Sfx.HitSfx.Attack1` / `Attack2` / `Attack3`

```
ServerStorage
└── Assets
    └── Sfx
        └── HitSfx
            ├── Attack1
            ├── Attack2
            └── Attack3
```

Each node may be a `Sound` **or** a folder containing a `Sound`
descendant (`BatService.resolveSfx` accepts both). A **flat**
`Assets.Sfx.AttackN` layout is also accepted — the source comment
says the boot mirror reads a flat `Assets.Sfx.Attack<N>`.

If none are found, the server emits one warning and every hit plays
silently. It never throws.

### Sound groups

`AudioGroups.AssignSfx` stamps the cloned hit sound into the
`GameSound` group. The groups are created at bootstrap by
`AudioGroups.EnsureGroups`; the client also creates a local fallback
if the replicated groups have not arrived.

### Workspace

**No Workspace assets are required by the Combat system.** The hitbox
is a purely mathematical query against whatever is already in the
workspace.

---

## External APIs

**None.** No `HttpService`, no `MarketplaceService`, no
`DataStoreService`, no `MessagingService`.

`GalaxyBat` is a Robux-only *catalog entry*; the actual purchase and
receipt handling belong to the **ShopsAndPurchases** system, not to
Combat. Combat only reads the granted Tool's name.

---

## Initialization Order

```text
1.  Remotes folder created (bootstrap.createRemotes)
2.  BaseService.RegisterBases(Workspace)
3.  BaseLockService.Init()
4.  StealService.SetPlayerService(PlayerService)
5.  StealService.Init()
6.  StealService.Start()
7.  BatService.Init()          -- wires Remotes.Names.BatSwing -> onSwing
8.  GearShopService.SetPlayerService(PlayerService)
9.  GearShopService.SetEconomyService(EconomyService)
10. GearShopService.Init()    -- grants + equips the Default Bat
```

Notes:

- `BatService.Init()` must be called **before players join**.
- `BatService.Init()` must run **after** `StealService.Init()` and
  `StealService.Start()`, because a bat hit calls
  `StealService.RollbackIfStealing`.
- The `Remotes` folder must exist before step 7; the `WaitForChild`
  has a **10-second** timeout and a missing remote only warns.
- `RagdollService` has **no `Init()`** — it is stateless until the
  first `Ragdoll()` call, and `BatService` requires it directly at
  load time.
- `GearShopService.Init()` (step 10) is what grants and equips the
  `Default Bat`. It does not need to precede step 7, but a player
  cannot swing until their gear grant lands.
- `BatService` has **no injection points** (no `Set*Service()`).
  It resolves `StealService`, `CarryRegistry`, `AnimalService`, and
  `EggService` by direct `require`, which is why none of them
  require `BatService` back.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
