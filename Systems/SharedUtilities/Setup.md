# SharedUtilities — Setup

Installing the SharedUtilities system into a new Rojo project.

This system is **two things**: five config domains and six small
server-side leaf modules. It also ships a **reference copy** of the
source game's whole-game bootstrap — that copy is for reading, not
installing (see step 5).

---

## 0. Read this first

Two facts that change the install:

1. **The shared modules are not in this system's `Source/` tree.**
   `ReplicatedStorage.Utility.Debug`, `ConfigValidator`, `Validation`,
   `StudioTestMode`, `Remotes`, `AudioGroups`, `WeightedDraw`,
   `BigNumber` and `Types/RarityType` live in
   `ReusableSystems/Shared/`. You must copy them separately — step 3.

2. **`bootstrap.server.lua` in this system's `Source/` tree is the
   source game's entire 1426-line boot script**, byte-identical to
   `src/ServerScriptService/bootstrap.server.lua`. It requires ~50
   modules across the whole game. **Do not copy it.** Read it for the
   wiring order, then wire your own bootstrap — step 5.

---

## 1. Copy the five config domains

```bash
SRC=ReusableSystems/Systems/SharedUtilities/Source
DST=your-project/src

mkdir -p "$DST/ReplicatedStorage/Config/Systems"
mkdir -p "$DST/ReplicatedStorage/Config/World"
mkdir -p "$DST/ReplicatedStorage/Config/Presentation"

cp "$SRC/ReplicatedStorage/Config/Systems/Debug.lua"          "$DST/ReplicatedStorage/Config/Systems/"
cp "$SRC/ReplicatedStorage/Config/World/Movement.lua"         "$DST/ReplicatedStorage/Config/World/"
cp "$SRC/ReplicatedStorage/Config/Presentation/Audio.lua"     "$DST/ReplicatedStorage/Config/Presentation/"
cp "$SRC/ReplicatedStorage/Config/Presentation/UI.lua"        "$DST/ReplicatedStorage/Config/Presentation/"
cp "$SRC/ReplicatedStorage/Config/Presentation/Vfx.lua"       "$DST/ReplicatedStorage/Config/Presentation/"
```

| Library path | Roblox destination |
|---|---|
| `Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage.Config.Systems.Debug` |
| `Source/ReplicatedStorage/Config/World/Movement.lua` | `ReplicatedStorage.Config.World.Movement` |
| `Source/ReplicatedStorage/Config/Presentation/Audio.lua` | `ReplicatedStorage.Config.Presentation.Audio` |
| `Source/ReplicatedStorage/Config/Presentation/UI.lua` | `ReplicatedStorage.Config.Presentation.UI` |
| `Source/ReplicatedStorage/Config/Presentation/Vfx.lua` | `ReplicatedStorage.Config.Presentation.Vfx` |

**Do not move `UI.lua`.** It does
`require(script.Parent.Parent.Creatures.Rarity)` — `script.Parent` is
`Config.Presentation` and `script.Parent.Parent` is
`ReplicatedStorage.Config`. The file **must** sit at
`Config/Presentation/UI.lua` or the require fails. That also means
you need `ReplicatedStorage/Config/Creatures/Rarity.lua` to exist
(see step 3).

---

## 2. Copy the six server modules

```bash
mkdir -p "$DST/ServerScriptService/Utility"

cp "$SRC/ServerScriptService/ServerLuckService.lua"  "$DST/ServerScriptService/"
cp "$SRC/ServerScriptService/SettingsService.lua"     "$DST/ServerScriptService/"
cp "$SRC/ServerScriptService/Utility/MoneyIcon.lua"       "$DST/ServerScriptService/Utility/"
cp "$SRC/ServerScriptService/Utility/MutationIcon.lua"    "$DST/ServerScriptService/Utility/"
cp "$SRC/ServerScriptService/Utility/PathfindingUtil.lua" "$DST/ServerScriptService/Utility/"
cp "$SRC/ServerScriptService/Utility/WaterHazard.lua"     "$DST/ServerScriptService/Utility/"
```

| Library path | Roblox destination |
|---|---|
| `Source/ServerScriptService/ServerLuckService.lua` | `ServerScriptService.ServerLuckService` |
| `Source/ServerScriptService/SettingsService.lua` | `ServerScriptService.SettingsService` |
| `Source/ServerScriptService/Utility/MoneyIcon.lua` | `ServerScriptService.Utility.MoneyIcon` |
| `Source/ServerScriptService/Utility/MutationIcon.lua` | `ServerScriptService.Utility.MutationIcon` |
| `Source/ServerScriptService/Utility/PathfindingUtil.lua` | `ServerScriptService.Utility.PathfindingUtil` |
| `Source/ServerScriptService/Utility/WaterHazard.lua` | `ServerScriptService.Utility.WaterHazard` |

**`SettingsService` must be a direct child of `ServerScriptService`** —
it does `require(script.Parent.PlayerService)`.

**`ServerLuckService` must also be a direct child of
`ServerScriptService`** — `EggService` does
`require(script.Parent.ServerLuckService)`.

---

## 3. Copy the shared dependencies

These are **not** in this system's `Source/` tree. They live in
`ReusableSystems/Shared/`.

```bash
SHARED=ReusableSystems/Shared
DST=your-project/src

mkdir -p "$DST/ReplicatedStorage/Utility"
mkdir -p "$DST/ReplicatedStorage/Types"

cp "$SHARED/Utilities/Debug.lua"           "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/ConfigValidator.lua" "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/Validation.lua"      "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/StudioTestMode.lua"  "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/AudioGroups.lua"     "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/WeightedDraw.lua"    "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Utilities/BigNumber.lua"       "$DST/ReplicatedStorage/Utility/"
cp "$SHARED/Types/RarityType.lua"          "$DST/ReplicatedStorage/Types/"
```

| Roblox destination | Required by | Required? |
|---|---|---|
| `ReplicatedStorage.Utility.Debug` | all six modules | **Yes** — non-deferred. |
| `ReplicatedStorage.Utility.ConfigValidator` | the bootstrap | Yes — otherwise nothing validates. |
| `ReplicatedStorage.Utility.Validation` | `SettingsService` | **Yes** — non-deferred. Pulls in `Packages.t` and `Types.RarityType`. |
| `ReplicatedStorage.Utility.StudioTestMode` | `Validation` (transitively) | Yes — comes along with `Validation`. |
| `ReplicatedStorage.Utility.BigNumber` | `Validation` (transitively) | Yes — comes along with `Validation`. |
| `ReplicatedStorage.Utility.Remotes` | `SettingsService` | **Yes** — non-deferred. (It also lives in `Shared/CommonModules/Remotes.lua`.) |
| `ReplicatedStorage.Utility.AudioGroups` | the bootstrap | Optional. |
| `ReplicatedStorage.Utility.WeightedDraw` | the luck spec only | Optional for runtime, needed for the test. |
| `ReplicatedStorage.Types.RarityType` | `Validation` | Yes. |

You also need, from **other systems**:

| Roblox destination | Why |
|---|---|
| `ReplicatedStorage.Config.Creatures.Rarity` | `ServerLuckService` (`LuckExponentDivisor`) and `Config.Presentation.UI` (`RarityColor`). |
| `ReplicatedStorage.Config.World.Events` | `ServerLuckService` (`LuckPoolOrder`). **Either keep it or move the field** — see step 4. |
| `ServerScriptService.PlayerService` | `SettingsService` reads and writes `profile.Data.Settings`. |

---

## 4. Third-party packages (Wally)

```toml
[dependencies]
t = "osyrisrblx/t@^2.2.1"

[dev-dependencies]
TestEZ = "roblox/testez@^0.4.0"
```

`t` is required by `ReplicatedStorage.Utility.Validation`
(`require(script.Parent.Parent.Packages.t)`). Rojo must map your
`Packages/` folder to `ReplicatedStorage/Packages` for the require to
resolve:

```json
{
  "name": "your-game",
  "tree": {
    "$className": "DataModel",
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage",
      "Packages": { "$path": "Packages" }
    },
    "ServerScriptService": { "$path": "src/ServerScriptService" }
  }
}
```

TestEZ is only needed to run the specs (step 8).

---

## 5. Wire it up

**Do not copy `Source/ServerScriptService/bootstrap.server.lua`.** It
is the source game's whole-game boot script. Instead, write your own
bootstrap that does the same thing in the same order.

### 5a. The debug + validation block (do this FIRST)

In your `ServerScriptService/bootstrap.server.lua`:

```lua
local DebugConfig = require(ReplicatedStorage.Config.Systems.Debug)
local ConfigValidator = require(ReplicatedStorage.Utility.ConfigValidator)
local Debug = require(ReplicatedStorage.Utility.Debug)
local StudioTestMode = require(ReplicatedStorage.Utility.StudioTestMode)

-- 1. Sync the debug switches FIRST. Everything after this can log.
Debug.SyncFromDebugConfig(DebugConfig)

-- 2. Central config validation. Studio: fail LOUDLY.
--    Live servers: warn, so a bad tune never hard-crashes production.
if DebugConfig.ConfigValidation == true then
    local okValidate, validateErr = pcall(ConfigValidator.AssertValid)
    if not okValidate then
        local RunService = game:GetService('RunService')
        local inStudio = false
        pcall(function() inStudio = RunService:IsStudio() end)
        if inStudio then
            error(tostring(validateErr), 0)
        else
            warn(tostring(validateErr))
        end
    end
end

-- 3. Seed the mutable Studio test-id switch from the frozen config.
StudioTestMode.Enabled = DebugConfig.AllowStudioTestUserIds == true
```

**Step 1 must be first.** Any `Debug.Log` before the sync is silenced
(the switches default to `false`).

### 5b. The leaf services

```lua
local SettingsService = require(script.Parent.SettingsService)
local WaterHazard = require(script.Parent.Utility.WaterHazard)

-- Later in the boot, after the rest of the world is up:
WaterHazard.Init()      -- instant-death water
SettingsService.Init()  -- connects the SaveSettings remote
```

### 5c. `ServerLuckService.Init()`

**There is no bootstrap line for this in the source game** — it is
called from `EggService.Init`. If you have an `EggService`, it does
it for you. If you do not, call it yourself:

```lua
local ServerLuckService = require(script.Parent.ServerLuckService)
ServerLuckService.Init()
```

`Init()` publishes the `ServerLuck` attribute so it exists from boot.
Call it **before the first egg roll** — late joiners and the first
roll read the attribute.

### 5d. The remotes

`SettingsService.Init()` waits up to 10 seconds for the `SaveSettings`
remote. Create the remote folder in your own `createRemotes()` step
(the shared `Remotes` module is the registry — it is the source of
truth for the name `SaveSettings` and for `SettingsState`).

### 5e. The client side

Your client bootstrap must call
`Debug.SyncFromDebugConfig(DebugConfig)` **on its own side**. The
client and server switches are independent — flipping the server one
never enables client output.

---

## 6. Configure

There is **no `Config.lua`** in the live game for this system — its
configuration *is* the five domain modules. The library's
[`Config.lua`](Config.lua) is a **documented reference transcription**
with every tunable, its default, its valid range, its safety and its
reader. Editing it changes nothing at runtime.

### 6a. Register the config domains (if you use the validator)

`ReplicatedStorage/Utility/ConfigValidator.lua` has a `_MODULES` list.
Add this system's entries:

```lua
{ Name = 'World.Movement',            Path = { 'World', 'Movement' } },
{ Name = 'World.Movement.Player',     Path = { 'World', 'Movement' }, Sub = 'Player' },
{ Name = 'Systems.Debug',             Path = { 'Systems', 'Debug' } },
{ Name = 'Presentation.Audio',        Path = { 'Presentation', 'Audio' } },
{ Name = 'Presentation.Vfx',          Path = { 'Presentation', 'Vfx' } },
{ Name = 'Presentation.UI.Overhead',  Path = { 'Presentation', 'UI' }, Sub = 'Overhead' },
```

`Presentation.UI` (the root) and `Presentation.UI.Notify` have **no**
`Validate()` — the validator's contract exempts presentation-only
domains without rules.

### 6b. The tunables you will want to touch first

| File | Key | Default | What it does |
|---|---|---|---|
| `Config/Systems/Debug.lua` | `ServerDebug` | `false` | Turns the server's diagnostic output on. |
| `Config/Systems/Debug.lua` | `ClientDebug` | `false` | Turns the client's diagnostic output on. |
| `Config/Systems/Debug.lua` | `Tags` | `{}` | A per-tag whitelist. **Only applied when non-empty.** If you use it, add `LUCK`, `Settings`, `IN`, `MI`, `Water`. |
| `Config/Systems/Debug.lua` | `AllowStudioTestUserIds` | `true` | Accepts Studio test UserIds. Harmless at publish — the `IsStudio()` gate is in `StudioTestMode`. |
| `Config/World/Movement.lua` | `Player.WalkSpeed` | `20` | The default avatar walk speed. |
| `Config/World/Movement.lua` | `Player.JumpPower` | `50` | The default avatar jump power. |
| `Config/World/Movement.lua` | `YawSmoothing` | `8.0` | The shared turn rate for all three walkers. |
| `Config/Presentation/UI.lua` | `Notify.MaxTextLength` | `120` | The toast text cap. |
| `Config/Presentation/UI.lua` | `Notify.CoalesceWindow` | `1.5` | Same-category toast coalescing. |
| `Config/Presentation/UI.lua` | `Overhead.Rainbow.Period` | `3` | The rainbow overhead cycle. |
| `Config/Presentation/Audio.lua` | `Collect.PoolSize` | `4` | The per-player CashClaim SFX pool. |
| `Config/Presentation/Vfx.lua` | `LevelUp.Lifetime` / `CleanupCap` | `2.0` / `1.2` | The level-up celebration cleanup. |

### 6c. The luck pool order — decide where it lives

`ServerLuckService` reads `Events.LuckPoolOrder` from
`ReplicatedStorage.Config.World.Events`. Two options:

- **Keep the Events config** — zero code change, and the central
  validator's JOIN rule keeps it honest.
- **Move it.** Change `ServerLuckService.lua:31` to require your own
  config, and move the field:

```lua
-- ServerScriptService/ServerLuckService.lua
local RarityConfig = require(ReplicatedStorage.Config.Creatures.Rarity)
local LuckConfig = require(ReplicatedStorage.Config.Systems.Luck)  -- yours
local Debug = require(ReplicatedStorage.Utility.Debug)

local LUCK_POOL: { string } = LuckConfig.LuckPoolOrder
```

The order **must** favour Mythic most — it is deliberately different
from `Rarity.Order`, which sorts Mythic *below* Legendary.

---

## 7. Author the Studio assets

All optional, but each one has a graceful degradation.

### 7a. The money icon

```
ServerStorage
└── Assets
    └── Decals
        └── MoneyIcon      -- an ImageLabel with a populated Image
```

`ReplicatedStorage/Assets/Decals/MoneyIcon` is the fallback.
`ServerStorage` is checked **first**.

Without it, the client falls back to a `"$"` chip and the server logs
**one** warning per process.

### 7b. The mutation decals

```
ServerStorage
└── Assets
    └── Decals
        ├── GalaxyIcon      -- for the 'Galactic' mutation
        └── SnowfallIcon    -- for the 'Frost' mutation
```

The mapping is fixed in `MutationIcon.lua`:

| Mutation id | Decal asset |
|---|---|
| `Galactic` | `GalaxyIcon` |
| `Frost` | `SnowfallIcon` |

Any other id maps to `nil` — **no icon is invented**. Without a decal,
the overhead keeps the prototype's authored visuals.

### 7c. The water

```
Workspace
└── Water          -- a BasePart, or a Model/Folder of BaseParts
```

Anything with a `Humanoid` that touches it gets `Health = 0`. A
missing `Water` warns and arms a `ChildAdded` retry — but the retry
only fires for a **direct child of `Workspace` named exactly
`Water`**.

---

## 8. The tests

### 8a. What to copy

| Spec | Copy it? | Needs |
|---|---|---|
| `Tests/ServerLuckService.spec.lua` | Yes | `ServerScriptService.TestEZTests._Helpers`, `ReplicatedStorage.Utility.WeightedDraw`, `ReplicatedStorage.Config.Creatures.Rarity` |
| `Tests/ServerLuckBoost.spec.lua` | Yes | nothing extra |
| `Tests/ConfigArchitecture.spec.lua` | Only if you port the whole config tree | every config domain in the game |
| `Tests/StudioTestUserIds.spec.lua` | Only | `ReplicatedStorage.Utility.StudioTestMode`, `ReplicatedStorage.Types.SlotType` |
| `Tests/BigNumber.spec.lua` | Not this system | `ReplicatedStorage.Utility.BigNumber` |
| `Tests/RichTextFormatter.spec.lua` | Not this system | `ReplicatedStorage.Utility.RichTextFormatter` |
| `Tests/StatCalculator.spec.lua` | Not this system | `ReplicatedStorage.Utility.StatCalculator` |
| `Tests/HudTree.spec.lua` | Not this system | `StarterPlayer.StarterPlayerScripts.HudTree` |
| `Tests/PromptOwnerFilter.spec.lua` | Not this system | `ServerScriptService.Animal.CarryPrompts`, `ReplicatedStorage.Types.SlotType` |
| `Tests/SellConfirmViewport.spec.lua` | Not this system | `StarterPlayer.StarterPlayerScripts.SellConfirmController` |

### 8b. The test-helper module

`ServerLuckService.spec.lua` requires:

```lua
local Helpers = require(ServerScriptService.TestEZTests._Helpers)
```

That module is **not** in this system's `Tests/` folder. In the source
game it lives at `src/Tests/ServerScriptService/TestEZTests/_Helpers.lua`
and Rojo maps it to `ServerScriptService.TestEZTests` via
`test.project.json`:

```json
"ServerScriptService": {
    "$path": "src/ServerScriptService",
    "TestEZTests": { "$path": "src/Tests/ServerScriptService/TestEZTests" }
}
```

Copy `_Helpers.lua` too, or the spec fails to load.

### 8c. Running

The specs are **TestEZ** specs and need **Roblox Studio** — there is
no headless Luau runner in this project. Open the test place
(`test.project.json`), start the server, and TestEZ runs the specs in
the Output window.

### 8d. The known failure

`ConfigArchitecture.spec.lua:183` asserts:

```lua
expect(Movement.Player.WalkSpeed).to.equal(24)
```

but `Config/World/Movement.lua:129` sets `WalkSpeed = 20`. The source
files are byte-identical between `src/` and this system, so **this
spec fails as shipped** — a pre-existing defect, not something the
library introduced.

If you port the spec, fix it one way or the other:

```lua
-- option A: the config is right, the spec is stale
expect(Movement.Player.WalkSpeed).to.equal(20)

-- option B: the spec is right — change the config to 24 AND
-- update the source comment, which currently says
-- "CURRENT: 20 (spec baseline; comment once said 16)"
```

---

## 9. Smoke test

### 9a. The config validates

In the Studio command bar (server context):

```lua
local ConfigValidator = require(ReplicatedStorage.Utility.ConfigValidator)
local issues = ConfigValidator.ValidateAll()
print(#issues, 'issues')
for _, i in ipairs(issues) do print(' - ' .. i) end
```

Expect `0 issues`. This also runs automatically at boot, and a
non-empty result is a **hard error in Studio**.

### 9b. The debug switches work

```lua
local Debug = require(ReplicatedStorage.Utility.Debug)
Debug.SetEnabled(true)                       -- the current side only
Debug.Log('SMOKE', 'hello', { a = 1 })        -- -> [SMOKE] hello a=1
```

Then flip `Systems.Debug.ServerDebug = true` and restart to see the
`[LUCK]`, `[Settings]`, `[Water]` streams.

### 9c. The luck service

```lua
local Luck = require(ServerScriptService.ServerLuckService)
print(Luck.GetLuck())          -- 1
print(Luck.SetLuck(4))         -- true
print(Luck.GetLuck())          -- 4
print(Luck.ApplyLuck({ Common = 100, Mythic = 1 }))   -- Common 100, Mythic 4^(5/3) ≈ 10.08
print(Luck.SetLuck(0))         -- false (rejected)
print(Luck.ResetLuck())        -- true
```

And with a client connected, `ReplicatedStorage:GetAttribute('ServerLuck')`
should track the value.

**A boost, end to end:**

```lua
local token = Luck.ActivateBoost(4, 60, 'smoke')
print(Luck.GetLuck())          -- 4
print(Luck.GetBoostInfo().mult) -- 4
Luck.OnBoostExpired(function(info) print('expired', info.expiredMult) end)
Luck.SetLuck(1)                -- admin cancels the boost
print(Luck.GetLuck())          -- 1
print(Luck.GetBoostInfo())     -- nil
```

### 9d. The settings service

```lua
local Settings = require(ServerScriptService.SettingsService)
print(Settings.GetSettings(12345).Bgm)   -- 1 (the default shape)
```

Then, with a client connected, change the BGM slider in the settings
UI and check that `profile.Data.Settings` changes and that the value
survives a rejoin.

### 9e. The water hazard

Author `Workspace.Water` as a `BasePart`. Walk into it → the character
dies. If `Workspace.Water` does not exist, the Output window shows
`'[Water] Workspace.Water missing; hazard inactive (retrying on
ChildAdded)'`.

### 9f. The icon resolvers

```lua
local MoneyIcon = require(ServerScriptService.Utility.MoneyIcon)
print(MoneyIcon.Resolve())     -- a table, or nil if the decal is missing

local MutationIcon = require(ServerScriptService.Utility.MutationIcon)
print(MutationIcon.DecalNameFor('Galactic'))   -- GalaxyIcon
print(MutationIcon.DecalNameFor('Ancient'))    -- nil
print(MutationIcon.ResolveImage('Galactic'))    -- the image id, or nil
```

### 9g. The pathfinding helper

```lua
local PathfindingUtil = require(ServerScriptService.Utility.PathfindingUtil)
print(PathfindingUtil.ShortestAngleDelta(0, math.pi * 1.5))  -- ≈ -1.5708 (the short way)
print(PathfindingUtil.AgentParams.AgentCanJump)             -- false
```

---

## 10. Production checklist

- [ ] The five config domains are at their exact Roblox paths.
- [ ] `Config/Presentation/UI.lua` is at that exact path (the `Rarity`
      require depends on it).
- [ ] The six server modules are at their exact Roblox paths, with
      `MoneyIcon`/`MutationIcon`/`PathfindingUtil`/`WaterHazard`
      inside `ServerScriptService/Utility/`.
- [ ] `SettingsService` and `ServerLuckService` are **direct children**
      of `ServerScriptService`.
- [ ] The shared modules are installed (`Debug`, `ConfigValidator`,
      `Validation`, `StudioTestMode`, `Remotes`, `BigNumber`,
      `Types/RarityType`).
- [ ] `osyrisrblx/t` is installed and `Packages/` maps to
      `ReplicatedStorage/Packages`.
- [ ] `ReplicatedStorage.Config.Creatures.Rarity` exists.
- [ ] The luck pool order is available — either the Events config is
      installed, or you moved the field and changed the require.
- [ ] `ServerScriptService.PlayerService` exists with a
      `Data.Settings` shape default.
- [ ] `Debug.SyncFromDebugConfig` runs **before** anything logs.
- [ ] `ConfigValidator.AssertValid()` runs at boot, with the
      Studio-hard-error / live-warn split.
- [ ] `StudioTestMode.Enabled` is seeded from the config.
- [ ] `WaterHazard.Init()` and `SettingsService.Init()` are called.
- [ ] `ServerLuckService.Init()` is called (or an `EggService` calls
      it).
- [ ] The config domains are registered in `ConfigValidator._MODULES`.
- [ ] The Studio assets are authored: `Assets.Decals.MoneyIcon`,
      `Assets.Decals.GalaxyIcon`, `Assets.Decals.SnowfallIcon`,
      `Workspace.Water`.
- [ ] `Systems.Debug.ServerDebug` and `ClientDebug` are **false** in
      the shipped build.
- [ ] `Systems.Debug.SkipPersistence` is **false**.
- [ ] `Systems.Debug.DrawPaths` is **false**.
- [ ] If you use a `Tags` whitelist, it includes `LUCK`, `Settings`,
      `IN`, `MI`, `Water`.
- [ ] The client bootstrap calls `Debug.SyncFromDebugConfig` on its
      own side.
- [ ] You did **not** copy `bootstrap.server.lua` from this system.
