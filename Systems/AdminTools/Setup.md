# AdminTools — Setup

Installing the admin framework and its 68 Cmdr commands into a new Rojo
project.

---

## 1. Install the Wally package

```toml
# wally.toml
[server-dependencies]
Cmdr = "evaera/cmdr@~1.12.0"
```

**Pin to 1.12.x.** Do not move to 1.13.0: it reshuffled the package
layout (`Command` moved under `CmdrClient`, `init.luau` uses `const`) and
the bootstrap in this system would need to be rewritten.

Then run:

```bash
wally install
```

### Map the package into Rojo

Cmdr is a **server** dependency, so it lands in `ServerPackages/`. Map
it to `ServerScriptService.Packages.Cmdr`:

```json
{
  "name": "MyGame",
  "tree": {
    "$className": "DataModel",
    "ServerScriptService": {
      "$path": "src/ServerScriptService",
      "Packages": {
        "$className": "Folder",
        "Cmdr": {
          "$path": "ServerPackages/Cmdr.lua"
        }
      }
    },
    "ReplicatedStorage": {
      "$path": "src/ReplicatedStorage"
    },
    "StarterPlayer": {
      "StarterPlayerScripts": {
        "$path": "src/StarterPlayer/StarterPlayerScripts"
      }
    }
  }
}
```

`ServerPackages/Cmdr.lua` is the file Wally generates:

```lua
return require(script.Parent._Index["evaera_cmdr@1.12.0"]["cmdr"])
```

The bootstrap requires it as
`ServerScriptService:WaitForChild('Packages'):WaitForChild('Cmdr')`.

---

## 2. Copy the framework files

| From the library | To your project | Roblox path |
|---|---|---|
| `Source/ServerScriptService/Admin/AdminConfig.lua` | `src/ServerScriptService/Admin/AdminConfig.lua` | `ServerScriptService.Admin.AdminConfig` |
| `Source/ServerScriptService/Admin/AdminService.lua` | `src/ServerScriptService/Admin/AdminService.lua` | `ServerScriptService.Admin.AdminService` |
| `Source/ServerScriptService/Admin/AdminArgs.lua` | `src/ServerScriptService/Admin/AdminArgs.lua` | `ServerScriptService.Admin.AdminArgs` |
| `Source/ServerScriptService/Admin/AdminTargetResolver.lua` | `src/ServerScriptService/Admin/AdminTargetResolver.lua` | `ServerScriptService.Admin.AdminTargetResolver` |
| `Source/ServerScriptService/Admin/AdminRateLimit.lua` | `src/ServerScriptService/Admin/AdminRateLimit.lua` | `ServerScriptService.Admin.AdminRateLimit` |
| `Source/ServerScriptService/Admin/AdminAudit.lua` | `src/ServerScriptService/Admin/AdminAudit.lua` | `ServerScriptService.Admin.AdminAudit` |
| `Source/ServerScriptService/Admin/AdminNotify.lua` | `src/ServerScriptService/Admin/AdminNotify.lua` | `ServerScriptService.Admin.AdminNotify` |
| `Source/ServerScriptService/Admin/AdminDelivery.lua` | `src/ServerScriptService/Admin/AdminDelivery.lua` | `ServerScriptService.Admin.AdminDelivery` |
| `Source/ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` | `src/ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` | `ServerScriptService.Cmdr.Server.CmdrBootstrap` |
| `Source/ServerScriptService/Cmdr/Server/Commands/*.lua` (136) | `src/ServerScriptService/Cmdr/Server/Commands/` | `ServerScriptService.Cmdr.Server.Commands` |
| `Source/ServerScriptService/Cmdr/Server/Types/*.lua` (8) | `src/ServerScriptService/Cmdr/Server/Types/` | `ServerScriptService.Cmdr.Server.Types` |
| `Source/ReplicatedStorage/Config/Systems/Security.lua` | `src/ReplicatedStorage/Config/Systems/Security.lua` | `ReplicatedStorage.Config.Systems.Security` |

**`Security.lua` already exists in most games.** If yours does, **merge**
the `Security.Admin` block into it rather than overwriting the file —
it also carries the receipt, door and placement budgets:

```lua
Security.Admin = {
    WindowSeconds = 10,
    MaxPerWindow = 30,
    MinGapSeconds = 0.2,
}
```

Copy the whole `Commands/` folder or nothing — Cmdr pairs `<name>.lua`
with `<name>Server.lua` **by filename**, and a definition without its
`Server` counterpart runs a `nil` `Run`.

---

## 3. Install the shared modules

| From the library | Roblox path | Used by |
|---|---|---|
| `Shared/Utilities/CmdrTypeUtil.lua` | `ReplicatedStorage.Utility.CmdrTypeUtil` | all 8 custom types |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage.Utility.Debug` | `AdminAudit` + 20 commands |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` | `AdminNotify.FormatMoney` + 6 commands |
| `Shared/Utilities/RichTextFormatter.lua` | `ReplicatedStorage.Utility.RichTextFormatter` | `AdminNotify.Escape` + 3 commands |
| `Shared/Utilities/Validation.lua` | `ReplicatedStorage.Utility.Validation` | 5 commands (money amount parsing) |
| `Shared/Types/TransactionReason.lua` | `ReplicatedStorage.Types.TransactionReason` | 6 commands |
| `Shared/Types/RarityType.lua` | `ReplicatedStorage.Types.RarityType` | `/setlevel`, `/spawnegg` |
| `Shared/Types/SlotType.lua` | `ReplicatedStorage.Types.SlotType` | `/cancelcarry`, `/removeanimal` |

`RichTextFormatter` must expose `Escape`, `Colored` and `AdminHex` —
`/resetplayer` and `/wipeplayer` use all three.

---

## 4. Install the canonical game configs

`AdminArgs` requires these **ten** config modules at load time. If your
game does not have them, create stubs with the same shapes:

| Roblox path | Required shape |
|---|---|
| `ReplicatedStorage.Config.Creatures.Animals` | `Get(defId) -> rarity?, def?` and `.Catalog` = `{ [rarity] = { [defId] = { displayName = string } } }` |
| `ReplicatedStorage.Config.Creatures.Eggs` | `.Price` = `{ [rarity] = number }` |
| `ReplicatedStorage.Config.Creatures.Traits` | `Get(id) -> def?` and `.Catalog` = `{ [id] = def }` |
| `ReplicatedStorage.Config.Creatures.Mutations` | `Get(id) -> def?` and `.Catalog` = `{ [id] = def }` |
| `ReplicatedStorage.Config.Creatures.Rarity` | `.Order` = `{ rarityId, ... }` (an array) and `.RarityDisplayName` = `{ [rarity] = string }` |
| `ReplicatedStorage.Config.Creatures.Progression` | `.MaxLevel` (number), `.AdminLevelCap` (number) |
| `ReplicatedStorage.Config.Economy.Gear` | `FindGear(id) -> { Id, Name }?` and `GetAll() -> { { Id, Name } }` |
| `ReplicatedStorage.Config.Economy.Rewards` | `.Codes` with `NormalizeCode(s) -> string?`, `FindById(id) -> def?`, `GetAll() -> { { Id } }` |
| `ReplicatedStorage.Config.Economy.Rebirth` | `MaxConfigured() -> number` |
| `ReplicatedStorage.Config.World.Arena` | `MaxLevel() -> number` |

Also required by individual commands (all optional for the framework,
required for those commands): `Config.Economy.Money`.

---

## 5. Install the game services the commands drive

Every one of these is required **at command-invocation time**, not at
boot — the `Run` functions require them lazily. A missing service makes
that one command fail; it does not break the bootstrap.

| Roblox path | Commands |
|---|---|
| `ServerScriptService.PlayerService` | 17 commands + `AdminNotify` + `AdminDelivery` |
| `ServerScriptService.BaseService` | 20 commands + `AdminDelivery` |
| `ServerScriptService.Base.SlotService` | `/giveegg`, `/giveanimal` (via `AdminDelivery`) |
| `ServerScriptService.Base.BaseLockService` | `/lockbase`, `/unlockbase` |
| `ServerScriptService.Base.DynamicSlotService` | 1 command |
| `ServerScriptService.Codes.CodesService` | `/redeemcode`, `/codeinfo` (+ `AdminDelivery`) |
| `ServerScriptService.EconomyService` | 7 commands |
| `ServerScriptService.EggService` | `/giveegg`, `/spawnegg` |
| `ServerScriptService.Egg.SpawnService` | `/eggstatus`, `/listcentereggs`, `/killcenteregg` |
| `ServerScriptService.Egg.Catalog` | 1 command |
| `ServerScriptService.AnimalService` | `/giveanimal`, `/getstats`, `/listanimals` |
| `ServerScriptService.Animal.AnimalOverhead` | 1 command |
| `ServerScriptService.MutationService` | 1 command |
| `ServerScriptService.TraitService` | 1 command |
| `ServerScriptService.Arena.ArenaService` | 5 commands |
| `ServerScriptService.Arena.ArenaProgressionService` | 4 commands |
| `ServerScriptService.Rebirth.RebirthService` | 6 commands |
| `ServerScriptService.Steal.StealService` | 4 commands |
| `ServerScriptService.Carry.CarryRegistry` | 5 commands |
| `ServerScriptService.Daily.DailyRewardsService` | 2 commands |
| `ServerScriptService.Playtime.PlaytimeRewardsService` | 2 commands |
| `ServerScriptService.ModifierService` | 2 commands |
| `ServerScriptService.GearShop.GearShopService` | 2 commands |
| `ServerScriptService.Combat.RagdollService` | 2 commands |
| `ServerScriptService.Event.EventService` | `/event` |
| `ServerScriptService.SellService` | `/sellanimal` |
| `ServerScriptService.StandPresentation` | `/standinfo` |
| `ServerScriptService.ServerLuckService` | `/luck` |

**The minimum viable install** is the framework plus
`PlayerService` + `BaseService` + `SlotService` + `CodesService` +
`EggService` + `AnimalService`. That covers `/giveegg`, `/giveanimal`,
`/announce`, `/adminlog`, `/tell` and the read-only info commands. Copy
the rest of the `Commands/` folder only as the matching services land.

---

## 6. Configure the allowlist

Open `src/ServerScriptService/Admin/AdminConfig.lua` and fill in the
allowlist:

```lua
AdminConfig.Admins = {
    [12345678] = { rank = 'superadmin' },
    [87654321] = { rank = 'admin' },
    [11111111] = { rank = 'mod' },
}
```

**It ships EMPTY** — nobody is an admin until you add someone. That is
the safe default.

> **SECURITY NOTE.** The source game shipped a live allowlist here
> (real userIds plus the Studio ids `0`/`1`/`2` with no `IsStudio()`
> gate). Those were removed at extraction. **The Studio ids `0`, `1` and
> `2` are always joined in a Studio playtest and are always real
> players in a live server.** If you want them, gate them:

```lua
local RunService = game:GetService('RunService')
if RunService:IsStudio() then
    AdminConfig.Admins[0] = { rank = 'superadmin' }
end
```

**Do not put a Discord webhook, API key or any other credential
anywhere in this system.** There is nowhere for one to go — the admin
framework makes no HTTP calls.

---

## 7. Fix the `Superadmin` case bug before you ship

`AdminConfig.RankOrder` is keyed `mod` / `admin` / `superadmin`
(lower case), but `AdminConfig.SuperadminGroup` is `'Superadmin'`
(capital S). `AdminService.CanRun` looks the rank up **verbatim**:

```lua
local requiredLevel = AdminConfig.RankOrder[requiredRank]
if not requiredLevel then
    return false   -- unknown rank -> DENY
end
```

So `/addadmin`, `/removeadmin` and `/shutdown` — which all call
`AssertCanRun(userId, AdminConfig.SuperadminGroup)` — **deny everyone,
including superadmins.** They are unusable as shipped.

**The one-line fix**, in `AdminService.CanRun`:

```lua
local requiredLevel = AdminConfig.RankOrder[string.lower(requiredRank)]
```

`'Superadmin'` → `'superadmin'` and `'Admin'` → `'admin'` are both keys
of `RankOrder`, so this repairs all three commands at once.

Do this **before** you rely on `/addadmin` to bootstrap the allowlist at
runtime — as shipped, it cannot grant anything.

---

## 8. Bootstrap

### Server

In your `src/ServerScriptService/bootstrap.server.lua`, **after** the
gameplay services are wired:

```lua
-- --- Cmdr admin framework ------------------------------------
-- Requiring the script IS the registration. There is no Init().
require(script.Parent.Cmdr.Server.CmdrBootstrap)
```

That single line:

1. requires Cmdr from `ServerScriptService.Packages.Cmdr`;
2. registers Cmdr's built-in commands (help / version / credits);
3. registers the **mandatory** `BeforeRun` pass-through hook;
4. registers the 8 custom argument types;
5. registers the 68 commands;
6. prints `[CmdrBootstrap] registered N commands + 1 BeforeRun hook(s)`.

**Check that print.** `N` should be **71** (68 admin commands + 3
Cmdr built-ins). A lower number means a command module threw during
registration — Cmdr's `RegisterCommandsIn` has **no `pcall`**, so one bad
file silently skips every command after it in the folder.

### Client

In your `src/StarterPlayer/StarterPlayerScripts/bootstrap.client.lua`:

```lua
local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))
```

`ReplicatedStorage.CmdrClient` **does not exist until the server has
required Cmdr** — Cmdr's own `Initialize.lua` is what parents it to
`ReplicatedStorage`. This `WaitForChild` blocks forever if the server
side is missing, so if your client hangs at startup, check the server
bootstrap first.

The default Cmdr activation key is **F2**.

### The exact order

```text
1. ReplicatedStorage.Utility.*  and  ReplicatedStorage.Config.*   (shared + configs)
2. ServerScriptService.Admin.*                                     (8 modules)
3. ServerScriptService.Cmdr.Server.Types.*                         (8 modules)
4. ServerScriptService.Cmdr.Server.Commands.*                      (136 modules)
5. Game services wired (PlayerService, BaseService, ArenaService, ...)
6. require(CmdrBootstrap)
7. On the client: require(ReplicatedStorage:WaitForChild('CmdrClient'))
```

---

## 9. Author the Studio assets

**None.** The admin framework needs no `Workspace` hierarchy and no
authored instances. The commands that touch the world resolve it through
the game's own services.

---

## 10. Smoke test

### A. Does it load?

1. Start the server. Expect **no errors** in the Output window.
2. Expect this line:
   ```text
   [CmdrBootstrap] registered 71 commands + 1 BeforeRun hook(s) (Studio)
   ```
   **71** = 68 admin commands + 3 built-ins. If you see fewer, a
   command module threw — the console will show the error, and every
   command after the bad file is missing.
3. Expect **no** warning like
   `[CmdrBootstrap] BeforeRun hook NOT registered — commands will be blocked`.
   If you see it, the `RegisterHook` call was removed.

### B. Does the gate work?

4. **As a non-admin**, type `/adminlog` in the client console (F2).
   Expect:
   ```text
   [Admin] you are not an admin.
   ```
   And **nothing** else — no audit entry for a non-admin attempt? (It
   *will* be audited only if the command got past the gate, which it
   did not. `/adminlog` audits *after* the gate, so a rejected non-admin
   leaves **no** trace. That is intentional.)
5. **As an admin** (your allowlisted userId), run `/adminlog`. Expect a
   success string and the audit trail to include the attempt.

### C. Does the target resolver work?

6. As an admin, run `/listplayers`. Expect the player list.
7. Run `/arenainfo me`. Expect your own arena report.
8. Run `/arenainfo all`. Expect a report for every player in the
   server.
9. Run `/arenainfo "NoSuchPlayer"`. Expect
   `No player "NoSuchPlayer" is in this server.`
10. With two players sharing a display name, run `/arenainfo <display>`.
    Expect the **ambiguity** error listing both usernames — never a
    silent pick.

### D. Does the rate limiter work?

11. Run `/adminlog` 31 times in quick succession. Expect the first 30
    to work and the 31st to return
    `Slow down: admin commands are rate limited (30 per 10s).`
    Wait 10 seconds and try again — it should work.

### E. Does the audit trail work?

12. Run `/adminlog 5`. Expect the newest-first entries with the
    `#N actor=... command=... success=...` format.
13. Confirm the entries include the commands you just ran.

### F. Does a grant work?

14. `/giveegg me Legendary`. Expect:
    - the executor's chat: `Gave 1 x Legendary Egg to <your name>.`
    - a toast to you: `You received a Legendary Egg!`
    - an egg in your base.
15. `/giveegg me Legendary` again with your base **full**. Expect the
    queued path:
    - `Gave 0 of 1 Legendary Egg to <your name>.` (or the "no free egg
      storage" wording)
    - a toast to you saying the reward is **queued**.
    - the egg delivered after you free a slot and run
      `/deliverpending me`.
16. `/giveanimal me Dragon` — expect the same three outcomes.
17. `/giveanimal me Dragon - Galactic,Frost`. Expect
    `Dragon — Galactic, Frost` in the summary.
18. `/giveanimal me Dragon Gold,Frost`. Expect a **rejection**:
    `Animals support only one trait; pass a single trait, not a list.`
19. `/giveanimal me Dragon - Frost,Frost`. Expect
    `Duplicate mutation: "Frost".`

### G. Does the placeholder behaviour hold?

20. `/setlevel me Common 50`. Expect
    `setlevel is a placeholder; would set <name> Common -> 50.` and
    **no** change to the player.
21. `/slowmode 30`. Expect
    `slowmode is a placeholder; would set 30s.` and **no** change to
    chat.

### H. Are the broken commands still broken? (fix them first)

22. `/addadmin <yourUserId> superadmin`. Before the case fix this
    **always fails** with
    `[Admin] you are rank "superadmin"; this command requires rank "Superadmin".`
    After the fix it should succeed.
23. `/removeadmin <yourUserId>` — same.

---

## 11. Optional: use the shipped spec

`Tests/AdminFramework.spec.lua` is a TestEZ spec with **18 cases**. It
uses the **real** `Admin/*` modules and the **real** canonical configs —
no players, no `Workspace`, no `DataStore`.

**Run it BEFORE the Cmdr bootstrap.**

Cmdr's `Registry:RegisterTypesIn` and `Registry:RegisterCommand`
**re-parent** the type and command-definition ModuleScripts into
`ReplicatedStorage.CmdrClient`. Once `CmdrBootstrap` has run,
`ServerScriptService.Cmdr.Server.Types` is **empty** and
`...Commands` holds only the `*Server.lua` halves — so the spec's
`custom types exist as modules` case fails, and the
`command definition contract` case finds 0 command definitions instead
of 68.

Two ways around it:

- **Run the spec in a separate test place** that never requires the
  bootstrap. The spec's `command definition contract` block reads the
  commands folder directly, so the files must still be in
  `ServerScriptService.Cmdr.Server.Commands` — which they are, as long
  as the bootstrap has not run in that place.
- **Or** change the spec to read `ReplicatedStorage.CmdrClient.Types`
  and `ReplicatedStorage.CmdrClient.Commands` instead.

Copy the spec into your test tree, for example:

```
src/Tests/ServerScriptService/TestEZTests/AdminFramework.spec.lua
```

and run the TestEZ runner. See `ReusableSystems/Tests/README.md`.

The spec also requires `ReplicatedStorage.Utility.CmdrTypeUtil` — it
tests `FuzzyFilter`, `ExactMatch`, `BestMatch` and `Trimmed` directly.

---

## 12. Optional: the shipped `Config.lua`

`Config.lua` in this folder is a **read-only, commented copy** of every
tunable. Nothing requires it. To change a value:

| Value | Where it actually lives | Needs a restart? |
|---|---|---|
| The allowlist | `AdminConfig.Admins` | Yes (edit the file) |
| The rank order | `AdminConfig.RankOrder` | Yes |
| The rate-limit budget | `Security.Admin` | **Yes** — `AdminRateLimit` snapshots it at module load |
| The audit buffer size (100) | a literal in `AdminAudit.lua:22` | Yes |
| The audit default count (10) | a literal in `AdminAudit.lua:67` | Yes |
| The audit truncation (160 / 180) | literals in `AdminAudit.lua:47,57` | Yes |
| The level ceilings | the game's `Progression` / `Arena` / `Rebirth` configs | No — read at call time |
| The grant quantity caps | literals in the command `Run` files | Yes |
| `/tell` max (240) | a literal in `tellServer.lua` | Yes |
| `/ragdoll` bounds | literals in `ragdollServer.lua` | Yes |
| `/speed` bounds | literals in `speedServer.lua` | Yes |
| `/setmoneymultiplier` bounds | literals in `setMoneyMultiplierServer.lua` | Yes |
| `/slowmode` bounds | literals in `slowmodeServer.lua` | Yes |

Mirror your changes into `Config.lua` so the library copy stays an
accurate reference.
