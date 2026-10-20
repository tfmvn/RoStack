# AdminTools — API

Every public function of every module in this system. There are **nine**
server modules plus the bootstrap script:

- `ServerScriptService.Admin.AdminConfig` (data only)
- `ServerScriptService.Admin.AdminService`
- `ServerScriptService.Admin.AdminArgs`
- `ServerScriptService.Admin.AdminTargetResolver`
- `ServerScriptService.Admin.AdminRateLimit`
- `ServerScriptService.Admin.AdminAudit`
- `ServerScriptService.Admin.AdminNotify`
- `ServerScriptService.Admin.AdminDelivery`
- `ServerScriptService.Cmdr.Server.CmdrBootstrap` (a script, not a module)

Plus the **eight Cmdr types** in `Cmdr/Server/Types/` and the **68
command pairs** in `Cmdr/Server/Commands/`.

Every module table is `table.freeze`d — you cannot add fields at
runtime. The **nested** `AdminConfig.Admins` table is the one
exception: it stays mutable so `AddAdmin`/`RemoveAdmin` can change it.

**Error convention.** Every `AdminArgs` resolver and every
`AdminTargetResolver.Resolve` returns `(ok, value | errorString)` and
**never throws**. `AdminService.AssertAdmin` and
`AdminService.AssertCanRun` are the two functions that **throw**.

---

## `ServerScriptService.Admin.AdminConfig`

```lua
local AdminConfig = require(game:GetService('ServerScriptService').Admin.AdminConfig)
```

A pure data module. It has **no functions**.

### Fields

```lua
AdminConfig.Admins: { [userId: number]: { rank: string } }
AdminConfig.RankOrder = { mod = 1, admin = 2, superadmin = 3 }
AdminConfig.DefaultGroup   = 'Default'
AdminConfig.ModGroup       = 'Mod'
AdminConfig.AdminGroup     = 'Admin'
AdminConfig.SuperadminGroup = 'Superadmin'
```

`AdminConfig.Admins` is **empty** in this library copy (see the security
note in `README.md`).

**Module-load assertions** (these `error` on load, before any command
can run):

```lua
assert(AdminConfig.RankOrder.mod < AdminConfig.RankOrder.admin,
    'AdminConfig.RankOrder: mod must be < admin')
assert(AdminConfig.RankOrder.admin < AdminConfig.RankOrder.superadmin,
    'AdminConfig.RankOrder: admin must be < superadmin')
```

---

## `ServerScriptService.Admin.AdminService`

```lua
local AdminService = require(game:GetService('ServerScriptService').Admin.AdminService)
```

The permission gate. The single source of truth for "is this userId an
admin, at what rank".

---

### `AdminService.IsAdmin(userId: number): boolean`

True if the userId is in the allowlist with any rank.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The Roblox userId. |

**Returns** `true` / `false`.

**Failure modes** — never throws. A non-number argument returns
`false`.

---

### `AdminService.GetRank(userId: number): string?`

The rank string for the userId.

**Returns** `'mod'` / `'admin'` / `'superadmin'`, or **`nil`** when the
userId is not an admin.

**Failure modes** — never throws. A non-number argument returns `nil`.

---

### `AdminService.GetRankLevel(userId: number): number`

The numeric rank level.

**Returns** `1` (mod) / `2` (admin) / `3` (superadmin), or **`0`** for
a non-admin. A rank present in the allowlist but **missing from
`RankOrder`** also returns `0`.

**Failure modes** — never throws.

---

### `AdminService.CanRun(userId: number, requiredRank: string?): boolean`

Can the userId run a command of `requiredRank`?

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The Roblox userId. |
| `requiredRank` | `string?` | `nil`, `''` or `'Default'` → open to everyone. |

**Returns** `true` / `false`.

**Logic, exactly**

1. `requiredRank` is `nil`, `''` or `AdminConfig.DefaultGroup` →
   **`true`** (no gate).
2. `AdminConfig.RankOrder[requiredRank]` is `nil` → **`false`**.
   **Deny by default** — a typo'd rank name is never a free pass.
3. Otherwise `GetRankLevel(userId) >= requiredLevel`.

**Failure modes** — never throws.

**Gotcha.** The lookup is **verbatim, case-sensitive**. `RankOrder` is
keyed `mod` / `admin` / `superadmin`, so
`CanRun(userId, AdminConfig.SuperadminGroup)` (`'Superadmin'`) is
`false` for **everyone**.

---

### `AdminService.AssertCanRun(userId: number, requiredRank: string?)`

**Throws** if the userId cannot run a command of the given rank. This
is the gate used by the 9 rank-gated commands.

**Parameters** — as `CanRun`.

**Returns** — nothing on success.

**Failure modes** — **`error(msg, 2)`** on failure. The messages:

```
[Admin] you are rank "<yourRank>"; this command requires rank "<requiredRank>".
[Admin] you are not an admin; this command requires rank "<requiredRank>".
```

The message is what Cmdr surfaces in the executor's chat.

---

### `AdminService.AssertAdmin(userId: number)`

**Throws** if the userId is not an admin at all. Used by the 59
commands that do not distinguish ranks.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The Roblox userId. |

**Returns** — nothing on success.

**Failure modes** — **`error('[Admin] you are not an admin.', 2)`**.
Exactly that string, every time. It deliberately does **not** reveal
the required rank.

---

### `AdminService.AddAdmin(userId: number, rank: string): boolean`

Add or update an admin.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | May be **offline**. |
| `rank` | `string` | Must be a key of `RankOrder`. |

**Returns** `true` on success, `false` on invalid input.

**Failure modes** — never throws. Returns `false` when:

- `userId` is not a number;
- `userId < 0`;
- `rank` is not a string;
- `rank` is not in `RankOrder`.

**Behaviour** — mutates `AdminConfig.Admins` **in place**. When the
userId is already present, the **existing entry table is reused** and
its `rank` field is overwritten, so a caller holding a reference sees
the update.

---

### `AdminService.RemoveAdmin(userId: number): boolean`

Remove an admin.

**Returns** `true` if the userId was present and is now gone, `false`
if they were not in the list.

**Failure modes** — never throws. A non-number argument returns `false`.

**Note** — the removal is permanent for the server session; a restart
restores whatever `AdminConfig.lua` says.

---

### `AdminService.ListAdmins(): { { userId: number, rank: string } }`

The allowlist as a sorted array.

**Returns** an array of `{ userId = number, rank = string }`.

**Sorting** — by `RankOrder[rank] or 0` **ascending**, then by userId
ascending. So **mods come first and superadmins last**.

**Failure modes** — never throws. An empty allowlist returns an empty
array.

**Note** — **no command calls this.** The doc comment mentions a
`/listadmins` command; it does not exist in the suite. There is
therefore **no runtime way to see the allowlist** except from a server
console.

---

## `ServerScriptService.Admin.AdminArgs`

```lua
local AdminArgs = require(game:GetService('ServerScriptService').Admin.AdminArgs)
```

Server-side canonical argument resolution. Every resolver re-validates
against the live canonical config, independent of what the client
autocomplete suggested.

**Convention** — every function returns `(ok, value | errorString)`.
**None of them throws.** The error string is surfaced to the admin
verbatim.

---

### `AdminArgs.ResolveAnimal(raw: any): (boolean, any, any, any)`

Resolve an animal definition id.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `raw` | `any` | A defId or a display name. |

**Returns** `(true, defId, rarity, def)` or `(false, errorString)`.

**Resolution order**

1. `AnimalConfig.Get(raw)` — an exact hit → `(true, raw, rarity, def)`.
2. A case-insensitive scan of `AnimalConfig.Catalog` for the **defId**.
3. A case-insensitive scan for the **`displayName`**.
4. Otherwise `(false, 'Unknown animal "<raw>".')`.

**Failure modes** — never throws. A non-string argument returns
`(false, 'Animal must be a definition id (e.g. "Dragon").')`.

---

### `AdminArgs.ResolveRarity(raw: any): (boolean, any)`

Resolve an egg rarity.

**Returns** `(true, rarity)` or `(false, errorString)`.

**Resolution order**

1. `EggConfig.Price[raw]` — an exact hit → `(true, raw)`.
2. A case-insensitive scan of `RarityConfig.Order`.
3. Otherwise `(false, 'Unknown egg rarity "<raw>".')`.

**Failure modes** — never throws. A non-string returns
`(false, 'Egg rarity must be text (e.g. "Legendary").')`.

---

### `AdminArgs.ResolveTrait(raw: any): (boolean, any)`

Resolve a **single** trait.

**Returns** `(true, traitIdOrNil)` or `(false, errorString)`.

**Rules**

- `nil`, `''`, `'-'`, `'none'` (case-insensitive) → `(true, nil)`
  — "no trait".
- A **comma anywhere in the string** → `(false, 'Animals support only
  one trait; pass a single trait, not a list.')`. **Never truncated.**
- `TraitConfig.Get(text)` — an exact hit → `(true, text)`.
- A case-insensitive scan of `TraitConfig.Catalog`.
- Otherwise `(false, 'Invalid trait: "<text>"')`.

**Failure modes** — never throws. A non-string, non-nil argument
returns `(false, 'Trait must be a single trait id (e.g. "Gold") or "-"
for none.')`.

---

### `AdminArgs.ResolveMutations(raw: any): (boolean, any)`

Resolve a **mutation list**.

**Returns** `(true, { id, ... })` or `(false, errorString)`. The output
is **sorted alphabetically** — not in input order.

**Accepted inputs**

| Input | Result |
|---|---|
| `nil` | `(true, {})` |
| A **table** (the parsed `mutationList` Cmdr type) | Each entry must be a string. |
| A **string** | `[]` and `"` are stripped, then it is split on `[^,%s]+` (comma **or** whitespace). |
| `''`, `'-'`, `'none'` (case-insensitive) | `(true, {})` |
| Anything else | `(false, 'Mutations must be a comma-separated list (e.g. "Galactic,Frost") or "-" for none.')` |

**Rules**

- Every id is **canonicalized case-insensitively** against
  `MutationConfig.Catalog`.
- An unknown id → `(false, 'Invalid mutation: "<id>"')`.
- A duplicate → `(false, 'Duplicate mutation: "<canonicalId>"')`.
  **Canonicalization happens BEFORE the duplicate check**, so
  `'frost,Frost'` is a **duplicate error**, not a silent collapse.

**Failure modes** — never throws. A table with a non-string entry
returns `(false, 'Invalid mutation: entry must be text.')`.

---

### `AdminArgs.ResolveGear(raw: any): (boolean, any, any)`

Resolve a gear item.

**Returns** `(true, gearId, gearEntry)` or `(false, errorString)`.

**Resolution order**

1. `GearConfig.FindGear(raw)` → `(true, found.Id, found)`.
2. A case-insensitive scan of `GearConfig.GetAll()` matching the **Id**
   or the **Name**.
3. Otherwise `(false, 'Unknown gear "<raw>".')`.

**Failure modes** — never throws. A non-string returns
`(false, 'Gear must be a gear id or name (e.g. "SilverBat").')`.

---

### `AdminArgs.ResolveCode(raw: any): (boolean, any, any)`

Resolve a redeem code.

**Returns** `(true, codeId, codeDef)` or `(false, errorString)`.

**Behaviour**

1. `CodesConfig.NormalizeCode(raw)` → `nil` means
   `(false, 'Code must be non-empty text.')`.
2. `CodesConfig.FindById(norm)` → `nil` means
   `(false, 'Unknown code "<norm>".')`.
3. Otherwise `(true, norm, def)`. The id is **normalized** (upper
   case in the shipped config).

**Failure modes** — never throws.

---

### `AdminArgs.ResolveAnimalLevel(raw: any): (boolean, any)`

Resolve an animal level.

**Returns** `(true, level)` or `(false, errorString)`.

**Rules** — must be a **whole number** in `1 .. LevelConfig.MaxLevel`
(**100** in the shipped game).

**Failure modes** — never throws.

- Non-number or non-integer →
  `(false, 'Level must be a whole number.')`
- Out of range →
  `(false, 'Level must be between 1 and 100.')`

---

### `AdminArgs.ResolveArenaLevel(raw: any): (boolean, any)`

Resolve an arena stage.

**Returns** `(true, level)` or `(false, errorString)`.

**Rules** — a whole number in `1 .. maxLevel`, where `maxLevel` is
`ArenaConfig.MaxLevel()` called **inside a `pcall`**. If that call
fails, the fallback is **50**.

**Failure modes** — never throws.

- Non-number or non-integer →
  `(false, 'Arena level must be a whole number.')`
- Out of range →
  `(false, 'Arena level must be between 1 and <maxLevel>.')`

---

### `AdminArgs.ResolveRebirthIndex(raw: any): (boolean, any)`

Resolve a rebirth index.

**Returns** `(true, index)` or `(false, errorString)`.

**Rules** — a whole number in `0 .. maxConfigured`, where `maxConfigured`
is `RebirthConfig.MaxConfigured()` called **inside a `pcall`**. If that
call fails, the fallback is **3**. **The range is 0-based** — `0` is the
first rebirth.

**Failure modes** — never throws.

- Non-number or non-integer →
  `(false, 'Rebirth must be a whole number.')`
- Out of range →
  `(false, 'Rebirth must be between 0 and <maxConfigured>.')`

---

### `AdminArgs.ResolveQuantity(raw: any, maxQty: number): (boolean, any)`

Resolve a grant quantity.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `raw` | `any` | `nil` means the default. |
| `maxQty` | `number` | The caller's upper bound. |

**Returns** `(true, quantity)` or `(false, errorString)`.

**Rules** — `raw == nil` → **`1`**. Otherwise a whole number in
`1 .. maxQty`.

**Failure modes** — never throws.

- Non-number or non-integer →
  `(false, 'Quantity must be a whole number.')`
- Out of range →
  `(false, 'Quantity must be between 1 and <maxQty>.')`

**The upper bounds used by the suite**

| Command | `maxQty` |
|---|---|
| `/giveanimal` | **5** |
| `/giveegg` | **10** |
| `/spawnegg` | **10** (its own bound, not `ResolveQuantity`) |

---

## `ServerScriptService.Admin.AdminTargetResolver`

```lua
local AdminTargetResolver = require(game:GetService('ServerScriptService').Admin.AdminTargetResolver)
```

The single centralized player-target resolver.

---

### `AdminTargetResolver.TargetResult` (type)

```lua
export type TargetResult = {
    ok: boolean,
    players: { Player }?,
    scope: string?,    -- 'Single' | 'Server'
    label: string?,
    error: string?,
}
```

---

### `AdminTargetResolver.Resolve(rawText: any, executor: Player?): TargetResult`

Resolve raw target text against the **current** live player list.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `rawText` | `any` | `me` / `all` / `server` / a username / a display name. Surrounding quotes are already stripped by Cmdr. |
| `executor` | `Player?` | The player running the command. Required for `me`. |

**Returns** a `TargetResult`.

**Resolution order**

| Input | Result |
|---|---|
| Not a string | `{ok=false, error='Target must be text (me, all, server, or a player name).'}` |
| Empty after trimming | The same error. |
| `me` (case-insensitive), live executor | `{ok=true, players={executor}, scope='Single', label=executor.Name}` |
| `me`, no live executor | `{ok=false, error='"me" needs a live executor; use a player name instead.'}` |
| `all` / `server` (case-insensitive), ≥1 player | `{ok=true, players={...every player...}, scope='Server', label='all players'}` |
| `all` / `server`, empty server | `{ok=false, error='No players are currently in this server.'}` |
| Exact **username** (case-insensitive) | `{ok=true, players={p}, scope='Single', label=p.Name}` |
| Exactly one **display-name** match | `{ok=true, players={p}, scope='Single', label=p.Name}` |
| **Two or more** display-name matches | `{ok=false, error='Ambiguous target "<text>" matches <N> players (<names>); use the exact username.'}` |
| No match | `{ok=false, error='No player "<text>" is in this server.'}` |

**Failure modes** — never throws.

**Invariants**

- An exact username match **always wins** over a display-name match.
- An ambiguous display name **never** silently picks a player.
- `all` / `server` **never** cross servers. There is no
  `MessagingService` fan-out in this framework.
- Only players with a non-nil `Parent` are considered.

---

### `AdminTargetResolver.Describe(players: { Player }, scope: string?): string`

A human-readable aggregate label for an admin confirmation.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `players` | `{ Player }` | The resolved players. |
| `scope` | `string?` | `'Server'` or nil. |

**Returns**

- `scope == 'Server'` → `'<N> players'`
- exactly one player → `'<Name>'`
- more than one player → `'<N> players'`

**Failure modes** — never throws.

---

## `ServerScriptService.Admin.AdminRateLimit`

```lua
local AdminRateLimit = require(game:GetService('ServerScriptService').Admin.AdminRateLimit)
```

A per-admin sliding-window throttle.

**Budget** — read from `Security.Admin` **once at module load**:
`WindowSeconds = 10`, `MaxPerWindow = 30`, `MinGapSeconds = 0.2`.

---

### `AdminRateLimit.Check(userId: number): (boolean, string?)`

May this execution proceed?

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The admin's userId. |

**Returns** `(true, nil)` to proceed, or `(false, message)` to drop.

**Algorithm**

1. A non-number userId → `(false, 'Rate limiter: invalid caller.')`.
2. Evict stamps older than `windowSeconds`, from the back, in place.
3. If the newest stamp is younger than `minGapSeconds` →
   `(false, 'Slow down: admin commands are rate limited (burst).')`.
4. If `#stamps >= maxPerWindow` →
   `(false, 'Slow down: admin commands are rate limited (30 per 10s).')`.
5. Otherwise push the stamp and return `(true, nil)`.

**Failure modes** — never throws.

**Notes**

- Uses **`os.clock()`** — CPU time, not wall-clock. Under load the
  "10 second window" stretches out in wall-clock terms.
- **No punishment and no lockout.** Only the excess execution fails.
- Call it **after** the permission gate: a rejected non-admin must not
  consume budget and must not learn the limits exist.

---

### `AdminRateLimit._TestReset()`

Clear all rate-limit state.

**Parameters / Returns** — none.

**Side effect** — `table.clear(_stamps)`.

---

## `ServerScriptService.Admin.AdminAudit`

```lua
local AdminAudit = require(game:GetService('ServerScriptService').Admin.AdminAudit)
```

Two sinks: a permanent `Debug.Log` trail and an in-memory ring buffer.

---

### `AdminAudit.Log(executorUserId: number, command: string, fields: any?, success: boolean, message: string?)`

Record one execution.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `executorUserId` | `number` | The admin's userId. |
| `command` | `string` | The command name, e.g. `'giveegg'`. |
| `fields` | `any?` | A flat map of extra fields. Tables are joined with `','`. |
| `success` | `boolean` | The outcome. |
| `message` | `string?` | The summary. Truncated. |

**Returns** — nothing.

**Behaviour**

- Increments a **monotonic** `_sequence` (never resets for the server
  session).
- `_flatten(fields)` converts every value to a string; a table value
  becomes `table.concat(v, ',')`. The map is **unordered** (`pairs`).
- `result` is truncated to **180** characters in the `Debug.Log` flat
  map.
- `pcall(Debug.Log, 'ADMIN', 'command', flat)` — the debug sink never
  throws.
- The ring-buffer line is
  `'#<seq> actor=<uid> command=<cmd> success=<true|false>'`, plus
  `' :: <message>'` when a message is given, with the message truncated
  to **160** characters.
- The buffer is capped at **100** entries; the 101st evicts the first.

**Failure modes** — never throws. A missing or non-table `fields` is
treated as an empty map.

---

### `AdminAudit.Recent(count: number?): { string }`

The newest entries.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `count` | `number?` | Default **10**. |

**Returns** an array of **strings**, **newest first**.

**Rules**

- `count` is not a number, or `< 1` → the default **10**.
- Otherwise `math.min(math.floor(count), 100)` — the maximum is the
  buffer size.
- An empty buffer returns an empty array.

**Failure modes** — never throws.

**Notes** — the entries are **strings**, not structured records. There
is no persistence: the buffer dies with the server.

---

## `ServerScriptService.Admin.AdminNotify`

```lua
local AdminNotify = require(game:GetService('ServerScriptService').Admin.AdminNotify)
```

The one place admin commands build player-facing text and deliver target
notifications.

**Channel policy**

- Target notifications go through `PlayerService.Notify` with category
  **`'Admin'`** — the same server→client toast every gameplay system
  uses.
- Admin confirmations are the **Cmdr `Run` return string**, shown to the
  executor in chat.
- `/announce` uses category **`'System'`**.
- **Private admin rewards never use the announcement path.**

---

### `AdminNotify.Escape(text: string): string`

RichText-escape a string.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `text` | `string` | Any free text, e.g. a player name. |

**Returns** the escaped string.

**Failure modes** — never throws. If `RichTextFormatter.Escape` errors
(the call is inside a `pcall`), it falls back to `tostring(text)`.

**Why it matters** — player names can contain RichText markup and toasts
render RichText. **Always escape** anything that came from a player.

---

### `AdminNotify.Tell(player: Player, text: string)`

Send a private admin toast to one player.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `player` | `Player` | The recipient. |
| `text` | `string` | **Already escaped by the caller.** |

**Returns** — nothing.

**Behaviour** — `pcall(PlayerService.Notify, player, 'Admin', text)`.

**Failure modes** — never throws. A missing player or a broken
`PlayerService.Notify` is swallowed silently.

**Rule** — notify **only after** the authoritative operation succeeded,
and **only for what actually happened**. Never a false success.

---

### `AdminNotify.TellAll(players: { Player }, textFn: (Player) -> string)`

Send a private admin toast to many players, with a per-player message.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `players` | `{ Player }` | The recipients. |
| `textFn` | `(Player) -> string` | Builds that player's personal message. |

**Returns** — nothing.

**Behaviour** — for each player, `textFn(player)` is called inside a
`pcall`; if it returns a string, `AdminNotify.Tell(player, text)` runs.

**Failure modes** — never throws. A `textFn` that throws skips that
one player; the others still get their message.

---

### `AdminNotify.FormatMoney(amount: string): string`

Format a BigNumber money string for display.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `amount` | `string` | A canonical BigNumber string. |

**Returns** `'$' .. BigNumber.Format(amount)`.

**Failure modes** — never throws. If `BigNumber.Format` errors or
returns an empty string, the fallback is `'$' .. tostring(amount)`.

**Example** — `FormatMoney('100000')` → `'$100,000'` (the exact
separators come from `BigNumber.Format`).

---

### `AdminNotify.EggLabel(rarity: string): string`

The display label for an egg rarity.

**Returns** `RarityConfig.RarityDisplayName[rarity]`, or
`'<rarity> Egg'` when the rarity is not in the display table.

**Failure modes** — never throws.

---

### `AdminNotify.DescribeEgg(rarity: string, trait: string?, mutations: { string }?): string`

A human-readable egg description.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `rarity` | `string` | The rarity id. |
| `trait` | `string?` | The hidden trait. Omitted when `nil` or `''`. |
| `mutations` | `{ string }?` | The mutations. Omitted when `nil` or empty. |

**Returns** the parts joined with `' — '`:

```text
<label>
<label> — <trait>
<label> — <mutations joined with ', '>
<label> — <trait> — <mutations joined with ', '>
```

**Examples**

```lua
DescribeEgg('Legendary')                        --> 'Legendary Egg'
DescribeEgg('Legendary', 'Gold')                --> 'Legendary Egg — Gold'
DescribeEgg('Legendary', nil, {'Frost','Galactic'})
    --> 'Legendary Egg — Frost, Galactic'
DescribeEgg('Legendary', 'Gold', {'Frost','Galactic'})
    --> 'Legendary Egg — Gold — Frost, Galactic'
```

**Failure modes** — never throws.

---

### `AdminNotify.DescribeAnimal(displayName: string, trait: string?, mutations: { string }?, level: number?): string`

A human-readable animal description.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `displayName` | `string` | The animal's display name. |
| `trait` | `string?` | Omitted when `nil` or `''`. |
| `mutations` | `{ string }?` | Omitted when `nil` or empty. |
| `level` | `number?` | Omitted when `nil`. |

**Returns** the parts joined with `' — '`:

```text
<displayName>
<displayName> — <trait>
<displayName> — <mutations joined with ', '>
<displayName> — <trait> — <mutations joined with ', '>
<displayName> — <trait> — <mutations joined with ', '> — Lv.<level>
```

**Examples**

```lua
DescribeAnimal('Dragon')                        --> 'Dragon'
DescribeAnimal('Dragon', 'Gold')                --> 'Dragon — Gold'
DescribeAnimal('Dragon', nil, {'Galactic'})     --> 'Dragon — Galactic'
DescribeAnimal('Dragon', 'Gold', {'Galactic'}, 25)
    --> 'Dragon — Gold — Galactic — Lv.25'
```

**Failure modes** — never throws.

**Gotcha** — the level part is added when `type(level) == 'number'`, so
a level of **0** still renders `Lv.0`.

---

## `ServerScriptService.Admin.AdminDelivery`

```lua
local AdminDelivery = require(game:GetService('ServerScriptService').Admin.AdminDelivery)
```

The **one** admin path for granting slot-bound items.

---

### `AdminDelivery.GiveEgg(userId: number, rarity: string, trait: string?, mutations: { string }?): { [string]: any }`

Grant one egg.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The recipient. |
| `rarity` | `string` | The egg rarity. |
| `trait` | `string?` | The hidden trait. |
| `mutations` | `{ string }?` | The mutations. |

**Returns** — exactly one of three shapes:

| Shape | Meaning |
|---|---|
| `{ ok = true, record = <persistence record> }` | The egg was written **and** spawned. |
| `{ queued = true }` | The base is full, or the spawn failed. The reward is queued for later. `ok` and `failed` are `false`. |
| `{ failed = true, error = '<string>' }` | Something went wrong. `ok` and `queued` are `false`. |

**The pipeline**

```text
_services()  ->  require Base.SlotService + Codes.CodesService  (both pcall)
                 -> nil  => { failed = true, error = 'delivery services unavailable' }

require EggService  (pcall)
                 -> nil  => { failed = true, error = 'egg service unavailable' }

PlayerService.GetPlayerData(userId)  (pcall)
                 -> not a table  => { failed = true, error = 'no profile' }

slot = SlotService.GetFreeSlot(userId)  (pcall)
                 -> no free slot  => queuePending()  => { queued = true }

SlotService.ReserveSlot(slot.id) == true  (pcall)
                 -> not reserved  => queuePending()  => { queued = true }

before = the set of existing record Ids in data.LuckyBlocks
PlayerService.AddEgg(userId, slot.id, rarity, nil, { Mutations = mutations, Trait = trait })
                 -> not true  => SlotService.ReleaseSlot(slot.id)
                              => { failed = true, error = 'persistence write failed' }

record = the record whose Id is NOT in `before` AND whose SlotId == slot.id
                 -> not found  => SlotService.ReleaseSlot(slot.id)
                              => { failed = true, error = 'record not found after write' }

EggService.SpawnFromPersistence(userId, record, slot)  (pcall)
                 -> r.success ~= true
                      => PlayerService.RemoveEgg(record.Id)
                         SlotService.ReleaseSlot(slot.id)
                         queuePending()  => { queued = true }

PlayerService.PushState(player, BaseService.Snapshot(userId))  (pcall)
                 => { ok = true, record = record }
```

**`queuePending()`** calls
`CodesService.QueuePendingReward(data, { Code = 'ADMIN', Kind = 'Egg', Rarity = rarity })`
inside a `pcall`, then sets `queued = true`.

**Failure modes** — never throws. Every external call is `pcall`-guarded
and every failure maps to one of the three return shapes.

**Invariants**

- A full base **never** fails the grant — it **queues** it through the
  same pending-reward pipeline every code and daily reward uses.
- A spawn failure **rolls back** (the record is removed, the slot
  released) and then queues the same way.
- The reward is **never silently lost** and **never force-placed**.
- **`AdminDelivery` does not notify.** The caller decides what to tell
  the target. Notify only on `ok` (a success toast) or `queued` (a
  queued explanation).

---

### `AdminDelivery.GiveAnimal(userId: number, defId: string, trait: string?, mutations: { string }?, level: number?): { [string]: any }`

Grant one animal.

**Parameters**

| Name | Type | Notes |
|---|---|---|
| `userId` | `number` | The recipient. |
| `defId` | `string` | The animal definition id. |
| `trait` | `string?` | The hidden trait. |
| `mutations` | `{ string }?` | The mutations. |
| `level` | `number?` | The starting level. **Defaults to 1.** |

**Returns** — the same three shapes as `GiveEgg`.

**The pipeline** is identical, with these differences:

| Step | `GiveEgg` | `GiveAnimal` |
|---|---|---|
| Service | `EggService` | `AnimalService` |
| Profile list | `data.LuckyBlocks` | `data.Brainrots` |
| Write | `PlayerService.AddEgg(userId, slot.id, rarity, nil, { Mutations, Trait })` | `PlayerService.AddAnimal(userId, slot.id, defId, nil, { Level = level or 1, Trait, Mutations })` |
| Spawn | `EggService.SpawnFromPersistence(userId, record, slot)` | `AnimalService.SpawnFromPersistence(userId, record, slot)` |
| Rollback | `PlayerService.RemoveEgg(record.Id)` | `PlayerService.RemoveAnimal(record.Id)` |
| Queue payload | `{ Code = 'ADMIN', Kind = 'Egg', Rarity = rarity }` | `{ Code = 'ADMIN', Kind = 'Animal', DefId = defId, Trait = trait, Level = level or 1 }` |

**Failure modes** — never throws. The error strings are
`'delivery services unavailable'`, `'animal service unavailable'`,
`'no profile'`, `'persistence write failed'`, and
`'record not found after write'`.

---

## `ServerScriptService.Cmdr.Server.CmdrBootstrap`

This is a **server Script**, not a ModuleScript. There is no `Init()`
and no exported table — **requiring it IS the registration**.

```lua
-- bootstrap.server.lua
require(script.Parent.Cmdr.Server.CmdrBootstrap)
```

### What it does, in order

1. `local Packages = ServerScriptService:WaitForChild('Packages')` then
   `local Cmdr = require(Packages:WaitForChild('Cmdr'))`.
2. `Cmdr.Registry:RegisterDefaultCommands(function(_) return true end)` —
   registers help / version / credits for everyone.
3. `Cmdr.Registry:RegisterHook('BeforeRun', function(_) return nil end)` —
   the **mandatory** pass-through hook.
4. `Cmdr.Registry:RegisterTypesIn(TypesFolder)` — the 8 custom types.
5. `Cmdr.Registry:RegisterCommandsIn(CommandsFolder, function(_) return true end)` —
   the 68 commands.
6. Counts the registered commands and the `BeforeRun` hooks; **warns**
   if the hook count is 0; prints the diagnostic line.

### The `BeforeRun` hook is not optional

Cmdr 1.12's dispatcher runs `Dispatcher:RunHooks("BeforeRun")` and
**blocks execution** ("Command blocked ... as no BeforeRun hook is
configured") while `Registry.Hooks.BeforeRun` is empty. The hook must
be registered on **this** `Registry` — the same instance the server
dispatcher runs against. A `Cmdr.BeforeRun =` assignment is a dead
table field nothing reads; that was the original multiplayer bug.

The hook returns `nil`, so it **grants nothing**. The per-command
`AdminService.Assert*` call remains the only authorization authority.

### The filter is accept-all

Both the type filter and the command filter return `true` for
everything. Cmdr's filter receives **only the command object**, never
the calling player, so it cannot implement per-player authorization.
The gate is inside each `Run`.

### Diagnostic output

```text
[CmdrBootstrap] registered 71 commands + 1 BeforeRun hook(s) (Studio)
[CmdrBootstrap] registered 71 commands + 1 BeforeRun hook(s) (Server)
```

**71** = 68 admin commands + 3 Cmdr built-ins.

**A lower count means a command module threw during registration.**
`Registry:RegisterCommandsIn` has **no `pcall`** around
`RegisterCommand`, so one bad command file skips every command after it
in the folder. The count is the only signal you get.

### Side effect: the source files move

`Registry:RegisterTypesIn` and `Registry:RegisterCommand` **re-parent**
the ModuleScripts:

```lua
object.Parent = self.Cmdr.ReplicatedRoot.Types
commandScript.Parent = self.Cmdr.ReplicatedRoot.Commands
```

`ReplicatedRoot` is `ReplicatedStorage.CmdrClient`. So after the
bootstrap:

- `ServerScriptService.Cmdr.Server.Types` is **empty**;
- `ServerScriptService.Cmdr.Server.Commands` holds only the `*Server.lua`
  halves;
- the definitions and types live in `ReplicatedStorage.CmdrClient`.

---

## The eight Cmdr types

Each module in `Cmdr/Server/Types/` returns `function(cmdr)` and calls
`cmdr:RegisterType(name, { ... })`.

The **allowed keys** are exactly: `Transform`, `Validate`,
`Autocomplete`, `Parse`, `DisplayName`, `Listable`, `ValidateOnce`,
`Prefixes`, `Default`, `ArgumentOperatorAliases`. Any other key makes
Cmdr's `RegisterType` **throw**.

The type **name** must match `^[%d%l]%w*$` — lower-case or digit
first.

| Type | `Transform` | `Validate` | `Autocomplete` | `Parse` |
|---|---|---|---|---|
| `adminTarget` | `Trimmed(text)` | **always `true`** | `me`/`all`/`server` + live usernames, fuzzy | identity |
| `animalDef` | exact id → display name → `BestMatch` → raw | `AnimalConfig.Get(value) ~= nil` | fuzzy over the sorted defIds | identity |
| `arenaOption` | exact → `BestMatch` → raw | exact match only | fuzzy over `{Buy1,Buy2,Buy3}` | identity |
| `codeId` | `NormalizeCode` → trimmed raw | `FindById(value) ~= nil` | fuzzy over the normalized ids | identity |
| `eggRarity` | exact → `BestMatch` → raw | `EggConfig.Price[value] ~= nil` | fuzzy | identity |
| `gearId` | exact id → display name → `BestMatch` → raw | `FindGear(value) ~= nil` | fuzzy | identity |
| `mutationList` | `''` for none; exact → `BestMatch` → raw | `''` ok; `MutationConfig.Get(value) ~= nil` | fuzzy | `{}` for `''`, else `{value}` |
| `traitId` | `'-'` for none markers; exact → `BestMatch` → raw | `'-'` ok; **comma rejected**; `Get(value) ~= nil` | fuzzy + `'-'` first when empty | `nil` for `'-'`, else the value |

**Notes**

- `adminTarget.Validate` **always returns true** — deliberately. The
  server-side `AdminTargetResolver` is the gate and produces the
  precise errors.
- `mutationList` is **`Listable = true`**. Cmdr splits on commas first,
  then unions the per-segment `Parse` results. Identical duplicates
  collapse in that union — benign, since the outcome is the single
  mutation. Unknown ids never reach `Run`.
- `traitId` rejects a comma with
  `'Animals support only one trait; pass a single trait, not a list.'`
- `traitId`'s `Autocomplete` inserts `'-'` at position 1 when the input
  is empty.

### The shared helper — `ReplicatedStorage.Utility.CmdrTypeUtil`

Not part of this system, but every type depends on it.

```lua
CmdrTypeUtil.FuzzyFilter(candidates: { string }, needle: any): { string }
CmdrTypeUtil.ExactMatch(candidates: { string }, text: any): string?
CmdrTypeUtil.BestMatch(candidates: { string }, text: any): string?
CmdrTypeUtil.Trimmed(text: any): string
```

| Function | Behaviour |
|---|---|
| `FuzzyFilter` | Case-insensitive **substring** match, **source order preserved**. An empty needle matches everything. A non-table candidate list returns `{}`. |
| `ExactMatch` | Case-insensitive equality; returns the **canonical** entry, or `nil`. |
| `BestMatch` | `ExactMatch` first; otherwise the **first** fuzzy hit; otherwise `nil`. |
| `Trimmed` | Strips leading and trailing whitespace. A non-string returns `''`. |

**Every matcher is total** — it never errors on bad input.

---

## The 68 commands

The command **definitions** (`<name>.lua`) are plain tables with these
keys:

```lua
{
    Name = 'giveegg',                    -- string, required
    Aliases = { 'ge', 'addegg' },        -- optional
    Description = '...',                 -- string, required
    Group = 'Admin',                     -- 'Admin' | 'Superadmin' | 'Default'
    Args = {
        { Type = 'adminTarget', Name = 'target', Description = '...' },
        { Type = 'number', Name = 'amount', Description = '...', Optional = true },
    },
}
```

The allowed definition keys are exactly Cmdr's `CommandMethods`:
`Name`, `Aliases`, `AutoExec`, `Description`, `Args`, `Run`,
`ClientRun`, `Data`, `Group`. An unknown key **throws** during
registration.

The allowed argument property keys are exactly: `Name`, `Type`,
`Description`, `Optional`, `Default`.

The command **name** is the lowercase form (`'giveegg'`), even though
the file is camelCase (`giveEgg.lua`). The `Run` file must be named
`<definition file name>Server.lua` in the same folder — Cmdr pairs them
by filename, and a definition with no `Server` counterpart gets a `nil`
`Run`.

### The `Run` function

```lua
return function(context, <arg1>, <arg2>, ...)
```

| Name | Type | Notes |
|---|---|---|
| `context` | `table` | Cmdr's context. `context.Executor` is the calling `Player`; `context.Executor.UserId` is the admin's userId. |

**Returns** — a **string** shown to the executor in chat. Returning
`nil` shows nothing.

**Failure modes** — a `Run` that calls `AssertAdmin` / `AssertCanRun`
**throws**; Cmdr surfaces the error message in chat. Everything else
returns a failure string.

### The full command list

| Command | Aliases | Group | Arguments | What it does | Gate |
|---|---|---|---|---|---|
| `addadmin` | — | Superadmin | `userId:number`, `rank:string` | Adds or updates an admin by userId at `mod`/`admin`/`superadmin`. The userId may be offline. | `AssertCanRun(…, 'Superadmin')` — **BROKEN**, see below |
| `adminlog` | — | Admin | `count:number?` | Shows the newest audit entries. Default 10, max 100. | `AssertAdmin` |
| `announce` | — | Admin | `message:string` | Broadcasts a server-wide toast. Category forced to `System`. | `AssertAdmin` |
| `arenainfo` | — | Admin | `target:adminTarget` | Read-only: arena level, XP, wins, highest completed stage, whether a raid is active. | `AssertAdmin` |
| `baseinfo` | — | Admin | `target:adminTarget` | Read-only: base id, lock state + remaining lock time, slot occupancy. | `AssertAdmin` |
| `bring` | — | Admin | `player:player` | Teleports the target to the executor's position. | `AssertAdmin` |
| `cancelarena` | — | Admin | `target:adminTarget` | Ends the target's active expedition via `ArenaService.CancelArena`. Cleared stages still pay. | `AssertAdmin` |
| `cancelcarry` | — | Admin | `target:adminTarget` | Returns a carried animal/egg to its slot — the same dispatch as death/disconnect recovery. | `AssertAdmin` |
| `cancelsteal` | — | Superadmin | `target:adminTarget` | Rolls back an in-progress steal via `StealService.RollbackCarried`. | `AssertCanRun(…, 'superadmin')` |
| `carryinfo` | — | Admin | `target:adminTarget` | Read-only: what the target carries, of which kind, and whether a steal is in progress. | `AssertAdmin` |
| `clearmoneymultiplier` | — | Admin | `target:adminTarget` | Removes the `AdminOverride` money modifier via `ModifierService.RemoveModifier`. | `AssertAdmin` |
| `codeinfo` | — | Admin | `code:codeId` | Read-only: one code's enabled flag, expiry, caps and full reward table. | `AssertAdmin` |
| `dailyclaim` | — | Admin | `target:adminTarget`, `day:number` | Claims a daily streak day (1-7) **for** the target through `DailyRewardsService.Claim`. There is no streak setter — it claims, never edits. | `AssertAdmin` |
| `dailyinfo` | — | Admin | `target:adminTarget` | Read-only: current streak day, claimable day, per-day states. | `AssertAdmin` |
| `deliverpending` | — | Admin | `target:adminTarget` | Retries queued code/admin rewards via `CodesService.TryDeliverPending`. | `AssertAdmin` |
| `eggstatus` | — | Admin | — | Read-only: center-egg count vs cap, per-state counts, Legendary/Mythic guarantee state. | `AssertAdmin` |
| `event` | — | Admin | `action:string`, `eventId:string?` | `status` / `start <Galaxy\|Snowfall>` / `stop` — delegates to `EventService`. | `AssertAdmin` |
| `fly` | — | Admin | — | Toggles flight for the executor (BodyPosition + BodyGyro on the HRP). **Per-character**: respawning does not re-enable it. | `AssertAdmin` |
| `forcerebirth` | — | Admin | `target:adminTarget` | Runs the canonical `RebirthService.RequestRebirth`. **Requirements are not bypassed** — grant money/animals first; a failure names the unmet requirement. | `AssertAdmin` |
| `getplayerstats` | `gps` | Admin | `player:player` | Prints money, base and inventory for one player. | `AssertAdmin` |
| `getstats` | — | Admin | `player:player`, `animalId:string` | Shows an animal's Level/XP and derived Health/Damage through `AnimalService.GetStats`. | `AssertAdmin` |
| `giveallgear` | — | Admin | `target:adminTarget` | Grants every gear-shop entry, one at a time. | `AssertAdmin` |
| `giveanimal` | `ga`, `addanimal` | Admin | `target:adminTarget`, `animal:animalDef`, `trait:traitId?`, `mutations:mutationList?`, `level:number?`, `quantity:number?` | Grants animals into the targets' bases through the canonical slot-reserve pipeline. Level defaults to 1, quantity to 1 (max 5). | `AssertAdmin` |
| `givearenawin` | — | Admin | `target:adminTarget`, `level:number` | Records an arena stage clear. | `AssertAdmin` |
| `givearenaxp` | — | Admin | `target:adminTarget`, `amount:number` | Grants arena XP. | `AssertAdmin` |
| `givecash` | `addcash` | Admin | `target:adminTarget`, `amount:string` | **Adds** money (BigNumber string). | `AssertAdmin` |
| `giveegg` | `ge`, `addegg` | Admin | `target:adminTarget`, `egg:eggRarity`, `trait:traitId?`, `mutations:mutationList?`, `quantity:number?` | Grants eggs. Quantity defaults to 1, max 10. | `AssertAdmin` |
| `givegear` | — | Admin | `target:adminTarget`, `gear:gearId` | Grants one gear tool. | `AssertAdmin` |
| `givemoney` | — | Admin | `player:player`, `amount:string` | Adds money to one player (native `player` type, not `adminTarget`). | `AssertAdmin` |
| `givexp` | — | Admin | `player:player`, `animalId:string`, `amount:integer` | Adds XP to an animal. | `AssertAdmin` |
| `killcenteregg` | `kcb` | Admin | `uniqueId:string` | Destroys a center egg by its unique id. | `AssertAdmin` |
| `listanimals` | — | Admin | `target:adminTarget` | Read-only: a player's animals. | `AssertAdmin` |
| `listcentereggs` | `lcb` | Admin | — | Lists all active center eggs. | `AssertAdmin` |
| `listcodes` | — | Admin | — | Lists the redeem-code catalog. | `AssertAdmin` |
| `listgear` | — | Admin | `target:adminTarget` | Read-only: gear ownership. | `AssertAdmin` |
| `listplayers` | `lp` | Admin | — | Lists the players in this server. | `AssertAdmin` |
| `lockbase` | — | Admin | `target:adminTarget` | Locks the target's base. | `AssertAdmin` |
| `luck` | — | Admin | `value:string?` | Shows or sets server-wide egg luck. A multiplier, `reset`, or omitted to show. | `AssertCanRun(…, 'admin')` |
| `playtimeclaim` | — | Admin | `target:adminTarget`, `milestone:number` | Claims a playtime milestone for the target. | `AssertAdmin` |
| `playtimeinfo` | — | Admin | `target:adminTarget` | Read-only: playtime reward state. | `AssertAdmin` |
| `ragdoll` | — | Admin | `target:adminTarget`, `duration:number?` | Ragdolls the target. Duration 1-30 s, default 5. | `AssertAdmin` |
| `rebirthinfo` | — | Admin | `target:adminTarget` | Read-only: rebirth progress. | `AssertAdmin` |
| `redeemcode` | — | Admin | `target:adminTarget`, `code:codeId` | Redeems a code for the targets. | `AssertAdmin` |
| `removeadmin` | — | Superadmin | `userId:number` | Removes an admin. | `AssertCanRun(…, 'Superadmin')` — **BROKEN** |
| `removeanimal` | — | Superadmin | `target:adminTarget`, `animalId:string` | **Permanently deletes** a live animal (the `BR_` unique id). | `AssertCanRun(…, 'superadmin')` |
| `removeegg` | — | Superadmin | `target:adminTarget`, `eggId:string` | **Permanently deletes** a placed egg (the `EG_` unique id). | `AssertCanRun(…, 'superadmin')` |
| `resetarena` | — | Superadmin | `target:adminTarget` | Resets arena progression to level 1. | `AssertCanRun(…, 'superadmin')` |
| `resetcash` | — | Admin | `target:adminTarget` | Resets money to the starting value. | `AssertCanRun(…, 'superadmin')` — **the `Admin` group is wrong** |
| `resetplayer` | — | Admin | `player:player` | Full data reset. An alias of `/wipeplayer`. | `AssertAdmin` |
| `sellanimal` | — | Admin | `target:adminTarget`, `animalId:string` | Force-sells a live animal at the canonical price. | `AssertAdmin` |
| `setanimallevel` | — | Admin | `target:adminTarget`, `animalId:string`, `level:number` | Sets a live animal's level (1-100). | `AssertAdmin` |
| `setcash` | — | Admin | `target:adminTarget`, `amount:string` | **Sets** money to an absolute value. | `AssertAdmin` |
| `setlevel` | — | Admin | `player:player`, `rarity:string`, `level:number` | **Placeholder — no-op.** Would set a rarity's level once the per-defId level system exists. | `AssertAdmin` |
| `setmoney` | — | Admin | `player:player`, `amount:string` | Sets money to a value. | `AssertAdmin` |
| `setmoneymultiplier` | — | Admin | `target:adminTarget`, `value:number` | Sets the money multiplier (0.01-100). | `AssertAdmin` |
| `shutdown` | — | Superadmin | `reason:string` | Shuts the server down. | `AssertCanRun(…, 'Superadmin')` — **BROKEN** |
| `slowmode` | — | Admin | `seconds:number` | **Placeholder — no-op.** Would set chat slowmode once a chat service is wired. | `AssertAdmin` |
| `spawnegg` | `slb` | Admin | `rarity:string`, `mutations:string?`, `trait:string?`, `count:number?` | Spawns eggs at the center. Count defaults to 1, max 10. | `AssertAdmin` |
| `speed` | — | Admin | `value:number` | Sets the executor's `WalkSpeed` (0-200). | `AssertAdmin` |
| `standinfo` | — | Admin | `target:adminTarget` | Read-only: stand counts. | `AssertAdmin` |
| `startarena` | — | Admin | `target:adminTarget`, `option:arenaOption?` | Starts an arena expedition. Option `Buy1`/`Buy2`/`Buy3`, default `Buy3`. | `AssertAdmin` |
| `takecash` | `removecash` | Admin | `target:adminTarget`, `amount:string` | **Removes** money. | `AssertAdmin` |
| `tptobase` | `tpb` | Admin | `player:player` | Teleports the executor to a player's base. | `AssertAdmin` |
| `tell` | — | Admin | `target:adminTarget`, `message:string` | Sends a private admin message (max 240 characters). | `AssertAdmin` |
| `tp` | — | Admin | `from:player`, `to:player` | Teleports player1 to player2. | `AssertAdmin` |
| `unlockbase` | — | Admin | `target:adminTarget` | Unlocks the target's base. | `AssertAdmin` |
| `unragdoll` | — | Admin | `target:adminTarget` | Stands a ragdolled player back up. | `AssertAdmin` |
| `wipeplayer` | — | Admin | `player:player` | Wipes a player's data to defaults. | `AssertAdmin` |

### The `Superadmin` case bug

`AdminConfig.RankOrder` is keyed `mod` / `admin` / `superadmin` (lower
case). `AdminConfig.SuperadminGroup` is `'Superadmin'` (capital S).
`AdminService.CanRun` looks the required rank up **verbatim**, so
`RankOrder['Superadmin']` is `nil` → **deny**.

**`/addadmin`, `/removeadmin` and `/shutdown` therefore deny everyone,
including superadmins.** The four commands that use the lowercase
literal `'superadmin'` (`/cancelsteal`, `/removeanimal`, `/removeegg`,
`/resetarena`) work correctly, as does `/luck` (`'admin'`).

The one-line fix in `AdminService.CanRun`:

```lua
local requiredLevel = AdminConfig.RankOrder[string.lower(requiredRank)]
```

### Rate-limit and audit coverage

**45** commands call both `AdminRateLimit.Check` (after the gate) and
`AdminAudit.Log` (on success **and** on every failure path).

**23** call **neither**:

`addadmin`, `announce`, `bring`, `event`, `fly`, `getplayerstats`,
`getstats`, `givemoney`, `givexp`, `killcenteregg`, `listcentereggs`,
`listplayers`, `removeadmin`, `resetplayer`, `setlevel`, `setmoney`,
`shutdown`, `slowmode`, `spawnegg`, `speed`, `tptobase`, `tp`,
`wipeplayer`.

### Placeholders

`setlevel` and `slowmode` validate their arguments, write a
`Debug.Log('CMDR', '<name> (no-op placeholder)', ...)` line and return
a string saying they are placeholders. **Neither has any effect.**
`setlevel` also caps the level at `Progression.AdminLevelCap` (**99**);
`slowmode` accepts `0..60` seconds.

### The `Run` return string

Every `Run` returns a **string** for the executor's chat. The
multi-target commands vary the wording by the number of resolved
players and by the outcome:

```text
'Gave 1 x Legendary Egg to Bob.'                              -- single, all delivered
'Bob has no free egg storage; reward queued as pending.'       -- single, queued
'Gave 0 of 1 Legendary Egg to Bob. Failed: Bob (delivery failed)'
'Granted Legendary Egg to 3 players (2 delivered, 1 queued).'  -- multi
```
