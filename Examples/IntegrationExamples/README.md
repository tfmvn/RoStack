# Integration Examples

Realistic, end-to-end walkthroughs that take systems out of this library and
stand them up in a **different** game. These are the "how do I actually use
this" documents.

| Example | What it proves | Difficulty |
|---|---|---|
| **[A. Wallet + Persistence](#example-a--wallet--persistence-economy--playerdata)** | Economy + PlayerData + a live HUD in an empty project | Beginner |
| **[B. A purchase flow](#example-b--a-purchase-flow-economy--inventory--upgrades)** | A server-authoritative purchase that spends money and grants an item | Intermediate |
| **[C. Adding a system](#example-c--adding-a-system-after-the-fact-economy--upgrades)** | What it actually costs to bolt one more system onto a working project | Intermediate |

Each example is written against the **real** API in this library. Every
function name, remote name, config key, and file path in here is copied from
the source, not invented. If a symbol does not exist, the example will say so.

> If you want a *runnable* starting point rather than a walkthrough, use
> [`../MinimalGame/`](../MinimalGame/) instead — that one has a `setup.sh`
> and a Rojo project you can actually build. This folder is prose plus
> code fragments.

---

## Before you start

Two rules from the source game that bite everyone the first time:

1. **Money is a string, not a number.** `data.Money` is a BigNumber decimal
   string (`'5000'`). Never `tonumber()` it — you lose precision above
   2^53 and the whole reason BigNumber exists evaporates.
2. **The server re-resolves every price.** A client that says "I want to
   buy the 1000-cost egg" is making a *request*. The server looks the price
   up in the config and ignores what the client sent.

Read [`../../MEMORY.md`](../../MEMORY.md) §2 and §3 before continuing. They
are short.

---

## Example A — Wallet + Persistence (Economy + PlayerData)

**Goal:** a player joins, gets a profile, sees their wallet on screen, earns
money, and the balance survives a server restart.

This is the minimum viable slice of the library and the base for every other
example.

### A.1 What you take from the library

| Library path | Roblox destination |
|---|---|
| `Systems/PlayerData/Source/ServerScriptService/PlayerService.lua` | `ServerScriptService/PlayerService.lua` |
| `Systems/PlayerData/Source/ServerScriptService/Base/PersistenceAudit.lua` | `ServerScriptService/Base/PersistenceAudit.lua` |
| `Systems/Economy/Source/ServerScriptService/EconomyService.lua` | `ServerScriptService/EconomyService.lua` |
| `Systems/Economy/Source/ReplicatedStorage/Config/Economy/Money.lua` | `ReplicatedStorage/Config/Economy/Money.lua` |
| `Systems/SharedUtilities/Source/ReplicatedStorage/Config/Systems/Debug.lua` | `ReplicatedStorage/Config/Systems/Debug.lua` |
| `Shared/Utilities/{BigNumber,Validation,Debug,NumberUtils}.lua` | `ReplicatedStorage/Utility/…` |
| `Shared/CommonModules/Remotes.lua` | `ReplicatedStorage/Utility/Remotes.lua` |
| `Shared/Types/{TransactionReason,PlayerDataType}.lua` | `ReplicatedStorage/Types/…` |

`setup.sh` in `../MinimalGame/` copies exactly this set, plus the two
hand-written files. If you want the runnable version, use that.

### A.2 The `require` paths do not change

Every file in this library keeps its **exact original Roblox path** inside
its `Source/` folder. That is a deliberate design decision: it means
`require` statements work unchanged whether the file is in the source game or
in your new project. There is no "library namespace" to learn.

So `EconomyService.lua` still says:

```lua
local EconomyConfig = require(script.Parent.Parent.ReplicatedStorage.Config.Economy.Money)
local Debug         = require(script.Parent.Parent.ReplicatedStorage.Utility.Debug)
local BigNumber     = require(script.Parent.Parent.ReplicatedStorage.Utility.BigNumber)
local TransactionReason = require(script.Parent.Parent.ReplicatedStorage.Types.TransactionReason)
```

and `PlayerService.lua` still says:

```lua
local Remotes = require(script.Parent.Parent.ReplicatedStorage.Utility.Remotes)
```

Because `PlayerService.lua` sits at `ServerScriptService/PlayerService.lua`,
`script.Parent` is `ServerScriptService` and `script.Parent.Parent` is the
root. **If you move a file, you must fix its requires.** The library's
`Dependencies.md` per system lists what each file expects.

### A.3 Remotes: the bootstrap's job

The `Remotes` module is a **registry**, not a factory. It has no
"create the remotes" function. Creating the `RemoteEvent` instances is the
bootstrap's responsibility, and the source game does it in
`ServerScriptService/bootstrap.server.lua` (lines 203–222):

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)

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

createRemotes()
```

Two details that matter:

- `Remotes.Names` is a **map** of name → name. Iterate it with `pairs()`.
  (`#Remotes.Names` is a runtime error — a map has no length.)
- `Remotes.SetRemotes(folder)` tells the module where the live instances are.
  Until it is called, `Remotes.FireClient` is a no-op.

There are **47 remotes** in the registry. You get all of them whether you use
one or not. That is fine — they are cheap, and it means a system you add
later does not need a registry edit.

### A.4 The bootstrap wiring

```lua
local EconomyService = require(script.Parent.EconomyService)
local PlayerService = require(script.Parent.PlayerService)

EconomyService.Init()
EconomyService.SetPlayerService(PlayerService)   -- BEFORE PlayerService.Init()
PlayerService.Init()
```

The ordering is load-bearing:

1. `createRemotes()` runs **before** any service `Init()`.
2. `EconomyService.Init()` runs before `PlayerService.Init()`.
3. `EconomyService.SetPlayerService(PlayerService)` runs **before**
   `PlayerService.Init()`, because the economy must own the `Money` field
   before the profile loads.

`EconomyService` never `require`s `PlayerService`. It reads a late-bound
ref that the bootstrap injects. That is what keeps the dependency graph
acyclic — see [`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) §3.

### A.5 Loading and unloading players

```lua
local function onPlayerAdded(player: Player)
	local ok = PlayerService.LoadPlayerData(player)
	if not ok then
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

`LoadPlayerData` returns a **boolean**, not the data. The data itself comes
from `PlayerService.GetPlayerData(userId)`. This split is deliberate: the
load can fail (profile locked, version mismatch) and a failed load must not
leave a half-initialized player in the table.

`PushState(player)` sends the initial wallet snapshot. `baseSnapshot` is
optional — omit it and the `Slots` field of the payload is an empty table.

### A.6 The wallet push

`PlayerService.PushState` fires the `PlayerState` remote with this exact
shape:

```lua
Remotes.FireClient(player, Remotes.Names.PlayerState, {
	Money        = data.Money,   -- BigNumber decimal STRING
	BaseId       = data.BaseId,
	Slots        = baseSnapshot and baseSnapshot.slots or {},
	CarriedKind  = carry.Kind,
	CarriedName  = carry.Name,
	CarriedSteal = carry.Steal == true,
})
```

`Money` is a string. `Slots` is empty unless you pass a base snapshot (that
is the `BasesAndSlots` system — out of scope here). `Carried*` fields come
from `CarryRegistry` and stay `nil`/`false` if you do not install it.

### A.7 The client HUD

The client **does not compute anything**. It listens for the push and
renders it.

```lua
local Remotes = require(ReplicatedStorage.Utility.Remotes)
local remotesFolder = Remotes.WaitForReady()
local playerState = remotesFolder:WaitForChild('PlayerState')

local pending = nil

local function render()
	if not pending then
		label.Text = 'loading...'
		return
	end
	-- Money is a decimal STRING. Display it directly.
	label.Text = '$' .. tostring(pending.Money or '0')
end

playerState.OnClientEvent:Connect(function(payload)
	pending = payload
	render()
end)
```

`Remotes.WaitForReady()` blocks until the server has created the folder and
called `SetRemotes`. That is the correct way to wait — do not
`WaitForChild('Remotes')` yourself, because the folder may exist while the
module still points elsewhere.

A full working version of this file (building the GUI from code so the
example needs no Studio-authored UI) is at
[`../MinimalGame/src/StarterPlayer/StarterPlayerScripts/MoneyHud.client.lua`](../MinimalGame/src/StarterPlayer/StarterPlayerScripts/MoneyHud.client.lua).

### A.8 Granting and spending money

Every balance change goes through `EconomyService`, never through
`data.Money = ...`.

```lua
local TransactionReason = require(ReplicatedStorage.Types.TransactionReason)

local result = EconomyService.AddMoney(userId, '250', TransactionReason.CashCollector)
if not result.Success then
	-- result.Code is one of: 'invalid-reason', 'no-profile',
	-- 'invalid-amount', 'cap-exceeded'
	return
end
-- result.NewMoney is the new balance, as a string
```

```lua
local result = EconomyService.TrySpendMoney(userId, '1000', TransactionReason.EggPurchase)
if not result.Success then
	if result.Code == 'insufficient' then
		-- tell the player they cannot afford it
	end
	return
end
```

Both return an `EconomyResult`:

```lua
{
	Success       = boolean,
	NewMoney      = string?,   -- post-write balance; nil on failure
	Reason        = string,    -- echo of the reason
	Code          = string?,   -- failure code; nil on success
	TransactionId = string,    -- 'tx-<userId>-<counter>' — grep this in logs
}
```

Three things to know about the reason parameter:

- It must be a member of the **closed** `TransactionReason` enum (17 values).
  A typo returns `Code = 'invalid-reason'` and changes nothing. The check
  happens *before* any mutation, so a bad reason can never move money.
- It is not decorative. The Debug log line records it, so when a balance
  changes in production you can answer "why did they get this money?"
  by grepping one field.
- `TransactionReason` has no "arbitrary" member. If your game needs a new
  kind of grant, **add it to the enum** (`Shared/Types/TransactionReason.lua`)
  rather than smuggling a string past the check. Adding an enum value is a
  deliberate act; the closed set is the point.

`TrySpendMoney` collapses compare-then-write into one critical section
with no `task.yield()` between the read and the write. The old
`CanAfford` + `DebitCash` two-step pattern is racy — two prompts in the same
frame can double-spend. **Use `TrySpendMoney`.** `CanAfford` still exists
for a *display* check ("can I afford this?" in a shop UI); never use it as
the gate before a spend.

### A.9 Where the money comes from

`EconomyService` does not generate money. It only mutates it. The sources in
the source game are:

| Source | System | Reason enum |
|---|---|---|
| First-join seed | `PlayerData` (reconcile pass) | `StartingMoney` |
| Animal cash pools | `Animals` + `Collectors` | `CashCollector` |
| Arena clears | `Arena` | `ArenaReward` |
| Codes | `CodesAndRewards` | `CodeReward` |
| Shop money packs | `ShopsAndPurchases` | `ShopMoneyPack` |
| Admin commands | `AdminTools` | `AdminGive` / `AdminSet` |
| Egg / gear sales | `Items` / `ShopsAndPurchases` | `SellAnimal` / `SellEgg` / `GearRefund` |

The seed is `Money.StartingMoney = '5000'`
(`ReplicatedStorage/Config/Economy/Money.lua`). It applies to **new
players only** — changing it never touches an existing balance.

---

## Example B — A Purchase Flow (Economy + Inventory + Upgrades)

**Goal:** a player buys an upgrade with money; the server decides whether
they can, spends the money, applies the upgrade, and tells the client.

This is the shape of *every* purchase in the library. Learn it once.

### B.1 The five-step shape

Every money-spending flow in the source game follows the same five steps.
The order matters.

```
1. RESOLVE   server looks up the real price/eligibility from config
2. CHECK     server verifies the player can afford it / is allowed
3. SPEND     EconomyService.TrySpendMoney(...)  ← one atomic call
4. GRANT     the thing is added to the player's data
5. REPLICATE push the new state to the client
```

The mistake everybody makes is doing 1–2 on the client and sending "I bought
it" to the server. The server must redo 1 and 2. **The client's price is a
display value, not an input.**

### B.2 The real implementation: `UpgradeService.UpgradeAnimal`

The source game already implements this flow, and it is worth reading
because it shows the *full* shape — including the parts people forget.

```lua
-- ServerScriptService/UpgradeService.lua
local result = UpgradeService.UpgradeAnimal(player, animalId)
if not result.success then
	-- result.error is one of the 15 codes in UpgradeService.Error
	return
end
-- result.animalId, result.oldLevel, result.newLevel,
-- result.cost, result.remainingMoney
```

`UpgradeAnimal` does all five steps itself:

1. **RESOLVE** — `GetUpgradeCost(definitionId, level)` computes the cost
   from the config, not from the client.
2. **CHECK** — the animal must exist, be owned by the caller, not be
   `Consumed`/`Destroyed`/`Carried`, and not be raid-locked.
3. **SPEND** — `EconomyService.TrySpendMoney(...)`.
4. **GRANT** — `Level += 1` on the persistent animal.
5. **REPLICATE** — the new state is pushed.

Note what it does **not** do: it never reads a cost from the request. The
client sends an `animalId`; the server looks up the definition, the rarity,
and the base price, and computes the cost with exact decimal arithmetic.

The error codes are the interesting part:

```
invalid-player    invalid-id        not-found        not-owner
busy              invalid-state     not-animal       invalid-definition
invalid-level     max-level         no-cost          slot-state
insufficient      grant-failed      service-unavailable
```

`not-animal` is declared in the error table but **no code path ever returns
it** — it is dead. `busy` is returned both for a genuinely in-flight
upgrade *and* for an animal locked by an active arena raid; the client
cannot tell them apart.

### B.3 The cost formula is exact decimal math

`GetUpgradeCost(definitionId, level)` computes `base × 1.12^(level-1)`.
It is **not** floating point. It computes `base × 28^k / 25^k` where
`k = level - 1`, scales the numerator by `10^(2k)` (which `25^k` divides
exactly), and does an exact integer quotient. The result is a canonical
BigNumber decimal string.

Level 3 of a Common animal is exactly `'125.44'`. Level 4 is exactly
`'140.4928'`. No drift, no rounding, no `math.pow`.

The base price comes from `AnimalConfig.SellBaseValue[rarity]` — the same
configured value the sale formula uses. `GetUpgradeCost` returns `nil` for
bad input and for `level >= MaxLevel` (there is no level-101 price).

### B.4 The refund path

If step 4 fails *after* step 3 succeeded, you have taken the money and given
nothing. Every flow in the source game has an explicit refund branch, and
every refund has its own `TransactionReason` (`EggRefund`, `GearRefund`,
`ArenaRestartRefund`, `EggOpenRefund`).

```lua
if not grantSucceeded then
	EconomyService.AddMoney(player.UserId, def.Cost, TransactionReason.EggRefund)
	return false
end
```

The separate refund reasons are not bureaucratic — the Debug log and any
analytics that reads it need to distinguish "the player got this money
back" from "the player earned this money". Merging them makes the money
flow unexplainable after the fact.

### B.5 What the client sends

A client request carries **intent and identifiers only**:

```lua
-- client
RequestUpgrade:FireServer('power_1')
```

Never a price, never a level, never a "granted: true" flag. The server
re-derives all three.

The `Remotes` registry has a dedicated remote per flow in the source game
(`RequestUpgrade`, `PurchaseEgg`, `BuyGear`, …). Reuse the existing name if
one fits; otherwise add a name to `Remotes.Names` and recreate the remote in
`createRemotes()`.

### B.6 Where the price comes from

Prices live in the config domain tree, never in the calling service:

| Config | What it holds |
|---|---|
| `ReplicatedStorage/Config/Creatures/Animals.lua` | `SellBaseValue[rarity]` — the **base price** that both selling *and* upgrading are computed from |
| `ReplicatedStorage/Config/Creatures/Eggs.lua` | `Price[rarity]` — egg prices |
| `ReplicatedStorage/Config/Creatures/Progression.lua` | `MaxLevel`, `XP`, `PointsPerLevel` — the **level** rules, not prices |
| `ReplicatedStorage/Config/Economy/Money.lua` | `StartingMoney`, `MaxMoney`, income and offline tunables |

There is no `UPGRADES` table of costs. The upgrade cost is **derived**:
`base × 1.12^(level-1)`, where `base` is
`AnimalConfig.SellBaseValue[rarity]` — the same configured value the sale
formula uses. `Progression` holds the level *rules* (`MaxLevel = 100`,
`XP.BaseRequired = 200`, `XP.GrowthRate = 1.12`, `PointsPerLevel = 3`),
and the `1.12` there is the same constant the cost formula encodes as
`28/25`.

That is why the two must be retuned **together**: `UpgradeService`
*asserts* `Progression.XP.GrowthRate == 1.12` at require time. Change the
growth rate without rewriting the 28/25 math and the server fails to boot.

There is also a **documented invariant** binding egg prices to animal sell
values: `EggConfig.Price[rarity]` must equal
`AnimalConfig.SellBaseValue[rarity]` for every rarity. A level-1 animal
liquidates for 75% of its egg cost, deliberately, so hatch-and-sell can
never print money. If you retune the price table, retune the sell bases
and the multipliers *together* or the recovery band silently breaks. See
`Money.lua`'s "Cross-catalog invariants" block and
[`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) §8.

---

## Example C — Adding a System After the Fact (Economy → Upgrades)

**Goal:** you already have Example A working, and now you want the
`Upgrades` system. What does it actually cost?

This is the question the library is really asking you. The answer is
*small, but not zero*, and the steps are mechanical.

### C.1 Copy the files

`Upgrades` is at `Systems/Upgrades/`. Copy its `Source/` tree into your
project, preserving the Roblox paths. In practice that means:

```
Systems/Upgrades/Source/ReplicatedStorage/Config/Creatures/Progression.lua
  → ReplicatedStorage/Config/Creatures/Progression.lua
```

Check `Systems/Upgrades/Dependencies.md` for the full list and for what
else the system expects to exist.

### C.2 Wire the service up

**`UpgradeService` has no `Init()`.** It is a pure-function service: it
holds no state of its own, so there is nothing to initialise. You only set
its peer refs:

```lua
local UpgradeService = require(script.Parent.UpgradeService)

UpgradeService.SetPlayerService(PlayerService)
UpgradeService.SetSlotService(SlotService)
UpgradeService.SetBaseService(BaseService)
UpgradeService.SetAnimalService(AnimalService)
UpgradeService.SetEconomyService(EconomyService)
```

This is a real difference between systems and the single most common thing
to get wrong when bolting a system on. Three wiring styles coexist in this
codebase:

| Style | Which systems | What you do |
|---|---|---|
| **Late-bound setters** | `EconomyService`, `UpgradeService`, `PlayerService` | Call `Set<Peer>Service(...)`; no `require` of the peer |
| **Direct `require`** | `RebirthService`, `ShopService`, `DoorService` | Just `require` it; the peer is a hard dependency |
| **Mixed** | `UpgradeService` (setters for peers, load-time `require` for config) | Both |

`ShopService` in particular has **no setter injection at all** — it
`require`s every dependency directly, so it must be `Init()`ed *after*
every service it calls into.

Most services with state do have an idempotent `Init()` with no arguments.
The full init order for the source game is in
[`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) §2.

### C.3 Order the setter calls

**Call the setters before any `Init()` of the service itself**, and before
anything can reach into the service. A service whose peer ref is unset does
not crash — it fails every call, returning `success = false,
error = 'service-unavailable'`. The bug is completely silent until a
player touches the feature.

`UpgradeService` has a `_wired()` check that returns
`'service-unavailable'` if *any* of its five refs is missing. If your
upgrade button "does nothing", check that all five were set.

`EconomyService` has `SetPlayerService` and `SetBaseService`.
`PlayerService` has `SetAnimalPoolSettlementHandler`. If a service's
`Dependencies.md` lists a `Set<Peer>Service` function, **call it before
`Init()`**.

### C.4 Add the remote (if the system uses one)

```lua
-- in Remotes.Names, Shared/CommonModules/Remotes.lua
RequestUpgrade = 'RequestUpgrade',
```

then make sure `createRemotes()` picks it up. It will — it iterates
`Remotes.Names` — but the client and server must agree on the name, and
the client must wait via `Remotes.WaitForReady()`.

### C.5 Register the config validator

Every config module has a `Validate(): { string }` function, and
`ConfigValidator` holds a registry of the domains it checks. If you add a
config domain, register it there, or it will be silently unvalidated.

`ConfigValidator` currently knows about **19 domains**. Note that
`Config/Economy/Shop.lua` and `Config/Creatures/Gear.lua` are *not* among
them — a pre-existing gap in the source game, recorded in
[`../../SECURITY_NOTES.md`](../../SECURITY_NOTES.md) §5 (issue S-3). It was
not fixed here because this task is an extraction, not a production change.

### C.6 Do not duplicate shared modules

`BigNumber`, `Validation`, `Debug`, `Remotes`, `Signals`, `NumberUtils`,
`StudioTestMode`, `OwnedObjectIdentity` live once, in
`Shared/Utilities/` and `Shared/CommonModules/`. If a system you are adding
"needs its own copy" of one of these, you are about to create two
`BigNumber` implementations and two sources of truth for money formatting.
That is the single most common way this library gets broken.

The complete usage map is in [`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) §5.

---

## Common mistakes

| Symptom | Cause | Fix |
|---|---|---|
| `Remotes.FireClient` does nothing | `SetRemotes` never called | Call it in `createRemotes()` |
| `attempt to get length of Remotes.Names` | `Names` is a map, not an array | `pairs(Remotes.Names)`, never `#` |
| Client HUD shows `loading...` forever | Client connected to a `RemoteEvent` that is not the one the server fired | Both sides must use `Remotes.Names.PlayerState` |
| Balance is a Lua number, precision loss | Someone did `tonumber(data.Money)` | Keep it a string everywhere |
| `Code = 'invalid-reason'` | Reason string is not in `TransactionReason` | Use the enum member |
| Money spent but nothing granted | Grant threw after the spend | Add the refund branch (§B.3) |
| Service returns `false` for everything | Late-bound peer ref was never set | Call `Set<Peer>Service()` before `Init()` |
| `require` fails after moving a file | Relative `script.Parent.Parent…` paths broke | Fix the requires; each file's `Dependencies.md` lists them |
| Two different `BigNumber` modules exist | A system was copied with its own copy | Delete the duplicate; use `Shared/Utilities/` |

---

## Related documents

- [`../../MEMORY.md`](../../MEMORY.md) — how the library actually works
- [`../../SYSTEM_INDEX.md`](../../SYSTEM_INDEX.md) — every system and its entry point
- [`../../DEPENDENCY_MAP.md`](../../DEPENDENCY_MAP.md) — init order, shared modules, remote protocol
- [`../../PROJECT_SETUP.md`](../../PROJECT_SETUP.md) — the Rojo projects and the 9-step integration
- [`../../Templates/IntegrationChecklist.md`](../../Templates/IntegrationChecklist.md) — pre-ship checklist
- [`../MinimalGame/`](../MinimalGame/) — the runnable version of Example A
