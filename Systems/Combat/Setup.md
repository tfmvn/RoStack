# Combat — Setup

Installing the Combat system into a **new** Rojo project. Every path
below is the destination Roblox path; the library's `Source/` tree
mirrors it, so the `require` calls resolve unchanged.

---

## 1. Copy the files

| From the library | To your Rojo project | Roblox path |
|---|---|---|
| `Systems/Combat/Source/ServerScriptService/Combat/BatService.lua` | `src/ServerScriptService/Combat/BatService.lua` | `ServerScriptService.Combat.BatService` |
| `Systems/Combat/Source/ServerScriptService/Combat/RagdollService.lua` | `src/ServerScriptService/Combat/RagdollService.lua` | `ServerScriptService.Combat.RagdollService` |
| `Systems/Combat/Source/ReplicatedStorage/Config/Economy/Gear.lua` | `src/ReplicatedStorage/Config/Economy/Gear.lua` | `ReplicatedStorage.Config.Economy.Gear` |

Also copy the shared leaves this system requires (from
`ReusableSystems/Shared/`):

| From the library | To your Rojo project | Roblox path |
|---|---|---|
| `Shared/Utilities/Validation.lua` | `src/ReplicatedStorage/Utility/Validation.lua` | `ReplicatedStorage.Utility.Validation` |
| `Shared/CommonModules/Remotes.lua` | `src/ReplicatedStorage/Utility/Remotes.lua` | `ReplicatedStorage.Utility.Remotes` |
| `Shared/Utilities/Debug.lua` | `src/ReplicatedStorage/Utility/Debug.lua` | `ReplicatedStorage.Utility.Debug` |
| `Shared/Utilities/AudioGroups.lua` | `src/ReplicatedStorage/Utility/AudioGroups.lua` | `ReplicatedStorage.Utility.AudioGroups` |
| `Shared/Types/SlotType.lua` | `src/ReplicatedStorage/Types/SlotType.lua` | `ReplicatedStorage.Types.SlotType` |
| `Shared/Utilities/StudioTestMode.lua` | `src/ReplicatedStorage/Utility/StudioTestMode.lua` | `ReplicatedStorage.Utility.StudioTestMode` |
| `Shared/Utilities/BigNumber.lua` | `src/ReplicatedStorage/Utility/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` (only if `Validation` needs it — it does) |
| `Shared/Types/RarityType.lua` | `src/ReplicatedStorage/Types/RarityType.lua` | `ReplicatedStorage.Types.RarityType` (only if `Validation` needs it — it does) |

`Shared/Utilities/Validation.lua` also requires
`ReplicatedStorage.Packages.t` (see step 2) and
`ReplicatedStorage.Utility.BigNumber` /
`ReplicatedStorage.Types.RarityType`.

Note on the library's shared layout: `ReusableSystems/Shared/Utilities/`,
`Shared/CommonModules/`, and `Shared/Types/` all land in
`ReplicatedStorage.Utility.*` / `ReplicatedStorage.Types.*` in the
original game. The two `Utility` sub-folders merge into the same
destination.

**You also need the systems Combat depends on** (see
[`Dependencies.md`](Dependencies.md)):

- `ServerScriptService.Steal.StealService` (Stealing system)
- `ServerScriptService.Carry.CarryRegistry` (Carry system)
- `ServerScriptService.AnimalService` (Animals system)
- `ServerScriptService.EggService` (EggsAndHatching system)

If you are installing Combat **alone** into a fresh game, you must
either port those four modules or stub them — `BatService` requires
all four at load time and will error on a missing module.

---

## 2. Install third-party packages (Wally)

`ReplicatedStorage.Utility.Validation` re-exports the `t` library, so
`t` is mandatory:

```toml
# wally.toml
[package]
name = "yourgame/yourgame"
version = "0.1.0"
registry = "https://github.com/UpliftGames/wally-index"
realm = "shared"

[dependencies]
t = "osyrisrblx/t@^2.2.1"
```

Then:

```bash
wally install
```

and map `Packages/` into `ReplicatedStorage.Packages` in your
`default.project.json`:

```json
{
  "name": "yourgame",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage",
      "Packages": { "$path": "Packages" }
    },
    "ServerScriptService": { "$path": "src/ServerScriptService" },
    "StarterPlayer": {
      "StarterPlayerScripts": { "$path": "src/StarterPlayer/StarterPlayerScripts" }
    },
    "StarterGui": { "$path": "src/StarterGui", "$ignoreUnknownInstances": true },
    "Workspace": { "$path": "src/Workspace", "$ignoreUnknownInstances": true }
  }
}
```

`Combat` itself needs **no** other package (no `Janitor`, no
`Cmdr`, no `ProfileService`, no `Promise`, no `Fusion`).

---

## 3. Author the Studio assets

### 3a. The gear Tools (mandatory)

Create one `Tool` instance per gear catalog entry, under
`ServerStorage.Assets.Ui.GearShop.Tools`, with the `Name` **exactly**
matching the catalog's `ToolName`:

```
ServerStorage.Assets.Ui.GearShop.Tools
├── Speed Coil        (Tool)
├── Silver Bat        (Tool)   <- needed for combat
├── Gravity Coil      (Tool)
├── Gold Bat          (Tool)   <- needed for combat
├── Coil Combo        (Tool)
├── Diamond Bat       (Tool)   <- needed for combat
├── Obsidian Bat      (Tool)   <- needed for combat
├── Crystal Bat       (Tool)   <- needed for combat
├── Invisible Cloak   (Tool)
├── Hacker Bat        (Tool)   <- needed for combat
├── Galaxy Bat        (Tool)   <- needed for combat
└── Default Bat       (Tool)   <- needed for combat
```

The eight listed in the comment are the ones with a
`Gear.Combat` entry. The other four are catalog-only (not bats) and
can be omitted **if you also remove their catalog entries** — but
`Gear.ValidateLive()` will flag them as missing otherwise.

A `Tool` needs a `Grip` and a `RequiresHandle` setting appropriate
for a bat; the client swing animation is cosmetic and played on the
character, so the Tool's own animation is optional.

### 3b. The hit SFX (optional but recommended)

```
ServerStorage.Assets.Sfx.HitSfx.Attack1   (Sound, or a Folder containing a Sound)
ServerStorage.Assets.Sfx.HitSfx.Attack2   (Sound, or a Folder containing a Sound)
ServerStorage.Assets.Sfx.HitSfx.Attack3   (Sound, or a Folder containing a Sound)
```

A flat `ServerStorage.Assets.Sfx.Attack1..3` layout is also accepted.
If these are missing the server warns once and every hit is silent.

### 3c. Sound groups

Create the group tree at boot, or let `AudioGroups.EnsureGroups` do
it:

```
SoundService
└── GameSound   (SoundGroup)  - master game volume
    └── BgmSound (SoundGroup) - music only
```

`AudioGroups.EnsureGroups(0)` is idempotent and safe to call from
your server bootstrap.

### 3d. Workspace

**Nothing.** The hitbox is a mathematical query; no Workspace assets
are needed.

---

## 4. Add the `BatSwing` remote

The remote is created at boot from the remotes registry — do not
hand-author it as a Rojo-mapped instance.

1. Add the name to your remotes registry
   (`ReplicatedStorage/Utility/Remotes.lua`):

   ```lua
   Remotes.Names.BatSwing = 'BatSwing'
   ```

2. In your server bootstrap, call the same `createRemotes()` helper
   the shared `Remotes` module expects (see
   `Remotes.SetRemotes` / `Remotes.GetFolder` /
   `Remotes.WaitForReady` in `Shared/CommonModules/Remotes.lua`).
   The `BatSwing` entry must be a `RemoteEvent`.

3. The **contract is load-bearing**: `BatSwing` is C→S with **no
   payload**. The server reads the player's equipped Tool to decide
   everything.

---

## 5. Wire the client

The client counterpart is **not** part of this system — you must write
it. Put it at `StarterPlayer/StarterPlayerScripts/BatController.lua`:

```lua
local Players = game:GetService('Players')
local ReplicatedStorage = game:GetService('ReplicatedStorage')

local Remotes = require(ReplicatedStorage.Utility.Remotes)
local BatConfig = require(ReplicatedStorage.Config.Economy.Gear).Combat

local localPlayer = Players.LocalPlayer
local lastLocalSwing = 0

local function onActivated(tool: Tool)
    local entry = BatConfig.GetByToolName(tool.Name)
    if entry == nil then
        return                        -- not a bat
    end
    local now = os.clock()
    if now - lastLocalSwing < entry.SwingCooldown then
        return                        -- cosmetic local gate only
    end
    lastLocalSwing = now
    -- (optional) play a local swing animation on the character
    local folder = Remotes.WaitForReady()
    local remote = folder:WaitForChild(Remotes.Names.BatSwing, 10)
    if remote ~= nil and remote:IsA('RemoteEvent') then
        remote:FireServer()           -- NO PAYLOAD
    end
end
```

Then connect `Tool.Activated` for each Tool that appears in the
character, and re-hook on `CharacterAdded`. The source game's
controller is `src/StarterPlayer/StarterPlayerScripts/BatController.lua`
in Brainrot Arena — copy it verbatim if you want the exact feel
(local animation id `rbxassetid://79224347193775`).

---

## 6. Bootstrap sequence

The exact order, from the source game's
`src/ServerScriptService/bootstrap.server.lua`:

```lua
-- top of the bootstrap, after the Remotes folder is created
local BatService = require(script.Parent.Combat.BatService)

-- ... other service inits ...

-- section 5: register Studio assets
BaseService.RegisterBases(Workspace)
BaseLockService.Init()

-- section 6: stealing must be live before bats
StealService.SetPlayerService(PlayerService)
StealService.Init()
StealService.Start()

-- section 6: Bat PvP — before players join
BatService.Init()

-- section 6: gear shop — grants + equips the Default Bat
GearShopService.SetPlayerService(PlayerService)
GearShopService.SetEconomyService(EconomyService)
GearShopService.Init()
```

Rules:

- `BatService.Init()` needs the **Remotes folder to exist** (it waits
  10 s for `BatSwing`, then warns and disables if absent).
- `BatService.Init()` must come **after** `StealService.Init()` and
  `StealService.Start()` — a bat hit calls
  `StealService.RollbackIfStealing`.
- `BatService.Init()` must come **before players join**.
- `RagdollService` has **no `Init()`** — nothing to call.
- `BatService` has **no `Set*Service()` injection** — it resolves
  `StealService`, `CarryRegistry`, `AnimalService`, and `EggService`
  by direct `require`.

---

## 7. Configuration to tune

Open `ReplicatedStorage/Config/Economy/Gear.lua` (or the
documentation-only consolidation in [`Config.lua`](Config.lua)):

- **`Gear.Combat` table** — per-bat `SwingCooldown`, `Hitbox.Size`,
  `Hitbox.Offset`, `Knockback.Horizontal/Vertical`,
  `RagdollDuration`, `RagdollImmunity`.
  Remember the runtime multiplies `Hitbox.Size` by a hard-coded
  **1.75** (`BatService.lua:213`).
- **`Gear.ENTRIES`** — the shop catalog. Every `Price` and
  `Description` is a `PLACEHOLDER:` in the source; tune before
  release.
- **Only eight of the thirteen gears have a combat entry.** A gear
  with a Tool but no combat entry cannot swing.
- **`ReplicatedStorage.Config.Systems.Debug`** — set
  `ServerDebug = true` to see the `Bat` tag's `Debug.Log` /
  `Debug.Warn` output while testing. It defaults to `false`, so
  production is silent.

---

## 8. Smoke test

Run these in order in a **Studio** multi-player test (two players
needed from step 4 onward):

1. **Config validation.** Call `require(ReplicatedStorage.Config.Economy.Gear).ValidateLive()` and
   `...Combat.Validate()` from the command bar. Both should return
   empty tables. A non-empty result names the missing Tool or the
   bad field.
2. **Remote wiring.** `BatService.Init()` should not warn. If it
   warns `BatSwing remote missing`, your remotes registry or
   `createRemotes()` is wrong.
3. **Equipment.** Give the test player the `Default Bat` Tool and
   equip it. The `Tool`'s `Name` must be exactly `Default Bat`.
4. **Swing.** Activate the Tool. The client's local animation should
   play. With `Debug.ServerDebug = true` the server console should
   print `[Bat] swing player=...` and, if a target is in range,
   `[Bat] hit attacker=... target=...`.
5. **Knockback + ragdoll.** With the second player 1–2 studs in
   front, the target should be shoved and go limp for
   `RagdollDuration` seconds (1.25 s for the Default Bat). The
   console should print `[Bat] ragdoll target=...` and
   `[Bat] knockback target=...`.
6. **Cooldown.** Swinging twice in a row within 1.0 s (Default Bat)
   should print `[Bat] rejected cooldown player=...` on the second.
7. **Carry interruption.** Pick up an animal with the target
   (`CarryRegistry.Set` via a test script, or in-game), then bat-hit
   them. The animal should be returned to its original slot and
   `[Bat] carry interrupted player=...` should print.
8. **Ragdoll immunity.** Bat-hit the same target twice in a row.
   The second hit should print `[Bat] ragdoll immune target=...` and
   the target should **keep** the knockback but not be re-ragdolled.
9. **SFX.** With the hit SFX assets present, everyone in range should
   hear a hit sound. Without them you get one
   `[Bat] HitSfx missing ...` warning and silence.
10. **Admin check.** `ragdoll <player>` and `unragdoll <player>`
    from the Cmdr admin console should report success/failure
    correctly — they call `RagdollService.Ragdoll` /
    `Unragdoll` directly.

**No automated test covers this system.** `Systems/Combat/Tests/`
contains three specs that exercise the **Carry** system
(`CarryService.spec.lua`, `PlayerGrab.spec.lua`,
`ResetProtection.spec.lua`) — they were placed there during
extraction. If you want regression coverage, write
`BatService.spec.lua` around the seams that already exist:
`BatService._TestReset()`, `RagdollService._TestReset()`, and the
`Remotes` stub helper (`_Helpers.StubRemotes()`) used by the existing
specs.

---

- [README.md](README.md) — overview, entry points, limitations.
- [MEMORY.md](MEMORY.md) — step-by-step mechanics and gotchas.
- [Dependencies.md](Dependencies.md) — require paths, remotes, assets, init order.
- [Setup.md](Setup.md) — install into a new Rojo project.
- [API.md](API.md) — every public function, with failure modes.
