# CodesAndRewards — API

Every public function of every module in the system.

Six modules:

| Module | Roblox path |
|---|---|
| `Rewards` | `ReplicatedStorage.Config.Economy.Rewards` (config) |
| `CodesService` | `ServerScriptService.Codes.CodesService` |
| `DailyRewardsService` | `ServerScriptService.Daily.DailyRewardsService` |
| `DailyRewardsWeek` | `ServerScriptService.Daily.DailyRewardsWeek` |
| `PlaytimeRewardsService` | `ServerScriptService.Playtime.PlaytimeRewardsService` |
| `PlaytimeRewardsDay` | `ServerScriptService.Playtime.PlaytimeRewardsDay` |

**General failure policy.** The three services are **non-throwing**: every
public entry point wraps its body in `pcall` and converts a thrown error
into a failure result table. No call site needs its own `pcall`. The
config module is pure and never throws. The two global selectors
(`DailyRewardsWeek`, `PlaytimeRewardsDay`) are **also** non-throwing: they
`pcall`-guard their DataStore calls and degrade to a deterministic
fallback rather than raising.

**Result table shape.** Every claim/redemption returns
`{ [string]: any }`:

| Key | Type | Present |
|---|---|---|
| `Success` | `boolean` | always |
| `Reason` | `string` | always — `'unknown-code'`, `'disabled'`, `'expired'`, `'no-systems'`, `'already-redeemed'`, `'invalid-config'`, `'grant-failed'`, `'busy'`, `'not-ready'`, `'already-claimed'`, `'internal'`, `'no-access'` |
| `Message` | `string?` | when the notification catalog supplies one |
| `RewardText` | `string?` | on success |
| `Day` | `number?` | Daily success |
| `Index` | `number?` | Playtime success |
| `ClaimedDays` / `ClaimedCount` | `number?` | skip-all success |
| `Complete` | `boolean?` | Daily skip-all success |
| `State` | `table?` | the post-claim snapshot |

---

## `Rewards` (config)

`require(ReplicatedStorage.Config.Economy.Rewards)`

Returns a frozen table `{ Codes, Daily, Playtime }`.

### `Rewards.Codes`

#### `Codes.NormalizeCode(input: any): string?`

Canonical code normalization. **Pure.**

- **Parameters:** `input` — the raw string the client typed.
- **Returns:** the trimmed, upper-cased string; or `nil` when `input` is
  not a string, or is empty/whitespace-only.
- **Failure modes:** never throws. Returns `nil` for invalid input.
- **Notes:** `'welcome'`, `' WELCOME '` and `'Welcome'` all normalize to
  `'WELCOME'`. The raw string is never stored.

#### `Codes.GetAll(): { CodeDef }`

The whole catalog.

- **Returns:** the live `CODES` array (the same table, not a copy).
- **Failure modes:** none.

#### `Codes.FindById(id: string): CodeDef?`

Looks up one catalog entry.

- **Parameters:** `id` — the **normalized** id (upper-case).
- **Returns:** the entry, or `nil` if there is no such id or `id` is not
  a string.
- **Failure modes:** never throws.
- **Notes:** linear scan; the catalog is small.

#### `Codes.ValidateRewards(rewards: any): { string }`

Validates one reward table against the shared reward shape. **Pure.**

- **Parameters:** `rewards` — a `{ Cash?, Eggs?, Tools?, Animals? }` table.
- **Returns:** an array of human-readable issue strings. **Empty array =
  valid.** Never `nil`.
- **Failure modes:** never throws; a non-table input yields issues.
- **Notes:** the same function validates code rewards, daily-day rewards
  and playtime-milestone rewards. It checks:
  - at least one category present,
  - `Cash` is a decimal **string** (a number is an issue),
  - each `Eggs` entry has a `Rarity` that exists in `Eggs.Price` and a
    positive integer `Amount`,
  - each `Tools` entry has an `Id` that exists in `Gear.FindGear` and a
    positive integer `Amount`,
  - each `Animals` entry has a `DefId` that exists in `Animals.Get`, an
    optional `Trait` that exists in `Traits.Get`, an optional `Level`
    that is a positive integer, and a positive integer `Amount`,
  - `Eggs` + `Animals` unit count does not exceed
    `MAX_SLOT_UNITS_PER_CODE` (10).

#### `Codes.ValidateList(codes: any): { string }`

Validates a whole catalog.

- **Parameters:** `codes` — the catalog array.
- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** checks each entry's shape, that ids are unique, that
  normalized codes do not collide, and that each entry's `Rewards` pass
  `Codes.ValidateRewards`.

#### `Codes.ValidateLive(): { string }`

Live validation of the real catalog. Called at server boot and again
from `CodesService.Init()`.

- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** identical to `Codes.Validate()` — both call
  `Codes.ValidateList(CODES)`.

#### `Codes.Validate(): { string }`

The `ConfigValidator` entry point.

- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** the central validator registers this as the domain
  `Economy.Rewards.Codes`.

### `Rewards.Daily`

#### `Daily.Settings`

`{ ClaimInterval: number }` — default `86400` (24 h). See `Config.lua`.

#### `Daily.WeeklyPools`

The pool catalog: `Pool_A`, `Pool_B`, `Pool_C`, each with exactly
7 contiguous days.

#### `Daily.DayCount(): number`

- **Returns:** `7` — the exact number of days in every daily pool.
- **Failure modes:** none. It is a module-local constant (`DAYS_PER_POOL`),
  not derived from the data.

#### `Daily.FindPool(pools: any, poolId: string): DailyPoolDef?`

- **Parameters:** `pools` — a pool array; `poolId` — the pool id.
- **Returns:** the pool table, or `nil` if `pools` is not a table,
  `poolId` is not a string, or no pool matches.
- **Failure modes:** never throws.

#### `Daily.ValidateList(pools: any, settings: any): { string }`

- **Parameters:** `pools` — the pool array; `settings` — the settings
  table.
- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** requires that every pool has exactly `DAYS_PER_POOL` days
  with contiguous keys `1..N`, that every day's rewards pass
  `Codes.ValidateRewards`, that pool ids are unique, and that
  `settings.ClaimInterval > 0`.

#### `Daily.ValidateLive(): { string }` / `Daily.Validate(): { string }`

Both call `Daily.ValidateList(Daily.WeeklyPools, Daily.Settings)`.

- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** `Validate()` is the `ConfigValidator` entry point for the
  domain `Economy.Rewards.Daily`.

### `Rewards.Playtime`

#### `Playtime.Settings`

`{ SessionResetsOnLeave = true, DailyResetTimezone = 'Asia/Kolkata',
DailyResetHour = 0, DailyResetMinute = 0, SkipAllEnabled = false,
DayBoundaryOffsetSeconds = 19800 }`. See `Config.lua`.

#### `Playtime.Pools`

`Pool_A`, `Pool_B`, `Pool_C` — three courses of 6 cumulative-playtime
milestones each.

#### `Playtime.MilestoneCount(): number`

- **Returns:** the milestone count of the **first** pool (6).
- **Failure modes:** never throws. Returns `0` if `Pools` is not a
  table, is empty, or its first entry has no `Milestones` array.
- **Notes:** the validator requires every other pool to have the same
  count.

#### `Playtime.FindPool(pools: any, poolId: string): PlaytimePoolDef?`

- **Returns:** the pool, or `nil` on a type mismatch / no match.
- **Failure modes:** never throws.

#### `Playtime.ValidateList(pools: any, settings: any): { string }`

- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.
- **Notes:** requires `SessionResetsOnLeave == true` (it is a rule
  statement, not a toggle), a non-empty timezone label, hour `0..23`,
  minute `0..59`, `DayBoundaryOffsetSeconds` in `0..86399`, all pools
  sharing the same milestone count, strictly ascending
  `RequiredPlaytime` within each pool, and every milestone's rewards
  passing `Codes.ValidateRewards`.

#### `Playtime.ValidateLive(): { string }` / `Playtime.Validate(): { string }`

Both call `Playtime.ValidateList(Playtime.Pools, Playtime.Settings)`.

- **Returns:** an array of issue strings; empty = valid.
- **Failure modes:** never throws.

---

## `CodesService`

`require(ServerScriptService.Codes.CodesService)`

### `CodesService.SetPlayerService(svc: any): ()`

- **Parameters:** `svc` — an object with `GetPlayerData(userId): table?`.
  `nil` unsets.
- **Returns:** nothing.
- **Failure modes:** never throws. If unset, every redeem returns
  `no-systems` and nothing is granted.

### `CodesService.SetEconomyService(svc: any): ()`

- **Parameters:** `svc` — an object with
  `GetMoney(userId): string` and
  `AddMoney(userId, amount, source, opts): { Success, NewMoney }`.
- **Returns:** nothing.
- **Failure modes:** never throws. If unset, cash rewards fail with
  `no-systems`.

### `CodesService.SetSlotService(svc: any): ()`

- **Parameters:** `svc` — an object with `GetFreeSlot(userId)` and
  `ReserveSlot(slotId): boolean` / `ReleaseSlot(slotId)`.
- **Returns:** nothing.
- **Failure modes:** never throws. If unset, egg/animal rewards are
  queued as pending rather than granted (and `Redeem` returns
  `no-systems` when the code actually contains egg/animal rewards).

### `CodesService.SetEggService(svc: any): ()`

- **Parameters:** `svc` — `EggService`, with
  `SpawnFromPersistence(userId, record, slot)`.
- **Returns:** nothing.
- **Failure modes:** never throws.

### `CodesService.SetAnimalService(svc: any): ()`

- **Parameters:** `svc` — `AnimalService`, with
  `SpawnFromPersistence(userId, record, slot)`.
- **Returns:** nothing.
- **Failure modes:** never throws.

### `CodesService.SetGearShopService(svc: any): ()`

- **Parameters:** `svc` — `GearShopService`, with
  `EnsureGearTool(player, gearId): boolean`.
- **Returns:** nothing.
- **Failure modes:** never throws. If unset, a code with tool rewards
  returns `no-systems`.

### `CodesService.NormalizePlayer(userId: number): ()`

Repairs the Codes profile slice in place.

- **Parameters:** `userId` — the player's UserId.
- **Returns:** nothing.
- **Failure modes:** never throws (the whole body is `pcall`-wrapped).
- **Side effects:** ensures `data.RedeemedCodes` is a table and
  `data.PendingCodeRewards` is a table; drops malformed pending entries
  (logging each drop) and keeps well-formed ones verbatim — including
  entries that cannot be delivered *right now*.
- **Notes:** it never deletes progress, only malformed rows.

### `CodesService.Redeem(player: Player, codeText: any): { [string]: any }`

The **one** authoritative redemption path.

- **Parameters:** `player` — the redeeming player; `codeText` — the raw
  string.
- **Returns:** the result table. On success `{ Success = true,
  RewardText = ' $2.5K, +1 Rare Egg' }` (note the leading space, which
  the notification template expects).
- **Failure modes:** never throws. A thrown error inside the
  transaction becomes `{ Success = false, Reason = 'internal' }` plus a
  `General_Generic` warning. The result is **also** pushed to
  `CodesResult` and the `Notify` channel.
- **Failure ladder** (first match wins):
  | Order | Condition | `Reason` | Notification id |
  |---|---|---|---|
  | 1 | `NormalizeCode` returns `nil` | `unknown-code` | `Codes_InvalidCode` |
  | 2 | the same player already has this code locked | `busy` | `General_Cooldown` |
  | 3 | the code is not in the catalog | `unknown-code` | `Codes_InvalidCode` |
  | 4 | `def.Enabled ~= true` | `disabled` | `Codes_CodeDisabled` |
  | 5 | `def.ExpiresAt` is a number and `os.time() >= ExpiresAt` | `expired` | `Codes_CodeExpired` |
  | 6 | services unwired or the profile is unavailable | `no-systems` | `General_Generic` |
  | 7 | `data.RedeemedCodes[norm] >= def.MaxPerPlayer` | `already-redeemed` | `Codes_AlreadyRedeemed` |
  | 8 | the per-server global counter is at the cap | `disabled` | `Codes_CodeDisabled` |
  | 9 | the reward config does not validate | `invalid-config` | `General_Generic` |
  | 10 | the reward needs a service that is unwired | `no-systems` | `General_Generic` |
  | 11 | a tool grant failed | `grant-failed` | `General_Generic` |
  | 12 | a cash grant failed | `grant-failed` | `General_Generic` |
  | — | an unexpected error | `internal` | `General_Generic` |
- **Notes:**
  - The lock key is `tostring(userId) .. '\0' .. norm` and is set
    **synchronously before any yield**, so a double-click cannot race.
  - The lock is **per code**, not per player: redeeming two *different*
    codes concurrently is allowed.
  - The expiry check uses **server** `os.time()` only.
  - `MaxGlobalRedemptions` is a **per-server in-memory** counter. It
    resets on restart and is not shared across servers.

### `CodesService.RedeemInner(player: Player, userId: number, norm: string): { [string]: any }`

The inner transaction. Public only so a spec can call it directly.

- **Parameters:** `player`; `userId`; `norm` — the **already normalized**
  code id.
- **Returns:** the result table, as above.
- **Failure modes:** never throws by itself (it is `pcall`-wrapped by
  `Redeem`, but calling it directly lets an error propagate).
- **Notes:** the commit order is **tools → cash → slot rewards → mark
  redeemed**. See `MEMORY.md` for why.

### `CodesService.TryDeliverPending(userId: number): boolean`

Drains the pending queue, delivering as many queued rewards as the
player's free base slots allow.

- **Parameters:** `userId`.
- **Returns:** `true` if at least one queued reward was delivered,
  `false` otherwise.
- **Failure modes:** never throws. Returns `false` when `userId` is not
  a number, or when a delivery is already in progress for that user
  (re-entrancy guard via `delivering[userId]`).
- **Side effects:** rewrites `data.PendingCodeRewards` to the entries
  that could **not** be delivered. Malformed entries are dropped.
  On success it sends a `Codes_PendingDelivered` notification listing
  what landed.
- **Notes:** the player must still be in the server (it resolves the
  `Player`); a queued reward for a departed player stays queued.

### `CodesService.DeliverEggReward(userId, data, codeLabel, rarity): { [string]: boolean }`

Shared delivery entry point (also used by the Daily and Playtime
services).

- **Parameters:** `userId`; `data` — the live profile table; `codeLabel`
  — a human label stored with a pending entry; `rarity` — the egg rarity.
- **Returns:** `{ ok = boolean, queued = boolean, failed = boolean }`.
  - `ok` — the egg was persisted and spawned.
  - `queued` — no free slot right now; the caller should persist it as
    pending.
  - `failed` — a required service is missing or an unexpected error
    occurred; the caller should also persist it as pending (a retry is
    always safe).
- **Failure modes:** never throws.

### `CodesService.DeliverAnimalReward(userId, data, codeLabel, defId, trait, level): { [string]: boolean }`

Same contract as `DeliverEggReward`, for animals.

- **Parameters:** `userId`; `data`; `codeLabel`; `defId`; `trait` (may be
  `nil`); `level` (may be `nil`).
- **Returns:** `{ ok, queued, failed }`.
- **Failure modes:** never throws.

### `CodesService.QueuePendingReward(data: any, entry: { [string]: any }): ()`

Appends a pending entry to the profile queue.

- **Parameters:** `data` — the profile table; `entry` — a
  `{ Code, Kind = 'Egg' | 'Animal', Rarity? | DefId?, Trait?, Level? }`
  table.
- **Returns:** nothing.
- **Failure modes:** never throws. Creates `PendingCodeRewards` if it
  is missing.
- **Notes:** the entry is **not** sanitized here — the caller is
  trusted. `TryDeliverPending` sanitizes on read.

### `CodesService.OnPlayerReady(player: Player): ()`

The join hook.

- **Parameters:** `player`.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Side effects:** calls `NormalizePlayer(player.UserId)` then
  `TryDeliverPending(player.UserId)`.
- **Notes:** the bootstrap calls this **after** base restore and offline
  earnings, so a reward that was queued before the player left is
  delivered against the final inventory.

### `CodesService.ForgetPlayer(userId: number): ()`

Clears session state for a departing player.

- **Parameters:** `userId`.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Side effects:** removes every lock whose key starts with
  `tostring(userId) .. '\0'`, and clears `delivering[userId]`. It does
  **not** touch the profile — queued rewards survive the leave.

### `CodesService.Init(): ()`

Bootstraps the service.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws. Idempotent — a second call is a
  no-op (`started` guard).
- **Side effects:** logs every `CodesConfig.ValidateLive()` issue as a
  **warning** (never an error), then connects the `CodesAction` remote
  handler. If the remote is missing, it logs
  `[Codes] Action remote wiring failed: ...` and the service simply
  never receives redemptions.

### `CodesService._TestReset(): ()`

Clears the locks and the `delivering` guard.

- **Failure modes:** never throws. It does **not** reset `started` or
  the `globalCounts` table.

---

## `DailyRewardsService`

`require(ServerScriptService.Daily.DailyRewardsService)`

### `DailyRewardsService.SetPlayerService(svc: any): ()`
### `DailyRewardsService.SetEconomyService(svc: any): ()`
### `DailyRewardsService.SetGearShopService(svc: any): ()`
### `DailyRewardsService.SetCodesService(svc: any): ()`

Service injection.

- **Parameters:** the service object, or `nil` to unset.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Notes:** `SetCodesService` **must** be called before `Init()` and
  before any claim — the grant path uses it to deliver eggs and animals
  and to queue pending rewards.

### `DailyRewardsService.GetSnapshot(userId: number, nowOverride: number?): { [string]: any }?`

The authoritative state snapshot.

- **Parameters:** `userId`; `nowOverride` — an optional unix timestamp
  (used by specs to simulate time).
- **Returns:**
  `{ WeekId, PoolId, Day, ClaimableDay?, CanClaim, NextClaimAt,
  LastClaimAt, DayCount, Days: [{ Day, State, Cash?, Eggs?, Tools?,
  Animals? }] }`, or **`nil`** when the profile is unavailable or the
  global week has no valid pool.
- **Failure modes:** never throws.
- **Notes:**
  - `Day` is the **next** day to claim (1..7) or `8` for "week
    complete".
  - `Days[].State` is `'Claimable'`, `'Claimed'` or `'Locked'`.
  - A `Claimed` day is one with `d < slice.Day`.
  - The snapshot **mutates** the profile: `sliceOf` heals the slice and
    `ensureWeek` resets it when the global week changed.

### `DailyRewardsService.PushState(player: Player): ()`

Pushes the snapshot to the client.

- **Parameters:** `player`.
- **Returns:** nothing.
- **Failure modes:** never throws. If `GetSnapshot` returns `nil`,
  **nothing is pushed** (the client keeps its last state).
- **Notes:** the payload goes to `DailyRewardsState`.

### `DailyRewardsService.Claim(player: Player, clickedDay: any): { [string]: any }`

The authoritative single-day claim.

- **Parameters:** `player`; `clickedDay` — the card the player pressed
  (may be `nil`).
- **Returns:** the result table. On success
  `{ Success = true, Day = n, RewardText = ' ...', State = snapshot }`.
- **Failure modes:** never throws. A thrown error becomes
  `{ Success = false, Reason = 'internal' }` + a `General_Generic`
  warning.
- **Failure ladder:**
  | Condition | `Reason` | Notification id |
  |---|---|---|
  | a claim for this player is already locked | `busy` | `General_Cooldown` |
  | services unwired / profile unavailable | `no-systems` | `General_Generic` |
  | the global week has no valid pool | `invalid-config` | `General_Generic` |
  | the clicked day is `< slice.Day` (already claimed) | `already-claimed` | `Daily_AlreadyClaimed` |
  | the 24 h window has not elapsed | `not-ready` | `Daily_NotReady` |
  | the clicked day is not the server-computed claimable day | `not-ready` | `Daily_NotReady` |
  | the pool or the day's rewards do not validate | `invalid-config` | `General_Generic` |
  | a tool grant failed | `grant-failed` | `General_Generic` |
  | a cash grant failed | `grant-failed` | `General_Generic` |
  | an unexpected error | `internal` | `General_Generic` |
- **Notes:**
  - `clickedDay` is **validated but never trusted** — the server
    recomputes the claimable day and rejects a mismatch. A forged
    "Day 7" grants nothing extra.
  - The lock is **per player**, not per day: two different days
    cannot be claimed concurrently.
  - **Day 8 is never claimable.** A completed week stays complete until
    the next global week, no matter how much time passes.
  - The result is also pushed to `DailyRewardsResult` and `Notify`.

### `DailyRewardsService.ClaimInner(player: Player, userId: number, clickedDay: any): { [string]: any }`

The inner transaction. Public for specs.

- **Failure modes:** does not `pcall` itself — an error propagates to
  the caller. `Claim` wraps it.

### `DailyRewardsService.ClaimAll(player: Player): { [string]: any }`

The paid "skip all" sweep.

- **Parameters:** `player`.
- **Returns:** on success
  `{ Success = true, ClaimedDays = n, Complete = boolean,
  RewardText = 'Skipped n day(s). ...', State = snapshot }`.
- **Failure modes:** never throws. Errors become `Reason = 'internal'`.
- **Failure ladder:**
  | Condition | `Reason` | Notification id |
  |---|---|---|
  | **no skip entitlement** | `no-access` | `Shop_SkipRequired` |
  | a claim for this player is already locked | `busy` | `General_Cooldown` |
  | services unwired / profile unavailable | `no-systems` | `General_Generic` |
  | the global week has no valid pool | `invalid-config` | `General_Generic` |
  | a day or the pool does not validate | the pass **stops** early but the call still succeeds | — |
  | an unexpected error | `internal` | `General_Generic` |
- **Notes:**
  - **Entitlement is required.** `_skipAccess[userId]` must be `true`,
    which only `GrantSkipAccess` sets.
  - The sweep grants through the **same** `commitDayRewards` a single
    claim uses — there is no duplicated reward logic.
  - **Idempotent**: a day that cannot grant stops the pass; already
    granted days stay granted, so a retry continues instead of
    duplicating.
  - A fully-claimed week succeeds with `ClaimedDays = 0`.
  - It composes **one** summary toast and **one** state push instead of
    seven.

### `DailyRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }`

The inner sweep. Public for specs.

### `DailyRewardsService.ForgetPlayer(userId: number): ()`

Clears the lock and the skip entitlement for a departing player.

- **Failure modes:** never throws.
- **Notes:** the streak itself lives on the profile and survives.

### `DailyRewardsService.GrantSkipAccess(player: any): boolean`

Grants the paid skip-all entitlement.

- **Parameters:** `player` — anything with a numeric `UserId` (a real
  `Player` or a table fake).
- **Returns:** `true` when the entitlement was granted, `false` when
  `player` has no numeric `UserId`.
- **Failure modes:** never throws.
- **Notes:**
  - **Idempotent.**
  - **Session state** — it is cleared on leave by `ForgetPlayer`.
  - Call this **only** from the Shop receipt path, after Roblox has
    confirmed payment.

### `DailyRewardsService.Init(): ()`

- **Failure modes:** never throws. Idempotent.
- **Side effects:** logs every `DailyRewardsConfig.ValidateLive()` issue
  as a warning, then connects the `DailyRewardsAction` remote.

### `DailyRewardsService._TestReset(): ()`

Clears the locks, the skip entitlements, `lastBroadcastWeekId`, and
calls `DailyRewardsWeek._TestReset()`.

- **Failure modes:** never throws. Does not reset `started`.

---

## `PlaytimeRewardsService`

`require(ServerScriptService.Playtime.PlaytimeRewardsService)`

### `PlaytimeRewardsService.SetPlayerService(svc: any): ()`
### `PlaytimeRewardsService.SetEconomyService(svc: any): ()`
### `PlaytimeRewardsService.SetGearShopService(svc: any): ()`
### `PlaytimeRewardsService.SetCodesService(svc: any): ()`

Service injection — same contract as the Daily service.

- **Failure modes:** never throws.

### `PlaytimeRewardsService.GetSnapshot(userId: number): { [string]: any }?`

The authoritative state snapshot.

- **Parameters:** `userId`.
- **Returns:**
  `{ PoolId, DayId, Playtime, SessionStart, Completed, ClaimedCount,
  Version, Rewards: [{ Index, RequiredPlaytime, State, Remaining,
  Cash?, Eggs?, Tools?, Animals? }] }`, or **`nil`** when the profile is
  unavailable, the session cannot be resolved, or the pool is invalid.
- **Failure modes:** never throws.
- **Notes:**
  - `Playtime` is `math.floor(os.clock() - session.start)` — the
    **session** clock, not a persisted total.
  - `Remaining` is whole seconds until the milestone unlocks.
  - `Version` is `math.floor(os.clock() * 1000)` — a client-side
    ordering guard.
  - `Rewards[].State` is `'Claimed'`, `'Claimable'` or `'Locked'`.
  - It **resolves the session lazily** and may therefore create one
    (and mutate the profile).

### `PlaytimeRewardsService.PushState(player: Player): ()`

Pushes the snapshot to `PlaytimeRewardsState`.

- **Failure modes:** never throws. Nothing is pushed when the snapshot
  is `nil`.

### `PlaytimeRewardsService.PushStateById(userId: number): ()`

Pushes to the player with that UserId, if they are in the server.

- **Failure modes:** never throws. Silently does nothing when the
  player is absent.

### `PlaytimeRewardsService.OnPlayerReady(player: Player): ()`

The join hook.

- **Parameters:** `player`.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Side effects:** resolves (or starts) the session and **arms the
  single-shot threshold pushes** — one `task.delay` per unclaimed
  milestone, each guarded by the session token, so a stale session never
  pushes.

### `PlaytimeRewardsService.Claim(player: Player, index: any): { [string]: any }`

The authoritative milestone claim.

- **Parameters:** `player`; `index` — the milestone the player pressed
  (may be `nil`).
- **Returns:** on success `{ Success = true, Index = n, RewardText = ' ...',
  State = snapshot }`.
- **Failure modes:** never throws. Errors become `Reason = 'internal'`.
- **Failure ladder:**
  | Condition | `Reason` | Notification id |
  |---|---|---|
  | a claim for this player is already locked | `busy` | `General_Cooldown` |
  | services unwired / profile unavailable | `no-systems` | `General_Generic` |
  | the session cannot be resolved | `no-systems` | `General_Generic` |
  | the pool is missing or empty | `invalid-config` | `General_Generic` |
  | `index` is not an integer in `1..#milestones` | `not-ready` | `Playtime_NotReady` |
  | the milestone's rewards do not validate | `invalid-config` | `General_Generic` |
  | the milestone is already claimed | `already-claimed` | `Playtime_AlreadyClaimed` |
  | the session playtime is below `RequiredPlaytime` | `not-ready` | `Playtime_NotReady` |
  | a tool grant failed | `grant-failed` | `General_Generic` |
  | a cash grant failed | `grant-failed` | `General_Generic` |
  | an unexpected error | `internal` | `General_Generic` |
- **Notes:**
  - `index` is **validated but never trusted** — the threshold, the
    claimed set, the pool and the rewards all recompute server-side.
  - The lock is **per player**.
  - Claiming a milestone **never** resets the session clock and never
    touches its siblings.

### `PlaytimeRewardsService.ClaimInner(player: Player, userId: number, index: any): { [string]: any }`

The inner transaction. Public for specs.

### `PlaytimeRewardsService.ClaimAll(player: Player): { [string]: any }`

The paid "skip all" sweep over the current session's milestones.

- **Parameters:** `player`.
- **Returns:** on success
  `{ Success = true, ClaimedCount = n, RewardText = '...', State = snapshot }`.
- **Failure modes:** never throws.
- **Failure ladder:** identical shape to the Daily `ClaimAll` —
  `no-access` (no entitlement) / `busy` / `no-systems` / `internal`.
  A milestone that cannot grant **stops the pass** but the call still
  succeeds.
- **Notes:** grants through the same `commitMilestone` a single claim
  uses; one summary toast and one state push; idempotent on retry.

### `PlaytimeRewardsService.ClaimAllInner(player: Player, userId: number): { [string]: any }`

The inner sweep. Public for specs.

### `PlaytimeRewardsService.ForgetPlayer(userId: number): ()`

Clears the session, the lock, and the skip entitlement for a departing
player.

- **Failure modes:** never throws.
- **Note:** this function is **defined twice** in the source file (once
  at ~line 477, once at ~line 723). The later definition wins. The
  effective behaviour is the fuller one: it clears the session, the
  lock **and** `_skipAccess`. This is a source defect — see
  `MEMORY.md`.

### `PlaytimeRewardsService.GrantSkipAccess(player: any): boolean`

Grants the paid skip-all entitlement. Same contract as the Daily
equivalent.

- **Returns:** `true` on grant, `false` when `player` has no numeric
  `UserId`.
- **Notes:** idempotent; session state; cleared on leave.

### `PlaytimeRewardsService.Init(): ()`

- **Failure modes:** never throws. Idempotent.
- **Side effects:** logs every `PlaytimeRewardsConfig.ValidateLive()`
  issue as a warning, then connects the `PlaytimeRewardsAction` remote.

### `PlaytimeRewardsService._TestReset(): ()`

Clears the sessions, the locks, the skip entitlements, resets
`sessionToken`, and calls `PlaytimeRewardsDay._TestReset()`.

- **Failure modes:** never throws. Does not reset `started`.

---

## `PlaytimeRewardsDay`

`require(ServerScriptService.Playtime.PlaytimeRewardsDay)`

The global daily pool selector.

### `PlaytimeRewardsDay.DayIndexAt(now: number): number`

The day index in the configured timezone.

- **Parameters:** `now` — a unix timestamp.
- **Returns:** `math.floor((now + IST_OFFSET_SECONDS) / 86400)` — a
  non-negative integer.
- **Failure modes:** never throws. A non-number `now` produces a
  nonsensical but finite number (the caller always passes `os.time()`).
- **Notes:** `IST_OFFSET_SECONDS` comes from
  `PlaytimeRewardsConfig.Settings.DayBoundaryOffsetSeconds` (19800 =
  UTC+5:30). The day boundary is 00:00 in that timezone, computed from
  **server** time only.

### `PlaytimeRewardsDay.Current(nowOverride: number?): { [string]: string }`

The current global day.

- **Parameters:** `nowOverride` — an optional unix timestamp.
- **Returns:** `{ DayId, PoolId, Source }` where
  - `DayId` is `'D%06d'` of the day index (e.g. `'D005000'`),
  - `PoolId` is the selected pool id, or `''` when misconfigured,
  - `Source` is one of:
    | `Source` | Meaning |
    |---|---|
    | `'global'` | the DataStore committed the selection |
    | `'local-fallback'` | the DataStore was unreachable; a **deterministic hash** picked the pool, so all servers still agree |
    | `'misconfigured'` | no valid pool exists for the day — check `PlaytimeRewardsConfig` |
- **Failure modes:** never throws. The DataStore is `pcall`-guarded and
  the store handle is cached; a failed handle is not retried
  (`storeFailed` latches).
- **Notes:** the result is cached per `dayIndex` and refreshed exactly at
  the boundary. The selection happens inside an **atomic**
  `UpdateAsync`, so when several servers cross the boundary at the same
  moment exactly one pool wins fleet-wide.

### `PlaytimeRewardsDay._TestReset(): ()`

Clears the cache, the store handle, and the `storeFailed` latch.

- **Failure modes:** never throws.

---

## `DailyRewardsWeek`

`require(ServerScriptService.Daily.DailyRewardsWeek)`

The global **weekly** pool selector — the sibling of
`PlaytimeRewardsDay` for the daily system. It is a **required dependency**
of `DailyRewardsService`, which reaches it through
`require(script.Parent.DailyRewardsWeek)`; the file must therefore be a
**direct child** of `ServerScriptService/Daily/`.

The module table is `table.freeze`d. It exports exactly **two**
functions. There is **no** `Init`, no `Start`, no setter and no
`Set*Service` — it is `require`d on demand and every call is
self-contained.

### Constants

Module-locals — **not** exported. Documented here because they are the
tunables.

| Name | Type | Value | Line |
|---|---|---|---|
| `SECONDS_PER_WEEK` | `number` | `604800` (`7 * 24 * 60 * 60`) | 48 |
| `DATASTORE_NAME` | `string` | `'p7_DailyRewards_Weekly_v1'` | 49 |
| `DATASTORE_KEY` | `string` | `'CurrentWeek'` | 50 |

---

### `DailyRewardsWeek.Current(nowOverride: number?): { [string]: string }`

The current global week. The **only** public function of the module.

- **Parameters:** `nowOverride` — an optional unix timestamp. When it is
  a number it is used instead of `os.time()` (this is how a spec
  simulates a different week). When it is anything else, `os.time()` is
  used. **Server time only** — the client clock is never consulted.
- **Returns:** a table with exactly three string fields:
  | Field | Value |
  |---|---|
  | `WeekId` | `'W%06d'` of `floor(now / 604800)` — e.g. `'W002994'`. The boundary is **Thursday 00:00 UTC**. |
  | `PoolId` | the selected pool id, e.g. `'Pool_B'`. **`''` when misconfigured.** |
  | `Source` | `'global'` — the DataStore committed the selection.<br>`'local-fallback'` — the DataStore was unreachable and a deterministic hash picked the pool (all servers still agree).<br>`'misconfigured'` — no valid pool exists; check the catalog. |
- **Failure modes:** **never throws.**
  - The DataStore handle acquisition is `pcall`-guarded; a failure
    latches `storeFailed` and the module stays in fallback mode for the
    rest of the server's life.
  - The `UpdateAsync` is `pcall`-guarded; a throw falls through to the
    fallback.
  - The `UpdateAsync` **return value** is re-validated after the
    `pcall` (`type(result) == 'table'`, `result.WeekId == weekId`,
    `validPoolId(result.PoolId)`); anything unexpected is treated as
    "unreachable" and takes the fallback path.
  - A catalog with **zero** valid pools returns
    `{ WeekId = <id>, PoolId = '', Source = 'misconfigured' }` and warns
    **once per week** (the miss is cached with the week's index).
- **Behaviour notes:**
  - **Cached per week.** Within a week, the call is an O(1) integer
    compare and performs **no DataStore traffic**. The cache is only
    bypassed when the cached `PoolId` is no longer valid in the config.
  - The result is a **fresh table** every call — mutating it does not
    affect the cache.
  - The selection happens inside an **atomic `UpdateAsync`**, so when
    several servers cross the week boundary simultaneously, exactly one
    pool wins fleet-wide. The losers re-run against the committed value
    and keep it.
  - The avoid-repeat promise covers **back-to-back repeats only** — week
    N+1 may reuse week N-1's pool. A single-pool catalog trivially
    repeats.
  - The fallback path's avoid-repeat is **best-effort**: it knows the
    hash chain, not the stored `PreviousPoolId`.
  - **The `Source` field is informational.** Nothing in the game branches
    on it.

---

### `DailyRewardsWeek._TestReset(): ()`

Clears all module state.

- **Parameters:** none.
- **Returns:** nothing.
- **Failure modes:** never throws.
- **Side effects:**
  - `cache = { weekIndex = -1, weekId = '', poolId = '', source = '' }`
    — the `-1` sentinel guarantees the next call misses.
  - `storeHandle = nil` — the DataStore handle is re-acquired on the
    next call.
  - `storeFailed = false` — the failure latch is cleared, so a spec can
    retry the store after a simulated outage.
- **Notes:** `DailyRewardsService._TestReset()` calls this for you, so
  resetting the daily service also resets this module.

---

## Module-locals (not public)

Listed so you know what exists and why. Do not call these.

### `CodesService`

| Local | Purpose |
|---|---|
| `logCode(message, context)` | `Debug.Log('CD', ...)` |
| `lockKey(userId, norm)` | `tostring(userId) .. '\0' .. norm` |
| `pushResult(player, payload)` | fires `CodesResult` |
| `failRedeem(player, reason, warningId, warningData)` | the failure terminal: notifies + builds the result table |
| `getData(userId)` | `PlayerService.GetPlayerData` |
| `sanitizePendingEntry(entry)` | validates one pending row, returns a clean copy or `nil` |
| `queuePending(data, entry)` | appends to the pending queue |
| `deliverEgg(userId, data, codeId, rarity)` | the slot-bound egg delivery |
| `deliverAnimal(userId, data, codeId, defId, trait, level)` | the slot-bound animal delivery |
| `describeRewards(...)` | builds the server-formatted reward summary |
| `formatCash(amount)` | `'+' .. BigNumber.Format(amount)` |
| `handleAction(player, payload)` | the `CodesAction` remote handler |

### `DailyRewardsService`

| Local | Purpose |
|---|---|
| `logDaily(message, context)` | `Debug.Log('DR', ...)` |
| `pushStateRemote` / `pushResult` | fire `DailyRewardsState` / `DailyRewardsResult` |
| `failClaim(player, reason, warningId)` | the failure terminal |
| `getData(userId)` | `PlayerService.GetPlayerData` |
| `sliceOf(data)` | lazy-heals the `DailyRewards` profile slice |
| `ensureWeek(slice, weekId)` | resets the slice when the global week changed |
| `computeStatus(slice, now)` | pure eligibility computation |
| `gearDisplayName` / `animalDisplayName` | display names for the snapshot |
| `dayState(day, status)` | `'Claimable'` / `'Claimed'` / `'Locked'` |
| `describeDay(pool, day, state)` | the per-day card descriptor |
| `checkInvariants(days, slice, status, context)` | the development invariant audit |
| `formatCash(amount)` | `'+' .. BigNumber.Format(amount)` |
| `maybeBroadcastWeek(weekId)` | the week-rollover broadcast |
| `commitDayRewards(...)` | the shared day-grant (used by Claim and ClaimAll) |
| `handleAction(player, payload)` | the `DailyRewardsAction` remote handler |

### `PlaytimeRewardsService`

| Local | Purpose |
|---|---|
| `logPlaytime(message, context)` | `Debug.Log('PT', ...)` |
| `pushStateRemote` / `pushResult` | fire `PlaytimeRewardsState` / `PlaytimeRewardsResult` |
| `failClaim(player, reason, warningId)` | the failure terminal |
| `getData(userId)` | `PlayerService.GetPlayerData` |
| `persistedOf(data)` | lazy-heals the `PlaytimeRewards` profile slice |
| `randomPoolExcluding(excludeId)` | the personal post-completion pool pick |
| `resolveSession(userId, data)` | the whole session lifecycle |
| `sessionPlaytime(session)` | `os.clock() - session.start` |
| `gearDisplayName` / `animalDisplayName` | display names |
| `formatCash(amount)` | `'+' .. BigNumber.Format(amount)` |
| `milestoneState(claimed, playtime, required)` | `'Claimed'` / `'Claimable'` / `'Locked'` |
| `commitMilestone(...)` | the shared milestone-grant (used by Claim and ClaimAll) |
| `handleAction(player, payload)` | the `PlaytimeRewardsAction` remote handler |

### `PlaytimeRewardsDay`

| Local | Purpose |
|---|---|
| `logDay(message, context)` | `Debug.Log('PTD', ...)` |
| `dayIdOf(dayIndex)` | `'D%06d'` |
| `validPoolId(poolId)` | the pool exists in the config |
| `hashDay(dayId)` | the deterministic fallback hash |
| `poolIds()` | the config pool ids |
| `deterministicPoolId(dayId, prevDayId)` | the fallback pick (avoids repeating the previous day's pool) |
| `randomPoolId(excludeId)` | the global random pick |
| `getStore()` | the cached DataStore handle |
| `loadOrSelectGlobal(dayId)` | the atomic `UpdateAsync` selection |

### `DailyRewardsWeek`

| Local | Purpose |
|---|---|
| `logWeek(message, context)` | `Debug.Log('DRW', message, context)` |
| `weekIndexAt(now)` | `math.floor(now / SECONDS_PER_WEEK)` |
| `weekIdOf(weekIndex)` | `('W%06d'):format(weekIndex)` |
| `validPoolId(poolId)` | the pool id exists in `DailyRewardsConfig.WeeklyPools` |
| `hashWeek(weekId)` | a 33-multiplier rolling hash mod 1000003 (fallback path only) |
| `poolIds()` | the config pool ids |
| `deterministicPoolId(weekId, prevWeekId)` | the fallback pick; avoids repeating the previous week's hash pick |
| `randomPoolId(excludeId)` | the global pick; excludes `excludeId` when alternatives exist |
| `getStore()` | the cached DataStore handle, with the `storeFailed` latch |
| `loadOrSelectGlobal(weekId)` | the atomic `UpdateAsync` load-or-select |
