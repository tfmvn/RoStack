# AdminTools

The admin framework and its 68 Cmdr commands.

**Portability:** Grade **A** core (the rank allowlist, the gate, the
argument resolvers, the target resolver, the rate limiter, the audit ring
buffer, the delivery pipeline, the Cmdr bootstrap) + Grade **B** (the command
suite itself, which is Brainrot Arena's admin surface, and the allowlist
entries, which are environment-specific).

**Source game:** Brainrot Arena (`p-7`).

---

## What It Does

Two layers that are deliberately kept apart:

**The framework** — eight modules under `ServerScriptService/Admin/` that
have no command-specific knowledge:

| Module | Job |
|---|---|
| `AdminConfig` | The allowlist (`Admins`), the rank order, the Cmdr group names. |
| `AdminService` | "Is this userId an admin, at what rank, may they run this?" — the single source of truth. |
| `AdminArgs` | Canonical server-side resolution of animal/rarity/trait/mutation/gear/code/level/quantity arguments. |
| `AdminTargetResolver` | Turns raw target text (`me` / `all` / `server` / a name) into a concrete player list. |
| `AdminRateLimit` | A per-admin sliding-window throttle. |
| `AdminAudit` | An in-memory ring buffer of the last 100 executions, plus a `Debug.Log` trail. |
| `AdminNotify` | The one place admin commands build player-facing text and send toasts. |
| `AdminDelivery` | The one path that grants slot-bound items (eggs, animals). |

**The command suite** — 68 Cmdr commands, each a **pair** of files:

- `<name>.lua` — the shared **command definition** (`Name`, `Aliases`,
  `Description`, `Group`, `Args`). This file is replicated to the client.
- `<name>Server.lua` — the server-only **Run** function. It never executes
  on the client.

Cmdr's convention is `RegisterCommandsIn` pairs `<name>.lua` with
`<name>Server.lua` automatically; a file whose name contains `Server` is
skipped by the walker.

### The security model, in one paragraph

Cmdr 1.12's registration filter receives **only the command object — never
the calling player**. So Cmdr's group system *cannot* be used for per-player
authorization at registration time. The framework works around this by
registering **every** command with an accept-all filter and putting the real
gate **inside** each `Run` function, as its first statement:

```lua
AdminService.AssertAdmin(context.Executor.UserId)          -- most commands
AdminService.AssertCanRun(context.Executor.UserId, 'superadmin')  -- 9 commands
```

Cmdr's `BeforeRun` hook is registered as a **pass-through** (`return nil`).
It exists only because Cmdr 1.12 blocks *all* command execution while
`Registry.Hooks.BeforeRun` is empty — without it, nothing runs at all. It
grants nothing; the per-command gate remains the only authority.

---

## Entry Points

| Entry point | Kind | Notes |
|---|---|---|
| `require(ServerScriptService.Cmdr.Server.CmdrBootstrap)` | Server script | **The only entry point.** Registering the commands is a side effect of requiring the script. There is no `Init()` to call. |
| `AdminService.IsAdmin(userId): boolean` | Server | True if the userId is in the allowlist with any rank. |
| `AdminService.GetRank(userId): string?` | Server | The rank string, or `nil`. |
| `AdminService.GetRankLevel(userId): number` | Server | `mod`=1, `admin`=2, `superadmin`=3, `0`=not an admin. |
| `AdminService.CanRun(userId, requiredRank?): boolean` | Server | The predicate behind the gate. Denies by default on an unknown rank name. |
| `AdminService.AssertCanRun(userId, requiredRank?)` | Server | **Throws** when the check fails. |
| `AdminService.AssertAdmin(userId)` | Server | **Throws** `'[Admin] you are not an admin.'` when the user is not in the allowlist. |
| `AdminService.AddAdmin(userId, rank): boolean` | Server | Mutates the allowlist in place. `false` on invalid input or unknown rank. |
| `AdminService.RemoveAdmin(userId): boolean` | Server | `false` when the userId was not an admin. |
| `AdminService.ListAdmins(): { {userId, rank} }` | Server | Sorted by rank level, then by userId. |
| `AdminTargetResolver.Resolve(rawText, executor)` | Server | `{ok, players?, scope?, label?, error?}`. |
| `AdminTargetResolver.Describe(players, scope?): string` | Server | `'3 players'` or the single player's name. |
| `AdminRateLimit.Check(userId): (boolean, string?)` | Server | `false` + a message when throttled. |
| `AdminAudit.Log(executorUserId, command, fields?, success, message?)` | Server | Appends to the ring buffer and logs. |
| `AdminAudit.Recent(count?): { string }` | Server | Newest-first. Default 10, max 100. |
| `AdminArgs.ResolveAnimal/ResolveRarity/ResolveTrait/ResolveMutations/ResolveGear/ResolveCode/ResolveAnimalLevel/ResolveArenaLevel/ResolveRebirthIndex/ResolveQuantity` | Server | All return `(ok, value | errorString)`. |
| `AdminNotify.Escape/Tell/TellAll/FormatMoney/EggLabel/DescribeEgg/DescribeAnimal` | Server | Text building and toast delivery. |
| `AdminDelivery.GiveEgg(userId, rarity, trait?, mutations?)` | Server | `{ok, record}` / `{queued}` / `{failed, error}`. |
| `AdminDelivery.GiveAnimal(userId, defId, trait?, mutations?, level?)` | Server | `{ok, record}` / `{queued}` / `{failed, error}`. |

---

## Files

| Library path | Roblox destination | Purpose |
|---|---|---|
| `Source/ServerScriptService/Admin/AdminConfig.lua` | `ServerScriptService.Admin.AdminConfig` | The allowlist, the rank order, the group names. |
| `Source/ServerScriptService/Admin/AdminService.lua` | `ServerScriptService.Admin.AdminService` | The permission gate. |
| `Source/ServerScriptService/Admin/AdminArgs.lua` | `ServerScriptService.Admin.AdminArgs` | Canonical argument resolvers. |
| `Source/ServerScriptService/Admin/AdminTargetResolver.lua` | `ServerScriptService.Admin.AdminTargetResolver` | The player-target resolver. |
| `Source/ServerScriptService/Admin/AdminRateLimit.lua` | `ServerScriptService.Admin.AdminRateLimit` | The sliding-window throttle. |
| `Source/ServerScriptService/Admin/AdminAudit.lua` | `ServerScriptService.Admin.AdminAudit` | The audit ring buffer. |
| `Source/ServerScriptService/Admin/AdminNotify.lua` | `ServerScriptService.Admin.AdminNotify` | Text building + toasts. |
| `Source/ServerScriptService/Admin/AdminDelivery.lua` | `ServerScriptService.Admin.AdminDelivery` | The grant pipeline for eggs and animals. |
| `Source/ServerScriptService/Cmdr/Server/CmdrBootstrap.luau` | `ServerScriptService.Cmdr.Server.CmdrBootstrap` | The bootstrap script. Registers everything. |
| `Source/ServerScriptService/Cmdr/Server/Commands/*.lua` (136 files) | `ServerScriptService.Cmdr.Server.Commands` | 68 definition + 68 `Run` pairs. |
| `Source/ServerScriptService/Cmdr/Server/Types/*.lua` (8 files) | `ServerScriptService.Cmdr.Server.Types` | The custom Cmdr argument types. |
| `Source/ReplicatedStorage/Config/Systems/Security.lua` | `ReplicatedStorage.Config.Systems.Security` | The admin rate-limit budget. |

**Shared modules this system needs** (not in this folder):

| Library path | Roblox destination |
|---|---|
| `Shared/Utilities/CmdrTypeUtil.lua` | `ReplicatedStorage.Utility.CmdrTypeUtil` |
| `Shared/Utilities/Debug.lua` | `ReplicatedStorage.Utility.Debug` |
| `Shared/Utilities/BigNumber.lua` | `ReplicatedStorage.Utility.BigNumber` |
| `Shared/Utilities/RichTextFormatter.lua` | `ReplicatedStorage.Utility.RichTextFormatter` |

---

## Configuration

### `AdminConfig` — the allowlist (Grade B, environment-specific)

**The allowlist in this library copy is EMPTY.** That is deliberate and it is
the safe default: nobody is an admin until you add someone.

> **SECURITY NOTE (library extraction).** The source game shipped a **live
> allowlist** in this file — two real userIds plus the Studio test ids `0`,
> `1` and `2`, **with no `RunService:IsStudio()` gate on the Studio ids**.
> Those entries were removed at extraction. Do not reintroduce them
> ungated; the ids `0`/`1`/`2` are always joined in Studio and are always
> real players in a live server.

Bootstrap it one of two ways:

```lua
-- (a) in AdminConfig.lua, statically:
AdminConfig.Admins = {
    [12345678] = { rank = 'superadmin' },
    [87654321] = { rank = 'admin' },
}

-- (b) at runtime, from a server console:
/addadmin <yourUserId> superadmin
```

The allowlist is a **flat numeric table**, so an offline userId works — you
can grant power before the player ever joins.

If you want Studio-only admins, gate them yourself:

```lua
local RunService = game:GetService('RunService')
if RunService:IsStudio() then
    AdminConfig.Admins[0] = { rank = 'superadmin' }
end
```

### `Security.Admin` — the rate-limit budget (Grade A)

`ReplicatedStorage/Config/Systems/Security.lua`:

| Key | Default | Meaning |
|---|---|---|
| `WindowSeconds` | `10` | The sliding-window length. |
| `MaxPerWindow` | `30` | Max executions per window per admin. |
| `MinGapSeconds` | `0.2` | Minimum gap between two executions (a 5/second burst cap). |

These are read **once** at `AdminRateLimit` module load into locals —
editing them at runtime has no effect.

### The rank order (Grade A)

| Rank | Level | Cmdr group |
|---|---|---|
| `mod` | 1 | `Mod` (declared but currently unused — every command is admin-tier) |
| `admin` | 2 | `Admin` |
| `superadmin` | 3 | `Superadmin` |

`AdminConfig` asserts `mod < admin < superadmin` **at module load**, so a
typo in `RankOrder` throws on server start, not on the first command.

### Other config the commands read

The commands validate their arguments against the **canonical game
configs**, not against a local copy. See `Dependencies.md` for the full
list. The relevant ceilings:

| Value | Lives in | Used by |
|---|---|---|
| `Progression.MaxLevel` | `Config/Creatures/Progression.lua` | `AdminArgs.ResolveAnimalLevel` |
| `Progression.AdminLevelCap` | `Config/Creatures/Progression.lua` | `/setlevel` |
| `ArenaConfig.MaxLevel()` | `Config/World/Arena.lua` | `AdminArgs.ResolveArenaLevel` (fallback 50) |
| `RebirthConfig.MaxConfigured()` | `Config/Economy/Rebirth.lua` | `AdminArgs.ResolveRebirthIndex` (fallback 3) |

---

## Dependencies

See [Dependencies.md](Dependencies.md) for the exact require paths, the
remotes, the profile fields and the initialization order.

The short version:

- **Cmdr 1.12.0** (Wally, `evaera/cmdr@~1.12.0`) — **required**.
- **Every game service** the commands touch — `PlayerService`,
  `BaseService`, `SlotService`, `CodesService`, `EggService`,
  `AnimalService`, `ArenaService`, `RebirthService`, `EventService`,
  `ModifierService`, `CarryRegistry`, `StealService`, `EconomyService`,
  `DailyRewardsService`, `PlaytimeRewardsService`, `SpawnService`,
  `AnimalStats` — **required at runtime** for the commands that use them.
  A missing service makes that one command fail; it does not break the
  bootstrap, because every command `require`s its dependencies **lazily
  inside the `Run` function**.
- **No remotes of its own.** Admin output goes back through Cmdr's own
  `CmdrFunction` RemoteFunction (the `Run` return string) and through
  `PlayerService.Notify` for target toasts.

---

## Initialization Order

```text
1. Wally install Cmdr 1.12.0
   -> ServerScriptService.Packages.Cmdr
2. Shared utilities in place:
   ReplicatedStorage.Utility.{CmdrTypeUtil, Debug, BigNumber, RichTextFormatter}
   ReplicatedStorage.Config.Systems.Security
3. ServerScriptService.Admin.*   (8 modules)
   ReplicatedStorage.Config.Creatures.*, Config.Economy.*, Config.World.Arena
4. ServerScriptService.Cmdr.Server.Types.*  (8 modules)
5. ServerScriptService.Cmdr.Server.Commands.*  (136 modules)
6. In your bootstrap.server.lua, AFTER the gameplay services are wired:
     require(script.Parent.Cmdr.Server.CmdrBootstrap)
7. On the client (StarterPlayerScripts):
     local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))
```

**Step 6 must come after the gameplay services are initialized.** Cmdr
registers commands immediately, but the `Run` functions resolve their
services lazily on first use, so an early registration is not fatal — it
just means the very first command of a session resolves a cold cache.

**Step 7 requires step 6 to have run**, because Cmdr's own
`Initialize.lua` is what moves `CmdrClient` into `ReplicatedStorage`
(`ReplicatedRoot.Parent = ReplicatedStorage`). Until the server has
required Cmdr, `ReplicatedStorage.CmdrClient` does not exist and the
client bootstrap blocks forever on that `WaitForChild`.

---

## Data

### The allowlist

```lua
AdminConfig.Admins = {
    [userId] = { rank = 'mod' | 'admin' | 'superadmin' },
}
```

This is the **only** persistent-ish admin state, and it is **not**
persisted: it lives in memory for the lifetime of the server. `/addadmin`
and `/removeadmin` mutate it in place; a server restart resets it to
whatever `AdminConfig.lua` says. There is no DataStore behind it.

### The audit ring buffer

```lua
AdminAudit.Recent(10) --> {
    '#12 actor=123 command=giveegg success=true :: Gave 1 x Legendary Egg to Bob.',
    '#11 actor=123 command=adminlog success=true :: Show recent admin audit entries.',
}
```

- A **fixed 100-entry** ring buffer. The 101st entry evicts the first.
- The sequence number `#N` is **monotonic for the server session** and
  never resets.
- The `result` tail is truncated to **160** characters in the ring-buffer
  line and to **180** characters in the `Debug.Log` flat map.
- **No persistence.** The audit trail does not survive a restart. It is
  operational telemetry, not a compliance log.

### The rate-limit state

`AdminRateLimit` keeps a per-userId array of `os.clock()` timestamps,
evicting expired ones in place on each check. It is unbounded in
userId count but bounded in stamps per user (≤ `MaxPerWindow`).

### Profile fields

The admin commands **read and write** the player profile through
`PlayerService` only — they never touch `ProfileService` directly. The
specific fields are listed in [Dependencies.md](Dependencies.md).

---

## Known Limitations

1. **Cmdr's group system is decorative.** The `Group` field on each
   command is used by Cmdr's help output and by the client console, but it
   is **not** the authorization mechanism. The `Run` function's
   `AssertAdmin` / `AssertCanRun` call is. A command whose `Group` says
   `Admin` but whose `Run` says `AssertCanRun(userId, 'superadmin')` is
   superadmin-only in practice — and `/resetcash` is exactly that (see
   the table below).

2. **`/resetcash` is declared `Group = 'Admin'` but gated at
   `superadmin`.** This is an inconsistency in the shipped suite, not a
   documented policy. The `Run` wins. If you port the suite verbatim,
   superadmins will be the only ones who can use it.

3. **`/setlevel` and `/slowmode` are deliberate no-ops.** Both validate
   their arguments, both write a `Debug.Log('CMDR', ... (no-op
   placeholder), ...)` line, and both return a string that says
   "is a placeholder". `/setlevel` needs a per-defId level system that
   does not exist; `/slowmode` needs a `TextChatService` integration that
   does not exist.

4. **23 of the 68 commands neither rate-limit nor audit.** The other 45
   call both `AdminRateLimit.Check` and `AdminAudit.Log`. The 23 without
   are: `/addadmin`, `/announce`, `/bring`, `/event`, `/fly`,
   `/getplayerstats`, `/getstats`, `/givemoney`, `/givexp`,
   `/killcenteregg`, `/listcentereggs`, `/listplayers`, `/removeadmin`,
   `/resetplayer`, `/setlevel`, `/setmoney`, `/shutdown`, `/slowmode`,
   `/spawnegg`, `/speed`, `/tptobase`, `/tp`, `/wipeplayer`. Several of
   these are high-impact (`/shutdown`, `/removeadmin`, `/givexp`,
   `/wipeplayer`). If you port the suite, add the two calls to any
   command that mutates state.

5. **The rate limiter is per-server, in-memory, and per-`userId`.** It
   resets on restart and it is not shared across servers. There is no
   punishment and no lockout — exceeding the budget just fails that one
   execution with a plain message.

6. **The audit buffer holds 100 entries.** On a busy server with many
   admins, `/adminlog` will not show the whole session.

7. **`/all` and `/server` never cross servers.** There is no
   `MessagingService` fan-out anywhere in this framework. A
   cross-server command would have to be a separate, explicitly-designed
   system.

8. **Ambiguous display names fail.** If two active players share a
   display name and the admin types the display name (not the username),
   the target resolution **fails** with a candidate list. It never picks
   one.

9. **`AdminConfig.Admins` is frozen only one level deep.**
   `table.freeze(AdminConfig)` freezes the module table, but `Admins` is
   a nested table and stays mutable — which is exactly what
   `AddAdmin`/`RemoveAdmin` rely on. It also means anything else with a
   reference to `AdminConfig.Admins` can mutate the allowlist.

10. **Cmdr relocates the source files.** `Registry:RegisterTypesIn` and
    `Registry:RegisterCommand` **re-parent** the type and command-definition
    ModuleScripts into `ReplicatedStorage.CmdrClient.Types` /
    `.Commands`. After the bootstrap has run, `ServerScriptService.Cmdr.Server.Types`
    is **empty** and `...Commands` holds only the `*Server.lua` halves.
    This is normal Cmdr behaviour, but it breaks any test or tool that
    expects to find the source files where you left them.

11. **The client cannot enforce anything.** The whole security model is
    server-side. A modified client can *send* any command; the server
    re-validates every argument against the canonical configs and re-checks
    the rank before doing anything.

12. **Argument validation is duplicated on purpose.** The Cmdr types
    (client-side autocomplete) and `AdminArgs` (server-side) both resolve
    the same values. The client side is UX only; the server side is the
    gate.

---

## Testing

`Tests/AdminFramework.spec.lua` is a TestEZ spec with **18 cases** across
9 `describe` blocks:

| Block | Cases | Covers |
|---|---|---|
| `AdminTargetResolver` | 4 | Non-string/empty targets, unknown players, `me` without a live executor, `all`/`server` never resolving to `Single` scope. |
| `AdminArgs animals` | 10 | Case-insensitive defId resolution, unknown animals, single-trait enforcement (including the comma rejection), mutation sorting/duplicates/unknowns/canonicalization-before-uniqueness, and the `LevelConfig.MaxLevel` ceiling. |
| `AdminArgs catalogs` | 4 | Rarity, gear (id + display name), code normalization, and the quantity / arena-level / rebirth-index bounds. |
| `AdminNotify builders` | 2 | `DescribeEgg` / `DescribeAnimal` composition and `FormatMoney`. |
| `AdminAudit` | 1 | Newest-first ordering. |
| `AdminRateLimit` | 1 | 30 allowed, the 31st blocked. |
| `CmdrTypeUtil` | 1 | Fuzzy filter, exact match, best match, trim. |
| `command definition contract` | 2 | Every definition has a name/description/group/args, every arg type is in the known set, every definition has a `*Server` counterpart, and the count is ≥ 60; and all 8 custom type modules exist. |

**The spec needs the real game in place** — it requires the actual
`Config/Creatures/*` and `Config/Economy/*` modules and the real
`ServerScriptService/Admin/*` modules. It has **no players**, no
`Workspace` and no `DataStore`; live multi-player behaviour is a Studio
manual-test concern.

**The spec must run BEFORE the Cmdr bootstrap.** The
`command definition contract` block reads
`ServerScriptService.Cmdr.Server.Commands` and
`ServerScriptService.Cmdr.Server.Types` and asserts the files are there.
Once `CmdrBootstrap` has run, Cmdr has **moved** those ModuleScripts into
`ReplicatedStorage.CmdrClient`, so the folder is empty and the
`custom types exist as modules` case fails. See `Setup.md`, step 8.

---

## The command suite

68 commands: **61** in the `Admin` group, **7** in the `Superadmin` group.
Every command is registered with an accept-all filter, so the `Group`
column below is *documentation and Cmdr-help metadata* — the **actual**
gate is the `Assert*` call in the `Run` function, which the last column
states.

| Command | Aliases | Group | Arguments | What it does | Actual gate |
|---|---|---|---|---|---|
| `/addadmin` | — | Superadmin | `userId:number`, `rank:string` | Adds or updates an admin by userId at `mod`/`admin`/`superadmin`. The userId may be offline. | `AssertCanRun(…, 'Superadmin')` |
| `/adminlog` | — | Admin | `count:number?` | Shows the newest audit entries. Default 10, max 100. | `AssertAdmin` |
| `/announce` | — | Admin | `message:string` | Broadcasts a server-wide toast. Category is forced to `System`. | `AssertAdmin` |
| `/arenainfo` | — | Admin | `target:adminTarget` | Read-only: arena level, XP, wins, highest completed stage, whether a raid is active. | `AssertAdmin` |
| `/baseinfo` | — | Admin | `target:adminTarget` | Read-only: base id, lock state + remaining lock time, slot occupancy. | `AssertAdmin` |
| `/bring` | — | Admin | `player:player` | Teleports the target to the executor's position. | `AssertAdmin` |
| `/cancelarena` | — | Admin | `target:adminTarget` | Ends the target's active expedition via `ArenaService.CancelArena` (cleared stages still pay). | `AssertAdmin` |
| `/cancelcarry` | — | Admin | `target:adminTarget` | Returns a carried animal/egg to its slot — the same dispatch as death/disconnect recovery. | `AssertAdmin` |
| `/cancelsteal` | — | Superadmin | `target:adminTarget` | Rolls back an in-progress steal via `StealService.RollbackCarried`. | `AssertCanRun(…, 'superadmin')` |
| `/carryinfo` | — | Admin | `target:adminTarget` | Read-only: what the target carries, of which kind, and whether a steal is in progress. | `AssertAdmin` |
| `/clearmoneymultiplier` | — | Admin | `target:adminTarget` | Removes the `AdminOverride` money modifier via `ModifierService.RemoveModifier`. | `AssertAdmin` |
| `/codeinfo` | — | Admin | `code:codeId` | Read-only: one code's enabled flag, expiry, caps and full reward table. | `AssertAdmin` |
| `/dailyclaim` | — | Admin | `target:adminTarget`, `day:number` | Claims a daily streak day (1-7) **for** the target through `DailyRewardsService.Claim`. There is no streak setter — it claims, never edits. | `AssertAdmin` |
| `/dailyinfo` | — | Admin | `target:adminTarget` | Read-only: current streak day, claimable day, per-day states. | `AssertAdmin` |
| `/deliverpending` | — | Admin | `target:adminTarget` | Retries queued code/admin rewards via `CodesService.TryDeliverPending`. | `AssertAdmin` |
| `/eggstatus` | — | Admin | — | Read-only: center-egg count vs cap, per-state counts, Legendary/Mythic guarantee state. | `AssertAdmin` |
| `/event` | — | Admin | `action:string`, `eventId:string?` | `status` / `start <Galaxy\|Snowfall>` / `stop` — delegates to `EventService`. | `AssertAdmin` |
| `/fly` | — | Admin | — | Toggles flight for the executor (BodyPosition + BodyGyro on the HRP). **Per-character**: respawning does not re-enable it. | `AssertAdmin` |
| `/forcerebirth` | — | Admin | `target:adminTarget` | Runs the canonical `RebirthService.RequestRebirth`. **Requirements are not bypassed** — grant money/animals first. | `AssertAdmin` |
| `/getplayerstats` | `gps` | Admin | `player:player` | Prints money, base and inventory for one player. | `AssertAdmin` |
| `/getstats` | — | Admin | `player:player`, `animalId:string` | Shows an animal's Level/XP and derived Health/Damage through `AnimalService.GetStats`. | `AssertAdmin` |
| `/giveallgear` | — | Admin | `target:adminTarget` | Grants every gear-shop entry, one at a time. | `AssertAdmin` |
| `/giveanimal` | `ga`, `addanimal` | Admin | `target:adminTarget`, `animal:animalDef`, `trait:traitId?`, `mutations:mutationList?`, `level:number?`, `quantity:number?` | Grants animals into the targets' bases through the canonical slot-reserve pipeline. Level defaults to 1, quantity to 1 (max 5). | `AssertAdmin` |
| `/givearenawin` | — | Admin | `target:adminTarget`, `level:number` | Records an arena stage clear. | `AssertAdmin` |
| `/givearenaxp` | — | Admin | `target:adminTarget`, `amount:number` | Grants arena XP. | `AssertAdmin` |
| `/givecash` | `addcash` | Admin | `target:adminTarget`, `amount:string` | **Adds** money (BigNumber string). | `AssertAdmin` |
| `/giveegg` | `ge`, `addegg` | Admin | `target:adminTarget`, `egg:eggRarity`, `trait:traitId?`, `mutations:mutationList?`, `quantity:number?` | Grants eggs. Quantity defaults to 1, max 10. | `AssertAdmin` |
| `/givegear` | — | Admin | `target:adminTarget`, `gear:gearId` | Grants one gear tool. | `AssertAdmin` |
| `/givemoney` | — | Admin | `player:player`, `amount:string` | Adds money to one player (native `player` type, not `adminTarget`). | `AssertAdmin` |
| `/givexp` | — | Admin | `player:player`, `animalId:string`, `amount:integer` | Adds XP to an animal. | `AssertAdmin` |
| `/killcenteregg` | `kcb` | Admin | `uniqueId:string` | Destroys a center egg by its unique id. | `AssertAdmin` |
| `/listanimals` | — | Admin | `target:adminTarget` | Read-only: a player's animals. | `AssertAdmin` |
| `/listcentereggs` | `lcb` | Admin | — | Lists all active center eggs. | `AssertAdmin` |
| `/listcodes` | — | Admin | — | Lists the redeem-code catalog. | `AssertAdmin` |
| `/listgear` | — | Admin | `target:adminTarget` | Read-only: gear ownership. | `AssertAdmin` |
| `/listplayers` | `lp` | Admin | — | Lists the players in this server. | `AssertAdmin` |
| `/lockbase` | — | Admin | `target:adminTarget` | Locks the target's base. | `AssertAdmin` |
| `/luck` | — | Admin | `value:string?` | Shows or sets server-wide egg luck. A multiplier, `reset`, or omitted to show. | `AssertCanRun(…, 'admin')` |
| `/playtimeclaim` | — | Admin | `target:adminTarget`, `milestone:number` | Claims a playtime milestone for the target. | `AssertAdmin` |
| `/playtimeinfo` | — | Admin | `target:adminTarget` | Read-only: playtime reward state. | `AssertAdmin` |
| `/ragdoll` | — | Admin | `target:adminTarget`, `duration:number?` | Ragdolls the target. Duration 1-30 s, default 5. | `AssertAdmin` |
| `/rebirthinfo` | — | Admin | `target:adminTarget` | Read-only: rebirth progress. | `AssertAdmin` |
| `/redeemcode` | — | Admin | `target:adminTarget`, `code:codeId` | Redeems a code for the targets. | `AssertAdmin` |
| `/removeadmin` | — | Superadmin | `userId:number` | Removes an admin. | `AssertCanRun(…, 'Superadmin')` |
| `/removeanimal` | — | Superadmin | `target:adminTarget`, `animalId:string` | **Permanently deletes** a live animal (the `BR_` unique id). | `AssertCanRun(…, 'superadmin')` |
| `/removeegg` | — | Superadmin | `target:adminTarget`, `eggId:string` | **Permanently deletes** a placed egg (the `EG_` unique id). | `AssertCanRun(…, 'superadmin')` |
| `/resetarena` | — | Superadmin | `target:adminTarget` | Resets arena progression to level 1. | `AssertCanRun(…, 'superadmin')` |
| `/resetcash` | — | Admin | `target:adminTarget` | Resets money to the starting value. **Gated at `superadmin` despite the `Admin` group.** | `AssertCanRun(…, 'superadmin')` |
| `/resetplayer` | — | Admin | `player:player` | Full data reset. An alias of `/wipeplayer`. | `AssertAdmin` |
| `/sellanimal` | — | Admin | `target:adminTarget`, `animalId:string` | Force-sells a live animal at the canonical price. | `AssertAdmin` |
| `/setanimallevel` | — | Admin | `target:adminTarget`, `animalId:string`, `level:number` | Sets a live animal's level (1-100). | `AssertAdmin` |
| `/setcash` | — | Admin | `target:adminTarget`, `amount:string` | **Sets** money to an absolute value. | `AssertAdmin` |
| `/setlevel` | — | Admin | `player:player`, `rarity:string`, `level:number` | **Placeholder — no-op.** Would set a rarity's level once the per-defId level system exists. | `AssertAdmin` |
| `/setmoney` | — | Admin | `player:player`, `amount:string` | Sets money to a value. | `AssertAdmin` |
| `/setmoneymultiplier` | — | Admin | `target:adminTarget`, `value:number` | Sets the money multiplier (0.01-100). | `AssertAdmin` |
| `/shutdown` | — | Superadmin | `reason:string` | Shuts the server down. | `AssertCanRun(…, 'Superadmin')` |
| `/slowmode` | — | Admin | `seconds:number` | **Placeholder — no-op.** Would set chat slowmode once a chat service is wired. | `AssertAdmin` |
| `/spawnegg` | `slb` | Admin | `rarity:string`, `mutations:string?`, `trait:string?`, `count:number?` | Spawns eggs at the center. Count defaults to 1, max 10. | `AssertAdmin` |
| `/speed` | — | Admin | `value:number` | Sets the executor's `WalkSpeed` (0-200). | `AssertAdmin` |
| `/standinfo` | — | Admin | `target:adminTarget` | Read-only: stand counts. | `AssertAdmin` |
| `/startarena` | — | Admin | `target:adminTarget`, `option:arenaOption?` | Starts an arena expedition. Option `Buy1`/`Buy2`/`Buy3`, default `Buy3`. | `AssertAdmin` |
| `/takecash` | `removecash` | Admin | `target:adminTarget`, `amount:string` | **Removes** money. | `AssertAdmin` |
| `/tptobase` | `tpb` | Admin | `player:player` | Teleports the executor to a player's base. | `AssertAdmin` |
| `/tell` | — | Admin | `target:adminTarget`, `message:string` | Sends a private admin message (max 240 characters). | `AssertAdmin` |
| `/tp` | — | Admin | `from:player`, `to:player` | Teleports player1 to player2. | `AssertAdmin` |
| `/unlockbase` | — | Admin | `target:adminTarget` | Unlocks the target's base. | `AssertAdmin` |
| `/unragdoll` | — | Admin | `target:adminTarget` | Stands a ragdolled player back up. | `AssertAdmin` |
| `/wipeplayer` | — | Admin | `player:player` | Wipes a player's data to defaults. | `AssertAdmin` |

### Rate limiting and auditing coverage

45 of the 68 commands call both `AdminRateLimit.Check` (after the gate)
and `AdminAudit.Log` (on success **and** on every failure path). The
other **23** call **neither**:

`/addadmin`, `/announce`, `/bring`, `/event`, `/fly`, `/getplayerstats`,
`/getstats`, `/givemoney`, `/givexp`, `/killcenteregg`, `/listcentereggs`,
`/listplayers`, `/removeadmin`, `/resetplayer`, `/setlevel`, `/setmoney`,
`/shutdown`, `/slowmode`, `/spawnegg`, `/speed`, `/tptobase`, `/tp`,
`/wipeplayer`.

Several of those are the highest-impact commands in the suite
(`/shutdown`, `/removeadmin`, `/givexp`, `/wipeplayer`, `/setmoney`).
**When you port, add the two calls to any command that mutates state.**

### Two target argument styles

- **`adminTarget`** (60 commands) — the custom type. Accepts `me`, `all`,
  `server`, a username, or a display name. Supports multi-target fan-out.
- **`player`** (8 commands: `/bring`, `/getplayerstats`, `/getstats`,
  `/givemoney`, `/givexp`, `/resetplayer`, `/setlevel`, `/setmoney`,
  `/tp`, `/tptobase`, `/wipeplayer`) — Cmdr's **native** type. One player
  only, resolved from the server's player list.

The native-`player` commands are the older ones; they predate the
`adminTarget` type and were not migrated. They also cannot target "all".

### The custom argument types

| Type | Resolves | Notes |
|---|---|---|
| `adminTarget` | `me` / `all` / `server` / username / display name | Validation is **permissive** — the server resolver is the gate. |
| `eggRarity` | `EggConfig.Price` keys | Only rarities that have a price. |
| `animalDef` | `AnimalConfig.Catalog` defIds | Display names also resolve. |
| `traitId` | `TraitConfig.Catalog` | `-` / `none` / empty mean "no trait". **Commas are rejected** — an animal carries at most one trait. |
| `mutationList` | `MutationConfig.Catalog` | **Listable** — comma-separated. |
| `gearId` | `GearConfig` entries | Ids and display names both resolve. |
| `codeId` | `CodesConfig` catalog | Normalized to upper case. |
| `arenaOption` | `Buy1` / `Buy2` / `Buy3` | Fixed list. |

---

## Adapting to a New Game

### 1. Copy the framework, drop the command suite

`ServerScriptService/Admin/*` and `ReplicatedStorage/Config/Systems/Security.lua`
are self-contained. The 136 command files are not — each one `require`s the
game services it drives.

### 2. Point the config at your game

`AdminArgs` requires these eight config modules. Replace them with your
own, keeping the same call signatures:

| Config module | Functions used |
|---|---|
| `Config.Creatures.Animals` | `Get(defId)`, `.Catalog` (bucket → defId → entry with `displayName`) |
| `Config.Creatures.Eggs` | `.Price` (rarity → price) |
| `Config.Creatures.Traits` | `Get(id)`, `.Catalog` |
| `Config.Creatures.Mutations` | `Get(id)`, `.Catalog` |
| `Config.Creatures.Rarity` | `.Order` (array of rarity ids) |
| `Config.Creatures.Progression` | `.MaxLevel` |
| `Config.Economy.Gear` | `FindGear(id)`, `GetAll()` → `{Id, Name}` |
| `Config.Economy.Rewards` | `.Codes` → `NormalizeCode`, `FindById`, `GetAll()` → `{Id}` |
| `Config.Economy.Rebirth` | `MaxConfigured()` |
| `Config.World.Arena` | `MaxLevel()` |

### 3. Rewrite the `Run` functions

For every command you keep, replace the game service calls with yours.
The **shape** of the file should stay the same:

```lua
return function(context, ...)
    local AdminService = require(ServerScriptService.Admin.AdminService)
    local AdminTargetResolver = require(ServerScriptService.Admin.AdminTargetResolver)
    local AdminArgs = require(ServerScriptService.Admin.AdminArgs)
    local AdminNotify = require(ServerScriptService.Admin.AdminNotify)
    local AdminAudit = require(ServerScriptService.Admin.AdminAudit)
    local AdminRateLimit = require(ServerScriptService.Admin.AdminRateLimit)

    AdminService.AssertAdmin(context.Executor.UserId)   -- 1. gate
    local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)  -- 2. throttle
    if not rateOk then
        AdminAudit.Log(context.Executor.UserId, 'mycmd', { ... }, false, rateErr)
        return rateErr                                    -- 3. audit the failure
    end
    local resolved = AdminTargetResolver.Resolve(target, context.Executor)  -- 4. resolve
    if not resolved.ok then
        AdminAudit.Log(context.Executor.UserId, 'mycmd', { ... }, false, resolved.error)
        return resolved.error
    end
    -- 5. revalidate every argument with AdminArgs
    -- 6. do the work
    -- 7. notify ONLY after the operation succeeded
    -- 8. AdminAudit.Log(..., success, summary)
    -- 9. return the summary string (Cmdr shows it to the executor)
end
```

### 4. Write the definition file to match

```lua
return {
    Name = 'mycmd',
    Aliases = { 'mc' },
    Description = 'What it does (admin-only).',
    Group = 'Admin',           -- 'Admin' | 'Superadmin' | 'Default'
    Args = {
        { Type = 'adminTarget', Name = 'target', Description = '...' },
        { Type = 'number', Name = 'amount', Description = '...' },
    },
}
```

And name the `Run` file `<definition file name>Server.lua` in the same
folder. Cmdr pairs them by name.

**Only these Cmdr argument types are available** (the spec asserts it):
`player`, `players`, `string`, `strings`, `number`, `numbers`, `integer`,
`positiveInteger`, `boolean`, plus the eight custom types. Any other
`Type` string makes Cmdr's `RegisterCommandObject` throw, and a throw
inside the registration loop **skips the rest of the folder** — so one bad
command silently unregisters everything after it.

### 5. Add the new type, if you need one

Drop a `ModuleScript` into `Types/` returning `function(cmdr) ... end` and
calling `cmdr:RegisterType(name, {...})`. The allowed keys are exactly:
`Transform`, `Validate`, `Autocomplete`, `Parse`, `DisplayName`,
`Listable`, `ValidateOnce`, `Prefixes`, `Default`,
`ArgumentOperatorAliases`. Any other key throws.

### 6. Never rely on `Group` alone

If you write a command that should be superadmin-only, use
`AssertCanRun(context.Executor.UserId, 'superadmin')` — **not** just
`Group = 'Superadmin'`. And use the same casing convention: the two
existing spellings (`AdminConfig.SuperadminGroup` = `'Superadmin'` and the
literal `'superadmin'`) both work because `AdminConfig.RankOrder` is
keyed by the **lower-case** rank and `CanRun` looks the rank up in
`RankOrder` — wait, it looks it up *verbatim*:

```lua
local requiredLevel = AdminConfig.RankOrder[requiredRank]
if not requiredLevel then return false end   -- unknown rank -> DENY
```

`RankOrder` keys are `mod`, `admin`, `superadmin` (lower case).
`AdminConfig.SuperadminGroup` is `'Superadmin'` (capital S) — **that
key is NOT in `RankOrder`**. So `AssertCanRun(userId, AdminConfig.SuperadminGroup)`
looks up `RankOrder['Superadmin']`, finds `nil`, and **denies everyone**,
including superadmins.

**This is a live bug in the shipped suite.** `/addadmin`, `/removeadmin`
and `/shutdown` all call `AssertCanRun(..., AdminConfig.SuperadminGroup)`
and are therefore **unusable** — every invocation throws
`[Admin] you are rank "superadmin"; this command requires rank "Superadmin".`
(for a caller who is an admin) or
`[Admin] you are not an admin; this command requires rank "Superadmin".`
(for one who is not).

The four commands that use the literal lowercase `'superadmin'`
(`/cancelsteal`, `/removeanimal`, `/removeegg`, `/resetarena`) work
correctly. So does `/luck` (`'admin'`).

**Fix it when you port** — either use the lowercase literal
`'superadmin'` everywhere, or change `AdminConfig.RankOrder` to be keyed
by the group names (`'Mod'`, `'Admin'`, `'Superadmin'`), or make
`CanRun` lowercase its lookup key. The one-line fix in `CanRun`:

```lua
local requiredLevel = AdminConfig.RankOrder[string.lower(requiredRank)]
```

…would not be enough on its own either, because `RankOrder` is keyed
`mod`/`admin`/`superadmin` while `'Superadmin'` lowercases to
`'superadmin'` — actually it **would** be enough. `string.lower('Superadmin')
== 'superadmin'` is a key in `RankOrder`. So that one-line change fixes
all three broken commands at once.

**Do not ship the three broken commands as-is.**

### 7. Bootstrap

```lua
-- bootstrap.server.lua
require(script.Parent.Cmdr.Server.CmdrBootstrap)
```

and on the client:

```lua
local CmdrClient = require(ReplicatedStorage:WaitForChild('CmdrClient'))
```

---

## See also

- [MEMORY.md](MEMORY.md) — the engineering notes.
- [API.md](API.md) — every public function.
- [Dependencies.md](Dependencies.md) — exact require paths, remotes, profile fields.
- [Setup.md](Setup.md) — the install steps.
- [Config.lua](Config.lua) — the consolidated tunables.
