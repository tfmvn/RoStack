# AdminTools — MEMORY

Engineering notes for a future agent. Dense, concrete, no filler.

---

## Purpose, in one line

A rank-based admin allowlist plus 68 Cmdr commands, where **Cmdr's own
group system is decorative** and the real gate is an `AdminService.Assert*`
call as the first statement of every `Run` function.

---

## The one thing that will bite you

**Cmdr 1.12's registration filter receives only the COMMAND OBJECT, never
the calling player.**

```lua
Cmdr.Registry:RegisterCommandsIn(CommandsFolder, function(_command)
    return true   -- accept-all
end)
```

So the filter **cannot** implement per-player authorization. The framework
therefore does the opposite of what you would expect: it registers
**everything** and puts the gate inside `Run`:

```lua
AdminService.AssertAdmin(context.Executor.UserId)              -- 59 commands
AdminService.AssertCanRun(context.Executor.UserId, 'superadmin') -- 6
AdminService.AssertCanRun(context.Executor.UserId, AdminConfig.SuperadminGroup) -- 3
AdminService.AssertCanRun(context.Executor.UserId, 'admin')    -- 1 (/luck)
```

`Group` on the definition is **metadata only** (Cmdr's help output, the
client console's grouping). It grants nothing.

Corollary: `AssertAdmin` **throws** (`error(msg, 2)`), it does not return
`false`. A `Run` that calls it aborts and Cmdr surfaces the error string
in chat. If you want a graceful failure, catch it yourself.

---

## How it actually works, step by step

### Boot

1. `bootstrap.server.lua` does `require(script.Parent.Cmdr.Server.CmdrBootstrap)`.
   Requiring a server script runs it. **There is no `Init()`** — the whole
   registration is a side effect of the require.
2. `CmdrBootstrap` requires Cmdr from `ServerScriptService.Packages.Cmdr`
   (`WaitForChild('Packages')` then `WaitForChild('Cmdr')`).
3. `Cmdr.Registry:RegisterDefaultCommands(function(_) return true end)` —
   registers help / version / credits. They are `Group = 'Default'` and
   intentionally ungated.
4. `Cmdr.Registry:RegisterHook('BeforeRun', function(_) return nil end)`.
   **This is mandatory, not optional.** Cmdr 1.12's dispatcher does
   `Dispatcher:RunHooks("BeforeRun")` and **blocks execution** ("Command
   blocked ... as no BeforeRun hook is configured") while
   `Registry.Hooks.BeforeRun` is empty. The hook must be on **this**
   `Registry` — the same instance the server dispatcher runs against.
   A `Cmdr.BeforeRun =` assignment is a dead table field nothing reads;
   that was the original multiplayer bug. The hook is a **pass-through**:
   it grants nothing, because the per-command `Assert*` is the authority.
5. `Cmdr.Registry:RegisterTypesIn(TypesFolder)` — **before** the commands,
   because the command definitions reference the type names.
6. `Cmdr.Registry:RegisterCommandsIn(CommandsFolder, acceptAll)`.
7. Diagnostics: counts the registered commands, warns if `BeforeRun` is
   empty, and prints `[CmdrBootstrap] registered N commands + 1 BeforeRun
   hook(s) (Studio|Server)`.

### Cmdr relocates the source files — this is the biggest surprise

```lua
-- Registry.lua:153 (RegisterCommand)
commandScript.Parent = self.Cmdr.ReplicatedRoot.Commands
-- Registry.lua:76 (RegisterTypesIn)
object.Parent = self.Cmdr.ReplicatedRoot.Types
```

`ReplicatedRoot` is `ReplicatedStorage.CmdrClient`. So **after the
bootstrap has run**:

- `ServerScriptService.Cmdr.Server.Commands` contains only the 68
  `*Server.lua` halves (they are never moved).
- `ServerScriptService.Cmdr.Server.Types` is **empty**.
- The 68 definition modules and 8 type modules now live in
  `ReplicatedStorage.CmdrClient.Commands` / `.Types`.

This breaks the shipped spec's `custom types exist as modules` case if the
bootstrap ran first. **Run the spec before the bootstrap**, or assert
against `ReplicatedStorage.CmdrClient.Types` instead.

Cmdr's `Initialize.lua` is also what does
`ReplicatedRoot.Parent = ReplicatedStorage` — i.e. **the server's require
of Cmdr is what creates `ReplicatedStorage.CmdrClient`**. The client
bootstrap's `ReplicatedStorage:WaitForChild('CmdrClient')` blocks forever
if the server never required Cmdr.

### A command execution

1. The client console sends the command through Cmdr's `CmdrFunction`
   RemoteFunction.
2. The server dispatcher runs the `BeforeRun` hook → `nil` → proceed.
3. Cmdr resolves each argument through the registered type's
   `Transform` → `Validate` → `Parse`. **This happens on the client too**
   (the type modules were replicated), so the client-side type layer is
   UX; the server re-validates everything through `AdminArgs`.
4. The server calls `commandObject.Run(context, ...args...)`.
5. `Run` gates, rate-limits, resolves the target, re-resolves the
   arguments, does the work, notifies, audits, and returns a **string**
   — which Cmdr prints in chat for the executor.

### `Run`'s canonical shape (from `giveEggServer.lua`)

```lua
return function(context, target, egg, trait, mutations, quantity)
    local AdminService = require(ServerScriptService.Admin.AdminService)
    -- ... 6 more Admin/* requires ...

    AdminService.AssertAdmin(context.Executor.UserId)          -- 1. gate (THROWS)

    local rateOk, rateErr = AdminRateLimit.Check(context.Executor.UserId)
    if not rateOk then
        AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, rateErr)
        return rateErr                                          -- 2. throttle
    end

    local resolved = AdminTargetResolver.Resolve(target, context.Executor)
    if not resolved.ok or resolved.players == nil then
        local err = if resolved.error ~= nil then resolved.error else 'Invalid target.'
        AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, err)
        return err                                              -- 3. target
    end

    local okRarity, rarity = AdminArgs.ResolveRarity(egg)
    if not okRarity then
        AdminAudit.Log(context.Executor.UserId, 'giveegg', { target = target }, false, rarity)
        return rarity                                           -- 4. revalidate
    end
    -- ... same for trait, mutations, quantity ...

    -- 5. do the work
    -- 6. notify ONLY for what actually happened
    -- 7. audit the outcome
    AdminAudit.Log(context.Executor.UserId, 'giveegg', { ... }, delivered > 0 or queued > 0, summary)
    return summary                                              -- 8. return string
end
```

**Rate limit is AFTER the gate**, deliberately: a rejected non-admin must
not consume budget and must not learn the limits exist.

**The notification shows only what was actually applied.** `giveegg`
counts `delivered` and `queued` separately and tells the target
"You received a %s!" only for units that really landed. A queued (full
base) target gets a *different* message ("your storage is full (reward
queued — free a slot!)"). Never a false success.

---

## The public API surface, with signatures

### `AdminConfig` (`ServerScriptService.Admin.AdminConfig`)

Frozen module table. **The nested `Admins` table is NOT frozen** — that
is deliberate, `AddAdmin`/`RemoveAdmin` mutate it in place.

```lua
AdminConfig.Admins: { [userId: number]: { rank: string } }   -- EMPTY in this library copy
AdminConfig.RankOrder = { mod = 1, admin = 2, superadmin = 3 }
AdminConfig.DefaultGroup   = 'Default'
AdminConfig.ModGroup       = 'Mod'
AdminConfig.AdminGroup     = 'Admin'
AdminConfig.SuperadminGroup = 'Superadmin'
```

Two module-load `assert`s: `mod < admin` and `admin < superadmin`.

### `AdminService`

```lua
AdminService.IsAdmin(userId: number): boolean
AdminService.GetRank(userId: number): string?
AdminService.GetRankLevel(userId: number): number        -- 0 = not an admin
AdminService.CanRun(userId: number, requiredRank: string?): boolean
AdminService.AssertCanRun(userId: number, requiredRank: string?)  -- THROWS
AdminService.AssertAdmin(userId: number)                          -- THROWS
AdminService.AddAdmin(userId: number, rank: string): boolean
AdminService.RemoveAdmin(userId: number): boolean
AdminService.ListAdmins(): { { userId: number, rank: string } }
```

`CanRun` semantics, exactly:
- `requiredRank == nil` or `''` or `== 'Default'` → **true** (open to
  everyone).
- `RankOrder[requiredRank]` is `nil` → **false** (deny by default; a
  typo'd rank is never a free pass).
- otherwise `GetRankLevel(userId) >= requiredLevel`.

`AddAdmin` returns `false` for a non-number userId, a negative userId, a
non-string rank, or a rank not in `RankOrder`. It **reuses the existing
entry table** when the userId is already present, so a caller holding a
reference sees the update.

`ListAdmins` sorts by `(RankOrder[rank] or 0)`, then by userId. **Note
the sort is by rank ascending** — mods first, superadmins last.

`AssertAdmin`'s message is exactly `'[Admin] you are not an admin.'`.
`AssertCanRun`'s message is either
`'[Admin] you are rank %q; this command requires rank %q.'` or
`'[Admin] you are not an admin; this command requires rank %q.'`.

### `AdminArgs` — all return `(ok, value | errorString)`

```lua
AdminArgs.ResolveAnimal(raw): (boolean, any, any, any)   -- ok, defId, rarity, def
AdminArgs.ResolveRarity(raw): (boolean, any)              -- ok, rarity
AdminArgs.ResolveTrait(raw): (boolean, any)                -- ok, traitOrNil
AdminArgs.ResolveMutations(raw): (boolean, any)            -- ok, { id } sorted
AdminArgs.ResolveGear(raw): (boolean, any, any)            -- ok, gearId, gear
AdminArgs.ResolveCode(raw): (boolean, any, any)            -- ok, codeId, codeDef
AdminArgs.ResolveAnimalLevel(raw): (boolean, any)
AdminArgs.ResolveArenaLevel(raw): (boolean, any)
AdminArgs.ResolveRebirthIndex(raw): (boolean, any)
AdminArgs.ResolveQuantity(raw, maxQty): (boolean, any)
```

Rules enforced:
- **Trait**: exactly zero or one. `nil`, `''`, `'-'`, `'none'` → `nil`.
  A **comma** in the input is **rejected loudly**, never truncated.
  Case-insensitive on the id.
- **Mutations**: N unique valid ids, possibly zero. `nil`/`''`/`'-'`/`'none'`
  → `{}`. Accepts an **already-parsed array** (the `mutationList` Cmdr
  type returns an array) or raw comma/space-separated text. String input
  strips `[]"` characters, then splits on `[^,%s]+`.
  **Canonicalization happens BEFORE the uniqueness check**, so
  `'frost,Frost'` is reported as a duplicate. The output is
  **`table.sort`ed** (alphabetical), not input order.
- **Animal**: `AnimalConfig.Get(raw)` first (exact); then a
  case-insensitive `defId` scan; then a case-insensitive `displayName`
  scan.
- **Rarity**: `EggConfig.Price[raw]` first (exact); then a
  case-insensitive scan of `RarityConfig.Order`.
- **Gear**: `GearConfig.FindGear(raw)` first; then a case-insensitive
  scan of `GetAll()` matching `Id` **or** `Name`.
- **Code**: `CodesConfig.NormalizeCode(raw)` → `nil` means "Code must be
  non-empty text."; then `FindById`.
- **AnimalLevel**: integer, `1 .. LevelConfig.MaxLevel`.
- **ArenaLevel**: integer, `1 .. ArenaConfig.MaxLevel()` (fallback **50**
  when the config call fails).
- **RebirthIndex**: integer, `0 .. RebirthConfig.MaxConfigured()`
  (fallback **3**).
- **Quantity**: integer, `1 .. maxQty`; `nil` → **1**.

### `AdminTargetResolver`

```lua
export type TargetResult = {
    ok: boolean,
    players: { Player }?,
    scope: string?,    -- 'Single' | 'Server'
    label: string?,
    error: string?,
}

AdminTargetResolver.Resolve(rawText: any, executor: Player?): TargetResult
AdminTargetResolver.Describe(players: { Player }, scope: string?): string
```

Resolution order:
1. Not a string, or empty after trimming → `{ok=false, error='Target must
   be text (me, all, server, or a player name).'}`.
2. `me` (case-insensitive) → the executor. **Requires a live executor**
   (`executor ~= nil and executor.Parent ~= nil`); otherwise
   `{ok=false, error='"me" needs a live executor; use a player name
   instead.'}`. `scope='Single'`.
3. `all` or `server` → **every player in THIS server**. Empty server →
   `{ok=false, error='No players are currently in this server.'}`.
   `scope='Server'`, `label='all players'`. **Never cross-server.**
4. **Exact username** (case-insensitive) → wins over everything.
   `scope='Single'`.
5. **Display name** (case-insensitive): exactly one candidate → that
   player; **two or more → FAILS** with
   `'Ambiguous target "%s" matches %d players (%s); use the exact
   username.'`
6. Nothing → `{ok=false, error='No player "%s" is in this server.'}`.

`Describe` returns `'%d players'` for `scope == 'Server'` or for more than
one player; otherwise the single player's `Name`.

`Players:GetPlayers()` is filtered to players with a non-nil `Parent`.

### `AdminRateLimit`

```lua
AdminRateLimit.Check(userId: number): (boolean, string?)
AdminRateLimit._TestReset()
```

Reads `Security.Admin` **once at module load** into locals
`_windowSeconds = 10`, `_maxPerWindow = 30`, `_minGapSeconds = 0.2`.
Runtime edits to `Security` have **no effect**.

Algorithm:
1. Non-number userId → `(false, 'Rate limiter: invalid caller.')`.
2. Evict stamps older than `windowSeconds` **from the back** (in place).
3. If the newest stamp is younger than `minGapSeconds` → `(false,
   'Slow down: admin commands are rate limited (burst).')`.
4. If `#stamps >= maxPerWindow` → `(false, 'Slow down: admin commands are
   rate limited (%d per %ds).')`.
5. Otherwise push the stamp and return `(true, nil)`.

Uses `os.clock()` — **CPU time, not wall-clock**. A server under heavy
load sees the window stretch out in wall-clock terms.

There is **no punishment and no lockout**. Only the excess execution
fails.

### `AdminAudit`

```lua
AdminAudit.Log(executorUserId: number, command: string, fields: any?, success: boolean, message: string?)
AdminAudit.Recent(count: number?): { string }
```

- Ring buffer of **100** strings. The 101st entry evicts index 1.
- `_sequence` is a monotonic counter for the server session.
- Line format: `#<seq> actor=<uid> command=<cmd> success=<true|false>` and,
  if a message is given, ` :: <message truncated to 160 chars>`.
- The `Debug.Log('ADMIN', 'command', flat)` flat map truncates `result`
  to **180** chars.
- `_flatten` turns table values into `table.concat(v, ',')` and everything
  else into `tostring(v)`. **The map is unordered** — `pairs` order.
- `Recent(count)`: default **10**; `math.min(math.floor(count), 100)`;
  `count < 1` or non-number → 10. **Newest-first.**
- **No persistence.** The buffer dies with the server.

### `AdminNotify`

```lua
AdminNotify.Escape(text: string): string
AdminNotify.Tell(player: Player, text: string)
AdminNotify.TellAll(players: { Player }, textFn: (Player) -> string)
AdminNotify.FormatMoney(amount: string): string
AdminNotify.EggLabel(rarity: string): string
AdminNotify.DescribeEgg(rarity: string, trait: string?, mutations: { string }?): string
AdminNotify.DescribeAnimal(displayName: string, trait: string?, mutations: { string }?, level: number?): string
```

- `Escape` delegates to `RichTextFormatter.Escape` inside a `pcall`;
  falls back to `tostring(text)` if it fails. Player names can contain
  RichText markup, and toasts render RichText — **always escape**.
- `Tell` → `pcall(PlayerService.Notify, player, 'Admin', text)`. Category
  is `'Admin'`. **Never throws.**
- `TellAll` calls `textFn` per player inside a `pcall`; a throwing
  `textFn` skips that player only.
- `FormatMoney` → `'$' .. BigNumber.Format(amount)`; on failure,
  `'$' .. tostring(amount)`.
- `EggLabel(rarity)` → `RarityConfig.RarityDisplayName[rarity]`, or
  `'<rarity> Egg'`.
- `DescribeEgg` → parts joined with `' — '`:
  `['Legendary Egg', trait?, mutations joined with ', ']`.
  e.g. `'Legendary Egg — Gold — Frost, Galactic'`.
- `DescribeAnimal` → parts joined with `' — '`:
  `[displayName, trait?, mutations joined with ', '?, 'Lv.%d'?]`.
  e.g. `'Dragon — Gold — Galactic — Lv.25'`.
  The level part is added when `type(level) == 'number'` — so a level of
  **0** still renders `Lv.0`.

### `AdminDelivery`

```lua
AdminDelivery.GiveEgg(userId: number, rarity: string, trait: string?, mutations: { string }?): { [string]: any }
AdminDelivery.GiveAnimal(userId: number, defId: string, trait: string?, mutations: { string }?, level: number?): { [string]: any }
```

Return shapes — **exactly one of**:
- `{ ok = true, record = <persistence record> }`
- `{ queued = true }` (and `ok = false`, `failed = false`)
- `{ failed = true, error = '<string>' }`

The pipeline (mirrors `CodesService.deliverEgg/deliverAnimal` step for
step):

```text
_services()            -> require Base.SlotService + Codes.CodesService (both pcall)
require EggService / AnimalService  (pcall)
PlayerService.GetPlayerData(userId)  (pcall)  -> 'no profile' on failure
  |
  v
slot = SlotService.GetFreeSlot(userId)
  -> no free slot      -> queuePending()  -> { queued = true }
  |
  v
SlotService.ReserveSlot(slot.id) == true
  -> not reserved      -> queuePending()  -> { queued = true }
  |
  v
before = id-set of the existing records (data.LuckyBlocks / data.Brainrots)
PlayerService.AddEgg/AddAnimal(userId, slot.id, ...)
  -> write failed     -> SlotService.ReleaseSlot(slot.id)
                       -> { failed = true, error = 'persistence write failed' }
  |
  v
record = the NEW record with rec.Id not in `before` AND rec.SlotId == slot.id
  -> not found        -> SlotService.ReleaseSlot(slot.id)
                       -> { failed = true, error = 'record not found after write' }
  |
  v
EggService/AnimalService.SpawnFromPersistence(userId, record, slot)
  -> r.success ~= true -> PlayerService.RemoveEgg/RemoveAnimal(record.Id)
                          SlotService.ReleaseSlot(slot.id)
                          queuePending() -> { queued = true }
  |
  v
PlayerService.PushState(player, BaseService.Snapshot(userId))
  -> { ok = true, record = record }
```

`queuePending()` calls
`CodesService.QueuePendingReward(data, { Code = 'ADMIN', Kind = 'Egg' | 'Animal', ... })`
inside a `pcall` and sets `queued = true`.

**The design rule:** a full base never fails the grant — it **queues** it
through the same pending-reward pipeline every code and daily reward uses.
Spawn failures are rolled back (the record is removed, the slot released)
and then queued the same way. The reward is never silently lost and never
force-placed.

`_findNew` matches on **both** a new `Id` **and** `SlotId == slot.id` —
that is how it identifies the record the write just created.

`AdminDelivery` has **no** `Notify` call — the caller decides what to
tell the target. The module's own doc comment says: "Callers notify ONLY
on ok (success toast) or queued (queued explanation) — never a false
success."

---

## The eight custom Cmdr types

Each module in `Cmdr/Server/Types/` returns `function(cmdr)` and calls
`cmdr:RegisterType(name, { ... })`.

The allowed keys are **exactly** `Transform`, `Validate`, `Autocomplete`,
`Parse`, `DisplayName`, `Listable`, `ValidateOnce`, `Prefixes`,
`Default`, `ArgumentOperatorAliases`. Any other key makes Cmdr's
`RegisterType` **throw**.

The type name must match `^[%d%l]%w*$` — lower-case or digit first.

| Type | Source of truth | Resolve | Validate | Autocomplete | Parse |
|---|---|---|---|---|---|
| `adminTarget` | live players | `Trimmed(text)` | **always true** | `me`/`all`/`server` + live usernames, fuzzy | identity |
| `animalDef` | `AnimalConfig.Catalog` | exact id → display name → `BestMatch` → raw | `AnimalConfig.Get(value) ~= nil` | fuzzy over sorted defIds | identity |
| `arenaOption` | fixed `{Buy1,Buy2,Buy3}` | exact → `BestMatch` → raw | exact match only | fuzzy | identity |
| `codeId` | `CodesConfig` | `NormalizeCode` → trimmed raw | `FindById(value) ~= nil` | fuzzy over normalized ids | identity |
| `eggRarity` | `EggConfig.Price` ∩ `RarityConfig.Order` | exact → `BestMatch` → raw | `EggConfig.Price[value] ~= nil` | fuzzy | identity |
| `gearId` | `GearConfig.GetAll()` | exact id → display name → `BestMatch` → raw | `FindGear(value) ~= nil` | fuzzy | identity |
| `mutationList` | `MutationConfig.Catalog` | `''` for none; exact → `BestMatch` → raw | `''` ok; `MutationConfig.Get(value) ~= nil` | fuzzy | `{}` for `''`, else `{value}` |
| `traitId` | `TraitConfig.Catalog` | `'-'` for none markers; exact → `BestMatch` → raw | `'-'` ok; **comma rejected**; `Get(value) ~= nil` | fuzzy + `'-'` first when empty | `nil` for `'-'`, else the value |

`adminTarget.Validate` **always returns true** — deliberately
permissive. The server-side `AdminTargetResolver` is the gate, and it
produces precise errors ("Ambiguous target ... matches 2 players").

`mutationList` is **`Listable = true`**. Cmdr splits on commas first,
then unions the per-segment `Parse` results. Identical duplicates
collapse in that union — benign, since the outcome is the single
mutation. Unknown ids never reach `Run` (`Validate` rejects them first),
and `AdminArgs.ResolveMutations` re-resolves everything anyway.

`traitId`'s `Autocomplete` inserts `'-'` at position 1 when the input is
empty.

`CmdrTypeUtil` (`ReplicatedStorage.Utility.CmdrTypeUtil`) is the shared
helper: `FuzzyFilter` (case-insensitive **substring**, source order),
`ExactMatch` (case-insensitive equality, returns the canonical entry),
`BestMatch` (exact, then first fuzzy hit), `Trimmed`. Every matcher is
total — it never errors on bad input.

---

## Invariants the code enforces

1. **Every admin command gates before it does anything.** The `Assert*`
   call is the first statement.
2. **The rate limit is after the gate.** A non-admin never consumes
   budget and never learns the limit exists.
3. **Every argument is re-resolved server-side.** The client type layer
   is UX only.
4. **A trait is zero or one.** A comma is an error, not a truncation.
5. **Mutations are unique and canonical.** Canonicalization precedes the
   duplicate check; the output is sorted.
6. **A target is never guessed.** An ambiguous display name fails with a
   candidate list.
7. **`all`/`server` is this server only.**
8. **A grant is never silently lost.** A full base queues; a spawn
   failure rolls back and then queues.
9. **A notification is never a false success.** Notify only after the
   authoritative operation succeeded, and only for what actually
   happened.
10. **Free text is RichText-escaped** before it reaches a toast.
11. **The allowlist is mutated in place**, so a runtime `/addadmin` is
    visible to every subsequent command with no reload.
12. **`RankOrder` is monotonic** (`mod < admin < superadmin`), asserted at
    module load.

---

## Failure and edge-case behaviour

| Situation | Result |
|---|---|
| Non-admin runs an admin command | `AssertAdmin` throws `'[Admin] you are not an admin.'` — Cmdr shows it in chat. |
| Admin of the wrong rank | `AssertCanRun` throws with the rank-vs-required-rank message. |
| Unknown rank name passed to `CanRun` | `false` — **deny by default**. |
| Target is not a string / empty | `{ok=false, error='Target must be text ...'}`. |
| `me` with no live executor | `{ok=false, error='"me" needs a live executor; use a player name instead.'}`. |
| `all` in an empty server | `{ok=false, error='No players are currently in this server.'}`. |
| Two players share a display name | `{ok=false, error='Ambiguous target ... (A, B); use the exact username.'}`. |
| Base is full when granting | `{queued=true}` — the reward is queued, not lost. |
| The persistence write fails | `{failed=true, error='persistence write failed'}` and the slot is released. |
| The record is not found after the write | `{failed=true, error='record not found after write'}` and the slot is released. |
| The spawn fails | The record is removed, the slot released, the reward queued. |
| The rate limit is hit | That one execution returns the "Slow down" string. **No punishment, no lockout.** |
| `/adminlog` with no entries | An empty list. |
| `/adminlog 999` | Clamped to 100. |
| `/adminlog 0` or a negative count | Falls back to 10. |
| `/setlevel`, `/slowmode` | Validate their arguments, log a placeholder line, and return a "is a placeholder" string. **No effect.** |

---

## Gotchas that will bite you

1. **THE `Superadmin` CASE BUG.** `AdminConfig.RankOrder` is keyed
   `mod` / `admin` / `superadmin` (lower case) but
   `AdminConfig.SuperadminGroup` is `'Superadmin'` (capital S).
   `CanRun` does `RankOrder[requiredRank]` **verbatim** → `nil` → **deny
   everyone**.
   `/addadmin`, `/removeadmin` and `/shutdown` all use
   `AdminConfig.SuperadminGroup` and are therefore **permanently
   unusable** — even for a superadmin. The other four superadmin
   commands use the lowercase literal `'superadmin'` and work.
   **Fix before you ship.** `string.lower(requiredRank)` in `CanRun`
   fixes all three at once (and `'Admin'` → `'admin'` also works).
   There is no `/listadmins` command either — `AdminService.ListAdmins`
   exists but no command calls it. **`/addadmin` being broken means a
   fresh install has no way to grant itself an admin at runtime**; you
   must edit `AdminConfig.Admins`.

2. **`/resetcash` is `Group = 'Admin'` but gates at `'superadmin'`.**
   The `Group` is wrong, the gate is right. The gate wins.

3. **`Group` is never the gate.** Don't trust it. Don't write a new
   command that relies on it.

4. **Cmdr moves your files.** After the bootstrap, the `Types` folder is
   empty and `Commands` holds only the `*Server.lua` halves. Tests and
   tooling that look in `ServerScriptService.Cmdr.Server.Types` will find
   nothing.

5. **A throw during registration silently unregisters the rest of the
   folder.** `RegisterCommandObject` errors on an unknown command key or
   an unknown argument property, and `RegisterCommandsIn` has **no
   `pcall`** around `RegisterCommand`. One bad command file and every
   command after it in the folder is gone. The bootstrap's printed count
   is your only signal — check it.

6. **`AssertAdmin` throws, it does not return false.** If you write a
   command that must fail gracefully, wrap it or use `CanRun`.

7. **`AdminConfig.Admins` is not frozen.** `table.freeze(AdminConfig)` is
   shallow. Anything with a reference can mutate the allowlist.

8. **`AdminRateLimit` snapshots `Security.Admin` at module load.**
   Editing `Security` at runtime does nothing. A restart is required.

9. **`os.clock()` is CPU time.** Under load the "10 second window" is
   longer in wall-clock terms.

10. **`ResolveMutations` sorts the output.** `'Galactic,Frost'` comes
    back as `{'Frost','Galactic'}`. Do not assume input order.

11. **`ResolveMutations` canonicalizes before deduping**, so
    `'frost,Frost'` is a **duplicate error**, not a silent collapse.

12. **`ResolveTrait` rejects a comma outright.** There is no
    multi-trait.

13. **`adminTarget` validates nothing.** If you write a command and rely
    on `Validate`, you get `true` for every string.

14. **`AdminDelivery` does not notify.** Forgetting to notify is the
    most likely bug in a new grant command.

15. **`AdminDelivery` requires `Codes.CodesService`** even though it
    only uses `QueuePendingReward`. Without it, `GiveEgg`/`GiveAnimal`
    return `{failed=true, error='delivery services unavailable'}`.

16. **`/fly` is per-character.** Respawning does not re-enable it.

17. **`/forcerebirth` does not bypass requirements.** It runs the
    canonical transaction; the money/arena/animals requirements still
    apply and the failure names the unmet one.

18. **`AdminAudit.Recent` returns strings, not tables.** If you want
    structured audit data you have to parse them, or replace the module.

19. **The audit buffer is 100 entries and is not persisted.** On a busy
    server you lose history.

20. **`AdminNotify.DescribeAnimal` renders `Lv.0`** for a level of 0,
    because it checks `type(level) == 'number'`.

---

## What to change to reuse it

### Keep as-is (Grade A)

`AdminService`, `AdminTargetResolver`, `AdminRateLimit`, `AdminAudit`,
`AdminNotify`, `AdminConfig` (structure), `AdminDelivery` (structure),
`CmdrBootstrap`, the eight types, `CmdrTypeUtil`.

### Replace

| Thing | Replace with |
|---|---|
| `AdminConfig.Admins` | Your own userIds. **Gate the Studio ids yourself.** |
| `AdminArgs`' ten config requires | Your game's canonical configs, keeping the same function names: `Animals.Get`/`.Catalog`, `Eggs.Price`, `Traits.Get`/`.Catalog`, `Mutations.Get`/`.Catalog`, `Rarity.Order`, `Progression.MaxLevel`, `Gear.FindGear`/`GetAll`, `Rewards.Codes.NormalizeCode`/`FindById`/`GetAll`, `Rebirth.MaxConfigured`, `Arena.MaxLevel`. |
| Every `Run` function's game-service calls | Your services. Keep the shape: gate → rate-limit → resolve target → revalidate args → work → notify → audit → return string. |
| `Security.Admin` | Your budget. |
| `PlayerService.Notify` | Your toast channel. `AdminNotify` expects `(player, category, text)`. |

### Fix on the way in

- `CanRun`: lowercase the rank lookup.
- `/resetcash`: change `Group` to `'Superadmin'` (or lower the gate to
  `'admin'` — your call, but pick one and make them agree).
- `/setlevel` and `/slowmode`: either implement them or delete them.

### Do not carry over

- The live allowlist that shipped in the source game (already removed
  here).
- The ungated Studio ids `0` / `1` / `2`.
