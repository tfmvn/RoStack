# MinimalGame

A **runnable** starting point. Unlike [`../IntegrationExamples/`](../IntegrationExamples/),
which is prose, this is a real Rojo project you can build and play.

It is the smallest slice of the library that is still a game: a player
joins, a profile loads and persists, a wallet holds a BigNumber decimal
string, and a HUD shows it.

| | |
|---|---|
| **Systems used** | `Economy`, `PlayerData` (+ the shared utilities they need) |
| **Hand-written files** | 2 — `bootstrap.server.lua`, `MoneyHud.client.lua` |
| **Everything else** | copied verbatim from the library by `setup.sh` |
| **Builds with** | `rojo build minimalgame.project.json -o build/minimalgame.rbxl` |
| **Plays in** | Roblox Studio (needs the published place for DataStore writes) |

---

## What is in the box

```
MinimalGame/
├── setup.sh                          # deterministic copier
├── minimalgame.project.json          # the Rojo project
├── README.md                         # this file
└── src/
    ├── ServerScriptService/
    │   ├── bootstrap.server.lua      # HAND-WRITTEN — the wiring
    │   ├── PlayerService.lua         # ← library (PlayerData)
    │   ├── EconomyService.lua        # ← library (Economy)
    │   ├── MutationService.lua       # ← library (MutationsAndTraits)
    │   ├── Base/
    │   │   └── PersistenceAudit.lua  # ← library (PlayerData)
    │   └── Carry/
    │       └── CarryRegistry.lua     # ← library (Carry)
    ├── ReplicatedStorage/
    │   ├── Config/
    │   │   ├── Economy/Money.lua     # ← library (Economy)
    │   │   ├── Systems/Debug.lua     # ← library (SharedUtilities)
    │   │   └── Creatures/{Progression,Mutations,Traits,Animals,Eggs}.lua
    │   ├── Utility/                  # ← library (Shared/*)
    │   └── Types/                    # ← library (Shared/Types)
    └── StarterPlayer/
        └── StarterPlayerScripts/
            └── MoneyHud.client.lua   # HAND-WRITTEN — the HUD
```

---

## Getting it running

### Step 1 — copy the library files in

```bash
cd ReusableSystems/Examples/MinimalGame
./setup.sh
```

`setup.sh` is a **deterministic copy driven by an explicit file list**, not
an auto-discovering installer. Every path is checked; a missing source is a
hard error, not a silent skip. It removes only the library-derived
subtrees before copying, so your hand-written files survive a re-run.

If you would rather copy by hand, the file list is right there in the
script.

### Step 2 — get the two dependencies

The library needs `ProfileService` and `Janitor` on the server:

| Package | Where | How |
|---|---|---|
| `ProfileService` | `ServerScriptService.Packages.ProfileService` | vendored at `src/Vendored/ProfileService.lua` in the source game |
| `Janitor` | `ServerScriptService.Packages.Janitor` | `ServerPackages/Janitor.lua` + `ServerPackages/_Index` |

`minimalgame.project.json` already points at both:

```json
"Packages": {
  "$className": "Folder",
  "ProfileService": { "$className": "ModuleScript", "$path": "../../../src/Vendored/ProfileService.lua" },
  "Janitor":       { "$className": "ModuleScript", "$path": "../../../ServerPackages/Janitor.lua" },
  "_Index":        { "$className": "Folder",      "$path": "../../../ServerPackages/_Index" }
}
```

Those `../../../` paths point back at the source game's repository
root. **If you copy this example into a different repository, change them**
to point at wherever your copy of those packages lives, or vendor them into
`MinimalGame/src/Vendored/` and repoint the paths there. A Rojo `$path`
that does not exist is a build error, not a runtime warning.

### Step 3 — build

```bash
rojo build minimalgame.project.json -o build/minimalgame.rbxl
```

Or open the folder in Studio with the Rojo plugin pointed at
`minimalgame.project.json`.

### Step 4 — play it

Open the built place in Roblox Studio and press **Play**.

Two caveats that are not about the example:

- **DataStore writes need a published place.** In an unpublished place,
  `ProfileService` falls back to its in-memory adapter and everything
  appears to work — but nothing persists. This is expected.
- **The player needs a profile slot.** `PlayerService.LoadPlayerData`
  returns `false` if the profile cannot be loaded, and the bootstrap kicks
  the player. If your HUD sits at `loading...` forever, check the server
  output for the load failure.

---

## The two hand-written files

Everything else in `src/` is the library, byte-for-byte. These two files
are the part you actually learn from.

### `bootstrap.server.lua`

The wiring. Compare it against the source game's
`Systems/SharedUtilities/Source/ServerScriptService/bootstrap.server.lua`
to see what adding the *rest* of the game actually costs.

The ordering rules it enforces:

1. `createRemotes()` runs **before** any service `Init()`.
2. `EconomyService.Init()` runs before `PlayerService.Init()`.
3. `EconomyService.SetPlayerService(PlayerService)` runs **before**
   `PlayerService.Init()` — the economy must own the `Money` field before
   the profile loads.

```lua
createRemotes()

EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)

PlayerService.Init()
```

`createRemotes()` is copied from the source game's
`bootstrap.server.lua` (lines 203–222). The `Remotes` module is a
**registry**, not a factory — it has no "create the remotes" function.
Creating the `RemoteEvent` instances is the bootstrap's job:

```lua
local function createRemotes()
	local folder = ReplicatedStorage:FindFirstChild('Remotes')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = 'Remotes'
		folder.Parent = ReplicatedStorage
	end
	local names = Remotes.Names
	for _, n in pairs(names) do
		if not folder:FindFirstChild(n) then
			local remote = Instance.new('RemoteEvent')
			remote.Name = n
			remote.Parent = folder
		end
	end
	Remotes.SetRemotes(folder)
	return folder
end
```

`Remotes.Names` is a **map** — iterate it with `pairs()`. `#Remotes.Names`
is a runtime error. There are **47** remotes in the registry; you get all
of them whether you use them or not.

### `MoneyHud.client.lua`

A ~80-line HUD built entirely from code, so the example needs no
Studio-authored GUI.

The one rule it demonstrates: **the client does not compute anything.** It
listens for a server push and renders it.

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Remotes.WaitForReady()
local playerState = remotesFolder:WaitForChild('PlayerState')

playerState.OnClientEvent:Connect(function(payload)
	label.Text = '$' .. tostring(payload.Money or '0')
end)
```

Two details worth copying:

- `Remotes.WaitForReady()` — not `WaitForChild('Remotes')`. The folder may
  exist while the module still points elsewhere. `WaitForReady()` blocks
  until `SetRemotes` has been called.
- `payload.Money` is a **decimal string**. `'$' .. tostring(payload.Money)`
  is correct. `tonumber()` on it loses precision above 2^53, which is the
  entire reason `BigNumber` exists.

---

## What this example deliberately leaves out

The source game has 28 systems. This one uses two. Everything below is
absent on purpose — adding it is the next step, and each addition is
covered in
[`../IntegrationExamples/README.md`](../IntegrationExamples/README.md).

| Missing | Consequence |
|---|---|
| `BasesAndSlots` | The `Slots` field of the `PlayerState` push is always an empty table; the player has no base |
| `Animals` / `EggsAndHatching` | Nothing to collect, nothing to hatch |
| `Collectors` | No income — the wallet only changes if you spend or grant it |
| `Upgrades` | Nothing to buy with money |
| `ClientPresentation` | No shop UI, no arena, no slot menu, no toasts |
| `ShopsAndPurchases` | No `ProcessReceipt` — **if you add developer products, you must add this**, or Roblox will keep retrying purchases |

Note the last row carefully. `ShopService` owns the **one**
`MarketplaceService.ProcessReceipt` in the source game. A game that sells
Robux without it will have purchases that never grant anything, and
Roblox will retry them indefinitely.

---

## Where to go next

| You want to… | Go to |
|---|---|
| Understand the wallet API in detail | `../IntegrationExamples/README.md` Example A |
| Add a purchase flow | `../IntegrationExamples/README.md` Example B |
| Add a whole new system | `../IntegrationExamples/README.md` Example C |
| Understand the full init order | `../../DEPENDENCY_MAP.md` §2 |
| See what each system needs | `../../SYSTEM_INDEX.md` |
| Ship it | `../../Templates/IntegrationChecklist.md` |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Rojo build fails on `Packages` | `../../../src/Vendored/ProfileService.lua` does not exist relative to *your* repo | Repoint the `$path`, or vendor the packages under `MinimalGame/src/` |
| Server errors on `require` of a `Config` module | `setup.sh` was not run, or was run from the wrong directory | Re-run `./setup.sh` from `MinimalGame/` |
| HUD shows `loading...` forever | The server never called `PushState` (profile load failed) | Check the server output for the load failure |
| Balance is `0` and never changes | No income system is installed | Expected — see "What this example deliberately leaves out" |
| `attempt to get length of Remotes.Names` | Someone used `#` on a map | Use `pairs()` |
| Player is kicked on join | `LoadPlayerData` returned `false` | Usually an unpublished place (DataStore unavailable) or a profile version mismatch |
