# PlayerData — Setup

How to install the `PlayerData` system in a new game.

---

## 1. What you are installing

Two server modules:

| File | Roblox path |
|---|---|
| `Systems/PlayerData/Source/ServerScriptService/PlayerService.lua` | `ServerScriptService/PlayerService.lua` |
| `Systems/PlayerData/Source/ServerScriptService/Base/PersistenceAudit.lua` | `ServerScriptService/Base/PersistenceAudit.lua` |

Plus the shared modules and config they require (see
[`Dependencies.md`](Dependencies.md) for the complete list):

- `ReplicatedStorage/Utility/{Remotes,Validation,Debug,BigNumber,OwnedObjectIdentity}.lua`
- `ReplicatedStorage/Types/{SlotType,TransactionReason}.lua`
- `ReplicatedStorage/Config/Economy/Money.lua`
- `ReplicatedStorage/Config/Systems/Debug.lua`
- `ReplicatedStorage/Config/Creatures/Progression.lua`
- `ServerScriptService/Carry/CarryRegistry.lua` (from the `Carry` system)
- `ServerScriptService/MutationService.lua` (from the `MutationsAndTraits` system)

`Shared/CommonModules/OwnedObjectIdentity.lua` lands at
`ReplicatedStorage/Utility/OwnedObjectIdentity.lua`.

> **The library's `Shared/` folder is split into `Utilities/` and
> `CommonModules/`, but both map to `ReplicatedStorage/Utility/` in the
> game.** The split is only for folder size. See
> [`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) §5.

---

## 2. External packages you must supply

`PlayerService` is the **only** module in the game that touches
`ProfileService`. You need two packages installed on the server:

| Package | Required as | Where it comes from |
|---|---|---|
| `ProfileService` | `ServerScriptService.Packages.ProfileService` | vendored in the source game at `src/Vendored/ProfileService.lua`; upstream is `alexes Throughout/ProfileService` (see `wally.toml`) |
| `Janitor` | `ServerScriptService.Packages.Janitor` | Wally package `kineticwallet/janitor` |

If you use Wally, the source game's `wally.toml` already declares both. The
library does **not** vendor the packages — copy `src/Vendored/ProfileService.lua`
and the `ServerPackages/` folder, or run `wally install`.

---

## 3. Install the files

Copy the two server modules and the shared modules/config they need to their
**original Roblox paths**. The library's `Source/` trees already sit at those
paths, so a straight copy works and every `require` resolves unchanged.

If you are using the library's test project, `Tools/generate_test_tree.py`
does this for you.

---

## 4. The DataStore name

```lua
local PROFILE_NAME = 'p7_PlayerData_Money_v1_dev_1'
```

**Change this before you ship.** The `p7_` prefix is the source game's
identifier.

Renaming a DataStore orphans every existing profile — the old data stays in
the old store and the new store starts empty. That is fine for a new game
and a disaster for a port, so do it now, not later.

There is also a per-player escape hatch that does *not* need a rename:
`PlayerService.WipeUser(userId)` resets one player's profile without
touching anyone else's.

---

## 5. Wire it into the bootstrap

```lua
local PlayerService = require(script.Parent.PlayerService)

PlayerService.Init()
```

Then handle the player lifecycle:

```lua
local function onPlayerAdded(player: Player)
	if not PlayerService.LoadPlayerData(player) then
		player:Kick('Could not load your save. Please rejoin.')
		return
	end
	PlayerService.MarkLoaded(player.UserId)
	PlayerService.PushState(player)
end

local function onPlayerRemoving(player: Player)
	PlayerService.CleanupPlayer(player.UserId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)   -- Studio: already in the place
end
```

**`CleanupPlayer` must run on every leave path**, including the failure
paths. A profile that is not released stays session-locked and the player
cannot rejoin until the lock expires.

---

## 6. Create the remotes

`PlayerService` fires two remotes. The `Remotes` module is a **registry**,
not a factory — creating the `RemoteEvent` instances is the bootstrap's job:

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)

local function createRemotes()
	local folder = ReplicatedStorage:FindFirstChild('Remotes')
	if not folder then
		folder = Instance.new('Folder')
		folder.Name = 'Remotes'
		folder.Parent = ReplicatedStorage
	end
	for _, n in pairs(Remotes.Names) do
		if not folder:FindFirstChild(n) then
			local remote = Instance.new('RemoteEvent')
			remote.Name = n
			remote.Parent = folder
		end
	end
	Remotes.SetRemotes(folder)
	return folder
end

createRemotes()
```

`Remotes.Names` is a **map** — iterate it with `pairs()`. `#Remotes.Names` is
a runtime error.

The two remotes this system needs are `PlayerState` and `Notify`, but you
get all **47** whether you use them or not. That is deliberate: a system you
add later does not need a registry edit.

---

## 7. Set the income hand-off (if you install `Economy`/`Income`)

```lua
IncomeService.SetAnimalPoolSettlementHandler(function(userId, pool)
	-- pay the pool out
end)
```

`PlayerService.SetAnimalPoolSettlementHandler(fn)` is the hook. If you install
the income system and forget it, cash pools accumulate and are **never paid**
— no error, no warning. The pools just grow.

---

## 8. Set the peer service refs (if you install them)

`PlayerService` reads other services through late-bound setters. It never
`require`s them, which keeps the dependency graph acyclic.

```lua
EconomyService.SetPlayerService(PlayerService)   -- required for the economy
```

`PlayerService` itself has no `Set*Service` peers other than the settlement
handler above. If you install `BasesAndSlots`, the base assignment happens
through `BaseService`, and `MarkLoaded` must fire **after** the base is
assigned — see the source game's `bootstrap.server.lua` for the exact
ordering.

---

## 9. What the profile template needs from you

The template in `PlayerService.lua` carries Brainrot Arena's fields. For a new
game, decide which of these you keep:

| Field | Keep? |
|---|---|
| `Money`, `BaseId`, `Rebirth`, `LastSeen`, `Loaded` | Yes — core |
| `Stats` | Yes — but the counters are yours |
| `Settings` | Yes — but the options are yours |
| `Tutorial` | Replace — `Step = 'BuyEgg'` is this game's step name |
| `Brainrots` | Rename — this game's animal list |
| `LuckyBlocks` | Rename — this game's egg list |
| `GearAutoBuy`, `OwnedRobuxGear` | Only if you have gear |
| `Arena` | Only if you have an arena |
| `DailyRewards`, `PlaytimeRewards` | Only if you have those reward tracks |
| `RedeemedCodes`, `PendingCodeRewards` | Yes, if you have codes |

The template is the source of truth — `ReplicatedStorage/Types/PlayerDataType.lua`
is **stale** and does not match it.

---

## 10. Studio assets

**None.** `PlayerData` references no Studio-authored instance, no asset id,
and no model. It is pure server logic.

---

## 11. External APIs

**None.** No HTTP calls, no webhooks, no third-party endpoints. The only
outbound traffic is Roblox's own DataStore service.

---

## 12. Verify the install

1. `rojo build <your project>.project.json` succeeds.
2. In Studio, press Play. The server output should show the profile load
   and the `PlayerState` push.
3. The client HUD shows the starting balance (`Money.StartingMoney`).
4. Rejoin. The balance is the same — that proves the DataStore round-trip.
5. Call `PlayerService.WipeUser(player.UserId)` from the command bar. The
   balance resets. That proves the reset path.

If step 3 shows `loading...` forever, the profile load failed. Check the
server output. In an **unpublished** place, `ProfileService` falls back to
its in-memory adapter and nothing persists — everything appears to work, but
the balance resets on every join.

---

## 13. Common install mistakes

| Symptom | Cause | Fix |
|---|---|---|
| Player is kicked on join | `LoadPlayerData` returned `false` | Check the server output; usually an unpublished place or a profile version mismatch |
| Balance resets every join | Unpublished place — DataStore is not available | Publish the place, or accept it for local testing |
| `attempt to index nil` on `Remotes.Names` | `createRemotes()` was not called | Call it before any service `Init()` |
| `attempt to get length of Remotes.Names` | `Names` is a map, not an array | Use `pairs()` |
| Cash pools never pay out | `SetAnimalPoolSettlementHandler` was never called | Set it |
| Player cannot rejoin after leaving | `CleanupPlayer` was not called on the leave path | Call it on every leave path |
| `Money` is a number, precision loss | Something wrote `data.Money` directly | Use `EconomyService`; keep it a string |
| Old profiles have wrong-typed fields | Normal — the repair blocks handle it | Do not remove the repair blocks; `Reconcile` alone does not fix wrong types |

---

## Related

| Document | Contents |
|---|---|
| [`README.md`](README.md) | What the system does |
| [`MEMORY.md`](MEMORY.md) | The non-obvious facts |
| [`Config.lua`](Config.lua) | Every tunable the system reads |
| [`Dependencies.md`](Dependencies.md) | Exact requires, DataStore, profile fields |
| [`API.md`](API.md) | Every public function |
| [`../../PROJECT_SETUP.md`](../../PROJECT_SETUP.md) | The whole-library integration |
| [`../../Templates/IntegrationChecklist.md`](../../Templates/IntegrationChecklist.md) | Pre-ship checklist |
