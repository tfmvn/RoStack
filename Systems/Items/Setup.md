# Items — Setup

How to install the Items (Gear Shop) system into a new Rojo project.

Related: [README.md](README.md) · [MEMORY.md](MEMORY.md) ·
[API.md](API.md) · [Dependencies.md](Dependencies.md)

---

## 1. Copy the files

| From this library | To in your Rojo project |
|---|---|
| `Source/ServerScriptService/GearShop/GearShopService.lua` | `ServerScriptService/GearShop/GearShopService.lua` |

Plus the modules it requires (see [Dependencies.md](Dependencies.md)):

| Required path | From | To |
|---|---|---|
| `ReplicatedStorage.Config.Economy.Gear` | **Combat** system, `Source/ReplicatedStorage/Config/Economy/Gear.lua` | `ReplicatedStorage/Config/Economy/Gear.lua` |
| `ReplicatedStorage.Config.World.Prompts` | **Carry** system, `Source/ReplicatedStorage/Config/World/Prompts.lua` | `ReplicatedStorage/Config/World/Prompts.lua` |
| `ReplicatedStorage.Utility.Remotes` | **Shared**, `CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `ReplicatedStorage.Utility.Validation` | **Shared**, `Utilities/Validation.lua` | `ReplicatedStorage/Utility/Validation.lua` |
| `ReplicatedStorage.Utility.BigNumber` | **Shared**, `Utilities/BigNumber.lua` | `ReplicatedStorage/Utility/BigNumber.lua` |
| `ReplicatedStorage.Utility.Debug` | **Shared**, `Utilities/Debug.lua` | `ReplicatedStorage/Utility/Debug.lua` |
| `ServerScriptService.Base.NotificationService` | **Notifications** system | `ServerScriptService/Base/NotificationService.lua` |
| `ServerScriptService.FunnelService` | **Analytics** system | `ServerScriptService/FunnelService.lua` |
| `ServerScriptService.Rebirth.RebirthService` | **Upgrades** system | `ServerScriptService/Rebirth/RebirthService.lua` |

`Remotes.lua` also requires `ReplicatedStorage/Utility/Signals.lua`
(copy `Shared/CommonModules/Signals.lua`).

### Rojo mapping

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",

    "ReplicatedStorage": {
      "$className": "ReplicatedStorage",
      "Utility": {
        "$path": "src/ReplicatedStorage/Utility"
      },
      "Config": {
        "$path": "src/ReplicatedStorage/Config"
      }
    },

    "ServerScriptService": {
      "$className": "ServerScriptService",
      "GearShop": {
        "$path": "src/ServerScriptService/GearShop"
      },
      "Base": {
        "$path": "src/ServerScriptService/Base"
      },
      "Rebirth": {
        "$path": "src/ServerScriptService/Rebirth"
      }
    },

    "ServerStorage": {
      "$className": "ServerStorage",
      "Assets": {
        "$path": "src/ServerStorage/Assets"
      }
    },

    "StarterGui": {
      "$className": "StarterGui",
      "$path": "src/StarterGui"
    }
  }
}
```

**Folder names matter.** The source requires
`ReplicatedStorage.Config.Economy.Gear`,
`ReplicatedStorage.Config.World.Prompts`,
`ReplicatedStorage.Utility.*`, `ServerScriptService.Base.*` and
`ServerScriptService.FunnelService` by absolute path.

---

## 2. Third-party packages

**None required by this module.** It uses only Roblox engine services
(`ReplicatedStorage`, `ServerStorage`, `ServerScriptService`,
`Workspace`).

You will need a profile library (`evaera/persist` / ProfileService, or
your own) to hold `GearAutoBuy` and `OwnedRobuxGear`, and a money
service for `TrySpendMoney` / `AddMoney` / `GetMoney`.

For the Robux path you need the **Robux Developer Products** setup in
Studio (Game Settings → Monetization → Developer Products). The Product
Id is configured in the **Shop** system, not here.

---

## 3. Configuration to tune

This system owns **no** config module. Its tunables are:

| What | Where it lives | Owner |
|---|---|---|
| The gear catalog (ids, names, prices, rebirth gates, tool names, `RobuxOnly`) | `ReplicatedStorage/Config/Economy/Gear.lua` | **Combat** |
| The shop `ProximityPrompt` (action text, hold, distance, line of sight) | `Prompts.GearShop` in `ReplicatedStorage/Config/World/Prompts.lua` | **Carry** |
| The shop preview framing | `Gear.Viewport` in `ReplicatedStorage/Config/Economy/Gear.lua` | **Combat** |
| The per-bat combat tuning | `Gear.Combat` in `ReplicatedStorage/Config/Economy/Gear.lua` | **Combat** |

**If you want the shop to be self-contained**, copy
`ReplicatedStorage/Config/Economy/Gear.lua` into your tree and edit it
there — the Combat system reads `Gear.Combat` from the same file, so
if you split the file you must keep the `ToolName` values in sync.

The shipped catalog's `Description` fields all begin with `PLACEHOLDER:`
and the prices are initial values. Tune them before release.

---

## 4. Bootstrap sequence

### 4a. Create the remotes

```lua
local ReplicatedStorage = game:GetService('ReplicatedStorage')
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local remotes = Instance.new('Folder')
remotes.Name = 'Remotes'
remotes.Parent = ReplicatedStorage
for _, name in Remotes.Names do
	local ev = Instance.new('RemoteEvent')
	ev.Name = name
	ev.Parent = remotes
end
Remotes.SetRemotes(remotes)
```

`GearShopAction`, `GearShopState` and `GearShopResult` all come from
`Remotes.Names`, so this loop creates all three.

### 4b. Inject and init

```lua
local GearShopService = require(script.Parent.GearShop.GearShopService)

GearShopService.SetPlayerService(PlayerService)
GearShopService.SetEconomyService(EconomyService)
GearShopService.Init()
```

`Init()` does four things, in this order:

1. `GearConfig.ValidateLive()` — config issues are logged as warns
   (missing `Tool` assets, duplicate ids, bad fields).
2. `publishPreviews()` — clones the gear `Tool`s (script-stripped) to
   `ReplicatedStorage.GearShopPreviews`.
3. `wireShopPrompt()` — finds `Workspace.Map.Shop.PromptPart`, creates
   a `ProximityPrompt` if there isn't one, and connects `Triggered` to
   `OpenShop`.
4. Connects `GearShopAction.OnServerEvent`.

### 4c. Player lifecycle

```lua
Players.PlayerAdded:Connect(function(player)
	-- Call this AFTER the profile is loaded (post MarkLoaded).
	player.CharacterAdded:Connect(function()
		GearShopService.OnCharacterSpawned(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	GearShopService.ForgetPlayer(player.UserId)
end)
```

**`OnPlayerReady` must be called after the profile is loaded.** The
`readyBy` guard means it will not retry — calling it too early means
the player silently loses their auto-buy on that join.

### 4d. The Robux grant (from your Shop system)

```lua
-- In your Developer Product receipt handler:
local ok = GearShopService.GrantRobuxGear(player, entry.GearId)
if not ok then
	-- Do NOT consume the purchase. Retry later: the grant failed
	-- because the Tool asset is missing (or the player is gone).
	return
end
```

`GrantRobuxGear` is the **only** path that grants a `RobuxOnly` gear.
The cash `Purchase` path rejects it with `error = 'robux-only'`.

---

## 5. Studio assets to author

### 5a. The gear `Tool`s

```text
ServerStorage
└── Assets
    └── Ui
        └── GearShop
            └── Tools
                ├── Default Bat
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
                └── Galaxy Bat
```

Each is a `Tool`. **The instance name must equal the catalog's
`ToolName` exactly** — the server resolves tools with
`FindFirstChild(toolName)` and matches live tools by exact `Name`.

Tool authoring checklist:

- `RequiresHandle = true` → add a `Handle` child that is a
  `BasePart`. Without it the player can hold the tool but never
  properly equip it.
- The `Handle` should be `Anchored = true`, `CanCollide = false`.
- Any behaviour scripts inside the `Tool` are **stripped from the
  preview clone** but **kept in the live grant**. Put the actual
  behaviour in a server script (e.g. the Combat system's `BatService`)
  rather than in the `Tool`, so the granted clone is inert data.

### 5b. The shop row template

```text
ServerStorage
└── Assets
    └── Ui
        └── GearShop
            └── GearTemplate
```

The server clones this into the player's
`PlayerGui…GearShop.ScrollingFrame` as a hidden prototype named
`GearTemplate`. Rules:

- It must have **no `GearId` attribute** — the server treats a
  template that already has one as stale and re-clones it.
- The actual rows are **separate clones** with a `GearId` attribute;
  the client stamps them.

### 5c. The world prompt

```text
Workspace
└── Map
    └── Shop
        └── PromptPart     -- BasePart
```

A `ProximityPrompt` is optional — if `PromptPart` has none, the server
creates one from `Prompts.GearShop`. If `PromptPart` itself is
missing, the shop has no world entry (a warn is logged) and the GUI
must be opened another way.

### 5d. The client GUI

```text
StarterGui
└── GearShop               -- ScreenGui
    └── ScrollingFrame     -- the template's parent
```

The server finds both by **recursive** `FindFirstChild`, so they may
be nested inside other frames.

### 5e. Preview publication (automatic)

```text
ReplicatedStorage
└── GearShopPreviews       -- created by the server at Init
```

Nothing to author — the server publishes script-stripped clones of
each gear `Tool` here.

---

## 6. The client side

The server is complete on its own; the client is what makes it
visible. You need:

1. A **shop GUI** that renders the `Gears` array from the
   `GearShopState` payload, one row per entry.
2. A **preview** in each row, using the `GearShopPreviews` clone with
   the matching `gearId` in a `ViewportFrame` (framed with
   `Gear.Viewport`).
3. A **request** path that fires `GearShopAction` with
   `{ Action = 'Purchase' | 'Equip' | 'SetAutoBuy', GearId = id,
   Enabled = bool }`.
4. A **result** handler that reads `GearShopResult`
   (`{ Action, GearId, Success, Error }`).

Do **not** trust the client for anything: the server re-resolves the
gear by `Id`, re-checks the price, the rebirth gate, the ownership,
and the live `Tool` presence.

---

## 7. Smoke test

1. **Service loads.** Start the server. No require errors. If
   `ReplicatedStorage.Config.Economy.Gear` is missing, you get a
   require failure — the config lives in the Combat system.
2. **Config validation.** The server logs
   `'[GearShop] Config issue: ...'` for each missing or wrong-class
   `Tool` asset. Fix every one of them before testing — a missing
   asset means that gear can never be bought.
3. **Default bat.** Join. You should be holding the Default Bat with
   no purchase. The shop GUI should show `Owned = true` for it.
4. **Open the shop.** Walk to `Workspace.Map.Shop.PromptPart` and
   press the prompt key. The GUI should open with 12 rows, your money,
   and your rebirth count.
5. **Buy something cheap.** `Speed Coil` is `500`. If you have the
   money, click Buy. You should get a success toast, the money should
   drop by exactly 500, and the Speed Coil should be **equipped**.
6. **Check the previews.** Each row should show a 3D preview, not an
   empty frame. If a preview is missing, the `Tool` asset is missing.
7. **Buy something you cannot afford.** You should get the
   insufficient-cash toast with the shortfall, and your money should
   **not** change.
8. **Buy it twice.** The second attempt should say "already owned" and
   **not** charge you again.
9. **Buy a rebirth-gated gear.** `Gravity Coil` needs 1 rebirth. With
   0 rebirth you should get the locked toast and no debit.
10. **Equip switching.** With two bats owned, switching between them
    should keep **exactly one** in your hand — the other goes to the
    Backpack. Check your inventory: there should be no duplicate bats.
11. **AutoBuy.** Enable AutoBuy on a gear you can afford. You should
    get it immediately. Disable it — the gear stays (AutoBuy is a
    preference, not a refund).
12. **Rejoin.** Rejoin the server. You should be back on the Default
    Bat (cash purchases are **not** persisted) unless AutoBuy bought
    it again, or the gear was a Robux entitlement.
13. **Die and respawn.** You should still be holding the same bat
    after respawning, and your inventory should contain **no
    duplicates**.
14. **Rollback check.** Temporarily rename a `Tool` asset so the grant
    fails mid-purchase (or use a gear whose asset you deleted after
    the debit). The purchase should fail with the "tool unavailable"
    toast **and your money should be refunded**. This is the most
    important path to verify.
15. **Player isolation.** Two players, one buys a bat, the other does
    not. Neither should see the other's state, and neither should
    have their equipped bat swapped.

### Running the specs

`Tests/GearShop.spec.lua` covers the catalog rules and the service
rules (join / equip / isolation / Robux entitlement). It requires the
shared `Tests/_Helpers.lua` and **Roblox Studio**. See
`../../Tests/README.md`.
